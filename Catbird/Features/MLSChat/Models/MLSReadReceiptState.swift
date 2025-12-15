import Foundation

/// Manages read receipt state for MLS conversations
@Observable
final class MLSReadReceiptState {
  /// Read receipts by message ID: messageId -> [userDid -> readAt]
  private(set) var readReceipts: [String: [String: Date]] = [:]

  /// Mark a message as read by a user
  /// - Parameters:
  ///   - messageId: The message identifier
  ///   - userDid: The DID of the user who read the message
  ///   - date: When the message was read
  func markAsRead(messageId: String, by userDid: String, at date: Date) {
    if readReceipts[messageId] == nil {
      readReceipts[messageId] = [:]
    }
    readReceipts[messageId]?[userDid] = date
  }

  /// Get the number of users who have read a message
  /// - Parameter messageId: The message identifier
  /// - Returns: Count of users who have read this message
  func readCount(for messageId: String) -> Int {
    readReceipts[messageId]?.count ?? 0
  }

  /// Check if a specific message has been read by a user
  /// - Parameters:
  ///   - messageId: The message identifier
  ///   - userDid: The DID of the user to check
  /// - Returns: True if the user has read this message
  func isRead(messageId: String, by userDid: String) -> Bool {
    readReceipts[messageId]?[userDid] != nil
  }

  /// Get the timestamp when a user read a message
  /// - Parameters:
  ///   - messageId: The message identifier
  ///   - userDid: The DID of the user
  /// - Returns: The date when the user read the message, or nil if not read
  func readDate(for messageId: String, by userDid: String) -> Date? {
    readReceipts[messageId]?[userDid]
  }

  /// Get all users who have read a message
  /// - Parameter messageId: The message identifier
  /// - Returns: Array of tuples containing user DIDs and read timestamps
  func readers(for messageId: String) -> [(userDid: String, readAt: Date)] {
    guard let readers = readReceipts[messageId] else {
      return []
    }
    return readers.map { (userDid: $0.key, readAt: $0.value) }
      .sorted { $0.readAt < $1.readAt }
  }

  /// Clear all read receipts
  func clearAll() {
    readReceipts.removeAll()
  }

  /// Clear read receipts for a specific message
  /// - Parameter messageId: The message identifier
  func clear(for messageId: String) {
    readReceipts.removeValue(forKey: messageId)
  }

  /// Clear read receipts for a specific conversation
  /// - Parameter conversationId: The conversation identifier
  /// - Note: This requires message IDs to follow a pattern including the conversation ID
  func clear(forConversation conversationId: String) {
    readReceipts = readReceipts.filter { messageId, _ in
      !messageId.contains(conversationId)
    }
  }
}
