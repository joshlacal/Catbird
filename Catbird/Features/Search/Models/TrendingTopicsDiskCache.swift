import Foundation
import Petrel

/// One account's trending topics, kept in UserDefaults so Search and the timeline can paint them
/// before the network answers on the next launch.
///
/// Only the trend list is stored (topic names, links, counts and the few actor stubs the API sends,
/// whose avatars are URLs). Preview posts, videos and images never are. An entry is read only for
/// the account it was written for and for at most `maxAge`. A mute or block removes every account's
/// entry, and sign-out or account removal removes that account's entry, so nothing stored before
/// either is shown afterwards. Whatever is read still goes through the live moderation context
/// (mutes, blocks, labels) when it is drawn, exactly like a fresh response.
struct TrendingTopicsDiskCache {
  static let keyPrefix = "catbird.trendingTopics.v1."
  /// How long a stored list may still be shown while a refresh runs.
  static let maxAge: TimeInterval = 24 * 60 * 60
  /// A list larger than this is kept in memory only. Ten trends with their actor stubs are a few KB.
  static let maxStoredBytes = 128 * 1024

  private struct Envelope: Codable {
    let accountDID: String
    let trends: [AppBskyUnspeccedDefs.TrendView]
    let savedAt: Date
  }

  let defaults: UserDefaults
  let now: () -> Date

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
  }

  static func key(for accountDID: String) -> String {
    keyPrefix + accountDID
  }

  /// The stored list for exactly this account, or nil when there is none, it is older than
  /// `maxAge`, it is dated in the future, or it cannot be read. Unusable entries are removed.
  func load(accountDID: String) -> (trends: [AppBskyUnspeccedDefs.TrendView], savedAt: Date)? {
    guard !accountDID.isEmpty else { return nil }
    let key = Self.key(for: accountDID)
    guard let data = defaults.data(forKey: key) else { return nil }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
          envelope.accountDID == accountDID,
          !envelope.trends.isEmpty else {
      defaults.removeObject(forKey: key)
      return nil
    }
    let age = now().timeIntervalSince(envelope.savedAt)
    // A clock moved backwards must not make an old list look fresh.
    guard age < Self.maxAge, age > -60 else {
      defaults.removeObject(forKey: key)
      return nil
    }
    return (envelope.trends, envelope.savedAt)
  }

  func store(_ trends: [AppBskyUnspeccedDefs.TrendView], accountDID: String, savedAt: Date) {
    guard !accountDID.isEmpty, !trends.isEmpty else { return }
    let key = Self.key(for: accountDID)
    guard let data = try? JSONEncoder().encode(Envelope(accountDID: accountDID, trends: trends, savedAt: savedAt)),
          data.count <= Self.maxStoredBytes else {
      defaults.removeObject(forKey: key)
      return
    }
    defaults.set(data, forKey: key)
  }

  func remove(accountDID: String) {
    guard !accountDID.isEmpty else { return }
    defaults.removeObject(forKey: Self.key(for: accountDID))
  }

  /// Removes every account's stored list.
  func removeAll() {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
      defaults.removeObject(forKey: key)
    }
  }

  /// Removes this account's stored list, e.g. on sign-out or account removal.
  static func remove(accountDID: String, defaults: UserDefaults = .standard) {
    TrendingTopicsDiskCache(defaults: defaults).remove(accountDID: accountDID)
  }
}
