import Foundation
import OSLog
import Observation

// MARK: - Types

/// A 1Password login Crest may offer, without its username or password.
private struct OnePasswordLogin: Sendable {
    let id: UUID
    let accountName: String
    let vaultID: String
    let itemID: String
    let title: String
    let websites: [OnePasswordWebsite]
}

/// 1Password's logins, offered in Crest's password prompt beside the Space's
/// own, read through the 1Password desktop app.
///
/// The source keeps only an index of login items, never a username or
/// password: the index lists titles and websites, a suggestion reads each
/// matching item for its username, and a fill reads the chosen item again for
/// its password, which goes straight to the page. The index refreshes in the
/// background once it is older than a few minutes and is dropped when the
/// source is turned off.
@Observable
@MainActor
final class BrowserOnePasswordCredentialSource: BrowserExternalCredentialSource {
    // MARK: - Static Variables

    static let enabledKey = "crest.passwords.onepassword.enabled"
    static let accountsKey = "crest.passwords.onepassword.accounts"
    /// How old the index may be before a lookup refreshes it.
    private static let indexLifetime: TimeInterval = 5 * 60
    /// How many matching items a suggestion reads for their usernames.
    private static let suggestionLimit = 8
    private static let log = Logger(subsystem: "com.pauldavis.crest", category: "OnePassword")

    // MARK: - Variables

