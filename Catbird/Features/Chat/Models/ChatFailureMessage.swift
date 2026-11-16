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
      return "Check your connection and try again."
    }
    if let validation = error as? MLSDirectComposeDraftStore.Failure, validation == .invalidText {
      return "Write a message of up to 1,000 characters."
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
    case .startEncryptedChat: return "Couldn’t start the encrypted chat. Try again."
    case .createEncryptedGroup: return "Couldn’t create the encrypted group. Try again."
    case .retryEncryptedGroup: return "Couldn’t finish setting up the group. Try again."
    case .cancelEncryptedGroup: return "Couldn’t cancel setting up the group. Try again."
    }
  }

  private static func text(for error: MlsError) -> String? {
    switch error {
    case .InsufficientPermissions, .RosterUnverified:
      return "Someone in this chat can’t use encrypted chat yet."
    case .GroupCreationPending:
      return "This chat is still being set up. Catbird will keep trying."
    case .GroupCreationNeedsUserAction:
      return "This chat needs your attention before it can be set up. Check Settings > Chat."
    case .GroupCreationRejected:
      return "This chat couldn’t be set up."
    case .ContextNotInitialized, .ContextClosed, .InvalidContext:
      return "Encrypted chat isn’t ready on this device yet. Try again in a moment."
    case .PendingDeviceAccess:
      return "This device is waiting to be added to your encrypted chats."
    default:
      return nil
    }
  }
}
