import Foundation
import Petrel
import Testing

@testable import Catbird

// Avatar and banner moderation: `ModerationPolicy.concealsAvatar/concealsBanner`
// (the `avatar` and `banner` contexts of the merged account + profile decision)
// and the avatar view's source decision, which must never build a request for a
// concealed avatar.

private let bluesky = ModerationPrefs.blueskyModerationDID
private let me = "did:web:me.test"
private let alice = "did:web:alice.test"
private let customLabeler = "did:plc:custom-labeler"

private func policy(
  adult: Bool,
  prefs: [(key: String, visibility: String)] = [],
  labelers: [String] = []
) -> ModerationPolicy {
  ModerationPolicy(
    accountDID: me,
    serverAdultContentEnabled: adult,
    contentLabelPrefs: prefs.map { ContentLabelPreference(labelerDid: nil, label: $0.key, visibility: $0.visibility) },
    labelerDIDs: labelers,
    labelerDefinitions: [:],
    isConfirmed: true)
}

/// Whether the avatar and the banner are concealed, in that order.
private func concealment(
  _ policy: ModerationPolicy,
  did: String?,
  labels: [ComAtprotoLabelDefs.Label]
) -> (avatar: Bool, banner: Bool) {
  (policy.concealsAvatar(did: did, labels: labels), policy.concealsBanner(did: did, labels: labels))
}

@Suite("Moderation: avatars and banners")
struct ProfileImageModerationTests {
  // MARK: Bluesky moderation account label

  @Test("Account labelled porn by Bluesky moderation, adult content off: both concealed, no reveal")
  func blueskyPornAdultOff() throws {
    let labels = [try ModerationFixtures.accountLabel("porn", name: "alice", src: bluesky)]
    let off = policy(adult: false)

    let result = concealment(off, did: alice, labels: labels)
    #expect(result.avatar)
    #expect(result.banner)
    #expect(off.profileImageUI(.avatar, did: alice, labels: labels).noOverride)
  }

  @Test(
    "Account labelled porn by Bluesky moderation, adult content on: the porn preference decides",
    arguments: [
      ("porn", "warn", true),
      ("porn", "hide", true),
      ("porn", "ignore", false),
      ("nsfw", "ignore", false),
    ])
  func blueskyPornAdultOn(key: String, visibility: String, concealed: Bool) throws {
    let labels = [try ModerationFixtures.accountLabel("porn", name: "alice", src: bluesky)]
    let on = policy(adult: true, prefs: [(key, visibility)])

    let result = concealment(on, did: alice, labels: labels)
    #expect(result.avatar == concealed)
    #expect(result.banner == concealed)
    #expect(!on.profileImageUI(.avatar, did: alice, labels: labels).noOverride)
  }

  @Test("nudity defaults to ignore, so a Bluesky nudity label shows the avatar")
  func nudityDefault() throws {
    let labels = [try ModerationFixtures.accountLabel("nudity", name: "alice", src: bluesky)]
    #expect(!policy(adult: true).concealsAvatar(did: alice, labels: labels))
  }

  // MARK: Self-labels

  @Test("A porn self-label on the profile record conceals both unless the user ignores porn")
  func profileSelfLabel() throws {
    let labels = [try ModerationFixtures.profileLabel("porn", name: "alice", src: alice)]

    let off = concealment(policy(adult: false), did: alice, labels: labels)
    #expect(off.avatar)
    #expect(off.banner)
    #expect(concealment(policy(adult: true, prefs: [("porn", "warn")]), did: alice, labels: labels).avatar)
    #expect(!concealment(policy(adult: true, prefs: [("porn", "ignore")]), did: alice, labels: labels).avatar)
  }

  @Test("Without a DID, the subject is read from the labels so self-labels still count")
  func selfLabelWithoutDID() throws {
    let labels = [try ModerationFixtures.profileLabel("porn", name: "alice", src: alice)]
    #expect(policy(adult: false).concealsAvatar(did: nil, labels: labels))
    #expect(policy(adult: false).concealsAvatar(did: "", labels: labels))
  }

  @Test("The subject DID comes from account and profile-record labels only")
  func subjectDIDFromLabels() throws {
    #expect(ProfileImageModerationSubject.subjectDID(of: try ModerationFixtures.accountLabel("porn", name: "alice")) == alice)
    #expect(ProfileImageModerationSubject.subjectDID(of: try ModerationFixtures.profileLabel("porn", name: "alice")) == alice)
    #expect(ProfileImageModerationSubject.subjectDID(of: try ModerationFixtures.postLabel("porn", name: "alice")) == nil)

    let explicit = ProfileImageModerationSubject(did: "did:web:bob.test", labels: [try ModerationFixtures.accountLabel("porn", name: "alice")])
    #expect(explicit.moderationDID == "did:web:bob.test")
    #expect(ProfileImageModerationSubject(did: nil, labels: nil).moderationDID.isEmpty)
  }

