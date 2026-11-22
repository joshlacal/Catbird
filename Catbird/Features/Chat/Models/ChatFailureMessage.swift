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
      return String(
        localized: "This device is waiting to be added to your encrypted chats.",
        comment: "Error when the current device is awaiting multi-device onboarding approval"
      )
    case .InvalidState(let message) where message.contains("ConversationNotAccepted"):
      return String(
        localized: "This chat is waiting to be accepted. You can send messages once it is.",
        comment: "Error when attempting to send into an unaccepted chat request"
      )
    default:
      return nil
    }
  }
}
