import Foundation
import Testing
@testable import Catbird

@MainActor
struct FeedPreferenceSnapshotStoreTests {
  @Test("Defaults and failures cannot replace a confirmed account policy")
  func retainsPolicyUntilAcceptedEmpty() {
    let store = FeedPreferenceSnapshotStore()
    let known = Preferences(accountDID: "account-a")
    known.hasConfirmedServerPreferences = true
    known.mutedWords = [MutedWord(id: "word", value: "retained", targets: ["tag"],
      actorTarget: "exclude-following", expiresAt: nil)]
    store.resolve(accountDID: "account-a", confirmed: FeedPreferenceSnapshot(known))
    let defaults = Preferences(accountDID: "account-a")
    #expect(store.resolve(accountDID: "account-a", confirmed: FeedPreferenceSnapshot(defaults))?.mutedWords.count == 1)
    #expect(store.resolve(accountDID: "account-a", confirmed: nil)?.mutedWords[0].targets == ["tag"])
    #expect(store.resolve(accountDID: "account-b", confirmed: FeedPreferenceSnapshot(known)) == nil)
    defaults.hasConfirmedServerPreferences = true
    #expect(store.resolve(accountDID: "account-a", confirmed: FeedPreferenceSnapshot(defaults))?.mutedWords.isEmpty == true)
    #expect(store.resolve(accountDID: "account-a", confirmed: nil, retainedLocal: FeedPreferenceSnapshot(known))?.mutedWords.isEmpty == true)
  }

  @Test("An existing legacy policy seeds only its own absent snapshot")
  func legacyFallback() {
    let store = FeedPreferenceSnapshotStore()
    let legacy = Preferences(accountDID: "account-a")
    legacy.mutedWords = [MutedWord(id: "word", value: "legacy", targets: ["content"], actorTarget: nil, expiresAt: nil)]
    let retained = store.resolve(accountDID: "account-a", confirmed: nil, retainedLocal: FeedPreferenceSnapshot(legacy))
    #expect(retained?.hasConfirmedServerPreferences == false)
    #expect(retained?.mutedWords.count == 1)
    #expect(store.resolve(accountDID: "account-b", confirmed: nil, retainedLocal: FeedPreferenceSnapshot(legacy)) == nil)
    #expect(store.snapshot(for: "account-a")?.mutedWords[0].value == "legacy")
    let feed = Preferences(accountDID: "account-feed")
    feed.feedViewPref = FeedViewPreference(hideReplies: true, hideRepliesByUnfollowed: nil,
      hideRepliesByLikeCount: nil, hideReposts: nil, hideQuotePosts: nil)
    #expect(store.resolve(accountDID: "account-feed", confirmed: nil,
      retainedLocal: FeedPreferenceSnapshot(feed))?.feedViewPref?.hideReplies == true)
    let adult = Preferences(accountDID: "account-adult")
    adult.adultContentEnabled = true
    #expect(store.resolve(accountDID: "account-adult", confirmed: nil,
      retainedLocal: FeedPreferenceSnapshot(adult))?.adultContentEnabled == true)
  }
}
