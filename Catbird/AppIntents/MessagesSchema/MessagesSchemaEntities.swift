//
//  MessagesSchemaEntities.swift
//  Catbird
//
//  iOS 27 Messages App Schema entities for Catbird MLS chat.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import CatbirdMLSCore
import CoreTransferable
import Foundation
import Petrel
import PetrelCatbird
import LinkPresentation
import GeoToolbox

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum CatbirdMessagesConversationAttribute: String, AppEnum {
  case mute = "mute"
  case group = "group"
  case pinned = "pinned"

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .mute: DisplayRepresentation(
      title: LocalizedStringResource("Muted", comment: "Conversation attribute indicating notifications are muted.")
    ),
    .group: DisplayRepresentation(
      title: LocalizedStringResource("Group Chat", comment: "Conversation attribute indicating a multi-person group chat.")
    ),
    .pinned: DisplayRepresentation(
      title: LocalizedStringResource("Pinned", comment: "Conversation attribute indicating a pinned conversation.")
    )
  ]
}

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum CatbirdMessagesMessageType: String, AppEnum {
  case text = "text"
  case audio = "audio"
  case image = "image"
  case video = "video"
  case unspecified = "unspecified"

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .text: DisplayRepresentation(
      title: LocalizedStringResource("Text", comment: "Message type for plain text chat messages.")
    ),
    .audio: DisplayRepresentation(
      title: LocalizedStringResource("Audio", comment: "Message type for audio chat messages.")
    ),
    .image: DisplayRepresentation(
      title: LocalizedStringResource("Image", comment: "Message type for image chat messages.")
    ),
    .video: DisplayRepresentation(
      title: LocalizedStringResource("Video", comment: "Message type for video chat messages.")
    ),
    .unspecified: DisplayRepresentation(
      title: LocalizedStringResource("Unspecified", comment: "Fallback message type when the chat content kind is unspecified.")
    )
  ]
}

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum CatbirdMessagesMessageAttribute: String, AppEnum {
  case none = "none"

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: DisplayRepresentation(
      title: LocalizedStringResource("None", comment: "Indicates a chat message has no special attributes.")
    )
  ]
}

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum CatbirdMessagesMessageEffect: String, AppEnum {
  case none = "none"

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: DisplayRepresentation(
      title: LocalizedStringResource("None", comment: "Indicates a chat message has no visual effect.")
    )
  ]
}

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum CatbirdMessagesCustomReaction: String, AppEnum {
  case like = "like"
  case love = "love"
  case laughter = "laughter"
  case dislike = "dislike"
  case question = "question"
  case exclamation = "exclamation"

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .like: DisplayRepresentation(
      title: LocalizedStringResource("Like", comment: "Message reaction name for thumbs-up / like.")
    ),
    .love: DisplayRepresentation(
      title: LocalizedStringResource("Love", comment: "Message reaction name for heart / love.")
    ),
    .laughter: DisplayRepresentation(
      title: LocalizedStringResource("Laughter", comment: "Message reaction name for laughing.")
    ),
    .dislike: DisplayRepresentation(
      title: LocalizedStringResource("Dislike", comment: "Message reaction name for thumbs-down / dislike.")
    ),
    .question: DisplayRepresentation(
      title: LocalizedStringResource("Question", comment: "Message reaction name for a question mark.")
    ),
    .exclamation: DisplayRepresentation(
      title: LocalizedStringResource("Exclamation", comment: "Message reaction name for an exclamation mark.")
    )
  ]
}

@available(anyAppleOS 27.0, *)
@UnionValue
enum CatbirdMessagesReadReaction: Sendable {
  case customReaction(CatbirdMessagesCustomReaction)
}

@available(anyAppleOS 27.0, *)
@UnionValue
enum CatbirdMessagesDestination: Sendable {
  case persons([IntentPerson])
  case recipient(CatbirdMessagesPersonEntity)
  case recipients([CatbirdMessagesPersonEntity])
}

