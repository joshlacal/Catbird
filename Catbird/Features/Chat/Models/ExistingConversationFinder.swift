import CatbirdMLSCore
import Foundation
import Petrel

/// Reads, without creating anything, the conversations this account already has with a person.
@MainActor
enum ExistingConversationFinder {
  /// The most recently active one-to-one encrypted chat with `peerDID`, found by membership.
  static func encryptedDirect(with peerDID: String, appState: AppState) async -> ExistingDirectConversation? {
    guard appState.isMLSRuntimeAllowed,
          let coordinator = await appState.getOrOpenMLSCoordinator(),
          let rows = try? await coordinator.listConversations(limit: 100)
    else { return nil }
    var candidates: [MLSDirectConversationLookup.Candidate] = []
    for row in rows {
      guard !Task.isCancelled else { return nil }
      guard let members = try? await coordinator.listMembers(conversationId: row.conversationId) else {
        continue
      }
      candidates.append(MLSDirectConversationLookup.Candidate(
        conversationID: row.conversationId,
        memberDIDs: members,
        lastActivity: Date(timeIntervalSince1970: TimeInterval(row.updatedAtMs) / 1000)
      ))
    }
    return MLSDirectConversationLookup.mostRecent(with: peerDID, selfDID: appState.userDID, in: candidates)
  }

  /// The Bluesky DM with `peerDID`, as a routing candidate.
  static func blueskyDirect(_ convo: ChatBskyConvoDefs.ConvoView?) -> ExistingDirectConversation? {
    guard let convo else { return nil }
    return ExistingDirectConversation(
      kind: .bluesky, id: convo.id, lastActivity: UnifiedConversation.bluesky(convo).lastActivityDate)
  }

  /// Shows an encrypted chat again if this account had deleted it for itself.
  static func revealIfHidden(_ conversationID: String, accountDID: String) {
    MLSDeletedForMe(accountDID: accountDID).reveal(conversationID)
  }
}
