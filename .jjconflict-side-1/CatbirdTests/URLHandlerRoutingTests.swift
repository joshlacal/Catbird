import XCTest
@testable import Catbird
import Petrel

final class URLHandlerRoutingTests: XCTestCase {
    var urlHandler: URLHandler!

    @MainActor
    private func makeAppState(userDID: String = "did:plc:testuser1234567890ab") async -> AppState {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        return AppState(userDID: userDID, client: client)
    }

    @MainActor
    override func setUp() {
        super.setUp()
        urlHandler = URLHandler()
    }

    override func tearDown() {
        urlHandler = nil
        super.tearDown()
    }

    // MARK: - Starter Pack Routes

    @MainActor
    func testStarterPackLongRoutes() async throws {
        let cases = [
            "https://bsky.app/start/did:plc:123/3kxyz",
            "https://bsky.app/starter-pack/did:plc:123/3kxyz",
            "bluesky://start/did:plc:123/3kxyz",
            "bluesky://starter-pack/did:plc:123/3kxyz",
            "https://bsky.app/profile/did:plc:123/starter-pack/3kxyz",
            "bluesky://profile/did:plc:123/starter-pack/3kxyz"
        ]

        let expectedURI = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.graph.starterpack/3kxyz")

        for urlString in cases {
            let dest = await urlHandler.parseDestination(from: urlString)
            XCTAssertEqual(dest, .starterPack(expectedURI), "Failed for \(urlString)")
        }
    }

    @MainActor
    func testStarterPackShortRoute() async {
        let cases = [
            "https://bsky.app/starter-pack-short/3kxyz",
            "bluesky://starter-pack-short/3kxyz"
        ]

        for urlString in cases {
            let dest = await urlHandler.parseDestination(from: urlString)
            XCTAssertEqual(dest, .starterPackShort("3kxyz"), "Failed for \(urlString)")
        }
    }

    // MARK: - Notifications Activity Batch

    @MainActor
    func testNotificationActivityBatchRoute() async throws {
        let uri1 = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.feed.post/1")
        let uri2 = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.feed.post/2")

        let validURL = "https://bsky.app/notifications/activity?posts=\(uri1.uriString()),\(uri2.uriString())"
        let dest = await urlHandler.parseDestination(from: validURL)
        XCTAssertEqual(dest, .notificationActivity([uri1, uri2]))

        // Malformed URI in list is filtered out
        let partialURL = "bluesky://notifications/activity?posts=\(uri1.uriString()),not-a-valid-at-uri,\(uri2.uriString())"
        let partialDest = await urlHandler.parseDestination(from: partialURL)
        XCTAssertEqual(partialDest, .notificationActivity([uri1, uri2]))

        // Non-post collection URIs are filtered out
        let nonPostURL = "https://bsky.app/notifications/activity?posts=\(uri1.uriString()),at://did:plc:123/app.bsky.graph.starterpack/abc,\(uri2.uriString())"
        let nonPostDest = await urlHandler.parseDestination(from: nonPostURL)
        XCTAssertEqual(nonPostDest, .notificationActivity([uri1, uri2]))

        // Duplicate URIs are deduplicated in order
        let duplicateURL = "https://bsky.app/notifications/activity?posts=\(uri1.uriString()),\(uri2.uriString()),\(uri1.uriString())"
        let duplicateDest = await urlHandler.parseDestination(from: duplicateURL)
        XCTAssertEqual(duplicateDest, .notificationActivity([uri1, uri2]))

        // Batches with > 25 URIs are capped at 25 in order
        var manyURIs: [ATProtocolURI] = []
        var manyURIStrings: [String] = []
        for i in 1...30 {
            let uri = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.feed.post/\(i)")
            if i <= 25 {
                manyURIs.append(uri)
            }
            manyURIStrings.append(uri.uriString())
        }
        let cappedURL = "https://bsky.app/notifications/activity?posts=" + manyURIStrings.joined(separator: ",")
        let cappedDest = await urlHandler.parseDestination(from: cappedURL)
        XCTAssertEqual(cappedDest, .notificationActivity(manyURIs))

        // All invalid returns nil (does not fall back to activitySubscriptions)
        let invalidURL = "https://bsky.app/notifications/activity?posts=invalid1,invalid2"
        let invalidDest = await urlHandler.parseDestination(from: invalidURL)
        XCTAssertNil(invalidDest)

        // Empty posts parameter returns nil
        let emptyURL = "https://bsky.app/notifications/activity?posts="
        let emptyDest = await urlHandler.parseDestination(from: emptyURL)
        XCTAssertNil(emptyDest)

        // Delivery-level assertions with navigateAction
        var capturedDestination: NavigationDestination?
        urlHandler.navigateAction = { destination, _ in
            capturedDestination = destination
        }

        capturedDestination = nil
        let handledValid = await urlHandler.handleURL(URL(string: validURL)!)
        XCTAssertTrue(handledValid)
        XCTAssertEqual(capturedDestination, .notificationActivity([uri1, uri2]))

        // Invalid delivery assertion - should not navigate
        capturedDestination = nil
        urlHandler.useInAppBrowser = false
        let handledInvalid = await urlHandler.handleURL(URL(string: invalidURL)!)
        XCTAssertFalse(handledInvalid)
        XCTAssertNil(capturedDestination, "Invalid notifications activity URL should not navigate")
    }

