import Foundation

// MARK: - Types

/// Where an external password manager stands, for its settings section.
struct BrowserExternalCredentialSourceStatus: Equatable, Sendable {
    /// One line a person can act on, or nil when there is nothing to say.
    let message: String?
    /// Whether the message describes something the person must fix.
    let needsAttention: Bool

    static let idle = BrowserExternalCredentialSourceStatus(message: nil, needsAttention: false)
}

/// A password manager outside Crest whose logins the password prompt offers
/// beside the Space's own.
///
/// A source never stores anything in Crest. It answers which of its logins
/// suit an origin with descriptors whose identities it alone recognises, and
/// reads a login's password only when the person picks one to fill. Private
/// browsing and isolated launches never reach a source.
@MainActor
protocol BrowserExternalCredentialSource: AnyObject {
    /// The manager's name as people know it, such as "1Password".
    var name: String { get }
    /// Whether the person turned the source on for this device.
    var isEnabled: Bool { get set }
    /// The accounts the source reads, as the person wrote them.
    var accounts: String { get set }
    var status: BrowserExternalCredentialSourceStatus { get }

    /// The source's logins for `origin`, as descriptors in `spaceID` that
    /// carry `origin` itself, so a fill passes the same origin check as a
    /// login the Space saved.
    func descriptors(matching origin: CredentialOrigin, in spaceID: UUID) async throws -> [CredentialDescriptor]
    /// The login behind a descriptor this source returned, with its password,
    /// or nil when the source no longer has it.
    func credential(id: UUID) async throws -> BrowserCredential?
    /// Whether `id` names a descriptor this source returned.
    func recognizes(_ id: UUID) -> Bool
    /// Reaches the manager once, so its status says whether filling will work.
    func checkConnection() async
}