@available(anyAppleOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct CatbirdMessagesCustomAttachment: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource(
      "Catbird Attachment",
      comment: "App Intents entity type name for a Catbird chat attachment."
    ),
    numericFormat: LocalizedStringResource(
      "\(placeholder: .int) Catbird attachments",
      comment: "Pluralized count of Catbird chat attachments."
    )
  )
  static var defaultQuery = CatbirdMessagesCustomAttachmentQuery()

  var id: String
  var sourceName: AttributedString?
  var description: AttributedString?

  init(id: String, sourceName: AttributedString?, description: AttributedString?) {
    self.id = id
    self.sourceName = sourceName
    self.description = description
  }

  static func == (lhs: CatbirdMessagesCustomAttachment, rhs: CatbirdMessagesCustomAttachment) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var displayRepresentation: DisplayRepresentation {
    if let description, !description.characters.isEmpty {
      return DisplayRepresentation(title: "\(String(description.characters))")
    }
    return DisplayRepresentation(
      title: LocalizedStringResource(
        "Attachment",
        comment: "Fallback display title for a Catbird chat attachment with no description."
      )
    )
  }
}

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesCustomAttachmentQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesCustomAttachment] {
    return []
  }
}

@available(anyAppleOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct CatbirdMessagesConversationEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource(
      "Catbird Conversation",
      comment: "App Intents entity type name for a Catbird MLS chat conversation."
    ),
    numericFormat: LocalizedStringResource(
      "\(placeholder: .int) Catbird conversations",
      comment: "Pluralized count of Catbird MLS chat conversations."
    )
  )
  static var defaultQuery = CatbirdMessagesConversationQuery()

  var id: String
  var recipients: [CatbirdMessagesPersonEntity]
  var displayName: String
  var previewText: AttributedString
  var conversationName: String?
  var isRead: Bool
  var attributes: Set<CatbirdMessagesConversationAttribute>
  var dateLastActive: Date?

  init(
    id: String,
    recipients: [CatbirdMessagesPersonEntity],
    displayName: String,
    previewText: AttributedString,
    conversationName: String?,
    isRead: Bool,
    attributes: Set<CatbirdMessagesConversationAttribute>,
    dateLastActive: Date?
  ) {
    self.id = id
    self.recipients = recipients
    self.displayName = displayName
    self.previewText = previewText
    self.conversationName = conversationName
    self.isRead = isRead
    self.attributes = attributes
    self.dateLastActive = dateLastActive
  }

  static func == (lhs: CatbirdMessagesConversationEntity, rhs: CatbirdMessagesConversationEntity) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(displayName)",
      subtitle: LocalizedStringResource(
        "\(recipients.count) members",
        comment: "Member count subtitle for a Catbird MLS chat conversation in Siri and Shortcuts."
      )
    )
  }
}

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesConversationQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesConversationEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
    let byID = Dictionary(
      uniqueKeysWithValues: directory.conversations.map { ($0.conversationID, $0) })

    return identifiers.compactMap { id in
      guard let canonicalID = try? MessagesSchemaRuntime.resolveConversationID(id, in: directory),
            let model = byID[canonicalID] else { return nil }
      return MessagesSchemaRuntime.conversationEntity(model: model, directory: directory)
    }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesConversationEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

    // Conversations arrive lastMessageAt-descending from storage. Match the
    // title OR any member's name/handle, so "messages with Alex" resolves the
    // conversation even when it has an explicit group title.
    return directory.conversations
      .filter { model in
        guard !trimmed.isEmpty else { return true }
        if directory.title(for: model).localizedCaseInsensitiveContains(trimmed) {
          return true
        }
        return directory.members(in: model.conversationID).contains { member in
          directory.name(for: member).localizedCaseInsensitiveContains(trimmed)
            || (directory.handle(for: member)?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
      }
      .map { MessagesSchemaRuntime.conversationEntity(model: $0, directory: directory) }
  }

  func suggestedEntities() async throws -> [CatbirdMessagesConversationEntity] {
    try await entities(matching: "")
  }
}

