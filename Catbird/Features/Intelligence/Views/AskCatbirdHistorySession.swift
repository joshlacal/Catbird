import Foundation

/// Sheet-scoped history work. Every store boundary validates the captured session
/// before a result can reach the visible conversation or its history menu.
@MainActor
final class AskCatbirdHistorySession {
  struct Identity: Equatable {
    let accountDID: String
    let context: CopilotContext
    let conversationID: UUID
    let generation = UUID()
  }

  struct Store {
    var conversations: (String) async throws -> [CopilotConversation]
    var save: (CopilotConversation) async throws -> Void
    var delete: (UUID, String) async throws -> Void
    var clear: (String) async -> Void

    static var live: Self {
      Self(
        conversations: { try await CopilotHistoryStore.shared.conversations(for: $0) },
        save: { try await CopilotHistoryStore.shared.save($0) },
        delete: { try await CopilotHistoryStore.shared.delete(conversationID: $0, accountDID: $1) },
        clear: { await CopilotHistoryStore.shared.clear(accountDID: $0) }
      )
    }
  }

  enum Operation {
    case load
    case save(CopilotConversation, isMigration: Bool)
    case delete
    case clear

    var failurePrefix: String {
      switch self {
      case .load: "Failed to load history"
      case .save(_, let migration): migration ? "Failed to migrate conversation" : "Failed to save conversation"
      case .delete: "Failed to delete conversation"
      case .clear: "Failed to clear history"
      }
    }
  }

  enum Outcome {
    case loaded([CopilotConversation], resetConversation: Bool)
    case failed(String)
  }

  private(set) var current: Identity?

  func activate(accountDID: String, context: CopilotContext, conversationID: UUID) {
    current = Identity(accountDID: accountDID, context: context, conversationID: conversationID)
  }

  func invalidate() { current = nil }

  func isCurrent(_ identity: Identity, activeAccountDID: String) -> Bool {
    !Task.isCancelled && current == identity && activeAccountDID == identity.accountDID
  }

  func perform(
    _ operation: Operation, identity: Identity, store: Store,
    activeAccountDID: () -> String
  ) async -> Outcome? {
    guard isCurrent(identity, activeAccountDID: activeAccountDID()) else { return nil }
    do {
      switch operation {
      case .load: break
      case .save(let conversation, _):
        guard conversation.accountDID == identity.accountDID,
          conversation.id == identity.conversationID, conversation.context == identity.context else { return nil }
        try await store.save(conversation)
      case .delete:
        try await store.delete(identity.conversationID, identity.accountDID)
      case .clear:
        await store.clear(identity.accountDID)
      }
      guard isCurrent(identity, activeAccountDID: activeAccountDID()) else { return nil }
      if case .clear = operation { return .loaded([], resetConversation: true) }
      let all = try await store.conversations(identity.accountDID)
      guard isCurrent(identity, activeAccountDID: activeAccountDID()) else { return nil }
      let matching = all.filter {
        $0.accountDID == identity.accountDID && $0.context.matchesHistoryContext(identity.context)
      }
      let shouldReset: Bool
      if case .delete = operation { shouldReset = true } else { shouldReset = false }
      return .loaded(matching, resetConversation: shouldReset)
    } catch {
      guard isCurrent(identity, activeAccountDID: activeAccountDID()) else { return nil }
      return .failed("\(operation.failurePrefix): \(error.localizedDescription)")
    }
  }
}
