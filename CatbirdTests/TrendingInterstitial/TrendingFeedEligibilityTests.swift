import Foundation
@testable import Petrel
import Testing
@testable import Catbird

@Suite("Trending feed eligibility")
struct TrendingFeedEligibilityTests {
  private let discoverURI =
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot"
  private let otherFeedURI =
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/with-friends"
  private let listURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.graph.list/3kabc123"

  private func feed(_ uri: String) throws -> FetchType {
    .feed(try ATProtocolURI(uriString: uri))
  }

  @Test("With no pins the timeline carries the card")
  func noPinsMeansTimeline() throws {
    #expect(TrendingFeedEligibility.isEligible(feed: .timeline, pinnedFeeds: []))
    #expect(!TrendingFeedEligibility.isEligible(feed: try feed(discoverURI), pinnedFeeds: []))
  }

  @Test("A first pin of Following keeps the card on the timeline")
  func followingPinMeansTimeline() throws {
    let pins = [SystemFeedTypes.following, discoverURI]
    #expect(TrendingFeedEligibility.isEligible(feed: .timeline, pinnedFeeds: pins))
    #expect(!TrendingFeedEligibility.isEligible(feed: try feed(discoverURI), pinnedFeeds: pins))
  }

  @Test("A first pinned custom feed carries the card and the timeline does not")
  func firstPinnedFeedIsEligible() throws {
    let pins = [discoverURI, SystemFeedTypes.following]
    #expect(TrendingFeedEligibility.isEligible(feed: try feed(discoverURI), pinnedFeeds: pins))
    #expect(!TrendingFeedEligibility.isEligible(feed: .timeline, pinnedFeeds: pins))
  }

  @Test("A pinned feed that is not first never carries the card")
  func laterPinIsNotEligible() throws {
    let pins = [discoverURI, otherFeedURI]
    #expect(!TrendingFeedEligibility.isEligible(feed: try feed(otherFeedURI), pinnedFeeds: pins))
  }

  @Test("A first pinned list carries the card")
  func firstPinnedListIsEligible() throws {
    let uri = try ATProtocolURI(uriString: listURI)
    #expect(TrendingFeedEligibility.isEligible(feed: .list(uri), pinnedFeeds: [listURI]))
    #expect(!TrendingFeedEligibility.isEligible(feed: .timeline, pinnedFeeds: [listURI]))
  }

  @Test("Author and likes feeds never carry the card")
  func authorAndLikesAreNeverEligible() {
    let did = "did:plc:z72i7hdynmk6r22z27h6tvur"
    #expect(!TrendingFeedEligibility.isEligible(feed: .author(did), pinnedFeeds: []))
    #expect(!TrendingFeedEligibility.isEligible(feed: .likes(did), pinnedFeeds: []))
  }
}
