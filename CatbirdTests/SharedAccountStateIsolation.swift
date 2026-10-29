//
//  SharedAccountStateIsolation.swift
//  CatbirdTests
//

import CatbirdMLSCore
import Foundation
import Testing
@testable import Catbird

// MARK: - Shared account state isolation

/// Runs a test that drives the real account path (`AppStateManager.shared` transitions or
/// `AuthenticationManager.switchToAccount`) from a signed-out lifecycle, then puts the shared
/// lifecycle and `MLSGRDBManager.shared` back the way the test found them.
///
/// The account path makes each account it signs in the active user of the shared MLS database
/// manager and leaves that account's database open. Suites that need an inactive shared manager
/// (for example the C29 draft entrypoint fixture) refuse to run after such a test, and a test
/// that starts from an earlier test's signed-in lifecycle tries to drain that account first.
struct SharedAccountStateIsolation: TestTrait, TestScoping {
  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    let snapshot = await SharedAccountStateSnapshot.captureAndSignOut()
    do {
      try await function()
    } catch {
      await snapshot.restore()
      throw error
    }
    await snapshot.restore()
  }
}

extension Trait where Self == SharedAccountStateIsolation {
  /// Starts the test signed out and restores the shared lifecycle and MLS database manager after it.
  static var isolatesSharedAccountState: Self { Self() }
}

@MainActor
private final class SharedAccountStateSnapshot {
  private let lifecycle: AppLifecycle
  private let cachedAccountDIDs: Set<String>
  private let activeDatabaseDID: String?
  private let openDatabaseDIDs: Set<String>

  private init(
    lifecycle: AppLifecycle,
    cachedAccountDIDs: Set<String>,
    activeDatabaseDID: String?,
    openDatabaseDIDs: Set<String>
  ) {
    self.lifecycle = lifecycle
    self.cachedAccountDIDs = cachedAccountDIDs
    self.activeDatabaseDID = activeDatabaseDID
    self.openDatabaseDIDs = openDatabaseDIDs
  }

  static func captureAndSignOut() async -> SharedAccountStateSnapshot {
    let appStateManager = AppStateManager.shared
    let database = MLSGRDBManager.shared
    let snapshot = SharedAccountStateSnapshot(
      lifecycle: appStateManager.lifecycle,
      cachedAccountDIDs: Set(appStateManager.authenticatedDIDs),
      activeDatabaseDID: await database.currentActiveDID,
      openDatabaseDIDs: Set(await database.openDatabaseUsers)
    )
    appStateManager.setLifecycleForTesting(.unauthenticated)
    return snapshot
  }

  func restore() async {
    let appStateManager = AppStateManager.shared
    appStateManager.setLifecycleForTesting(lifecycle)

    // Stop MLS work for accounts the test signed in, as an account switch does for the old account.
    let signedInDuringTest = appStateManager.authenticatedDIDs.filter { !cachedAccountDIDs.contains($0) }
    for did in signedInDuringTest {
      await appStateManager.prepareMLSStorageReset(for: did)
    }

    // AppState startup continues in the background after the test body returns: it can create
    // an MLS conversation manager, open its account's database and make that account active
    // again. Keep tearing that work down until the shared manager has matched the snapshot for
    // a quiet period, and report the test if it never settles.
    let database = MLSGRDBManager.shared
    let quietChecksRequired = 5
    let deadline = ContinuousClock.now + .seconds(10)
    var quietChecks = 0
    while quietChecks < quietChecksRequired {
      var changed = false
      for did in signedInDuringTest where appStateManager.getState(for: did)?.mlsConversationManager != nil {
        await appStateManager.prepareMLSStorageReset(for: did)
        changed = true
      }
      for did in await database.openDatabaseUsers where !openDatabaseDIDs.contains(did) {
        _ = await database.closeDatabaseAndDrain(for: did, timeout: 2.0)
        changed = true
      }
      if await database.currentActiveDID != activeDatabaseDID {
        await database.setActiveUser(activeDatabaseDID)
        changed = true
      }
      quietChecks = changed ? 0 : quietChecks + 1
      guard ContinuousClock.now < deadline else {
        let active = await database.currentActiveDID ?? "nil"
        let open = await database.openDatabaseUsers.sorted()
        Issue.record("Shared MLS database state did not settle after the test: active=\(active), open=\(open)")
        return
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}
