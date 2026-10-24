import CatbirdMLSCore
//
//  MLSViewModels.swift
//  Catbird
//
//  View model types for MLS UI (SQLiteData-based)
//

import Foundation
import Petrel
import PetrelCatbird

// MARK: - View Models

/// ViewModel for conversation list display
public struct MLSConversationViewModel: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String?
  public let participants: [MLSParticipantViewModel]
  public let lastMessagePreview: String?
  public let lastMessageTimestamp: Date?
  public let unreadCount: Int
  public let isGroupChat: Bool
  public let groupId: String?

  public init(
    id: String,
    name: String?,
    participants: [MLSParticipantViewModel],
    lastMessagePreview: String?,
    lastMessageTimestamp: Date?,
    unreadCount: Int,
    isGroupChat: Bool,
    groupId: String?
  ) {
    self.id = id
    self.name = name
    self.participants = participants
    self.lastMessagePreview = lastMessagePreview
    self.lastMessageTimestamp = lastMessageTimestamp
    self.unreadCount = unreadCount
    self.isGroupChat = isGroupChat
    self.groupId = groupId
  }
}

/// ViewModel for conversation participant display
public struct MLSParticipantViewModel: Identifiable, Hashable, Sendable {
  public let id: String
  public let handle: String
  public let displayName: String?
  public let avatarURL: URL?

  public init(
    id: String,
    handle: String,
    displayName: String?,
    avatarURL: URL?
  ) {
    self.id = id
    self.handle = handle
    self.displayName = displayName
    self.avatarURL = avatarURL
  }
}

/// ViewModel for message display
struct MLSMessageViewModel: Identifiable {
  let id: String
  let content: String
  let contentType: String
  let timestamp: Date
  let senderID: String
  let senderHandle: String
  let senderDisplayName: String?
  let isCurrentUser: Bool
  let isDelivered: Bool
  let isRead: Bool
  let isSent: Bool
  let error: String?
}

/// ViewModel for member management
struct MLSMemberViewModel: Identifiable {
  let id: String
  let did: String
  let handle: String?
  let displayName: String?
  let leafIndex: Int
  let role: String
  let isActive: Bool
  let addedAt: Date
  let removedAt: Date?
}

// MARK: - Server Model to ViewModel Conversion

extension BlueCatbirdChatDefs.ConversationState {
  func toViewModel(unreadCount: Int = 0) -> MLSConversationViewModel {
    // Split complex map to prevent type checker explosion
    let participantVMs: [MLSParticipantViewModel] = participants.map { member in
      let didStr = member.userDid.description
      let lastPart = didStr.split(separator: ":").last
      let handle = lastPart.map(String.init) ?? didStr

      return MLSParticipantViewModel(
        id: didStr,
        handle: handle,
        displayName: nil,
        avatarURL: nil
      )
    }

    return MLSConversationViewModel(
      id: coordinates.conversationId,
      // Phase F: Display title comes from
      // local GRDB cache populated by MLSConversationManager+Metadata.
      name: nil,
      participants: participantVMs,
      lastMessagePreview: nil,
      lastMessageTimestamp: nil,
      unreadCount: unreadCount,
      isGroupChat: participants.count > 2,
      groupId: coordinates.groupId.data.hexEncodedString()
    )
  }
}

// MARK: - Server Model Lexicon Compatibility

extension BlueCatbirdChatDefs.ConversationState {
  var conversationId: String { coordinates.conversationId }
  var groupId: String { coordinates.groupId.data.map { String(format: "%02x", $0) }.joined() }
  var epoch: Int { coordinates.epoch }
  var resetGeneration: Int { coordinates.generation }
  var members: [BlueCatbirdChatDefs.ParticipantView] { participants }
}

extension BlueCatbirdChatDefs.ParticipantView {
  var did: DID { userDid }
  var isAdmin: Bool { role == .value_admin }
}

public enum ApplicationEntryError: Error, LocalizedError, Sendable {
  case unexpectedBodyVariant(entryId: String, conversationId: String)

  public var errorDescription: String? {
    switch self {
    case .unexpectedBodyVariant(let entryId, let conversationId):
      return "Application entry \(entryId) in conversation \(conversationId) contains an unexpected or malformed body variant and cannot be processed safely."
    }
  }
}

extension BlueCatbirdChatDefs.ApplicationEntry {
  var id: String { entryId }
  var convoId: String { conversationId }
  var createdAt: ATProtocolDate { receivedAt }

  var parsedBody: BlueCatbirdChatDefs.ApplicationSendBody? {
    guard case let .blueCatbirdChatDefsApplicationSendBody(body) = signedRequest.body else {
      return nil
    }
    return body
  }

  /// Strict epoch extraction: returns the epoch if the entry has a valid ApplicationSendBody, nil otherwise.
  /// Consuming call sites must not fabricate an epoch for unexpected variants.
  var epoch: Int? {
    parsedBody?.prior.epoch
  }

  /// Strict ciphertext extraction: returns the ciphertext if the entry has a valid ApplicationSendBody, nil otherwise.
  /// Consuming call sites must not fabricate empty ciphertext for unexpected variants.
  var ciphertext: Data? {
    parsedBody?.applicationMessage.bytes.data
  }

  /// Sender DID from the signed request body, or nil if unparseable.
  var senderDID: String? {
    parsedBody?.actorDid.description
  }

  /// Throws if the body is unknown or malformed (fail closed).
  func requireApplicationBody() throws -> BlueCatbirdChatDefs.ApplicationSendBody {
    guard let parsedBody else {
      throw ApplicationEntryError.unexpectedBodyVariant(entryId: entryId, conversationId: conversationId)
    }
    return parsedBody
  }
}

extension MLSCredentialBinding {
  /// Compares DID roots between sender identity and account DID.
  /// Follows `catbird-mls/src/orchestrator/messaging.rs`:
  /// DID method-specific identifiers are case-sensitive. Fails closed (returns false)
  /// if either root is empty.
  static func isSameAccount(_ senderIdentity: String, as accountDID: String) -> Bool {
    let senderRoot = credentialRootDID(senderIdentity)
    let accountRoot = credentialRootDID(accountDID)
    guard !senderRoot.isEmpty, !accountRoot.isEmpty else {
      return false
    }
    return senderRoot == accountRoot
  }

  /// Convenience for optional account DID; returns false if account DID is nil or empty.
  static func isSameAccount(_ senderIdentity: String, as accountDID: String?) -> Bool {
    guard let accountDID else { return false }
    return isSameAccount(senderIdentity, as: accountDID)
  }
}
