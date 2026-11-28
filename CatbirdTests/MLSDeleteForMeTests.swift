import Foundation
import Testing
@testable import Catbird
@testable import CatbirdMLSCore

/// "Delete for Me" on an MLS chat erases the message from this account only. The data source
/// dispatches the exact server message ID to the native erase and drops every in-memory copy.
@MainActor
@Suite("MLSDeleteForMe")
struct MLSDeleteForMeTests {
  private enum ActionFailure: Error {
    case rejected
  }

  private final class Recorder {
    var deleteForMe: [(conversationID: String, messageID: String)] = []
    var unsend: [(conversationID: String, messageID: String)] = []
  }

  private func makeDataSource(
    recorder: Recorder,
    deleteForMeFails: Bool = false
  ) -> MLSConversationDataSource {
    let actions = MLSMessageActionPerformer(
      edit: { _, _, _ in },
      unsend: { conversationID, messageID in
        recorder.unsend.append((conversationID, messageID))
      },
      deleteForMe: { conversationID, messageID in
        if deleteForMeFails { throw ActionFailure.rejected }
        recorder.deleteForMe.append((conversationID, messageID))
      }
    )
    let dataSource = MLSConversationDataSource(
      conversationId: "convo-1",
      currentUserDID: "did:plc:tester",
      appState: nil,
      actionPerformer: actions
    )
    dataSource.setActionConsentForTesting(resolved: true, pending: false)
    return dataSource
  }

  private func message(
    id: String,
    sender: String,
    diffableID: String? = nil,
    isSystemMessage: Bool = false,
    sendState: MessageSendState = .sent
  ) -> MLSMessageAdapter {
    MLSMessageAdapter(
      id: id,
      text: "text of \(id)",
      senderDID: sender,
      currentUserDID: "did:plc:tester",
      sentAt: Date(),
      isSystemMessage: isSystemMessage,
      sendState: sendState,
      diffableID: diffableID
    )
  }

  @Test func deletingAPeerMessageDispatchesExactIDAndRemovesOnlyThatRow() async {
    let recorder = Recorder()
    let dataSource = makeDataSource(recorder: recorder)
    dataSource.ingestConfirmedMessageForTesting(message(id: "peer-1", sender: "did:plc:remote"))
    dataSource.ingestConfirmedMessageForTesting(message(id: "peer-2", sender: "did:plc:remote"))

    await dataSource.deleteMessageForMe(messageID: "peer-1")

    #expect(recorder.deleteForMe.count == 1)
    #expect(recorder.deleteForMe.first?.conversationID == "convo-1")
    #expect(recorder.deleteForMe.first?.messageID == "peer-1")
    #expect(recorder.unsend.isEmpty, "Delete for Me must never unsend for everyone")
    #expect(dataSource.message(for: "peer-1") == nil)
    #expect(dataSource.message(for: "peer-2") != nil)
  }

  @Test func deletingAnOwnMessageResolvesItsPendingIdentity() async {
    let recorder = Recorder()
    let dataSource = makeDataSource(recorder: recorder)
    dataSource.ingestConfirmedMessageForTesting(
      message(id: "msg-real", sender: "did:plc:tester", diffableID: "pending:stable")
    )

    await dataSource.deleteMessageForMe(messageID: "pending:stable")

    #expect(recorder.deleteForMe.first?.messageID == "msg-real")
    #expect(recorder.unsend.isEmpty)
    #expect(dataSource.messages.isEmpty)
  }

  @Test func failedDeleteKeepsTheRow() async {
    let recorder = Recorder()
    let dataSource = makeDataSource(recorder: recorder, deleteForMeFails: true)
    dataSource.ingestConfirmedMessageForTesting(message(id: "peer-1", sender: "did:plc:remote"))

    await dataSource.deleteMessageForMe(messageID: "peer-1")

    #expect(dataSource.message(for: "peer-1") != nil)
    #expect(dataSource.error != nil)
  }

  @Test func systemAndUnconfirmedRowsAreNeverDispatched() async {
    let recorder = Recorder()
    let dataSource = makeDataSource(recorder: recorder)
    dataSource.ingestConfirmedMessageForTesting(
      message(id: "system", sender: "did:plc:remote", isSystemMessage: true)
    )
    dataSource.ingestConfirmedMessageForTesting(
      message(id: "failed", sender: "did:plc:tester", sendState: .failed("send failed"))
    )

    await dataSource.deleteMessageForMe(messageID: "system")
    await dataSource.deleteMessageForMe(messageID: "failed")
    await dataSource.deleteMessageForMe(messageID: "missing")

    #expect(recorder.deleteForMe.isEmpty)
    #expect(dataSource.message(for: "system") != nil)
    #expect(dataSource.message(for: "failed") != nil)
  }

  @Test func deleteForMeIsAllowedWhileTheConversationCannotSend() async {
    let recorder = Recorder()
    let dataSource = makeDataSource(recorder: recorder)
    dataSource.setActionConsentForTesting(resolved: false, pending: true)
    dataSource.ingestConfirmedMessageForTesting(message(id: "peer-1", sender: "did:plc:remote"))

    await dataSource.deleteMessageForMe(messageID: "peer-1")

    #expect(recorder.deleteForMe.map(\.messageID) == ["peer-1"])
    #expect(dataSource.message(for: "peer-1") == nil)
  }

  @Test func confirmedMLSMessagesOfferDeleteForMeBesideUnsend() {
    let callbacks = ChatMessageMenuCallbacks(canReply: true, canDelete: true, canReport: true)
    let own = message(id: "own", sender: "did:plc:tester")
    let peer = message(id: "peer", sender: "did:plc:remote")

    let ownActions = ChatMessageMenuActions.available(for: own, callbacks: callbacks, quickReactions: [])
    let peerActions = ChatMessageMenuActions.available(for: peer, callbacks: callbacks, quickReactions: [])

    #expect(Array(ownActions.suffix(3)) == [.deleteForMe, .edit, .unsend])
    #expect(Array(peerActions.suffix(2)) == [.deleteForMe, .report])
    #expect(!ownActions.contains(.report))
    #expect(!peerActions.contains(.unsend))
  }

  @Test func blobIDsAreCollectedFromImageAndAudioEmbedsOnly() {
    #expect(MLSConversationDataSource.attachmentBlobIDs(for: nil).isEmpty)
    #expect(MLSConversationDataSource.attachmentBlobIDs(for: .unknown(type: "x")).isEmpty)
  }
}
