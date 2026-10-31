import Foundation
import Testing
@testable import Catbird

@MainActor
struct AskCatbirdHistorySessionTests {
  private let account = "did:plc:fixture-a"
  private let context = CopilotContext.thread(anchorURI: "at://did:plc:a/app.bsky.feed.post/a")

  @Test("A suspended migration cannot publish history or an error into a replaced context")
  func migrationContextReplacement() async throws {
    for shouldFail in [false, true] {
      let session = makeSession()
      let identity = try #require(session.current)
      let gate = Suspension()
      var reads: [String] = []
      let store = AskCatbirdHistorySession.Store(
        conversations: { reads.append($0); return [] },
        save: { _ in try await gate.wait() }, delete: { _, _ in }, clear: { _ in })
      let conversation = CopilotConversation(id: identity.conversationID, accountDID: account, context: context)
      let task = Task { await session.perform(.save(conversation, isMigration: true), identity: identity,
        store: store, activeAccountDID: { account }) }
      await gate.waitUntilSuspended()
      session.activate(accountDID: account, context: .search(query: "replacement"), conversationID: UUID())
      gate.resume(failing: shouldFail)
      expectSuppressed(await task.value)
      #expect(reads.isEmpty, "A stale migration must not even start a history read for the replacement context")
    }
  }

  @Test("A suspended deletion cannot reset a replacement account or conversation")
  func deletionAccountReplacement() async throws {
    let session = makeSession()
    let identity = try #require(session.current)
    let gate = Suspension()
    var activeAccount = account
    var mutations: [String] = []
    var reads: [String] = []
    let store = AskCatbirdHistorySession.Store(conversations: { reads.append($0); return [] }, save: { _ in },
      delete: { id, did in mutations.append("\(did)/\(id)"); try await gate.wait() }, clear: { _ in })
    let task = Task { await session.perform(.delete, identity: identity, store: store,
      activeAccountDID: { activeAccount }) }
    await gate.waitUntilSuspended()
    activeAccount = "did:plc:fixture-b"
    session.activate(accountDID: activeAccount, context: context, conversationID: UUID())
    gate.resume()
    expectSuppressed(await task.value)
    #expect(mutations == ["\(account)/\(identity.conversationID)"])
    #expect(reads.isEmpty)
  }

  @Test("The second suspension in migration and deletion is also guarded")
  func staleHistoryRead() async throws {
    for delete in [false, true] {
      let session = makeSession()
      let identity = try #require(session.current)
      let gate = Suspension()
      var reads: [String] = []
      let old = CopilotConversation(id: identity.conversationID, accountDID: account, context: context)
      let store = AskCatbirdHistorySession.Store(
        conversations: { did in reads.append(did); try await gate.wait(); return [old] },
        save: { _ in }, delete: { _, _ in }, clear: { _ in })
      let operation: AskCatbirdHistorySession.Operation = delete ? .delete : .save(old, isMigration: true)
      let task = Task { await session.perform(operation, identity: identity, store: store,
        activeAccountDID: { account }) }
      await gate.waitUntilSuspended()
      session.activate(accountDID: account, context: context, conversationID: UUID())
      gate.resume()
      expectSuppressed(await task.value)
      #expect(reads == [account], "Store reads must use the captured account, never replacement state")
    }
  }

  @Test("Cancellation suppresses a successful save and a delayed load failure")
  func cancelledCompletions() async throws {
    for saving in [false, true] {
      let session = makeSession()
      let identity = try #require(session.current)
      let gate = Suspension()
      let old = CopilotConversation(id: identity.conversationID, accountDID: account, context: context)
      let store = AskCatbirdHistorySession.Store(conversations: { _ in
        if !saving { try await gate.wait() }; return []
      }, save: { _ in try await gate.wait() }, delete: { _, _ in }, clear: { _ in })
      let operation: AskCatbirdHistorySession.Operation = saving ? .save(old, isMigration: false) : .load
      let task = Task { await session.perform(operation, identity: identity, store: store,
        activeAccountDID: { account }) }
      await gate.waitUntilSuspended()
      task.cancel()
      gate.resume(failing: !saving)
      expectSuppressed(await task.value)
    }
  }

  @Test("Clear cannot reset a new conversation after its store suspension")
  func staleClear() async throws {
    let session = makeSession()
    let identity = try #require(session.current)
    let gate = Suspension()
    let store = AskCatbirdHistorySession.Store(conversations: { _ in [] }, save: { _ in },
      delete: { _, _ in }, clear: { _ in try? await gate.wait() })
    let task = Task { await session.perform(.clear, identity: identity, store: store,
      activeAccountDID: { account }) }
    await gate.waitUntilSuspended()
    session.activate(accountDID: account, context: context, conversationID: UUID())
    gate.resume()
    expectSuppressed(await task.value)
  }

  @Test("A current deletion publishes only matching history and requests one reset")
  func currentDeletion() async throws {
    let session = makeSession()
    let identity = try #require(session.current)
    let matching = CopilotConversation(accountDID: account, context: context)
    let foreign = CopilotConversation(accountDID: "did:plc:b", context: context)
    let store = AskCatbirdHistorySession.Store(conversations: { _ in [matching, foreign] },
      save: { _ in }, delete: { _, _ in }, clear: { _ in })
    let outcome = await session.perform(.delete, identity: identity, store: store, activeAccountDID: { account })
    guard case .loaded(let conversations, let reset) = outcome else {
      Issue.record("Current deletion did not produce its publication"); return
    }
    #expect(conversations.map(\.id) == [matching.id])
    #expect(reset)
  }

  private func makeSession() -> AskCatbirdHistorySession {
    let session = AskCatbirdHistorySession()
    session.activate(accountDID: account, context: context, conversationID: UUID())
    return session
  }

  private func expectSuppressed(_ outcome: AskCatbirdHistorySession.Outcome?) {
    if case nil = outcome {} else { Issue.record("Stale operation returned a UI publication or reset") }
  }

  @MainActor
  private final class Suspension {
    enum Failure: Error { case expected }
    private var pending: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws {
      try await withCheckedThrowingContinuation { continuation in
        pending = continuation
        started?.resume()
        started = nil
      }
    }
    func waitUntilSuspended() async {
      if pending != nil { return }
      await withCheckedContinuation { started = $0 }
    }
    func resume(failing: Bool = false) {
      if failing { pending?.resume(throwing: Failure.expected) } else { pending?.resume() }
      pending = nil
    }
  }
}
