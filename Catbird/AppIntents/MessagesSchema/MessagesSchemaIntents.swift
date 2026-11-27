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
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Draft Catbird Message",
    comment: "Messages App Schema intent title for drafting an encrypted Catbird chat message."
  )
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
      LocalizedStringResource(
        "Your account changed while preparing the draft. Please try again.",
        comment: "Error when the active Catbird account changes mid-intent before a chat draft is stored."
      )
    )
    try Task.checkCancellation()
    guard await accountIsCurrent() else { throw accountChanged }

    let coordinator = try await MessagesSchemaRuntime.coordinator()
    try Task.checkCancellation()
    let activeAccountDid = await coordinator.accountDid
    guard activeAccountDid == draft.accountDID, await accountIsCurrent() else { throw accountChanged }

    let conversationID: String?
    if let destination {
      try await IntentClientProvider.shared.requireCoveredUse(for: draft.accountDID)
      let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
      let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
      let target = try await MessagesSchemaRuntime.resolveDestination(
        recipients: recipients, coordinator: coordinator, directory: directory)
      try Task.checkCancellation()
      guard await accountIsCurrent() else { throw accountChanged }
      switch target {
      case .existing(let convoId):
        conversationID = convoId
      case .recipientDraft(var request):
        guard !request.submitted else {
          throw IntentError.invalidParameter(
            LocalizedStringResource(
              "A saved request is still resolving. Open Catbird to retry or cancel it.",
              comment: "Error when an outgoing encrypted chat request is already in flight."
            )
          )
        }
        request.text = draftText
        MLSDirectComposeDraftStore.requestPresentation(request)
        return .result(
          dialog: Self.startedInCatbirdDialog(
            droppedUnsupportedContent: droppedUnsupportedContent
          )
        )
      }
    } else {
      conversationID = nil
    }

    try await MainActor.run {
      try ChatDraftHandoff.shared.storeDurably(
        PendingChatDraft(
          id: draft.id, accountDID: draft.accountDID, sceneID: draft.sceneID,
          conversationID: conversationID, text: draft.text),
        accountDID: draft.accountDID)
    }

    let accountChangedAfterRetaining = IntentError.serviceUnavailable(
      LocalizedStringResource(
        "Your account changed while preparing the draft. Its text has been retained in Catbird.",
        comment: "Error when the active Catbird account changes after saving a chat draft durably."
      )
    )
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

    return .result(
      dialog: Self.dialog(
        for: result,
        hasConversation: conversationID != nil,
        droppedUnsupportedContent: droppedUnsupportedContent
      )
    )
  }

  private static func startedInCatbirdDialog(droppedUnsupportedContent: Bool) -> IntentDialog {
    guard droppedUnsupportedContent else {
      return IntentDialog(
        LocalizedStringResource(
          "Draft started in Catbird.",
          comment: "Spoken confirmation when a chat draft opens in the target Catbird conversation."
        )
      )
    }
    return IntentDialog(
      LocalizedStringResource(
        "Draft started in Catbird. Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over.",
        comment: "Spoken confirmation when a chat draft opens in Catbird and unsupported attachments were omitted."
      )
    )
  }

  private static func dialog(
    for result: SceneRouteCoordinator.DeliveryResult,
    hasConversation: Bool,
    droppedUnsupportedContent: Bool
  ) -> IntentDialog {
    switch (result, hasConversation, droppedUnsupportedContent) {
    case (.delivered(_), false, false):
      return IntentDialog(
        LocalizedStringResource(
          "Pick a conversation in Catbird to start your draft.",
          comment: "Spoken confirmation when a chat draft opens Catbird without a specific conversation selected."
        )
      )
    case (.delivered(_), false, true):
      return IntentDialog(
        LocalizedStringResource(
          "Pick a conversation in Catbird to start your draft. Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over.",
          comment: "Spoken confirmation when a chat draft opens Catbird without a conversation and unsupported attachments were omitted."
        )
      )
    case (.delivered(_), true, _):
      return startedInCatbirdDialog(droppedUnsupportedContent: droppedUnsupportedContent)
    case (.queued, _, false), (.duplicate, _, false):
      return IntentDialog(
        LocalizedStringResource(
          "Your draft is waiting for its Catbird window to become available.",
          comment: "Spoken status when a chat draft is queued waiting for the target app scene."
        )
      )
    case (.queued, _, true), (.duplicate, _, true):
      return IntentDialog(
        LocalizedStringResource(
          "Your draft is waiting for its Catbird window to become available. Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over.",
          comment: "Spoken status when a chat draft is queued for its window and unsupported attachments were omitted."
        )
      )
    case (.dropped(_), _, false):
      return IntentDialog(
        LocalizedStringResource(
          "Catbird couldn't open the intended window. Your draft text has been retained.",
          comment: "Spoken status when the target scene could not open, confirming the draft text was saved."
        )
      )
    case (.dropped(_), _, true):
      return IntentDialog(
        LocalizedStringResource(
          "Catbird couldn't open the intended window. Your draft text has been retained. Attachments, audio, locations, and scheduling aren't supported yet — the text was carried over.",
          comment: "Spoken status when the target scene could not open and unsupported attachments were omitted."
        )
      )
    }
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct CatbirdSendMessageSchemaIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Send Catbird Message",
    comment: "Messages App Schema intent title for sending an encrypted Catbird chat message."
  )

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
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "Catbird Messages App Schema currently supports text only.",
          comment: "Error spoken by Siri when attempting to send unsupported attachment types via Catbird chat."
        )
      )
    }

    let text = try MessagesSchemaRuntime.text(from: content ?? AttributedString(""))
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)

    let recipients = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    let target = try await MessagesSchemaRuntime.resolveDestination(
      recipients: recipients, coordinator: coordinator, directory: directory)
    try await IntentClientProvider.shared.requireCoveredUse(for: directory.currentUserDID)
    let finalConvoId: String
    let sentMessageID: String
    let sentAt: Date
    switch target {
    case .existing(let conversationID):
      let row = try await coordinator.sendMessage(conversationId: conversationID, text: text)
      finalConvoId = conversationID
      sentMessageID = row.messageId
      sentAt = Date(timeIntervalSince1970: Double(row.createdAtMs) / 1_000.0)
    case .recipientDraft(var draft):
      guard !draft.submitted || draft.text == text else {
        throw IntentError.invalidParameter(
          LocalizedStringResource(
            "A different saved request is still resolving. Open Catbird to retry or cancel it.",
            comment: "Error when another chat request to the same recipient is already pending."
          )
        )
      }
      draft.text = text
      draft.submitted = true
      try MLSDirectComposeDraftStore.validateText(text)
      MLSDirectComposeDraftStore.save(draft)
      let sequencerDID = await MainActor.run {
        AppStateManager.shared.lifecycle.appState?.defaultMLSSequencerDID ?? "did:web:chat.catbird.blue"
      }
      let outcome = try await MLSDirectChatStart.start(
        coordinator: coordinator,
        sequencerDID: sequencerDID,
        recipientDID: draft.recipientDID,
        text: text
      )
      switch outcome.delivery {
      case .sentWithRequest, .sentAsMessage:
        break
      case .earlierRequestWaiting:
        throw IntentError.invalidParameter(
          LocalizedStringResource(
            "You’ve already sent this person a request. You can send more messages once they accept it.",
            comment: "Error when trying to send an MLS chat message while an outgoing request is still awaiting acceptance."
          )
        )
      case .theirRequestWaiting:
        throw IntentError.invalidParameter(
          LocalizedStringResource(
            "This person has sent you a request. Accept it in Requests to reply.",
            comment: "Error when trying to send an MLS chat message while an incoming chat request from that person awaits acceptance."
          )
        )
      }
      finalConvoId = outcome.conversationID
      sentMessageID = outcome.messageID ?? UUID().uuidString.lowercased()
      sentAt = outcome.sentAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000.0) } ?? Date()
      MLSDirectComposeDraftStore.archive(draft)
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
    let preview = AttributedString(
      String(
        localized: "MLS Chat",
        comment: "Preview label for an encrypted MLS chat conversation."
      )
    )

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

    return .result(
      value: [entity],
      dialog: IntentDialog(
        LocalizedStringResource(
          "Sent.",
          comment: "Spoken confirmation after sending an encrypted Catbird chat message."
        )
      )
    )
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
struct CatbirdEditSentMessageSchemaIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Edit Catbird Message",
    comment: "Messages App Schema intent title for editing a previously sent Catbird chat message."
  )

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  @Parameter(title: "Content")
  var content: AttributedString

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let editedText = try MessagesSchemaRuntime.text(from: content)
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let conversationID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      coordinator: coordinator
    )
    let payloadData = try MLSMessagePayload.edit(
      targetMessageId: message.id,
      newText: editedText
    ).encodeToJSON()
    guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
      throw IntentError.serviceUnavailable(
        LocalizedStringResource(
          "Could not encode message edit payload.",
          comment: "Error when encoding an edited chat message fails."
        )
      )
    }
    _ = try await coordinator.sendMessage(conversationId: conversationID, text: payloadJSON)
    return .result(
      dialog: IntentDialog(
        LocalizedStringResource(
          "Updated message.",
          comment: "Spoken confirmation after editing a sent Catbird chat message."
        )
      )
    )
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct CatbirdUnsendMessageSchemaIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Unsend Catbird Message",
    comment: "Messages App Schema intent title for unsending a Catbird chat message."
  )

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let conversationID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      coordinator: coordinator
    )
    _ = try await coordinator.unsendMessage(
      conversationId: conversationID,
      messageId: message.id
    )
    return .result(
      dialog: IntentDialog(
        LocalizedStringResource(
          "Unsent message.",
          comment: "Spoken confirmation after unsending a Catbird chat message."
        )
      )
    )
  }
}

