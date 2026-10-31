//
//  WidgetDataReader.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import Foundation
import os

struct WidgetDataReader {
  private static let logger = Logger(subsystem: "blue.catbird", category: "WidgetDataReader")
  private static let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  /// Returns the posts the app saved for `configKey` under `accountDID`, or nil
  /// when that feed hasn't been loaded in the app for this account. There is
  /// deliberately no fallback to another feed, so the widget never shows one
  /// feed's posts under another feed's name.
  static func feedData(accountDID: String, configKey: String) -> WidgetFeedSnapshot? {
    guard !accountDID.isEmpty else { return nil }

    let scopedKey = "\(configKey).\(accountDID)"
    guard let data = defaults?.data(forKey: scopedKey),
          let decoded = decodeFeedData(data) else {
      return nil
    }
    logger.debug("Loaded from scoped key: \(scopedKey)")
    return decoded
  }

  static func activeAccountDID() -> String? {
    defaults?.string(forKey: "activeAccountDID")
  }

  static func allAccounts() -> [WidgetAccount] {
    guard let data = defaults?.data(forKey: "widgetAccounts"),
          let accounts = try? decoder.decode([WidgetAccount].self, from: data) else {
      return []
    }
    return accounts
  }

  private static func decodeFeedData(_ data: Data) -> WidgetFeedSnapshot? {
    if let enhanced = try? decoder.decode(FeedWidgetDataEnhanced.self, from: data) {
      return WidgetFeedSnapshot(posts: enhanced.posts, lastUpdated: enhanced.lastUpdated)
    }
    if let basic = try? decoder.decode(FeedWidgetData.self, from: data) {
      return WidgetFeedSnapshot(posts: basic.posts, lastUpdated: basic.lastUpdated)
    }
    return nil
  }
}
#endif
