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

  static func feedData(accountDID: String, configKey: String) -> [WidgetPost]? {
    // Try DID-scoped key first
    let scopedKey = "\(configKey).\(accountDID)"
    if let data = defaults?.data(forKey: scopedKey),
       let decoded = decodeFeedData(data) {
      logger.debug("Loaded from scoped key: \(scopedKey)")
      return decoded
    }

    // Fallback to general feed data for this account
    let fallbackKey = "\(FeedWidgetConstants.feedDataKey).\(accountDID)"
    if let data = defaults?.data(forKey: fallbackKey),
       let decoded = decodeFeedData(data) {
      logger.debug("Loaded from fallback key: \(fallbackKey)")
      return decoded
    }

    // Legacy fallback: unscoped key
    if let data = defaults?.data(forKey: configKey),
       let decoded = decodeFeedData(data) {
      logger.debug("Loaded from legacy key: \(configKey)")
      return decoded
    }

    return nil
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

  private static func decodeFeedData(_ data: Data) -> [WidgetPost]? {
    if let enhanced = try? decoder.decode(FeedWidgetDataEnhanced.self, from: data) {
      return enhanced.posts
    }
    if let basic = try? decoder.decode(FeedWidgetData.self, from: data) {
      return basic.posts
    }
    return nil
  }
}
#endif
