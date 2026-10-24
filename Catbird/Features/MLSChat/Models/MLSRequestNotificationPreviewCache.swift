import CatbirdMLSCore
import Foundation
import GRDB

/// A short-lived display cache populated only from the verified Rust projection.
/// The notification extension has read-only access and cannot import a Welcome.
@MainActor
enum MLSRequestNotificationPreviewCache {
  static func project(_ request: DirectRequestView, accountDID: String, database: MLSDatabase) async throws {
    guard let messageID = request.firstMessageId else { return }
    let text: String?
    if request.consent == .incomingPending, request.capabilities.canPreview, case .ready(let preview, _) = request.preview {
      text = preview
    } else { text = nil }
    let expiresAt = Date().addingTimeInterval(300).timeIntervalSince1970
    try await database.write { db in
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS app_direct_request_notification_preview (
          account_did TEXT NOT NULL, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
          text TEXT, expires_at REAL NOT NULL, state_version INTEGER NOT NULL,
          PRIMARY KEY(account_did, conversation_id, message_id)
        )
        """)
      try db.execute(sql: """
        INSERT INTO app_direct_request_notification_preview VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_did, conversation_id, message_id) DO UPDATE SET
          text = excluded.text, expires_at = excluded.expires_at, state_version = excluded.state_version
        WHERE excluded.state_version >= app_direct_request_notification_preview.state_version
        """, arguments: [accountDID, request.conversationId, messageID, text, expiresAt, request.stateVersion])
      try db.execute(sql: "UPDATE app_direct_request_notification_preview SET text = NULL WHERE expires_at < ?", arguments: [Date().timeIntervalSince1970])
    }
  }
}
