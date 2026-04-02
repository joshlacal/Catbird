import CatbirdMLSCore
import Observation
import Petrel

/// Lightweight merge coordinator that combines Bluesky DM and MLS conversation lists
/// into a single sorted array. Does not own either data source — just merges their outputs.
@Observable
final class UnifiedChatCoordinator {
  private(set) var conversations: [UnifiedConversation] = []

  /// Set by ChatTabView from `appState.chatManager.acceptedConversations`
  var blueskyConversations: [ChatBskyConvoDefs.ConvoView] = [] {
    didSet { recompute() }
  }

  /// Set by ChatTabView after MLS polling builds a complete state struct
  var mlsState: MLSConversationListState = .init() {
    didSet { recompute() }
  }

  /// Whether MLS is enabled for the current account. When false, only Bluesky convos appear.
  var mlsEnabled: Bool = false {
    didSet { recompute() }
  }

  private func recompute() {
    let bsky = blueskyConversations.map { UnifiedConversation.bluesky($0) }

    let mls: [UnifiedConversation]
    if mlsEnabled {
      mls = mlsState.conversations.map { convo in
        UnifiedConversation.mls(
          conversation: convo,
          participants: mlsState.participants[convo.conversationID] ?? [],
          unreadCount: mlsState.unreadCounts[convo.conversationID] ?? 0,
          lastMessage: mlsState.lastMessages[convo.conversationID],
          memberChange: mlsState.memberChanges[convo.conversationID],
          lastActivityDate: mlsState.latestActivity[convo.conversationID] ?? convo.createdAt
        )
      }
    } else {
      mls = []
    }

    conversations = (bsky + mls).sorted { $0.lastActivityDate > $1.lastActivityDate }
  }
}
