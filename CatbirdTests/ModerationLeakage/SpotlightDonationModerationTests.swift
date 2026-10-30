import Foundation
import Petrel
import Testing

@testable import Catbird

// Spotlight entries show a post's text and author avatar, or a profile's name
// and avatar, outside the app with no warning. These suites check which posts
// and profiles the donator may index, and which feed posts it may seed into the
// on-screen resolution store.

@Suite("Moderation leakage: Spotlight donation")
struct SpotlightDonationModerationTests {
  private typealias F = LeakageFixtures

  private static let likeURI = "at://did:web:self.test/app.bsky.feed.like/like"

  // MARK: Posts

  @Test("An unlabeled post may be indexed")
  func unlabeledPostIsIndexable() throws {
    #expect(SpotlightDonationModeration.allowsPost(try F.post(by: "alice"), policy: F.policy()))
  }

  @Test(
    "A post with a list filter or blur, a media blur, or a blurred author avatar is not indexed",
    arguments: [
      ("!hide", false),  // list filter
      ("!warn", false),  // list blur
      ("sexual", false),  // media blur
      ("sexual", true),  // author avatar blur
    ])
  func moderatedPostIsNotIndexed(value: String, onAuthor: Bool) throws {
    let post =
      try onAuthor
      ? F.post(by: "alice", authorLabels: [F.accountLabel(value, on: "alice")])
      : F.post(by: "alice", labels: [F.postLabel(value, on: "alice")])
    #expect(!SpotlightDonationModeration.allowsPost(post, policy: F.policy()))
  }

  @Test("An adult post is not indexed while adult content is off")
  func adultPostWithAdultOffIsNotIndexed() throws {
    let post = try F.post(by: "alice", labels: [F.postLabel("sexual", on: "alice")])
    #expect(!SpotlightDonationModeration.allowsPost(post, policy: F.policy(adult: false)))
  }

  @Test("Feed posts a list filters are not seeded; warned posts stay on screen and are seeded")
  func resolutionSeeding() throws {
    let hidden = try F.post(by: "alice", labels: [F.postLabel("!hide", on: "alice")])
    let warned = try F.post(by: "bob", labels: [F.postLabel("!warn", on: "bob")])
    let adultOff = try F.post(by: "carol", labels: [F.postLabel("porn", on: "carol")])

    #expect(!SpotlightDonationModeration.isListed(hidden, policy: F.policy()))
    #expect(SpotlightDonationModeration.isListed(warned, policy: F.policy()))
    #expect(!SpotlightDonationModeration.isListed(adultOff, policy: F.policy(adult: false)))
    #expect(SpotlightDonationModeration.isListed(try F.post(by: "dave"), policy: F.policy()))
  }

  @Test("Feed donation indexes engaged posts that moderation allows, and nothing else")
  func feedDonationSelection() throws {
    let liked = AppBskyFeedDefs.ViewerState(like: try ATProtocolURI(uriString: Self.likeURI))
    let likedPlain = try F.post(by: "alice", viewer: liked)
    let likedWarned = try F.post(by: "bob", labels: [F.postLabel("!warn", on: "bob")], viewer: liked)
    let bookmarkedMedia = try F.post(
      by: "carol", labels: [F.postLabel("sexual", on: "carol")],
      viewer: AppBskyFeedDefs.ViewerState(bookmarked: true))
    let notEngaged = try F.post(by: "dave")
    let authored = try F.post(by: "self")

    let indexed = SpotlightDonationModeration.indexableFeedPosts(
      [likedPlain, likedWarned, bookmarkedMedia, notEngaged, authored],
      viewerDID: F.viewerDID, policy: F.policy())
    #expect(indexed.map { $0.uri.uriString() } == [likedPlain, authored].map { $0.uri.uriString() })
  }

  @Test("A thread anchor labelled !hide, or with a blurred avatar, is not seeded into the resolution store")
  func moderatedAnchorIsNotStored() throws {
    let hidden = try F.post(by: "alice", labels: [F.postLabel("!hide", on: "alice")])
    let blurredAvatar = try F.post(by: "bob", authorLabels: [F.accountLabel("sexual", on: "bob")])
    let adultOff = try F.post(by: "carol", labels: [F.postLabel("porn", on: "carol")])
    let plain = try F.post(by: "dave")

    let stored = SpotlightDonationModeration.storablePosts([hidden, blurredAvatar, plain], policy: F.policy())
    #expect(stored.map { $0.uri.uriString() } == [plain.uri.uriString()])
    #expect(SpotlightDonationModeration.storablePosts([adultOff], policy: F.policy(adult: false)).isEmpty)
    #expect(SpotlightDonationModeration.storablePosts([adultOff], policy: F.policy(prefs: [
      ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "ignore")
    ])).count == 1)
  }

  // MARK: Profiles

  @Test("An opened profile labelled !warn, or with a blurred avatar, is not seeded into the resolution store")
  func moderatedProfileIsNotStored() throws {
    let warned = try F.profile("alice", labels: [F.accountLabel("!warn", on: "alice")])
    let blurredAvatar = try F.profile("bob", labels: [F.profileLabel("sexual", on: "bob")])
    let plain = try F.profile("carol")
    let stored = SpotlightDonationModeration.storableProfiles([warned, blurredAvatar, plain], policy: F.policy())
    #expect(stored.map { $0.did.didString() } == [plain.did.didString()])
  }

  @Test("An unlabeled profile may be indexed, and an ignored label does not change that")
  func unlabeledProfileIsIndexable() throws {
    let policy = F.policy()
    #expect(SpotlightDonationModeration.allowsProfile(try F.profile("alice"), policy: policy))
    // `nudity` defaults to `ignore`.
    let ignored = try F.profile("bob", labels: [F.accountLabel("nudity", on: "bob")])
    #expect(SpotlightDonationModeration.allowsProfile(ignored, policy: policy))
  }

  @Test(
    "A profile with a profile-list filter, a profile-view blur or an avatar blur is not indexed",
    arguments: [
      ("!hide", false),  // profile-list filter
      ("!warn", false),  // profile-view blur
      ("sexual", false),  // avatar blur from an account label
      ("sexual", true),  // avatar blur from a profile-record label
    ])
  func moderatedProfileIsNotIndexed(value: String, onProfileRecord: Bool) throws {
    let label = try onProfileRecord ? F.profileLabel(value, on: "alice") : F.accountLabel(value, on: "alice")
    let profile = try F.profile("alice", labels: [label])
    #expect(!SpotlightDonationModeration.allowsProfile(profile, policy: F.policy()))
  }
}
