import XCTest
@testable import Catbird

final class ExternalURLIntentTests: XCTestCase {

    // MARK: - Compose Intent

    func testComposeIntentParsing() {
        let cases = [
            "bluesky://intent/compose?text=Hello%20Catbird",
            "https://bsky.app/intent/compose?text=Hello%20Catbird"
        ]

        for urlString in cases {
            let url = URL(string: urlString)!
            let intent = ExternalURLIntent.parse(from: url)
            XCTAssertEqual(intent, .compose(text: "Hello Catbird"))
        }
    }

    func testComposeIntentIgnoresRemoteMedia() {
        // Spec acceptance: Remote http/https image or video values embedded in compose intent parameters are never fetched.
        let url = URL(string: "https://bsky.app/intent/compose?text=Check%20this&imageUris=https://example.com/pic.jpg&videoUri=https://example.com/vid.mp4")!
        let intent = ExternalURLIntent.parse(from: url)
        XCTAssertEqual(intent, .compose(text: "Check this"))
    }

    // MARK: - Verify Email Intent

    func testVerifyEmailIntentParsing() {
        let cases = [
            "bluesky://intent/verify-email?code=abc-123-xyz",
            "https://bsky.app/intent/verify-email?code=abc-123-xyz"
        ]

        for urlString in cases {
            let url = URL(string: urlString)!
            let intent = ExternalURLIntent.parse(from: url)
            XCTAssertEqual(intent, .verifyEmail(code: "abc-123-xyz"))
        }

        // Missing code returns nil
        let missingCode = URL(string: "https://bsky.app/intent/verify-email")!
        XCTAssertNil(ExternalURLIntent.parse(from: missingCode))
    }

    // MARK: - Group Chat Join Intent

    func testGroupChatJoinIntentParsing() {
        let cases = [
            ("bluesky://chat/3kxyz78", "3kxyz78"),
            ("https://bsky.app/chat/3kxyz78", "3kxyz78"),
            ("bluesky://messages/join/3kxyz78", "3kxyz78"),
            ("https://bsky.app/messages/join/3kxyz78", "3kxyz78"),
            ("https://bsky.app/chat/1234567890", "1234567890") // 10 chars
        ]

        for (urlString, expectedCode) in cases {
            let url = URL(string: urlString)!
            let intent = ExternalURLIntent.parse(from: url)
            XCTAssertEqual(intent, .groupChatJoin(code: expectedCode), "Failed for \(urlString)")
        }
    }

    func testGroupChatCodeValidation() {
        XCTAssertTrue(ExternalURLIntent.isValidChatInviteCode("1234567")) // 7 chars
        XCTAssertTrue(ExternalURLIntent.isValidChatInviteCode("1234567890")) // 10 chars
        XCTAssertTrue(ExternalURLIntent.isValidChatInviteCode("AbCdEfG"))

        XCTAssertFalse(ExternalURLIntent.isValidChatInviteCode("123456")) // 6 chars (too short)
        XCTAssertFalse(ExternalURLIntent.isValidChatInviteCode("12345678901")) // 11 chars (too long)
        XCTAssertFalse(ExternalURLIntent.isValidChatInviteCode("1234-567")) // Non-alphanumeric
        XCTAssertFalse(ExternalURLIntent.isValidChatInviteCode("1234 567")) // Whitespace
    }

    // MARK: - Age Assurance Intent Ignored

    func testAgeAssuranceIntentIsIgnored() {
        let url = URL(string: "bluesky://intent/age-assurance?state=xyz&code=123")!
        let intent = ExternalURLIntent.parse(from: url)
        XCTAssertNil(intent, "Age-assurance intents must be ignored and not parsed as valid external intents")

        let httpsURL = URL(string: "https://bsky.app/intent/age-assurance?state=xyz&code=123")!
        let httpsIntent = ExternalURLIntent.parse(from: httpsURL)
        XCTAssertNil(httpsIntent, "HTTPS age-assurance intents must also be ignored")
    }

    // MARK: - Presenter Duplicate Suppression & Pending Auth Retention

    @MainActor
    func testPresenterDuplicateSuppression() {
        let presenter = ExternalURLIntentPresenter()
        let url = URL(string: "bluesky://intent/compose?text=Hello")!
        let intent = ExternalURLIntent.parse(from: url)!

        // First delivery sets active/pending
        presenter.handleIntent(intent, from: url, appState: nil)
        XCTAssertEqual(presenter.pendingIntent, intent)
        XCTAssertEqual(presenter.lastDeliveredURL, url.absoluteString)

        // Second delivery of identical URL is ignored
        presenter.pendingIntent = nil
        presenter.handleIntent(intent, from: url, appState: nil)
        XCTAssertNil(presenter.pendingIntent, "Duplicate delivery should be suppressed")
    }

    // MARK: - Security & Disambiguation (WS-G-11 & WS-G-12)

    func testUntrustedOriginsRejected() {
        let untrustedURLs = [
            "https://evil.example/intent/compose?text=spam",
            "https://evil.example/chat/3kxyz78",
            "https://evil.example/intent/verify-email?code=1234567",
            "https://evil.example/messages/join/3kxyz78",
            "http://attacker.com/intent/compose?text=hello",
            "http://bsky.app/intent/compose?text=hello",
            "http://bsky.app/chat/3kxyz78",
            "custom://intent/compose?text=hello",
            "https://notbsky.app/chat/3kxyz78",
            "file:///intent/compose?text=hello"
        ]

        for urlString in untrustedURLs {
            let url = URL(string: urlString)!
            XCTAssertNil(ExternalURLIntent.parse(from: url), "Untrusted origin should be rejected: \(urlString)")
        }
    }

    func testMessagesRoutesNotHijackedAsChatInvites() {
        // Two-segment /messages/{path} routes should not be parsed as chat invites
        let nonInviteCases = [
            "https://bsky.app/messages/settings",
            "https://bsky.app/messages/inbox",
            "bluesky://messages/settings",
            "bluesky://messages/inbox",
            "https://bsky.app/messages/conversation"
        ]

        for urlString in nonInviteCases {
            let url = URL(string: urlString)!
            XCTAssertNil(ExternalURLIntent.parse(from: url), "Route should not be hijacked: \(urlString)")
        }

        // Three-segment /messages/join/{code} and two-segment /chat/{code} should work
        let validInviteCases = [
            ("https://bsky.app/messages/join/3kxyz78", "3kxyz78"),
            ("bluesky://messages/join/3kxyz78", "3kxyz78"),
            ("https://bsky.app/chat/3kxyz78", "3kxyz78"),
            ("bluesky://chat/3kxyz78", "3kxyz78")
        ]

        for (urlString, expectedCode) in validInviteCases {
            let url = URL(string: urlString)!
            XCTAssertEqual(ExternalURLIntent.parse(from: url), .groupChatJoin(code: expectedCode))
        }
    }
}
