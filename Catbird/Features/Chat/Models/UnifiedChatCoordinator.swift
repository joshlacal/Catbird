import Observation
import Petrel

/// Lightweight coordinator that exposes the accepted Bluesky DM conversations
/// as a single list in the server's most-recent-activity order (ChatManager
/// keeps that order and moves a conversation to the top after a send). Does
/// not own the data source — ChatTabView feeds it from `appState.chatManager`.
@Observable
final class UnifiedChatCoordinator {
  private(set) var conversations: [UnifiedConversation] = []

  /// Set by ChatTabView from `appState.chatManager.acceptedConversations`
  var blueskyConversations: [ChatBskyConvoDefs.ConvoView] = [] {
    didSet { recompute() }
  }

  func reset() {
    blueskyConversations = []
    conversations = []
  }

  private func recompute() {
    // No client-side re-sort: last-message dates miss system events and
    // deleted messages, which would sink active groups below stale chats.
    conversations = blueskyConversations.map { UnifiedConversation.bluesky($0) }
  }
}
