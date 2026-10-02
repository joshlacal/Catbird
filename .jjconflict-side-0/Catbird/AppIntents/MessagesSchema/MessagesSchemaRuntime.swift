//
//  MessagesSchemaRuntime.swift
//  Catbird
//
//  Runtime bridge for iOS 27 Messages App Schema intents, backed by Bluesky
//  direct messages (chat.bsky.convo). All calls go through the standalone
//  IntentClientProvider client, so they work without the app UI running.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import Foundation
import Petrel
import LinkPresentation
import GeoToolbox

@available(anyAppleOS 27.0, *)
enum MessagesSchemaRuntime {
  static func client() async throws -> ATProtoClient {
    try await IntentClientProvider.shared.client(for: IntentAccountResolver.activeDID())
  }

  static func text(from attributedString: AttributedString) throws -> String {
    let text = String(attributedString.characters)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw IntentError.invalidParameter("Message content cannot be empty.")
    }
    return text
  }

  /// Resolves a schema destination to recipient DIDs + display names.
  /// `.persons` values (Siri-resolved contacts) are matched by spoken name
  /// against the user's existing chat members — a contact's phone number or
  /// email is never a DID, so identifier-based resolution is impossible.
  static func recipients(
    for destination: CatbirdMessagesDestination,
    directory: ChatDirectory
  ) throws -> [(did: String, displayName: String)] {
    switch destination {
    case .recipient(let entity):
      return [(entity.id, entity.displayName)]

    case .recipients(let entities):
      guard !entities.isEmpty else {
        throw IntentError.invalidParameter("No recipients specified.")
      }
      return entities.map { ($0.id, $0.displayName) }

    case .persons(let persons):
      guard !persons.isEmpty else {
        throw IntentError.invalidParameter("No recipients specified.")
      }
      return try persons.map { person in
        guard let name = spokenName(for: person) else {
          throw IntentError.invalidParameter(
            "That contact has no name Catbird can match against your chats.")
        }
        guard let member = member(matchingName: name, in: directory) else {
          throw IntentError.invalidParameter(
            "Couldn't find \"\(name)\" in your Catbird chats.")
        }
        return (member.did, directory.name(for: member))
      }
    }
  }

  /// Best display string for a Siri-resolved person.
  static func spokenName(for person: IntentPerson) -> String? {
    switch person.name {
    case .displayName(let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case .components(let components):
      let formatted = PersonNameComponentsFormatter.localizedString(
        from: components, style: .default)
      let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    default:
      return nil
    }
  }

  /// First chat member (recency-ordered, excluding self) whose resolved name
  /// or handle contains `name`, case-insensitively.
  static func member(matchingName name: String, in directory: ChatDirectory) -> Member? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return directory.recipientCandidates().first { member in
      directory.name(for: member).localizedCaseInsensitiveContains(trimmed)
        || (directory.handle(for: member)?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }
  }

  /// Pure matcher: the first conversation (in `conversationOrder`) whose
  /// non-self member DID set equals `recipientDIDs` (case-insensitive).
  static func conversationID(
    matching recipientDIDs: [String],
    in membersByConvoID: [String: [String]],
    conversationOrder: [String],
    selfDID: String
  ) -> String? {
    let target = Set(recipientDIDs.map { $0.lowercased() })
    guard !target.isEmpty else { return nil }
    let selfLowered = selfDID.lowercased()
    for convoID in conversationOrder {
      let members = Set(
        (membersByConvoID[convoID] ?? [])
          .map { $0.lowercased() }
          .filter { $0 != selfLowered }
      )
      if members == target {
        return convoID
      }
    }
    return nil
  }

  /// Existing conversation with exactly these recipients, else the
  /// conversation chat.bsky returns for the member set (created on demand).
  static func resolveDestination(
    recipients: [(did: String, displayName: String)],
    client: ATProtoClient,
    directory: ChatDirectory
  ) async throws -> String {
    guard !recipients.isEmpty else { throw IntentError.invalidParameter("No recipients specified.") }
    if let existing = conversationID(
      matching: recipients.map(\.did),
      in: directory.membersByConvoID.mapValues { $0.map(\.did) },
      conversationOrder: directory.conversations.map(\.id),
      selfDID: directory.currentUserDID
    ) {
      return existing
    }
    let members = try recipients.map { try DID(didString: $0.did) }
    let (code, data) = try await client.chat.bsky.convo.getConvoForMembers(
      input: ChatBskyConvoGetConvoForMembers.Parameters(members: members))
    guard (200..<300).contains(code), let convo = data?.convo else {
      let names = recipients.map(\.displayName).joined(separator: ", ")
      throw IntentError.invalidParameter("\(names) can't receive direct messages right now.")
    }
    return convo.id
  }

  // MARK: - Name directory

  struct Member: Sendable, Equatable {
    let did: String
    let displayName: String?
    let handle: String?
  }

  /// Snapshot of recent conversations + their members. This is what Siri
  /// entity resolution matches against, so names here must be human names —
  /// never raw DIDs.
  struct ChatDirectory {
    let conversations: [ChatBskyConvoDefs.ConvoView]
    let membersByConvoID: [String: [Member]]
    let currentUserDID: String

    /// Best human-readable name for a member: display name, then handle,
    /// then a DID suffix as last resort.
    func name(for member: Member) -> String {
      if let displayName = member.displayName, !displayName.isEmpty {
        return displayName
      }
      if let handle = member.handle, !handle.isEmpty {
        return "@\(handle)"
      }
      return String(member.did.suffix(8))
    }

    func handle(for member: Member) -> String? {
      member.handle
    }

    func members(in conversationID: String) -> [Member] {
      membersByConvoID[conversationID] ?? []
    }

    /// Members across all conversations, excluding self, deduplicated by DID,
    /// in conversation-recency order.
    func recipientCandidates() -> [Member] {
      var seen = Set<String>()
      var result: [Member] = []
      for convo in conversations {
        for member in members(in: convo.id)
        where member.did != currentUserDID && seen.insert(member.did).inserted {
          result.append(member)
        }
      }
      return result
    }

    func member(withDID did: String) -> Member? {
      for members in membersByConvoID.values {
        if let match = members.first(where: { $0.did == did }) {
          return match
        }
      }
      return nil
    }

    /// Conversation title: group name if set, otherwise the other members'
    /// names.
    func title(for conversation: ChatBskyConvoDefs.ConvoView) -> String {
      if case .chatBskyConvoDefsGroupConvo(let group)? = conversation.kind, !group.name.isEmpty {
        return group.name
      }
      let others = members(in: conversation.id)
        .filter { $0.did != currentUserDID }
        .map { name(for: $0) }
      return others.isEmpty ? "Conversation" : others.joined(separator: ", ")
    }
  }

  static func directory(client: ATProtoClient, limit: Int = 100) async throws -> ChatDirectory {
    let userDID = try await client.getDid()
    let output = try unwrapIntentResponse(
      await client.chat.bsky.convo.listConvos(
        input: ChatBskyConvoListConvos.Parameters(limit: min(max(limit, 1), 100))))
    var membersByConvoID: [String: [Member]] = [:]
    for convo in output.convos {
      membersByConvoID[convo.id] = convo.members.map {
        Member(did: $0.did.didString(), displayName: $0.displayName, handle: $0.handle.value)
      }
    }
    return ChatDirectory(
      conversations: output.convos,
      membersByConvoID: membersByConvoID,
      currentUserDID: userDID
    )
  }

  static func personEntity(
    from member: Member, directory: ChatDirectory
  ) -> CatbirdMessagesPersonEntity {
    CatbirdMessagesPersonEntity(
      id: member.did,
      displayName: directory.name(for: member),
      isMe: member.did == directory.currentUserDID
    )
  }

  static func previewText(for conversation: ChatBskyConvoDefs.ConvoView) -> AttributedString {
    if case .chatBskyConvoDefsMessageView(let message)? = conversation.lastMessage {
      return AttributedString(message.text)
    }
    return AttributedString("")
  }

  static func conversationEntity(
    convo: ChatBskyConvoDefs.ConvoView,
    directory: ChatDirectory
  ) -> CatbirdMessagesConversationEntity {
    let members = directory.members(in: convo.id)
    let recipients = members
      .filter { $0.did != directory.currentUserDID }
      .map { personEntity(from: $0, directory: directory) }
    let title = directory.title(for: convo)

    var attributes: Set<CatbirdMessagesConversationAttribute> = []
    if members.count > 2 { attributes.insert(.group) }
    if convo.muted { attributes.insert(.mute) }

    var lastActive: Date?
    if case .chatBskyConvoDefsMessageView(let message)? = convo.lastMessage {
      lastActive = message.sentAt.date
    }

    return CatbirdMessagesConversationEntity(
      id: convo.id,
      recipients: recipients,
      displayName: title,
      previewText: previewText(for: convo),
      conversationName: title,
      isRead: convo.unreadCount == 0,
      attributes: attributes,
      dateLastActive: lastActive
    )
  }

  static func messageEntity(
    from message: ChatBskyConvoDefs.MessageView,
    convo: ChatBskyConvoDefs.ConvoView,
    directory: ChatDirectory
  ) -> CatbirdMessagesMessageEntity {
    let senderDID = message.sender.did.didString()
    let sender: CatbirdMessagesPersonEntity
    if let member = directory.member(withDID: senderDID) {
      sender = personEntity(from: member, directory: directory)
    } else {
      sender = CatbirdMessagesPersonEntity(
        id: senderDID,
        displayName: String(senderDID.suffix(8)),
        isMe: senderDID == directory.currentUserDID
      )
    }

    return CatbirdMessagesMessageEntity(
      id: message.id,
      messageType: .text,
      author: sender,
      isRead: true,
      attributes: [],
      conversation: conversationEntity(convo: convo, directory: directory),
      date: message.sentAt.date,
      subject: nil,
      body: AttributedString(message.text),
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
  }

  /// Recent messages (newest first) of a conversation; deleted and system
  /// messages are skipped.
  static func recentMessages(
    in convoID: String,
    limit: Int,
    client: ATProtoClient
  ) async throws -> [ChatBskyConvoDefs.MessageView] {
    let output = try unwrapIntentResponse(
      await client.chat.bsky.convo.getMessages(
        input: ChatBskyConvoGetMessages.Parameters(convoId: convoID, limit: min(max(limit, 1), 100))))
    return output.messages.compactMap {
      if case .chatBskyConvoDefsMessageView(let message) = $0 { return message }
      return nil
    }
  }
}

#endif
