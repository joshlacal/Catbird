//
//  MessagesSchemaIntents.swift
//  Catbird
//
//  iOS 27 Messages App Schema intents for Catbird MLS chat.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import CatbirdMLSCore
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
      let manager = try await MessagesSchemaRuntime.conversationManager()
      guard let account = manager.userDid else { throw IntentError.notSignedIn }
      try await ChatDraftHandoff.shared.storeDurably(
        PendingChatDraft(conversationID: nil, text: draftText), accountDID: account, database: manager.database)
      await MainActor.run {
        AppStateManager.shared.lifecycle.appState?.navigationManager.navigate(to: .chatTab, in: 4)
      }
      return .result(
        dialog: IntentDialog(
          stringLiteral:
            "Pick a conversation in Catbird to start your draft.\(unsupportedNote)"))
    }

    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
    let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    let target = try await MessagesSchemaRuntime.resolveDestination(
      recipients: recipients, manager: manager, directory: directory)
    switch target {
    case .existing(let convoId):
      try await ChatDraftHandoff.shared.storeDurably(
        PendingChatDraft(conversationID: convoId, text: draftText),
        accountDID: directory.currentUserDID, database: manager.database)
      await MainActor.run {
        AppStateManager.shared.lifecycle.appState?.navigationManager.navigate(to: .mlsConversation(convoId), in: 4)
      }
    case .recipientDraft(var draft):
      guard !draft.submitted else {
        throw IntentError.invalidParameter("A saved request is still resolving. Open Catbird to retry or cancel it.")
      }
      draft.text = draftText
      try await MLSDirectComposeDraftStore.requestPresentation(draft, database: manager.database)
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
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)

    let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    let target = try await MessagesSchemaRuntime.resolveDestination(
      recipients: recipients, manager: manager, directory: directory)
    let finalConvoId: String
    let sentMessageID: String
    let sentAt: Date
    switch target {
    case .existing(let conversationID):
      guard try await MLSDirectRequestAccess.allowsOrdinaryEffects(manager: manager, conversationID: conversationID) else {
        throw IntentError.invalidParameter("This request must be accepted and ready before sending another message.")
      }
      let result = try await manager.sendMessage(convoId: conversationID, plaintext: text)
      finalConvoId = conversationID
      sentMessageID = result.messageId
      sentAt = result.receivedAt.date
    case .recipientDraft(var draft):
      guard !draft.submitted || draft.text == text else {
        throw IntentError.invalidParameter("A different saved request is still resolving. Open Catbird to retry or cancel it.")
      }
      draft.text = text
      draft.submitted = true
      try await MLSDirectComposeDraftStore.validateText(text)
      try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
      let outcome = try await manager.startDirectRequest(input: DirectRequestInput(
        draftId: draft.id.uuidString.lowercased(), recipientDid: draft.recipientDID, text: text, invitation: nil))
      guard case .requestSent(let conversationID, let messageID, _) = outcome else {
        try await MLSDirectComposeDraftStore.requestPresentation(draft, database: manager.database)
        throw IntentError.serviceUnavailable("Your request is saved. Open Catbird to check its outcome or retry the same request.")
      }
      finalConvoId = conversationID
      sentMessageID = messageID
      sentAt = Date()
      try await MLSDirectComposeDraftStore.archive(draft, database: manager.database)
    }

    // Sender must be the user's human name (never a raw DID) with isMe set —
    // Siri surfaces this entity in follow-up conversation.
    let selfDID = directory.currentUserDID
    let selfName: String
    if let selfMember = directory.member(withDID: selfDID) {
      selfName = directory.name(for: selfMember)
    } else {
      let resolved = await MessagesSchemaRuntime.ProfileNameCache.shared.resolve(dids: [selfDID])
      selfName = resolved[selfDID]?.displayName
        ?? resolved[selfDID]?.handle.map { "@\($0)" }
        ?? String(selfDID.suffix(8))
    }
    let sender = CatbirdMessagesPersonEntity(id: selfDID, displayName: selfName, isMe: true)

    let recipientEntities = recipients.map {
      CatbirdMessagesPersonEntity(id: $0.did, displayName: $0.displayName)
    }
    let convoModel = directory.conversations.first { $0.conversationID == finalConvoId }
    let convoTitle = convoModel.map { directory.title(for: $0) }
      ?? recipients.map(\.displayName).joined(separator: ", ")
    let preview = AttributedString("MLS Chat")

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

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let text = try MessagesSchemaRuntime.text(from: content)
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let canonicalID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      manager: manager
    )
    guard try await MLSDirectRequestAccess.allowsOrdinaryEffects(manager: manager, conversationID: canonicalID) else {
      throw IntentError.invalidParameter("This request must be accepted and ready before editing messages.")
    }
    _ = try await manager.editMessage(
      convoId: canonicalID,
      messageId: message.id,
      newText: text
    )

    return .result(dialog: "Edited.")
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct CatbirdUnsendMessageSchemaIntent {
  static var title: LocalizedStringResource = "Unsend Catbird Message"

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let canonicalID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      manager: manager
    )
    _ = try await manager.unsendMessage(
      convoId: canonicalID,
      messageId: message.id
    )

    return .result(dialog: "Unsent.")
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
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let canonicalID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      manager: manager
    )
    try await manager.setMessageReadStatus(
      convoId: canonicalID,
      messageId: message.id,
      read: isRead
    )

    return .result(dialog: isRead ? "Marked read." : "Marked unread.")
  }
}

#endif