@available(anyAppleOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct CatbirdSetMessageReadStatusSchemaIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Set Catbird Message Read Status",
    comment: "Messages App Schema intent title for marking a Catbird chat message read or unread."
  )

  @Parameter(title: "Message")
  var message: CatbirdMessagesMessageEntity

  @Parameter(title: "Read")
  var isRead: Bool

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let canonicalID = try await MessagesSchemaRuntime.resolveConversationID(
      message.conversation.id,
      coordinator: coordinator
    )
    if isRead {
      let rows = try await coordinator.listMessages(conversationId: canonicalID, limit: 100)
      if let targetRow = rows.first(where: { $0.messageId == message.id }) ?? rows.first {
        try await coordinator.markConversationRead(
          conversationId: canonicalID,
          readThroughSeq: targetRow.seq
        )
        try await coordinator.acknowledgeEntriesUpTo(
          conversationId: canonicalID,
          upToSeq: targetRow.seq
        )
        if targetRow.seq > 0 {
          _ = try? await coordinator.advanceReadState(
            conversationId: canonicalID,
            candidateSeq: UInt64(targetRow.seq)
          )
        }
      }
    }

    let dialog = isRead
      ? IntentDialog(
          LocalizedStringResource(
            "Marked read.",
            comment: "Spoken confirmation after marking a Catbird chat message as read."
          )
        )
      : IntentDialog(
          LocalizedStringResource(
            "Marked unread.",
            comment: "Spoken confirmation after marking a Catbird chat message as unread."
          )
        )
    return .result(dialog: dialog)
  }
}

#endif
