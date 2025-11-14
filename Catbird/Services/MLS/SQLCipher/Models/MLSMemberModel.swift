//
//  MLSMemberModel.swift
//  Catbird
//
//  MLS group member data model
//

import Foundation
import GRDB

/// MLS group member model
struct MLSMemberModel: Codable, Sendable, Hashable, Identifiable {
  let memberID: String
  let conversationID: String
  let currentUserDID: String
  let did: String
  let handle: String?
  let displayName: String?
  let leafIndex: Int
  let credentialData: Data?
  let signaturePublicKey: Data?
  let addedAt: Date
  let updatedAt: Date
  let removedAt: Date?
  let isActive: Bool
  let role: Role
  let capabilitiesData: Data?

  var id: String { memberID }

  // Computed property for capabilities array
  var capabilities: [String]? {
    get {
      guard let data = capabilitiesData else { return nil }
      return try? JSONDecoder().decode([String].self, from: data)
    }
  }

  // Helper to create capabilitiesData from array
  static func encodeCapabilities(_ capabilities: [String]?) -> Data? {
    guard let capabilities = capabilities else { return nil }
    return try? JSONEncoder().encode(capabilities)
  }

  // MARK: - Role Enum

  /// Member role
  enum Role: String, Codable, Sendable {
    case member
    case admin
    case moderator
  }
}

// MARK: - GRDB Conformance
extension MLSMemberModel: FetchableRecord, PersistableRecord {
  static let databaseTableName = "MLSMemberModel"

  enum Columns {
    static let memberID = Column("memberID")
    static let conversationID = Column("conversationID")
    static let currentUserDID = Column("currentUserDID")
    static let did = Column("did")
    static let handle = Column("handle")
    static let displayName = Column("displayName")
    static let leafIndex = Column("leafIndex")
    static let credentialData = Column("credentialData")
    static let signaturePublicKey = Column("signaturePublicKey")
    static let addedAt = Column("addedAt")
    static let updatedAt = Column("updatedAt")
    static let removedAt = Column("removedAt")
    static let isActive = Column("isActive")
    static let role = Column("role")
    static let capabilitiesData = Column("capabilities")
  }

  enum CodingKeys: String, CodingKey {
    case memberID
    case conversationID
    case currentUserDID
    case did
    case handle
    case displayName
    case leafIndex
    case credentialData
    case signaturePublicKey
    case addedAt
    case updatedAt
    case removedAt
    case isActive
    case role
    case capabilitiesData = "capabilities"
  }
}

// MARK: - MLSMemberModel

extension MLSMemberModel {
  // MARK: - Initialization

  init(
    memberID: String,
    conversationID: String,
    currentUserDID: String,
    did: String,
    handle: String? = nil,
    displayName: String? = nil,
    leafIndex: Int,
    credentialData: Data? = nil,
    signaturePublicKey: Data? = nil,
    addedAt: Date = Date(),
    updatedAt: Date = Date(),
    removedAt: Date? = nil,
    isActive: Bool = true,
    role: Role = .member,
    capabilities: [String]? = nil
  ) {
    self.memberID = memberID
    self.conversationID = conversationID
    self.currentUserDID = currentUserDID
    self.did = did
    self.handle = handle
    self.displayName = displayName
    self.leafIndex = leafIndex
    self.credentialData = credentialData
    self.signaturePublicKey = signaturePublicKey
    self.addedAt = addedAt
    self.updatedAt = updatedAt
    self.removedAt = removedAt
    self.isActive = isActive
    self.role = role
    self.capabilitiesData = Self.encodeCapabilities(capabilities)
  }

  // MARK: - Update Methods

  /// Create copy marked as removed
  func withRemoved(at date: Date = Date()) -> MLSMemberModel {
    MLSMemberModel(
      memberID: memberID,
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      did: did,
      handle: handle,
      displayName: displayName,
      leafIndex: leafIndex,
      credentialData: credentialData,
      signaturePublicKey: signaturePublicKey,
      addedAt: addedAt,
      updatedAt: date,
      removedAt: date,
      isActive: false,
      role: role,
      capabilities: capabilities
    )
  }

  /// Create copy with updated profile info
  func withProfileInfo(handle: String?, displayName: String?) -> MLSMemberModel {
    MLSMemberModel(
      memberID: memberID,
      conversationID: conversationID,
      currentUserDID: currentUserDID,
      did: did,
      handle: handle,
      displayName: displayName,
      leafIndex: leafIndex,
      credentialData: credentialData,
      signaturePublicKey: signaturePublicKey,
      addedAt: addedAt,
      updatedAt: Date(),
      removedAt: removedAt,
      isActive: isActive,
      role: role,
      capabilities: capabilities
    )
  }
}
