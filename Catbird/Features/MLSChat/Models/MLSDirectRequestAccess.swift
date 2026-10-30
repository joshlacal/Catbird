import CatbirdMLSCore

/// Host effects require a positively classified legacy conversation or a
/// verified accepted request. A missing local request row grants no access.
@MainActor
enum MLSDirectRequestAccess {
  static func allowsOrdinaryEffects(manager: MLSConversationManager, conversationID: String) async throws -> Bool {
    switch try await manager.classifyDirectRequestConversation(conversationId: conversationID) {
    case .legacyV1:
      let pending = try await manager.fetchPendingRequestConversations()
      return !pending.contains { $0.conversationID == conversationID }
    case .verifiedRequest:
      let views = try await manager.listDirectRequestViews()
      guard let view = views.first(where: { $0.conversationId == conversationID }) else { return false }
      return view.consent == .accepted && view.capabilities.canSend
    case .requestAwaitingProjection, .unknown:
      return false
    }
  }
}
