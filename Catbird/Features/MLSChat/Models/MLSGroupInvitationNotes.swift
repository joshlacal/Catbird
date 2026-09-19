import CatbirdMLSCore
import Foundation
import GRDB

/// Optional notes are durable host work attached to an already confirmed group.
/// They cannot create or invite a group, or infer acceptance of either conversation.
struct MLSGroupInvitationNotes: Codable, Identifiable, Equatable, Sendable {
  var id: String { conversationID }
  let accountDID: String
  let conversationID: String
  let recipients: [String]
  var text: String
  var drafts: [String: UUID] = [:]
}

@MainActor
enum MLSGroupInvitationNotesStore {
  static func save(_ batch: MLSGroupInvitationNotes, database: MLSDatabase) async throws {
    try MLSDirectComposeDraftStore.validateText(batch.text)
    try await database.write { db in
      try createTable(db)
      if let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_group_invitation_notes WHERE account_did = ? AND conversation_id = ?", arguments: [batch.accountDID, batch.conversationID]) {
        let previous = try JSONDecoder().decode(MLSGroupInvitationNotes.self, from: data)
        guard previous.recipients == batch.recipients, previous.text == batch.text,
              previous.drafts.allSatisfy({ batch.drafts[$0.key] == $0.value }) else {
          throw MLSDirectComposeDraftStore.Failure.immutableSubmittedDraft
        }
      }
      try db.execute(sql: "INSERT INTO app_group_invitation_notes VALUES (?, ?, ?) ON CONFLICT(account_did, conversation_id) DO UPDATE SET payload = excluded.payload", arguments: [batch.accountDID, batch.conversationID, try JSONEncoder().encode(batch)])
    }
  }

  static func list(accountDID: String, database: MLSDatabase) async throws -> [MLSGroupInvitationNotes] {
    try await database.write { db in
      try createTable(db)
      return try Data.fetchAll(db, sql: "SELECT payload FROM app_group_invitation_notes WHERE account_did = ?", arguments: [accountDID]).map { try JSONDecoder().decode(MLSGroupInvitationNotes.self, from: $0) }
    }
  }

  static func draftStatus(id: UUID, accountDID: String, database: MLSDatabase) async throws -> (MLSDirectComposeDraft, Bool)? {
    try await database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT payload, archived FROM app_direct_compose_drafts WHERE account_did = ? AND id = ?", arguments: [accountDID, id.uuidString]) else { return nil }
      let data: Data = row["payload"]
      let archived: Bool = row["archived"]
      return (try JSONDecoder().decode(MLSDirectComposeDraft.self, from: data), archived)
    }
  }

  nonisolated private static func createTable(_ db: Database) throws {
    try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_group_invitation_notes (account_did TEXT NOT NULL, conversation_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account_did, conversation_id))")
  }
}
