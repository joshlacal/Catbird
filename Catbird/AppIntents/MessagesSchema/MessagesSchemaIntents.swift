//
//  MessagesSchemaIntents.swift
//  Catbird
//
//  iOS 27 Messages App Schema intents for Bluesky direct messages.
//  The messages schema domain is all-or-nothing (Xcode build-validates all
//  five intents), but chat.bsky has no edit or unsend: those two intents exist
//  to satisfy the domain and fail with an explanatory error.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import Foundation
import GeoToolbox
import Petrel
import LinkPresentation

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct CatbirdDraftMessageSchemaIntent {
  static var title: LocalizedStringResource = "Draft Catbird Message"
  static var openAppWhenRun = true

  @Parameter(title: "Destination")
  var destination: CatbirdMessagesDestination?

  @Parameter(title: "Subject")
  var subject: AttributedString?

  @Parameter(title: "Content")
  var content: AttributedString?

  @Parameter(title: "Attachments", default: [], supportedTypeIdentifiers: ["public.item"])
  var attachments: [IntentFile]

  @Parameter(title: "Audio Message", supportedTypeIdentifiers: ["public.audio"])
  var audioMessage: IntentFile?

  @Parameter(title: "Locations", default: [])
  var locations: [GeoToolbox.PlaceDescriptor]

  @Parameter(title: "Links", default: [])
  var links: [URL]

  @Parameter(title: "Scheduled Date")
  var scheduledDate: Date?

  func perform() async throws -> some IntentResult {
    var draftText = String((content ?? subject ?? AttributedString("")).characters)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !links.isEmpty {
      let linkText = links.map(\.absoluteString).joined(separator: "\n")
      draftText = draftText.isEmpty ? linkText : draftText + "\n" + linkText
    }

    let unsupportedNote =
      (!attachments.isEmpty || audioMessage != nil || !locations.isEmpty || scheduledDate != nil)
      ? " Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over."
      : ""

    guard let destination else {
      await MainActor.run {
        ChatDraftHandoff.shared.store(PendingChatDraft(conversationID: nil, text: draftText))
        AppStateManager.shared.lifecycle.appState?.navigationManager.navigate(to: .chatTab, in: 4)
      }
      return .result(
        dialog: IntentDialog(
          stringLiteral:
            "Pick a conversation in Catbird to start your draft.\(unsupportedNote)"))
    }

    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
    let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    let convoId = try await MessagesSchemaRuntime.resolveDestination(
      recipients: recipients, client: client, directory: directory)
    await MainActor.run {
      ChatDraftHandoff.shared.store(PendingChatDraft(conversationID: convoId, text: draftText))
      AppStateManager.shared.lifecycle.appState?.navigationManager.navigate(to: .conversation(convoId), in: 4)
    }

    return .result(
      dialog: IntentDialog(
        stringLiteral: "Draft started in Catbird.\(unsupportedNote)"))
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct CatbirdSendMessageSchemaIntent {
  static var title: LocalizedStringResource = "Send Catbird Message"

  @Parameter(title: "Destination")
  var destination: CatbirdMessagesDestination

  @Parameter(title: "Subject")
  var subject: AttributedString?

  @Parameter(title: "Content")
  var content: AttributedString?

  @Parameter(title: "Attachments", default: [], supportedTypeIdentifiers: ["public.item"])
  var attachments: [IntentFile]

  @Parameter(title: "Audio Message", supportedTypeIdentifiers: ["public.audio"])
  var audioMessage: IntentFile?

  @Parameter(title: "Locations", default: [])
  var locations: [GeoToolbox.PlaceDescriptor]

  @Parameter(title: "Links", default: [])
  var links: [URL]

  @Parameter(title: "Scheduled Date")
  var scheduledDate: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<[CatbirdMessagesMessageEntity]> & ProvidesDialog {
    guard attachments.isEmpty, audioMessage == nil, locations.isEmpty, scheduledDate == nil else {
      throw IntentError.invalidParameter("Catbird Messages App Schema currently supports text only.")
    }

    let text = try MessagesSchemaRuntime.text(from: content ?? AttributedString(""))
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)

    let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    let finalConvoId = try await MessagesSchemaRuntime.resolveDestination(
      recipients: recipients, client: client, directory: directory)
    let sent = try unwrapIntentResponse(
      await client.chat.bsky.convo.sendMessage(
        input: ChatBskyConvoSendMessage.Input(
          convoId: finalConvoId,
          message: ChatBskyConvoDefs.MessageInput(
            text: text, facets: nil, embed: nil, replyTo: nil))))
    let sentMessageID = sent.id
    let sentAt = sent.sentAt.date

    // Sender must be the user's human name (never a raw DID) with isMe set —
    // Siri surfaces this entity in follow-up conversation.
    let selfDID = directory.currentUserDID
    let selfName = directory.member(withDID: selfDID).map { directory.name(for: $0) }
      ?? String(selfDID.suffix(8))
    let sender = CatbirdMessagesPersonEntity(id: selfDID, displayName: selfName, isMe: true)

    let recipientEntities = recipients.map {
      CatbirdMessagesPersonEntity(id: $0.did, displayName: $0.displayName)
    }
    let convoModel = directory.conversations.first { $0.id == finalConvoId }
    let convoTitle = convoModel.map { directory.title(for: $0) }
      ?? recipients.map(\.displayName).joined(separator: ", ")
    let preview = AttributedString(text)

    let convoEntity = CatbirdMessagesConversationEntity(
      id: finalConvoId,
      recipients: recipientEntities,
      displayName: convoTitle,
      previewText: preview,
      conversationName: convoTitle,
      isRead: true,
      attributes: recipientEntities.count > 1 ? [.group] : [],
      dateLastActive: sentAt
    )

    let entity = CatbirdMessagesMessageEntity(
      id: sentMessageID,
      messageType: .text,
      author: sender,
      isRead: true,
      attributes: [],
      conversation: convoEntity,
      date: sentAt,
      subject: nil,
      body: AttributedString(text),
      attachments: [],
      audioMessage: nil,
      customAttachments: [],
      locations: [],
      links: [],
      messageEffect: nil,
      reaction: nil,
      referencedMessage: nil,
      notificationIdentifier: nil
    )

    return .result(value: [entity], dialog: "Sent.")
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
struct CatbirdEditSentMessageSchemaIntent {
  static var title: LocalizedStringResource = "Edit Catbird Message"

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  @Parameter(title: "Content")
  var content: AttributedString

  func perform() async throws -> IntentResultContainer<Never, Never, Never, IntentDialog> {
    throw IntentError.invalidParameter("Bluesky direct messages can't be edited.")
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct CatbirdUnsendMessageSchemaIntent {
  static var title: LocalizedStringResource = "Unsend Catbird Message"

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  func perform() async throws -> IntentResultContainer<Never, Never, Never, IntentDialog> {
    throw IntentError.invalidParameter("Bluesky direct messages can't be unsent.")
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct CatbirdSetMessageReadStatusSchemaIntent {
  static var title: LocalizedStringResource = "Set Catbird Message Read Status"

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  @Parameter(title: "Read")
  var isRead: Bool

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard isRead else {
      throw IntentError.invalidParameter("Bluesky direct messages can't be marked unread.")
    }
    let client = try await MessagesSchemaRuntime.client()
    _ = try unwrapIntentResponse(
      await client.chat.bsky.convo.updateRead(
        input: ChatBskyConvoUpdateRead.Input(
          convoId: message.conversation.id, messageId: message.id)))

    return .result(dialog: isRead ? "Marked read." : "Marked unread.")
  }
}

#endif
