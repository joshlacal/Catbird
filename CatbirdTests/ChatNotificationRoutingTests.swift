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
}
