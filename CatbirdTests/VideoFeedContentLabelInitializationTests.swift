import Foundation
import Petrel
import SwiftUI
import Testing
@testable import Catbird

// The video feed asks the moderation engine synchronously, so a record
// self-label covers the player on the first render. These replace the old
// `ContentLabelManager.getInitialContentVisibility` contract, which used a
// hardcoded label list and no account policy.

@MainActor
@Suite("Video content label initialization")
struct VideoFeedContentLabelInitializationTests {
  /// Adult content on, builtin defaults: `porn` hides, `sexual` and
  /// `graphic-media` warn, `nudity` is ignored.
  private let adultOnPolicy = ModerationPolicy(
    accountDID: "did:plc:viewer",
    serverAdultContentEnabled: true, contentLabelPrefs: [], labelerDIDs: [],
    labelerDefinitions: [:], isConfirmed: true)

  @Test("Record self-labels cover the player before any preference load", arguments: [
    ("porn", true, true),
    ("sexual", false, true),
    ("graphic-media", false, true),
    ("nudity", false, false),
    ("bot-account", false, false)
  ])
  func selfLabelsApplyImmediately(value: String, filtered: Bool, covered: Bool) throws {
    let item = try #require(VideoFeedItem(post: try videoPost(selfLabel: value)))
    let moderation = item.moderation(policy: adultOnPolicy)
    #expect(moderation.isFilteredFromList == filtered)
    #expect(moderation.concealsPlayback == covered)
  }

  @Test("Server and self labels keep the most restrictive cover")
  func mixedLabels() throws {
    let post = try videoPost(selfLabel: "porn", serverLabel: "graphic-media")
    let item = try #require(VideoFeedItem(post: post))
    let moderation = item.moderation(policy: adultOnPolicy)
    #expect(moderation.isFilteredFromList)
    #expect(moderation.concealsPlayback)
    #expect(moderation.playback.noOverride == false)
    let plain = try #require(VideoFeedItem(post: try videoPost()))
    #expect(!plain.moderation(policy: adultOnPolicy).concealsPlayback)
  }

  @Test("Same-URI refreshed moderation covers an earlier revealed selection", arguments: [
    ("porn", true),
    ("graphic-media", true)
  ])
  func refreshedSelectedVideo(value: String, covered: Bool) throws {
    let seed = try videoPost()
    let refreshed = try videoPost(serverLabel: value)
    let original = try #require(VideoFeedItem(post: seed))
    let selected = try #require(VideoFeedItem.initialItems(startingAt: seed, feedPosts: [.init(post: refreshed)]).first)
    #expect(selected.id == original.id)
    #expect(selected.revealIdentity != original.revealIdentity)
    #expect(!original.moderation(policy: adultOnPolicy).concealsPlayback)
    #expect(selected.moderation(policy: adultOnPolicy).concealsPlayback == covered)
  }

  // MARK: - Fixtures

  /// A video post by `did:plc:labeltest`. A self-label lives in the record only
  /// (the AppView has not merged it); a server label is issued by the Bluesky
  /// moderation service on the post.
  private func videoPost(selfLabel: String? = nil, serverLabel: String? = nil) throws -> AppBskyFeedDefs.PostView {
    let uri = try ATProtocolURI(uriString: "at://did:plc:labeltest/app.bsky.feed.post/selected")
    let author = try DID(didString: "did:plc:labeltest")
    let createdAt = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    let record = AppBskyFeedPost(
      text: "Video", entities: nil, facets: nil, reply: nil, embed: nil, langs: nil,
      labels: selfLabel.map { .comAtprotoLabelDefsSelfLabels(.init(values: [.init(val: $0)])) },
      tags: nil, createdAt: createdAt)
    let base = PublicPostTestFixtures.makePostView(uri: uri, authorDID: author, record: .knownType(record))
    let video = AppBskyEmbedVideo.View(cid: base.cid, playlist: URI(uriString: "https://video.example.test/selected.m3u8"))
    let labeler = try DID(didString: ModerationPrefs.blueskyModerationDID)
    return AppBskyFeedDefs.PostView(
      uri: base.uri, cid: base.cid, author: base.author, record: base.record,
      embed: .appBskyEmbedVideoView(video), indexedAt: base.indexedAt,
      labels: serverLabel.map { [.init(src: labeler, uri: URI(uriString: uri.uriString()), val: $0, cts: createdAt)] }
    )
  }
}
