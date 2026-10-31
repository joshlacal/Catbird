import Foundation
import SQLite3
import os

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lightweight SQLite3 reader for `<AppGroup>/profile_cache.db` inside `NotificationServiceExtension` (`G1`).
///
/// Uses Apple's built-in `SQLite3` C library with `SQLITE_OPEN_READONLY` and closes the descriptor
/// immediately on return so the extension links zero `GRDB` symbols and holds zero SQLite locks.
actor ProfileCacheDatabase {
  static let shared = ProfileCacheDatabase()

  private let logger = Logger(subsystem: "blue.catbird", category: "NSEProfileCache")

  private init() {}

  func read(did: String) -> CachedProfile? {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ) else {
      return nil
    }

    let dbPath = containerURL.appendingPathComponent("profile_cache.db").path
    guard FileManager.default.fileExists(atPath: dbPath) else {
      return nil
    }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let handle = db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(handle) }

    sqlite3_busy_timeout(handle, 250)

    let sql = "SELECT handle, displayName, avatarURL FROM cached_profiles WHERE did = ?1 LIMIT 1;"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
      if let stmt { sqlite3_finalize(stmt) }
      return nil
    }
    defer { sqlite3_finalize(statement) }

    _ = did.withCString { cStr in
      sqlite3_bind_text(statement, 1, cStr, -1, sqliteTransient)
    }

    guard sqlite3_step(statement) == SQLITE_ROW else {
      return nil
    }

    guard let rawHandle = sqlite3_column_text(statement, 0) else {
      return nil
    }
    let handleStr = String(cString: rawHandle)
    let displayName: String? = sqlite3_column_text(statement, 1).map { String(cString: $0) }
    let avatarURL: String? = sqlite3_column_text(statement, 2).map { String(cString: $0) }

    return CachedProfile(
      did: did,
      handle: handleStr,
      displayName: displayName,
      avatarURL: avatarURL
    )
  }
}

struct CachedProfile: Sendable {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: String?
}
