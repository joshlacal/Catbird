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
import UniformTypeIdentifiers

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct CatbirdDraftMessageSchemaIntent {
  static var title: LocalizedStringResource = "Draft Catbird Message"
  static var supportedModes: IntentModes { .foreground }

  @Parameter(title: "Destination")
  var destination: CatbirdMessagesDestination?

  @Parameter(title: "Subject")
  var subject: AttributedString?

  @Parameter(title: "Content")
  var content: AttributedString?

  @Parameter(title: "Attachments", default: [], supportedContentTypes: [.item])
  var attachments: [IntentFile]

  @Parameter(title: "Audio Message", supportedContentTypes: [.audio])
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

    let droppedUnsupportedContent =
      !attachments.isEmpty || audioMessage != nil || !locations.isEmpty || scheduledDate != nil

    // Capture identity and the target window before the secure chat service
    // can suspend. A known scene can never be replaced by a later focused window.
    let textToStore = draftText
    let draft = try await MainActor.run {
      let sceneID = SceneRouteCoordinator.shared.preferredSceneIDForExternalEvent()
      guard let accountDID = IntentAccountResolver.activeDID() else {
        throw IntentError.notSignedIn
      }
      return PendingChatDraft(
        accountDID: accountDID, sceneID: sceneID, conversationID: nil, text: textToStore)
    }

    let accountIsCurrent: @MainActor @Sendable () -> Bool = {
      let manager = AppStateManager.shared
      return !manager.isTransitioning
        && IntentAccountResolver.activeDID() == draft.accountDID
        && (manager.lifecycle.userDID == nil || manager.lifecycle.userDID == draft.accountDID)
    }
    let accountChanged = IntentError.serviceUnavailable(
      "Your account changed while preparing the draft. Please try again.")
    try Task.checkCancellation()
    guard await accountIsCurrent() else { throw accountChanged }

    let manager = try await MessagesSchemaRuntime.conversationManager()
    try Task.checkCancellation()
    guard manager.userDid == draft.accountDID, await accountIsCurrent() else { throw accountChanged }

    let conversationID: String?
    if let destination {
      try await IntentClientProvider.shared.requireCoveredUse(for: draft.accountDID)
      let directory = try await MessagesSchemaRuntime.directory(manager: manager)
      let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
      let target = try await MessagesSchemaRuntime.resolveDestination(
        recipients: recipients, manager: manager, directory: directory)
      try Task.checkCancellation()
      guard await accountIsCurrent() else { throw accountChanged }
      switch target {
      case .existing(let convoId):
        conversationID = convoId
      case .recipientDraft(var request):
        guard !request.submitted else {
          throw IntentError.invalidParameter("A saved request is still resolving. Open Catbird to retry or cancel it.")
        }
        request.text = draftText
        try await MLSDirectComposeDraftStore.requestPresentation(request, database: manager.database)
        return .result(dialog: Self.dialog(
          "Draft started in Catbird.", droppedUnsupportedContent: droppedUnsupportedContent))
      }
    } else {
      conversationID = nil
    }

    try await ChatDraftHandoff.shared.storeDurably(
      PendingChatDraft(
        id: draft.id, accountDID: draft.accountDID, sceneID: draft.sceneID,
        conversationID: conversationID, text: draft.text),
      accountDID: draft.accountDID, database: manager.database)

    let accountChangedAfterRetaining = IntentError.serviceUnavailable(
      "Your account changed while preparing the draft. Its text has been retained in Catbird.")
    let result = try await MainActor.run {
      try Task.checkCancellation()
      guard accountIsCurrent() else { throw accountChangedAfterRetaining }
      let command: SceneRouteCommand = conversationID.map {
        .navigate(.mlsConversation($0), tabIndex: 4)
      } ?? .showTab(4, resetPath: false)
      return SceneRouteCoordinator.shared.submit(
        SceneRouteRequest(
          id: draft.id, accountDID: draft.accountDID, command: command,
          preferredSceneID: draft.sceneID),
        beforeDelivery: { context in
          accountIsCurrent() && !context.isInvalidated
            && context.accountDID == draft.accountDID
            && (draft.sceneID == nil || draft.sceneID == context.sceneID)
        })
    }

    let status: LocalizedStringResource
    switch result {
    case .delivered:
      status = conversationID == nil
        ? "Pick a conversation in Catbird to start your draft."
        : "Draft started in Catbird."
    case .queued, .duplicate:
      status = "Your draft is waiting for its Catbird window to become available."
    case .dropped:
      status = "Catbird couldn't open the intended window. Your draft text has been retained."
    }
    return .result(dialog: Self.dialog(status, droppedUnsupportedContent: droppedUnsupportedContent))
  }

  private static func dialog(
    _ status: LocalizedStringResource, droppedUnsupportedContent: Bool
  ) -> IntentDialog {
    guard droppedUnsupportedContent else { return IntentDialog(status) }
    return IntentDialog(
      "\(status) Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over.")
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

  @Parameter(title: "Attachments", default: [], supportedContentTypes: [.item])
  var attachments: [IntentFile]

  @Parameter(title: "Audio Message", supportedContentTypes: [.audio])
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
    try await IntentClientProvider.shared.requireCoveredUse(for: directory.currentUserDID)
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
