//
//  MLSMessageModel.swift
//  Catbird
//
//  MLS message data model with plaintext caching
//

import Foundation
import GRDB

/// MLS message model (critical for plaintext caching)
struct MLSMessageModel: Codable, Sendable, Hashable, Identifiable {
  let messageID: String
  let currentUserDID: String
  let conversationID: String
  let senderID: String
  let plaintext: String?
  let embedDataJSON: Data?  // Stores MLSEmbedData as JSON
  let wireFormat: Data?
  let contentType: String
  let timestamp: Date
  let epoch: Int64
  let sequenceNumber: Int64
  let authenticatedData: Data?
  let signature: Data?
  let isDelivered: Bool
  let isRead: Bool
  let isSent: Bool
  let sendAttempts: Int
  let error: String?
  let processingState: String
  let gapBefore: Bool
  let plaintextExpired: Bool

  var id: String { messageID }

  // MARK: - Computed Properties

  /// Parse embedData from JSON
  var parsedEmbed: MLSEmbedData? {
    guard let json = embedDataJSON else { return nil }
    return try? MLSEmbedData.fromJSONData(json)
  }

  // MARK: - Initialization

  init(
    messageID: String,
    currentUserDID: String,
    conversationID: String,
    senderID: String,
    plaintext: String? = nil,
    embedDataJSON: Data? = nil,
    wireFormat: Data? = nil,
    contentType: String = "text",
    timestamp: Date = Date(),
    epoch: Int64,
    sequenceNumber: Int64,
    authenticatedData: Data? = nil,
    signature: Data? = nil,
    isDelivered: Bool = false,
    isRead: Bool = false,
    isSent: Bool = false,
    sendAttempts: Int = 0,
    error: String? = nil,
    processingState: String = "delivered",
    gapBefore: Bool = false,
    plaintextExpired: Bool = false
  ) {
    self.messageID = messageID
    self.currentUserDID = currentUserDID
    self.conversationID = conversationID
    self.senderID = senderID
    self.plaintext = plaintext
    self.embedDataJSON = embedDataJSON
    self.wireFormat = wireFormat
    self.contentType = contentType
    self.timestamp = timestamp
    self.epoch = epoch
    self.sequenceNumber = sequenceNumber
    self.authenticatedData = authenticatedData
    self.signature = signature
    self.isDelivered = isDelivered
    self.isRead = isRead
    self.isSent = isSent
    self.sendAttempts = sendAttempts
    self.error = error
    self.processingState = processingState
    self.gapBefore = gapBefore
    self.plaintextExpired = plaintextExpired
  }

  // MARK: - Update Methods

  /// Create copy with plaintext cached
  func withPlaintext(_ text: String, embedData: MLSEmbedData? = nil) -> MLSMessageModel {
    let embedJSON = embedData.flatMap { try? $0.toJSONData() }
    return MLSMessageModel(
      messageID: messageID,
      currentUserDID: currentUserDID,
      conversationID: conversationID,
      senderID: senderID,
      plaintext: text,
      embedDataJSON: embedJSON,
      wireFormat: wireFormat,
      contentType: contentType,
      timestamp: timestamp,
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      authenticatedData: authenticatedData,
      signature: signature,
      isDelivered: isDelivered,
      isRead: isRead,
      isSent: isSent,
      sendAttempts: sendAttempts,
      error: error,
      processingState: processingState,
      gapBefore: gapBefore,
      plaintextExpired: plaintextExpired
    )
  }

  /// Create copy marked as sent
  func withSentStatus() -> MLSMessageModel {
    MLSMessageModel(
      messageID: messageID,
      currentUserDID: currentUserDID,
      conversationID: conversationID,
      senderID: senderID,
      plaintext: plaintext,
      embedDataJSON: embedDataJSON,
      wireFormat: wireFormat,
      contentType: contentType,
      timestamp: timestamp,
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      authenticatedData: authenticatedData,
      signature: signature,
      isDelivered: true,
      isRead: isRead,
      isSent: true,
      sendAttempts: sendAttempts,
      error: nil,
      processingState: processingState,
      gapBefore: gapBefore,
      plaintextExpired: plaintextExpired
    )
  }

