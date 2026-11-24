import CatbirdMLSCore
//
//  MLSSystemMessage.swift
//  Catbird
//
//  MLS system message types for membership changes and group events
//

import Foundation
import Petrel
import PetrelCatbird

/// Type of system message for MLS conversation events
enum SystemMessageType: String, Codable, Sendable {
  case memberJoined = "member_joined"
  case memberLeft = "member_left"
  case memberKicked = "member_kicked"
  case memberRemoved = "member_removed"
  case epochRotated = "epoch_rotated"
  case groupCreated = "group_created"
  case adminPromoted = "admin_promoted"
  case deviceAdded = "device_added"
  case groupReset = "group_reset"
  case infoMessage = "info_message"
}

/// System message for MLS conversation events (membership changes, etc.)
struct MLSSystemMessage: Identifiable, Sendable {
  /// Unique identifier for this system message
  let id: String

  /// Conversation ID
  let conversationId: String

  /// Type of system event
  let type: SystemMessageType

  /// When the event occurred
  let timestamp: Date

  /// DID of the actor who performed the action (if applicable)
  let actorDID: String?

  /// DID of the target user affected by the action (if applicable)
  let targetDID: String?

  /// Additional info message
  let infoText: String?

  init(
    id: String,
    conversationId: String,
    type: SystemMessageType,
    timestamp: Date,
    actorDID: String? = nil,
    targetDID: String? = nil,
    infoText: String? = nil
  ) {
    self.id = id
    self.conversationId = conversationId
    self.type = type
    self.timestamp = timestamp
    self.actorDID = actorDID
    self.targetDID = targetDID
    self.infoText = infoText
  }

  /// Create a system message from a ResetRequestedEvent
  static func from(resetRequestedEvent: BlueCatbirdChatDefs.ResetRequestedEvent) -> MLSSystemMessage {
    return MLSSystemMessage(
      id: resetRequestedEvent.resetRequestId,
      conversationId: resetRequestedEvent.conversationId,
      type: .groupReset,
      timestamp: Date(),
      actorDID: nil,
      targetDID: nil,
      infoText: String(localized: "Encryption was reset", comment: "System message when conversation encryption keys are reset")
    )
  }
}

