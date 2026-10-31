import Foundation

/// Keeps account policy values through read failures. It never persists preferences.
@MainActor
final class FeedPreferenceSnapshotStore {
  static let shared = FeedPreferenceSnapshotStore()
  private var snapshots: [String: FeedPreferenceSnapshot] = [:]

  func snapshot(for accountDID: String) -> FeedPreferenceSnapshot? { snapshots[accountDID] }

  /// Only a complete confirmed policy replaces a known snapshot, including an
  /// accepted empty collection. Legacy known rules can seed an absent snapshot.
  @discardableResult
  func resolve(accountDID: String, confirmed: FeedPreferenceSnapshot?,
               retainedLocal: FeedPreferenceSnapshot? = nil) -> FeedPreferenceSnapshot? {
    if let confirmed, confirmed.accountDID == accountDID, confirmed.hasConfirmedServerPreferences {
      snapshots[accountDID] = confirmed
    } else if snapshots[accountDID] == nil, let retainedLocal, retainedLocal.accountDID == accountDID,
              !retainedLocal.mutedWords.isEmpty || !retainedLocal.contentLabelPrefs.isEmpty
                || retainedLocal.feedViewPref != nil || retainedLocal.adultContentEnabled {
      snapshots[accountDID] = retainedLocal
    }
    return snapshots[accountDID]
  }
}