    let name = "1Password"
    private(set) var status = BrowserExternalCredentialSourceStatus.idle

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            resetIndex()
            if isEnabled { Task { await checkConnection() } } else { status = .idle }
        }
    }

    var accounts: String {
        didSet {
            guard accounts != oldValue else { return }
            defaults.set(accounts, forKey: Self.accountsKey)
            resetIndex()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var clients: [String: any OnePasswordAccountReading] = [:]
    /// The route to the app this process settled on, once a lookup needed one.
    @ObservationIgnored private var route: Route?
    @ObservationIgnored private var logins: [OnePasswordLogin] = []
    @ObservationIgnored private var loginsByID: [UUID: OnePasswordLogin] = [:]
    /// Each item keeps one identity across refreshes, so a prompt still open
    /// over an older index can fill what it shows.
    @ObservationIgnored private var identities: [String: UUID] = [:]
    /// The descriptors suggestions handed out, each naming the Space and page
    /// origin it was offered for, so a fill carries exactly what the prompt
    /// checks. They hold usernames, never passwords.
    @ObservationIgnored private var offered: [UUID: CredentialDescriptor] = [:]
    @ObservationIgnored private var indexedAt: Date?
    @ObservationIgnored private var indexing: Task<Void, Never>?

    // MARK: - Initializers

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        accounts = defaults.string(forKey: Self.accountsKey) ?? ""
    }

    // MARK: - Actions - Suggestions

    func descriptors(matching origin: CredentialOrigin, in spaceID: UUID) async throws -> [CredentialDescriptor] {
        guard isEnabled, origin.isSecure else { return [] }
        do {
            try await ensureIndex()
        } catch {
            // The prompt still offers the Space's own passwords; settings say
            // why 1Password's are missing.
            status = Self.status(for: error)
            throw error
        }
        let matches = logins.filter { login in login.websites.contains { $0.matches(origin) } }
        var descriptors: [CredentialDescriptor] = []
        for login in matches.prefix(Self.suggestionLimit) {
            guard let item = try? await client(for: login.accountName).item(login.itemID, inVault: login.vaultID)
            else { continue }
            let descriptor = CredentialDescriptor(
                id: login.id,
                spaceID: spaceID,
                origin: origin,
                username: Self.username(in: item),
                displayName: login.title
            )
            offered[login.id] = descriptor
            descriptors.append(descriptor)
        }
        return descriptors
    }

    func credential(id: UUID) async throws -> BrowserCredential? {
        guard isEnabled, let login = loginsByID[id], var descriptor = offered[id] else { return nil }
        let item = try await client(for: login.accountName).item(login.itemID, inVault: login.vaultID)
        guard let password = Self.password(in: item) else { return nil }
        descriptor.username = Self.username(in: item)
        return BrowserCredential(descriptor: descriptor, password: password)
    }

    func recognizes(_ id: UUID) -> Bool {
        offered[id] != nil
    }

    // MARK: - Actions - Connection

    func checkConnection() async {
        guard isEnabled else {
            status = .idle
            return
        }
        do {
            resetIndex()
            try await ensureIndex()
            let accountCount = Set(logins.map(\.accountName)).count
            status = BrowserExternalCredentialSourceStatus(
                message: String(
                    localized:
                        "Connected \(route?.description ?? ""): \(logins.count) logins from \(accountCount) \(accountCount == 1 ? "account" : "accounts")."
                ),
                needsAttention: false)
        } catch {
            status = Self.status(for: error)
        }
    }

    // MARK: - Actions - Index

    /// The accounts the person listed, or with none listed, every account
    /// the 1Password app reports through its CLI.
    private func resolvedAccountNames() async throws -> [String] {
        let listed =
            accounts
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !listed.isEmpty { return listed }
        guard let executable = OnePasswordCommandLineClient.installedExecutable() else {
            throw SourceError.noAccounts
        }
        return try await OnePasswordCommandLineClient.accountNames(using: executable)
    }

    private func ensureIndex() async throws {
        if let indexedAt, Date().timeIntervalSince(indexedAt) < Self.indexLifetime { return }
        if indexedAt != nil {
            // A stale index still answers while a fresh one is read.
            refreshInBackground()
            return
        }
        try await rebuildIndex()
    }

    private func refreshInBackground() {
        guard indexing == nil else { return }
        indexing = Task { [weak self] in
            try? await self?.rebuildIndex()
            self?.indexing = nil
        }
    }

    private func rebuildIndex() async throws {
        let names = try await resolvedAccountNames()
        guard !names.isEmpty else { throw SourceError.noAccounts }
        var rebuilt: [OnePasswordLogin] = []
        var failure: (any Error)?
        for accountName in names {
            do {
                let client = try client(for: accountName)
                for overview in try await client.loginOverviews()
                where overview.state != "archived" && !overview.websites.isEmpty {
                    let key = "\(accountName)\n\(overview.vaultId)\n\(overview.id)"
                    let id = identities[key] ?? UUID()
                    identities[key] = id
                    rebuilt.append(
                        OnePasswordLogin(
                            id: id, accountName: accountName, vaultID: overview.vaultId, itemID: overview.id,
                            title: overview.title, websites: overview.websites))
                }
            } catch {
                // One account failing still offers the others' logins.
                Self.log.error("1Password account could not be read: \(String(describing: error), privacy: .public)")
                failure = failure ?? error
            }
        }
        if rebuilt.isEmpty, let failure { throw failure }
        logins = rebuilt
        loginsByID = Dictionary(rebuilt.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexedAt = Date()
    }

    private func resetIndex() {
        indexing?.cancel()
        indexing = nil
        logins = []
        loginsByID = [:]
        offered = [:]
        indexedAt = nil
        clients = [:]
        route = nil
    }

    private func client(for accountName: String) throws -> any OnePasswordAccountReading {
        if let client = clients[accountName] { return client }
        let route = try self.route ?? Route.available()
        self.route = route
        let client = route.client(for: accountName)
        clients[accountName] = client
        return client
    }

    /// How this process reaches the 1Password app: the integration library
    /// the app ships for its SDKs, loaded into Crest where the process may
    /// load it, or else the 1Password CLI as a separate program.
    private enum Route {
        case library(OnePasswordDesktopLibrary)
        case commandLine(URL)

        static func available() throws -> Route {
            if let library = try? OnePasswordDesktopLibrary() { return .library(library) }
            if let executable = OnePasswordCommandLineClient.installedExecutable() { return .commandLine(executable) }
            throw OnePasswordDesktopError.noRoute
        }

        func client(for accountName: String) -> any OnePasswordAccountReading {
            switch self {
            case .library(let library):
                OnePasswordDesktopClient(accountName: accountName, library: library)
            case .commandLine(let executable):
                OnePasswordCommandLineClient(accountName: accountName, executable: executable)
            }
        }

        var description: String {
            switch self {
            case .library: String(localized: "through the 1Password app")
            case .commandLine: String(localized: "through the 1Password CLI")
            }
        }
    }

    // MARK: - Actions - Fields

    /// The login's username: its built-in username field, or the first field
    /// titled as one.
    private static func username(in item: OnePasswordItem) -> String {
        let field =
            item.fields.first { $0.id == "username" }
            ?? item.fields.first { ["username", "email", "user name"].contains($0.title.lowercased()) }
        return field?.value ?? ""
    }

    /// The login's password: its built-in password field, or its first
    /// concealed field.
    private static func password(in item: OnePasswordItem) -> String? {
        let field =
            item.fields.first { $0.id == "password" }
            ?? item.fields.first { $0.fieldType == "Concealed" }
        guard let value = field?.value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Actions - Status

    private enum SourceError: Error {
        case noAccounts
    }

    private static func status(for error: any Error) -> BrowserExternalCredentialSourceStatus {
        let message: String
        switch error {
        case let error as OnePasswordDesktopError:
            message = error.message
        case SourceError.noAccounts:
            message = String(localized: "Enter the 1Password accounts to fill from, or install the 1Password CLI.")
        default:
            message = String(localized: "Crest couldn’t reach 1Password.")
        }
        return BrowserExternalCredentialSourceStatus(message: message, needsAttention: true)
    }
}
