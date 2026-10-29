import Foundation

/// How far a 1Password website reaches, as the person set it on the item.
struct OnePasswordAutofillBehavior: Hashable, Sendable {
    // MARK: - Static Variables

    /// The site and every subdomain of it.
    static let anywhereOnWebsite = OnePasswordAutofillBehavior(
        name: "AnywhereOnWebsite", fills: true, includesSubdomains: true)
    /// Only the exact host the item names.
    static let exactDomain = OnePasswordAutofillBehavior(name: "ExactDomain", fills: true, includesSubdomains: false)
    /// Never fills.
    static let never = OnePasswordAutofillBehavior(name: "Never", fills: false, includesSubdomains: false)
    static let all = [anywhereOnWebsite, exactDomain, never]

    // MARK: - Variables

    let name: String
    let fills: Bool
    let includesSubdomains: Bool

    // MARK: - Actions - Lookup

    /// The behavior the app wrote, read as the narrowest reach when it is one
    /// this client does not know.
    static func named(_ name: String?) -> OnePasswordAutofillBehavior {
        all.first { $0.name == name }
            ?? OnePasswordAutofillBehavior(name: name ?? "", fills: true, includesSubdomains: false)
    }
}

/// A website saved on a 1Password item, and which page origins it may fill.
///
/// A login is offered only on a secure page whose host is the item's host or,
/// when the item reaches anywhere on the website, a subdomain of it. A
/// leading `www.` on the item does not narrow it. Ports must agree: an item
/// that names one fills only there, and one that names none fills only on the
/// default port. Anything this cannot read does not match.
struct OnePasswordWebsite: Decodable, Sendable {
    // MARK: - Variables

    let url: String
    let autofillBehavior: OnePasswordAutofillBehavior

    // MARK: - Actions - Matching

    func matches(_ origin: CredentialOrigin) -> Bool {
        guard autofillBehavior.fills, origin.scheme == "https",
            let saved = Self.parsed(url)
        else { return false }
        let pageHost = Self.normalized(origin.host)
        guard !pageHost.isEmpty else { return false }
        if let port = saved.port {
            guard port == origin.port else { return false }
        } else {
            guard origin.port == 443 else { return false }
        }
        if pageHost == saved.host { return true }
        let base = saved.host.hasPrefix("www.") ? String(saved.host.dropFirst(4)) : saved.host
        if pageHost == base { return true }
        // An address names one machine; only names have subdomains.
        guard autofillBehavior.includesSubdomains, !Self.isAddress(base), base.contains(".") else { return false }
        return pageHost.hasSuffix("." + base)
    }

    /// The saved host and any explicit port. 1Password stores websites as the
    /// person typed them, often with no scheme.
    private static func parsed(_ url: String) -> (host: String, port: Int?)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
            components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http",
            let host = components.host.map(normalized), !host.isEmpty
        else { return nil }
        return (host, components.port)
    }

    private static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

extension OnePasswordWebsite {
    private enum CodingKeys: String, CodingKey {
        case url
        case autofillBehavior
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        autofillBehavior = .named(try container.decodeIfPresent(String.self, forKey: .autofillBehavior))
    }
}