/// Extension for generating display text for system messages
extension MLSSystemMessage {
  /// Generate display text with profile enrichment
  func displayText(
    profiles: [String: MLSProfileEnricher.ProfileData],
    currentUserDID: String
  ) -> String {
    let actorIsCurrentUser = actorDID == currentUserDID && !currentUserDID.isEmpty
    let targetIsCurrentUser = targetDID == currentUserDID && !currentUserDID.isEmpty

    let actorDisplayName = actorDID.map { did in
      profiles[did]?.displayName ?? profiles[did]?.handle ?? shortDID(did)
    }
    let targetDisplayName = targetDID.map { did in
      profiles[did]?.displayName ?? profiles[did]?.handle ?? shortDID(did)
    }

    switch type {
    case .memberJoined:
      if targetIsCurrentUser {
        return String(localized: "You joined the conversation", comment: "System message when the current user joins a conversation")
      } else if let target = targetDisplayName {
        return String(localized: "\(target) joined the conversation", comment: "System message when a member joins a conversation. %@ is the member's name.")
      }
      return String(localized: "A member joined the conversation", comment: "System message when an unnamed member joins a conversation")

    case .memberLeft:
      if targetIsCurrentUser {
        return String(localized: "You left the conversation")
      } else if let target = targetDisplayName {
        return String(localized: "\(target) left the conversation", comment: "System message when a member leaves a conversation. %@ is the member's name.")
      }
      return String(localized: "A member left the conversation", comment: "System message when an unnamed member leaves a conversation")

    case .memberKicked, .memberRemoved:
      if targetIsCurrentUser {
        return String(localized: "You left", comment: "System message when the current user leaves or is removed from a conversation")
      } else if let target = targetDisplayName {
        return String(localized: "\(target) left", comment: "System message when a member leaves or is removed from a conversation. %@ is the member's name.")
      }
      return String(localized: "A member left", comment: "System message when an unnamed member leaves or is removed")

    case .epochRotated:
      return String(localized: "Security keys were updated", comment: "System message when MLS epoch encryption keys rotate")

    case .groupCreated:
      if actorIsCurrentUser {
        return String(localized: "You created this conversation", comment: "System message when the current user created the conversation")
      } else if let actor = actorDisplayName {
        return String(localized: "\(actor) created this conversation", comment: "System message when another member created the conversation. %@ is the creator's name.")
      }
      return String(localized: "Conversation created", comment: "System message when a conversation is created")

    case .adminPromoted:
      if actorIsCurrentUser, let target = targetDisplayName {
        return String(localized: "You promoted \(target) to admin", comment: "System message when the current user promotes a member to admin. %@ is the promoted member's name.")
      } else if targetIsCurrentUser, let actor = actorDisplayName {
        return String(localized: "\(actor) promoted you to admin", comment: "System message when another member promotes the current user to admin. %@ is the actor's name.")
      } else if targetIsCurrentUser {
        return String(localized: "You were promoted to admin", comment: "System message when the current user is promoted to admin")
      } else if let target = targetDisplayName, let actor = actorDisplayName {
        return String(localized: "\(actor) promoted \(target) to admin", comment: "System message when one member promotes another to admin. %1$@ is the actor's name, %2$@ is the target's name.")
      } else if let target = targetDisplayName {
        return String(localized: "\(target) was promoted to admin", comment: "System message when a member is promoted to admin. %@ is the member's name.")
      }
      return String(localized: "A member was promoted to admin", comment: "System message when an unnamed member is promoted to admin")

    case .deviceAdded:
      if targetIsCurrentUser {
        if let infoText, !infoText.isEmpty {
          return String(localized: "You added a new device (\(infoText))", comment: "System message when the current user adds a named device. %@ is the device name.")
        }
        return String(localized: "You added a new device", comment: "System message when the current user adds a new device")
      } else if let target = targetDisplayName {
        if let infoText, !infoText.isEmpty {
          return String(localized: "\(target) added a new device (\(infoText))", comment: "System message when a member adds a named device. %1$@ is the member's name, %2$@ is the device name.")
        }
        return String(localized: "\(target) added a new device", comment: "System message when a member adds a new device. %@ is the member's name.")
      }
      return String(localized: "A new device was added", comment: "System message when a new device is added to the conversation")

    case .groupReset:
      if actorIsCurrentUser {
        if let infoText, !infoText.isEmpty {
          return String(localized: "You reset the encryption for this conversation (\(infoText))", comment: "System message when the current user resets group encryption with a reason. %@ is the reason.")
        }
        return String(localized: "You reset the encryption for this conversation", comment: "System message when the current user resets group encryption")
      } else if let actor = actorDisplayName {
        if let infoText, !infoText.isEmpty {
          return String(localized: "\(actor) reset the encryption for this conversation (\(infoText))", comment: "System message when a member resets group encryption with a reason. %1$@ is the member's name, %2$@ is the reason.")
        }
        return String(localized: "\(actor) reset the encryption for this conversation", comment: "System message when a member resets group encryption. %@ is the member's name.")
      }
      return String(localized: "Encryption was reset for this conversation", comment: "System message when conversation encryption is reset")

    case .infoMessage:
      return infoText ?? String(localized: "System message", comment: "Fallback label for a chat system event")
    }
  }

  /// Extract short DID for display (last 8 characters)
  private func shortDID(_ did: String) -> String {
    let components = did.split(separator: ":")
    if let last = components.last, last.count > 8 {
      return String(last.suffix(8))
    }
    return String(did.suffix(8))
  }

  /// System message icon
  var iconName: String {
    switch type {
    case .memberJoined:
      return "person.badge.plus"
    case .memberLeft:
      return "person.badge.minus"
    case .memberKicked, .memberRemoved:
      return "person.crop.circle.badge.xmark"
    case .epochRotated:
      return "lock.rotation"
    case .groupCreated:
      return "bubble.left.and.bubble.right"
    case .adminPromoted:
      return "star.circle"
    case .deviceAdded:
      return "laptopcomputer.and.iphone"
    case .groupReset:
      return "arrow.triangle.2.circlepath.circle"
    case .infoMessage:
      return "info.circle"
    }
  }
}
