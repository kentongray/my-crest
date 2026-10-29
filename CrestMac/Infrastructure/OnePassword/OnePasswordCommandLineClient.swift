import Foundation

// MARK: - Types

/// An account as `op account list` reports it.
private struct OnePasswordCommandLineAccount: Decodable {
    let accountUUID: String

    enum CodingKeys: String, CodingKey { case accountUUID = "account_uuid" }
}

/// An item as `op item list` reports it.
private struct OnePasswordCommandLineOverview: Decodable {
    struct Vault: Decodable { let id: String }
    struct Link: Decodable { let href: String }

    let id: String
    let title: String
    let category: String
    let vault: Vault
    let urls: [Link]?
}

/// An item as `op item get` reports it.
private struct OnePasswordCommandLineItem: Decodable {
    struct Vault: Decodable { let id: String }
    struct Field: Decodable {
        let id: String
        let type: String?
        let purpose: String?
        let label: String?
        let value: String?
    }

    let id: String
    let title: String
    let category: String
    let vault: Vault
    let fields: [Field]?
}

/// One 1Password account read through the 1Password CLI, `op`, which the
/// 1Password app authorizes through its own "Integrate with 1Password CLI"
/// setting and prompt.
///
/// `op` runs as its own signed program, so Crest loads nothing of 1Password's
/// into its process. Only item and vault identifiers travel on its command
/// line; values come back on its standard output and are never logged.
actor OnePasswordCommandLineClient: OnePasswordAccountReading {
    // MARK: - Static Variables

    /// Where Homebrew and 1Password's installer put `op`.
    static let candidatePaths = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
    /// How long a call may wait, which covers 1Password's authorization prompt.
    private static let timeout: TimeInterval = 120

    // MARK: - Variables

    let accountName: String
    private let executable: URL

    // MARK: - Initializers

    init(accountName: String, executable: URL) {
        self.accountName = accountName
        self.executable = executable
    }

    // MARK: - Actions - Accounts

    /// The installed `op`, or nil when there is none.
    static func installedExecutable() -> URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// Every account the 1Password app has signed in.
    static func accountNames(using executable: URL) async throws -> [String] {
        let output = try await run(executable, ["account", "list", "--format", "json"])
        guard let accounts = try? JSONDecoder().decode([OnePasswordCommandLineAccount].self, from: output) else {
            throw OnePasswordDesktopError.unreadableResponse
        }
        return accounts.map(\.accountUUID)
    }

    // MARK: - Actions - Items

    func loginOverviews() async throws -> [OnePasswordItemOverview] {
        let output = try await Self.run(
            executable, ["item", "list", "--account", accountName, "--categories", "Login", "--format", "json"])
        guard let overviews = try? JSONDecoder().decode([OnePasswordCommandLineOverview].self, from: output) else {
            throw OnePasswordDesktopError.unreadableResponse
        }
        // The CLI reports no autofill behavior; 1Password's default, anywhere
        // on the website, stands in for it.
        return overviews.map { overview in
            OnePasswordItemOverview(
                id: overview.id, title: overview.title, category: "Login", vaultId: overview.vault.id,
                websites: (overview.urls ?? []).map {
                    OnePasswordWebsite(url: $0.href, autofillBehavior: .anywhereOnWebsite)
                },
                state: nil)
        }
    }

    func item(_ itemID: String, inVault vaultID: String) async throws -> OnePasswordItem {
        let output = try await Self.run(
            executable,
            ["item", "get", itemID, "--vault", vaultID, "--account", accountName, "--reveal", "--format", "json"])
        guard let item = try? JSONDecoder().decode(OnePasswordCommandLineItem.self, from: output) else {
            throw OnePasswordDesktopError.unreadableResponse
        }
        return OnePasswordItem(
            id: item.id, title: item.title, category: "Login", vaultId: item.vault.id,
            fields: (item.fields ?? []).map { field in
                // The CLI marks the built-in fields by purpose rather than id.
                let id =
                    switch field.purpose {
                    case "USERNAME": "username"
                    case "PASSWORD": "password"
                    default: field.id
                    }
                return OnePasswordItemField(
                    id: id, title: field.label ?? "", fieldType: field.type == "CONCEALED" ? "Concealed" : "Text",
                    value: field.value ?? "")
            })
    }

    // MARK: - Actions - Process

    /// Runs `op` and returns its standard output, or throws what its error said.
    private static func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: OnePasswordDesktopError.connectionDropped)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: OnePasswordDesktopError.commandLine(errorText))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
