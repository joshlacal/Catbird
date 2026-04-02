import Foundation
import GRDB
import os

/// Shared GRDB profile cache in the App Group container.
/// Written by the main app (ChatManager), read by NSE for notification enrichment.
actor ProfileCacheDatabase {
  static let shared = ProfileCacheDatabase()

  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileCache")
  private var dbPool: DatabasePool?

  private init() {}

  func getPool() throws -> DatabasePool {
    if let pool = dbPool { return pool }
    let pool = try createPool()
    dbPool = pool
    return pool
  }

  private func createPool() throws -> DatabasePool {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ) else {
      throw ProfileCacheError.appGroupUnavailable
    }

    let dbURL = containerURL.appendingPathComponent("profile_cache.db")
    var config = Configuration()
    config.journalMode = .wal
    config.busyMode = .timeout(5)

    let pool = try DatabasePool(path: dbURL.path, configuration: config)

    try pool.write { db in
      try db.create(table: "cached_profiles", ifNotExists: true) { t in
        t.primaryKey("did", .text)
        t.column("handle", .text).notNull()
        t.column("displayName", .text)
        t.column("avatarURL", .text)
        t.column("updatedAt", .datetime).notNull()
      }
    }

    return pool
  }

  func write(did: String, handle: String, displayName: String?, avatarURL: String?) async {
    do {
      let pool = try getPool()
      try pool.write { db in
        try db.execute(
          sql: """
            INSERT INTO cached_profiles (did, handle, displayName, avatarURL, updatedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (did) DO UPDATE SET
              handle = excluded.handle,
              displayName = excluded.displayName,
              avatarURL = excluded.avatarURL,
              updatedAt = excluded.updatedAt
            """,
          arguments: [did, handle, displayName, avatarURL, Date()]
        )
      }
    } catch {
      logger.error("Failed to write profile cache: \(error.localizedDescription)")
    }
  }

  func read(did: String) async -> CachedProfile? {
    do {
      let pool = try getPool()
      return try pool.read { db in
        try CachedProfile.fetchOne(
          db,
          sql: "SELECT * FROM cached_profiles WHERE did = ?",
          arguments: [did]
        )
      }
    } catch {
      logger.error("Failed to read profile cache: \(error.localizedDescription)")
      return nil
    }
  }
}

struct CachedProfile: Codable, FetchableRecord {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: String?
  let updatedAt: Date
}

enum ProfileCacheError: Error {
  case appGroupUnavailable
}
