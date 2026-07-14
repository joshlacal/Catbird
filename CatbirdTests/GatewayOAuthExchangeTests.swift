import Foundation
import Testing

@testable import Catbird

@Suite("Temporary gateway OAuth legacy callback compatibility")
struct GatewayOAuthExchangeTests {
  private let callbackURL = URL(string: "https://catbird.blue/oauth/callback")!
  private let loginURL = URL(string: "https://api.catbird.blue/auth/login?identifier=alice.test")!
  private let sessionID = "550e8400-e29b-41d4-a716-446655440000"

  @Test("authentication manager activates only legacy compatibility")
  func authenticationManagerWiring() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let sourceURL = testsURL.deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Catbird/Core/State/AuthManager.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("GatewayOAuthLegacyCallback("))
    let consume = try #require(source.range(of: "gatewayOAuthLegacyCallback.consume(url)"))
    let handoff = try #require(source.range(of: "internalCallback.fragment = \"session_id=\\(sessionID)\""))
    #expect(consume.lowerBound < handoff.lowerBound)
    #expect(!source.contains("gatewayOAuthExchange.redeem(url)"))
    #expect(!source.contains("GatewayOAuthExchange("))
  }

  @Test("login URL remains unchanged and an exact legacy callback succeeds once")
  func validLegacyCallback() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    #expect(try await callback.prepareLogin(loginURL) == loginURL)

    let result = try await callback.consume(
      URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!)
    #expect(result == sessionID)

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!)
    }
  }

  @Test("callback requires an active unexpired login attempt")
  func attemptRequiredAndExpiring() async throws {
    let clock = TestUptime()
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL, uptime: { clock.value })
    let validURL = URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(validURL)
    }
    _ = try await callback.prepareLogin(loginURL)
    clock.value = 60.001
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(validURL)
    }
  }

  @Test("callback URL and session ID validation fail closed")
  func invalidCallbacks() async throws {
    let invalidURLs = [
      "http://catbird.blue/oauth/callback#session_id=\(sessionID)",
      "https://catbird.blue.evil.example/oauth/callback#session_id=\(sessionID)",
      "https://catbird.blue@evil.example/oauth/callback#session_id=\(sessionID)",
      "https://user@catbird.blue/oauth/callback#session_id=\(sessionID)",
      "https://catbird.blue:444/oauth/callback#session_id=\(sessionID)",
      "https://catbird.blue/oauth/other#session_id=\(sessionID)",
      "https://catbird.blue/oauth/callback?session_id=\(sessionID)",
      "https://catbird.blue/oauth/callback?next=%2F#session_id=\(sessionID)",
      "https://catbird.blue/oauth/callback#session_id=\(sessionID)&extra=value",
      "https://catbird.blue/oauth/callback#extra=value&session_id=\(sessionID)",
      "https://catbird.blue/oauth/callback#session_id=",
      "https://catbird.blue/oauth/callback#session_id=a%26b",
      "https://catbird.blue/oauth/callback#session_id=a%25b",
      "https://catbird.blue/oauth/callback#session_id=a=b",
      "https://catbird.blue/oauth/callback#session_id=550E8400-E29B-41D4-A716-446655440000",
      "https://catbird.blue/oauth/callback#session_id=550e8400e29b41d4a716446655440000",
      "https://catbird.blue/oauth/callback#session_id=550e8400-e29b-41d4-a716-44665544000",
      "https://catbird.blue/oauth/callback#session_id=550e8400-e29b-41d4-a716-4466554400000",
    ]

    for rawURL in invalidURLs {
      let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
      _ = try await callback.prepareLogin(loginURL)
      await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized, "\(rawURL)") {
        try await callback.consume(URL(string: rawURL)!)
      }
    }

    let oversized = String(repeating: "a", count: 513)
    let oversizedURL = try #require(
      legacyCallbackURL(sessionIDFragmentValue: oversized))
    let oversizedCallback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await oversizedCallback.prepareLogin(loginURL)
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await oversizedCallback.consume(oversizedURL)
    }

  }

  @Test("callback path must be the literal percent-encoded path")
  func encodedCallbackPathIsRejected() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await callback.prepareLogin(loginURL)

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://catbird.blue/oauth/%63allback#session_id=\(sessionID)")!)
    }
  }

  @Test("a canonical lowercase hyphenated UUID session ID is preserved")
  func canonicalUUIDSessionID() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await callback.prepareLogin(loginURL)
    let callbackURL = try #require(legacyCallbackURL(sessionIDFragmentValue: sessionID))
    #expect(try await callback.consume(callbackURL) == sessionID)
  }

  @Test("fragment field name must be literal")
  func rawFragmentFieldName() async throws {
    let encodedNameCallback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await encodedNameCallback.prepareLogin(loginURL)
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await encodedNameCallback.consume(
        URL(string: "https://catbird.blue/oauth/callback#session%5Fid=\(sessionID)")!)
    }

  }

  @Test("auth views clear a prepared legacy attempt on every pre-callback exit")
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

    #expect(loginSource.contains("private func cancelAuthenticationTaskAndPendingAttempt()"))
    #expect(loginSource.contains("await cancelPendingAttemptBeforeCallback()"))
    #expect(
      loginSource.contains(
        ".onDisappear {\n            if !isLoggingIn {\n                cancelAuthenticationTaskAndPendingAttempt()"
      )
    )
    #expect(!loginSource.contains(".onDisappear {\n            cancelAuthenticationTaskAndPendingAttempt()"))
    let cancelAction = try #require(
      loginSource.range(of: "private func cancelAuthentication()")
    )
    let timeoutAction = try #require(
      loginSource.range(of: "private func startTimeoutCountdown()")
    )
    #expect(
      loginSource[cancelAction.lowerBound..<timeoutAction.lowerBound]
        .contains("cancelAuthenticationTaskAndPendingAttempt()")
    )
    #expect(switcherSource.contains("private func cancelAuthenticationTaskAndPendingAttempt()"))
    #expect(switcherSource.contains("await cancelPendingAttemptBeforeCallback()"))
    #expect(switcherSource.contains(".onDisappear(perform: cancelAuthenticationTaskAndPendingAttempt)"))
    #expect(
      switcherSource.contains(
        "Button(\"Cancel\", systemImage: \"xmark\") {\n            cancelAuthenticationTaskAndPendingAttempt()\n            isAddingAccount = false"
      )
    )
  }

  @Test("omitted and explicit default HTTPS ports are equivalent")
  func defaultHTTPSPortNormalization() async throws {
    for (configured, received) in [
      (
        "https://catbird.blue/oauth/callback",
        "https://catbird.blue:443/oauth/callback#session_id=\(sessionID)"
      ),
      (
        "https://catbird.blue:443/oauth/callback",
        "https://catbird.blue/oauth/callback#session_id=\(sessionID)"
      ),
    ] {
      let callback = GatewayOAuthLegacyCallback(callbackURL: URL(string: configured)!)
      _ = try await callback.prepareLogin(loginURL)
      #expect(try await callback.consume(URL(string: received)!) == sessionID)
    }
  }

  @Test("a malformed callback consumes the pending attempt")
  func malformedCallbackConsumesAttempt() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await callback.prepareLogin(loginURL)

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://evil.example/oauth/callback#session_id=\(sessionID)")!)
    }
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!)
    }
  }

  @Test("a live attempt blocks replacement and cancellation clears it")
  func overlappingAndCancelledAttempts() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    _ = try await callback.prepareLogin(loginURL)

    await #expect(throws: GatewayOAuthLegacyCallbackError.flowInProgress) {
      try await callback.prepareLogin(loginURL)
    }

    await callback.cancelPendingLogin()
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!)
    }
    #expect(try await callback.prepareLogin(loginURL) == loginURL)
  }

  @Test("invalid configured callbacks fail without creating an attempt")
  func invalidConfiguration() async throws {
    let invalidConfiguredCallbacks = [
      "http://catbird.blue/oauth/callback",
      "https://evil.example/oauth/callback",
      "https://catbird.blue.evil.example/oauth/callback",
      "https://user@catbird.blue/oauth/callback",
      "https://user:password@catbird.blue/oauth/callback",
      "https://catbird.blue/oauth/callback?next=%2F",
      "https://catbird.blue/oauth/callback#session_id=configured",
      "https://catbird.blue/oauth/other",
      "https://catbird.blue:444/oauth/callback",
    ]
    let validURL = URL(string: "https://catbird.blue/oauth/callback#session_id=\(sessionID)")!

    for rawURL in invalidConfiguredCallbacks {
      let callback = GatewayOAuthLegacyCallback(callbackURL: URL(string: rawURL)!)
      await #expect(throws: GatewayOAuthLegacyCallbackError.configuration, "\(rawURL)") {
        try await callback.prepareLogin(loginURL)
      }
      await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized, "\(rawURL)") {
        try await callback.consume(validURL)
      }
    }
  }

  private func legacyCallbackURL(sessionIDFragmentValue: String) -> URL? {
    var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    components?.fragment = "session_id=\(sessionIDFragmentValue)"
    return components?.url
  }
}

private final class TestUptime: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: TimeInterval = 0

  var value: TimeInterval {
    get { lock.withLock { storedValue } }
    set { lock.withLock { storedValue = newValue } }
  }
}
