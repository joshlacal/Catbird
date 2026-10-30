import Foundation
import Testing
@testable import Catbird
@testable import Petrel

/// Synthetic accounts in unique keychain namespaces. No gateway or provider requests.
@Suite("Gateway session rejection UI continuity")
struct GatewaySessionRejectionTests {
  private struct Fixture {
    let manager: AuthenticationManager
    let client: ATProtoClient
    let storage: KeychainStorage
    let proof: GatewaySessionFailureContext
  }

  private let did = "did:plc:syntheticgatewayrejection"
  private let replacementSession = "synthetic-replacement-session"

  @Test("Anonymous and inactive-account legacy logout events preserve the active session")
  @MainActor
  func unrelatedLegacyLogoutPreservesActiveSession() async throws {
    try await withFixture { fixture in
      for eventDID: String? in [nil, "", "did:plc:otheraccount"] {
        await fixture.manager.handleAutoLogoutFromPetrel(did: eventDID, reason: "401_no_auth_provider_or_url")
        #expect(fixture.manager.state.userDID == self.did)
        #expect(fixture.manager.client === fixture.client)
        #expect(!fixture.manager.isAuthInvalid)
        #expect(fixture.manager.expiredAccountInfo == nil)
      }

      // Ignored events must not arm the debounce flag and swallow a real expiration.
      await fixture.manager.handleAutoLogoutFromPetrel(did: self.did, reason: "invalid_grant")
      #expect(fixture.manager.state.userDID == nil)
      #expect(fixture.manager.client == nil)
      #expect(fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo?.did == self.did)
    }
  }

  @MainActor
  private func withFixture(_ operation: (Fixture) async throws -> Void) async throws {
    let namespace = "blue.catbird.test.gateway-rejection.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: namespace))
    defer {
      defaults.removePersistentDomain(forName: namespace)
      #expect(KeychainManager.nukeAllKeychainItems(forNamespace: namespace))
    }
    let storage = KeychainStorage(namespace: namespace)
    try await storage.saveAccount(
      Account(did: did, handle: "synthetic.example", pdsURL: URL(string: "https://provider.example")!),
      for: did
    )
    try await storage.saveGatewaySession("synthetic-rejected-session", for: did)
    try await storage.saveCurrentDID(did)
    let client = try await ATProtoClient(
      oauthConfig: OAuthConfiguration(
        clientId: "https://client.example/client-metadata.json",
        redirectUri: "https://client.example/oauth/callback", scope: "atproto"
      ),
      namespace: namespace,
      authMode: .gateway,
      gatewayURL: URL(string: "https://gateway.example")!
    )
    var overrides = AuthenticationDependencyOverrides()
    overrides.handleOAuthCallback = { _, _ in
      try await storage.saveGatewaySession(self.replacementSession, for: self.did)
    }
    let manager = AuthenticationManager(userDefaults: defaults, dependencyOverrides: overrides)
    manager.setAuthenticatedForTesting(did: did, client: client)
    // Obtain real SDK proof from its guarded mutation path; never construct a proof by hand.
    let recordedProof = try await storage.recordGatewaySessionFailure(
      ifMatches: "synthetic-rejected-session", for: did, deleteMatchingSession: false
    )
    let proof = try #require(recordedProof)
    try await operation(Fixture(manager: manager, client: client, storage: storage, proof: proof))
  }

  @MainActor
  private func pauseValidation(on fixture: Fixture) -> (
    task: Task<Void, Never>, validated: RejectionTestSignal, deliver: RejectionTestSignal
  ) {
    let validated = RejectionTestSignal()
    let deliver = RejectionTestSignal()
    fixture.manager.gatewaySessionFailureValidationDeliveryHook = { result in
      #expect(result, "The SDK must validate the original session before replacement")
      await validated.signal()
      await deliver.wait()
    }
    let task = Task { @MainActor in
      await fixture.manager.handleGatewaySessionRejection(fixture.proof)
    }
    return (task, validated, deliver)
  }

