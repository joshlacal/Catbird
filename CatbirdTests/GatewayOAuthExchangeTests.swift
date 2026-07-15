import Foundation
import Testing

@testable import Catbird

@Suite("Gateway OAuth single-use exchange")
struct GatewayOAuthExchangeTests {
  private let callbackURL = URL(string: "https://catbird.blue/oauth/callback")!
  private let gatewayURL = URL(string: "https://api.catbird.blue")!

  @Test("legacy URL callback ingestion is absent from production wiring")
  func legacyCallbackIngestionRemoved() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = testsURL.deletingLastPathComponent().deletingLastPathComponent()
    let sourcePaths = [
      "Catbird/App/CatbirdApp.swift",
      "Catbird/Core/Networking/GatewayOAuthExchange.swift",
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

    #expect(sources.allSatisfy { !$0.contains("GatewayOAuthLegacyCallback") })
    #expect(sources.allSatisfy { !$0.contains("gatewayOAuthLegacyCallback") })
    #expect(sources.allSatisfy { !$0.contains("callback#session_id") })
    #expect(sources.allSatisfy { !$0.contains("consume(url)") })
    #expect(sources.joined().contains("gatewayOAuthExchange.redeem(url)"))
  }

  @Test("auth views clear a prepared exchange attempt on every pre-callback exit")
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
    #expect(switcherSource.contains("private func cancelAuthenticationTaskAndPendingAttempt()"))
    #expect(switcherSource.contains("await cancelPendingAttemptBeforeCallback()"))
  }

  @Test("gateway callback secrets are absent from callback logging calls")
  func gatewayCallbackSecretsAreNotLogged() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryURL = testsURL.deletingLastPathComponent().deletingLastPathComponent()
    let exchangeSource = try String(
      contentsOf: repositoryURL.appendingPathComponent(
        "Catbird/Core/Networking/GatewayOAuthExchange.swift"),
      encoding: .utf8
    )
    let authSource = try String(
      contentsOf: repositoryURL.appendingPathComponent("Catbird/Core/State/AuthManager.swift"),
      encoding: .utf8
    )
    let appSource = try String(
      contentsOf: repositoryURL.appendingPathComponent("Catbird/App/CatbirdApp.swift"),
      encoding: .utf8
    )
    let handlerSource = try String(
      contentsOf: repositoryURL.appendingPathComponent(
        "Catbird/Core/Networking/URLHandler.swift"),
      encoding: .utf8
    )

    let authCallback = try sourceScope(
      authSource,
      from: "  func handleGatewayCallback(_ url: URL) async throws {",
      to: "  func cancelGatewayOAuthFlow() async {"
    )
    let appCallback = try sourceScope(
      appSource,
      from: "      .onOpenURL { url in",
      to: "          } else if url.scheme == \"blue.catbird\""
    )
    let handlerCallback = try sourceScope(
      handlerSource,
      from: "    private func handleOAuthCallback(_ url: URL) {",
      to: "    // MARK: - In-App Browser"
    )
    let callbackLogging = [
      loggingCalls(in: exchangeSource),
      loggingCalls(in: authCallback),
      loggingCalls(in: appCallback),
      loggingCalls(in: handlerCallback),
    ].joined(separator: "\n")
    let forbiddenValueReferences = [
      "url.absoluteString",
      "url.query",
      "queryItems",
      #"\(url)"#,
      #"\(url,"#,
      #"\(code"#,
      "sessionID",
      "session_id",
      "browserNonce",
      "internalCallback",
      "payload.sessionID",
    ]

    for forbidden in forbiddenValueReferences {
      #expect(!callbackLogging.contains(forbidden))
    }
  }

  @Test("login binds a cryptographic nonce and the exact callback URL")
  func loginBinding() async throws {
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { _ in throw GatewayOAuthExchangeError.unauthorized }
    )

    let loginURL = try await exchange.prepareLogin(
      URL(string: "https://api.catbird.blue/auth/login?identifier=alice.test")!
    )
    let components = try #require(URLComponents(url: loginURL, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    let nonce = try #require(query["browser_nonce"] ?? nil)

    #expect(query["identifier"] == "alice.test")
    #expect(query["redirect_to"] == callbackURL.absoluteString)
    #expect(nonce.count == 43)
    #expect(nonce.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
  }

  @Test("a second login cannot replace a live pending browser nonce")
  func overlappingLoginRejected() async throws {
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { _ in throw GatewayOAuthExchangeError.unauthorized }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

    await #expect(throws: GatewayOAuthExchangeError.flowInProgress) {
      try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
    }
  }

  @Test("a native nonce expires after sixty seconds")
  func nativeNonceExpiry() async throws {
    let clock = TestUptime()
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      uptime: { clock.value },
      send: { _ in throw GatewayOAuthExchangeError.unauthorized }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
    clock.value = 60.001

    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await exchange.redeem(
        URL(
          string:
            "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")!
      )
    }
  }

  @Test("exchange transport rejects redirects and streamed responses over budget")
  func transportBoundaries() throws {
    #expect(GatewayOAuthExchangeTransport.redirectTarget == nil)
    var buffer = Data(repeating: 65, count: GatewayOAuthExchange.maximumResponseBytes)
    try GatewayOAuthExchangeTransport.append(
      Data(), to: &buffer, maximumBytes: GatewayOAuthExchange.maximumResponseBytes)
    #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try GatewayOAuthExchangeTransport.append(
        Data([66]), to: &buffer, maximumBytes: GatewayOAuthExchange.maximumResponseBytes)
    }
  }

  @Test("cancelling transport stops its underlying URL session task")
  func transportCancellation() async throws {
    let probe = TransportCancellationProbe()
    TransportCancellationURLProtocol.registry.install(probe)
    defer { TransportCancellationURLProtocol.registry.install(nil) }

    let transport = GatewayOAuthExchangeTransport(
      maximumBytes: GatewayOAuthExchange.maximumResponseBytes,
      protocolClasses: [TransportCancellationURLProtocol.self]
    )
    let request = URLRequest(url: gatewayURL.appendingPathComponent("auth/exchange"))
    let operation = Task {
      try await transport.send(request)
    }
    await probe.waitUntilStarted()
    operation.cancel()

    do {
      _ = try await operation.value
      Issue.record("cancelled transport unexpectedly returned a response")
    } catch {
      // Cancellation must fail the send and stop the underlying URL loading task.
    }
    await probe.waitUntilStopped()
    #expect(probe.stopCount == 1)
  }

  @Test("an absolute deadline wins even when the sender ignores cancellation")
  func absoluteRequestDeadline() async throws {
    let sendGate = ManualAsyncGate()
    let deadlineGate = ManualAsyncGate()
    let response = HTTPURLResponse(
      url: gatewayURL.appendingPathComponent("auth/exchange"),
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { _ in
        await sendGate.wait()
        return (
          Data(#"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8),
          response
        )
      },
      waitForDeadline: {
        await deadlineGate.wait()
      }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

    let redemption = Task {
      try await exchange.redeem(
        URL(
          string:
            "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        )!
      )
    }
    await sendGate.waitUntilEntered()
    await deadlineGate.waitUntilEntered()
    await deadlineGate.open()

    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await redemption.value
    }
    await sendGate.open()
  }

  @Test("cancelling the flow invalidates an in-flight exchange response")
  func cancelledInFlightExchange() async throws {
    let sendGate = ManualAsyncGate()
    let response = HTTPURLResponse(
      url: gatewayURL.appendingPathComponent("auth/exchange"),
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { _ in
        await sendGate.wait()
        return (
          Data(#"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8),
          response
        )
      }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

    let redemption = Task {
      try await exchange.redeem(
        URL(
          string:
            "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        )!
      )
    }
    await sendGate.waitUntilEntered()
    await exchange.cancelPendingLogin()
    _ = try await exchange.prepareLogin(
      URL(string: "https://api.catbird.blue/auth/login?identifier=next-account.test")!
    )
    await sendGate.open()

    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await redemption.value
    }
  }

  @Test("callback redemption sends JSON to the fixed endpoint with exact Origin")
  func redemptionRequest() async throws {
    let recorder = RequestRecorder(
      responseData: Data(
        #"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8),
      response: HTTPURLResponse(
        url: gatewayURL.appendingPathComponent("auth/exchange"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
    )
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { request in await recorder.send(request) }
    )
    let loginURL = try await exchange.prepareLogin(
      URL(string: "https://api.catbird.blue/auth/login")!
    )
    let loginComponents = try #require(URLComponents(url: loginURL, resolvingAgainstBaseURL: false))
    let nonce = try #require(
      loginComponents.queryItems?.first(where: { $0.name == "browser_nonce" })?.value)

    let sessionID = try await exchange.redeem(
      URL(
        string:
          "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")!
    )
    let request = try #require(await recorder.request)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

    #expect(sessionID == "550e8400-e29b-41d4-a716-446655440000")
    #expect(request.url == gatewayURL.appendingPathComponent("auth/exchange"))
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://catbird.blue")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(
      json == [
        "code": "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
        "browser_nonce": nonce,
      ])
  }

  @Test("malformed callback consumes pending nonce and replay fails locally")
  func malformedCallbackAndReplay() async throws {
    let recorder = RequestRecorder(
      responseData: Data(
        #"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8),
      response: HTTPURLResponse(
        url: gatewayURL.appendingPathComponent("auth/exchange"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
    )
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { request in await recorder.send(request) }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await exchange.redeem(
        URL(
          string:
            "https://evil.example/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")!
      )
    }
    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await exchange.redeem(
        URL(
          string:
            "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")!
      )
    }
    #expect(await recorder.request == nil)
  }

  @Test("wrong origin, malformed code, fragments, and extra query fields fail closed")
  func structuralCallbackValidation() async throws {
    let invalidURLs = [
      "http://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
      "https://catbird.blue.evil.example/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
      "https://catbird.blue/oauth/callback?code=short",
      "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ&session_id=leak",
      "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ#fragment",
    ]

    for rawURL in invalidURLs {
      let exchange = GatewayOAuthExchange(
        gatewayURL: gatewayURL,
        callbackURL: callbackURL,
        send: { _ in throw GatewayOAuthExchangeError.unauthorized }
      )
      _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
      await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
        try await exchange.redeem(URL(string: rawURL)!)
      }
    }
  }

  @Test("HTTPS default port is equivalent when omitted or explicit")
  func defaultHTTPSPortNormalization() async throws {
    for (configured, callback) in [
      (
        "https://catbird.blue/oauth/callback",
        "https://catbird.blue:443/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
      ),
      (
        "https://catbird.blue:443/oauth/callback",
        "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
      ),
    ] {
      let response = HTTPURLResponse(
        url: gatewayURL.appendingPathComponent("auth/exchange"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let exchange = GatewayOAuthExchange(
        gatewayURL: gatewayURL,
        callbackURL: URL(string: configured)!,
        send: { request in
          #expect(request.value(forHTTPHeaderField: "Origin") == "https://catbird.blue")
          return (
            Data(#"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8),
            response
          )
        }
      )
      _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
      #expect(
        try await exchange.redeem(URL(string: callback)!)
          == "550e8400-e29b-41d4-a716-446655440000")
    }
  }

  @Test("non-default HTTPS callback ports are rejected")
  func nonDefaultHTTPSPortRejected() async throws {
    let exchange = GatewayOAuthExchange(
      gatewayURL: gatewayURL,
      callbackURL: callbackURL,
      send: { _ in throw GatewayOAuthExchangeError.unauthorized }
    )
    _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
    await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
      try await exchange.redeem(
        URL(
          string:
            "https://catbird.blue:444/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        )!
      )
    }
  }

  @Test("transport eagerly initializes its session and cancels unknown delegate tasks")
  func eagerTransportAndUnknownTaskPolicy() {
    let transport = GatewayOAuthExchangeTransport(
      maximumBytes: GatewayOAuthExchange.maximumResponseBytes)
    #expect(transport.hasInitializedSession)
    #expect(
      GatewayOAuthExchangeTransport.responseDisposition(hasPendingRequest: false) == .cancel)
    #expect(
      GatewayOAuthExchangeTransport.responseDisposition(hasPendingRequest: true) == .allow)
  }

  @Test("authentication manager uses one canonical gateway URL")
  func canonicalGatewayURL() {
    #expect(AuthenticationManager.gatewayURL == CatbirdGatewayConfiguration.current.origin)
  }

  @Test("non-success and oversized or malformed responses fail closed")
  func boundedResponse() async throws {
    let cases: [(Data, Int, [String: String])] = [
      (
        Data(#"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8), 401,
        ["Content-Type": "application/json"]
      ),
      (
        Data(repeating: 65, count: GatewayOAuthExchange.maximumResponseBytes + 1), 200,
        ["Content-Type": "application/json"]
      ),
      (
        Data(#"{"session_id":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8), 200,
        ["Content-Type": "text/plain"]
      ),
      (Data(#"{"session_id":""}"#.utf8), 200, ["Content-Type": "application/json"]),
    ]

    for (data, status, headers) in cases {
      let response = HTTPURLResponse(
        url: gatewayURL.appendingPathComponent("auth/exchange"),
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
      )!
      let exchange = GatewayOAuthExchange(
        gatewayURL: gatewayURL,
        callbackURL: callbackURL,
        send: { _ in (data, response) }
      )
      _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

      await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
        try await exchange.redeem(
          URL(
            string:
              "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
          )!)
      }
    }
  }

  @Test("exchange accepts only canonical lowercase UUID session identifiers")
  func canonicalSessionIDGrammar() async throws {
    let invalidSessionIDs = [
      "session-123",
      "550E8400-E29B-41D4-A716-446655440000",
      "550e8400-e29b-41d4-a716-446655440000#fragment",
      String(repeating: "a", count: 513),
    ]

    for sessionID in invalidSessionIDs {
      let response = HTTPURLResponse(
        url: gatewayURL.appendingPathComponent("auth/exchange"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let responseData = try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
      let exchange = GatewayOAuthExchange(
        gatewayURL: gatewayURL,
        callbackURL: callbackURL,
        send: { _ in (responseData, response) }
      )
      _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)

      await #expect(throws: GatewayOAuthExchangeError.unauthorized) {
        try await exchange.redeem(
          URL(
            string:
              "https://catbird.blue/oauth/callback?code=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
          )!)
      }
    }
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

private actor RequestRecorder {
  private(set) var request: URLRequest?
  let responseData: Data
  let response: URLResponse

  init(responseData: Data, response: URLResponse) {
    self.responseData = responseData
    self.response = response
  }

  func send(_ request: URLRequest) -> (Data, URLResponse) {
    self.request = request
    return (responseData, response)
  }
}

private actor ManualAsyncGate {
  private var entered = false
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    while !entered {
      await Task.yield()
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

private final class TransportCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var storedStopCount = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  var stopCount: Int {
    lock.withLock { storedStopCount }
  }

  func markStarted() {
    let waiters = lock.withLock {
      started = true
      let waiters = startWaiters
      startWaiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  func markStopped() {
    let waiters = lock.withLock {
      storedStopCount += 1
      let waiters = stopWaiters
      stopWaiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        guard !started else { return true }
        startWaiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func waitUntilStopped() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        guard storedStopCount == 0 else { return true }
        stopWaiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }
}

private func sourceScope(_ source: String, from start: String, to end: String) throws -> String {
  let startRange = try #require(source.range(of: start))
  let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
  return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func loggingCalls(in source: String) -> String {
  var calls: [String] = []
  var current: [String] = []
  var parenthesisDepth = 0

  for line in source.components(separatedBy: .newlines) {
    if current.isEmpty {
      guard line.contains("logger.") || line.contains("print(") else { continue }
    }

    current.append(line)
    parenthesisDepth += line.reduce(into: 0) { depth, character in
      if character == "(" {
        depth += 1
      } else if character == ")" {
        depth -= 1
      }
    }

    if parenthesisDepth <= 0 {
      calls.append(current.joined(separator: "\n"))
      current.removeAll()
      parenthesisDepth = 0
    }
  }

  if !current.isEmpty {
    calls.append(current.joined(separator: "\n"))
  }
  return calls.joined(separator: "\n")
}

private final class TransportCancellationProbeRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var probe: TransportCancellationProbe?

  func install(_ probe: TransportCancellationProbe?) {
    lock.withLock {
      self.probe = probe
    }
  }

  func current() -> TransportCancellationProbe? {
    lock.withLock { probe }
  }
}

private final class TransportCancellationURLProtocol: URLProtocol, @unchecked Sendable {
  static let registry = TransportCancellationProbeRegistry()

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.registry.current()?.markStarted()
  }

  override func stopLoading() {
    Self.registry.current()?.markStopped()
  }
}
