@testable import Catbird
import CatbirdMLSCore
import Foundation
import GRDB
import Testing
/// Tap-routing payload parsing for chat notifications (`NotificationManager.chatConversationID`).
/// Covers the two real chat payload shapes (NSE `chat_message` push and local polling
/// notification) plus the guard preserving the generic `uri`/`did` routing path.
struct ChatNotificationRoutingTests {
  @Test("NSE chat_message push payload routes via convoId")
  func nseChatMessagePayloadRoutes() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat_message",
      "convoId": "3kconvo123",
      "messageId": "3kmsg456",
      "senderDid": "did:plc:sender",
      "messageText": "hello",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == "3kconvo123")
  }

  @Test("Local polling notification payload routes via conversationID")
  func localChatPayloadRoutes() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat",
      "conversationID": "3kconvo123",
      "recipientDid": "did:plc:recipient",
      "messageID": "3kmsg456",
      "senderHandle": "alice.test",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == "3kconvo123")
  }

  @Test("convoId is preferred over conversationID when both are present")
  func convoIdPreferredOverConversationID() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat_message",
      "convoId": "3kfromnse",
      "conversationID": "3kfromlocal",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == "3kfromnse")
  }

  @Test("Payloads with a uri key keep the generic routing path")
  func uriPayloadKeepsGenericPath() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat",
      "uri": "3kconvo123",
      "conversationID": "3kconvo123",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == nil)
  }

  @Test("Payloads with a did key keep the generic routing path")
  func didPayloadKeepsGenericPath() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat",
      "did": "did:plc:recipient",
      "conversationID": "3kconvo123",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == nil)
  }

  @Test("Non-chat notification types do not route")
  func nonChatTypesDoNotRoute() {
    for type in ["mls_message", "mls_message_decrypted", "like", "reply"] {
      let userInfo: [AnyHashable: Any] = [
        "type": type,
        "convoId": "3kconvo123",
      ]

      #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == nil)
    }
  }

  @Test("Missing type key does not route")
  func missingTypeDoesNotRoute() {
    let userInfo: [AnyHashable: Any] = ["convoId": "3kconvo123"]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == nil)
  }

  @Test("Chat type without a conversation key does not route")
  func chatTypeWithoutConversationKeyDoesNotRoute() {
    let userInfo: [AnyHashable: Any] = [
      "type": "chat_message",
      "senderDid": "did:plc:sender",
    ]

    #expect(NotificationManager.chatConversationID(fromUserInfo: userInfo) == nil)
  }

  // MARK: - F65: Direct Message Request Routing

  @Test("mls_message_request push payload routes via convo_id with valid protocol_version and recipient_account")
  func mlsMessageRequestPayloadRoutes() {
    let valid: [AnyHashable: Any] = [
      "type": "mls_message_request",
      "protocol_version": "2",
      "recipient_account": String(repeating: "a", count: 64),
      "convo_id": "00000000-0000-4000-8000-000000000001",
      "message_id": "00000000-0000-4000-8000-000000000002",
      "request_id": "00000000-0000-4000-8000-000000000003",
      "event_id": "00000000-0000-4000-8000-000000000004",
    ]

    #expect(NotificationManager.isNavigableMLSNotification(fromUserInfo: valid))
    #expect(NotificationManager.mlsConversationID(fromUserInfo: valid) == "00000000-0000-4000-8000-000000000001")
    #expect(NotificationManager.chatConversationID(fromUserInfo: valid) == nil)
  }

  @Test("mls_message_request rejects invalid protocol_version or malformed recipient_account")
  func mlsMessageRequestRejectsInvalidPayloads() {
    let wrongVersion: [AnyHashable: Any] = [
      "type": "mls_message_request",
      "protocol_version": "1",
      "recipient_account": String(repeating: "a", count: 64),
      "convo_id": "00000000-0000-0000-0000-000000000001",
    ]
    #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: wrongVersion))
    #expect(NotificationManager.mlsConversationID(fromUserInfo: wrongVersion) == nil)

    let shortHash: [AnyHashable: Any] = [
      "type": "mls_message_request",
      "protocol_version": "2",
      "recipient_account": "abc",
      "convo_id": "00000000-0000-0000-0000-000000000001",
    ]
    #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: shortHash))

    let uppercaseHash: [AnyHashable: Any] = [
      "type": "mls_message_request",
      "protocol_version": "2",
      "recipient_account": String(repeating: "A", count: 64),
      "convo_id": "00000000-0000-0000-0000-000000000001",
    ]
    #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: uppercaseHash))

    let emptyConvo: [AnyHashable: Any] = [
      "type": "mls_message_request",
      "protocol_version": "2",
      "recipient_account": String(repeating: "a", count: 64),
      "convo_id": "",
    ]
    #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: emptyConvo))
  }

  @Test("mls_message_request rejects non-canonical convo_id")
  func mlsMessageRequestRejectsNonCanonicalConvoID() {
    for invalidConvo in ["non-canonical-id", "not-a-uuid", "../../traversal", "12345"] {
      let payload: [AnyHashable: Any] = [
        "type": "mls_message_request",
        "protocol_version": "2",
        "recipient_account": String(repeating: "a", count: 64),
        "convo_id": invalidConvo,
      ]
      #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: payload))
      #expect(NotificationManager.mlsConversationID(fromUserInfo: payload) == nil)
    }
  }

  @Test("mls_message and mls_message_decrypted reject non-canonical convo_id")
  func mlsMessageRejectsNonCanonicalConvoID() {
    for type in ["mls_message", "mls_message_decrypted"] {
      let invalid: [AnyHashable: Any] = [
        "type": type,
        "convo_id": "not-canonical",
      ]
      #expect(!NotificationManager.isNavigableMLSNotification(fromUserInfo: invalid))
      #expect(NotificationManager.mlsConversationID(fromUserInfo: invalid) == nil)

      let valid: [AnyHashable: Any] = [
        "type": type,
        "convo_id": "00000000-0000-4000-8000-000000000001",
      ]
      #expect(NotificationManager.isNavigableMLSNotification(fromUserInfo: valid))
      #expect(NotificationManager.mlsConversationID(fromUserInfo: valid) == "00000000-0000-4000-8000-000000000001")
    }
  }

  // MARK: - F69: Deferred Route Resolution During Suspension

  @Test("resolveMLSConversationRoute defers resolution while storage is suspended until suspension clears")
  func resolveMLSConversationRouteDefersWhileSuspended() async throws {
    let did = "did:plc:test-f69-\(UUID().uuidString.lowercased())"
    let convoId = UUID().uuidString.lowercased()
    let groupID = Data(repeating: 0x42, count: 32)

    // Seed conversation in GRDB
    let manager = CatbirdMLSCore.MLSGRDBManager()
    let pool = try await manager.getDatabasePool(for: did)
    try await pool.write { db in
      let model = CatbirdMLSCore.MLSConversationModel(
        conversationID: convoId,
        currentUserDID: did,
        groupID: groupID
      )
      try model.insert(db)
    }

    let notifManager = NotificationManager()

    // 1. Pre-condition: when NOT suspended, resolveMLSConversationRoute succeeds immediately
    let initial = await notifManager.resolveMLSConversationRoute(convoId, recipientDID: did, maxWaitTime: 1.0)
    #expect(initial?.conversationID == convoId)
    #expect(initial?.groupID == groupID)

    // 2. F69: Assert global suspension flag to simulate app suspended state
    CatbirdMLSCore.MLSClient.markSuspensionInProgress(reason: "F69 test")
    #expect(CatbirdMLSCore.MLSClient.isSuspensionInProgress)

    // Launch deferred resolution in a concurrent Task with maxWaitTime 3.0s
    let resolveTask = Task {
      await notifManager.resolveMLSConversationRoute(convoId, recipientDID: did, maxWaitTime: 3.0)
    }

    // Wait 0.3s while suspension is active: task must still be running (not returned nil prematurely)
    try await Task.sleep(nanoseconds: 300_000_000)

    // Clear suspension to simulate app foreground resumption
    CatbirdMLSCore.MLSClient.clearSuspensionFlag(reason: "F69 test resume")
    #expect(!CatbirdMLSCore.MLSClient.isSuspensionInProgress)

    // The deferred route resolution must now succeed and return the conversation!
    let deferred = await resolveTask.value
    #expect(deferred?.conversationID == convoId)
    #expect(deferred?.groupID == groupID)

    // Cleanup
    try? await manager.deleteDatabase(for: did)
  }

  // MARK: - F74: AppDelegate Deferred Route Resolution During Suspension

  @Test("AppDelegate.resolveMLSConversationRoute defers resolution while storage is suspended until suspension clears")
  func appDelegateResolveMLSConversationRouteDefersWhileSuspended() async throws {
    let did = "did:plc:test-f74-\(UUID().uuidString.lowercased())"
    let convoId = UUID().uuidString.lowercased()
    let groupID = Data(repeating: 0x43, count: 32)

    // Seed conversation in GRDB
    let grdbManager = CatbirdMLSCore.MLSGRDBManager()
    let pool = try await grdbManager.getDatabasePool(for: did)
    try await pool.write { db in
      let model = CatbirdMLSCore.MLSConversationModel(
        conversationID: convoId,
        currentUserDID: did,
        groupID: groupID
      )
      try model.insert(db)
    }

    let delegate = await MainActor.run { CatbirdApp.AppDelegate() }

    // 1. Pre-condition: when NOT suspended, resolveMLSConversationRoute succeeds immediately
    let initial = await delegate.resolveMLSConversationRoute(convoId, recipientDID: did, maxWaitTime: 1.0)
    #expect(initial == convoId)

    // 2. F74: Assert global suspension flag to simulate app suspended state
    CatbirdMLSCore.MLSClient.markSuspensionInProgress(reason: "F74 test")
    #expect(CatbirdMLSCore.MLSClient.isSuspensionInProgress)
    #expect(CatbirdMLSCore.MLSCoreContext.isSuspensionInProgress)

    // Launch deferred resolution in a concurrent Task with maxWaitTime 3.0s
    let resolveTask = Task {
      await delegate.resolveMLSConversationRoute(convoId, recipientDID: did, maxWaitTime: 3.0)
    }

    // Wait 0.3s while suspension is active: task must still be running (not returned nil prematurely)
    try await Task.sleep(nanoseconds: 300_000_000)

    // Clear suspension to simulate app foreground resumption
    CatbirdMLSCore.MLSClient.clearSuspensionFlag(reason: "F74 test resume")
    #expect(!CatbirdMLSCore.MLSClient.isSuspensionInProgress)
    #expect(!CatbirdMLSCore.MLSCoreContext.isSuspensionInProgress)

    // The deferred route resolution must now succeed and return the conversation!
    let deferred = await resolveTask.value
    #expect(deferred == convoId)

    // Cleanup
    try? await grdbManager.deleteDatabase(for: did)
  }
}
