import CatbirdMLSCore
import Foundation

/// What the user was doing when a chat operation failed.
enum ChatFailureContext: Sendable {
  case startEncryptedChat
  case createEncryptedGroup
  case retryEncryptedGroup
  case cancelEncryptedGroup
}

/// The one place a chat failure becomes text for the user. Error descriptions from the
/// encrypted chat engine are never shown; each failure maps to a plain sentence.
enum ChatFailureMessage {
  static func text(for error: Error, context: ChatFailureContext) -> String {
    if let mlsError = error as? MlsError {
      return text(for: mlsError) ?? generic(for: context)
    }
    if error is URLError {
      return String(
        localized: "Check your connection and try again.",
        comment: "Error message when a chat operation fails due to network connectivity"
      )
    }
    if let validation = error as? MLSDirectComposeDraftStore.Failure, validation == .invalidText {
      return String(
        localized: "Write a message of up to 1,000 characters.",
        comment: "Validation message when the opening encrypted chat message is empty or exceeds 1,000 characters"
      )
    }
    return generic(for: context)
  }

  /// Text for a person whose encrypted chat capability is not `.capable`, or nil.
  static func text(for capability: MLSChatCapability) -> String? {
    switch capability {
    case .capable: return nil
    case .incapable: return NewConversationKindModel.incapableNotice
    case .unknown: return NewConversationKindModel.unknownNotice
    }
  }

  private static func generic(for context: ChatFailureContext) -> String {
    switch context {
    case .startEncryptedChat:
      return String(
        localized: "Couldn’t start the encrypted chat. Try again.",
        comment: "Generic error when starting a one-to-one encrypted chat fails"
      )
    case .createEncryptedGroup:
      return String(
        localized: "Couldn’t create the encrypted group. Try again.",
        comment: "Generic error when creating an encrypted group chat fails"
      )
    case .retryEncryptedGroup:
      return String(
        localized: "Couldn’t finish setting up the group. Try again.",
        comment: "Generic error when retrying pending encrypted group creation fails"
      )
    case .cancelEncryptedGroup:
      return String(
        localized: "Couldn’t cancel setting up the group. Try again.",
        comment: "Generic error when cancelling pending encrypted group creation fails"
      )
    }
  }

  private static func text(for error: MlsError) -> String? {
    switch error {
    case .InsufficientPermissions, .RosterUnverified:
      return String(
        localized: "Someone in this chat can’t use encrypted chat yet.",
        comment: "Error when one or more participants lack verified encrypted chat capability"
      )
    case .GroupCreationPending:
      return String(
        localized: "This chat is still being set up. Catbird will keep trying.",
        comment: "Status message when encrypted group setup is still in progress"
      )
    case .GroupCreationNeedsUserAction:
      return String(
        localized: "This chat needs your attention before it can be set up. Check Settings > Chat.",
        comment: "Error when encrypted group setup requires user action in Chat settings"
      )
    case .GroupCreationRejected:
      return String(
        localized: "This chat couldn’t be set up.",
        comment: "Error when encrypted group setup is rejected"
      )
    case .ContextNotInitialized, .ContextClosed, .InvalidContext:
      return String(
        localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.",
        comment: "Error when the local encrypted chat engine is not initialized yet"
      )
    case .PendingDeviceAccess:
      return pendingDeviceText
    case .InvalidState(let message) where message.contains("ConversationNotAccepted"):
      return String(
        localized: "This chat is waiting to be accepted. You can send messages once it is.",
        comment: "Error when attempting to send into an unaccepted chat request"
      )
    case .InvalidState(let message):
      return serviceRefusalCode(in: message).flatMap { text(forServiceCode: $0) }
    default:
      return nil
    }
  }

  /// Shown when this device has enrolled but another of the account's devices has not
  /// approved it yet. The delivery service refuses every chat this device tries to start.
  static var pendingDeviceText: String {
    String(
      localized: "This device is waiting for approval. On a device that already has your encrypted chats, open Settings > Devices and approve it.",
      comment: "Error when the current device is awaiting approval from another of the account's devices before it can use encrypted chat"
    )
  }

  /// The delivery service's refusal code inside an engine `InvalidState` message.
  ///
  /// The engine passes the service's error name through as the whole message, for example
  /// `Invalid state: RecipientKeysUnavailable`. Anything that is not a single identifier is
  /// engine detail, not a service code.
  static func serviceRefusalCode(in message: String) -> String? {
    var code = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = code.range(of: "Invalid state:") {
      code = String(code[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let first = code.first, first.isUppercase,
          code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
      return nil
    }
    return code
  }

  /// Text for a delivery service refusal code, or nil for one the user can do nothing about.
  static func text(forServiceCode code: String) -> String? {
    switch code {
    case "DevicePendingApproval":
      return pendingDeviceText
    case "NotAuthorized":
      return String(
        localized: "This device isn’t allowed to start encrypted chats yet. Check Settings > Devices.",
        comment: "Error when the encrypted chat service refuses this device, usually because it has not been approved yet"
      )
    case "DeviceRevoked":
      return String(
        localized: "This device was removed from your encrypted chats.",
        comment: "Error when the current device was revoked from the account's encrypted chat devices"
      )
    case "DeviceNotRegistered":
      return String(
        localized: "This device isn’t set up for encrypted chat yet. Try again in a moment.",
        comment: "Error when the current device is not registered with the encrypted chat service"
      )
    case "AccountSessionExpired":
      return String(
        localized: "Your session expired. Sign in again to use encrypted chat.",
        comment: "Error when the account session used for encrypted chat has expired"
      )
    case "AccountTakedown":
      return String(
        localized: "This account can’t use encrypted chat.",
        comment: "Error when the account was taken down by moderators and cannot use encrypted chat"
      )
    case "RecipientKeysUnavailable":
      return String(
        localized: "This person’s encrypted chat isn’t reachable right now. Try again later.",
        comment: "Error when the recipient has no device ready to receive a new encrypted chat"
      )
    case "RequestPolicyDenied":
      return String(
        localized: "This person isn’t accepting encrypted chat requests from you.",
        comment: "Error when the recipient's message settings refuse a new encrypted chat request"
      )
    case "RecipientAuthorityUnsupported":
      return String(
        localized: "This person’s encrypted chat server can’t take requests from yours yet.",
        comment: "Error when the recipient's encrypted chat home server is not supported"
      )
    case "ExistingDirect":
      return String(
        localized: "You already have an encrypted chat with this person.",
        comment: "Error when a one-to-one encrypted chat with this person already exists"
      )
    case "CapacityUnavailable", "RateLimited":
      return String(
        localized: "Encrypted chat is busy right now. Try again in a moment.",
        comment: "Error when the encrypted chat service is temporarily unavailable or rate limiting"
      )
    case "CutoverRequired", "ProtocolUpgradeRequired":
      return String(
        localized: "Encrypted chat requests aren’t available right now. Update Catbird or try again later.",
        comment: "Error when the encrypted chat service is not accepting new chat requests or needs a newer app"
      )
    default:
      return nil
    }
  }
}
