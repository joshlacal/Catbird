//
//  MessagesSchemaEntities.swift
//  Catbird
//
//  iOS 27 Messages App Schema entities for Catbird MLS chat.
//

#if os(iOS)

import AppIntents
import CatbirdMLSCore
import CoreTransferable
import Foundation
import Petrel
import PetrelCatbird
import LinkPresentation
import GeoToolbox

@available(iOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum CatbirdMessagesConversationAttribute: String, AppEnum {
  case mute
  case group
  case pinned

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .mute: "Muted",
    .group: "Group Chat",
    .pinned: "Pinned"
  ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum CatbirdMessagesMessageType: String, AppEnum {
  case text
  case audio
  case image
  case video
  case unspecified

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .text: "Text",
    .audio: "Audio",
    .image: "Image",
    .video: "Video",
    .unspecified: "Unspecified"
  ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum CatbirdMessagesMessageAttribute: String, AppEnum {
  case none

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: "None"
  ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum CatbirdMessagesMessageEffect: String, AppEnum {
  case none

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: "None"
  ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum CatbirdMessagesCustomReaction: String, AppEnum {
  case like
  case love
  case laughter
  case dislike
  case question
  case exclamation

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .like: "Like",
    .love: "Love",
    .laughter: "Laughter",
    .dislike: "Dislike",
    .question: "Question",
    .exclamation: "Exclamation"
  ]
}

@available(iOS 27.0, *)
@UnionValue
enum CatbirdMessagesReadReaction: Sendable {
  case customReaction(CatbirdMessagesCustomReaction)
}

@available(iOS 27.0, *)
@UnionValue
enum CatbirdMessagesDestination: Sendable {
  case persons([IntentPerson])
  case recipient(CatbirdMessagesPersonEntity)
  case recipients([CatbirdMessagesPersonEntity])
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct CatbirdMessagesCustomAttachment: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Catbird Attachment")
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
    let titleStr = description.map { String($0.characters) } ?? "Attachment"
    return DisplayRepresentation(title: "\(titleStr)")
  }
}

@available(iOS 27.0, *)
struct CatbirdMessagesCustomAttachmentQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesCustomAttachment] {
    return []
  }
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct CatbirdMessagesConversationEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Catbird Conversation")
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
      subtitle: recipients.count == 1 ? "1 member" : "\(recipients.count) members"
    )
  }
}

@available(iOS 27.0, *)
struct CatbirdMessagesConversationQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesConversationEntity] {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
    let byID = Dictionary(
      uniqueKeysWithValues: directory.conversations.map { ($0.conversationID, $0) })

    return identifiers.compactMap { id in
      byID[id].map { MessagesSchemaRuntime.conversationEntity(model: $0, directory: directory) }
    }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesConversationEntity] {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
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

@available(iOS 27.0, *)
@AppEntity(schema: .messages.message)
struct CatbirdMessagesMessageEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Catbird Message")
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
    return DisplayRepresentation(
      title: "\(textStr.isEmpty ? "Message" : textStr)",
      subtitle: "\(conversation.displayName)"
    )
  }
}

@available(iOS 27.0, *)
struct CatbirdMessagesMessageQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesMessageEntity] {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
    let byID = Dictionary(
      uniqueKeysWithValues: directory.conversations.map { ($0.conversationID, $0) })

    var entities: [CatbirdMessagesMessageEntity] = []
    for identifier in identifiers {
      let message = try await MessagesSchemaRuntime.fetchMessage(identifier, manager: manager)
      let title = byID[message.conversationID].map { directory.title(for: $0) }
      entities.append(
        MessagesSchemaRuntime.messageEntity(
          from: message, conversationTitle: title, directory: directory)
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
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let userDID = manager.userDid else {
      throw IntentError.notSignedIn
    }

    var matchingEntities: [CatbirdMessagesMessageEntity] = []
    for convo in directory.conversations.prefix(conversationLimit) {
      let messages = try await manager.storage.fetchMessagesForConversation(
        convo.conversationID,
        currentUserDID: userDID,
        database: manager.database,
        limit: messagesPerConversation
      )

      for message in messages {
        let plaintext = message.plaintext ?? ""
        if trimmed.isEmpty || plaintext.localizedCaseInsensitiveContains(trimmed) {
          matchingEntities.append(
            MessagesSchemaRuntime.messageEntity(
              from: message,
              conversationTitle: directory.title(for: convo),
              directory: directory)
          )
        }
      }
    }
    return matchingEntities
  }
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct CatbirdMessagesPersonEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Catbird Contact")
  static var defaultQuery = CatbirdMessagesPersonQuery()

  var id: String
  var displayName: String
  var person: IntentPerson

  init(id: String, displayName: String, isMe: Bool = false) {
    self.id = id
    self.displayName = displayName

    var nameComponents = PersonNameComponents()
    nameComponents.givenName = displayName
    self.person = IntentPerson(
      identifier: .unknown,
      name: .components(nameComponents),
      handle: nil,
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
    DisplayRepresentation(title: "\(displayName)", subtitle: "\(id)")
  }
}

// Apple Intelligence can pass message entities to other apps and system
// experiences when they're Transferable — export the message body as text.
@available(iOS 27.0, *)
extension CatbirdMessagesMessageEntity: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: { entity in
      entity.body.map { String($0.characters) } ?? ""
    })
  }
}

@available(iOS 27.0, *)
struct CatbirdMessagesPersonQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesPersonEntity] {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)

    return identifiers.map { did in
      if let member = directory.member(withDID: did) {
        return MessagesSchemaRuntime.personEntity(from: member, directory: directory)
      }
      return CatbirdMessagesPersonEntity(id: did, displayName: String(did.suffix(8)))
    }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesPersonEntity] {
    let manager = try await MessagesSchemaRuntime.conversationManager()
    let directory = try await MessagesSchemaRuntime.directory(manager: manager)
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
