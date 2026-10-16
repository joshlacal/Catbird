#if os(iOS)
import Foundation
import Petrel
import SwiftData
import Testing
@testable import Catbird

/// DraftImageOrphanSweep in a DraftPhotoSandbox: what a run removes, keeps and never touches, the
/// quarantine and store-reset fence, and how a run stops. DraftImageOrphanSweepGate's rules are
/// checked on their own, and ComposerDraftManager's wiring of them with an on-disk store and a
/// real DraftSyncService. Nothing here runs against the host app's SharedDrafts folder, and the
/// sweep's last start is written only to the sandbox's own defaults suite.
@Suite("Draft photo orphan sweep")
@MainActor
struct DraftImageOrphanSweepTests {
  private static let day: TimeInterval = 86_400
  private let account = "did:plc:draftphotosweep"

  // MARK: One run

  @Test("A run removes week-old photos nothing names and keeps every named or recent one")
  func removesOldUnnamedFiles() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let aged = now.addingTimeInterval(-8 * Self.day)
    let orphan = try sandbox.managedFile(modifiedAt: aged)
    let namedByTombstone = try sandbox.managedFile(modifiedAt: aged)
    let recentOrphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-3_600))
    let named = try (0..<6).map { _ in try sandbox.managedFile(modifiedAt: aged) }
    let captured = sandbox.directory.appendingPathComponent("CapturedMedia", isDirectory: true)
    let untouched = [
      try sandbox.file(named: "\(UUID().uuidString).jpg", modifiedAt: aged),
      try sandbox.file(named: "\(UUID().uuidString).mov", modifiedAt: aged),
      try sandbox.file(named: "draft_image_\(DraftPhotoSandbox.randomHex().uppercased()).jpg", modifiedAt: aged),
      try sandbox.file(named: "draft_image_\(DraftPhotoSandbox.randomHex()).jpg", in: captured, modifiedAt: aged)
    ]
    let persistence = sandbox.persistence
    let tombstone = try persistence.saveDraft(DraftPhotoSandbox.draft(naming: namedByTombstone), accountDID: account)
    try persistence.markDeleted(id: tombstone, accountDID: account)
    _ = try persistence.saveDraft(DraftPhotoSandbox.draft(naming: named[0]), accountDID: "did:plc:someoneelse")
    sandbox.recoveryDefaults.set(
      DraftPhotoSandbox.naming(named[1]),
      forKey: SceneComposerEditingSession.persistenceKey(sceneID: UUID(), accountDID: account)
    )
    sandbox.recoveryDefaults.set(DraftPhotoSandbox.naming(named[2]), forKey: SceneComposerEditingSession.legacyRecoveryKey)
    sandbox.handoffDefaults.set(DraftPhotoSandbox.naming(named[3]), forKey: ComposeDraftStasher.draftKey)
    try DraftPhotoSandbox.naming(named[4]).write(to: sandbox.outboxQueue)
    try FileManager.default.createDirectory(at: sandbox.legacyDrafts, withIntermediateDirectories: true)
    try DraftPhotoSandbox.naming(named[5]).write(to: sandbox.legacyDrafts.appendingPathComponent("legacy.json"))

    let report = await sandbox.sweep().run(now: now)

    #expect(!DraftPhotoSandbox.exists(orphan))
    #expect(!DraftPhotoSandbox.exists(namedByTombstone), "a deleted draft's own photo")
    #expect(DraftPhotoSandbox.exists(recentOrphan), "used within the week")
    #expect(named.allSatisfy(DraftPhotoSandbox.exists), "another account's row, an envelope, the legacy key, the handoff slot, the outbox and a legacy JSON draft")
    #expect(untouched.allSatisfy(DraftPhotoSandbox.exists), "unmanaged names, videos and subfolders")
    #expect(report == DraftImageOrphanSweep.Report(removed: 2, keptNamed: 6, skippedByDate: 0, removedBytes: 8, stopReason: nil))
  }

  @Test("An open editor keeps a week-old photo it holds")
  func liveHolderKeepsOldFile() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let held = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-30 * Self.day))
    let holder = DraftPhotoTestHolder([held])

    let report = await sandbox.sweep().run(now: now)

    #expect(DraftPhotoSandbox.exists(held))
    #expect(report.removed == 0 && report.keptNamed == 1)
    withExtendedLifetime(holder) {}
  }

  @Test("Files last used before the newest quarantine or store reset are kept")
  func quarantineFence() async throws {
    let now = Date()
    // Quarantines 60 and 30 days ago: only a file last used after the newer one goes.
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      try sandbox.quarantinedStore(createdAt: now.addingTimeInterval(-60 * Self.day))
      try sandbox.quarantinedStore(createdAt: now.addingTimeInterval(-30 * Self.day))
      let beforeFence = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-40 * Self.day))
      let afterFence = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-10 * Self.day))

      let report = await sandbox.sweep().run(now: now)

      #expect(DraftPhotoSandbox.exists(beforeFence), "its row may still be in the quarantined store")
      #expect(!DraftPhotoSandbox.exists(afterFence))
      #expect(report.removed == 1)
    }
    // A store reset that left no quarantine copy fences the same way.
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      let beforeReset = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-40 * Self.day))
      let afterReset = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-10 * Self.day))

      let report = await sandbox.sweep(storeResetDate: now.addingTimeInterval(-30 * Self.day)).run(now: now)

      #expect(DraftPhotoSandbox.exists(beforeReset), "a Bluesky draft re-imported into the new store may name it")
      #expect(!DraftPhotoSandbox.exists(afterReset))
      #expect(report.removed == 1)
    }
    // A quarantine 2 days ago leaves no file old enough: nothing goes, and the empty window is fine.
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      try sandbox.quarantinedStore(createdAt: now.addingTimeInterval(-2 * Self.day))
      let aged = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))

      let report = await sandbox.sweep().run(now: now)

      #expect(DraftPhotoSandbox.exists(aged))
      #expect(report == DraftImageOrphanSweep.Report())
      let discovery = try DraftImageOrphanSweep.discover(
        directory: sandbox.directory, quarantineDirectory: sandbox.quarantine, storeResetDate: nil,
        now: now, minimumUnusedAge: DraftImageOrphanSweep.minimumUnusedAge
      )
      #expect(discovery == DraftImageOrphanSweep.Discovery(candidates: [], eligible: nil))
    }
  }

  @Test("A file named after it was listed, or reused since, is kept")
  func batchRechecksBeforeUnlink() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let reused = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-9 * Self.day))
    let orphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
    // Between listing and its batch, a composition reuses one file (writeImageData marks it).
    let sweep = sandbox.sweep(batchSize: 1, interruption: {
      try? DraftPhotoSandbox.setModified(reused, to: Date())
      return nil
    })

    let report = await sweep.run(now: now)

    #expect(DraftPhotoSandbox.exists(reused))
    #expect(!DraftPhotoSandbox.exists(orphan))
    #expect(report.removed == 1 && report.skippedByDate == 1)
  }

  @Test("Content-hash reuse preserves the original birth across a row-loss fence")
  func reusePreservesBirthProtection() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let data = Data("isolated draft safety image".utf8)
    let first = try #require(CodableMediaItem.writeImageData(data, directory: sandbox.directory))
    let file = try #require(URL(string: first.urlString))
    let birth = now.addingTimeInterval(-40 * Self.day)
    try FileManager.default.setAttributes([.creationDate: birth, .modificationDate: birth], ofItemAtPath: file.path)
    let reused = try #require(CodableMediaItem.writeImageData(data, directory: sandbox.directory))
    #expect(!reused.created)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.creationDate] as? Date).map { abs($0.timeIntervalSince(birth)) < 1 } == true)
    #expect((attributes[.modificationDate] as? Date).map { abs($0.timeIntervalSince(now)) < 60 } == true)
    let report = await sandbox.sweep(storeResetDate: now.addingTimeInterval(-30 * Self.day))
      .run(now: now.addingTimeInterval(8 * Self.day))
    #expect(DraftPhotoSandbox.exists(file))
    #expect(report.removed == 0)
  }

  // MARK: Stopping

  @Test("Reusing a pre-reset photo cannot erase its lost-row protection")
  func reuseDoesNotCrossLostRowFence() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let birth = now.addingTimeInterval(-40 * Self.day)
    let reset = now.addingTimeInterval(-30 * Self.day)
    let file = try sandbox.managedFile(modifiedAt: birth)
    try FileManager.default.setAttributes([.creationDate: birth], ofItemAtPath: file.path)
    // Another composition reuses this content hash after the row was quarantined, then ends.
    // Seven days later mtime is old again, but the absent account's remote row still names it.
    try DraftPhotoSandbox.setModified(file, to: now.addingTimeInterval(-8 * Self.day))

    let report = await sandbox.sweep(storeResetDate: reset).run(now: now)

    #expect(DraftPhotoSandbox.exists(file), "a later reuse must not make the original lost row's photo eligible")
    #expect(report.removed == 0)
  }

  @Test("A batch rechecks first-write protection immediately before unlink")
  func birthFenceRecheckedBeforeUnlink() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let reset = now.addingTimeInterval(-30 * Self.day)
    let file = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
    try FileManager.default.setAttributes(
      [.creationDate: now.addingTimeInterval(-20 * Self.day)], ofItemAtPath: file.path
    )
    let sweep = sandbox.sweep(storeResetDate: reset, interruption: {
      // Discovery's metadata must not authorize deletion of a file now carrying old birth
      // provenance (for example a recovered file replaced at the same content-hash path).
      try? FileManager.default.setAttributes(
        [.creationDate: now.addingTimeInterval(-40 * Self.day)], ofItemAtPath: file.path
      )
      return nil
    })

    let report = await sweep.run(now: now)

    #expect(DraftPhotoSandbox.exists(file))
    #expect(report.removed == 0 && report.skippedByDate == 1)
  }

  @Test("A store that cannot be read stops the run and keeps every file")
  func unreadableStoreStops() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let files = try (0..<3).map { _ in try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day)) }
    sandbox.recoveryDefaults.set("not data", forKey: SceneComposerEditingSession.legacyRecoveryKey)

    let report = await sandbox.sweep().run(now: now)

    #expect(report.stopReason == .storeUnreadable)
    #expect(report.removed == 0)
    #expect(files.allSatisfy(DraftPhotoSandbox.exists))
  }

  @Test("A run stops between batches when interrupted, and does nothing in a cancelled task")
  func stopsBetweenBatches() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let files = try (0..<5).map { _ in try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day)) }
    let checks = Counter()

    let interrupted = await sandbox.sweep(batchSize: 2, interruption: {
      checks.value += 1
      return checks.value > 1 ? .draftSyncStarted : nil
    }).run(now: now)

    #expect(interrupted.removed == 2)
    #expect(interrupted.stopReason == .draftSyncStarted)
    #expect(files.filter(DraftPhotoSandbox.exists).count == 3)

    let cancelled = await Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      return await sandbox.sweep().run(now: now)
    }.value

    #expect(cancelled.removed == 0)
    #expect(cancelled.stopReason == .cancelled)
    #expect(files.filter(DraftPhotoSandbox.exists).count == 3)
  }

  @Test("A folder that cannot be read stops the run; a missing draft folder has nothing to sweep")
  func unreadableFolders() async throws {
    let now = Date()
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      let file = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
      try Data("not a folder".utf8).write(to: sandbox.quarantine)

      let report = await sandbox.sweep().run(now: now)

      #expect(report.stopReason == .quarantineUnreadable)
      #expect(DraftPhotoSandbox.exists(file))
    }
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      try FileManager.default.removeItem(at: sandbox.directory)
      try Data("not a folder".utf8).write(to: sandbox.directory)

      #expect(await sandbox.sweep().run(now: now).stopReason == .folderUnreadable)
    }
    do {
      let sandbox = try DraftPhotoSandbox()
      defer { sandbox.remove() }
      try FileManager.default.removeItem(at: sandbox.directory)

      #expect(await sandbox.sweep().run(now: now) == DraftImageOrphanSweep.Report())
    }
  }

  // MARK: Gate

  @Test("The gate's rules", arguments: draftPhotoSweepGateCases)
  func gateRefusals(_ gate: DraftPhotoSweepGateCase) {
    let now = Date()
    let refusal = DraftImageOrphanSweepGate.refusal(
      storeIsDurable: gate.storeIsDurable,
      isInBackground: gate.isInBackground,
      syncEnabled: gate.syncEnabled,
      syncRunning: gate.syncRunning,
      syncCompletedThisLaunch: gate.syncCompleted,
      lastStartedAt: gate.lastStarted.map { now.addingTimeInterval($0) },
      now: now
    )
    #expect(refusal == gate.expected)
  }

  // MARK: The manager

  @Test("A manager on an in-memory store refuses and leaves everything in place")
  func inMemoryStoreRefuses() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let orphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
    let manager = ComposerDraftManager(
      accountDID: account, modelContext: sandbox.container.mainContext, defaults: sandbox.recoveryDefaults
    )
    useSandboxStores(sandbox, in: manager)

    let result = await manager.sweepOrphanedDraftImageFilesIfDue(now: now, isInBackground: { true })

    #expect(result == .refused(.storeNotDurable))
    #expect(DraftPhotoSandbox.exists(orphan))
    #expect(sandbox.recoveryDefaults.object(forKey: DraftImageOrphanSweep.lastStartedKey) == nil, "a refusal records no start")
  }

  @Test("A manager built for tests sweeps only a folder a test handed it")
  func testManagerWithoutFolderRefuses() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let durable = try DurableDrafts(sandbox: sandbox, account: account)
    durable.manager.useDraftImageStoresForTesting(
      handoffDefaults: sandbox.handoffDefaults, outboxQueueURL: sandbox.outboxQueue
    )

    #expect(await durable.sweep(at: Date()) == .refused(.folderUnavailable))
  }

  @Test("A manager on a durable store sweeps once a day")
  func durableStoreSweepsOncePerDay() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let durable = try DurableDrafts(sandbox: sandbox, account: account)
    let now = Date()
    let appDefaultsBefore = UserDefaults.standard.object(forKey: DraftImageOrphanSweep.lastStartedKey) as? Double
    let first = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))

    #expect(await durable.sweep(at: now) == .finished(.init(removed: 1, removedBytes: 4)))
    #expect(!DraftPhotoSandbox.exists(first))

    let second = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
    #expect(await durable.sweep(at: now) == .refused(.notDue))
    #expect(DraftPhotoSandbox.exists(second))
    #expect(await durable.sweep(at: now.addingTimeInterval(25 * 3_600)) == .finished(.init(removed: 1, removedBytes: 4)))
    #expect(!DraftPhotoSandbox.exists(second))

    let recorded = sandbox.recoveryDefaults.object(forKey: DraftImageOrphanSweep.lastStartedKey) as? Double
    #expect(recorded == now.addingTimeInterval(25 * 3_600).timeIntervalSince1970)
    #expect(UserDefaults.standard.object(forKey: DraftImageOrphanSweep.lastStartedKey) as? Double == appDefaultsBefore,
            "the app's own defaults are never written")
  }

  @Test("A run stops before its next batch when the app returns to the foreground")
  func stopsWhenAppReturnsToForeground() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let durable = try DurableDrafts(sandbox: sandbox, account: account)
    let now = Date()
    let orphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))
    let checks = Counter()

    // The gate sees the app in the background; by the first batch it is active again.
    let result = await durable.sweep(at: now, isInBackground: {
      checks.value += 1
      return checks.value == 1
    })

    #expect(result == .finished(.init(stopReason: .returnedToForeground)))
    #expect(DraftPhotoSandbox.exists(orphan))
  }

  @Test("With draft sync on, the sweep waits for a complete sync of the account in this launch")
  func draftSyncGate() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let durable = try DurableDrafts(sandbox: sandbox, account: account)
    let transport = HeldDraftTransport()
    let service = durable.useDraftSync(transport: transport)
    let now = Date()
    let orphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))

    #expect(await durable.sweep(at: now) == .refused(.draftSyncNotCompleted))

    transport.failsList = true
    await service.syncDrafts(accountDID: account)
    #expect(service.lastIssue != nil, "fixture: the pass failed")
    #expect(await durable.sweep(at: now) == .refused(.draftSyncNotCompleted), "a failed pass completes nothing")

    transport.failsList = false
    transport.holdsList = true
    let cancelledPass = Task { await service.syncDrafts(accountDID: account) }
    try await waitUntil { service.isSyncing && transport.isHolding }
    #expect(await durable.sweep(at: now) == .refused(.draftSyncRunning))
    cancelledPass.cancel()
    transport.release()
    await cancelledPass.value
    #expect(!service.isSyncing)
    #expect(await durable.sweep(at: now) == .refused(.draftSyncNotCompleted), "a cancelled pass completes nothing")

    transport.holdsList = false
    await service.syncDrafts(accountDID: account)
    #expect(service.syncedAccountsThisLaunch == [account])
    #expect(await durable.sweep(at: now) == .finished(.init(removed: 1, removedBytes: 4)))
    #expect(!DraftPhotoSandbox.exists(orphan))
  }

  @Test("A run stops before its next batch when a draft sync starts")
  func stopsWhenDraftSyncStarts() async throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let durable = try DurableDrafts(sandbox: sandbox, account: account)
    let transport = HeldDraftTransport()
    let service = durable.useDraftSync(transport: transport)
    await service.syncDrafts(accountDID: account)
    #expect(service.syncedAccountsThisLaunch == [account], "fixture: a complete pass")
    let now = Date()
    let orphan = try sandbox.managedFile(modifiedAt: now.addingTimeInterval(-8 * Self.day))

    // The pass starts at the run's first suspension, after the gate let it in.
    transport.holdsList = true
    let pass = Task { await service.syncDrafts(accountDID: account) }
    let result = await durable.sweep(at: now)

    #expect(result == .finished(.init(stopReason: .draftSyncStarted)))
    #expect(DraftPhotoSandbox.exists(orphan))
    transport.release()
    await pass.value
  }

  private func useSandboxStores(_ sandbox: DraftPhotoSandbox, in manager: ComposerDraftManager) {
    manager.useDraftImageStoresForTesting(
      handoffDefaults: sandbox.handoffDefaults, outboxQueueURL: sandbox.outboxQueue,
      legacyDraftsDirectory: sandbox.legacyDrafts, draftImagesDirectory: sandbox.directory,
      quarantineDirectory: sandbox.quarantine
    )
  }

  /// A ComposerDraftManager on an on-disk store in the sandbox, using only the sandbox's stores.
  @MainActor
  private struct DurableDrafts {
    let container: ModelContainer
    let manager: ComposerDraftManager
    let account: String

    init(sandbox: DraftPhotoSandbox, account: String) throws {
      let schema = Schema([DraftPost.self])
      container = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(
          schema: schema, url: sandbox.root.appendingPathComponent("Drafts.store"), cloudKitDatabase: .none
        )
      )
      self.account = account
      manager = ComposerDraftManager(
        accountDID: account, modelContext: container.mainContext, defaults: sandbox.recoveryDefaults
      )
      manager.useDraftImageStoresForTesting(
        handoffDefaults: sandbox.handoffDefaults, outboxQueueURL: sandbox.outboxQueue,
        legacyDraftsDirectory: sandbox.legacyDrafts, draftImagesDirectory: sandbox.directory,
        quarantineDirectory: sandbox.quarantine
      )
    }

    func sweep(
      at now: Date, isInBackground: @escaping @MainActor () -> Bool = { true }
    ) async -> DraftImageOrphanSweep.Result {
      await manager.sweepOrphanedDraftImageFilesIfDue(now: now, isInBackground: isInBackground)
    }

    /// A draft sync service with sync on, over this store and `transport`.
    func useDraftSync(transport: HeldDraftTransport) -> DraftSyncService {
      let account = account
      let service = DraftSyncService(
        persistence: DraftPersistence(modelContext: container.mainContext),
        clientProvider: { nil }, accountProvider: { account },
        enabledProvider: { true }, transportProvider: { _ in transport }
      )
      manager.useDraftSyncServiceForTesting(service)
      return service
    }
  }
}

