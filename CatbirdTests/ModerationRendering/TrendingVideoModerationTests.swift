import Foundation
import Petrel
import Testing

@testable import Catbird

// The trending video previews (Discover and the home-feed interstitial) list
// only posts the policy keeps in feeds, and never request or draw a thumbnail
// the policy covers, as `VideoPostCard` hides it behind the merged
// `contentList` and `contentMedia` UI upstream.

@Suite("Moderation rendering: trending video previews")
struct TrendingVideoModerationTests {
  private typealias F = RenderingFixtures

  private static let thumbnail = "https://video.example.test/thumb.jpg"

  private func videoEmbed(alt: String? = nil) -> AppBskyEmbedVideo.View {
    AppBskyEmbedVideo.View(
      cid: CID.fromDAGCBOR(Data("video".utf8)), playlist: URI(uriString: "https://video.example.test/p.m3u8"),
      thumbnail: URI(uriString: Self.thumbnail), alt: alt)
  }

  private func video(
    labels: [ComAtprotoLabelDefs.Label]? = nil, selfLabels: [String] = [],
    author: AppBskyActorDefs.ProfileViewBasic? = nil
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    AppBskyFeedDefs.FeedViewPost(
      post: try F.post(author: author, labels: labels, selfLabels: selfLabels, embed: .appBskyEmbedVideoView(videoEmbed(alt: "A clip"))))
  }

  // MARK: - Listing

  @Test("A porn video is dropped while adult content is off or porn is hidden, and listed when porn warns")
  func pornVideoFollowsTheListFilter() throws {
    let porn = try video(labels: [try F.label("porn")])
    #expect(TrendingVideoModeration.listed([porn], policy: F.policy(adult: false)).isEmpty)
    #expect(TrendingVideoModeration.listed([porn], policy: F.policy()).isEmpty, "porn hides by default")
    #expect(TrendingVideoModeration.listed([porn], policy: F.policy(labels: ["porn": "warn"])).count == 1)
  }

  @Test("A reply whose parent the policy filters is dropped with it, as feeds drop the slice")
  func replyToFilteredParentIsDropped() throws {
    let parentURI = "at://\(F.quotedAuthorDID)/app.bsky.feed.post/parent"
    let parent = try F.post(
      uri: parentURI, author: try F.profile(did: F.quotedAuthorDID), labels: [try F.label("!hide", uri: parentURI)])
    let reply = F.reply(
      try F.post(embed: .appBskyEmbedVideoView(videoEmbed())), parent: parent)
    #expect(TrendingVideoModeration.listed([reply], policy: F.policy()).isEmpty)
    #expect(ContentFilterService.listFilterSubject(of: reply, policy: F.policy()) == .replyParent)
  }

  @Test("Plain and warned videos stay listed in their order")
  func listedKeepsOrder() throws {
    let plain = try video()
    let warned = try video(labels: [try F.label("!warn")])
    let hidden = try video(labels: [try F.label("!hide")])
    let listed = TrendingVideoModeration.listed([warned, hidden, plain], policy: F.policy())
    #expect(listed.map { $0.post.uri.uriString() } == [warned, plain].map { $0.post.uri.uriString() })
  }

  // MARK: - Thumbnails

  @Test("A porn video with adult content off has no thumbnail to request")
  func adultOffPornHasNoThumbnail() throws {
    let post = try video(labels: [try F.label("porn")]).post
    let policy = F.policy(adult: false)
    #expect(TrendingVideoModeration.thumbnailURL(for: post, policy: policy) == nil)
    let cover = TrendingVideoModeration.thumbnailUI(for: post, policy: policy)
    #expect(cover.blur && cover.noOverride)
    #expect(ModerationPresentation.title(for: cover) == "Adult Content")
  }

  @Test("A media label set to warn covers the thumbnail; a plain video exposes it", arguments: [
    "porn", "sexual", "graphic-media"
  ])
  func warnedMediaCoversThumbnail(value: String) throws {
    let policy = F.policy(labels: [value: "warn"])
    let post = try video(labels: [try F.label(value)]).post
    #expect(TrendingVideoModeration.thumbnailURL(for: post, policy: policy) == nil)
    #expect(TrendingVideoModeration.thumbnailUI(for: post, policy: policy).blur)
    #expect(TrendingVideoModeration.thumbnailURL(for: try video().post, policy: policy)?.absoluteString == Self.thumbnail)
  }

  @Test("A post-level restriction covers the thumbnail: !warn, an account label, a labeler blurs:content or blurs:media label")
  func postLevelRestrictionsCoverThumbnail() throws {
    #expect(TrendingVideoModeration.thumbnailURL(for: try video(labels: [try F.label("!warn")]).post, policy: F.policy()) == nil)

    let warnedAuthor = try F.profile(labels: [try F.accountLabel("!warn")])
    #expect(TrendingVideoModeration.thumbnailURL(for: try video(author: warnedAuthor).post, policy: F.policy()) == nil)

    let custom = try video(labels: [try F.label("custom", src: F.customLabelerDID)]).post
    for blurs in ["content", "media"] {
      let policy = F.customLabelerPolicy(blurs: blurs, severity: "alert")
      #expect(TrendingVideoModeration.thumbnailURL(for: custom, policy: policy) == nil, "blurs:\(blurs) covers the preview")
    }
    let none = F.customLabelerPolicy(blurs: "none", severity: "alert")
    #expect(TrendingVideoModeration.thumbnailURL(for: custom, policy: none)?.absoluteString == Self.thumbnail)
  }

  @Test("A record self-label the AppView has not merged covers the thumbnail")
  func selfLabelCoversThumbnail() throws {
    let post = try video(selfLabels: ["graphic-media"]).post
    #expect(TrendingVideoModeration.thumbnailURL(for: post, policy: F.policy()) == nil)
  }

  @Test("The thumbnail and alt text are found behind a quote with media as well")
  func quoteWithMediaThumbnail() throws {
    let quoted = try F.quoted()
    let view = AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(quoted))
    let embed: AppBskyFeedDefs.PostViewEmbedUnion = .appBskyEmbedRecordWithMediaView(
      AppBskyEmbedRecordWithMedia.View(record: view, media: .appBskyEmbedVideoView(videoEmbed(alt: "Behind a quote"))))
    let post = try F.post(embed: embed)
    #expect(TrendingVideoModeration.videoThumbnailURL(in: post)?.absoluteString == Self.thumbnail)
    #expect(TrendingVideoModeration.videoAltText(in: post) == "Behind a quote")
    #expect(TrendingVideoModeration.videoThumbnailURL(in: try F.post(embed: F.imageEmbed)) == nil)
  }
}
