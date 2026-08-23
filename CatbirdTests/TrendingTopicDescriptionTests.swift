import XCTest
import Petrel
@testable import Catbird

final class TrendingTopicDescriptionTests: XCTestCase {
  func testDescriptionCollapsesWhitespaceAndRemovesMarkup() {
    let topic = makeTopic(description: "  <b>Swift  6.2</b>\nadds concurrency tools.  ")

    XCTAssertEqual(
      TrendingTopicPresentation.description(for: topic),
      "Swift 6.2 adds concurrency tools."
    )
  }

  func testMissingDescriptionDoesNotInventSummary() {
    let topic = makeTopic(description: nil)

    XCTAssertNil(TrendingTopicPresentation.description(for: topic))
  }

  func testMutedTextChecksDescriptionAndMetadata() {
    let topic = makeTopic(description: "A championship final is underway.")

    XCTAssertTrue(
      TrendingTopicPresentation.matchesMutedText("championship", topic: topic)
    )
    XCTAssertFalse(
      TrendingTopicPresentation.matchesMutedText("foundation models", topic: topic)
    )
  }

  private func makeTopic(description: String?) -> AppBskyUnspeccedDefs.TrendView {
    AppBskyUnspeccedDefs.TrendView(
      topic: "swift",
      displayName: "Swift News",
      description: description,
      link: "/profile/trending.bsky.app/feed/swift",
      startedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000)),
      postCount: 42,
      status: "hot",
      category: "technology",
      actors: []
    )
  }
}
