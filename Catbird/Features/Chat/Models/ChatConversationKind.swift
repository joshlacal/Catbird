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
    case .encrypted: return "Encrypted chat"
    case .bluesky: return "Bluesky DM"
    }
  }

  var optionDetail: String {
    switch self {
    case .encrypted: return "End-to-end encrypted. Only the people in the chat can read it."
    case .bluesky: return "A direct message on Bluesky."
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
    case .encrypted: return "Encrypted chat"
    case .bluesky: return "Bluesky DM"
    }
  }

  var infoDetail: String {
    switch self {
    case .encrypted: return "Messages are end-to-end encrypted. Only the people in this chat can read them."
    case .bluesky: return "A direct message conversation on Bluesky."
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
