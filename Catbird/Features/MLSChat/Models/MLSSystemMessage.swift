//
//  MLSSystemMessage.swift
//  Catbird
//
//  MLS system message types for membership changes and group events
//

import Foundation
import Petrel

#if os(iOS)

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

  /// Create a system message from an InfoEvent
  static func from(infoEvent: BlueCatbirdMlsStreamConvoEvents.InfoEvent, conversationId: String) -> MLSSystemMessage {
    return MLSSystemMessage(
      id: infoEvent.cursor,
      conversationId: conversationId,
      type: .infoMessage,
      timestamp: Date(),
      actorDID: nil,
      targetDID: nil,
      infoText: infoEvent.info
    )
  }

  /// Create a system message from a NewDeviceEvent
  static func from(deviceEvent: BlueCatbirdMlsStreamConvoEvents.NewDeviceEvent) -> MLSSystemMessage {
    return MLSSystemMessage(
      id: deviceEvent.cursor,
      conversationId: deviceEvent.convoId,
      type: .deviceAdded,
      timestamp: Date(),
      actorDID: nil,
      targetDID: deviceEvent.userDid.description,
      infoText: deviceEvent.deviceName
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
    let actorName = actorDID.flatMap { did -> String? in
      if did == currentUserDID {
        return "You"
      }
      return profiles[did]?.displayName ?? profiles[did]?.handle ?? shortDID(did)
    }

    let targetName = targetDID.flatMap { did -> String? in
      if did == currentUserDID {
        return "you"
      }
      return profiles[did]?.displayName ?? profiles[did]?.handle ?? shortDID(did)
    }

    switch type {
    case .memberJoined:
      if let target = targetName {
        return "\(target) joined the conversation"
      }
      return "A member joined the conversation"

    case .memberLeft:
      if let target = targetName {
        return "\(target) left the conversation"
      }
      return "A member left the conversation"

    case .memberKicked, .memberRemoved:
      // Simplified: Always show as "left" regardless of reason
      if let target = targetName {
        return "\(target) left"
      }
      return "A member left"

    case .epochRotated:
      return "Security keys were updated"

    case .groupCreated:
      if let actor = actorName {
        return "\(actor) created this conversation"
      }
      return "Conversation created"

    case .adminPromoted:
      if let target = targetName, let actor = actorName {
        return "\(actor) promoted \(target) to admin"
      } else if let target = targetName {
        return "\(target) was promoted to admin"
      }
      return "A member was promoted to admin"

    case .deviceAdded:
      if let target = targetName {
        let deviceInfo = infoText.map { " (\($0))" } ?? ""
        return "\(target) added a new device\(deviceInfo)"
      }
      return "A new device was added"

    case .infoMessage:
      return infoText ?? "System message"
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
    case .infoMessage:
      return "info.circle"
    }
  }
}

#endif
