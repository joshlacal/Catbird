import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("Gateway OAuth Direct Continuity Tests")
struct GatewayOAuthExchangeTests {
  private let callbackURL = URL(string: "https://catbird.blue/oauth/callback")!
  private let gatewayURL = URL(string: "https://api.catbird.blue")!

  @Test("GatewayOAuthExchange and legacy fragment callbacks are absent from production wiring")
  func legacyCallbackIngestionRemoved() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = testsURL.deletingLastPathComponent().deletingLastPathComponent()
    let sourcePaths = [
      "Catbird/App/CatbirdApp.swift",
      "Catbird/Core/State/AuthManager.swift",
      "Catbird/Features/Auth/Views/LoginView.swift",
      "Catbird/Features/Auth/Views/AccountSwitcherView.swift",
    ]

    let sources = try sourcePaths.map { relativePath in
      try String(
        contentsOf: repositoryURL.appendingPathComponent(relativePath),
        encoding: .utf8
      )
    }

    #expect(sources.allSatisfy { !$0.contains("GatewayOAuthExchange") })
    #expect(sources.allSatisfy { !$0.contains("gatewayOAuthExchange") })
    #expect(sources.allSatisfy { !$0.contains("GatewayOAuthLegacyCallback") })
    #expect(sources.allSatisfy { !$0.contains("callback#session_id") })
    #expect(sources.allSatisfy { !$0.contains("session_id=") })
    #expect(sources.allSatisfy { !$0.contains("internalCallback.fragment") })
    #expect(sources.allSatisfy { !$0.contains("prepareGatewayLogin") })
    #expect(sources.allSatisfy { !$0.contains("redeemGatewayCallback") })
  }

  @Test("auth views clear flow state on every pre-callback exit")
  func authViewPendingAttemptCleanupWiring() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = testsURL.deletingLastPathComponent().deletingLastPathComponent()
    let loginSource = try String(
      contentsOf: repositoryURL.appendingPathComponent("Catbird/Features/Auth/Views/LoginView.swift"),
      encoding: .utf8
    )
    let switcherSource = try String(
      contentsOf: repositoryURL.appendingPathComponent(
        "Catbird/Features/Auth/Views/AccountSwitcherView.swift"),
      encoding: .utf8
    )

    #expect(loginSource.contains("cancelGatewayOAuthFlow()"))
    #expect(switcherSource.contains("cancelGatewayOAuthFlow()"))
  }

  @Test("Shipping gateway login dispatch returns Petrel's bound login URL unchanged without second nonce")
  @MainActor
  func testShippingLoginReturnsPetrelURLUnchanged() async throws {
    let petrelURL = URL(string: "https://api.catbird.blue/auth/login?browser_nonce=test_nonce_32_bytes_unpadded_base64url&redirect_to=https%3A%2F%2Fcatbird.blue%2Foauth%2Fcallback&identifier=alice.test")!

    var capturedOverrides = AuthenticationDependencyOverrides()
    capturedOverrides.startOAuth = { _, _, _, _ in
      return petrelURL
    }

    let authManager = AuthenticationManager(dependencyOverrides: capturedOverrides)
    let dummyClient = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    authManager.setClientForTesting(dummyClient)

    let dispatchedURL = try await authManager.login(handle: "alice.test")

    #expect(dispatchedURL.absoluteString == petrelURL.absoluteString)
    #expect(dispatchedURL.query?.contains("browser_nonce=test_nonce_32_bytes_unpadded_base64url") == true)
  }

  private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    func set(_ url: URL) {
      lock.lock()
      defer { lock.unlock() }
      _url = url
    }
    func get() -> URL? {
      lock.lock()
      defer { lock.unlock() }
      return _url
    }
  }

  @Test("Shipping gateway callback dispatch passes exact Nest callback directly to handleOAuthCallback")
  @MainActor
  func testShippingGatewayCallbackPassesExactURLDirectly() async throws {
    let nestCallback = URL(string: "https://catbird.blue/oauth/callback?code=nest_code_1234567890")!
    let urlBox = URLBox()

    let namespace = "blue.catbird.test.gateway.\(UUID().uuidString)"
    let storage = KeychainStorage(namespace: namespace)
    let testDID = "did:plc:alice12345"
    let testAccount = Account(
      did: testDID,
      handle: "alice.test",
      pdsURL: URL(string: "https://bsky.social")!
    )
    let testSession = Session(
      accessToken: "access-123",
      refreshToken: "refresh-123",
      createdAt: Date(),
      expiresIn: 7200,
      tokenType: .dpop,
      did: testDID
    )
    try await storage.saveAccount(testAccount, for: testDID)
    try await storage.saveSession(testSession, for: testDID)
    try await storage.saveCurrentDID(testDID)

    let client = try await ATProtoClient(
      oauthConfig: OAuthConfig(
        clientId: "test-client",
        redirectUri: "https://catbird.blue/oauth/callback",
        scope: "atproto"
      ),
      namespace: namespace,
      authMode: .gateway,
      gatewayURL: URL(string: "https://api.catbird.blue")!
    )

    var capturedOverrides = AuthenticationDependencyOverrides()
    capturedOverrides.handleOAuthCallback = { activeClient, url in
      urlBox.set(url)
      // Populate stored account on client
      try await activeClient.switchToAccount(did: testDID)
    }

    let authManager = AuthenticationManager(dependencyOverrides: capturedOverrides)
    authManager.setClientForTesting(client)

    try await authManager.handleGatewayCallback(nestCallback)

    let passedURL = urlBox.get()
    #expect(passedURL?.absoluteString == nestCallback.absoluteString)
    #expect(passedURL?.fragment == nil, "Callback passed to Petrel must never have a fragment")
  }

  @Test("Attacker-deliverable error universal link without matching state does not cancel in-flight login")
  @MainActor
  func testAttackerErrorCallbackDoesNotCancelInFlightLogin() async throws {
    let attackerCallback = URL(string: "https://catbird.blue/oauth/callback?error=access_denied")!
    let namespace = "blue.catbird.test.csrf.\(UUID().uuidString)"

    let client = try await ATProtoClient(
      oauthConfig: OAuthConfig(
        clientId: "test-client",
        redirectUri: "https://catbird.blue/oauth/callback",
        scope: "atproto"
      ),
      namespace: namespace,
      authMode: .gateway,
      gatewayURL: URL(string: "https://api.catbird.blue")!
    )

    var cancelCalled = false
    var capturedOverrides = AuthenticationDependencyOverrides()
    capturedOverrides.startOAuth = { _, _, _, _ in
      return URL(string: "https://api.catbird.blue/auth/login?browser_nonce=123")!
    }
    capturedOverrides.handleOAuthCallback = { _, url in
      // When Petrel rejects unmatched error callback
      throw Catbird.AuthError.invalidCallbackURL
    }

    let authManager = AuthenticationManager(dependencyOverrides: capturedOverrides)
    authManager.setClientForTesting(client)

    // Put AuthManager in authenticating state
    authManager.updateState(.authenticating(progress: .waitingForCallback))

    // Handle attacker callback
    do {
      try await authManager.handleGatewayCallback(attackerCallback)
      Issue.record("Expected handleGatewayCallback to throw invalidCallbackURL")
    } catch let error as Catbird.AuthError {
      #expect(error == Catbird.AuthError.invalidCallbackURL)
    }

    // State MUST NOT have been transitioned to error, flow is NOT cancelled
    if case .authenticating = authManager.state {
      // In-flight authentication state preserved
    } else {
      Issue.record("Expected AuthManager state to remain .authenticating, got \(authManager.state)")
    }
  }

  @Test("Error callback with mismatched state does not cancel in-flight flow")
  @MainActor
  func testMismatchedStateErrorCallbackPreservesFlowState() async throws {
    let mismatchedCallback = URL(string: "https://catbird.blue/oauth/callback?error=access_denied&state=attacker_state_token")!
    let namespace = "blue.catbird.test.csrf.mismatch.\(UUID().uuidString)"

    let client = try await ATProtoClient(
      oauthConfig: OAuthConfig(
        clientId: "test-client",
        redirectUri: "https://catbird.blue/oauth/callback",
        scope: "atproto"
      ),
      namespace: namespace,
      authMode: .gateway,
      gatewayURL: URL(string: "https://api.catbird.blue")!
    )

    var capturedOverrides = AuthenticationDependencyOverrides()
    capturedOverrides.handleOAuthCallback = { _, _ in
      throw Catbird.AuthError.invalidCallbackURL
    }

    let authManager = AuthenticationManager(dependencyOverrides: capturedOverrides)
    authManager.setClientForTesting(client)
    authManager.updateState(.authenticating(progress: .waitingForCallback))

    do {
      try await authManager.handleGatewayCallback(mismatchedCallback)
      Issue.record("Expected handleGatewayCallback to throw invalidCallbackURL")
    } catch let error as Catbird.AuthError {
      #expect(error == Catbird.AuthError.invalidCallbackURL)
    }

    // Auth state must remain .authenticating
    if case .authenticating = authManager.state {
      // Success
    } else {
      Issue.record("Expected AuthManager state to remain .authenticating, got \(authManager.state)")
    }
  }
}
