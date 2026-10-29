import Foundation

/// One 1Password account's login items, read through whichever route to the
/// 1Password app this process can use.
protocol OnePasswordAccountReading: Actor {
    var accountName: String { get }
    /// Every login item that names a website, without field values.
    func loginOverviews() async throws -> [OnePasswordItemOverview]
    /// One item with its fields, which carry its username and password.
    func item(_ itemID: String, inVault vaultID: String) async throws -> OnePasswordItem
}

extension OnePasswordDesktopClient: OnePasswordAccountReading {
    func loginOverviews() async throws -> [OnePasswordItemOverview] {
        var overviews: [OnePasswordItemOverview] = []
        for vault in try await vaults() {
            overviews += try await items(inVault: vault.id).filter { $0.category == "Login" }
        }
        return overviews
    }
}