  /// Create copy marked as read
  func withReadStatus() -> MLSMessageModel {
    MLSMessageModel(
      messageID: messageID,
      currentUserDID: currentUserDID,
      conversationID: conversationID,
      senderID: senderID,
      plaintext: plaintext,
      embedDataJSON: embedDataJSON,
      wireFormat: wireFormat,
      contentType: contentType,
      timestamp: timestamp,
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      authenticatedData: authenticatedData,
      signature: signature,
      isDelivered: isDelivered,
      isRead: true,
      isSent: isSent,
      sendAttempts: sendAttempts,
      error: error,
      processingState: processingState,
      gapBefore: gapBefore,
      plaintextExpired: plaintextExpired
    )
  }

  /// Create copy with send error
  func withError(_ errorMessage: String) -> MLSMessageModel {
    MLSMessageModel(
      messageID: messageID,
      currentUserDID: currentUserDID,
      conversationID: conversationID,
      senderID: senderID,
      plaintext: plaintext,
      embedDataJSON: embedDataJSON,
      wireFormat: wireFormat,
      contentType: contentType,
      timestamp: timestamp,
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      authenticatedData: authenticatedData,
      signature: signature,
      isDelivered: false,
      isRead: isRead,
      isSent: false,
      sendAttempts: sendAttempts + 1,
      error: errorMessage,
      processingState: "failed",
      gapBefore: gapBefore,
      plaintextExpired: plaintextExpired
    )
  }

  /// Create copy marked as expired (forward secrecy)
  func withExpiredPlaintext() -> MLSMessageModel {
    MLSMessageModel(
      messageID: messageID,
      currentUserDID: currentUserDID,
      conversationID: conversationID,
      senderID: senderID,
      plaintext: nil, // Clear plaintext
      embedDataJSON: nil, // Clear embed
      wireFormat: wireFormat,
      contentType: contentType,
      timestamp: timestamp,
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      authenticatedData: authenticatedData,
      signature: signature,
      isDelivered: isDelivered,
      isRead: isRead,
      isSent: isSent,
      sendAttempts: sendAttempts,
      error: error,
      processingState: processingState,
      gapBefore: gapBefore,
      plaintextExpired: true
    )
  }
}

// MARK: - GRDB Conformance
extension MLSMessageModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSMessageModel"

  enum Columns {
    static let messageID = Column("messageID")
    static let currentUserDID = Column("currentUserDID")
    static let conversationID = Column("conversationID")
    static let senderID = Column("senderID")
    static let plaintext = Column("plaintext")
    static let embedDataJSON = Column("embedData")
    static let wireFormat = Column("wireFormat")
    static let contentType = Column("contentType")
    static let timestamp = Column("timestamp")
    static let epoch = Column("epoch")
    static let sequenceNumber = Column("sequenceNumber")
    static let authenticatedData = Column("authenticatedData")
    static let signature = Column("signature")
    static let isDelivered = Column("isDelivered")
    static let isRead = Column("isRead")
    static let isSent = Column("isSent")
    static let sendAttempts = Column("sendAttempts")
    static let error = Column("error")
    static let processingState = Column("processingState")
    static let gapBefore = Column("gapBefore")
    static let plaintextExpired = Column("plaintextExpired")
  }

  enum CodingKeys: String, CodingKey {
    case messageID
    case currentUserDID
    case conversationID
    case senderID
    case plaintext
    case embedDataJSON = "embedData"
    case wireFormat
    case contentType
    case timestamp
    case epoch
    case sequenceNumber
    case authenticatedData
    case signature
    case isDelivered
    case isRead
    case isSent
    case sendAttempts
    case error
    case processingState
    case gapBefore
    case plaintextExpired
  }
}

// MARK: - Helpers

extension MLSMessageModel {
  /// Check if message has plaintext available
  var hasPlaintext: Bool {
    plaintext != nil && !plaintextExpired
  }

  /// Check if message can be retried
  var canRetry: Bool {
    !isSent && sendAttempts < 3
  }

  /// Display text (handles expired messages)
  var displayText: String {
    if plaintextExpired {
      return "🔒 Message expired (forward secrecy)"
    } else if let text = plaintext {
      return text
    } else {
      return "[Encrypted]"
    }
  }
}
