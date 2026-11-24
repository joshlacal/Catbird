import CatbirdMLSCore
import Foundation

/// The two kinds of conversation in the one inbox. A conversation is one kind for its whole
/// life: nothing converts a Bluesky DM into an encrypted chat or back, and both kinds with
/// the same person can exist side by side.
enum ChatConversationKind: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
  /// An end-to-end encrypted (MLS) chat.
  case encrypted
  /// A Bluesky direct message (`chat.bsky`).
  case bluesky

  var id: String { rawValue }

  /// Encrypted chats carry a lock in the inbox row and the thread header; Bluesky DMs do not.
  var showsLock: Bool { self == .encrypted }

  /// The name of the kind where the user picks one.
  var optionTitle: String {
    switch self {
    case .encrypted:
      return String(localized: "Encrypted chat", comment: "Option title for starting an end-to-end encrypted chat")
    case .bluesky:
      return String(localized: "Bluesky DM", comment: "Option title for starting a Bluesky direct message")
    }
  }

  var optionDetail: String {
    switch self {
    case .encrypted:
      return String(
        localized: "End-to-end encrypted. Only the people in the chat can read it.",
        comment: "Description for the encrypted chat option when starting a conversation"
      )
    case .bluesky:
      return String(
        localized: "A direct message on Bluesky.",
        comment: "Description for the Bluesky DM option when starting a conversation"
      )
    }
  }

  var optionSystemImage: String {
    switch self {
    case .encrypted: return "lock.fill"
    case .bluesky: return "bubble.left.and.bubble.right"
    }
  }

  /// The conversation type as the thread info screen states it.
  var infoTitle: String {
    switch self {
    case .encrypted:
      return String(localized: "Encrypted chat", comment: "Conversation type label on the thread info screen")
    case .bluesky:
      return String(localized: "Bluesky DM", comment: "Conversation type label on the thread info screen")
    }
  }

  var infoDetail: String {
    switch self {
    case .encrypted:
      return String(
        localized: "Messages are end-to-end encrypted. Only the people in this chat can read them.",
        comment: "Conversation type explanation for encrypted chats on the thread info screen"
      )
    case .bluesky:
      return String(
        localized: "A direct message conversation on Bluesky.",
        comment: "Conversation type explanation for Bluesky DMs on the thread info screen"
      )
    }
  }
}

/// A person a new conversation is being started with.
struct NewConversationRecipient: Equatable, Hashable, Sendable, Identifiable {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: URL?

  var id: String { did }

  var participant: MLSParticipantViewModel {
    MLSParticipantViewModel(id: did, handle: handle, displayName: displayName, avatarURL: avatarURL)
  }
}

extension NewConversationRecipient {
  init(profile: any ProfileDisplayable) {
    self.init(
      did: profile.did.didString(),
      handle: profile.handle.description,
      displayName: profile.displayName,
      avatarURL: profile.finalAvatarURL()
    )
  }
}
