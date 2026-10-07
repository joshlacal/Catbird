//
//  MessagesSchemaEntities.swift
//  Catbird
//
//  iOS 27 Messages App Schema entities for Bluesky direct messages.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import CoreTransferable
import Foundation
import Petrel
import LinkPresentation
import GeoToolbox

@available(anyAppleOS 27.0, *)
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

@available(anyAppleOS 27.0, *)
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

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum CatbirdMessagesMessageAttribute: String, AppEnum {
  case none

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: "None"
  ]
}

@available(anyAppleOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum CatbirdMessagesMessageEffect: String, AppEnum {
  case none

  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .none: "None"
  ]
}

@available(anyAppleOS 27.0, *)
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

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesCustomAttachmentQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesCustomAttachment] {
    return []
  }
}

@available(anyAppleOS 27.0, *)
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

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesConversationQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesConversationEntity] {
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
    let byID = Dictionary(
      directory.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var result: [CatbirdMessagesConversationEntity] = []
    for id in identifiers {
      if let convo = byID[id] {
        result.append(MessagesSchemaRuntime.conversationEntity(convo: convo, directory: directory))
      } else if let output = try? unwrapIntentResponse(
        await client.chat.bsky.convo.getConvo(input: ChatBskyConvoGetConvo.Parameters(convoId: id))) {
        // Older conversation outside the recent-list window.
        let convo = output.convo
        var membersByConvoID = directory.membersByConvoID
        membersByConvoID[convo.id] = convo.members.map {
          MessagesSchemaRuntime.Member(
            did: $0.did.didString(), displayName: $0.displayName, handle: $0.handle.value)
        }
        let extended = MessagesSchemaRuntime.ChatDirectory(
          conversations: directory.conversations + [convo],
          membersByConvoID: membersByConvoID,
          currentUserDID: directory.currentUserDID
        )
        result.append(MessagesSchemaRuntime.conversationEntity(convo: convo, directory: extended))
      }
    }
    return result
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesConversationEntity] {
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

    // Conversations arrive recency-ordered. Match the title OR any member's
    // name/handle, so "messages with Alex" resolves the conversation even
    // when it has an explicit group name.
    return directory.conversations
      .filter { convo in
        guard !trimmed.isEmpty else { return true }
        if directory.title(for: convo).localizedCaseInsensitiveContains(trimmed) {
          return true
        }
        return directory.members(in: convo.id).contains { member in
          directory.name(for: member).localizedCaseInsensitiveContains(trimmed)
            || (directory.handle(for: member)?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
      }
      .map { MessagesSchemaRuntime.conversationEntity(convo: $0, directory: directory) }
  }

  func suggestedEntities() async throws -> [CatbirdMessagesConversationEntity] {
    try await entities(matching: "")
  }
}

@available(anyAppleOS 27.0, *)
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

@available(anyAppleOS 27.0, *)
struct CatbirdMessagesMessageQuery: EntityStringQuery {
  /// chat.bsky has no fetch-message-by-ID endpoint, so identifiers are looked
  /// up in the recent history of the most recent conversations.
  func entities(for identifiers: [String]) async throws -> [CatbirdMessagesMessageEntity] {
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
    var remaining = Set(identifiers)
    var found: [String: CatbirdMessagesMessageEntity] = [:]

    for convo in directory.conversations.prefix(10) where !remaining.isEmpty {
      let messages = try await MessagesSchemaRuntime.recentMessages(
        in: convo.id, limit: 50, client: client)
      for message in messages where remaining.contains(message.id) {
        remaining.remove(message.id)
        found[message.id] = MessagesSchemaRuntime.messageEntity(
          from: message, convo: convo, directory: directory)
      }
    }
    return identifiers.compactMap { found[$0] }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesMessageEntity] {
    try await matchingEntities(string, conversationLimit: 10, messagesPerConversation: 25)
  }

  func suggestedEntities() async throws -> [CatbirdMessagesMessageEntity] {
    try await matchingEntities("", conversationLimit: 5, messagesPerConversation: 10)
  }

  /// Siri runs these queries synchronously during a request, so both entry
  /// points are capped: conversations arrive recency-ordered, and only the
  /// most recent few are scanned.
  private func matchingEntities(
    _ string: String,
    conversationLimit: Int,
    messagesPerConversation: Int
  ) async throws -> [CatbirdMessagesMessageEntity] {
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

    var matchingEntities: [CatbirdMessagesMessageEntity] = []
    for convo in directory.conversations.prefix(conversationLimit) {
      let messages = try await MessagesSchemaRuntime.recentMessages(
        in: convo.id, limit: messagesPerConversation, client: client)
      for message in messages
      where trimmed.isEmpty || message.text.localizedCaseInsensitiveContains(trimmed) {
        matchingEntities.append(
          MessagesSchemaRuntime.messageEntity(from: message, convo: convo, directory: directory))
      }
    }
    return matchingEntities
  }
}

@available(anyAppleOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct CatbirdMessagesPersonEntity: Identifiable, Hashable, Sendable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Catbird Contact")
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
    DisplayRepresentation(title: "\(displayName)", subtitle: handle.map { "@\($0)" })
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
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)

    return identifiers.map { did in
      if let member = directory.member(withDID: did) {
        return MessagesSchemaRuntime.personEntity(from: member, directory: directory)
      }
      return CatbirdMessagesPersonEntity(id: did, displayName: String(did.suffix(8)))
    }
  }

  func entities(matching string: String) async throws -> [CatbirdMessagesPersonEntity] {
    let client = try await MessagesSchemaRuntime.client()
    let directory = try await MessagesSchemaRuntime.directory(client: client)
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
