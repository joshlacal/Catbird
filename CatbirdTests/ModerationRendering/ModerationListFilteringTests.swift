import Foundation
import Petrel
import Testing

@testable import Catbird

// `ContentFilterService` drops a feed entry when the account's policy filters
// the post, its reply parent or its reply root (`state/queries/post-feed.ts`
// drops the whole slice upstream).

@Suite("Moderation rendering: list filtering")
struct ModerationListFilteringTests {
  private typealias F = RenderingFixtures
  private let service = ContentFilterService()

  private func parentURI(_ slug: String) -> String { "at://\(F.quotedAuthorDID)/app.bsky.feed.post/\(slug)" }

  @Test("A reply whose parent the policy filters is dropped with it")
  func replyToFilteredParentIsDropped() async throws {
    let parent = try F.post(
      uri: parentURI("parent"), author: try F.profile(did: F.quotedAuthorDID),
      labels: [try F.label("porn", uri: parentURI("parent"))], embed: F.imageEmbed)
    let reply = F.reply(try F.post(), parent: parent)
    let adultOff = F.settings(policy: F.policy(adult: false))
    #expect(!service.shouldShowFeedViewPost(reply, settings: adultOff))
    #expect(await service.filterFeedViewPosts([reply], settings: adultOff).isEmpty)

    let adultOnWarn = F.settings(policy: F.policy(labels: ["porn": "warn"]))
    #expect(service.shouldShowFeedViewPost(reply, settings: adultOnWarn))
  }

  @Test("A reply whose root the policy filters is dropped")
  func replyToFilteredRootIsDropped() async throws {
    let root = try F.post(
      uri: parentURI("root"), author: try F.profile(did: F.quotedAuthorDID),
      labels: [try F.label("!hide", uri: parentURI("root"))])
    let parent = try F.post(uri: parentURI("parent"), author: try F.profile(did: F.quotedAuthorDID))
    let reply = F.reply(try F.post(), parent: parent, root: root)
    #expect(!service.shouldShowFeedViewPost(reply, settings: F.settings(policy: F.policy())))
  }

  @Test("The post itself is dropped by a hide setting, a !hide label or adult-off, and kept otherwise")
  func postFiltering() async throws {
    let policy = F.policy(labels: ["graphic-media": "hide"])
    let hiddenBySetting = AppBskyFeedDefs.FeedViewPost(post: try F.post(labels: [try F.label("graphic-media")], embed: F.imageEmbed))
    let hiddenByLabel = AppBskyFeedDefs.FeedViewPost(post: try F.post(labels: [try F.label("!hide")]))
    let warned = AppBskyFeedDefs.FeedViewPost(post: try F.post(labels: [try F.label("!warn")]))
    let plain = AppBskyFeedDefs.FeedViewPost(post: try F.post())
    let kept = await service.filterFeedViewPosts([hiddenBySetting, hiddenByLabel, warned, plain], settings: F.settings(policy: policy))
    #expect(kept.map { $0.post.uri.uriString() } == [warned.post.uri.uriString(), plain.post.uri.uriString()])

    let adultOff = F.settings(policy: F.policy(adult: false))
    let sexual = try F.post(labels: [try F.label("sexual")], embed: F.imageEmbed)
    #expect(!service.shouldShowPostView(sexual, settings: adultOff))
    #expect(service.shouldShowPostView(sexual, settings: F.settings(policy: F.policy())))
  }

  @Test("The viewer's own labelled post is never filtered")
  func ownPostIsKept() async throws {
    let own = try F.post(
      uri: "at://\(F.viewerDID)/app.bsky.feed.post/mine", author: try F.profile(did: F.viewerDID),
      labels: [try F.label("porn", uri: "at://\(F.viewerDID)/app.bsky.feed.post/mine")], embed: F.imageEmbed)
    #expect(service.shouldShowPostView(own, settings: F.settings(policy: F.policy(adult: false))))
  }

  @Test("A media label from a labeler the account does not subscribe to does not filter")
  func unsubscribedLabelerDoesNotFilter() async throws {
    let post = try F.post(labels: [try F.label("porn", src: "did:web:stranger.test")], embed: F.imageEmbed)
    #expect(service.shouldShowPostView(post, settings: F.settings(policy: F.policy(adult: false))))
  }

  @Test("The fail-closed policy treats adult content as off")
  func failClosedFilters() async throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    #expect(!service.shouldShowPostView(post, settings: FeedTunerSettings.default))
  }
}
