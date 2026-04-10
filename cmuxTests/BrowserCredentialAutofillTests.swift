import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - KeychainCredential Model Tests

final class KeychainCredentialTests: XCTestCase {
    func testCredentialEquality() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let b = KeychainCredential(username: "user1", password: "pass2", server: "example.com", label: "label")
        // Equality is based on username + server, not password or label.
        XCTAssertEqual(a, b)
    }

    func testCredentialInequality() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let c = KeychainCredential(username: "user2", password: "pass1", server: "example.com", label: nil)
        XCTAssertNotEqual(a, c)
    }

    func testCredentialInequalityByServer() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let d = KeychainCredential(username: "user1", password: "pass1", server: "other.com", label: nil)
        XCTAssertNotEqual(a, d)
    }

    func testCredentialHashConsistency() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let b = KeychainCredential(username: "user1", password: "pass2", server: "example.com", label: "label")
        // Equal credentials must have equal hash values.
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testCredentialSetDeduplication() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let b = KeychainCredential(username: "user1", password: "pass2", server: "example.com", label: "label")
        let set: Set<KeychainCredential> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    func testCredentialUniqueIDs() {
        let a = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        let b = KeychainCredential(username: "user1", password: "pass1", server: "example.com", label: nil)
        // Even equal credentials get unique IDs for list rendering.
        XCTAssertNotEqual(a.id, b.id)
    }
}

// MARK: - CredentialDetectorMessage Parsing Tests

final class CredentialDetectorMessageTests: XCTestCase {
    func testParseLoginFormDetected() {
        let body: [String: Any] = [
            "type": "loginFormDetected",
            "domain": "github.com",
            "url": "https://github.com/login"
        ]
        let msg = CredentialDetectorMessage(body: body)
        switch msg {
        case .loginFormDetected(let domain, let url):
            XCTAssertEqual(domain, "github.com")
            XCTAssertEqual(url, "https://github.com/login")
        default:
            XCTFail("Expected loginFormDetected, got \(String(describing: msg))")
        }
    }

    func testParseNoLoginForm() {
        let body: [String: Any] = [
            "type": "noLoginForm",
            "domain": "google.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        switch msg {
        case .noLoginForm(let domain):
            XCTAssertEqual(domain, "google.com")
        default:
            XCTFail("Expected noLoginForm, got \(String(describing: msg))")
        }
    }

    func testParseCredentialCaptured() {
        let body: [String: Any] = [
            "type": "credentialCaptured",
            "username": "testuser",
            "password": "secret123",
            "domain": "example.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        switch msg {
        case .credentialCaptured(let username, let password, let domain):
            XCTAssertEqual(username, "testuser")
            XCTAssertEqual(password, "secret123")
            XCTAssertEqual(domain, "example.com")
        default:
            XCTFail("Expected credentialCaptured, got \(String(describing: msg))")
        }
    }

