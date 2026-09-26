@testable import Catbird
import Foundation
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
      "convo_id": "00000000-0000-0000-0000-000000000001",
      "message_id": "00000000-0000-0000-0000-000000000002",
      "request_id": "00000000-0000-0000-0000-000000000003",
      "event_id": "00000000-0000-0000-0000-000000000004",
    ]

    #expect(NotificationManager.isNavigableMLSNotification(fromUserInfo: valid))
    #expect(NotificationManager.mlsConversationID(fromUserInfo: valid) == "00000000-0000-0000-0000-000000000001")
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
        "convo_id": "00000000-0000-0000-0000-000000000001",
      ]
      #expect(NotificationManager.isNavigableMLSNotification(fromUserInfo: valid))
      #expect(NotificationManager.mlsConversationID(fromUserInfo: valid) == "00000000-0000-0000-0000-000000000001")
    }
  }
}
