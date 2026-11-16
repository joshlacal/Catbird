import Foundation

/// An existing conversation with one person.
struct ExistingDirectConversation: Equatable, Sendable {
  let kind: ChatConversationKind
  let id: String
  let lastActivity: Date
}

/// Where a "Message" entry point goes.
enum ChatEntryDestination: Equatable, Sendable {
  case bluesky(convoID: String)
  case encrypted(conversationID: String)
  /// No conversation with this person yet: the new conversation screen, with them picked.
  case newConversation(NewConversationRecipient)
}

enum ChatEntryRouter {
  /// Opens the existing conversation with the person, the most recently active one when both
  /// kinds exist; otherwise the new conversation screen with the person picked. Never creates
  /// a conversation.
  static func destination(
    for recipient: NewConversationRecipient,
    bluesky: ExistingDirectConversation?,
    encrypted: ExistingDirectConversation?
  ) -> ChatEntryDestination {
    // A tie opens the encrypted chat. The caller still has to pick a kind when
    // neither kind exists; routing never creates one on its own.
    let latest: ExistingDirectConversation?
    switch (encrypted, bluesky) {
    case (let encrypted?, let bluesky?):
      latest = encrypted.lastActivity >= bluesky.lastActivity ? encrypted : bluesky
    case (let encrypted?, nil):
      latest = encrypted
    case (nil, let bluesky?):
      latest = bluesky
    case (nil, nil):
      latest = nil
    }
    guard let latest else {
      return .newConversation(recipient)
    }
    switch latest.kind {
    case .encrypted: return .encrypted(conversationID: latest.id)
    case .bluesky: return .bluesky(convoID: latest.id)
    }
  }
}

/// Finds the existing one-to-one encrypted chat with a person from conversation memberships.
enum MLSDirectConversationLookup {
  struct Candidate: Equatable, Sendable {
    let conversationID: String
    let memberDIDs: [String]
    let lastActivity: Date
  }

  /// The most recently active conversation whose members, apart from this account, are
  /// exactly `peerDID`.
  static func mostRecent(
    with peerDID: String, selfDID: String, in candidates: [Candidate]
  ) -> ExistingDirectConversation? {
    let peer = peerDID.lowercased()
    let me = selfDID.lowercased()
    guard peer != me else { return nil }
    return candidates
      .filter { candidate in
        let members = Set(candidate.memberDIDs.map { $0.lowercased() })
        return members.count == 2 && members.contains(me) && members.contains(peer)
      }
      .max(by: { $0.lastActivity < $1.lastActivity })
      .map { ExistingDirectConversation(kind: .encrypted, id: $0.conversationID, lastActivity: $0.lastActivity) }
  }
}

/// Whether an encrypted group can be created with the picked people. Every member must be
/// able to use encrypted chat; nothing is changed or dropped automatically.
enum EncryptedGroupMembership {
  struct Evaluation: Equatable, Sendable {
    /// Picked people whose records say they cannot use encrypted chat yet.
    let notCapable: [String]
    /// Picked people whose capability is not known (still checking, or the check failed).
    let unchecked: [String]
    let hasSelection: Bool

    var canContinue: Bool { hasSelection && notCapable.isEmpty && unchecked.isEmpty }
  }

  static func evaluate(
    selected: [String], capabilities: [String: MLSChatCapabilityStatus]
  ) -> Evaluation {
    var notCapable: [String] = []
    var unchecked: [String] = []
    for did in selected {
      switch capabilities[did] {
      case .capable: continue
      case .incapable: notCapable.append(did)
      case .unknown, .none: unchecked.append(did)
      }
    }
    return Evaluation(notCapable: notCapable, unchecked: unchecked, hasSelection: !selected.isEmpty)
  }
}

/// A capability answer without its reason, as the people picker keeps it.
enum MLSChatCapabilityStatus: Equatable, Sendable {
  case capable
  case incapable
  case unknown
}