    @MainActor
    func testConfigureAssignsAppState() async {
        let appState = await makeAppState()
        urlHandler.configure(with: appState)

        var capturedDestination: NavigationDestination?
        urlHandler.navigateAction = { destination, _ in
            capturedDestination = destination
        }

        // With appState configured, handleURL can use appState context
        let result = await urlHandler.handleURL(URL(string: "https://bsky.app/video-feed")!)
        XCTAssertTrue(result)
        XCTAssertEqual(capturedDestination, .videoFeed)
    }

    // MARK: - Video Feed Route

    @MainActor
    func testVideoFeedRoute() async {
        let cases = [
            "https://bsky.app/video-feed",
            "bluesky://video-feed"
        ]

        for urlString in cases {
            let dest = await urlHandler.parseDestination(from: urlString)
            XCTAssertEqual(dest, .videoFeed, "Failed for \(urlString)")
        }

        // Delivery-level assertion with navigateAction
        var capturedDestination: NavigationDestination?
        urlHandler.navigateAction = { destination, _ in
            capturedDestination = destination
        }

        for urlString in cases {
            capturedDestination = nil
            let handled = await urlHandler.handleURL(URL(string: urlString)!)
            XCTAssertTrue(handled, "Failed to handle \(urlString)")
            XCTAssertEqual(capturedDestination, .videoFeed, "Failed delivery for \(urlString)")
        }
    }
    // MARK: - Settings Subpaths

    @MainActor
    func testSettingsRoutes() async {
        let expectations: [(String, SettingsRoute)] = [
            ("https://bsky.app/settings/language", .language),
            ("bluesky://settings/language", .language),
            ("https://bsky.app/settings/accessibility", .accessibility),
            ("bluesky://settings/accessibility", .accessibility),
            ("https://bsky.app/settings/appearance", .appearance),
            ("bluesky://settings/appearance", .appearance),
            ("https://bsky.app/settings/account", .account),
            ("bluesky://settings/account", .account),
            ("https://bsky.app/settings/privacy-and-security", .privacyAndSecurity),
            ("bluesky://settings/privacy-and-security", .privacyAndSecurity),
            ("https://bsky.app/settings/content-and-media", .contentAndMedia),
            ("bluesky://settings/content-and-media", .contentAndMedia),
            ("https://bsky.app/settings/about", .about),
            ("bluesky://settings/about", .about),
            ("https://bsky.app/settings/notifications", .notifications),
            ("bluesky://settings/notifications", .notifications),
            ("https://bsky.app/settings/moderation", .moderation),
            ("bluesky://settings/moderation", .moderation),
            ("https://bsky.app/settings/following-feed", .followingFeed),
            ("bluesky://settings/saved-feeds", .savedFeeds),
            ("https://bsky.app/settings/app-passwords", .appPasswords),
            ("bluesky://settings/interests", .interests),
            ("https://bsky.app/settings/app-icon", .appIcon)
        ]

        for (urlString, expectedRoute) in expectations {
            let dest = await urlHandler.parseDestination(from: urlString)
            XCTAssertEqual(dest, .settings(expectedRoute), "Failed for \(urlString)")
        }
    }

