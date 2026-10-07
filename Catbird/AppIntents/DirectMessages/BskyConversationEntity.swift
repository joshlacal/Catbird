//
//  BskyConversationEntity.swift
//  Catbird
//
//  App Intents entity for Bluesky direct-message conversations
//  (chat.bsky.convo). Hand-written: ConvoView's lastMessage is a union, which
//  the lexicon entity generator intentionally doesn't support. Runs entirely
//  against the standalone IntentClientProvider client — the chat service
//  proxy header (bskyChatDID) is applied automatically by the client.
//

import AppIntents
import Foundation
import Petrel

@available(iOS 18.0, *)
struct BskyConversationEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bluesky Conversation")
  static var defaultQuery = BskyConversationQuery()

  let id: String
  let title: String
  let memberHandles: [String]
  let lastMessagePreview: String?
  let unreadCount: Int
  let muted: Bool

  init(from view: ChatBskyConvoDefs.ConvoView, currentUserDID: String?) {
    id = view.id
    let others = view.members.filter { $0.did.didString() != currentUserDID }
    let names = others.map { member in
      if let displayName = member.displayName, !displayName.isEmpty {
        return displayName
      }
      return "@\(member.handle.value)"
    }
    title = names.isEmpty ? "Conversation" : names.joined(separator: ", ")
    memberHandles = others.map { $0.handle.value }
    if case .chatBskyConvoDefsMessageView(let message)? = view.lastMessage {
      lastMessagePreview = message.text.isEmpty ? nil : message.text
    } else {
      lastMessagePreview = nil
    }
    unreadCount = view.unreadCount
    muted = view.muted
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      subtitle: lastMessagePreview.map { "\($0)" }
    )
  }
}

@available(iOS 18.0, *)
struct BskyConversationQuery: EntityQuery, EntityStringQuery {
  init() {}

  /// A conversation ID belongs to exactly one account, but saved shortcuts hand
  /// back only the ID — including conversations picked under a non-active
  /// account. Resolve against the active account first, then the other
  /// signed-in accounts for anything it can't see.
  func entities(for identifiers: [String]) async throws -> [BskyConversationEntity] {
    let activeDID = IntentAccountResolver.activeDID()
    let otherDIDs = AccountEntityQuery.allAccounts().map(\.id).filter { $0 != activeDID }
    let candidateDIDs = [activeDID].compactMap { $0 } + otherDIDs
    guard !candidateDIDs.isEmpty else { throw IntentError.notSignedIn }

    var results: [BskyConversationEntity] = []
    var unresolved = identifiers
    for did in candidateDIDs where !unresolved.isEmpty {
      guard let client = try? await IntentClientProvider.shared.client(for: did),
        let currentDID = try? await client.getDid()
      else { continue }
      var stillUnresolved: [String] = []
      for identifier in unresolved {
        let response = try? await client.chat.bsky.convo.getConvo(
          input: ChatBskyConvoGetConvo.Parameters(convoId: identifier))
        if let response, (200..<300).contains(response.responseCode),
          let convo = response.data?.convo
        {
          results.append(BskyConversationEntity(from: convo, currentUserDID: currentDID))
        } else {
          stillUnresolved.append(identifier)
        }
      }
      unresolved = stillUnresolved
    }
    return results
  }

  func entities(matching string: String) async throws -> [BskyConversationEntity] {
    let all = try await Self.recentConversations(limit: 50)
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return all }
    return all.filter { convo in
      convo.title.localizedCaseInsensitiveContains(trimmed)
        || convo.memberHandles.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
  }

  func suggestedEntities() async throws -> [BskyConversationEntity] {
    try await Self.recentConversations(limit: 10)
  }

  static func recentConversations(limit: Int, accountDID: String? = nil) async throws
    -> [BskyConversationEntity]
  {
    let client = try await IntentClientProvider.shared.client(
      for: accountDID ?? IntentAccountResolver.activeDID())
    let currentDID = try await client.getDid()
    let output = try unwrapIntentResponse(
      await client.chat.bsky.convo.listConvos(
        input: ChatBskyConvoListConvos.Parameters(limit: min(max(limit, 1), 100))))
    return output.convos.map { BskyConversationEntity(from: $0, currentUserDID: currentDID) }
  }
}