  // MARK: Label trust

  @Test("A label from an unsubscribed labeler is ignored; the same label from a subscribed one conceals")
  func unsubscribedLabeler() throws {
    let labels = [try ModerationFixtures.accountLabel("porn", name: "alice", src: customLabeler)]

    let unsubscribed = concealment(policy(adult: false), did: alice, labels: labels)
    #expect(!unsubscribed.avatar)
    #expect(!unsubscribed.banner)

    let subscribed = concealment(policy(adult: false, labelers: [customLabeler]), did: alice, labels: labels)
    #expect(subscribed.avatar)
    #expect(subscribed.banner)
  }

  // MARK: Imperative labels

  @Test("!hide on the account conceals both with no reveal, whatever the adult setting")
  func hideOnAccount() throws {
    let labels = [try ModerationFixtures.accountLabel("!hide", name: "alice", src: bluesky)]
    for adult in [false, true] {
      let current = policy(adult: adult, prefs: [("porn", "ignore")])
      let result = concealment(current, did: alice, labels: labels)
      #expect(result.avatar)
      #expect(result.banner)
      #expect(current.profileImageUI(.banner, did: alice, labels: labels).noOverride)
    }
  }

  // MARK: Own profile

  @Test("Own profile: labels still conceal (as in the official app), but never lock a reveal")
  func ownProfile() throws {
    let porn = [try ModerationFixtures.accountLabel("porn", name: "me", src: bluesky)]
    let off = policy(adult: false)
    #expect(off.decide(profile: ProfileImageModerationSubject(did: me, labels: porn)).isMe)
    #expect(concealment(off, did: me, labels: porn).avatar)
    #expect(concealment(off, did: me, labels: porn).banner)
    #expect(!off.profileImageUI(.avatar, did: me, labels: porn).noOverride)

    let hidden = [try ModerationFixtures.accountLabel("!hide", name: "me", src: bluesky)]
    #expect(concealment(off, did: me, labels: hidden).avatar)
    #expect(!off.profileImageUI(.avatar, did: me, labels: hidden).noOverride)
  }

  // MARK: No labels

  @Test("An account without labels is never concealed")
  func noLabels() {
    let off = policy(adult: false)
    #expect(!off.concealsAvatar(did: alice, labels: nil))
    #expect(!off.concealsBanner(did: alice, labels: []))
    #expect(off.profileImageUI(.avatar, did: alice, labels: nil) == .empty)
  }
}

// MARK: - Avatar view source

@Suite("Moderation: avatar view source")
@MainActor
struct AsyncProfileImageSourceTests {
  private let url = URL(string: "https://cdn.bsky.app/img/avatar/plain/did:web:alice.test/cid@jpeg")

  @Test("A concealed avatar builds no image request, with or without a URL")
  func concealedBuildsNoRequest() throws {
    let labels = [try ModerationFixtures.accountLabel("porn", name: "alice", src: bluesky)]
    for candidate in [url, nil] {
      let source = AsyncProfileImage.source(
        url: candidate, sizeInPoints: 40, displayScale: 3, did: alice, labels: labels, policy: policy(adult: false))
      guard case .concealed = source else {
        Issue.record("Expected a concealed avatar, got \(source)")
        continue
      }
    }
  }

  @Test("An allowed avatar loads the resized request; no URL means the plain placeholder")
  func allowedAvatar() throws {
    let labels = [try ModerationFixtures.accountLabel("porn", name: "alice", src: bluesky)]
    let on = policy(adult: true, prefs: [("porn", "ignore")])

    let loaded = AsyncProfileImage.source(url: url, sizeInPoints: 40, displayScale: 3, did: alice, labels: labels, policy: on)
    guard case .image(let request) = loaded else {
      Issue.record("Expected an image request, got \(loaded)")
      return
    }
    #expect(request.url == url)

    let missing = AsyncProfileImage.source(url: nil, sizeInPoints: 40, displayScale: 3, did: alice, labels: nil, policy: on)
    guard case .placeholder = missing else {
      Issue.record("Expected no source, got \(missing)")
      return
    }
  }
}