    func testParseUnknownType() {
        let body: [String: Any] = [
            "type": "unknownMessage",
            "domain": "test.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }

    func testParseMissingType() {
        let body: [String: Any] = [
            "domain": "test.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }

    func testParseLoginFormDetectedMissingDomain() {
        let body: [String: Any] = [
            "type": "loginFormDetected",
            "url": "https://test.com/login"
        ]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }

    func testParseLoginFormDetectedMissingURL() {
        let body: [String: Any] = [
            "type": "loginFormDetected",
            "domain": "test.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }

    func testParseCredentialCapturedMissingPassword() {
        let body: [String: Any] = [
            "type": "credentialCaptured",
            "username": "user",
            "domain": "test.com"
        ]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }

    func testParseEmptyBody() {
        let body: [String: Any] = [:]
        let msg = CredentialDetectorMessage(body: body)
        XCTAssertNil(msg)
    }
}

// MARK: - Credential Detector Script Content Tests

final class CredentialDetectorScriptTests: XCTestCase {
    func testScriptContainsFillFunction() {
        XCTAssertTrue(
            credentialDetectorScript.contains("__cmuxFillCredential"),
            "Script must define the __cmuxFillCredential fill function"
        )
    }

    func testScriptContainsCaptureFunction() {
        XCTAssertTrue(
            credentialDetectorScript.contains("__cmuxCaptureCredentialOnSubmit"),
            "Script must define the __cmuxCaptureCredentialOnSubmit capture function"
        )
    }

    func testScriptContainsFormSubmitListener() {
        XCTAssertTrue(
            credentialDetectorScript.contains("addEventListener('submit'"),
            "Script must listen for form submit events"
        )
    }

    func testScriptContainsMutationObserver() {
        XCTAssertTrue(
            credentialDetectorScript.contains("MutationObserver"),
            "Script must use MutationObserver for SPA form detection"
        )
    }

    func testScriptContainsReactValueSetter() {
        XCTAssertTrue(
            credentialDetectorScript.contains("HTMLInputElement.prototype"),
            "Script must use native HTMLInputElement setter for React compatibility"
        )
    }

    func testScriptContainsInputEventDispatch() {
        XCTAssertTrue(
            credentialDetectorScript.contains("dispatchEvent(new Event('input'"),
            "Script must dispatch input events after filling for framework reactivity"
        )
    }

    func testScriptIsIdempotent() {
        XCTAssertTrue(
            credentialDetectorScript.contains("__cmuxCredentialDetectorInstalled"),
            "Script must guard against double-injection"
        )
    }

    func testScriptContainsMessageHandlerName() {
        XCTAssertTrue(
            credentialDetectorScript.contains("cmuxCredentialDetector"),
            "Script must reference the correct message handler name"
        )
    }

    func testScriptDetectsPasswordFields() {
        XCTAssertTrue(
            credentialDetectorScript.contains("input[type=\"password\"]"),
            "Script must query for password input fields"
        )
    }

    func testScriptHandlesPopstate() {
        XCTAssertTrue(
            credentialDetectorScript.contains("popstate"),
            "Script must re-scan on SPA popstate navigation"
        )
    }
}

// MARK: - KeychainCredentialStore Tests

final class KeychainCredentialStoreTests: XCTestCase {
    // These tests exercise the actual Keychain API against a test-specific domain.
    // SecItemAdd may fail in unsigned test runners (CI, detached codesign environments),
    // so tests that require write access skip gracefully when Keychain writes are unavailable.
    private let testServer = "cmux-unit-test-\(ProcessInfo.processInfo.processIdentifier).local"
    private let testUsername = "cmux-test-user"
    private let testPassword = "cmux-test-password-\(UUID().uuidString)"

    private var keychainWriteAvailable: Bool {
        // Probe whether the Keychain allows writes AND reads by attempting a round-trip.
        // In unsigned test runners, SecItemAdd may succeed but SecItemCopyMatching
        // returns no results due to missing codesign/entitlements.
        let probeServer = "cmux-keychain-probe-\(ProcessInfo.processInfo.processIdentifier).local"
        let probePassword = UUID().uuidString
        let saved = KeychainCredentialStore.save(
            username: "probe", password: probePassword, server: probeServer
        )
        guard saved else { return false }
        let retrieved = KeychainCredentialStore.credentials(for: probeServer)
        // Clean up regardless.
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: probeServer,
        ]
        SecItemDelete(query as CFDictionary)
        return retrieved.contains(where: { $0.password == probePassword })
    }

    override func tearDown() {
        super.tearDown()
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: testServer,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func testQueryForNonExistentServer() {
        let creds = KeychainCredentialStore.credentials(for: testServer)
        XCTAssertTrue(creds.isEmpty, "No credentials should exist for the test server")
    }

    func testSaveAndRetrieveCredential() throws {
        try XCTSkipUnless(keychainWriteAvailable, "Keychain writes unavailable in this environment")

        let saved = KeychainCredentialStore.save(
            username: testUsername,
            password: testPassword,
            server: testServer
        )
        XCTAssertTrue(saved, "Saving a credential should succeed")

        let creds = KeychainCredentialStore.credentials(for: testServer)
        XCTAssertEqual(creds.count, 1)
        XCTAssertEqual(creds.first?.username, testUsername)
        XCTAssertEqual(creds.first?.password, testPassword)
        XCTAssertEqual(creds.first?.server, testServer)
    }

    func testSaveUpdatesExistingCredential() throws {
        try XCTSkipUnless(keychainWriteAvailable, "Keychain writes unavailable in this environment")

        let saved1 = KeychainCredentialStore.save(
            username: testUsername,
            password: "old-password",
            server: testServer
        )
        XCTAssertTrue(saved1)

        let updatedPassword = "new-password-\(UUID().uuidString)"
        let saved2 = KeychainCredentialStore.save(
            username: testUsername,
            password: updatedPassword,
            server: testServer
        )
        XCTAssertTrue(saved2)

        let creds = KeychainCredentialStore.credentials(for: testServer)
        XCTAssertEqual(creds.count, 1, "Should still be one credential after update")
        XCTAssertEqual(creds.first?.password, updatedPassword)
    }

    func testSaveMultipleUsersForSameServer() throws {
        try XCTSkipUnless(keychainWriteAvailable, "Keychain writes unavailable in this environment")

        let saved1 = KeychainCredentialStore.save(
            username: "user-a",
            password: "pass-a",
            server: testServer
        )
        let saved2 = KeychainCredentialStore.save(
            username: "user-b",
            password: "pass-b",
            server: testServer
        )
        XCTAssertTrue(saved1)
        XCTAssertTrue(saved2)

        let creds = KeychainCredentialStore.credentials(for: testServer)
        XCTAssertEqual(creds.count, 2)
        let usernames = Set(creds.map(\.username))
        XCTAssertTrue(usernames.contains("user-a"))
        XCTAssertTrue(usernames.contains("user-b"))
    }
}
