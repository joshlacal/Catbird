import CatbirdMLSCore
import Foundation
import GRDB

/// A local recipient target is never a canonical conversation identity.
struct MLSDirectComposeDraft: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let accountDID: String
  let recipientDID: String
  var text: String
  var submitted: Bool
  var conversationID: String?
  var invitation: MLSGroupInvitationReference?
  var noteAttempted: Bool?
  var noteMessageID: String?

  init(accountDID: String, recipientDID: String, text: String = "", invitation: MLSGroupInvitationReference? = nil) {
    self.id = UUID()
    self.accountDID = accountDID
    self.recipientDID = recipientDID
    self.text = text
    self.invitation = invitation
    self.submitted = false
  }
}

/// Host compose state only. The Rust journal remains publication authority.
/// Rows live in the account's protected MLS database, alongside host projections.
@MainActor
enum MLSDirectComposeDraftStore {
  enum Failure: Error { case accountChanged, immutableSubmittedDraft, invalidText }

  static func open(accountDID: String, recipientDID: String, database: MLSDatabase) async throws -> MLSDirectComposeDraft {
    try await database.write { db in
      try createTable(db)
      for data in try Data.fetchAll(db, sql: "SELECT payload FROM app_direct_compose_drafts WHERE account_did = ? AND recipient_did = ? AND archived = 0 ORDER BY updated_at DESC", arguments: [accountDID, recipientDID]) {
        let draft = try JSONDecoder().decode(MLSDirectComposeDraft.self, from: data)
        if draft.invitation == nil { return draft }
      }
      let draft = MLSDirectComposeDraft(accountDID: accountDID, recipientDID: recipientDID)
      try persist(draft, in: db)
      return draft
    }
  }

  static func invitationDraft(accountDID: String, reference: MLSGroupInvitationReference, database: MLSDatabase) async throws -> MLSDirectComposeDraft {
    guard reference.invitedByDid == accountDID else { throw Failure.accountChanged }
    return try await database.write { db in
      try createTable(db)
      for data in try Data.fetchAll(db, sql: "SELECT payload FROM app_direct_compose_drafts WHERE account_did = ? AND recipient_did = ? AND archived = 0 ORDER BY updated_at DESC", arguments: [accountDID, reference.recipientDid]) {
        let draft = try JSONDecoder().decode(MLSDirectComposeDraft.self, from: data)
        if draft.invitation == reference { return draft }
      }
      let draft = MLSDirectComposeDraft(accountDID: accountDID, recipientDID: reference.recipientDid, invitation: reference)
      try persist(draft, in: db)
      return draft
    }
  }

  static func savedInvitationNotes(accountDID: String, database: MLSDatabase) async throws -> [MLSDirectComposeDraft] {
    try await database.write { db in
      try createTable(db)
      return try Data.fetchAll(db, sql: "SELECT payload FROM app_direct_compose_drafts WHERE account_did = ? AND archived = 0 ORDER BY updated_at DESC", arguments: [accountDID])
        .map { try JSONDecoder().decode(MLSDirectComposeDraft.self, from: $0) }
        .filter { $0.invitation != nil }
    }
  }