    // MARK: - Percent Encoding & Entities

    @MainActor
    func testPercentEncodingAndEntityRoutes() async throws {
        // Hashtag
        let tagURL = "https://bsky.app/hashtag/Swift%206"
        let tagDest = await urlHandler.parseDestination(from: tagURL)
        XCTAssertEqual(tagDest, .hashtag("Swift 6"))

        // Topic
        let topicURL = "bluesky://topic/Art%20Design"
        let topicDest = await urlHandler.parseDestination(from: topicURL)
        XCTAssertEqual(topicDest, .topic("Art Design"))

        // Post
        let postURL = "https://bsky.app/profile/did:plc:123/post/3kxyz"
        let postDest = await urlHandler.parseDestination(from: postURL)
        let postURI = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.feed.post/3kxyz")
        XCTAssertEqual(postDest, .post(postURI))

        // Feed
        let feedURL = "https://bsky.app/profile/did:plc:123/feed/whats-hot"
        let feedDest = await urlHandler.parseDestination(from: feedURL)
        let feedURI = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.feed.generator/whats-hot")
        XCTAssertEqual(feedDest, .feed(feedURI))

        // List
        let listURL = "https://bsky.app/profile/did:plc:123/lists/my-list"
        let listDest = await urlHandler.parseDestination(from: listURL)
        let listURI = try ATProtocolURI(uriString: "at://did:plc:123/app.bsky.graph.list/my-list")
        XCTAssertEqual(listDest, .list(listURI))

        // Bookmarks / Saved
        let savedURL = "https://bsky.app/saved"
        let savedDest = await urlHandler.parseDestination(from: savedURL)
        XCTAssertEqual(savedDest, .bookmarks)
    }

    // MARK: - OAuth Callback Matching

    @MainActor
    func testOAuthCallbackMatching() async {
        let appState = await makeAppState()
        urlHandler.configure(with: appState)
        urlHandler.useInAppBrowser = false

        var capturedDestination: NavigationDestination?
        urlHandler.navigateAction = { destination, _ in
            capturedDestination = destination
        }

        // Legitimate callback URLs are handled as OAuth callbacks (not routed as navigation destinations)
        let validHTTPSCallback = URL(string: "https://catbird.blue/oauth/callback?code=abc1234567890123456789012345678901234567890123")!
        capturedDestination = nil
        let handledHTTPS = await urlHandler.handleURL(validHTTPSCallback)
        XCTAssertTrue(handledHTTPS, "Expected handleURL to return true for valid HTTPS OAuth callback")
        XCTAssertNil(capturedDestination, "OAuth callback should not trigger navigation")

        let validCustomSchemeCallback = URL(string: "catbird://oauth/callback?code=abc1234567890123456789012345678901234567890123")!
        capturedDestination = nil
        let handledCustom = await urlHandler.handleURL(validCustomSchemeCallback)
        XCTAssertTrue(handledCustom, "Expected handleURL to return true for valid custom scheme callback")
        XCTAssertNil(capturedDestination, "OAuth callback should not trigger navigation")

        let validBlueCatbirdCallback = URL(string: "blue.catbird://oauth/callback?code=abc1234567890123456789012345678901234567890123")!
        capturedDestination = nil
        let handledBlueCatbird = await urlHandler.handleURL(validBlueCatbirdCallback)
        XCTAssertTrue(handledBlueCatbird, "Expected handleURL to return true for valid blue.catbird callback")
        XCTAssertNil(capturedDestination, "OAuth callback should not trigger navigation")

        // Non-callback URLs containing /oauth/callback are not swallowed as OAuth callbacks
        let externalURL = URL(string: "https://example.com/oauth/callback/help")!
        capturedDestination = nil
        let handledExternal = await urlHandler.handleURL(externalURL)
        XCTAssertFalse(handledExternal, "Expected handleURL to return false for external URL when in-app browser is disabled")
        XCTAssertNil(capturedDestination, "External URL should not trigger navigation")
    }
}
