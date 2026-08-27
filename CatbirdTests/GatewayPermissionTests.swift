import AuthenticationServices
import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Gateway Permission Coordinator Tests")
struct GatewayPermissionTests {

  @MainActor
  private func makeIsolatedAuthManager() -> AuthenticationManager {
    let suiteName = "test-auth-\(UUID().uuidString)"
    let isolatedDefaults = UserDefaults(suiteName: suiteName)!
    isolatedDefaults.removePersistentDomain(forName: suiteName)
    return AuthenticationManager(userDefaults: isolatedDefaults)
  }

  @MainActor
  private func makeTestAuthManager(did: String = "did:plc:test1234") async throws -> AuthenticationManager {
    let authManager = makeIsolatedAuthManager()
    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )
    let client = try await ATProtoClient(
      baseURL: URL(string: "https://bsky.social")!,
      oauthConfig: oauthConfig,
      namespace: "blue.catbird.test",
      authMode: .legacy,
      userAgent: "CatbirdTest/1.0"
    )
    authManager.setAuthenticatedForTesting(did: did, client: client)
    return authManager
  }

  @MainActor
  private func stubUpgradeStart(on authManager: AuthenticationManager) {
    authManager.fetchGrantedScopesHook = { _ in
      Set(["atproto"])
    }
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }
  }

  // MARK: - Contract & Enum Verification

  @Test("GatewayPermission enum scopes match exact contractual values")
  func testEnumScopesContract() {
    #expect(GatewayPermission.identityHandle.rawValue == "identity:handle")
    #expect(GatewayPermission.accountEmailManage.rawValue == "account:email?action=manage")
    #expect(GatewayPermission.accountStatusManage.rawValue == "account:status?action=manage")
    #expect(GatewayPermission.identityHandle.scopeString == "identity:handle")
    #expect(GatewayPermission.allCases.count == 3)
    #expect(GatewayPermission.permissionCallbackURL == URL(string: "https://catbird.blue/oauth/permission-callback")!)
  }

  // MARK: - Already Granted Scope

  @Test("Already granted scope skips browser presentation and returns immediately")
  @MainActor
  func testAlreadyGrantedSkipsBrowser() async throws {
    let authManager = try await makeTestAuthManager()

    authManager.fetchGrantedScopesHook = { _ in
      return Set(["identity:handle", "atproto", "transition:generic"])
    }

    var presentCallCount = 0
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      Issue.record("startGatewayScopeUpgrade should not be called when permission is already granted")
      return URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }

    try await authManager.ensureGatewayPermission(.identityHandle) { _ in
      presentCallCount += 1
      return URL(string: "https://catbird.blue/oauth/permission-callback")!
    }

    #expect(presentCallCount == 0, "Browser presentation should be skipped when grant is already present")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  // MARK: - Successful Scope Upgrade

  @Test("Successful progressive scope upgrade completes and preserves authenticated state")
  @MainActor
  func testSuccessfulUpgradeFlow() async throws {
    let authManager = try await makeTestAuthManager()

    authManager.fetchGrantedScopesHook = { _ in
      return Set(["atproto"])
    }

    var startCalled = false
    authManager.startGatewayScopeUpgradeHook = { requesting, did, callbackURL in
      #expect(requesting == Set(["identity:handle"]))
      #expect(did == "did:plc:test1234")
      #expect(callbackURL == GatewayPermission.permissionCallbackURL)
      startCalled = true
      return URL(string: "https://nest.catbird.blue/auth/upgrade?session=123")!
    }

    var presentCalled = false
    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { callbackURL, did in
      #expect(callbackURL == URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!)
      #expect(did == "did:plc:test1234")
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    try await authManager.ensureGatewayPermission(.identityHandle) { authURL in
      #expect(authURL == URL(string: "https://nest.catbird.blue/auth/upgrade?session=123")!)
      presentCalled = true
      return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
    }

    #expect(startCalled)
    #expect(presentCalled)
    #expect(completeCalled)
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  // MARK: - Cancellation

  @Test("Cancellation during presentation throws cancelled and leaves AuthState authenticated")
  @MainActor
  func testCancellationLeavesStateAuthenticated() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    await #expect(throws: GatewayPermissionError.cancelled) {
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        throw CancellationError()
      }
    }

    #expect(!completeCalled, "completeGatewayScopeUpgradeHook must never be called after cancellation")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))

    // Verify in-flight state is cleaned up: subsequent request can run
    authManager.fetchGrantedScopesHook = { _ in
      return Set(["identity:handle"])
    }
    try await authManager.ensureGatewayPermission(.identityHandle) { _ in
      Issue.record("Should not present after granted")
      return URL(string: "https://catbird.blue/oauth/permission-callback")!
    }
  }

  // MARK: - Partial Grant / Scope Denial

  @Test("Partial grant missing the requested scope throws missingGrantedScope and leaves AuthState authenticated")
  @MainActor
  func testPartialGrantThrowsMissingScope() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      // Server returned scopes without the requested identity:handle
      return Set(["atproto", "transition:generic"])
    }

    await #expect(throws: GatewayPermissionError.missingGrantedScope(.identityHandle)) {
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    #expect(completeCalled)
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  // MARK: - DID / State Switch During Flow

  @Test("Account switch or DID change during presentation aborts flow with stateChanged and never calls complete")
  @MainActor
  func testDIDSwitchDuringFlowThrowsStateChanged() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:originalUser")

    stubUpgradeStart(on: authManager)

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    await #expect(throws: GatewayPermissionError.stateChanged) {
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        // Simulate user switching accounts while browser sheet was open
        authManager.updateState(.authenticated(userDID: "did:plc:switchedUser"))
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    #expect(!completeCalled, "completeGatewayScopeUpgradeHook must never be called after DID/account continuity loss")
    // State is now the switched user
    #expect(authManager.state == .authenticated(userDID: "did:plc:switchedUser"))
  }

  // MARK: - Concurrency: Coalescing & Conflicting Requests

  @Test("Concurrent requests for the same scope coalesce onto a single in-flight task")
  @MainActor
  func testConcurrencyCoalescesSameScope() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var startCallCount = 0
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      startCallCount += 1
      return URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }

    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      return Set(["identity:handle", "atproto"])
    }

    let enteredPresentation = AsyncBarrier()
    let releasePresentation = AsyncBarrier()

    async let firstCall: Void = authManager.ensureGatewayPermission(.identityHandle) { _ in
      await enteredPresentation.signal()
      await releasePresentation.waitForSignal()
      return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
    }

    // Wait until firstCall has entered presentation and is registered in-flight
    await enteredPresentation.waitForSignal()

    async let secondCall: Void = authManager.ensureGatewayPermission(.identityHandle) { _ in
      Issue.record("Second coalesced request should not call present separately")
      return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
    }

    // Release presentation barrier to allow firstCall and secondCall to finish
    await releasePresentation.signal()

    // Both calls must succeed
    try await firstCall
    try await secondCall

    #expect(startCallCount == 1, "startGatewayScopeUpgrade should only be called once when coalesced")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  @Test("Cancelling a coalesced waiter throws cancelled on waiter without cancelling owner task")
  @MainActor
  func testConcurrencyCoalescedWaiterCancellationDoesNotCancelOwner() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var startCallCount = 0
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      startCallCount += 1
      return URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    let enteredPresentation = AsyncBarrier()
    let releasePresentation = AsyncBarrier()

    let ownerTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        await enteredPresentation.signal()
        await releasePresentation.waitForSignal()
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    // Wait until owner is in presentation and registered in-flight
    await enteredPresentation.waitForSignal()

    var waiterPresentationCalled = false
    let waiterTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        waiterPresentationCalled = true
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    // Give waiter a chance to register/await coalesced task
    await Task.yield()

    // Cancel the waiter task while owner is still suspended in presentation
    waiterTask.cancel()

    // Waiter must fail promptly with GatewayPermissionError.cancelled
    await #expect(throws: GatewayPermissionError.cancelled) {
      try await waiterTask.value
    }
    #expect(!waiterPresentationCalled, "Waiter must not call present")

    // Now release presentation so the owner flow continues and finishes
    await releasePresentation.signal()

    // Owner must succeed despite waiter cancellation
    try await ownerTask.value

    #expect(completeCalled, "Owner must successfully complete the upgrade")
    #expect(startCallCount == 1, "startGatewayScopeUpgrade must be called only once")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  @Test("Concurrent request for a different scope while another is in-flight is rejected with alreadyInProgress")
  @MainActor
  func testConcurrencyRejectsConflictingScope() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      return Set(["identity:handle", "atproto"])
    }

    let enteredPresentation = AsyncBarrier()
    let releasePresentation = AsyncBarrier()

    async let firstCall: Void = authManager.ensureGatewayPermission(.identityHandle) { _ in
      await enteredPresentation.signal()
      await releasePresentation.waitForSignal()
      return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
    }

    // Wait until firstCall has entered presentation and is registered in-flight
    await enteredPresentation.waitForSignal()

    // Conflicting request for accountEmailManage while identityHandle is in flight
    await #expect(throws: GatewayPermissionError.alreadyInProgress) {
      try await authManager.ensureGatewayPermission(.accountEmailManage) { _ in
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    await releasePresentation.signal()
    try await firstCall
  }

  // MARK: - Cleanup & Lifecycle

  @Test("Calling cancelInFlightPermissionUpgrade cancels in-flight task")
  @MainActor
  func testExplicitCancelCleansUp() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    let enteredPresentation = AsyncBarrier()
    let releasePresentation = AsyncBarrier()

    let upgradeTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        await enteredPresentation.signal()
        await releasePresentation.waitForSignal()
        try Task.checkCancellation()
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    // Wait until presentation is active
    await enteredPresentation.waitForSignal()

    // Explicitly cancel in flight upgrade
    authManager.cancelInFlightPermissionUpgrade()
    await releasePresentation.signal()

    await #expect(throws: GatewayPermissionError.cancelled) {
      try await upgradeTask.value
    }

    #expect(!completeCalled, "completeGatewayScopeUpgradeHook must not be called after cancellation")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  @Test("Calling logout cancels in-flight permission and transitions state to unauthenticated")
  @MainActor
  func testLogoutCancelsInFlightPermission() async throws {
    let authManager = try await makeTestAuthManager()

    stubUpgradeStart(on: authManager)

    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Set(["identity:handle", "atproto"])
    }

    let enteredPresentation = AsyncBarrier()
    let releasePresentation = AsyncBarrier()

    let upgradeTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        await enteredPresentation.signal()
        await releasePresentation.waitForSignal()
        try Task.checkCancellation()
        return URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
      }
    }

    // Wait until presentation is active
    await enteredPresentation.waitForSignal()

    await authManager.logout(isManual: true)
    await releasePresentation.signal()

    await #expect(throws: GatewayPermissionError.cancelled) {
      try await upgradeTask.value
    }

    #expect(!completeCalled, "completeGatewayScopeUpgradeHook must never be called after logout")
    #expect(authManager.state == .unauthenticated)
  }

  @Test("Calling ensureGatewayPermission while unauthenticated throws unauthenticated error")
  @MainActor
  func testUnauthenticatedThrows() async throws {
    let authManager = try await makeTestAuthManager()
    authManager.updateState(.unauthenticated)

    await #expect(throws: GatewayPermissionError.unauthenticated) {
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        return URL(string: "https://catbird.blue/oauth/permission-callback")!
      }
    }
  }

  // MARK: - Late Non-Cooperative Flow Cancellation & Race Resilience

  @Test("Late non-cooperative flow A canceled, flow B starts, A resumes: B remains registered and A never completes callback")
  @MainActor
  func testLateNonCooperativeFlowRace() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:test1234")

    stubUpgradeStart(on: authManager)

    var flowACompleteCalled = false
    var flowBCompleteCalled = false
    authManager.completeGatewayScopeUpgradeHook = { callbackURL, did in
      if callbackURL.query?.contains("flow=A") == true {
        flowACompleteCalled = true
        return Set(["identity:handle", "atproto"])
      } else if callbackURL.query?.contains("flow=B") == true {
        flowBCompleteCalled = true
        return Set(["account:email?action=manage", "atproto"])
      }
      return Set(["atproto"])
    }

    let flowAEnteredPresent = AsyncBarrier()
    let flowARelease = AsyncBarrier()
    let flowBEnteredPresent = AsyncBarrier()
    let flowBRelease = AsyncBarrier()

    // 1. Launch Flow A
    let flowATask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        await flowAEnteredPresent.signal()
        await flowARelease.waitForSignal()
        // Non-cooperative presentation: does not throw CancellationError, returns URL
        return URL(string: "https://catbird.blue/oauth/permission-callback?flow=A")!
      }
    }

    // 2. Wait until Flow A has started and entered presentation
    await flowAEnteredPresent.waitForSignal()

    // 3. Cancel Flow A
    authManager.cancelInFlightPermissionUpgrade()

    // 4. Start Flow B
    let flowBTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.accountEmailManage) { _ in
        await flowBEnteredPresent.signal()
        await flowBRelease.waitForSignal()
        return URL(string: "https://catbird.blue/oauth/permission-callback?flow=B")!
      }
    }

    // 5. Wait until Flow B has entered presentation and registered as the active in-flight upgrade
    await flowBEnteredPresent.waitForSignal()

    // 6. Resume late non-cooperative Flow A
    await flowARelease.signal()

    // Flow A should fail with cancellation or state change error
    await #expect(throws: GatewayPermissionError.cancelled) {
      try await flowATask.value
    }

    #expect(!flowACompleteCalled, "Flow A must never invoke completeGatewayScopeUpgradeHook")

    // 7. Resume and complete Flow B
    await flowBRelease.signal()
    try await flowBTask.value

    #expect(flowBCompleteCalled, "Flow B must complete successfully")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  @Test("Caller cancellation clears in-flight entry so flow B can start before non-cooperative flow A resumes")
  @MainActor
  func testCallerCancelThenBStartsBeforeAResumes() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:test1234")

    stubUpgradeStart(on: authManager)

    var flowACompleteCalled = false
    var flowBCompleteCalled = false
    authManager.completeGatewayScopeUpgradeHook = { callbackURL, did in
      if callbackURL.query?.contains("flow=A") == true {
        flowACompleteCalled = true
        return Set(["identity:handle", "atproto"])
      } else if callbackURL.query?.contains("flow=B") == true {
        flowBCompleteCalled = true
        return Set(["account:email?action=manage", "atproto"])
      }
      return Set(["atproto"])
    }

    let flowAEnteredPresent = AsyncBarrier()
    let flowARelease = AsyncBarrier()
    let flowBEnteredPresent = AsyncBarrier()
    let flowBRelease = AsyncBarrier()

    // 1. Launch Flow A in a caller Task
    let flowATask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.identityHandle) { _ in
        await flowAEnteredPresent.signal()
        await flowARelease.waitForSignal()
        // Non-cooperative presentation: does not throw CancellationError, returns URL
        return URL(string: "https://catbird.blue/oauth/permission-callback?flow=A")!
      }
    }

    // 2. Wait until Flow A has started and entered presentation
    await flowAEnteredPresent.waitForSignal()

    // 3. Cancel Flow A via parent task cancellation
    flowATask.cancel()

    // 4. Start Flow B immediately before Flow A resumes
    let flowBTask = Task { @MainActor in
      try await authManager.ensureGatewayPermission(.accountEmailManage) { _ in
        await flowBEnteredPresent.signal()
        await flowBRelease.waitForSignal()
        return URL(string: "https://catbird.blue/oauth/permission-callback?flow=B")!
      }
    }

    // 5. Wait deterministically until Flow B has entered presentation and registered as active in-flight upgrade
    await flowBEnteredPresent.waitForSignal()
    #expect(!flowACompleteCalled, "Flow B must start immediately while Flow A is still suspended in presentation")

    // 6. Resume and complete Flow B while Flow A remains paused
    await flowBRelease.signal()
    try await flowBTask.value

    #expect(flowBCompleteCalled, "Flow B must complete successfully while Flow A is still paused")
    #expect(!flowACompleteCalled, "Flow A must not have completed")

    // 7. Resume late non-cooperative Flow A
    await flowARelease.signal()
    // Flow A should fail with cancellation error
    await #expect(throws: GatewayPermissionError.cancelled) {
      try await flowATask.value
    }

    #expect(!flowACompleteCalled, "Flow A must never invoke completeGatewayScopeUpgradeHook")
    #expect(authManager.state == .authenticated(userDID: "did:plc:test1234"))
  }

  // MARK: - Handle Transition Tests

  @Test("recordCurrentHandleChange throws when unauthenticated or DID mismatches expected DID")
  @MainActor
  func testRecordCurrentHandleChangeWrongDIDThrows() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:alice123")

    // Mismatched expected DID while authenticated as did:plc:alice123
    #expect(throws: AuthError.invalidSession) {
      try authManager.recordCurrentHandleChange("alice-new.bsky.social", for: "did:plc:bob456")
    }

    // Empty expected DID
    #expect(throws: AuthError.invalidSession) {
      try authManager.recordCurrentHandleChange("alice-new.bsky.social", for: "")
    }

    // Unauthenticated state
    authManager.updateState(.unauthenticated)
    #expect(throws: AuthError.invalidSession) {
      try authManager.recordCurrentHandleChange("alice-new.bsky.social", for: "did:plc:alice123")
    }
  }

  @Test("recordCurrentHandleChange throws clientNotInitialized when client is missing")
  @MainActor
  func testRecordCurrentHandleChangeClientNotInitializedThrows() async throws {
    let authManager = makeIsolatedAuthManager()
    authManager.updateState(.authenticated(userDID: "did:plc:alice123"))

    #expect(throws: AuthError.clientNotInitialized) {
      try authManager.recordCurrentHandleChange("alice.bsky.social", for: "did:plc:alice123")
    }
  }

  @Test("recordCurrentHandleChange throws invalidHandle for invalid, empty, or DID-like handles")
  @MainActor
  func testRecordCurrentHandleChangeInvalidHandleThrows() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:alice123")

    let invalidHandles = [
      "",
      "   ",
      "\n\t",
      "did:plc:something",
      "did:web:example.com",
      "DID:PLC:UPPERCASE",
      "@",
      "@   ",
      "@did:plc:alice123",
      // Single label (no dot)
      "alice",
      "@alice",
      "localhost",
      "invalid_handle",
      // Invalid characters
      "alice!@#.bsky.social",
      "alice bsky.social",
      "alice/bsky.social",
      "alice$bsky.social",
      // Leading / trailing dashes in labels
      "-alice.bsky.social",
      "alice-.bsky.social",
      "alice.-bsky.social",
      "alice.bsky-.social",
      // Empty labels / double dots
      "alice..bsky.social",
      ".alice.bsky.social",
      "alice.bsky.social.",
      // TLD starting with a digit
      "alice.123",
      "test.0",
      // Overly long handle or label
      String(repeating: "a", count: 254) + ".com",
      String(repeating: "a", count: 64) + ".bsky.social",
    ]

    for invalidHandle in invalidHandles {
      #expect(throws: AuthError.invalidHandle) {
        try authManager.recordCurrentHandleChange(invalidHandle, for: "did:plc:alice123")
      }
    }
  }

  @Test("recordCurrentHandleChange successfully updates current handle, persistent storage, and preserves DID/AppState")
  @MainActor
  func testRecordCurrentHandleChangeSuccessfulStorageAndCurrentValue() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:alice123")

    // Initially record an initial handle
    try authManager.recordCurrentHandleChange("alice.bsky.social", for: "did:plc:alice123")
    #expect(authManager.handle == "alice.bsky.social")
    #expect(authManager.getStoredHandle(for: "did:plc:alice123") == "alice.bsky.social")
    #expect(authManager.state == .authenticated(userDID: "did:plc:alice123"))

    // Transition to a new handle (with @ prefix and uppercase characters to verify canonicalization)
    try authManager.recordCurrentHandleChange("  @Alice-Updated.Bsky.Social  ", for: "did:plc:alice123")

    // Verify current in-memory handle is canonicalized
    #expect(authManager.handle == "alice-updated.bsky.social")

    // Verify persistent storage is updated
    #expect(authManager.getStoredHandle(for: "did:plc:alice123") == "alice-updated.bsky.social")

    // Verify auth state / DID is unchanged
    #expect(authManager.state == .authenticated(userDID: "did:plc:alice123"))

    // Verify cached profile data was updated
    let profile = authManager.getCachedProfileData(for: "did:plc:alice123")
    #expect(profile?.handle == "alice-updated.bsky.social")
  }

  @Test("recordCurrentHandleChange does not mutate other accounts in storage or order")
  @MainActor
  func testRecordCurrentHandleChangeNoOtherAccountMutation() async throws {
    let authManager = try await makeTestAuthManager(did: "did:plc:alice123")

    // Setup multiple accounts in storage
    authManager.storeHandle("alice.bsky.social", for: "did:plc:alice123")
    authManager.storeHandle("bob.bsky.social", for: "did:plc:bob456")
    authManager.storeHandle("carol.bsky.social", for: "did:plc:carol789")
    authManager.updateAccountOrder(["did:plc:alice123", "did:plc:bob456", "did:plc:carol789"])

    // Update Alice's handle
    try authManager.recordCurrentHandleChange("alice-new.bsky.social", for: "did:plc:alice123")

    // Alice should be updated
    #expect(authManager.handle == "alice-new.bsky.social")
    #expect(authManager.getStoredHandle(for: "did:plc:alice123") == "alice-new.bsky.social")

    // Bob and Carol must remain completely unmutated
    #expect(authManager.getStoredHandle(for: "did:plc:bob456") == "bob.bsky.social")
    #expect(authManager.getStoredHandle(for: "did:plc:carol789") == "carol.bsky.social")

    let stored = authManager.getStoredHandles()
    #expect(stored["did:plc:alice123"] == "alice-new.bsky.social")
    #expect(stored["did:plc:bob456"] == "bob.bsky.social")
    #expect(stored["did:plc:carol789"] == "carol.bsky.social")
    #expect(stored.count == 3)
  }
}

// MARK: - Test Helpers

/// A thread-safe async barrier for coordinating test execution order deterministically.
private actor AsyncBarrier {
  private var isSignaled = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func signal() {
    isSignaled = true
    for continuation in continuations {
      continuation.resume()
    }
    continuations.removeAll()
  }

  func waitForSignal() async {
    if isSignaled { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}
