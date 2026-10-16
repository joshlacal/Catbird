#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import Catbird

/// Calls the app's recovery operations against temporary locations and isolated defaults.
/// Every protection check has a post-loss orphan control, so a disabled sweep cannot pass.
@Suite("Draft photo production recovery fences")
@MainActor
struct DraftPhotoRecoveryFenceTests {
  private static let day: TimeInterval = 86_400

  enum Loss: CaseIterable { case reset, quarantine, writeAheadLog, migrationCollision }

  @Test("Each operation that loses rows durably protects their photos", arguments: Loss.allCases)
  func recoveryOperationsFencePhotos(_ loss: Loss) async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let locations = locations(in: sandbox)
    let lostAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - 30 * Self.day))
    let sweepAt = Date()
    let old = try sandbox.managedFile(modifiedAt: sweepAt.addingTimeInterval(-8 * Self.day))
    try setBirth(old, to: lostAt.addingTimeInterval(-Self.day))
    let new = try sandbox.managedFile(modifiedAt: sweepAt.addingTimeInterval(-8 * Self.day))
    try setBirth(new, to: lostAt.addingTimeInterval(Self.day))
    let store = try #require(locations.storeDirectory)
    let legacy = try #require(locations.legacyDirectory)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data("durable store".utf8).write(to: store.appendingPathComponent("Catbird.store"))
    let wal = store.appendingPathComponent("Catbird.store-wal")
    try Data("uncheckpointed draft rows".utf8).write(to: wal)

    switch loss {
    case .reset:
      CatbirdSwiftDataStore.resetAllDatabaseFiles(locations: locations, now: lostAt)
      #expect(!DraftPhotoSandbox.exists(store))
    case .quarantine:
      CatbirdSwiftDataStore.quarantineSwiftDataStore(reason: "test", locations: locations, now: lostAt)
      #expect(!DraftPhotoSandbox.exists(store.appendingPathComponent("Catbird.store")))
      let quarantines = try FileManager.default.contentsOfDirectory(at: sandbox.quarantine, includingPropertiesForKeys: nil)
      #expect(quarantines.count == 1)
      // The operation happened at the injected clock time; model the folder's birth too.
      for folder in quarantines { try setBirth(folder, to: lostAt) }
    case .writeAheadLog:
      CatbirdSwiftDataStore.deleteSwiftDataSidecarsOnly(locations: locations, now: lostAt)
      #expect(!DraftPhotoSandbox.exists(wal))
      #expect(DraftPhotoSandbox.exists(store.appendingPathComponent("Catbird.store")))
    case .migrationCollision:
      try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
      try Data("different account's old rows".utf8).write(to: legacy.appendingPathComponent("Catbird.store"))
      CatbirdSwiftDataStore.migrateSwiftDataFromAppGroup(locations: locations, now: lostAt)
      #expect(!DraftPhotoSandbox.exists(legacy))
      #expect(try Data(contentsOf: store.appendingPathComponent("Catbird.store")) == Data("durable store".utf8))
    }

    let fence = CatbirdSwiftDataStore.lastStoreResetDate(in: sandbox.recoveryDefaults)
    #expect(fence == lostAt, "the production loss hook must persist the fence outside the removed store")
    let report = await sandbox.sweep(storeResetDate: fence).run(now: sweepAt)
    #expect(DraftPhotoSandbox.exists(old), "the old account's remote row may still import")
    #expect(!DraftPhotoSandbox.exists(new), "post-loss unreferenced photos still expire")
    #expect(report.removed == 1)
  }

  @Test("A crash-loop volatile session fences its photos on the next durable opening")
  func volatileToDurableTransition() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let locations = locations(in: sandbox)
    let enteredAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - 40 * Self.day))
    let reopenedAt = enteredAt.addingTimeInterval(10 * Self.day)
    sandbox.recoveryDefaults.set(2, forKey: CatbirdSwiftDataStore.launchAttemptCountKey)
    sandbox.recoveryDefaults.set(enteredAt.timeIntervalSince1970, forKey: CatbirdSwiftDataStore.lastLaunchTimeKey)
    let volatile = CatbirdSwiftDataStore.openWithRecovery(locations: locations, now: enteredAt)
    guard case .degraded(let memory, _) = volatile else {
      Issue.record("The crash-loop production branch must open the in-memory store")
      return
    }
    let accountB = "did:plc:volatile-account-b"
    let photo = try sandbox.managedFile(modifiedAt: Date().addingTimeInterval(-8 * Self.day))
    try setBirth(photo, to: enteredAt.addingTimeInterval(Self.day))
    let volatilePersistence = DraftPersistence(modelContext: memory.mainContext)
    _ = try volatilePersistence.saveDraft(DraftPhotoSandbox.draft(naming: photo), accountDID: accountB)

    // No B rows survive. A's durable launch has no reason to import B's remote drafts yet.
    let durable = CatbirdSwiftDataStore.openWithRecovery(locations: locations, now: reopenedAt)
    guard case .ready(let disk) = durable else {
      Issue.record("The next launch must open the real temporary durable store")
      return
    }
    #expect(try DraftPersistence(modelContext: disk.mainContext).fetchDrafts(for: accountB).isEmpty)
    let fence = CatbirdSwiftDataStore.lastStoreResetDate(in: sandbox.recoveryDefaults)
    #expect(fence == reopenedAt, "entry time alone cannot protect photos written later in safe mode")
    let postRecovery = try sandbox.managedFile(modifiedAt: Date().addingTimeInterval(-8 * Self.day))
    try setBirth(postRecovery, to: reopenedAt.addingTimeInterval(Self.day))
    let report = await sandbox.sweep(storeResetDate: fence).run(now: Date())
    #expect(DraftPhotoSandbox.exists(photo))
    #expect(!DraftPhotoSandbox.exists(postRecovery))
    #expect(report.removed == 1)

    // A normal durable opening must not advance the fence forever.
    _ = CatbirdSwiftDataStore.openWithRecovery(locations: locations, now: reopenedAt.addingTimeInterval(Self.day))
    #expect(CatbirdSwiftDataStore.lastStoreResetDate(in: sandbox.recoveryDefaults) == reopenedAt)
  }

  private func locations(in sandbox: DraftPhotoSandbox) -> CatbirdSwiftDataStore.RecoveryLocations {
    CatbirdSwiftDataStore.RecoveryLocations(
      storeDirectory: sandbox.root.appendingPathComponent("swiftdata", isDirectory: true),
      legacyDirectory: sandbox.root.appendingPathComponent("legacy-swiftdata", isDirectory: true),
      additionalDatabaseDirectories: [], defaults: sandbox.recoveryDefaults
    )
  }

  private func setBirth(_ url: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
  }
}
#endif
