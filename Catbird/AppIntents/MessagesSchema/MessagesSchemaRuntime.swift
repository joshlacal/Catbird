//
//  MessagesSchemaRuntime.swift
//  Catbird
//
//  Runtime bridge for iOS 27 Messages App Schema intents. MLS mutations must go
//  through the live app-state-owned manager because they depend on local device
//  keys, storage, and recovery state.
//

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)

import AppIntents
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import LinkPresentation
import GeoToolbox

@available(anyAppleOS 27.0, *)
enum MessagesSchemaRuntime {
  static func coordinator() async throws -> MLSClientCoordinator {
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

    guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
      throw IntentError.serviceUnavailable(
        LocalizedStringResource(
          "Catbird's secure chat service is unavailable or requires ATProto Spaces permissions. Open Catbird and try again.",
          comment: "Error spoken by Siri when MLS secure chat is not yet initialized or authorized."
        )
      )
    }

    return coordinator
  }

  static func text(from attributedString: AttributedString) throws -> String {
    let text = String(attributedString.characters)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "Message content cannot be empty.",
          comment: "Validation error when a Catbird chat message has empty body text."
        )
      )
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
        throw IntentError.invalidParameter(
          LocalizedStringResource(
            "No recipients specified.",
            comment: "Validation error when sending a Catbird chat message without any recipient."
          )
        )
      }
      return entities.map { ($0.id, $0.displayName) }

    case .persons(let persons):
      guard !persons.isEmpty else {
        throw IntentError.invalidParameter(
          LocalizedStringResource(
            "No recipients specified.",
            comment: "Validation error when sending a Catbird chat message without any recipient."
          )
        )
      }
      return try persons.map { person in
        guard let name = spokenName(for: person) else {
          throw IntentError.invalidParameter(
            LocalizedStringResource(
              "That contact has no name Catbird can match against your chats.",
              comment: "Error when a Siri contact lacks a displayable name to match against Catbird chat members."
            )
          )
        }
        guard let member = member(matchingName: name, in: directory) else {
          throw IntentError.invalidParameter(
            LocalizedStringResource(
              "Couldn't find \"\(name)\" in your Catbird chats.",
              comment: "Error when no existing Catbird chat member matches a spoken contact name; placeholder is the contact's name."
            )
          )
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

  enum ComposeDestination {
    case existing(String)
    case recipientDraft(MLSDirectComposeDraft)
  }

  /// Read-only resolution plus a local draft. No destination lookup creates MLS state.
  static func resolveDestination(
    recipients: [(did: String, displayName: String)],
    coordinator _: MLSClientCoordinator,
    directory: ChatDirectory
  ) async throws -> ComposeDestination {
    guard !recipients.isEmpty else {
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "No recipients specified.",
          comment: "Validation error when sending a Catbird chat message without any recipient."
        )
      )
    }
    if let existing = conversationID(matching: recipients.map(\.did),
      in: directory.membersByConvoID.mapValues { $0.map(\.did) },
      conversationOrder: directory.conversations.map(\.conversationID), selfDID: directory.currentUserDID) {
      guard isCanonicalStableID(existing) else { throw MLSConversationIdentityBoundary.Error.invalidStableID(existing) }
      return .existing(existing)
    }
    guard recipients.count == 1 else {
      throw IntentError.invalidParameter(
        LocalizedStringResource(
          "Create a group in Catbird before sending to multiple recipients.",
          comment: "Error when attempting to start a new multi-person MLS group chat via Siri before creating the group in Catbird."
        )
      )
    }
    return .recipientDraft(MLSDirectComposeDraftStore.open(
      accountDID: directory.currentUserDID, recipientDID: recipients[0].did))
  }

  private static func isCanonicalStableID(_ value: String) -> Bool {
    MLSConversationIdentityBoundary.isCanonicalStableID(value)
  }

  // MARK: - Name directory (SDK-backed, profile-enriched)

  /// Process-lifetime cache of DID → (displayName, handle) resolved via
  /// app.bsky.actor.getProfiles. Member rows carry no names, so
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
      return others.isEmpty
        ? String(
            localized: "Conversation",
            comment: "Fallback title for an MLS chat conversation with no other participants."
          )
        : others.joined(separator: ", ")
    }
  }

  static func directory(coordinator: MLSClientCoordinator) async throws -> ChatDirectory {
    let userDID = await coordinator.accountDid
    let rows = try await coordinator.listConversations(limit: 100)
    let loadedConversations = rows.map { MLSConversationModel(row: $0, currentUserDID: userDID) }
    let identityRecords = loadedConversations.map {
      MLSConversationIdentityBoundary.Record(
        conversationID: $0.conversationID,
        groupID: $0.groupID.hexEncodedString()
      )
    }
    let canonicalRecords = try MLSConversationIdentityBoundary.canonicalize(identityRecords)
    let canonicalIDs = Set(canonicalRecords.map(\.conversationID))
    let canonicalConversations = loadedConversations.filter {
      canonicalIDs.contains($0.conversationID)
    }
    var canonicalMembersByConvoID: [String: [MLSMemberModel]] = [:]
    var memberDIDs = Set<String>()
    for convo in canonicalConversations {
      let convoID = convo.conversationID
      let msgRows = (try? await coordinator.listMessages(conversationId: convoID, limit: 25)) ?? []
      var seen = Set<String>()
      canonicalMembersByConvoID[convoID] = msgRows.compactMap { row in
        guard seen.insert(row.senderDid).inserted else { return nil }
        memberDIDs.insert(row.senderDid)
        return MLSMemberModel(
          memberID: "\(convoID):\(row.senderDid)",
          conversationID: convoID,
          currentUserDID: userDID,
          did: row.senderDid
        )
      }
    }

    var directory = ChatDirectory(
      conversations: canonicalConversations,
      membersByConvoID: canonicalMembersByConvoID,
      currentUserDID: userDID
    )

    // Best-effort profile enrichment: member rows carry no names, and Siri
    // matches spoken names against these entities. Failure degrades to
    // handle/DID-suffix display, never blocks resolution.
    directory.namesByDID = await ProfileNameCache.shared.resolve(dids: Array(memberDIDs))
    return directory
  }

  static func resolveConversationID(
    _ requestedID: String,
    in directory: ChatDirectory
  ) throws -> String {
    let records = directory.conversations.map {
      MLSConversationIdentityBoundary.Record(
        conversationID: $0.conversationID,
        groupID: $0.groupID.hexEncodedString()
      )
    }
    return try MLSConversationIdentityBoundary.resolve(requestedID, in: records)
  }

  static func resolveConversationID(
    _ requestedID: String,
    coordinator: MLSClientCoordinator
  ) async throws -> String {
    let directory = try await directory(coordinator: coordinator)
    return try resolveConversationID(requestedID, in: directory)
  }

  static func personEntity(
    from member: MLSMemberModel, directory: ChatDirectory
  ) -> CatbirdMessagesPersonEntity {
    CatbirdMessagesPersonEntity(
      id: member.did,
      displayName: directory.name(for: member),
      handle: directory.handle(for: member)
    )
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
      previewText: AttributedString(
        String(
          localized: "MLS Chat",
          comment: "Preview label for an encrypted MLS chat conversation."
        )
      ),
      conversationName: title,
      isRead: model.unreadCount == 0,
      attributes: members.count > 2 ? [.group] : [],
      dateLastActive: model.lastMessageAt
    )
  }

  static func messageEntity(
    from message: MLSMessageModel,
    conversationTitle: String? = nil,
    directory: ChatDirectory? = nil,
    conversationIDOverride: String? = nil
  ) -> CatbirdMessagesMessageEntity {
    let sender: CatbirdMessagesPersonEntity
    if let directory, let member = directory.member(withDID: message.senderID) {
      sender = personEntity(from: member, directory: directory)
    } else {
      sender = CatbirdMessagesPersonEntity(
        id: message.senderID, displayName: String(message.senderID.suffix(8)))
    }
    let preview = AttributedString(
      String(
        localized: "MLS Chat",
        comment: "Preview label for an encrypted MLS chat conversation."
      )
    )
    let bodyText = message.parsedPayload()?.text ?? String(
      localized: "Encrypted message",
      comment: "Placeholder body text when an encrypted MLS message payload cannot be read."
    )

    let convoEntity = CatbirdMessagesConversationEntity(
      id: conversationIDOverride ?? message.conversationID,
      recipients: [sender],
      displayName: conversationTitle ?? String(
        localized: "Conversation",
        comment: "Fallback title for an MLS chat conversation."
      ),
      previewText: preview,
      conversationName: conversationTitle,
      isRead: true,
      attributes: [],
      dateLastActive: message.timestamp
    )

    return CatbirdMessagesMessageEntity(
      id: message.messageID,
      messageType: .text,
      author: sender,
      isRead: true,
      attributes: [],
      conversation: convoEntity,
      date: message.timestamp,
      subject: nil,
      body: AttributedString(bodyText),
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
    coordinator: MLSClientCoordinator
  ) async throws -> MLSMessageModel {
    let userDID = await coordinator.accountDid
    let convos = try await coordinator.listConversations(limit: 100)
    for convo in convos {
      let rows = try await coordinator.listMessages(conversationId: convo.conversationId, limit: 100)
      if let matchingRow = rows.first(where: { $0.messageId == messageID }) {
        return MLSMessageModel(row: matchingRow, currentUserDID: userDID)
      }
    }
    throw IntentError.invalidParameter(
      LocalizedStringResource(
        "Catbird could not find that message.",
        comment: "Error spoken by Siri when a referenced chat message cannot be found in storage."
      )
    )
  }
}

#endif
