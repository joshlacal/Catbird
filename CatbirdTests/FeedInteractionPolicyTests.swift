//
//  FeedInteractionPolicyTests.swift
//  CatbirdTests
//

import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Feed interaction feedback policy")
struct FeedInteractionPolicyTests {
  private static let discoverURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot"
  private static let videoURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids"
  private static let thirdPartyURI = "at://did:plc:creator123/app.bsky.feed.generator/cats"

  private func feed(_ uri: String) throws -> FetchType {
    .feed(try ATProtocolURI(uriString: uri))
  }

  private func info(
    _ uri: String,
    did: String? = "did:web:feeds.example.com",
    accepts: Bool,
    fetchedAt: Date = Date()
  ) -> FeedGeneratorInteractionInfo {
    FeedGeneratorInteractionInfo(
      feedURI: uri, generatorDID: did, acceptsInteractions: accepts, fetchedAt: fetchedAt)
  }

  @Test("A third-party feed that accepts interactions gets a target")
  func acceptingThirdPartyFeed() throws {
    let target = FeedInteractionPolicy.target(
      for: try feed(Self.thirdPartyURI), info: info(Self.thirdPartyURI, accepts: true))
    #expect(target == FeedInteractionTarget(feedURI: Self.thirdPartyURI, generatorDID: "did:web:feeds.example.com"))
  }

  @Test("A third-party feed that does not accept interactions gets none")
  func nonAcceptingThirdPartyFeed() throws {
    #expect(FeedInteractionPolicy.target(
      for: try feed(Self.thirdPartyURI), info: info(Self.thirdPartyURI, accepts: false)) == nil)
  }

  @Test("Discover and Video accept feedback without declaring it", arguments: [discoverURI, videoURI])
  func blueskyFeedbackFeeds(uri: String) throws {
    let target = FeedInteractionPolicy.target(for: try feed(uri), info: info(uri, accepts: false))
    #expect(target?.feedURI == uri)
  }

  @Test("No target while generator info is loading or lacks a DID")
  func missingInfoOrDID() throws {
    #expect(FeedInteractionPolicy.target(for: try feed(Self.discoverURI), info: nil) == nil)
    #expect(FeedInteractionPolicy.target(
      for: try feed(Self.discoverURI), info: info(Self.discoverURI, did: nil, accepts: true)) == nil)
    #expect(FeedInteractionPolicy.target(
      for: try feed(Self.discoverURI), info: info(Self.discoverURI, did: "", accepts: true)) == nil)
  }

  @Test("Info for a different feed never enables the current one")
  func mismatchedFeedInfo() throws {
    #expect(FeedInteractionPolicy.target(
      for: try feed(Self.thirdPartyURI), info: info(Self.discoverURI, accepts: true)) == nil)
  }

  @Test("Timelines, lists, author and likes feeds never get a target")
  func nonCustomFeeds() throws {
    let accepting = info(Self.thirdPartyURI, accepts: true)
    let listURI = try ATProtocolURI(uriString: "at://did:plc:creator123/app.bsky.graph.list/abc")
    for fetchType: FetchType in [.timeline, .list(listURI), .author("did:plc:creator123"), .likes("did:plc:creator123")] {
      #expect(FeedInteractionPolicy.target(for: fetchType, info: accepting) == nil)
    }
  }

  @Test("Cached generator info expires after the TTL")
  @MainActor
  func cacheExpiresAfterTTL() {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let cache = FeedGeneratorInfoCache(now: { now })
    #expect(cache.info(for: Self.thirdPartyURI) == nil)

    let view = AppBskyFeedDefs.GeneratorView(
      uri: try! ATProtocolURI(uriString: Self.thirdPartyURI),
      cid: try! CID.parse("bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm"),
      did: try! DID(didString: "did:web:feeds.example.com"),
      creator: AppBskyActorDefs.ProfileView(
        did: try! DID(didString: "did:plc:creator123"),
        handle: try! Handle(handleString: "creator.example.com"),
        displayName: nil, pronouns: nil, description: nil, avatar: nil, associated: nil,
        indexedAt: nil, createdAt: nil, viewer: nil, labels: nil, verification: nil,
        status: nil, debug: nil),
      displayName: "Cats", description: nil, descriptionFacets: nil, avatar: nil,
      likeCount: nil, acceptsInteractions: true, labels: nil, viewer: nil,
      contentMode: nil, indexedAt: ATProtocolDate(date: now))
    let stored = cache.store(view)
    #expect(stored.acceptsInteractions)
    #expect(cache.info(for: Self.thirdPartyURI) == stored)

    now = now.addingTimeInterval(FeedGeneratorInfoCache.timeToLive - 1)
    #expect(cache.info(for: Self.thirdPartyURI) == stored)

    now = now.addingTimeInterval(2)
    #expect(cache.info(for: Self.thirdPartyURI) == nil)
  }
}
