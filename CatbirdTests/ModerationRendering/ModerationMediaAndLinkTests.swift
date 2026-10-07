import Foundation
import Petrel
import Testing

@testable import Catbird

// The video feed cover and the link-card gate derive from the same engine as
// the feed row. The cover merges `contentView` and `contentMedia`, as
// `screens/VideoFeed/index.tsx` does upstream.

@Suite("Moderation rendering: video and link media")
struct ModerationMediaAndLinkTests {
  private typealias F = RenderingFixtures

  private func videoPost(labels: [ComAtprotoLabelDefs.Label]? = nil, selfLabels: [String] = []) throws -> AppBskyFeedDefs.PostView {
    let video = AppBskyEmbedVideo.View(
      cid: CID.fromDAGCBOR(Data("video".utf8)), playlist: URI(uriString: "https://video.example.test/p.m3u8"))
    return try F.post(labels: labels, selfLabels: selfLabels, embed: .appBskyEmbedVideoView(video))
  }

  @Test("A media label covers the video so it cannot autoplay; a plain video plays")
  func mediaLabelCoversVideo() throws {
    let covered = try #require(VideoFeedItem(post: try videoPost(labels: [try F.label("sexual")])))
    let moderation = covered.moderation(policy: F.policy())
    #expect(moderation.concealsPlayback)
    #expect(!moderation.isFilteredFromList)
    #expect(!moderation.playback.noOverride)
    #expect(ModerationPresentation.title(for: moderation.playback) == "Adult Content")

    let plain = try #require(VideoFeedItem(post: try videoPost()))
    #expect(!plain.moderation(policy: F.policy()).concealsPlayback)
  }

  @Test("A !warn label covers the video through the contentView blur")
  func warnLabelCoversVideo() throws {
    let item = try #require(VideoFeedItem(post: try videoPost(labels: [try F.label("!warn")])))
    let moderation = item.moderation(policy: F.policy())
    #expect(moderation.concealsPlayback)
    #expect(moderation.playback.blurs.map(\.label.val) == ["!warn"])
  }

  @Test("A content-level cover hides the caption with the player; a media-only cover leaves it")
  func contentCoverConcealsCaption() throws {
    let warned = try #require(VideoFeedItem(post: try videoPost(labels: [try F.label("!warn")])))
    #expect(warned.moderation(policy: F.policy()).concealsCaption)

    let warnedAuthor = try F.profile(labels: [try F.accountLabel("!warn")])
    let video = AppBskyEmbedVideo.View(
      cid: CID.fromDAGCBOR(Data("video".utf8)), playlist: URI(uriString: "https://video.example.test/p.m3u8"))
    let byWarnedAuthor = try #require(
      VideoFeedItem(post: try F.post(author: warnedAuthor, embed: .appBskyEmbedVideoView(video))))
    let moderation = byWarnedAuthor.moderation(policy: F.policy())
    #expect(moderation.concealsCaption)
    #expect(moderation.concealsPlayback)

    let mediaOnly = try #require(VideoFeedItem(post: try videoPost(labels: [try F.label("sexual")])))
    let mediaModeration = mediaOnly.moderation(policy: F.policy())
    #expect(mediaModeration.concealsPlayback)
    #expect(!mediaModeration.concealsCaption, "a media label is not about the post text")

    let plain = try #require(VideoFeedItem(post: try videoPost()))
    #expect(!plain.moderation(policy: F.policy()).concealsCaption)
  }

  @Test("Adult off: a porn video is skipped by the feed and, if shown, its cover has no Show")
  func adultOffVideo() throws {
    let item = try #require(VideoFeedItem(post: try videoPost(labels: [try F.label("porn")])))
    let moderation = item.moderation(policy: F.policy(adult: false))
    #expect(moderation.isFilteredFromList)
    #expect(moderation.concealsPlayback)
    #expect(moderation.playback.noOverride)
    #expect(ModerationGateText.explanation(for: moderation.playback).contains("bsky.app"))
  }

  @Test("A record self-label covers the video before the AppView merges it")
  func selfLabelCoversVideo() throws {
    let item = try #require(VideoFeedItem(post: try videoPost(selfLabels: ["graphic-media"])))
    #expect(item.moderation(policy: F.policy()).concealsPlayback)
  }

  @Test("Merging two UIs keeps each cause once and locks when either side locks")
  func mergedUI() throws {
    let post = try F.post(labels: [try F.label("!hide"), try F.label("porn")], embed: F.imageEmbed)
    let decision = F.policy(adult: false).decide(post: post)
    let merged = decision.ui(.contentView).merged(with: decision.ui(.contentMedia))
    #expect(Set(merged.blurs.map(\.label.val)) == ["!hide", "porn"])
    #expect(merged.noOverride)
    let twice = merged.merged(with: merged)
    #expect(twice.blurs.count == merged.blurs.count)
    #expect(twice.filters.count == merged.filters.count)
  }

  // MARK: - Link cards

  @Test("Labels on a link card gate it as media when a trusted labeler issued them")
  func linkLabelsGateCard() throws {
    let trusted = [try F.label("porn", uri: "https://example.test/article")]
    let ui = ExternalLinkModeration.mediaUI(labels: trusted, policy: F.policy(labels: ["porn": "warn"]))
    #expect(ui.blur)
    #expect(!ui.noOverride)
    #expect(ExternalLinkModeration.mediaUI(labels: trusted, policy: F.policy(adult: false)).noOverride)
  }

  @Test("Link labels from an unknown source, or no labels, leave the card alone")
  func linkLabelsIgnored() throws {
    let stranger = [try F.label("porn", uri: "https://example.test/article", src: "did:web:stranger.test")]
    #expect(!ExternalLinkModeration.mediaUI(labels: stranger, policy: F.policy(adult: false)).blur)
    #expect(!ExternalLinkModeration.mediaUI(labels: nil, policy: F.policy(adult: false)).blur)
    #expect(!ExternalLinkModeration.mediaUI(labels: [], policy: F.policy(adult: false)).blur)
  }
}
