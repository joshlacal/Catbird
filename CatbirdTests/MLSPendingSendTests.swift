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

  private enum ActionFailure: Error {
    case rejected
  }

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

  @Test func completePendingSendKeepsEntryVisibleAsSentUntilConfirmedArrives() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "hello", embed: nil)

    // Server confirmed, but the confirmed row hasn't landed via observation
    // yet: the bubble must stay visible (no gap frame) with the clock cleared.
    dataSource.completePendingSend(id: id, realMessageID: "msg-real-1")

    #expect(dataSource.pendingSends.count == 1)
    let adapter = dataSource.messages.first { $0.id == id }
    #expect(adapter != nil)
    #expect(adapter?.sendState == .sent)
  }

  @Test func confirmedAdapterTakesOverPendingDiffableIdentity() {
    let dataSource = makeDataSource()
    let id = dataSource.beginPendingSend(text: "hello", embed: nil)
    dataSource.completePendingSend(id: id, realMessageID: "msg-real-2")

    // Simulate the confirmed row arriving (what buildAdapters produces).
    dataSource.ingestConfirmedMessageForTesting(
      MLSMessageAdapter(
        id: "msg-real-2",
        text: "hello",
        senderDID: "did:plc:tester",
        currentUserDID: "did:plc:tester",
        sentAt: Date(),
        sendState: .sent,
        diffableID: id
      )
    )

    // Exactly one visible message: same diffable identity, real API identity.
    let visible = dataSource.messages
    #expect(visible.count == 1)
    #expect(visible.first?.diffableID == id)
    #expect(visible.first?.id == "msg-real-2")
    #expect(dataSource.pendingSends.isEmpty)
    // The collection-view identity resolves back to the real message.
    #expect(dataSource.message(for: id)?.id == "msg-real-2")
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

  @Test func onlyCurrentUserMessageExposesEditAndUnsendCapabilities() {
    let own = MLSMessageAdapter(
      id: "own",
      text: "hello",
      senderDID: "did:plc:tester",
      currentUserDID: "did:plc:tester",
      sentAt: Date()
    )
    let remote = MLSMessageAdapter(
      id: "remote",
      text: "hello",
      senderDID: "did:plc:remote",
      currentUserDID: "did:plc:tester",
      sentAt: Date()
    )

    #expect(own.canEdit == true)
    #expect(own.canUnsend == true)
    #expect(remote.canEdit == false)
    #expect(remote.canUnsend == false)
  }

  @Test func acknowledgedPendingMessageDoesNotExposeServerActionsBeforeHandoff() {
    let dataSource = makeDataSource()
    let pendingID = dataSource.beginPendingSend(text: "hello", embed: nil)

    dataSource.completePendingSend(id: pendingID, realMessageID: "msg-real")

    let acknowledgedPending = dataSource.message(for: pendingID)
    #expect(acknowledgedPending?.sendState == .sent)
    #expect(acknowledgedPending?.canEdit == false)
    #expect(acknowledgedPending?.canUnsend == false)
  }

  @Test func editDispatchesTheResolvedExactMessageID() async {
    var dispatched: (conversationID: String, messageID: String, text: String)?
    let actions = MLSMessageActionPerformer(
      edit: { conversationID, messageID, text in
        dispatched = (conversationID, messageID, text)
      },
      unsend: { _, _ in }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    dataSource.ingestConfirmedMessageForTesting(
      MLSMessageAdapter(
        id: "msg-real",
        text: "before",
        senderDID: "did:plc:tester",
        currentUserDID: "did:plc:tester",
        sentAt: Date(),
        diffableID: "pending:stable"
      )
    )

    await dataSource.editMessage(messageID: "pending:stable", newText: "  after  ")

    #expect(dispatched?.conversationID == "convo-1")
    #expect(dispatched?.messageID == "msg-real")
    #expect(dispatched?.text == "after")
  }

  @Test func failedEditReturnsFailureAndKeepsTheEditSessionText() async {
    let actions = MLSMessageActionPerformer(
      edit: { _, _, _ in throw ActionFailure.rejected },
      unsend: { _, _ in }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    let message = MLSMessageAdapter(
      id: "msg-real",
      text: "retry this edit",
      senderDID: "did:plc:tester",
      currentUserDID: "did:plc:tester",
      sentAt: Date()
    )
    dataSource.ingestConfirmedMessageForTesting(message)
    var editSession = MLSMessageEditSession()
    editSession.begin(message)

    let succeeded = await dataSource.editMessage(
      messageID: message.id,
      newText: "retry this edit"
    )
    editSession.finish(succeeded: succeeded)

    #expect(succeeded == false)
    #expect(editSession.message?.id == message.id)
    #expect(editSession.message?.text == "retry this edit")
  }

  @Test func successfulEditClearsTheEditSession() async {
    let actions = MLSMessageActionPerformer(
      edit: { _, _, _ in },
      unsend: { _, _ in }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    let message = MLSMessageAdapter(
      id: "msg-real",
      text: "before",
      senderDID: "did:plc:tester",
      currentUserDID: "did:plc:tester",
      sentAt: Date()
    )
    dataSource.ingestConfirmedMessageForTesting(message)
    var editSession = MLSMessageEditSession()
    editSession.begin(message)

    let succeeded = await dataSource.editMessage(
      messageID: message.id,
      newText: "after"
    )
    editSession.finish(succeeded: succeeded)

    #expect(succeeded == true)
    #expect(editSession.message == nil)
  }

  @Test func remoteMessageCannotDispatchEditOrUnsend() async {
    var editCount = 0
    var unsendCount = 0
    let actions = MLSMessageActionPerformer(
      edit: { _, _, _ in editCount += 1 },
      unsend: { _, _ in unsendCount += 1 }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    dataSource.ingestConfirmedMessageForTesting(
      MLSMessageAdapter(
        id: "remote",
        text: "not mine",
        senderDID: "did:plc:remote",
        currentUserDID: "did:plc:tester",
        sentAt: Date()
      )
    )

    await dataSource.editMessage(messageID: "remote", newText: "no")
    await dataSource.unsendMessage(messageID: "remote")

    #expect(editCount == 0)
    #expect(unsendCount == 0)
  }

  @Test func successfulUnsendDispatchesExactIDAndRemovesTheRow() async {
    var dispatched: (conversationID: String, messageID: String)?
    let actions = MLSMessageActionPerformer(
      edit: { _, _, _ in },
      unsend: { conversationID, messageID in
        dispatched = (conversationID, messageID)
      }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    dataSource.ingestConfirmedMessageForTesting(
      MLSMessageAdapter(
        id: "msg-real",
        text: "remove me",
        senderDID: "did:plc:tester",
        currentUserDID: "did:plc:tester",
        sentAt: Date(),
        diffableID: "pending:stable"
      )
    )

    await dataSource.unsendMessage(messageID: "pending:stable")

    #expect(dispatched?.conversationID == "convo-1")
    #expect(dispatched?.messageID == "msg-real")
    #expect(dataSource.messages.isEmpty)
  }
}