@available(anyAppleOS 27.0, *)
@AppEntity(schema: .messages.message)
struct CatbirdMessagesMessageEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource(
      "Catbird Message",
      comment: "App Intents entity type name for a Catbird MLS chat message."
    ),
    numericFormat: LocalizedStringResource(
      "\(placeholder: .int) Catbird messages",
      comment: "Pluralized count of Catbird MLS chat messages."
    )
  )
  static var defaultQuery = CatbirdMessagesMessageQuery()

  var id: String
  var messageType: CatbirdMessagesMessageType
  var author: CatbirdMessagesPersonEntity
  var isRead: Bool
  var attributes: Set<CatbirdMessagesMessageAttribute>
  var conversation: CatbirdMessagesConversationEntity
  var date: Date
  var subject: AttributedString?
  var body: AttributedString?
  var attachments: [IntentFile]
  var audioMessage: IntentFile?
  var customAttachments: [CatbirdMessagesCustomAttachment]
  var locations: [GeoToolbox.PlaceDescriptor]
  var links: [LinkPresentation.LinkMetadata]
  var messageEffect: CatbirdMessagesMessageEffect?
  var reaction: CatbirdMessagesReadReaction?
  var referencedMessage: CatbirdMessagesMessageEntity?
  var notificationIdentifier: String?

  init(
    id: String,
    messageType: CatbirdMessagesMessageType,
    author: CatbirdMessagesPersonEntity,
    isRead: Bool,
    attributes: Set<CatbirdMessagesMessageAttribute>,
    conversation: CatbirdMessagesConversationEntity,
    date: Date,
    subject: AttributedString?,
    body: AttributedString?,
    attachments: [IntentFile],
    audioMessage: IntentFile?,
    customAttachments: [CatbirdMessagesCustomAttachment],
    locations: [GeoToolbox.PlaceDescriptor],
    links: [LinkPresentation.LinkMetadata],
    messageEffect: CatbirdMessagesMessageEffect?,
    reaction: CatbirdMessagesReadReaction?,
    referencedMessage: CatbirdMessagesMessageEntity?,
    notificationIdentifier: String?
  ) {
    self.id = id
    self.messageType = messageType
    self.author = author
    self.isRead = isRead
    self.attributes = attributes
    self.conversation = conversation
    self.date = date
    self.subject = subject
    self.body = body
    self.attachments = attachments
    self.audioMessage = audioMessage
    self.customAttachments = customAttachments
    self.locations = locations
    self.links = links
    self.messageEffect = messageEffect
    self.reaction = reaction
    self.referencedMessage = referencedMessage
    self.notificationIdentifier = notificationIdentifier
  }

  static func == (lhs: CatbirdMessagesMessageEntity, rhs: CatbirdMessagesMessageEntity) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var displayRepresentation: DisplayRepresentation {
    let textStr = body.map { String($0.characters) } ?? ""
    let title: LocalizedStringResource = textStr.isEmpty
      ? LocalizedStringResource(
          "Message",
          comment: "Fallback display title for a Catbird chat message with empty text."
        )
      : "\(textStr)"
    return DisplayRepresentation(
      title: title,
      subtitle: "\(conversation.displayName)"
    )
  }
}

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesMessageQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesMessageEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
    let byID = Dictionary(
      uniqueKeysWithValues: directory.conversations.map { ($0.conversationID, $0) })

    var entities: [CatbirdMessagesMessageEntity] = []
    for identifier in identifiers {
      let message = try await MessagesSchemaRuntime.fetchMessage(identifier, coordinator: coordinator)
      guard let canonicalID = try? MessagesSchemaRuntime.resolveConversationID(
        message.conversationID,
        in: directory
      ) else {
        continue
      }
      let title = byID[canonicalID].map { directory.title(for: $0) }
      entities.append(
        MessagesSchemaRuntime.messageEntity(
          from: message,
          conversationTitle: title,
          directory: directory,
          conversationIDOverride: canonicalID
        )
      )
    }
    return entities
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesMessageEntity] {
    try await matchingEntities(string, conversationLimit: 10, messagesPerConversation: 25)
  }

  func suggestedEntities() async throws -> [CatbirdMessagesMessageEntity] {
    try await matchingEntities("", conversationLimit: 5, messagesPerConversation: 10)
  }

  /// Siri runs these queries synchronously during a request, so both entry
  /// points are capped: conversations arrive recency-ordered from storage, and
  /// only the most recent few are scanned.
  private func matchingEntities(
    _ string: String,
    conversationLimit: Int,
    messagesPerConversation: Int
  ) async throws -> [CatbirdMessagesMessageEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let userDID = await coordinator.accountDid

    var matchingEntities: [CatbirdMessagesMessageEntity] = []
    for convo in directory.conversations.prefix(conversationLimit) {
      let rows = try await coordinator.listMessages(
        conversationId: convo.conversationID,
        limit: UInt32(max(1, messagesPerConversation))
      )

      for row in rows {
        let message = MLSMessageModel(row: row, currentUserDID: userDID)
        let plaintext = message.parsedPayload()?.text ?? ""
        if trimmed.isEmpty || plaintext.localizedCaseInsensitiveContains(trimmed) {
          matchingEntities.append(
            MessagesSchemaRuntime.messageEntity(
              from: message,
              conversationTitle: directory.title(for: convo),
              directory: directory,
              conversationIDOverride: convo.conversationID)
          )
        }
      }
    }
    return matchingEntities
  }
}

