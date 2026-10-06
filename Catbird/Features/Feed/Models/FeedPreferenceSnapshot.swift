import Foundation

/// Value copies prevent a later pending edit from changing a confirmed runtime snapshot.
struct FeedPreferenceSnapshot {
  let accountDID: String
  let hasConfirmedServerPreferences: Bool
  let adultContentEnabled: Bool
  let contentLabelPrefs: [ContentLabelPreference]
  let mutedWords: [MutedWord]
  let feedViewPref: FeedViewPreference?

  init(_ preferences: Preferences) {
    accountDID = preferences.accountDID
    hasConfirmedServerPreferences = preferences.hasConfirmedServerPreferences
    adultContentEnabled = preferences.adultContentEnabled
    contentLabelPrefs = preferences.contentLabelPrefs
    mutedWords = preferences.mutedWords
    feedViewPref = preferences.feedViewPref
  }
}
