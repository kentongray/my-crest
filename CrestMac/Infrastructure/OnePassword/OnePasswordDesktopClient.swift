import Foundation

// MARK: - Types

/// One of the app's vaults, by the fields Crest reads.
struct OnePasswordVault: Decodable, Sendable {
    let id: String
    let title: String
}

/// An item as the app lists it: no field values, so no secrets.
struct OnePasswordItemOverview: Decodable, Sendable {
    let id: String
    let title: String
    let category: String
    let vaultId: String
    let websites: [OnePasswordWebsite]
    let state: String?
}

/// An item with its fields, which carry its secrets.
struct OnePasswordItem: Decodable, Sendable {
    let id: String
    let title: String
    let category: String
    let vaultId: String
    let fields: [OnePasswordItemField]
}

struct OnePasswordItemField: Decodable, Sendable {
    let id: String
    let title: String
    let fieldType: String
    let value: String
}

/// The envelope every request to the library travels in. The account and
/// payload ride as the official Go SDK sends them, the payload as base64.
private struct OnePasswordDesktopRequest: Encodable {
    let kind: String
    let accountName: String
    let payload: Data

    enum CodingKeys: String, CodingKey {
        case kind
        case accountName = "account_name"
        case payload
    }
}

private struct OnePasswordDesktopResponse: Decodable {
    let success: Bool
    let payload: Data
}

/// What the app says when it refuses a request.
private struct OnePasswordDesktopRefusal: Decodable {
    let name: String?
    let message: String?
}

/// What identifies this client to the app, which shows the integration's name
/// in its authorization prompt.
private struct OnePasswordClientConfiguration: Encodable {
    let serviceAccountToken = ""
    let programmingLanguage = "Swift"
    let sdkVersion = "0040102"
    let integrationName: String
    let integrationVersion: String
    let requestLibraryName = "URLSession"
    let requestLibraryVersion = "Foundation"
    let os = "darwin"
    let osVersion: String
    let architecture = "arm64"
    let accountName: String

    enum CodingKeys: String, CodingKey {
        case serviceAccountToken, programmingLanguage, sdkVersion, integrationName, integrationVersion
        case requestLibraryName, requestLibraryVersion, os, osVersion, architecture
        case accountName = "account_name"
    }
}

private struct OnePasswordInvocation<Parameters: Encodable>: Encodable {
    struct Call: Encodable {
        let clientId: UInt64
        let parameters: Method
    }

    struct Method: Encodable {
        let name: String
        let parameters: Parameters
    }

    let invocation: Call
}

/// No list options, which the official SDK sends as a null `params`.
private struct OnePasswordVaultListParameters: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .params)
    }

    enum CodingKeys: String, CodingKey { case params }
}

private struct OnePasswordItemListParameters: Encodable {
    let vaultId: String
    let filters: [String] = []

    enum CodingKeys: String, CodingKey {
        case vaultId = "vault_id"
        case filters
    }
}

private struct OnePasswordItemGetParameters: Encodable {
    let vaultId: String
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case vaultId = "vault_id"
        case itemId = "item_id"
    }
}

/// One 1Password account, read through the desktop app.
///
/// The account is named as the person knows it: the name at the top of the
/// app's sidebar, its sign-in address, or its UUID. The app authorizes this
/// process per account and lets that lapse after ten idle minutes or when it
/// locks; a lapsed client is created again and the request retried once, which
/// may show the app's prompt again.
actor OnePasswordDesktopClient {
    // MARK: - Variables

    let accountName: String
    private let library: OnePasswordDesktopLibrary
    private var clientID: UInt64?

    // MARK: - Initializers

    init(accountName: String, library: OnePasswordDesktopLibrary) {
        self.accountName = accountName
        self.library = library
    }

    // MARK: - Actions - Vaults and Items

    func vaults() async throws -> [OnePasswordVault] {
        try await invoke("VaultsList", OnePasswordVaultListParameters())
    }

    func items(inVault vaultID: String) async throws -> [OnePasswordItemOverview] {
        try await invoke("ItemsList", OnePasswordItemListParameters(vaultId: vaultID))
    }

    func item(_ itemID: String, inVault vaultID: String) async throws -> OnePasswordItem {
        try await invoke("ItemsGet", OnePasswordItemGetParameters(vaultId: vaultID, itemId: itemID))
    }

    // MARK: - Actions - Requests

    private func invoke<Parameters: Encodable, Answer: Decodable>(
        _ method: String, _ parameters: Parameters
    ) async throws -> Answer {
        do {
            return try await invokeOnce(method, parameters)
        } catch OnePasswordDesktopError.sessionExpired {
            clientID = nil
            return try await invokeOnce(method, parameters)
        }
    }

    private func invokeOnce<Parameters: Encodable, Answer: Decodable>(
        _ method: String, _ parameters: Parameters
    ) async throws -> Answer {
        let id = try await connectedClientID()
        let invocation = OnePasswordInvocation(
            invocation: .init(clientId: id, parameters: .init(name: method, parameters: parameters)))
        let answer = try await send(kind: "invoke", payload: JSONEncoder().encode(invocation))
        do {
            return try JSONDecoder().decode(Answer.self, from: answer)
        } catch {
            throw OnePasswordDesktopError.unreadableResponse
        }
    }

    private func connectedClientID() async throws -> UInt64 {
        if let clientID { return clientID }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let configuration = OnePasswordClientConfiguration(
            integrationName: "Crest",
            integrationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            accountName: accountName
        )
        let answer = try await send(kind: "init_client", payload: JSONEncoder().encode(configuration))
        guard let id = try? JSONDecoder().decode(UInt64.self, from: answer) else {
            throw OnePasswordDesktopError.unreadableResponse
        }
        clientID = id
        return id
    }

    private func send(kind: String, payload: Data) async throws -> Data {
        let request = try JSONEncoder().encode(
            OnePasswordDesktopRequest(kind: kind, accountName: accountName, payload: payload))
        let response: OnePasswordDesktopResponse
        do {
            response = try JSONDecoder().decode(OnePasswordDesktopResponse.self, from: await library.send(request))
        } catch let error as OnePasswordDesktopError {
            throw error
        } catch {
            throw OnePasswordDesktopError.unreadableResponse
        }
        guard response.success else {
            let refusal = try? JSONDecoder().decode(OnePasswordDesktopRefusal.self, from: response.payload)
            if refusal?.name == "DesktopSessionExpired" { throw OnePasswordDesktopError.sessionExpired }
            throw OnePasswordDesktopError.refused(
                refusal?.message ?? String(decoding: response.payload, as: UTF8.self))
        }
        return response.payload
    }
}
