import Foundation
import WebKit
import XCTest

@testable import Crest

@MainActor
final class BrowserCredentialFormTests: XCTestCase {
    func testFocusMessageRequiresATrustedGestureAndNeverAcceptsAPassword() throws {
        let valid = try XCTUnwrap(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "focus",
                "trusted": true,
                "formID": "form-1",
                "username": "person@example.com",
                "passwordKind": "current",
            ]))

        XCTAssertEqual(valid.event, .focus)
        XCTAssertEqual(valid.formID, "form-1")
        XCTAssertEqual(valid.username, "person@example.com")
        XCTAssertNil(valid.password)
        XCTAssertNil(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "focus",
                "trusted": false,
                "formID": "form-1",
            ]))
        XCTAssertNil(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "focus",
                "trusted": true,
                "formID": "form-1",
            ]))
        XCTAssertNil(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "focus",
                "trusted": true,
                "formID": "form-1",
                "password": "page-tried-to-exfiltrate-this",
            ]))
    }

    func testSubmitMessageRequiresCompleteTrustedFieldsAndRedactsItsSecret() throws {
        let message = try XCTUnwrap(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "submit",
                "trusted": true,
                "formID": "form-7",
                "username": "person",
                "password": "correct horse battery staple",
                "passwordKind": "new",
            ]))

        XCTAssertEqual(message.event, .submit)
        XCTAssertEqual(message.username, "person")
        XCTAssertEqual(message.password, "correct horse battery staple")
        XCTAssertEqual(message.passwordKind, .new)
        XCTAssertFalse(message.description.contains("correct horse battery staple"))
        XCTAssertTrue(message.description.contains("<redacted>"))

        XCTAssertNil(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "submit",
                "trusted": false,
                "formID": "form-7",
                "username": "person",
                "password": "secret",
                "passwordKind": "current",
            ]))
        let passwordOnlyStep = try XCTUnwrap(
            BrowserCredentialFormMessage(body: [
                "version": 1,
                "event": "submit",
                "trusted": true,
                "formID": "form-7",
                "password": "secret",
                "passwordKind": "current",
            ]))
        XCTAssertNil(passwordOnlyStep.username)
        XCTAssertEqual(passwordOnlyStep.password, "secret")
    }

    func testIsolatedBridgeClassifiesAndFillsAnOrdinaryLoginForm() async throws {
        let webView = try await credentialBridgeWebView(
            html: """
                <!doctype html>
                <style>input { display: block; width: 220px; height: 32px; }</style>
                <form id="login">
                  <input id="login-user" autocomplete="username" value="person@example.com">
                  <input id="login-password" type="password" autocomplete="current-password" value="old-secret">
                </form>
                """)

        let inspectionResult = try await inspect("#login", in: webView)
        let inspection = try XCTUnwrap(inspectionResult)
        let pageWorldBridgeVisibility = try await webView.callAsyncJavaScript(
            "return typeof globalThis.__crestCredentialBridge;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        XCTAssertEqual(pageWorldBridgeVisibility as? String, "undefined")
        XCTAssertEqual(inspection["username"] as? String, "person@example.com")
        XCTAssertEqual(inspection["passwordKind"] as? String, "current")
        XCTAssertEqual(inspection["passwordFieldID"] as? String, "login-password")
        XCTAssertEqual(inspection["passwordFieldCount"] as? Int, 1)

        let formID = try XCTUnwrap(inspection["formID"] as? String)
        let didFill = try await fill(
            formID: formID,
            username: "filled@example.com",
            password: "filled-secret",
            in: webView
        )
        XCTAssertTrue(didFill)
        let pageValues = try await pageJSON(
            """
            return JSON.stringify({
              username: document.querySelector('#login-user').value,
              password: document.querySelector('#login-password').value
            });
            """,
            in: webView
        )
        XCTAssertEqual(pageValues["username"] as? String, "filled@example.com")
        XCTAssertEqual(pageValues["password"] as? String, "filled-secret")
    }

    func testSignInUsernameFieldRaisesThePromptAndOtherFieldsDoNot() async throws {
        var focusMessages: [[String: Any]] = []
        let webView = try await credentialBridgeWebView(
            html: """
                <!doctype html>
                <style>input { display: block; width: 220px; height: 32px; }</style>
                <input id="search" type="text">
                <form id="login">
                  <input id="login-user" autocomplete="username">
                  <input id="login-password" type="password" autocomplete="current-password">
                </form>
                """,
            receive: { message in
                if let body = message.body as? [String: Any], body["event"] as? String == "focus" {
                    focusMessages.append(body)
                }
            })

        let raisedForUsername = try await focusForTesting("#login-user", in: webView)
        let raisedForSearch = try await focusForTesting("#search", in: webView)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(raisedForUsername)
        XCTAssertFalse(raisedForSearch)
        XCTAssertEqual(focusMessages.count, 1)
        XCTAssertEqual(focusMessages.first?["passwordKind"] as? String, "current")
        XCTAssertNotNil(focusMessages.first?["fieldRect"])
    }

    func testEmailFirstSignInRaisesThePromptAndFillsOnlyTheAccount() async throws {
        var focusMessages: [[String: Any]] = []
        let webView = try await credentialBridgeWebView(
            html: """
                <!doctype html>
                <style>input { display: block; width: 220px; height: 32px; }</style>
                <form id="newsletter"><input id="newsletter-email" type="email" name="newsletter"></form>
                <form id="identifier"><input id="account" type="email" autocomplete="username"></form>
                """,
            receive: { message in
                if let body = message.body as? [String: Any], body["event"] as? String == "focus" {
                    focusMessages.append(body)
                }
            })

        let raisedForNewsletter = try await focusForTesting("#newsletter-email", in: webView)
        let raisedForAccount = try await focusForTesting("#account", in: webView)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(raisedForNewsletter)
        XCTAssertTrue(raisedForAccount)
        XCTAssertEqual(focusMessages.count, 1)
        let formID = try XCTUnwrap(focusMessages.first?["formID"] as? String)
        let didFill = try await fill(formID: formID, username: "person@example.com", password: "unused", in: webView)
        XCTAssertTrue(didFill)
        let pageValues = try await pageJSON(
            "return JSON.stringify({ account: document.querySelector('#account').value });", in: webView)
        XCTAssertEqual(pageValues["account"] as? String, "person@example.com")
    }

    private func focusForTesting(_ selector: String, in webView: WKWebView) async throws -> Bool {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__crestCredentialBridge?.focusForTesting(selector) === true;",
            arguments: ["selector": selector],
            in: nil,
            contentWorld: BrowserCredentialContentBridge.contentWorld
        )
        return try XCTUnwrap(value as? Bool)
    }

    private func credentialBridgeWebView(
        html: String,
        receive: @escaping @MainActor (WKScriptMessage) -> Void = { _ in }
    ) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        _ = BrowserCredentialContentBridge.install(
            in: configuration.userContentController,
            receive: receive
        )
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let waiter = CredentialBridgeNavigationWaiter(webView: webView)
        try await waiter.load(
            simulatedRequest: URLRequest(url: URL(string: "https://forms.crest.test/")!),
            responseHTML: html
        )
        return webView
    }

    private func inspect(_ selector: String, in webView: WKWebView) async throws -> [String: Any]? {
        let value = try await webView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.__crestCredentialBridge?.inspectForTesting(selector) ?? null);",
            arguments: ["selector": selector],
            in: nil,
            contentWorld: BrowserCredentialContentBridge.contentWorld
        )
        let json = try XCTUnwrap(value as? String)
        if json == "null" { return nil }
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fill(
        formID: String,
        username: String,
        password: String,
        in webView: WKWebView
    ) async throws -> Bool {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__crestCredentialBridge?.fill(formID, username, password) === true;",
            arguments: [
                "formID": formID,
                "username": username,
                "password": password,
            ],
            in: nil,
            contentWorld: BrowserCredentialContentBridge.contentWorld
        )
        return try XCTUnwrap(value as? Bool)
    }

    private func pageJSON(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let json = try XCTUnwrap(value as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class CredentialBridgeNavigationWaiter: NSObject, WKNavigationDelegate {
    private weak var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, any Error>?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load(simulatedRequest request: URLRequest, responseHTML: String) async throws {
        guard let webView else { throw CredentialBridgeNavigationWaiterError.releasedWebView }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadSimulatedRequest(request, responseHTML: responseHTML)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum CredentialBridgeNavigationWaiterError: Error {
    case releasedWebView
}
