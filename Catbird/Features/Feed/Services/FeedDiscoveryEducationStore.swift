import Foundation

/// Persists the optional Saved/Pinned explanation independently for each account.
@MainActor
struct FeedDiscoveryEducationStore {
  private let defaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.defaults = userDefaults
  }

  func hasAcknowledged(accountDID: String) -> Bool {
    defaults.bool(forKey: key(accountDID))
  }

  func acknowledge(accountDID: String) {
    defaults.set(true, forKey: key(accountDID))
  }

  private func key(_ accountDID: String) -> String {
    "feedDiscovery.libraryExplanation.\(accountDID)"
  }
}
