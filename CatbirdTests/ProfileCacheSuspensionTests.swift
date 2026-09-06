import Foundation
import GRDB
import Synchronization
import Testing
@testable import Catbird

@Suite("Profile cache suspension", .serialized)
struct ProfileCacheSuspensionTests {
  @Test("Existing profile cache rejects writes while suspended and recovers on resume")
  func existingPoolRejectsSuspendedWrites() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test setup")
    defer { GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test cleanup") }
    let cache = ProfileCacheDatabase(databaseURL: directory.appendingPathComponent("profiles.db"))
    await cache.write(did: "did:plc:test", handle: "before.test", displayName: nil, avatarURL: nil)
    let pool = try await cache.getPool()

    GRDBSuspensionCoordinator.setLifecycleSuspended(true, reason: "test background")
    do {
      try await pool.write { db in
        try db.execute(sql: "UPDATE cached_profiles SET handle = 'blocked.test'")
      }
      Issue.record("A suspended profile cache accepted a write")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_ABORT)
    }
    await cache.write(did: "did:plc:test", handle: "blocked.test", displayName: nil, avatarURL: nil)

    GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test foreground")
    #expect(await cache.read(did: "did:plc:test")?.handle == "before.test")
    await cache.write(did: "did:plc:test", handle: "after.test", displayName: nil, avatarURL: nil)
    #expect(await cache.read(did: "did:plc:test")?.handle == "after.test")
  }

  @Test("A profile cache first used after suspension defers opening until resume")
  func latePoolDefersOpeningUntilResume() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GRDBSuspensionCoordinator.setLifecycleSuspended(true, reason: "test background")
    defer { GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test cleanup") }
    let url = directory.appendingPathComponent("profiles.db")
    let cache = ProfileCacheDatabase(databaseURL: url)

    await cache.write(did: "did:plc:test", handle: "blocked.test", displayName: nil, avatarURL: nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    do {
      _ = try await cache.getPool()
      Issue.record("A profile cache opened after the suspension notification")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_ABORT)
    }

    GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test foreground")
    #expect(await cache.read(did: "did:plc:test") == nil)
    await cache.write(did: "did:plc:test", handle: "after.test", displayName: nil, avatarURL: nil)
    #expect(await cache.read(did: "did:plc:test")?.handle == "after.test")
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("Reentrant lifecycle changes finish suspension delivery before resuming pools")
  func reentrantLifecycleChangeResumesPool() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test setup")
    defer { GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "test cleanup") }
    let cache = ProfileCacheDatabase(databaseURL: directory.appendingPathComponent("profiles.db"))
    _ = try await cache.getPool()
    let handlingSuspend = Mutex(false)
    let center = NotificationCenter.default
    let suspendObserver = center.addObserver(forName: Database.suspendNotification, object: nil, queue: nil) { _ in
      handlingSuspend.withLock { $0 = true }
      GRDBSuspensionCoordinator.setLifecycleSuspended(false, reason: "reentrant foreground")
      handlingSuspend.withLock { $0 = false }
    }
    let resumeObserver = center.addObserver(forName: Database.resumeNotification, object: nil, queue: nil) { _ in
      #expect(!handlingSuspend.withLock { $0 })
    }
    defer {
      center.removeObserver(suspendObserver)
      center.removeObserver(resumeObserver)
    }

    GRDBSuspensionCoordinator.setLifecycleSuspended(true, reason: "test background")
    await cache.write(did: "did:plc:test", handle: "resumed.test", displayName: nil, avatarURL: nil)
    #expect(await cache.read(did: "did:plc:test")?.handle == "resumed.test")
  }
}
