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

    // Capture identity and preserve the text before client resolution can
    // suspend. A known scene can never be replaced by a later focused window.
    let textToStore = draftText
    let draft = try await MainActor.run {
      let coordinator = SceneRouteCoordinator.shared
      let sceneID = coordinator.preferredSceneIDForExternalEvent()
      guard let accountDID = IntentAccountResolver.activeDID() else {
        throw IntentError.notSignedIn
      }
      let draft = PendingChatDraft(
        accountDID: accountDID, sceneID: sceneID, conversationID: nil, text: textToStore)
      guard ChatDraftHandoff.shared.store(draft) else {
        throw IntentError.serviceUnavailable("Catbird couldn't retain this draft. Please try again.")
      }
      return draft
    }

    let accountIsCurrent: @MainActor @Sendable () -> Bool = {
      let manager = AppStateManager.shared
      return !manager.isTransitioning
        && IntentAccountResolver.activeDID() == draft.accountDID
        && (manager.lifecycle.userDID == nil || manager.lifecycle.userDID == draft.accountDID)
    }
    let accountChanged = IntentError.serviceUnavailable(
      "Your account changed while preparing the draft. Its text has been retained in Catbird.")
    try Task.checkCancellation()
    guard await accountIsCurrent() else { throw accountChanged }

    let conversationID: String?
    if let destination {
      let client = try await IntentClientProvider.shared.client(for: draft.accountDID)
      try Task.checkCancellation()
      guard await accountIsCurrent() else { throw accountChanged }
      let continuity = await client.authContinuitySnapshot()
      let clientDID = try await client.getDid()
      guard continuity.did == draft.accountDID, clientDID == draft.accountDID,
        await accountIsCurrent()
      else { throw accountChanged }

      // Each exact-auth scope must contain one generated request. Keep the
      // cached conversation match outside those scopes because it makes none.
      let listed = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
        try await client.chat.bsky.convo.listConvos(input: .init(limit: 100))
      }
      try Task.checkCancellation()
      guard await accountIsCurrent(), await client.authContinuitySnapshot() == continuity,
        case .performed(let response) = listed
      else { throw accountChanged }
      let output = try unwrapIntentResponse(response)
      var membersByConvoID: [String: [MessagesSchemaRuntime.Member]] = [:]
      for conversation in output.convos {
        membersByConvoID[conversation.id] = conversation.members.map {
          MessagesSchemaRuntime.Member(
            did: $0.did.didString(), displayName: $0.displayName, handle: $0.handle.value)
        }
      }
      let directory = MessagesSchemaRuntime.ChatDirectory(
        conversations: output.convos, membersByConvoID: membersByConvoID,
        currentUserDID: clientDID)
      let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
      if let existing = MessagesSchemaRuntime.conversationID(
        matching: recipients.map(\.did),
        in: membersByConvoID.mapValues { $0.map(\.did) },
        conversationOrder: output.convos.map(\.id), selfDID: clientDID
      ) {
        conversationID = existing
      } else {
        let members = try recipients.map { try DID(didString: $0.did) }
        let resolved = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
          try await client.chat.bsky.convo.getConvoForMembers(input: .init(members: members))
        }
        try Task.checkCancellation()
        guard await accountIsCurrent(), await client.authContinuitySnapshot() == continuity,
          case .performed(let response) = resolved
        else { throw accountChanged }
        let output = try unwrapIntentResponse(response)
        conversationID = output.convo.id
      }
    } else {
      conversationID = nil
    }

    let result = try await MainActor.run {
      try Task.checkCancellation()
      guard accountIsCurrent() else { throw accountChanged }
      let command: SceneRouteCommand = conversationID.map {
        .navigate(.conversation($0), tabIndex: 4)
      } ?? .showTab(4, resetPath: false)
      return SceneRouteCoordinator.shared.submit(
        SceneRouteRequest(
          id: draft.id, accountDID: draft.accountDID, command: command,
          preferredSceneID: draft.sceneID),
        beforeDelivery: { context in
          guard accountIsCurrent(), !context.isInvalidated,
            context.accountDID == draft.accountDID,
            draft.sceneID == nil || draft.sceneID == context.sceneID
          else { return false }
          return ChatDraftHandoff.shared.bind(
            id: draft.id, accountDID: draft.accountDID, sceneID: context.sceneID,
            conversationID: conversationID) != nil
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
    guard droppedUnsupportedContent else {
      return .result(dialog: IntentDialog(status))
    }
    return .result(
      dialog: IntentDialog(
        "\(status) Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over."))
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

    return .result(dialog: "Marked read.")
  }
}

#endif