// MARK: - Helpers

struct DraftPhotoSweepGateCase: CustomTestStringConvertible, Sendable {
  let name: String
  /// Seconds from now.
  var lastStarted: TimeInterval?
  var storeIsDurable = true
  var isInBackground = true
  var syncEnabled = false
  var syncRunning = false
  var syncCompleted = false
  let expected: DraftImageOrphanSweepGate.Refusal?
  var testDescription: String { name }
}

let draftPhotoSweepGateCases: [DraftPhotoSweepGateCase] = [
  .init(name: "never started", expected: nil),
  .init(name: "started an hour ago", lastStarted: -3_600, expected: .notDue),
  .init(name: "started 25 hours ago", lastStarted: -25 * 3_600, expected: nil),
  .init(name: "started 30 minutes ahead of the clock", lastStarted: 1_800, expected: .notDue),
  .init(name: "started 2 hours ahead of the clock", lastStarted: 2 * 3_600, expected: nil),
  .init(name: "started a year ahead of the clock", lastStarted: 365 * 86_400, expected: nil),
  .init(name: "in-memory store", storeIsDurable: false, expected: .storeNotDurable),
  .init(name: "app in the foreground", isInBackground: false, expected: .appInForeground),
  .init(name: "sync running", syncEnabled: true, syncRunning: true, syncCompleted: true, expected: .draftSyncRunning),
  .init(name: "sync on, not completed this launch", syncEnabled: true, expected: .draftSyncNotCompleted),
  .init(name: "sync on, completed this launch", syncEnabled: true, syncCompleted: true, expected: nil),
  .init(name: "sync off", syncEnabled: false, expected: nil),
  .init(name: "not due outranks every other refusal", lastStarted: -60, storeIsDurable: false,
        isInBackground: false, syncEnabled: true, syncRunning: true, expected: .notDue)
]

@MainActor
private final class Counter {
  var value = 0
}

/// A Bluesky drafts transport with no drafts, whose listing can fail or wait until released.
@MainActor
final class HeldDraftTransport: DraftSyncTransport {
  var failsList = false
  var holdsList = false
  private var waiting: CheckedContinuation<Void, Never>?

  var isHolding: Bool { waiting != nil }

  func list(cursor: String?) async throws -> DraftRemotePage {
    if holdsList {
      await withCheckedContinuation { waiting = $0 }
    }
    if failsList { throw DraftSyncFailure.http(503) }
    return DraftRemotePage(records: [], cursor: nil)
  }

  func release() {
    waiting?.resume()
    waiting = nil
  }

  func create(payload: Data) async throws -> String { throw DraftSyncFailure.http(400) }
  func update(id: String, payload: Data) async throws { throw DraftSyncFailure.http(400) }
  func delete(id: String) async throws { throw DraftSyncFailure.http(400) }
}

/// Waits for a condition another task brings about, for at most two seconds.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<200 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
}
#endif
