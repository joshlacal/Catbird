import Foundation
import Petrel

extension ChatBskyConvoDefs.ConvoView {
  var groupMetadata: ChatBskyConvoDefs.GroupConvo? {
    guard let kind else { return nil }

    switch kind {
    case .chatBskyConvoDefsGroupConvo(let group):
      return group
    case .chatBskyConvoDefsDirectConvo, .unexpected:
      return nil
    }
  }

  var isGroupConversation: Bool {
    groupMetadata != nil || members.count > 2
  }

  var isLockedForSending: Bool {
    guard let lockStatus = groupMetadata?.lockStatus else { return false }
    return lockStatus.rawValue != ChatBskyConvoDefs.ConvoLockStatus.unlocked.rawValue
  }

  /// The current user's group member role, when this is a group conversation
  /// and the roster includes them.
  func currentUserMemberRole(currentUserDID: String) -> ChatBskyActorDefs.MemberRole? {
    guard !currentUserDID.isEmpty,
          let member = members.first(where: { $0.did.didString() == currentUserDID }),
          case .chatBskyActorDefsGroupConvoMember(let groupMember) = member.kind else {
      return nil
    }
    return groupMember.role
  }

  /// Whether the current user owns this group conversation. Owners must lock
  /// the group before leaving (`OwnerCannotLeave` on chat.bsky.convo.leaveConvo).
  func isOwnedGroupConversation(currentUserDID: String) -> Bool {
    guard groupMetadata != nil else { return false }
    return currentUserMemberRole(currentUserDID: currentUserDID)?.rawValue
      == ChatBskyActorDefs.MemberRole.owner.rawValue
  }

  func displayMembersExcludingCurrentUser(currentUserDID: String) -> [ChatBskyActorDefs.ProfileViewBasic] {
    guard !currentUserDID.isEmpty else { return members }
    return members.filter { $0.did.didString() != currentUserDID }
  }

  func directDisplayMember(currentUserDID: String) -> ChatBskyActorDefs.ProfileViewBasic? {
    if !currentUserDID.isEmpty,
       let member = members.first(where: { $0.did.didString() != currentUserDID }) {
      return member
    }

    return members.first
  }

  /// Primary member of this conversation for reporting and safety attribution
  func primaryMember(currentUserDID: String) -> ChatBskyActorDefs.ProfileViewBasic? {
    if !isGroupConversation {
      return directDisplayMember(currentUserDID: currentUserDID)
    }

    // Group chat: check owner first
    if let owner = members.first(where: { member in
      if case .chatBskyActorDefsGroupConvoMember(let gm) = member.kind,
         gm.role.rawValue == ChatBskyActorDefs.MemberRole.owner.rawValue {
        return true
      }
      return false
    }) {
      return owner
    }

    // Otherwise first non-self member
    let otherMembers = displayMembersExcludingCurrentUser(currentUserDID: currentUserDID)
    return otherMembers.first ?? members.first
  }
  func displayTitle(currentUserDID: String) -> String {
    if let groupMetadata {
      let groupName = groupMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return groupName.isEmpty ? "Group Chat" : groupName
    }

    if isGroupConversation {
      let names = displayMembersExcludingCurrentUser(currentUserDID: currentUserDID)
        .map { $0.chatDisplayName }
        .filter { !$0.isEmpty }

      guard !names.isEmpty else { return "Group Chat" }

      if names.count <= 2 {
        return names.joined(separator: ", ")
      }

      return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) other\(names.count == 3 ? "" : "s")"
    }

    guard let member = directDisplayMember(currentUserDID: currentUserDID) else {
      return "Chat"
    }

    if member.isDeletedBlueskyChatAccount {
      return "Deleted Account"
    }

    return member.chatDisplayName.isEmpty ? "Chat" : member.chatDisplayName
  }

  func displaySubtitle(currentUserDID: String) -> String? {
    if let groupMetadata {
      let count = groupMetadata.memberCount
      return "\(count) member\(count == 1 ? "" : "s")"
    }

    if isGroupConversation {
      let count = members.count
      return "\(count) member\(count == 1 ? "" : "s")"
    }

    guard let member = directDisplayMember(currentUserDID: currentUserDID),
          !member.isDeletedBlueskyChatAccount else {
      return nil
    }

    guard let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !displayName.isEmpty else {
      return nil
    }

    return "@\(member.handle.description)"
  }

  /// Share-picker search: matches the group name and ALL non-self member
  /// names/handles (the legacy picker only matched the first member).
  func matchesShareSearch(_ query: String, currentUserDID: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }

    if displayTitle(currentUserDID: currentUserDID)
      .localizedCaseInsensitiveContains(trimmed) {
      return true
    }

    return displayMembersExcludingCurrentUser(currentUserDID: currentUserDID)
      .contains { member in
        member.chatDisplayName.localizedCaseInsensitiveContains(trimmed)
          || member.handle.description.localizedCaseInsensitiveContains(trimmed)
      }
  }

  /// Moderation block state for this conversation.
  /// For a direct chat: checks if the other member has `blocking`, `blockingByList`, or `blockedBy`.
  /// For a group chat: checks if the current user blocks the group owner/primary member (non-owner blocks do not suppress group composer).
  func moderationBlockState(currentUserDID: String) -> BlueskyConversationBlockState {
    if !isGroupConversation {
      guard let member = directDisplayMember(currentUserDID: currentUserDID),
            let viewer = member.viewer else {
        return .none
      }

      if viewer.blocking != nil {
        return .directBlock(
          did: member.did.didString(),
          handle: member.handle.description,
          displayName: member.displayName
        )
      } else if let list = viewer.blockingByList {
        return .listBlock(
          did: member.did.didString(),
          handle: member.handle.description,
          displayName: member.displayName,
          list: list
        )
      } else if viewer.blockedBy == true {
        return .blockedBy(
          did: member.did.didString(),
          handle: member.handle.description,
          displayName: member.displayName
        )
      }
      return .none
    } else {
      // Group chat: check if current user has blocked the group owner / primary member
      guard let primary = primaryMember(currentUserDID: currentUserDID),
            let viewer = primary.viewer else {
        return .none
      }

      if viewer.blocking != nil {
        return .directBlock(
          did: primary.did.didString(),
          handle: primary.handle.description,
          displayName: primary.displayName
        )
      } else if let list = viewer.blockingByList {
        return .listBlock(
          did: primary.did.didString(),
          handle: primary.handle.description,
          displayName: primary.displayName,
          list: list
        )
      }
      return .none
    }
  }
}

extension ChatBskyActorDefs.ProfileViewBasic {
  var isDeletedBlueskyChatAccount: Bool {
    handle.description == "missing.invalid"
  }

  var chatDisplayName: String {
    if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !displayName.isEmpty {
      return displayName
    }

    guard !isDeletedBlueskyChatAccount else { return "Deleted Account" }
    return "@\(handle.description)"
  }
}

enum BlueskyConversationBlockState: Equatable, Sendable {
  case none
  case directBlock(did: String, handle: String, displayName: String?)
  case listBlock(did: String, handle: String, displayName: String?, list: AppBskyGraphDefs.ListViewBasic)
  case blockedBy(did: String, handle: String, displayName: String?)

  var isBlocked: Bool {
    self != .none
  }
}

