import XCTest
@testable import Catbird
import Petrel

@MainActor
final class LiveStatusValidationTests: XCTestCase {

    // MARK: - Host Sanitization

    func testHostSanitization() {
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("nba.smart.link"), "nba.smart.link")
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("www.twitch.tv"), "twitch.tv")
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("m.youtube.com"), "youtube.com")
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("live.stream.place"), "stream.place")
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("stream.place"), "stream.place")
        XCTAssertEqual(LiveStatusManager.sanitizeLiveHost("watch.bluecast.app"), "bluecast.app")
    }

    // MARK: - Stream URL Validation

    func testAllowedHostsValidation() {
        let validURLs = [
            "https://twitch.tv/streamer",
            "https://www.twitch.tv/streamer",
            "https://youtube.com/watch?v=123",
            "https://m.youtube.com/live/123",
            "https://stream.place/live/user",
            "https://bluecast.app/stream",
            "https://substack.com/live/author",
            "https://beehiiv.com/posts/live",
            "https://skylight.social/live",
            "https://nba.smart.link/watch",
            "https://espn.com/watch/live"
        ]

        for urlString in validURLs {
            let result = LiveStatusManager.validateStreamURL(urlString)
            XCTAssertTrue(result.isValid, "Expected valid for \(urlString), got error: \(result.error ?? "none")")
            XCTAssertNotNil(result.apexDomain)
        }
    }

    func testDisallowedHostsAndSchemes() {
        // Non-HTTPS
        let httpResult = LiveStatusManager.validateStreamURL("http://twitch.tv/streamer")
        XCTAssertFalse(httpResult.isValid)
        XCTAssertEqual(httpResult.error, "Only HTTPS stream links are allowed")

        // Disallowed domain
        let disallowedResult = LiveStatusManager.validateStreamURL("https://example.com/stream")
        XCTAssertFalse(disallowedResult.isValid)

        // Malformed URL
        let malformedResult = LiveStatusManager.validateStreamURL("not a valid url")
        XCTAssertFalse(malformedResult.isValid)
    }

    // MARK: - Duration Display

    func testDurationDisplay() {
        XCTAssertEqual(LiveStatusManager.displayDuration(minutes: 30), "30 minutes")
        XCTAssertEqual(LiveStatusManager.displayDuration(minutes: 60), "1 hour")
        XCTAssertEqual(LiveStatusManager.displayDuration(minutes: 120), "2 hours")
        XCTAssertEqual(LiveStatusManager.displayDuration(minutes: 90), "1h 30m")
        XCTAssertEqual(LiveStatusManager.displayDuration(minutes: 240), "4 hours")
    }
}