@available(anyAppleOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct CatbirdMessagesPersonEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource(
      "Catbird Contact",
      comment: "App Intents entity type name for a Catbird MLS chat participant."
    ),
    numericFormat: LocalizedStringResource(
      "\(placeholder: .int) Catbird contacts",
      comment: "Pluralized count of Catbird MLS chat participants."
    )
  )
  static var defaultQuery = CatbirdMessagesPersonQuery()

  var id: String
  var displayName: String
  /// Bluesky handle without the leading `@`, when known.
  var handle: String?
  var person: IntentPerson

  init(id: String, displayName: String, handle: String? = nil, isMe: Bool = false) {
    self.id = id
    self.displayName = displayName
    self.handle = handle
    self.person = IntentPerson(
      identifier: .applicationDefined(id),
      name: .displayName(displayName),
      handle: handle.map { IntentPerson.Handle(applicationDefined: $0, label: nil) },
      isMe: isMe
    )
  }

  static func == (lhs: CatbirdMessagesPersonEntity, rhs: CatbirdMessagesPersonEntity) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var displayRepresentation: DisplayRepresentation {
    // Siri shows this in disambiguation lists — a handle, never a raw DID.
    let formattedHandle = handle.map { "@\($0)" }
    return DisplayRepresentation(
      title: "\(displayName)",
      subtitle: formattedHandle.map { "\($0)" }
    )
  }
}

// Apple Intelligence can pass message entities to other apps and system
// experiences when they're Transferable — export the message body as text.
@available(anyAppleOS 27.0, *)
extension CatbirdMessagesMessageEntity: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: { entity in
      entity.body.map { String($0.characters) } ?? ""
    })
  }
}

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesPersonQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesPersonEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)

    return identifiers.map { did in
      if let member = directory.member(withDID: did) {
        return MessagesSchemaRuntime.personEntity(from: member, directory: directory)
      }
      return CatbirdMessagesPersonEntity(id: did, displayName: String(did.suffix(8)))
    }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesPersonEntity] {
    let coordinator = try await MessagesSchemaRuntime.coordinator()
    let directory = try await MessagesSchemaRuntime.directory(coordinator: coordinator)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

    // Candidates are chat members (excluding self), recency-ordered. Siri
    // matches spoken names against displayName/handle — these must be human
    // names, never raw DIDs, or resolution falls through to Contacts.
    return directory.recipientCandidates()
      .filter { member in
        guard !trimmed.isEmpty else { return true }
        return directory.name(for: member).localizedCaseInsensitiveContains(trimmed)
          || (directory.handle(for: member)?.localizedCaseInsensitiveContains(trimmed) ?? false)
      }
      .map { MessagesSchemaRuntime.personEntity(from: $0, directory: directory) }
  }

  func suggestedEntities() async throws -> [CatbirdMessagesPersonEntity] {
    try await entities(matching: "")
  }
}

#endif
