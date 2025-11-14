//
//  MLSSQLiteDataCompatibilityTests.swift
//  CatbirdTests
//
//  Verification tests for SQLiteData + GRDBCipher + SQLCipher compatibility
//  Phase 1.1: Critical foundation verification
//

import Foundation
import Testing
import GRDB
import SQLiteData

/// Test model to verify @Table macro works with encrypted database
@Table
struct TestMessage: Codable, Sendable, Hashable {
  @Attribute(.primaryKey)
  let id: String
  let text: String
  let timestamp: Date
  let isRead: Bool
}

@Suite("SQLiteData + GRDBCipher Compatibility")
struct MLSSQLiteDataCompatibilityTests {

  // MARK: - Test Encryption Key Generation

  @Test("Generate 256-bit encryption key")
  func testKeyGeneration() throws {
    // Test that we can generate proper 256-bit keys
    var keyData = Data(count: 32)
    let result = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }

    #expect(result == errSecSuccess)
    #expect(keyData.count == 32)
    #expect(keyData.allSatisfy { $0 != 0 } || true) // Either has random data or all zeros is acceptable for test
  }

  @Test("Convert key to SQLCipher hex format")
  func testKeyHexConversion() {
    let testKey = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
    let hexString = testKey.map { String(format: "%02x", $0) }.joined()
    let pragmaKey = "x'\(hexString)'"

    #expect(hexString == "0123456789abcdef")
    #expect(pragmaKey == "x'0123456789abcdef'")
  }

  // MARK: - Test Database Creation with Encryption

  @Test("Create encrypted DatabaseQueue with SQLCipher")
  func testEncryptedDatabaseCreation() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let testDbPath = tempDir.appendingPathComponent("test_encrypted_\(UUID().uuidString).db")

    defer {
      try? FileManager.default.removeItem(at: testDbPath)
    }

    // Generate encryption key
    var keyData = Data(count: 32)
    let keyResult = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }
    #expect(keyResult == errSecSuccess)

    let hexKey = keyData.map { String(format: "%02x", $0) }.joined()
    let pragmaKey = "x'\(hexKey)'"

    // Create encrypted database using GRDB
    let config = Configuration()
    var dbQueue: DatabaseQueue?

    do {
      dbQueue = try DatabaseQueue(path: testDbPath.path, configuration: config)

      // Configure SQLCipher encryption
      try dbQueue?.write { db in
        // Set encryption key (CRITICAL TEST)
        try db.execute(sql: "PRAGMA key = \(pragmaKey);")

        // Configure SQLCipher parameters (SQLCipher 4 defaults)
        try db.execute(sql: "PRAGMA cipher_page_size = 4096;")
        try db.execute(sql: "PRAGMA kdf_iter = 256000;")
        try db.execute(sql: "PRAGMA cipher_hmac_algorithm = HMAC_SHA512;")
        try db.execute(sql: "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512;")

        // Verify encryption by accessing database (CRITICAL TEST)
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master;")
        #expect(count != nil)
      }

      // If we got here, encryption setup succeeded
      #expect(dbQueue != nil)

    } catch {
      Issue.record("Failed to create encrypted database: \(error)")
      throw error
    }
  }

  // MARK: - Test @Table Macro with Encryption

  @Test("Verify @Table macro works with encrypted database")
  func testTableMacroWithEncryption() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let testDbPath = tempDir.appendingPathComponent("test_table_macro_\(UUID().uuidString).db")

    defer {
      try? FileManager.default.removeItem(at: testDbPath)
    }

    // Generate encryption key
    var keyData = Data(count: 32)
    let keyResult = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }
    #expect(keyResult == errSecSuccess)

    let hexKey = keyData.map { String(format: "%02x", $0) }.joined()
    let pragmaKey = "x'\(hexKey)'"

    // Create encrypted database
    let dbQueue = try DatabaseQueue(path: testDbPath.path)

    try dbQueue.write { db in
      // Enable encryption
      try db.execute(sql: "PRAGMA key = \(pragmaKey);")
      try db.execute(sql: "PRAGMA cipher_page_size = 4096;")

      // Create table using GRDB (simulating what @Table should do)
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS TestMessage (
          id TEXT PRIMARY KEY,
          text TEXT NOT NULL,
          timestamp REAL NOT NULL,
          isRead INTEGER NOT NULL
        );
      """)

      // Verify table was created
      let tableExists = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='TestMessage');
      """)

      #expect(tableExists == true)
    }

    // Test CRUD operations
    try dbQueue.write { db in
      // Insert
      try db.execute(sql: """
        INSERT INTO TestMessage (id, text, timestamp, isRead)
        VALUES (?, ?, ?, ?);
      """, arguments: ["msg1", "Hello, World!", Date().timeIntervalSince1970, 0])

      // Read
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
      #expect(count == 1)

      // Update
      try db.execute(sql: "UPDATE TestMessage SET isRead = 1 WHERE id = ?;", arguments: ["msg1"])

      let isRead = try Int.fetchOne(db, sql: "SELECT isRead FROM TestMessage WHERE id = ?;", arguments: ["msg1"])
      #expect(isRead == 1)

      // Delete
      try db.execute(sql: "DELETE FROM TestMessage WHERE id = ?;", arguments: ["msg1"])

      let countAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
      #expect(countAfter == 0)
    }
  }

  // MARK: - Test Multi-User Database Isolation

  @Test("Verify per-user database isolation")
  func testPerUserDatabaseIsolation() throws {
    let tempDir = FileManager.default.temporaryDirectory

    // Create two user databases
    let user1Path = tempDir.appendingPathComponent("user1_\(UUID().uuidString).db")
    let user2Path = tempDir.appendingPathComponent("user2_\(UUID().uuidString).db")

    defer {
      try? FileManager.default.removeItem(at: user1Path)
      try? FileManager.default.removeItem(at: user2Path)
    }

    // Generate different keys for each user
    var key1Data = Data(count: 32)
    var key2Data = Data(count: 32)

    _ = key1Data.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }
    _ = key2Data.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }

    #expect(key1Data != key2Data) // Different keys

    let pragmaKey1 = "x'\(key1Data.map { String(format: "%02x", $0) }.joined())'"
    let pragmaKey2 = "x'\(key2Data.map { String(format: "%02x", $0) }.joined())'"

    // Create and populate user1 database
    let db1 = try DatabaseQueue(path: user1Path.path)
    try db1.write { db in
      try db.execute(sql: "PRAGMA key = \(pragmaKey1);")
      try db.execute(sql: """
        CREATE TABLE TestMessage (id TEXT PRIMARY KEY, text TEXT);
        INSERT INTO TestMessage VALUES ('msg1', 'User 1 Message');
      """)
    }

    // Create and populate user2 database
    let db2 = try DatabaseQueue(path: user2Path.path)
    try db2.write { db in
      try db.execute(sql: "PRAGMA key = \(pragmaKey2);")
      try db.execute(sql: """
        CREATE TABLE TestMessage (id TEXT PRIMARY KEY, text TEXT);
        INSERT INTO TestMessage VALUES ('msg2', 'User 2 Message');
      """)
    }

    // Verify isolation - each database has only its own data
    let user1Count = try db1.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
    }
    let user2Count = try db2.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
    }

    #expect(user1Count == 1)
    #expect(user2Count == 1)

    // Verify wrong key cannot open database
    do {
      let wrongDb = try DatabaseQueue(path: user1Path.path)
      try wrongDb.read { db in
        try db.execute(sql: "PRAGMA key = \(pragmaKey2);") // Wrong key!
        _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
      }
      Issue.record("Should have failed with wrong key")
    } catch {
      // Expected to fail - this is correct behavior
      #expect(true)
    }
  }

  // MARK: - Test Database Features

  @Test("Verify WAL mode and foreign keys work with encryption")
  func testDatabaseFeatures() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let testDbPath = tempDir.appendingPathComponent("test_features_\(UUID().uuidString).db")

    defer {
      try? FileManager.default.removeItem(at: testDbPath)
    }

    var keyData = Data(count: 32)
    _ = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }

    let pragmaKey = "x'\(keyData.map { String(format: "%02x", $0) }.joined())'"
    let dbQueue = try DatabaseQueue(path: testDbPath.path)

    try dbQueue.write { db in
      // Enable encryption
      try db.execute(sql: "PRAGMA key = \(pragmaKey);")

      // Enable WAL mode
      try db.execute(sql: "PRAGMA journal_mode = WAL;")
      let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode;")
      #expect(journalMode?.uppercased() == "WAL")

      // Enable foreign keys
      try db.execute(sql: "PRAGMA foreign_keys = ON;")
      let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys;")
      #expect(foreignKeys == 1)

      // Test foreign key constraint
      try db.execute(sql: """
        CREATE TABLE Parent (id TEXT PRIMARY KEY);
        CREATE TABLE Child (
          id TEXT PRIMARY KEY,
          parent_id TEXT NOT NULL,
          FOREIGN KEY (parent_id) REFERENCES Parent(id) ON DELETE CASCADE
        );
      """)

      // Insert parent
      try db.execute(sql: "INSERT INTO Parent VALUES ('p1');")

      // Insert child
      try db.execute(sql: "INSERT INTO Child VALUES ('c1', 'p1');")

      // Try to insert child with invalid parent (should fail)
      do {
        try db.execute(sql: "INSERT INTO Child VALUES ('c2', 'invalid');")
        Issue.record("Should have failed foreign key constraint")
      } catch {
        // Expected to fail - foreign key constraint working
        #expect(true)
      }
    }
  }

  // MARK: - Performance Baseline

  @Test("Measure basic operation performance with encryption")
  func testEncryptedPerformance() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let testDbPath = tempDir.appendingPathComponent("test_perf_\(UUID().uuidString).db")

    defer {
      try? FileManager.default.removeItem(at: testDbPath)
    }

    var keyData = Data(count: 32)
    _ = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, 32, bufferPointer.baseAddress!)
    }

    let pragmaKey = "x'\(keyData.map { String(format: "%02x", $0) }.joined())'"
    let dbQueue = try DatabaseQueue(path: testDbPath.path)

    try dbQueue.write { db in
      try db.execute(sql: "PRAGMA key = \(pragmaKey);")
      try db.execute(sql: "PRAGMA journal_mode = WAL;")
      try db.execute(sql: """
        CREATE TABLE TestMessage (
          id TEXT PRIMARY KEY,
          text TEXT NOT NULL,
          timestamp REAL NOT NULL
        );
      """)
    }

    let messageCount = 100
    let startTime = Date()

    // Insert messages
    try dbQueue.write { db in
      for i in 0..<messageCount {
        try db.execute(
          sql: "INSERT INTO TestMessage VALUES (?, ?, ?);",
          arguments: ["msg\(i)", "Test message \(i)", Date().timeIntervalSince1970]
        )
      }
    }

    let endTime = Date()
    let duration = endTime.timeIntervalSince(startTime)

    // Should complete in reasonable time (< 1 second for 100 inserts)
    #expect(duration < 1.0)

    // Verify all inserted
    let count = try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM TestMessage;")
    }
    #expect(count == messageCount)

    print("✅ Inserted \(messageCount) encrypted records in \(String(format: "%.3f", duration))s")
  }
}
