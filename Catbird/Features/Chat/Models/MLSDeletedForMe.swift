import CatbirdMLSCore
import Foundation

/// Encrypted chats this account deleted for itself, and when.
///
/// "Delete for me" hides a chat on this account only; the group goes on. A chat used to stay
/// hidden for good, so when the other person wrote again the push arrived but the chat never
/// came back to the list. Each deletion now keeps its time, and a message that arrives after
/// it brings the chat back, as in Messages and Signal.
struct MLSDeletedForMe {
  private let defaults: UserDefaults
  private let now: () -> Date
  private let key: String
  private let legacyKey: String

  init(
    accountDID: String,
    defaults: UserDefaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.now = now
    let account = accountDID.lowercased()
    key = "mls.deletedForMeAt.\(account)"
    legacyKey = "mls.deletedForMe.\(account)"
  }

  /// Hide the chat until a newer message arrives.
  func hide(_ conversationID: String) {
    var marks = load()
    marks[conversationID] = now().timeIntervalSince1970
    save(marks)
  }

  /// Show the chat again, for example when this account starts a chat with the same person.
  func reveal(_ conversationID: String) {
    var marks = load()
    guard marks.removeValue(forKey: conversationID) != nil else { return }
    save(marks)
  }

  /// Whether the chat is still hidden, given its newest message. A message newer than the
  /// deletion clears the mark, so the chat stays in the list from then on.
  func isHidden(_ conversationID: String, latestMessageAt: Date?) -> Bool {
    var marks = load()
    guard let deletedAt = marks[conversationID] else { return false }
    if let latestMessageAt, latestMessageAt.timeIntervalSince1970 > deletedAt {
      marks.removeValue(forKey: conversationID)
      save(marks)
      return false
    }
    return true
  }

  /// Whether the chat is still hidden, searching past the preview window when needed.
  ///
  /// `newestFirst` is the page the list already loaded. When it holds no text or photo, older
  /// pages from `olderThan` (messages before a sequence number, newest first) are searched until
  /// they reach messages older than the deletion, so a text followed by many reactions or edits
  /// still brings the chat back.
  func isHidden(
    _ conversationID: String,
    newestFirst: [MLSMessageModel],
    olderThan: (Int64) async throws -> [MLSMessageModel]
  ) async -> Bool {
    guard let deletedAt = load()[conversationID].map(Date.init(timeIntervalSince1970:)) else {
      return false
    }
    var page = newestFirst
    while !page.isEmpty {
      if let latest = Self.latestRestoringMessageAt(in: page) {
        return isHidden(conversationID, latestMessageAt: latest)
      }
      guard let oldest = page.min(by: { $0.sequenceNumber < $1.sequenceNumber }),
        oldest.timestamp > deletedAt
      else { break }
      guard let older = try? await olderThan(oldest.sequenceNumber) else { break }
      page = older
    }
    return isHidden(conversationID, latestMessageAt: nil)
  }

  /// The newest message in `messages` that brings a deleted chat back.
  static func latestRestoringMessageAt(in messages: [MLSMessageModel]) -> Date? {
    messages.lazy
      .filter { bringsChatBack($0.parsedPayload()) }
      .map(\.timestamp)
      .max()
  }

  /// Whether a message brings a deleted chat back: a new text or photo does; reactions, read
  /// receipts, typing, edits and membership changes do not.
  static func bringsChatBack(_ payload: MLSMessagePayload?) -> Bool {
    guard let payload, payload.messageType == .text else { return false }
    return !(payload.text ?? "").isEmpty || payload.embed != nil
  }

  private func load() -> [String: Double] {
    var marks = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    // Deletions saved before times were kept: treat them as made now, so they stay hidden
    // until the next message rather than all reappearing at once.
    if let legacy = defaults.stringArray(forKey: legacyKey) {
      let stamp = now().timeIntervalSince1970
      for id in legacy where marks[id] == nil {
        marks[id] = stamp
      }
      save(marks)
      defaults.removeObject(forKey: legacyKey)
    }
    return marks
  }

  private func save(_ marks: [String: Double]) {
    if marks.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(marks, forKey: key)
    }
  }
}
