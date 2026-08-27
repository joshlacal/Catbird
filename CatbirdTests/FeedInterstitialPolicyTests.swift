import XCTest
@testable import Catbird
import Petrel

final class FeedInterstitialPolicyTests: XCTestCase {

    struct FeedInterstitialPolicy {
        static func shouldInsertInterstitial(
            at index: Int,
            postCount: Int,
            showTrendingTopics: Bool,
            showTrendingVideos: Bool,
            feedType: String
        ) -> Bool {
            guard feedType == "timeline" || feedType == "discover" else { return false }
            guard postCount >= 7 else { return false }
            guard index == 6 else { return false }
            return showTrendingTopics || showTrendingVideos
        }
    }

    func testInterstitialPlacementRule() {
        // Must be inserted at index 6 (after 6th post) on timeline/discover with at least 7 posts
        XCTAssertTrue(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 10,
            showTrendingTopics: true,
            showTrendingVideos: true,
            feedType: "timeline"
        ))

        XCTAssertTrue(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 7,
            showTrendingTopics: true,
            showTrendingVideos: false,
            feedType: "discover"
        ))

        // Index other than 6 should not insert
        XCTAssertFalse(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 5,
            postCount: 10,
            showTrendingTopics: true,
            showTrendingVideos: true,
            feedType: "timeline"
        ))

        // Post count < 7 should not insert
        XCTAssertFalse(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 6,
            showTrendingTopics: true,
            showTrendingVideos: true,
            feedType: "timeline"
        ))

        // Unsupported feed types (e.g. custom list or author feed) should not insert
        XCTAssertFalse(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 10,
            showTrendingTopics: true,
            showTrendingVideos: true,
            feedType: "author"
        ))
    }

    func testSettingsCombinationRule() {
        // Both disabled -> no interstitial
        XCTAssertFalse(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 10,
            showTrendingTopics: false,
            showTrendingVideos: false,
            feedType: "timeline"
        ))

        // Topics only -> true
        XCTAssertTrue(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 10,
            showTrendingTopics: true,
            showTrendingVideos: false,
            feedType: "timeline"
        ))

        // Videos only -> true
        XCTAssertTrue(FeedInterstitialPolicy.shouldInsertInterstitial(
            at: 6,
            postCount: 10,
            showTrendingTopics: false,
            showTrendingVideos: true,
            feedType: "timeline"
        ))
    }
}
