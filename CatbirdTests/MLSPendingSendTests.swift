import Testing
import Foundation
@testable import Catbird
@testable import CatbirdMLSCore

// WS-6.5: optimistic pending/failed send bookkeeping in the unified MLS data
// source. Uses a data source with no AppState/database — the pending overlay
// is pure in-memory state.
@MainActor
@Suite("MLSPendingSend")
struct MLSPendingSendTests {

  private func makeDataSource() -> MLSConversationDataSource {
    MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil
    )
  }

  @Test func beginPendingSendAppearsInMessagesAsSending() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "hello", embed: nil)

    #expect(id.hasPrefix(PendingMLSSend.idPrefix))
    #expect(dataSource.pendingSends.count == 1)

    let adapter = dataSource.messages.first { $0.id == id }
    #expect(adapter != nil)
    #expect(adapter?.text == "hello")
    #expect(adapter?.sendState == .sending)
    #expect(adapter?.isFromCurrentUser == true)
  }

  @Test func failPendingSendTransitionsToFailedWithReason() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "hello", embed: nil)

    dataSource.failPendingSend(id: id, reason: "server unreachable")

    let adapter = dataSource.messages.first { $0.id == id }
    #expect(adapter?.sendState == .failed("server unreachable"))
  }

  @Test func completePendingSendRemovesEntry() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "hello", embed: nil)

    dataSource.completePendingSend(id: id)

    #expect(dataSource.pendingSends.isEmpty)
    #expect(dataSource.messages.first { $0.id == id } == nil)
  }

  @Test func takeFailedPendingSendReturnsContentOnlyWhenFailed() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "retry me", embed: nil)

    // Still sending: retry must be a no-op.
    #expect(dataSource.takeFailedPendingSend(id: id) == nil)
    #expect(dataSource.pendingSends.count == 1)

    dataSource.failPendingSend(id: id, reason: "boom")
    let taken = dataSource.takeFailedPendingSend(id: id)

    #expect(taken?.text == "retry me")
    #expect(dataSource.pendingSends.isEmpty)

    // Taking twice returns nil.
    #expect(dataSource.takeFailedPendingSend(id: id) == nil)
  }

  @Test func failPendingSendWithUnknownIdIsNoOp() {
    let dataSource = makeDataSource()
    dataSource.failPendingSend(id: "pending:nope", reason: "boom")
    #expect(dataSource.pendingSends.isEmpty)
  }

  @Test func pendingEntriesAppendAfterConfirmedMessages() {
    let dataSource = makeDataSource()
    let first = dataSource.beginPendingSend(text: "one", embed: nil)
    let second = dataSource.beginPendingSend(text: "two", embed: nil)

    let ids = dataSource.messages.map(\.id)
    #expect(ids == [first, second])
  }

  @Test func recoveryStateDefaultsToHealthyAndDoesNotBlock() {
    let dataSource = makeDataSource()
    #expect(dataSource.conversationRecoveryState == .healthy)
    #expect(dataSource.isSendBlockedByRecovery == false)
  }
}
