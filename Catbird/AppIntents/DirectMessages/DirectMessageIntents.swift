//
//  DirectMessageIntents.swift
//  Catbird
//
//  Plain App Intents for Bluesky direct messages (chat.bsky.convo). These are
//  deliberately NOT part of the iOS 27 Messages App Schema — that domain is
//  reserved for MLS chat (see MessagesSchema/) — but they make Bluesky DMs
//  fully scriptable from Shortcuts. All calls go through the standalone
//  IntentClientProvider client, so they work with the app not running.
//

import AppIntents
import Foundation
import Petrel

@available(iOS 18.0, *)
struct SendDirectMessageIntent: AppIntent {
  static let title: LocalizedStringResource = "Send Direct Message"
  static let description = IntentDescription(
    "Send a Bluesky direct message to a person. Finds (or starts) your conversation with them.")

  @Parameter(title: "Account")
  var account: AccountEntity?

  @Parameter(title: "Recipient")
  var recipient: ProfileEntity

  @Parameter(title: "Message")
  var message: String

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw IntentError.invalidParameter("Message text cannot be empty.")
    }

    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)
    let recipientName = recipient.displayName ?? "@\(recipient.handle)"

    let (convoCode, convoData) = try await client.chat.bsky.convo.getConvoForMembers(
      input: ChatBskyConvoGetConvoForMembers.Parameters(
        members: [try DID(didString: recipient.id)]))
    guard (200..<300).contains(convoCode), let convo = convoData?.convo else {
      throw IntentError.invalidParameter(
        "\(recipientName) can't receive direct messages right now.")
    }

    _ = try unwrapIntentResponse(
      await client.chat.bsky.convo.sendMessage(
        input: ChatBskyConvoSendMessage.Input(
          convoId: convo.id,
          message: ChatBskyConvoDefs.MessageInput(
            text: text, facets: nil, embed: nil, replyTo: nil))))

    return .result(dialog: IntentDialog(stringLiteral: "Sent to \(recipientName)."))
  }
}

@available(iOS 18.0, *)
struct GetConversationsIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Conversations"
  static let description = IntentDescription(
    "Get your most recent Bluesky direct-message conversations.")

  @Parameter(title: "Account")
  var account: AccountEntity?

  @Parameter(title: "Result Limit")
  var limit: Int?

  init() {}

  func perform() async throws -> some IntentResult & ReturnsValue<[BskyConversationEntity]> & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let conversations = try await BskyConversationQuery.recentConversations(
      limit: limit ?? 25, accountDID: did)

    let dialog: IntentDialog
    if let first = conversations.first {
      dialog = IntentDialog(
        stringLiteral:
          "Found \(conversations.count) conversation\(conversations.count == 1 ? "" : "s"). Latest: \(first.title).")
    } else {
      dialog = IntentDialog(stringLiteral: "No conversations found.")
    }
    return .result(value: conversations, dialog: dialog)
  }
}

@available(iOS 18.0, *)
struct GetUnreadDMCountIntent: AppIntent {
  static let title: LocalizedStringResource = "Unread Message Count"
  static let description = IntentDescription(
    "Get the number of unread Bluesky direct messages across your conversations.")

  @Parameter(title: "Account")
  var account: AccountEntity?

  init() {}

  func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    let output = try unwrapIntentResponse(
      await client.chat.bsky.convo.listConvos(
        input: ChatBskyConvoListConvos.Parameters(limit: 100)))
    let unread = output.convos.reduce(0) { $0 + $1.unreadCount }

    return .result(
      value: unread,
      dialog: IntentDialog(
        stringLiteral: "You have \(unread) unread direct message\(unread == 1 ? "" : "s")."))
  }
}

@available(iOS 18.0, *)
struct MarkConversationReadIntent: AppIntent {
  static let title: LocalizedStringResource = "Mark Conversation Read"
  static let description = IntentDescription(
    "Mark a Bluesky direct-message conversation as read.")

  @Parameter(title: "Account")
  var account: AccountEntity?

  @Parameter(title: "Conversation")
  var conversation: BskyConversationEntity

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    _ = try unwrapIntentResponse(
      await client.chat.bsky.convo.updateRead(
        input: ChatBskyConvoUpdateRead.Input(convoId: conversation.id)))

    return .result(
      dialog: IntentDialog(stringLiteral: "Marked \(conversation.title) as read."))
  }
}
