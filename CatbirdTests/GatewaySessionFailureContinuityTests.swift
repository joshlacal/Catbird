import Foundation
import OSLog
import Petrel
import Testing
@testable import Catbird

/// Exercises the actual app consumer with a public-only client: no authenticated SDK
/// initializer, keychain, app singleton, APNs, biometric prompt, or network operation.
/// SDK tests separately qualify the opaque proof factory and its generation validation.
@Suite("Gateway session failure continuity", .serialized)
@MainActor
struct GatewaySessionFailureContinuityTests {
  private let accountA = "did:plc:fixtureaccounta"
  private let accountB = "did:plc:fixtureaccountb"

  private struct SilentLog: AuthLogHandler {
    func log(level: OSLogType, event: AuthLogEvent) {}
  }

  private func fixture(
    overrides: AuthenticationDependencyOverrides = .init()
  ) async -> (AuthenticationManager, ATProtoClient, UserDefaults, String) {
    let suite = "GatewaySessionFailureContinuity-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let manager = AuthenticationManager(
      userDefaults: defaults, logHandler: SilentLog(), dependencyOverrides: overrides,
      configureBiometrics: false
    )
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    manager.setAuthenticatedForTesting(did: accountA, client: client)
    return (manager, client, defaults, suite)
  }

  @Test("Unscoped legacy failures cannot sign out a working account", arguments: [nil, "", "  "] as [String?])
  func unscopedFailureIsIgnored(did: String?) async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    await manager.handleAutoLogoutFromPetrel(did: did, reason: "session_expired")
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
    #expect(manager.expiredAccountInfo == nil)
  }

  @Test("Late B rejection after rollback never checks or tears down A")
  func inactiveAccountProofIsIgnored() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    var checks = 0
    await manager.handleGatewaySessionFailure(did: accountB, reason: "session_expired") { _ in
      checks += 1
      return true
    }
    #expect(checks == 0)
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
  }

  @Test("A stale same-account proof leaves the replacement session alone")
  func rejectedProofIsIgnored() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in false }
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
  }

  @Test("Current terminal expiry changes auth state but retains account data")
  func genuineExpiryPreservesLocalData() async throws {
    let (manager, _, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let handles = [accountA: "fixture-a.test", accountB: "fixture-b.test"]
    defaults.set(try JSONEncoder().encode(handles), forKey: "catbird_account_handles")
    defaults.set("retained", forKey: "fixture-private-data")
    await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in true }
    #expect(manager.state == .unauthenticated)
    #expect(manager.client == nil)
    #expect(manager.isAuthInvalid)
    #expect(manager.expiredAccountInfo?.did == accountA)
    #expect(manager.getStoredHandles() == handles)
    #expect(defaults.string(forKey: "fixture-private-data") == "retained")
    #expect(manager.pendingAuthAlert == nil)
    // This actual handler completes with a client lacking any auth strategy/storage;
    // there is no explicit logout, unregister, or data-cleanup dependency in the path.
  }

  @Test("Deferred target failure is dropped after rollback to A")
  func deferredFailureAfterRollback() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    var checks = 0
    manager.beginDeferringAutoLogout()
    await manager.handleGatewaySessionFailure(did: accountB, reason: "session_expired") { _ in
      checks += 1
      return true
    }
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(checks == 0)
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(checks == 0)
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
  }

  @Test("Deferred current-session failure is reconciled only once")
  func deferredCurrentFailure() async {
    let (manager, _, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    var checks = 0
    manager.beginDeferringAutoLogout()
    await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
      checks += 1
      return true
    }
    #expect(manager.state == .authenticated(userDID: accountA))
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(checks == 1)
    #expect(manager.state == .unauthenticated)
  }

  @Test("A deferred inactive failure cannot overwrite the active account's rejection")
  func deferredFailuresRemainAccountScoped() async {
    let (manager, _, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    manager.beginDeferringAutoLogout()
    await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in true }
    await manager.handleGatewaySessionFailure(did: accountB, reason: "session_expired") { _ in
      Issue.record("Inactive account proof must not be checked against the active client")
      return true
    }
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(manager.state == .unauthenticated)
    #expect(manager.expiredAccountInfo?.did == accountA)
  }

  /// A deterministic actor-hop pause. No sleep or real IO is used to create races.
  @MainActor
  private final class ValidationPause {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Bool, Never>?

    func validate() async -> Bool {
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
      return await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
      releaseWaiter?.resume(returning: true)
      releaseWaiter = nil
    }
  }

  @Test("A switch starting during proof validation invalidates the consumer")
  func switchDuringValidation() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let pause = ValidationPause()
    let consumer = Task { @MainActor in
      await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
        await pause.validate()
      }
    }
    await pause.waitUntilEntered()
    manager.beginDeferringAutoLogout()
    manager.setAuthenticatedForTesting(did: accountB)
    manager.endDeferringAutoLogout()
    pause.release()
    await consumer.value
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(manager.state == .authenticated(userDID: accountB))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
    #expect(manager.expiredAccountInfo == nil)
  }

  @Test("A replaced client survives a queued proof for the same DID")
  func sameAccountReplacementDuringValidation() async {
    let (manager, _, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let replacement = await ATProtoClient(baseURL: URL(string: "https://replacement.invalid")!)
    let pause = ValidationPause()
    let consumer = Task { @MainActor in
      await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
        await pause.validate()
      }
    }
    await pause.waitUntilEntered()
    manager.setClientForTesting(replacement)
    pause.release()
    await consumer.value
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === replacement)
    #expect(!manager.isAuthInvalid)
  }

  @Test("Rollback revalidates a current A rejection deferred during validation")
  func sameAccountRollbackDuringValidation() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let pause = ValidationPause()
    var checks = 0
    let consumer = Task { @MainActor in
      await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
        checks += 1
        if checks == 1 { return await pause.validate() }
        return true
      }
    }
    await pause.waitUntilEntered()
    manager.beginDeferringAutoLogout()
    pause.release()
    await consumer.value
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
    #expect(checks == 1)
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(checks == 2)
    #expect(manager.state == .unauthenticated)
    #expect(manager.expiredAccountInfo?.did == accountA)
    #expect(manager.isAuthInvalid)
  }

  @Test("Rollback discards the old proof when a same-DID credential was replaced")
  func replacementCredentialDuringDeferredValidation() async {
    let (manager, client, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let pause = ValidationPause()
    var checks = 0
    let consumer = Task { @MainActor in
      await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
        checks += 1
        if checks == 1 { return await pause.validate() }
        // The SDK's generation check now sees the new credential in the same client.
        return false
      }
    }
    await pause.waitUntilEntered()
    manager.beginDeferringAutoLogout()
    pause.release()
    await consumer.value
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    #expect(checks == 2)
    #expect(manager.state == .authenticated(userDID: accountA))
    #expect(manager.client === client)
    #expect(!manager.isAuthInvalid)
    #expect(manager.expiredAccountInfo == nil)
  }

  @Test("A switch already reconciled before validation returns still rechecks the proof")
  func rollbackSettlesBeforeValidationReturns() async {
    let (manager, _, defaults, suite) = await fixture()
    defer { defaults.removePersistentDomain(forName: suite) }
    let pause = ValidationPause()
    var checks = 0
    let consumer = Task { @MainActor in
      await manager.handleGatewaySessionFailure(did: accountA, reason: "session_expired") { _ in
        checks += 1
        if checks == 1 { return await pause.validate() }
        return true
      }
    }
    await pause.waitUntilEntered()
    manager.beginDeferringAutoLogout()
    manager.endDeferringAutoLogout()
    await manager.reconcileDeferredGatewaySessionFailure()
    pause.release()
    await consumer.value
    #expect(checks == 2)
    #expect(manager.state == .unauthenticated)
    #expect(manager.expiredAccountInfo?.did == accountA)
  }

  @Test("SDK missing credentials are terminal, ambiguous refresh failures remain retryable")
  func exactSDKErrorClassification() {
    #expect(AppStateManager.isReauthenticationFailure(Petrel.AuthError.noActiveAccount))
    #expect(AppStateManager.isReauthenticationFailure(Petrel.AuthError.invalidCredentials))
    #expect(!AppStateManager.isReauthenticationFailure(Petrel.AuthError.tokenRefreshFailed))
    #expect(!AppStateManager.isReauthenticationFailure(Petrel.AuthError.networkError(URLError(.timedOut))))
    #expect(!AppStateManager.isReauthenticationFailure(Petrel.AuthError.cancelled))
    #expect(!AppStateManager.isReauthenticationFailure(Petrel.AuthError.serverError(503, nil)))
  }

  @Test("A transport failure during switching is not labeled an expired account")
  func failedSwitchDoesNotInventExpiry() async {
    let (manager, client, defaults, suite) = await fixture(overrides: .init(switchAccount: { _, _ in
      throw URLError(.notConnectedToInternet)
    }))
    defer { defaults.removePersistentDomain(forName: suite) }
    manager.beginDeferringAutoLogout()
    defer { manager.endDeferringAutoLogout() }
    do {
      try await manager.switchToAccount(did: accountB)
      Issue.record("Expected the injected transport error")
    } catch {
      #expect((error as? URLError)?.code == .notConnectedToInternet)
    }
    #expect(manager.expiredAccountInfo == nil)
    #expect(!manager.isAuthInvalid)
    #expect(manager.client === client) // Retained for AppStateManager's rollback.
    #expect(!manager.isSwitchingAccount)
  }

  @Test("A rejected switch marks only its target for reauthentication")
  func failedSwitchPreservesTargetIdentity() async {
    let (manager, client, defaults, suite) = await fixture(overrides: .init(switchAccount: { _, _ in
      throw Petrel.AuthError.noActiveAccount
    }))
    defer { defaults.removePersistentDomain(forName: suite) }
    manager.beginDeferringAutoLogout()
    defer { manager.endDeferringAutoLogout() }
    do {
      try await manager.switchToAccount(did: accountB)
      Issue.record("Expected the injected authentication error")
    } catch {
      #expect(AppStateManager.isReauthenticationFailure(error))
    }
    #expect(manager.expiredAccountInfo?.did == accountB)
    #expect(!manager.isAuthInvalid)
    #expect(manager.client === client)
    #expect(!manager.isSwitchingAccount)
  }
}
