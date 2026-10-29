import CryptoKit
import Foundation

/// The login Crest last filled into a page, kept only as its origin, username
/// and a digest of its password, so submitting it unchanged is not mistaken
/// for a new password to save. The password itself is never kept.
struct BrowserCredentialFilledLogin: Equatable, Sendable {
    // MARK: - Variables

    let origin: CredentialOrigin
    let username: String
    private let passwordDigest: Data

    // MARK: - Initializers

    init(origin: CredentialOrigin, username: String, password: String) {
        self.origin = origin
        self.username = username
        passwordDigest = Self.digest(of: password)
    }

    // MARK: - Actions - Matching

    /// Whether a submission of `username` and `password` on `origin` is this
    /// login, unchanged.
    func matches(origin: CredentialOrigin, username: String, password: String) -> Bool {
        origin == self.origin && username == self.username && Self.digest(of: password) == passwordDigest
    }

    private static func digest(of password: String) -> Data {
        Data(SHA256.hash(data: Data(password.utf8)))
    }
}