  @Test("Completed same-DID permission promotion survives a queued valid rejection", arguments: [false, true])
  @MainActor
  func permissionPromotionSurvivesDelayedValidation(partialGrant: Bool) async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      fixture.manager.fetchGrantedScopesHook = { _ in ["atproto"] }
      fixture.manager.startGatewayScopeUpgradeHook = { _, _, _ in
        URL(string: "https://gateway.example/auth/upgrade")!
      }
      fixture.manager.completeGatewayScopeUpgradeHook = { _, expectedDID in
        #expect(expectedDID == self.did)
        try await fixture.storage.saveGatewaySession(self.replacementSession, for: expectedDID)
        return partialGrant ? ["atproto"] : ["atproto", GatewayPermission.circleSpaces.rawValue]
      }
      do {
        try await fixture.manager.ensureGatewayPermission(.circleSpaces) { _ in
          GatewayPermission.permissionCallbackURL
        }
        #expect(!partialGrant)
      } catch {
        #expect(partialGrant)
        #expect(error as? GatewayPermissionError == .missingGrantedScope(.circleSpaces))
      }
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo == nil)
      let storedSession = try await fixture.storage.getGatewaySession(for: did)
      #expect(storedSession == replacementSession)
    }
  }

  @Test("Completed same-DID gateway callback survives a queued valid rejection")
  @MainActor
  func gatewayCallbackSurvivesDelayedValidation() async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      do {
        try await fixture.manager.handleGatewayCallback(URL(string: "https://client.example/oauth/callback?code=synthetic")!)
      } catch {
        // Always release the deterministic barrier, including a failed fixture setup.
        await pending.deliver.signal()
        await pending.task.value
        throw error
      }
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo == nil)
      let storedSession = try await fixture.storage.getGatewaySession(for: did)
      #expect(storedSession == replacementSession)
    }
  }

  @Test("Auth state round trip invalidates a previously validated rejection")
  @MainActor
  func authStateRoundTripSurvivesDelayedValidation() async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      fixture.manager.updateState(.authenticating(progress: .exchangingTokens))
      fixture.manager.updateState(.authenticated(userDID: did))
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
    }
  }

  @Test("Replacing and restoring the same client invalidates a queued rejection")
  @MainActor
  func clientRoundTripSurvivesDelayedValidation() async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      fixture.manager.setClientForTesting(nil)
      fixture.manager.setClientForTesting(fixture.client)
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
    }
  }

  @Test("Another account survives a queued valid rejection")
  @MainActor
  func differentAccountSurvivesDelayedValidation() async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      let otherDID = "did:plc:syntheticotheraccount"
      do {
        try await fixture.storage.saveCurrentDID(otherDID)
      } catch {
        await pending.deliver.signal()
        await pending.task.value
        throw error
      }
      fixture.manager.updateState(.authenticated(userDID: otherDID))
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: otherDID))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo == nil)
    }
  }

  @Test("An SDK-invalidated rejection cannot change the active UI session")
  @MainActor
  func invalidProofCannotLogOut() async throws {
    try await withFixture { fixture in
      try await fixture.storage.saveGatewaySession(replacementSession, for: did)
      var receivedResult: Bool?
      fixture.manager.gatewaySessionFailureValidationDeliveryHook = { result in
        receivedResult = result
      }
      await fixture.manager.handleGatewaySessionRejection(fixture.proof)

      #expect(receivedResult == false)
      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo == nil)
    }
  }

  @Test("SDK candidate promotion without a UI revision survives a queued valid rejection")
  @MainActor
  func sdkCandidatePromotionSurvivesDelayedValidation() async throws {
    try await withFixture { fixture in
      let pending = pauseValidation(on: fixture)
      await pending.validated.wait()
      do {
        // This is the SDK's candidate-promotion primitive. No AuthManager state,
        // client, or revision changes, so only the atomic SDK check can protect it.
        let promoted = try await fixture.storage.compareAndSwapGatewaySession(
          expectedOldSession: "synthetic-rejected-session",
          newSession: replacementSession, for: did
        )
        #expect(promoted)
      } catch {
        await pending.deliver.signal()
        await pending.task.value
        throw error
      }
      await pending.deliver.signal()
      await pending.task.value

      #expect(fixture.manager.state == .authenticated(userDID: did))
      #expect(fixture.manager.client === fixture.client)
      #expect(!fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo == nil)
      let storedSession = try await fixture.storage.getGatewaySession(for: did)
      #expect(storedSession == replacementSession)
    }
  }

  @Test("An unchanged current rejection still expires the active UI session")
  @MainActor
  func currentProofExpiresSession() async throws {
    try await withFixture { fixture in
      await fixture.manager.handleGatewaySessionRejection(fixture.proof)

      #expect(fixture.manager.state == .unauthenticated)
      #expect(fixture.manager.client == nil)
      #expect(fixture.manager.isAuthInvalid)
      #expect(fixture.manager.expiredAccountInfo?.did == did)
    }
  }
}

private actor RejectionTestSignal {
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    signaled = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func wait() async {
    if signaled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
