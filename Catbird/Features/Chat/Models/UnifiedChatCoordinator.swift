import CatbirdMLSCore
import Observation
import Petrel

/// Lightweight merge coordinator that combines Bluesky DM and MLS conversation lists
/// into a single array. Bluesky conversations keep the server's most-recent-activity
/// order (ChatManager keeps that order and moves a conversation to the top after a
/// send); MLS conversations are interleaved by their latest activity. Does not own
/// either data source — ChatTabView feeds it from `appState.chatManager` and MLS polling.
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

  func reset() {
    blueskyConversations = []
    mlsState = .init()
    mlsEnabled = false
    conversations = []
  }

  private func recompute() {
    // Bluesky conversations are not re-sorted client-side: last-message dates miss
    // system events and deleted messages, which would sink active groups below
    // stale chats. MLS conversations are merged in around that order by activity.
    let bsky = blueskyConversations.map { UnifiedConversation.bluesky($0) }

    guard mlsEnabled, !mlsState.conversations.isEmpty else {
      conversations = bsky
      return
    }

    let mls = mlsState.conversations.map { convo in
      UnifiedConversation.mls(
        conversation: convo,
        participants: mlsState.participants[convo.conversationID] ?? [],
        unreadCount: mlsState.unreadCounts[convo.conversationID] ?? 0,
        lastMessage: mlsState.lastMessages[convo.conversationID],
        memberChange: mlsState.memberChanges[convo.conversationID],
        lastActivityDate: mlsState.latestActivity[convo.conversationID] ?? convo.createdAt
      )
    }
    .sorted { $0.lastActivityDate > $1.lastActivityDate }

    var merged: [UnifiedConversation] = []
    merged.reserveCapacity(bsky.count + mls.count)
    var mlsIndex = mls.startIndex
    for convo in bsky {
      while mlsIndex < mls.endIndex, mls[mlsIndex].lastActivityDate > convo.lastActivityDate {
        merged.append(mls[mlsIndex])
        mlsIndex += 1
      }
      merged.append(convo)
    }
    merged.append(contentsOf: mls[mlsIndex...])
    conversations = merged
  }
}
