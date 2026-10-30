//
//  ChatDraftHandoff.swift
//  Catbird
//
//  Carries a chat draft from an App Intent (Siri / Shortcuts) into the chat
//  composer. The intent process stores the draft and navigates; the
//  conversation view consumes it when it appears (or immediately, via the
//  notification, if it is already on screen).
//

import Foundation
import CatbirdMLSCore
import GRDB

struct PendingChatDraft: Codable, Sendable, Equatable {
  /// Conversation the draft targets. `nil` means "next conversation the user
  /// opens" (draft had no resolvable destination).
  let conversationID: String?
  let text: String
}

@MainActor
final class ChatDraftHandoff {
  static let shared = ChatDraftHandoff()

  /// Posted after `store(_:)` so an already-visible conversation view can
  /// consume the draft without waiting for a fresh `onAppear`.
  static let didStoreDraft = Notification.Name("ChatDraftHandoff.didStoreDraft")

  private(set) var pending: PendingChatDraft?
  private var pendingAccountDID: String?

  private init() {}

  func store(_ draft: PendingChatDraft) {
    pendingAccountDID = AppStateManager.shared.lifecycle.userDID
    pending = draft
    NotificationCenter.default.post(name: Self.didStoreDraft, object: nil)
  }

  /// Returns the pending draft text if it targets `conversationID` (or is a
  /// wildcard draft), clearing it so it is applied exactly once.
  func consume(for conversationID: String) -> String? {
    guard pendingAccountDID == AppStateManager.shared.lifecycle.userDID, let pending else { return nil }
    guard MLSConversationIdentityBoundary.isCanonicalStableID(conversationID) else {
      return nil
    }
    if let target = pending.conversationID,
       !MLSConversationIdentityBoundary.isCanonicalStableID(target) {
      return nil
    }
    guard pending.conversationID == nil || pending.conversationID == conversationID else {
      return nil
    }
    self.pending = nil
    return pending.text
  }
  func storeDurably(_ draft: PendingChatDraft, accountDID: String, database: MLSDatabase) async throws {
    try await database.write { db in
      try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_chat_draft_handoff (account_did TEXT PRIMARY KEY, payload BLOB)")
      try db.execute(sql: "INSERT INTO app_chat_draft_handoff VALUES (?, ?) ON CONFLICT(account_did) DO UPDATE SET payload = excluded.payload", arguments: [accountDID, try JSONEncoder().encode(draft)])
    }
    guard AppStateManager.shared.lifecycle.userDID == accountDID else { return }
    store(draft)
  }

  func consumeDurably(for conversationID: String, accountDID: String, database: MLSDatabase) async throws -> String? {
    guard MLSConversationIdentityBoundary.isCanonicalStableID(conversationID) else { return nil }
    let text: String? = try await database.write { db in
      try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_chat_draft_handoff (account_did TEXT PRIMARY KEY, payload BLOB)")
      guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_chat_draft_handoff WHERE account_did = ?", arguments: [accountDID]) else { return nil }
      let draft = try JSONDecoder().decode(PendingChatDraft.self, from: data)
      guard draft.conversationID == nil || draft.conversationID == conversationID else { return nil }
      try db.execute(sql: "UPDATE app_chat_draft_handoff SET payload = NULL WHERE account_did = ?", arguments: [accountDID])
      return draft.text
    }
    guard AppStateManager.shared.lifecycle.userDID == accountDID else { return nil }
    if let text { pending = nil; return text }
    return consume(for: conversationID)
  }

}
