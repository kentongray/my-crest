import Foundation
import XCTest

@testable import Crest

/// Which page origins a 1Password website may fill decides where a password
/// goes, so it stays as narrow as the item's own autofill setting.
final class OnePasswordWebsiteMatchingTests: XCTestCase {
    private func origin(_ host: String, scheme: String = "https", port: Int = 443) -> CredentialOrigin {
        CredentialOrigin(scheme: scheme, host: host, port: port)
    }

    private func website(_ url: String, _ behavior: OnePasswordAutofillBehavior = .anywhereOnWebsite)
        -> OnePasswordWebsite
    {
        OnePasswordWebsite(url: url, autofillBehavior: behavior)
    }

    func testAnywhereOnWebsiteFillsTheSiteAndItsSubdomainsOnly() {
        let saved = website("https://www.example.com/login")
        XCTAssertTrue(saved.matches(origin("example.com")))
        XCTAssertTrue(saved.matches(origin("www.example.com")))
        XCTAssertTrue(saved.matches(origin("accounts.example.com")))
        XCTAssertFalse(saved.matches(origin("example.com.evil.test")))
        XCTAssertFalse(saved.matches(origin("notexample.com")))
        XCTAssertFalse(saved.matches(origin("example.org")))
    }

    func testExactDomainAndNeverStayNarrow() {
        let exact = website("login.example.com", .exactDomain)
        XCTAssertTrue(exact.matches(origin("login.example.com")))
        XCTAssertFalse(exact.matches(origin("other.login.example.com")))
        XCTAssertFalse(exact.matches(origin("example.com")))
        XCTAssertFalse(website("example.com", .never).matches(origin("example.com")))
        XCTAssertFalse(website("example.com", .named("SomethingNew")).matches(origin("www.example.com")))
    }

    func testOnlySecurePagesOnTheSavedPortFill() {
        XCTAssertFalse(website("example.com").matches(origin("example.com", scheme: "http", port: 80)))
        XCTAssertFalse(website("example.com").matches(origin("example.com", port: 8443)))
        XCTAssertTrue(website("https://example.com:8443").matches(origin("example.com", port: 8443)))
        XCTAssertFalse(website("https://example.com:8443").matches(origin("example.com")))
    }

    func testAddressesAndUnreadableWebsitesNeverReachOtherHosts() {
        XCTAssertTrue(website("https://192.168.1.10").matches(origin("192.168.1.10")))
        XCTAssertFalse(website("https://1.10").matches(origin("192.168.1.10")))
        XCTAssertFalse(website("").matches(origin("example.com")))
        XCTAssertFalse(website("not a url at all").matches(origin("example.com")))
        XCTAssertFalse(website("com").matches(origin("example.com")))
    }
}
