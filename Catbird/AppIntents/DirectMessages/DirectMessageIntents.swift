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
  static let title: LocalizedStringResource = LocalizedStringResource(
    "Send Direct Message",
    comment: "App Intent title for sending a Bluesky direct message."
  )
  static let description = IntentDescription(
    LocalizedStringResource(
      "Send a Bluesky direct message to a person. Finds (or starts) your conversation with them.",
      comment: "App Intent description for Send Direct Message."
    )
  )

  @Parameter(
    title: LocalizedStringResource(
      "Account",
      comment: "Parameter title for choosing which signed-in Bluesky account sends the direct message."
    )
  )
  var account: AccountEntity?

  @Parameter(
    title: LocalizedStringResource(
      "Recipient",
      comment: "Parameter title for the Bluesky profile receiving the direct message."
    ),
    requestValueDialog: IntentDialog(
      LocalizedStringResource(
        "Who do you want to message?",
        comment: "Prompt spoken by Siri asking which recipient to send a Bluesky direct message to."
      )
    )
  )
  var recipient: ProfileEntity

  @Parameter(
    title: LocalizedStringResource(
      "Message",
      comment: "Parameter title for the text of a Bluesky direct message."
    ),
    requestValueDialog: IntentDialog(
      LocalizedStringResource(
        "What do you want to say?",
        comment: "Prompt spoken by Siri asking for the direct message text."
      )
    )
  )
  var message: String

  static var parameterSummary: some ParameterSummary {
    Summary("Send \(\.$message) to \(\.$recipient)") {
      \.$account
    }
  }

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "Enter a message to send.",
          comment: "Validation error when Send Direct Message is given empty text."
        )
      )
    }

    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)
    let sendingDID = try await client.getDid()
    let recipientName = recipient.displayName ?? "@\(recipient.handle)"

    let (convoCode, convoData) = try await client.chat.bsky.convo.getConvoForMembers(
      input: ChatBskyConvoGetConvoForMembers.Parameters(
        members: [try DID(didString: recipient.id)]))
    guard (200..<300).contains(convoCode), let convo = convoData?.convo else {
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "\(recipientName) can’t receive direct messages right now.",
          comment: "Error when a Bluesky direct-message conversation cannot be opened with the recipient; placeholder is the recipient's name or handle."
        )
      )
    }

    // A message can't be unsent for the recipient, so always confirm the
    // recipient and text first (Siri may have misheard either).
    try await requestConfirmation(
      actionName: .send,
      dialog: IntentDialog(
        LocalizedStringResource(
          "Send “\(text)” to \(recipientName)?",
          comment: "Confirmation prompt before sending a Bluesky direct message; first placeholder is message text, second is recipient name."
        )
      )
    )

    try await IntentClientProvider.shared.requireCoveredUse(for: sendingDID)
    _ = try unwrapIntentResponse(
      await client.chat.bsky.convo.sendMessage(
        input: ChatBskyConvoSendMessage.Input(
          convoId: convo.id,
          message: ChatBskyConvoDefs.MessageInput(
            text: text, facets: nil, embed: nil, replyTo: nil))))

    return .result(
      dialog: IntentDialog(
        LocalizedStringResource(
          "Sent to \(recipientName).",
          comment: "Spoken confirmation after sending a Bluesky direct message; placeholder is the recipient's name or handle."
        )
      )
    )
  }
}

@available(iOS 18.0, *)
struct GetConversationsIntent: AppIntent {
  static let title: LocalizedStringResource = LocalizedStringResource(
    "Get Conversations",
    comment: "App Intent title for listing recent Bluesky direct-message conversations."
  )
  static let description = IntentDescription(
    LocalizedStringResource(
      "Get your most recent Bluesky direct-message conversations.",
      comment: "App Intent description for Get Conversations."
    )
  )

  @Parameter(
    title: LocalizedStringResource(
      "Account",
      comment: "Parameter title for choosing which signed-in Bluesky account's conversations to list."
    )
  )
  var account: AccountEntity?

  @Parameter(
    title: LocalizedStringResource(
      "Result Limit",
      comment: "Parameter title for maximum number of conversations to return."
    )
  )
  var limit: Int?

  static var parameterSummary: some ParameterSummary {
    Summary("Get recent conversations") {
      \.$limit
      \.$account
    }
  }

  init() {}

  func perform() async throws -> some IntentResult & ReturnsValue<[BskyConversationEntity]> & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let conversations = try await BskyConversationQuery.recentConversations(
      limit: limit ?? 25, accountDID: did)

    let dialog: IntentDialog
    if let first = conversations.first {
      dialog = IntentDialog(
        LocalizedStringResource(
          "Found \(conversations.count) conversations. Latest: \(first.title).",
          comment: "Spoken summary of Bluesky DM conversations; first placeholder is the conversation count, second is the latest conversation title."
        )
      )
    } else {
      dialog = IntentDialog(
        LocalizedStringResource(
          "No conversations found.",
          comment: "Spoken summary when the user has no Bluesky DM conversations."
        )
      )
    }
    return .result(value: conversations, dialog: dialog)
  }
}

@available(iOS 18.0, *)
struct GetUnreadDMCountIntent: AppIntent {
  static let title: LocalizedStringResource = LocalizedStringResource(
    "Unread Message Count",
    comment: "App Intent title for checking unread Bluesky direct messages."
  )
  static let description = IntentDescription(
    LocalizedStringResource(
      "Get the number of unread Bluesky direct messages across your conversations.",
      comment: "App Intent description for Unread Message Count."
    )
  )

  @Parameter(
    title: LocalizedStringResource(
      "Account",
      comment: "Parameter title for choosing which signed-in Bluesky account's unread messages to count."
    )
  )
  var account: AccountEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Get unread message count") {
      \.$account
    }
  }

  init() {}

  func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    let output = try unwrapIntentResponse(
      await client.chat.bsky.convo.listConvos(
        input: ChatBskyConvoListConvos.Parameters(limit: 100)))
    let unread = output.convos.reduce(0) { $0 + $1.unreadCount }

    let dialog = IntentDialog(
      LocalizedStringResource(
        "You have \(unread) unread direct messages.",
        comment: "Spoken count of unread Bluesky direct messages."
      )
    )
    return .result(value: unread, dialog: dialog)
  }
}

@available(iOS 18.0, *)
struct MarkConversationReadIntent: AppIntent {
  static let title: LocalizedStringResource = LocalizedStringResource(
    "Mark Conversation Read",
    comment: "App Intent title for marking a Bluesky direct-message conversation as read."
  )
  static let description = IntentDescription(
    LocalizedStringResource(
      "Mark a Bluesky direct-message conversation as read.",
      comment: "App Intent description for Mark Conversation Read."
    )
  )

  @Parameter(
    title: LocalizedStringResource(
      "Account",
      comment: "Parameter title for choosing which signed-in Bluesky account owns the conversation."
    )
  )
  var account: AccountEntity?

  @Parameter(
    title: LocalizedStringResource(
      "Conversation",
      comment: "Parameter title for the Bluesky conversation to mark as read."
    )
  )
  var conversation: BskyConversationEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Mark \(\.$conversation) as read") {
      \.$account
    }
  }

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    _ = try unwrapIntentResponse(
      await client.chat.bsky.convo.updateRead(
        input: ChatBskyConvoUpdateRead.Input(convoId: conversation.id)))

    return .result(
      dialog: IntentDialog(
        LocalizedStringResource(
          "Marked \(conversation.title) as read.",
          comment: "Spoken confirmation after marking a Bluesky DM conversation as read; placeholder is the conversation title."
        )
      )
    )
  }
}
