import CatbirdMLSCore
import Foundation
import GRDB
import Testing
@testable import Catbird

@Suite("Direct recipient drafts")
@MainActor
struct MLSNewConversationViewModelTests {
  @Test("selection creates only local state and reuses the same account-scoped ID")
  func selectionDoesNotCreateRemoteConversation() async throws {
    let database = try DatabaseQueue()
    let first = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: database)
    let second = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: database)
    let otherAccount = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:carol", recipientDID: "did:plc:bob", database: database)
    #expect(first.id == second.id)
    #expect(first.id != otherAccount.id)
    #expect(first.conversationID == nil)
    #expect(!first.submitted)
    let tables = try await database.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
    #expect(tables == ["app_direct_compose_drafts"])
  }

  @Test("draft and handoff survive reopening without sharing another account's text")
  func durableReopenAndIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("drafts.sqlite").path
    var database: DatabaseQueue? = try DatabaseQueue(path: path)
    var draft = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: try #require(database))
    draft.text = "Hello, Bob"
    try await MLSDirectComposeDraftStore.requestPresentation(draft, database: try #require(database))
    try database?.close()
    database = nil
    let reopened = try DatabaseQueue(path: path)
    let restored = try await MLSDirectComposeDraftStore.pendingPresentation(accountDID: "did:plc:alice", database: reopened)
    let other = try await MLSDirectComposeDraftStore.pendingPresentation(accountDID: "did:plc:carol", database: reopened)
    #expect(restored == draft)
    #expect(other == nil)
    try await MLSDirectComposeDraftStore.clearPresentation(accountDID: "did:plc:alice", database: reopened)
    let saved = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: reopened)
    #expect(saved.text == "Hello, Bob")
  }

  @Test("ambiguous submitted intent cannot be rewritten or assigned another ID")
  func immutableSubmittedInput() async throws {
    let database = try DatabaseQueue()
    var draft = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: database)
    draft.text = "Exact saved introduction"
    draft.submitted = true
    try await MLSDirectComposeDraftStore.save(draft, database: database)
    let retry = try await MLSDirectComposeDraftStore.open(accountDID: draft.accountDID, recipientDID: draft.recipientDID, database: database)
    #expect(retry == draft)
    draft.text = "Different introduction"
    await #expect(throws: MLSDirectComposeDraftStore.Failure.self) {
      try await MLSDirectComposeDraftStore.save(draft, database: database)
    }
    let unchanged = try await MLSDirectComposeDraftStore.open(accountDID: draft.accountDID, recipientDID: draft.recipientDID, database: database)
    #expect(unchanged.text == "Exact saved introduction")
  }

  @Test("archiving a cancelled draft creates a fresh identity without deleting retained text")
  func cancellationPreservesOriginalDraft() async throws {
    let database = try DatabaseQueue()
    var first = try await MLSDirectComposeDraftStore.open(accountDID: "did:plc:alice", recipientDID: "did:plc:bob", database: database)
    first.text = "Saved before cancellation"
    first.submitted = true
    try await MLSDirectComposeDraftStore.save(first, database: database)
    try await MLSDirectComposeDraftStore.archive(first, database: database)
    let next = try await MLSDirectComposeDraftStore.open(accountDID: first.accountDID, recipientDID: first.recipientDID, database: database)
    #expect(next.id != first.id)
    #expect(!next.submitted)
    let retained = try await database.read { db in
      try Data.fetchOne(db, sql: "SELECT payload FROM app_direct_compose_drafts WHERE id = ? AND archived = 1", arguments: [first.id.uuidString])
    }
    #expect(try JSONDecoder().decode(MLSDirectComposeDraft.self, from: #require(retained)) == first)
  }

  @Test("invitation notes retain exact reference and uncertain attempt across reopen")
  func invitationNoteCustody() async throws {
    let database = try DatabaseQueue()
    let owner = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    let reference = try MLSGroupInvitationReference(authorityDid: "did:web:chat.catbird.blue",
      conversationId: "00000000-0000-4000-8000-000000000011",
      invitationTransitionId: "00000000-0000-4000-8000-000000000012",
      invitedByDid: owner, invitedByDeviceId: "00000000-0000-4000-8000-000000000013",
      recipientDid: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb")
    var note = try await MLSDirectComposeDraftStore.invitationDraft(accountDID: owner, reference: reference, database: database)
    note.text = "A separate note"
    note.submitted = true
    note.noteAttempted = true
    try await MLSDirectComposeDraftStore.save(note, database: database)
    let restored = try await MLSDirectComposeDraftStore.invitationDraft(accountDID: owner, reference: reference, database: database)
    #expect(restored == note)
    #expect(restored.noteAttempted == true)
    let ordinary = try await MLSDirectComposeDraftStore.open(accountDID: owner, recipientDID: reference.recipientDid, database: database)
    #expect(ordinary.invitation == nil)
    #expect(ordinary.id != note.id)
    note.noteAttempted = false
    await #expect(throws: MLSDirectComposeDraftStore.Failure.self) { try await MLSDirectComposeDraftStore.save(note, database: database) }
    let saved = try await MLSDirectComposeDraftStore.savedInvitationNotes(accountDID: owner, database: database)
    #expect(saved == [restored])
    let other = try await MLSDirectComposeDraftStore.savedInvitationNotes(accountDID: reference.recipientDid, database: database)
    #expect(other.isEmpty)
  }

  @Test("unresolved and pending consent never dispatch message actions")
  func consentBlocksOrdinaryEffects() async {
    var edits = 0
    var unsends = 0
    let actions = MLSMessageActionPerformer(edit: { _, _, _ in edits += 1 }, unsend: { _, _ in unsends += 1 })
    let source = MLSConversationDataSource(conversationId: "conversation", currentUserDID: "did:plc:alice", appState: nil, actionPerformer: actions)
    source.ingestConfirmedMessageForTesting(MLSMessageAdapter(id: "message", text: "Saved", senderDID: "did:plc:alice", currentUserDID: "did:plc:alice", sentAt: Date()))
    #expect(source.isSendBlockedByRecovery)
    #expect(await source.editMessage(messageID: "message", newText: "Changed") == false)
    await source.unsendMessage(messageID: "message")
    source.setActionConsentForTesting(resolved: true, pending: true)
    #expect(source.isSendBlockedByRecovery)
    #expect(await source.editMessage(messageID: "message", newText: "Changed") == false)
    await source.unsendMessage(messageID: "message")
    #expect(edits == 0 && unsends == 0)
    #expect(source.messages.count == 1)
  }

  @Test("notification cache is account scoped, expires, and never restores an older pending preview")
  func notificationPreviewBoundaries() async throws {
    let database = try DatabaseQueue()
    func view(_ consent: RequestConsent, version: UInt64) -> DirectRequestView {
      DirectRequestView(introduction: nil, conversationId: "conversation", firstMessageId: "first-message",
        consent: consent, crypto: .ready, preview: .ready(text: "Private introduction", invitation: nil),
        capabilities: RequestCapabilities(canPreview: true, canAccept: consent == .incomingPending,
          canClose: consent != .closed, canSend: false, canEmitReceipts: false, canAdminister: false),
        stateVersion: version, generation: 1)
    }
    let account = "did:plc:alice"
    try await MLSRequestNotificationPreviewCache.project(view(.incomingPending, version: 1), accountDID: account, database: database)
    let cached = try await database.read { db in
      try String.fetchOne(db, sql: "SELECT text FROM app_direct_request_notification_preview WHERE account_did = ? AND conversation_id = ? AND message_id = ? AND expires_at >= ?", arguments: [account, "conversation", "first-message", Date().timeIntervalSince1970])
    }
    #expect(cached == "Private introduction")
    let anotherAccount = try await database.read { db in
      try String.fetchOne(db, sql: "SELECT text FROM app_direct_request_notification_preview WHERE account_did = ?", arguments: ["did:plc:bob"])
    }
    #expect(anotherAccount == nil)
    try await database.write { db in
      try db.execute(sql: "UPDATE app_direct_request_notification_preview SET expires_at = ?", arguments: [Date().addingTimeInterval(-1).timeIntervalSince1970])
    }
    let expired = try await database.read { db in
      try String.fetchOne(db, sql: "SELECT text FROM app_direct_request_notification_preview WHERE expires_at >= ?", arguments: [Date().timeIntervalSince1970])
    }
    #expect(expired == nil)
    try await MLSRequestNotificationPreviewCache.project(view(.closed, version: 2), accountDID: account, database: database)
    try await MLSRequestNotificationPreviewCache.project(view(.incomingPending, version: 1), accountDID: account, database: database)
    let closed = try await database.read { db in try String.fetchOne(db, sql: "SELECT text FROM app_direct_request_notification_preview") }
    #expect(closed == nil)
  }

  @Test("text bounds count UTF8 bytes and reject empty input before submission")
  func exactTextBound() throws {
    try MLSDirectComposeDraftStore.validateText(String(repeating: "a", count: 16_384))
    #expect(throws: MLSDirectComposeDraftStore.Failure.self) { try MLSDirectComposeDraftStore.validateText(String(repeating: "a", count: 16_385)) }
    #expect(throws: MLSDirectComposeDraftStore.Failure.self) { try MLSDirectComposeDraftStore.validateText(" \n ") }
    #expect(throws: MLSDirectComposeDraftStore.Failure.self) { try MLSDirectComposeDraftStore.validateText(String(repeating: "🙂", count: 4097)) }
  }
}
