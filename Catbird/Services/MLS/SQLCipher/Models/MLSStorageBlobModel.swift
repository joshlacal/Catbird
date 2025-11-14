//
//  MLSStorageBlobModel.swift
//  Catbird
//
//  MLS encrypted storage blob model (for MLS FFI state and other binary blobs)
//

import Foundation
import GRDB

/// MLS encrypted storage blob model (matches v1_initial_schema migration)
struct MLSStorageBlobModel: Codable, Sendable, Hashable, Identifiable {
  let blobID: String
  let conversationID: String?
  let currentUserDID: String
  let blobType: String
  let blobData: Data
  let mimeType: String
  let size: Int
  let createdAt: Date
  let updatedAt: Date

  var id: String { blobID }

  // MARK: - Blob Type Constants

  enum BlobType {
    static let ffiState = "ffi_state"
    static let keyPackage = "key_package"
    static let groupState = "group_state"
  }

  // MARK: - Initialization

  init(
    blobID: String,
    conversationID: String? = nil,
    currentUserDID: String,
    blobType: String,
    blobData: Data,
    mimeType: String = "application/octet-stream",
    size: Int? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.blobID = blobID
    self.conversationID = conversationID
    self.currentUserDID = currentUserDID
    self.blobType = blobType
    self.blobData = blobData
    self.mimeType = mimeType
    self.size = size ?? blobData.count
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // MARK: - Update Methods

  /// Create updated copy with new blob data
  func withUpdatedData(_ newData: Data) -> MLSStorageBlobModel {
    MLSStorageBlobModel(
      blobID: blobID,
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      blobType: blobType,
      blobData: newData,
      mimeType: mimeType,
      size: newData.count,
      createdAt: createdAt,
      updatedAt: Date()
    )
  }

  // MARK: - Computed Properties

  /// Size of blob data in bytes (from stored size field)
  var sizeInBytes: Int {
    size
  }

  /// Age of storage blob in seconds
  var ageInSeconds: TimeInterval {
    Date().timeIntervalSince(updatedAt)
  }
}

// MARK: - GRDB Conformance
extension MLSStorageBlobModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSStorageBlobModel"

  enum Columns {
    static let blobID = Column("blobID")
    static let conversationID = Column("conversationID")
    static let currentUserDID = Column("currentUserDID")
    static let blobType = Column("blobType")
    static let blobData = Column("blobData")
    static let mimeType = Column("mimeType")
    static let size = Column("size")
    static let createdAt = Column("createdAt")
    static let updatedAt = Column("updatedAt")
  }

  enum CodingKeys: String, CodingKey {
    case blobID
    case conversationID
    case currentUserDID
    case blobType
    case blobData
    case mimeType
    case size
    case createdAt
    case updatedAt
  }
}
