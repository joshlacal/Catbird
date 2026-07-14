//
//  MessagesSchemaRuntime.swift
//  Catbird
//
//  Runtime bridge for iOS 27 Messages App Schema intents. MLS mutations must go
//  through the live app-state-owned manager because they depend on local device
//  keys, storage, and recovery state.
//

#if os(iOS)

import AppIntents
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import LinkPresentation
import GeoToolbox

@available(iOS 27.0, *)
enum MessagesSchemaRuntime {
  static func conversationManager() async throws -> MLSConversationManager {
    // Background intent launches run the app's init path, but lifecycle.appState
    // is populated asynchronously — poll briefly instead of failing the intent
    // the instant it's still nil.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var appState = await MainActor.run { AppStateManager.shared.lifecycle.appState }
    while appState == nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(250))
      appState = await MainActor.run { AppStateManager.shared.lifecycle.appState }
    }

    guard let appState else {
      throw IntentError.notSignedIn
    }

    guard let manager = await appState.getMLSConversationManager(timeout: 15.0) else {
      throw IntentError.serviceUnavailable(
        "Catbird's secure chat service is still starting. Open Catbird and try again."
      )
    }

    return manager
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
  static func member(matchingName name: String, in directory: ChatDirectory) -> MLSMemberModel? {
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

  /// Finds the existing conversation whose member set matches `recipients`,
  /// creating a group if none exists (MLS requires the group to exist before
  /// composing into it). Supports 1:1 and multi-recipient destinations.
  static func findOrCreateConversation(
    recipients: [(did: String, displayName: String)],
    manager: MLSConversationManager,
    directory: ChatDirectory
  ) async throws -> String {
    guard !recipients.isEmpty else {
      throw IntentError.invalidParameter("No recipients specified.")
    }

    if let existing = conversationID(
      matching: recipients.map(\.did),
      in: directory.membersByConvoID.mapValues { $0.map(\.did) },
      conversationOrder: directory.conversations.map(\.conversationID),
      selfDID: directory.currentUserDID
    ) {
      return existing
    }

    let peerDIDs = try recipients.map { try DID(didString: $0.did) }
    let name = recipients
      .map { $0.displayName.isEmpty ? $0.did : $0.displayName }
      .joined(separator: ", ")
    let newConvo = try await manager.createGroup(initialMembers: peerDIDs, name: name)
    return newConvo.conversationId
  }

  // MARK: - Name directory (GRDB-backed, profile-enriched)

  /// Process-lifetime cache of DID → (displayName, handle) resolved via
  /// app.bsky.actor.getProfiles. Member rows in GRDB don't carry names, so
  /// without this Siri would try to match spoken names against DIDs.
  actor ProfileNameCache {
    static let shared = ProfileNameCache()
    private var names: [String: (displayName: String?, handle: String?)] = [:]

    func resolve(dids: [String]) async -> [String: (displayName: String?, handle: String?)] {
      let missing = dids.filter { names[$0] == nil }
      let client = await MainActor.run {
        AppStateManager.shared.lifecycle.appState?.atProtoClient
      }
      if !missing.isEmpty, let client {
        for start in stride(from: 0, to: missing.count, by: 25) {
          let chunk = Array(missing[start..<min(start + 25, missing.count)])
          guard
            let actors = try? chunk.map({ try ATIdentifier(string: $0) }),
            let (code, data) = try? await client.app.bsky.actor.getProfiles(
              input: AppBskyActorGetProfiles.Parameters(actors: actors)),
            (200...299).contains(code), let profiles = data?.profiles
          else { continue }
          for profile in profiles {
            names[profile.did.didString()] = (profile.displayName, profile.handle.value)
          }
        }
      }
      return names.filter { dids.contains($0.key) }
    }
  }

  /// Snapshot of every active conversation + its members, with resolved
  /// handles/display names. This is what Siri entity resolution matches
  /// against, so names here must be human names — never raw DIDs.
  struct ChatDirectory {
    let conversations: [MLSConversationModel]
    let membersByConvoID: [String: [MLSMemberModel]]
    let currentUserDID: String
    var namesByDID: [String: (displayName: String?, handle: String?)] = [:]

    /// Best human-readable name for a member: resolved profile, then cached
    /// row fields, then a DID suffix as last resort.
    func name(for member: MLSMemberModel) -> String {
      let resolved = namesByDID[member.did]
      if let displayName = resolved?.displayName ?? member.displayName, !displayName.isEmpty {
        return displayName
      }
      if let handle = resolved?.handle ?? member.handle, !handle.isEmpty {
        return "@\(handle)"
      }
      return String(member.did.suffix(8))
    }

    func handle(for member: MLSMemberModel) -> String? {
      namesByDID[member.did]?.handle ?? member.handle
    }

    func members(in conversationID: String) -> [MLSMemberModel] {
      membersByConvoID[conversationID] ?? []
    }

    /// Members across all conversations, excluding self, deduplicated by DID,
    /// in conversation-recency order.
    func recipientCandidates() -> [MLSMemberModel] {
      var seen = Set<String>()
      var result: [MLSMemberModel] = []
      for convo in conversations {
        for member in members(in: convo.conversationID)
        where member.did != currentUserDID && seen.insert(member.did).inserted {
          result.append(member)
        }
      }
      return result
    }

    func member(withDID did: String) -> MLSMemberModel? {
      for members in membersByConvoID.values {
        if let match = members.first(where: { $0.did == did }) {
          return match
        }
      }
      return nil
    }

    /// Conversation title: explicit title if set, otherwise the other
    /// members' names.
    func title(for conversation: MLSConversationModel) -> String {
      if let title = conversation.title, !title.isEmpty {
        return title
      }
      let others = members(in: conversation.conversationID)
        .filter { $0.did != currentUserDID }
        .map { name(for: $0) }
      return others.isEmpty ? "Conversation" : others.joined(separator: ", ")
    }
  }

  static func directory(manager: MLSConversationManager) async throws -> ChatDirectory {
    guard let userDID = manager.userDid else {
      throw IntentError.notSignedIn
    }
    let result = try await manager.storage.fetchConversationsWithMembers(
      currentUserDID: userDID,
      database: manager.database
    )
    var directory = ChatDirectory(
      conversations: result.conversations,
      membersByConvoID: result.membersByConvoID,
      currentUserDID: userDID
    )

    // Best-effort profile enrichment: member rows carry no names, and Siri
    // matches spoken names against these entities. Failure degrades to
    // handle/DID-suffix display, never blocks resolution.
    let memberDIDs = Set(result.membersByConvoID.values.flatMap { $0.map(\.did) })
    directory.namesByDID = await ProfileNameCache.shared.resolve(dids: Array(memberDIDs))
    return directory
  }

  static func personEntity(
    from member: MLSMemberModel, directory: ChatDirectory
  ) -> CatbirdMessagesPersonEntity {
    CatbirdMessagesPersonEntity(id: member.did, displayName: directory.name(for: member))
  }

  static func conversationEntity(
    model: MLSConversationModel,
    directory: ChatDirectory
  ) -> CatbirdMessagesConversationEntity {
    let members = directory.members(in: model.conversationID)
    let recipients = members
      .filter { $0.did != directory.currentUserDID }
      .map { personEntity(from: $0, directory: directory) }
    let title = directory.title(for: model)

    return CatbirdMessagesConversationEntity(
      id: model.conversationID,
      recipients: recipients,
      displayName: title,
      previewText: AttributedString("MLS chat"),
      conversationName: title,
      isRead: true,
      attributes: members.count > 2 ? [.group] : [],
      dateLastActive: model.lastMessageAt
    )
  }

  static func messageEntity(
    from message: MLSMessageModel,
    conversationTitle: String? = nil,
    directory: ChatDirectory? = nil
  ) -> CatbirdMessagesMessageEntity {
    let sender: CatbirdMessagesPersonEntity
    if let directory, let member = directory.member(withDID: message.senderID) {
      sender = personEntity(from: member, directory: directory)
    } else {
      sender = CatbirdMessagesPersonEntity(
        id: message.senderID, displayName: String(message.senderID.suffix(8)))
    }
    let preview = AttributedString("MLS Chat")

    let convoEntity = CatbirdMessagesConversationEntity(
      id: message.conversationID,
      recipients: [sender],
      displayName: conversationTitle ?? "Conversation",
      previewText: preview,
      conversationName: conversationTitle,
      isRead: message.isRead,
      attributes: [],
      dateLastActive: message.timestamp
    )

    return CatbirdMessagesMessageEntity(
      id: message.messageID,
      messageType: .text,
      author: sender,
      isRead: message.isRead,
      attributes: [],
      conversation: convoEntity,
      date: message.timestamp,
      subject: nil,
      body: AttributedString(message.plaintext ?? "Encrypted message"),
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

  static func fetchMessage(
    _ messageID: String,
    manager: MLSConversationManager
  ) async throws -> MLSMessageModel {
    guard let userDID = manager.userDid else {
      throw IntentError.notSignedIn
    }

    guard
      let message = try await manager.storage.fetchMessage(
        messageID: messageID,
        currentUserDID: userDID,
        database: manager.database
      )
    else {
      throw IntentError.invalidParameter("Catbird could not find that message.")
    }

    return message
  }
}

#endif
