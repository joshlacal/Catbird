import Observation
import Petrel

/// Lightweight coordinator that exposes the accepted Bluesky DM conversations
/// as a single list sorted by most recent activity. Does not own the data
/// source — ChatTabView feeds it from `appState.chatManager`.
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
    conversations = blueskyConversations
      .map { UnifiedConversation.bluesky($0) }
      .sorted { $0.lastActivityDate > $1.lastActivityDate }
  }
}
