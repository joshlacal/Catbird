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
/// lifecycle and `MLSClientCoordinator` state back the way the test found them.
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
  /// Starts the test signed out and restores the shared lifecycle and MLS coordinator state after it.
  static var isolatesSharedAccountState: Self { Self() }
}

@MainActor
private final class SharedAccountStateSnapshot {
  private let lifecycle: AppLifecycle
  private let cachedAccountDIDs: Set<String>

  private init(
    lifecycle: AppLifecycle,
    cachedAccountDIDs: Set<String>
  ) {
    self.lifecycle = lifecycle
    self.cachedAccountDIDs = cachedAccountDIDs
  }

  static func captureAndSignOut() async -> SharedAccountStateSnapshot {
    let appStateManager = AppStateManager.shared
    let snapshot = SharedAccountStateSnapshot(
      lifecycle: appStateManager.lifecycle,
      cachedAccountDIDs: Set(appStateManager.authenticatedDIDs)
    )
    appStateManager.setLifecycleForTesting(.unauthenticated)
    return snapshot
  }

  func restore() async {
    let appStateManager = AppStateManager.shared
    appStateManager.setLifecycleForTesting(lifecycle)

    let signedInDuringTest = appStateManager.authenticatedDIDs.filter { !cachedAccountDIDs.contains($0) }
    for did in signedInDuringTest {
      await appStateManager.prepareMLSStorageReset(for: did)
    }

    let quietChecksRequired = 5
    let deadline = ContinuousClock.now + .seconds(10)
    var quietChecks = 0
    while quietChecks < quietChecksRequired {
      var changed = false
      for did in signedInDuringTest where appStateManager.getState(for: did)?.mlsCoordinator != nil {
        await appStateManager.prepareMLSStorageReset(for: did)
        changed = true
      }
      quietChecks = changed ? 0 : quietChecks + 1
      guard ContinuousClock.now < deadline else {
        Issue.record("Shared MLS coordinator state did not settle after the test")
        return
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}