  static func save(_ draft: MLSDirectComposeDraft, database: MLSDatabase) async throws {
    try await database.write { db in
      try createTable(db)
      if let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_direct_compose_drafts WHERE id = ? AND account_did = ?", arguments: [draft.id.uuidString, draft.accountDID]) {
        let previous = try JSONDecoder().decode(MLSDirectComposeDraft.self, from: data)
        guard previous.recipientDID == draft.recipientDID,
              previous.invitation == draft.invitation,
              !previous.submitted || (previous.text == draft.text && draft.submitted),
              previous.noteAttempted != true || (draft.noteAttempted == true && previous.text == draft.text) else {
          throw Failure.immutableSubmittedDraft
        }
      }
      try persist(draft, in: db)
    }
  }

  static func archive(_ draft: MLSDirectComposeDraft, database: MLSDatabase) async throws {
    try await database.write { db in
      try createTable(db)
      try db.execute(sql: "UPDATE app_direct_compose_drafts SET archived = 1 WHERE id = ? AND account_did = ?", arguments: [draft.id.uuidString, draft.accountDID])
    }
  }

  /// A terminal non-publication (e.g. `RecipientKeysUnavailable`) ends that
  /// draft id in the Rust journal, so retrying it can never publish. Archive
  /// it and carry the text into a fresh, editable draft for the same target.
  static func reopenAfterTerminal(_ draft: MLSDirectComposeDraft, database: MLSDatabase) async throws -> MLSDirectComposeDraft {
    let fresh = MLSDirectComposeDraft(accountDID: draft.accountDID, recipientDID: draft.recipientDID,
      text: draft.text, invitation: draft.invitation)
    try await database.write { db in
      try createTable(db)
      try db.execute(sql: "UPDATE app_direct_compose_drafts SET archived = 1 WHERE id = ? AND account_did = ?", arguments: [draft.id.uuidString, draft.accountDID])
      try persist(fresh, in: db)
    }
    return fresh
  }

  static func validateText(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf8.count <= 16_384 else { throw Failure.invalidText }
  }

  nonisolated private static func createTable(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS app_direct_compose_drafts (
        id TEXT NOT NULL, account_did TEXT NOT NULL, recipient_did TEXT NOT NULL,
        payload BLOB NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL, PRIMARY KEY(account_did, id)
      )
      """)
  }

  nonisolated private static func persist(_ draft: MLSDirectComposeDraft, in db: Database) throws {
    try db.execute(sql: """
      INSERT INTO app_direct_compose_drafts (id, account_did, recipient_did, payload, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(account_did, id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
      """, arguments: [draft.id.uuidString, draft.accountDID, draft.recipientDID, try JSONEncoder().encode(draft), Date().timeIntervalSince1970])
  }
}

@MainActor
extension MLSDirectComposeDraftStore {
  static func requestPresentation(_ draft: MLSDirectComposeDraft, database: MLSDatabase) async throws {
    try await save(draft, database: database)
    try await database.write { db in
      try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_direct_compose_handoff (account_did TEXT PRIMARY KEY, draft_id TEXT)")
      try db.execute(sql: "INSERT INTO app_direct_compose_handoff VALUES (?, ?) ON CONFLICT(account_did) DO UPDATE SET draft_id = excluded.draft_id", arguments: [draft.accountDID, draft.id.uuidString])
    }
    NotificationCenter.default.post(name: .directComposeDraftReady, object: draft.accountDID)
  }

  static func pendingPresentation(accountDID: String, database: MLSDatabase) async throws -> MLSDirectComposeDraft? {
    try await database.write { db in
      try createTable(db)
      try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_direct_compose_handoff (account_did TEXT PRIMARY KEY, draft_id TEXT)")
      guard let data = try Data.fetchOne(db, sql: "SELECT d.payload FROM app_direct_compose_handoff h JOIN app_direct_compose_drafts d ON d.id = h.draft_id AND d.account_did = h.account_did WHERE h.account_did = ? AND d.archived = 0", arguments: [accountDID]) else { return nil }
      return try JSONDecoder().decode(MLSDirectComposeDraft.self, from: data)
    }
  }

  static func clearPresentation(accountDID: String, database: MLSDatabase) async throws {
    try await database.write { db in
      try db.execute(sql: "UPDATE app_direct_compose_handoff SET draft_id = NULL WHERE account_did = ?", arguments: [accountDID])
    }
  }
}

extension Notification.Name {
  static let directComposeDraftReady = Notification.Name("Catbird.directComposeDraftReady")
}

// Durable host representation converts to the generated shared request input.
extension MLSGroupInvitationReference {
  var requestReference: GroupInvitationReference {
    GroupInvitationReference(authorityDid: authorityDid, conversationId: conversationId,
      invitationTransitionId: invitationTransitionId, invitedByDid: invitedByDid,
      invitedByDeviceId: invitedByDeviceId, recipientDid: recipientDid)
  }

  init(verified reference: GroupInvitationReference) throws {
    try self.init(authorityDid: reference.authorityDid, conversationId: reference.conversationId,
      invitationTransitionId: reference.invitationTransitionId, invitedByDid: reference.invitedByDid,
      invitedByDeviceId: reference.invitedByDeviceId, recipientDid: reference.recipientDid)
  }
}
