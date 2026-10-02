import Testing
@testable import Catbird
#if os(iOS)
import Foundation
import GRDB
#endif

@MainActor
@Suite("MLS suspension storage close", .serialized)
struct MLSSuspensionCloseCoordinatorTests {
  @Test("A missing Rust path still closes Swift storage")
  func missingRustPathClosesSwiftStorage() async {
    var swiftClosed = false
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: false,
      transitionStillCurrent: { true },
      prepareRustRuntime: { Issue.record("Unavailable Rust path was prepared"); return true },
      closePreparedRuntime: { Issue.record("Unavailable Rust path was closed") },
      closeSwiftStorage: { swiftClosed = true; return true },
      waitForSwiftStorageRetry: { Issue.record("Completed storage should not wait"); return false }
    )
    #expect(swiftClosed)
    #expect(outcome == .rustPathUnavailable)
  }

  @Test("Rust preparation failure still drains Swift storage without reporting complete")
  func failedPreparationClosesSwiftStorage() async {
    var swiftClosed = false
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: true,
      transitionStillCurrent: { true },
      prepareRustRuntime: { false },
      closePreparedRuntime: { Issue.record("Unprepared Rust path was closed") },
      closeSwiftStorage: { swiftClosed = true; return true },
      waitForSwiftStorageRetry: { false }
    )
    #expect(swiftClosed)
    #expect(outcome == .preparationFailed)
  }

  @Test("Completion waits for a pending Swift open or close to release storage")
  func incompleteSwiftCloseRetriesAfterYield() async {
    var events: [String] = []
    var opening = true
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: true,
      transitionStillCurrent: { true },
      prepareRustRuntime: { events.append("prepare"); return true },
      closePreparedRuntime: { events.append("rust closed") },
      closeSwiftStorage: {
        events.append(opening ? "swift retained" : "swift closed")
        return !opening
      },
      waitForSwiftStorageRetry: {
        await Task.yield()
        events.append("open unwound")
        opening = false
        return true
      }
    )
    #expect(events == ["prepare", "rust closed", "swift retained", "open unwound", "swift closed"])
    #expect(outcome == .closed)
  }

  @Test("Retained Swift storage at expiration cannot report successful close")
  func expirationStopsIncompleteClose() async {
    var closeAttempts = 0
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: true,
      transitionStillCurrent: { true },
      prepareRustRuntime: { true },
      closePreparedRuntime: {},
      closeSwiftStorage: { closeAttempts += 1; return false },
      waitForSwiftStorageRetry: { false }
    )
    #expect(closeAttempts == 1)
    #expect(outcome == .storageCloseIncomplete)
  }

  @Test("Foreground during Rust preparation prevents both storage closes")
  func stalePreparationDoesNotCloseForegroundStorage() async {
    var current = true
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: true,
      transitionStillCurrent: { current },
      prepareRustRuntime: { await Task.yield(); current = false; return true },
      closePreparedRuntime: { Issue.record("A stale transition closed Rust storage") },
      closeSwiftStorage: { Issue.record("A stale transition closed Swift storage"); return true },
      waitForSwiftStorageRetry: { false }
    )
    #expect(outcome == .staleTransition)
  }

  @Test("Foreground while waiting for Swift storage prevents a later close")
  func staleRetryDoesNotCloseReopenedForegroundStorage() async {
    var current = true
    var closeAttempts = 0
    let outcome = await MLSSuspensionCloseCoordinator.run(
      rustPathAvailable: false,
      transitionStillCurrent: { current },
      prepareRustRuntime: { true },
      closePreparedRuntime: {},
      closeSwiftStorage: { closeAttempts += 1; return false },
      waitForSwiftStorageRetry: { await Task.yield(); current = false; return true }
    )
    #expect(closeAttempts == 1)
    #expect(outcome == .staleTransition)
  }

  @Test("Expiration retries Swift storage after the normal path claimed Rust close")
  func expirationRetriesSwiftAfterRustClaimWasConsumed() {
    var swiftClosed = false
    let complete = MLSSuspensionCloseCoordinator.runExpiration(
      transitionStillCurrent: { true },
      claimRustRuntimeClose: { false },
      closeRustRuntime: { Issue.record("Rust was closed twice") },
      closeSwiftStorage: { swiftClosed = true; return true }
    )
    #expect(swiftClosed)
    #expect(complete)
  }

  @Test("Each expiration retries retained Swift storage but claims Rust only once")
  func repeatedExpirationRetriesRetainedStorage() {
    var rustClaimed = false
    var rustCloses = 0
    var swiftCloseAttempts = 0
    func expire() -> Bool {
      MLSSuspensionCloseCoordinator.runExpiration(
        transitionStillCurrent: { true },
        claimRustRuntimeClose: {
          guard !rustClaimed else { return false }
          rustClaimed = true
          return true
        },
        closeRustRuntime: { rustCloses += 1 },
        closeSwiftStorage: { swiftCloseAttempts += 1; return swiftCloseAttempts == 2 }
      )
    }
    #expect(!expire())
    #expect(expire())
    #expect(rustCloses == 1)
    #expect(swiftCloseAttempts == 2)
  }

  @Test("An expired older scene cannot close a newer foreground's storage")
  func staleExpirationDoesNotCloseStorage() {
    let complete = MLSSuspensionCloseCoordinator.runExpiration(
      transitionStillCurrent: { false },
      claimRustRuntimeClose: { Issue.record("A stale expiration claimed Rust close"); return true },
      closeRustRuntime: { Issue.record("A stale expiration closed Rust storage") },
      closeSwiftStorage: { Issue.record("A stale expiration closed Swift storage"); return true }
    )
    #expect(!complete)
  }

  #if os(iOS)
  @Test("Successful resume adopts the replacement pool before projection reads")
  func foregroundResumeHandsOffReplacementPoolBeforeProjectionRead() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mls-foreground-pool-\(UUID().uuidString).sqlite")
    let closedPool = try DatabasePool(path: databaseURL.path)
    try await closedPool.write { db in
      try db.execute(sql: "CREATE TABLE resume_probe(value INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO resume_probe VALUES (42)")
    }
    try closedPool.close()
    #expect(throws: DatabaseError.self) {
      try closedPool.read { try Int.fetchOne($0, sql: "SELECT value FROM resume_probe") }
    }
    let replacementPool = try DatabasePool(path: databaseURL.path)
    defer { try? replacementPool.close() }
    var managerPool = closedPool
    var projectionPool = closedPool
    var projectionValue: Int?
    var events: [String] = []
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive) }

    let outcome = await MLSForegroundResumeCoordinator.run(
      managerAvailable: true,
      resumeStillCurrent: { MLSForegroundResumeCoordinator.isCurrentActiveTransition(generation) },
      prepareStorage: { events.append("prepared") },
      resumeManager: {
        await Task.yield()
        managerPool = replacementPool
        events.append("manager resumed")
        return .resumed
      },
      reassertSuspensionAfterStaleResume: { Issue.record("Current resume was treated as stale") },
      reloadProjection: {
        projectionPool = managerPool
        events.append("pool handed off")
        do {
          projectionValue = try await projectionPool.read {
            try Int.fetchOne($0, sql: "SELECT value FROM resume_probe")
          }
          events.append("projection read")
        } catch {
          Issue.record("Projection used closed storage: \(error)")
        }
      },
      performBackup: { events.append("backup") }
    )

    #expect(outcome == .resumed)
    #expect(projectionPool === replacementPool)
    #expect(projectionValue == 42)
    #expect(events == ["prepared", "manager resumed", "pool handed off", "projection read", "backup"])
  }

  @Test("A failed Core resume cannot hand off storage or reload the projection")
  func failedForegroundResumeSkipsPoolHandoff() async {
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive) }
    var projectionReloaded = false
    let outcome = await MLSForegroundResumeCoordinator.run(
      managerAvailable: true,
      resumeStillCurrent: { MLSForegroundResumeCoordinator.isCurrentActiveTransition(generation) },
      prepareStorage: {},
      resumeManager: { await Task.yield(); return .failedStillSuspended },
      reassertSuspensionAfterStaleResume: { Issue.record("Failed resume was treated as stale") },
      reloadProjection: { projectionReloaded = true },
      performBackup: { Issue.record("Failed resume performed backup") }
    )
    #expect(outcome == .failedStillSuspended)
    #expect(!projectionReloaded)
  }

  @Test("Becoming inactive during Core resume prevents the projection pool handoff")
  func staleForegroundResumeSkipsPoolHandoff() async {
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    var staleResumeHandled = false
    var projectionReloaded = false
    let outcome = await MLSForegroundResumeCoordinator.run(
      managerAvailable: true,
      resumeStillCurrent: { MLSForegroundResumeCoordinator.isCurrentActiveTransition(generation) },
      prepareStorage: {},
      resumeManager: {
        await Task.yield()
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
        return .resumed
      },
      reassertSuspensionAfterStaleResume: { staleResumeHandled = true },
      reloadProjection: { projectionReloaded = true },
      performBackup: { Issue.record("Stale resume performed backup") }
    )
    #expect(outcome == .staleTransition)
    #expect(staleResumeHandled)
    #expect(!projectionReloaded)
  }

  @Test("Open lifecycle gates do not make a failed runtime recovery successful")
  func failedRuntimeRecoverySkipsProjectionHandoff() async {
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive) }
    var projectionReloaded = false
    let outcome = await MLSForegroundResumeCoordinator.run(
      managerAvailable: true,
      resumeStillCurrent: { MLSForegroundResumeCoordinator.isCurrentActiveTransition(generation) },
      prepareStorage: {},
      resumeManager: { .runtimeRecoveryFailed },
      reassertSuspensionAfterStaleResume: { Issue.record("Failed recovery was treated as stale") },
      reloadProjection: { projectionReloaded = true },
      performBackup: { Issue.record("Failed recovery performed backup") }
    )
    #expect(outcome == .runtimeRecoveryFailed)
    #expect(!projectionReloaded)
  }

  @Test("Entering inactive immediately revokes the foreground storage permit")
  func inactiveRevokesForegroundStoragePermit() throws {
    let activeGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    let permit = try #require(
      MLSForegroundResumeCoordinator.storagePreparationPermit(for: activeGeneration)
    )
    #expect(permit.isValid)

    _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)

    #expect(!permit.isValid)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: activeGeneration) == nil)
  }

  @Test("Entering background immediately revokes the foreground storage permit")
  func backgroundRevokesForegroundStoragePermit() throws {
    let activeGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    let permit = try #require(
      MLSForegroundResumeCoordinator.storagePreparationPermit(for: activeGeneration)
    )

    let backgroundGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)

    #expect(!permit.isValid)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: activeGeneration) == nil)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: backgroundGeneration) == nil)
  }

  @Test("A stale foreground task cannot acquire the next active generation's permit")
  func newForegroundGenerationRejectsOldStoragePermit() throws {
    let oldGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    let oldPermit = try #require(
      MLSForegroundResumeCoordinator.storagePreparationPermit(for: oldGeneration)
    )
    _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
    _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
    let newGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive) }
    let newPermit = try #require(
      MLSForegroundResumeCoordinator.storagePreparationPermit(for: newGeneration)
    )

    #expect(!oldPermit.isValid)
    #expect(newPermit.isValid)
    #expect(oldPermit !== newPermit)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: oldGeneration) == nil)
  }

  @Test("A replacement active transition revokes the previous active permit")
  func replacementActiveTransitionRevokesPreviousPermit() throws {
    let oldGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    let oldPermit = try #require(
      MLSForegroundResumeCoordinator.storagePreparationPermit(for: oldGeneration)
    )
    let newGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive) }

    #expect(!oldPermit.isValid)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: oldGeneration) == nil)
    #expect(MLSForegroundResumeCoordinator.storagePreparationPermit(for: newGeneration)?.isValid == true)
  }

  @Test("A scene's normal Rust claim does not consume its expiration storage cleanup")
  func normalSceneClaimAllowsExpirationStorageCleanup() {
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
    defer { _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active) }
    let claim = MLSSceneSuspensionCloseClaim(transitionToken: generation, expectedPhase: .background)
    #expect(claim.claimNormalCloseIfCurrent())
    var swiftClosed = false

    let complete = MLSSuspensionCloseCoordinator.runExpiration(
      transitionStillCurrent: { claim.requestExpirationIfCurrent() },
      claimRustRuntimeClose: { claim.claimExpirationIfCurrent() },
      closeRustRuntime: { Issue.record("Normal close already claimed this scene's Rust runtime") },
      closeSwiftStorage: { swiftClosed = true; return true }
    )

    #expect(claim.expirationRequested)
    #expect(swiftClosed)
    #expect(complete)
  }

  @Test("A scene's expiration cannot act on a newer foreground generation")
  func foregroundInvalidatesSceneExpirationClaim() {
    let inactiveGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
    let inactiveClaim = MLSSceneSuspensionCloseClaim(
      transitionToken: inactiveGeneration, expectedPhase: .inactive
    )
    let backgroundGeneration = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
    let backgroundClaim = MLSSceneSuspensionCloseClaim(
      transitionToken: backgroundGeneration, expectedPhase: .background
    )
    _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)

    for claim in [inactiveClaim, backgroundClaim] {
      let complete = MLSSuspensionCloseCoordinator.runExpiration(
        transitionStillCurrent: { claim.requestExpirationIfCurrent() },
        claimRustRuntimeClose: { claim.claimExpirationIfCurrent() },
        closeRustRuntime: { Issue.record("A stale scene expiration closed Rust storage") },
        closeSwiftStorage: { Issue.record("A stale scene expiration closed Swift storage"); return true }
      )

      #expect(!complete)
      #expect(!claim.expirationRequested)
    }
  }
  #endif
}
