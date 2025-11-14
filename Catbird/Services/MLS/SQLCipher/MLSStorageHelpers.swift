//
//  MLSStorageHelpers.swift
//  Catbird
//
//  Critical MLS storage operations for GRDB
//  Provides plaintext caching, transactions, and complex queries
//

import Foundation
import GRDB
import OSLog

/// Helper functions for critical MLS storage operations
/// Works with GRDB directly for write operations
struct MLSStorageHelpers {

  // MARK: - Properties

  private static let logger = Logger(subsystem: "Catbird", category: "MLSStorage")

  // MARK: - Critical Operations

  /// Save plaintext immediately after MLS decryption
  /// CRITICAL: MLS ratchet burns secrets after first decrypt - must cache!
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - messageID: Unique message identifier
  ///   - plaintext: Decrypted message text
  ///   - embedDataJSON: Optional rich embed data (as JSON Data)
  ///   - epoch: MLS epoch number
  ///   - sequenceNumber: Message sequence in epoch
  static func savePlaintext(
    in database: DatabaseQueue,
    messageID: String,
    plaintext: String,
    embedDataJSON: Data? = nil,
    epoch: Int64,
    sequenceNumber: Int64
  ) async throws {
    try await database.write { db in
      // Update message with plaintext using GRDB QueryInterface
      if let embedDataJSON = embedDataJSON {
        try db.execute(sql: """
          UPDATE MLSMessageModel
          SET plaintext = ?,
              embedDataJSON = ?,
              epoch = ?,
              sequenceNumber = ?,
              plaintextExpired = 0
          WHERE messageID = ?;
        """, arguments: [plaintext, embedDataJSON, epoch, sequenceNumber, messageID])
      } else {
        try db.execute(sql: """
          UPDATE MLSMessageModel
          SET plaintext = ?,
              epoch = ?,
              sequenceNumber = ?,
              plaintextExpired = 0
          WHERE messageID = ?;
        """, arguments: [plaintext, epoch, sequenceNumber, messageID])
      }

      logger.info("💾 Cached plaintext for message: \(messageID)")
    }
  }

  /// Mark plaintext as expired (forward secrecy enforcement)
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - olderThan: Expire messages older than this date
  ///   - conversationID: Optional conversation filter
  static func markPlaintextExpired(
    in database: DatabaseQueue,
    olderThan date: Date,
    conversationID: String? = nil
  ) async throws {
    try await database.write { db in
      if let convID = conversationID {
        // Expire for specific conversation
        try db.execute(sql: """
          UPDATE MLSMessageModel
          SET plaintext = NULL,
              embedDataJSON = NULL,
              plaintextExpired = 1
          WHERE conversationID = ? AND timestamp < ?;
        """, arguments: [convID, date])
      } else {
        // Expire all messages older than date
        try db.execute(sql: """
          UPDATE MLSMessageModel
          SET plaintext = NULL,
              embedDataJSON = NULL,
              plaintextExpired = 1
          WHERE timestamp < ?;
        """, arguments: [date])
      }

      logger.info("🔒 Expired plaintext for messages older than: \(date)")
    }
  }

  // MARK: - Batch Operations

  /// Insert multiple messages atomically
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - messages: Array of messages to insert
  static func batchInsertMessages(
    in database: DatabaseQueue,
    messages: [MLSMessageModel]
  ) async throws {
    try await database.write { db in
      for var message in messages {
        try message.insert(db)
      }
      logger.info("💾 Batch inserted \(messages.count) messages")
    }
  }

  /// Insert multiple members atomically
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - members: Array of members to insert
  static func batchInsertMembers(
    in database: DatabaseQueue,
    members: [MLSMemberModel]
  ) async throws {
    try await database.write { db in
      for var member in members {
        try member.insert(db)
      }
      logger.info("💾 Batch inserted \(members.count) members")
    }
  }

  // MARK: - Complex Queries

  /// Fetch messages with plaintext available
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - conversationID: Conversation identifier
  ///   - currentUserDID: Current user DID
  ///   - limit: Maximum number of messages
  /// - Returns: Array of messages with plaintext
  static func fetchDecryptedMessages(
    from database: DatabaseQueue,
    conversationID: String,
    currentUserDID: String,
    limit: Int = 50
  ) async throws -> [MLSMessageModel] {
    try await database.read { db in
      try MLSMessageModel
        .filter(MLSMessageModel.Columns.conversationID == conversationID)
        .filter(MLSMessageModel.Columns.currentUserDID == currentUserDID)
        .filter(MLSMessageModel.Columns.plaintextExpired == false)
        .order(MLSMessageModel.Columns.timestamp.desc)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Get unread message count for conversation
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - conversationID: Conversation identifier
  ///   - currentUserDID: Current user DID
  /// - Returns: Number of unread messages
  static func getUnreadCount(
    from database: DatabaseQueue,
    conversationID: String,
    currentUserDID: String
  ) async throws -> Int {
    try await database.read { db in
      try MLSMessageModel
        .filter(MLSMessageModel.Columns.conversationID == conversationID)
        .filter(MLSMessageModel.Columns.currentUserDID == currentUserDID)
        .filter(MLSMessageModel.Columns.isRead == false)
        .fetchCount(db)
    }
  }

  /// Fetch active conversations sorted by last message
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - currentUserDID: Current user DID
  /// - Returns: Array of active conversations
  static func fetchActiveConversations(
    from database: DatabaseQueue,
    currentUserDID: String
  ) async throws -> [MLSConversationModel] {
    try await database.read { db in
      try MLSConversationModel
        .filter(MLSConversationModel.Columns.currentUserDID == currentUserDID)
        .filter(MLSConversationModel.Columns.isActive == true)
        .order(MLSConversationModel.Columns.lastMessageAt.desc)
        .fetchAll(db)
    }
  }

  // MARK: - Transactions

  /// Execute multiple operations atomically
  /// - Parameters:
  ///   - database: GRDB DatabaseQueue
  ///   - block: Transaction block
  static func transaction<T>(
    in database: DatabaseQueue,
    _ block: @escaping (Database) throws -> T
  ) async throws -> T {
    try await database.write { db in
      try block(db)
    }
  }
}

// MARK: - MLSEmbedData Codable Helpers

extension MLSEmbedData {
  /// Encode to Data for storage
  func encoded() -> Data? {
    try? JSONEncoder().encode(self)
  }

  /// Decode from Data
  static func decoded(from data: Data?) -> MLSEmbedData? {
    guard let data = data else { return nil }
    return try? JSONDecoder().decode(MLSEmbedData.self, from: data)
  }
}
