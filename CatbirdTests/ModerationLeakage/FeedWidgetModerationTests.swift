import Foundation
import Petrel
import Testing

@testable import Catbird

// The feed widget stores posts in the shared App Group and renders them with no
// warning or reveal control. These suites check which posts, media and avatars
// reach that data under the account's moderation policy.

@Suite("Moderation leakage: feed widget")
struct FeedWidgetModerationTests {
  private typealias F = LeakageFixtures

  @Test("An unlabeled post keeps its text, media and avatar")
  func unlabeledPostIsComplete() throws {
    let post = try F.post(by: "alice")
    let widgetPost = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: F.policy()))

    #expect(widgetPost.text == "Text by alice")
    #expect(widgetPost.imageURLs == [F.imageURL("alice")])
    #expect(widgetPost.authorAvatarURL == F.avatarURL("alice"))
  }

  @Test(
    "A post a list would filter or put behind a warning is left out",
    arguments: [
      ("!hide", true),  // system hide: list filter
      ("!warn", true),  // system warn: list blur, no filter
      ("porn", true),  // default `hide` setting: list filter
      ("sexual", false),  // adult content off: list filter
    ])
  func listModeratedPostIsDropped(value: String, adult: Bool) throws {
    let post = try F.post(by: "alice", labels: [F.postLabel(value, on: "alice")])
    #expect(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: F.policy(adult: adult)) == nil)
  }

  @Test("A hide setting on a media label drops the post, not only its media")
  func hideSettingOnMediaLabelDropsPost() throws {
    let post = try F.post(by: "alice", labels: [F.postLabel("sexual", on: "alice")])
    let policy = F.policy(prefs: [ContentLabelPreference(labelerDid: nil, label: "sexual", visibility: "hide")])
    #expect(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: policy) == nil)
  }

  @Test("A warned media label keeps the text and avatar and omits the images")
  func mediaLabelOmitsImages() throws {
    let post = try F.post(by: "alice", labels: [F.postLabel("sexual", on: "alice")])
    let widgetPost = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: F.policy()))

    #expect(widgetPost.text == "Text by alice")
    #expect(widgetPost.imageURLs.isEmpty)
    #expect(widgetPost.authorAvatarURL == F.avatarURL("alice"))
  }

  @Test("A warned media label omits the video thumbnail")
  func mediaLabelOmitsVideoThumbnail() throws {
    let labeled = try F.post(by: "alice", labels: [F.postLabel("graphic-media", on: "alice")], media: .video)
    let plain = try F.post(by: "bob", media: .video)

    let hidden = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(labeled), policy: F.policy()))
    let shown = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(plain), policy: F.policy()))
    #expect(hidden.imageURLs.isEmpty)
    #expect(shown.imageURLs == [F.videoThumbnailURL("bob")])
  }

  @Test("An avatar label on the author omits only the avatar", arguments: [true, false])
  func avatarLabelOmitsAvatar(onProfileRecord: Bool) throws {
    let label = try onProfileRecord ? F.profileLabel("sexual", on: "alice") : F.accountLabel("sexual", on: "alice")
    let post = try F.post(by: "alice", authorLabels: [label])
    let widgetPost = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: F.policy()))

    #expect(widgetPost.authorAvatarURL == nil)
    #expect(widgetPost.imageURLs == [F.imageURL("alice")])
    #expect(widgetPost.text == "Text by alice")
  }

  @Test("Labels from a labeler the account does not subscribe to have no effect")
  func untrustedLabelerIsIgnored() throws {
    let post = try F.post(by: "alice", labels: [F.postLabel("!hide", on: "alice", src: "did:plc:not-subscribed")])
    let widgetPost = try #require(FeedWidgetPosts.widgetPost(from: F.feedPost(post), policy: F.policy()))
    #expect(widgetPost.imageURLs == [F.imageURL("alice")])
  }

  @Test("Building widget data keeps feed order, skips moderated posts and caps the count")
  func makeFiltersAndCaps() throws {
    var posts: [AppBskyFeedDefs.FeedViewPost] = []
    for index in 0..<(FeedWidgetPosts.postLimit * 2) {
      let name = "author\(index)"
      let labels = index.isMultiple(of: 2) ? [try F.postLabel("!hide", on: name)] : nil
      posts.append(F.feedPost(try F.post(by: name, labels: labels)))
    }

    let widgetPosts = FeedWidgetPosts.make(from: posts, policy: F.policy())
    #expect(widgetPosts.count == FeedWidgetPosts.postLimit)
    #expect(widgetPosts.map(\.text) == (0..<FeedWidgetPosts.postLimit).map { "Text by author\($0 * 2 + 1)" })
  }
}
