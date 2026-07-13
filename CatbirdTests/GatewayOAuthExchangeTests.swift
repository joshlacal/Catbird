import Foundation
import Testing

@testable import Catbird

@Suite("Gateway OAuth single-use exchange")
struct GatewayOAuthExchangeTests {
  private let callbackURL = URL(string: "https://catbird.blue/oauth/callback")!
  private let gatewayURL = URL(string: "https://api.catbird.blue")!

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

  @Test("callback redemption sends JSON to the fixed endpoint with exact Origin")
  func redemptionRequest() async throws {
    let recorder = RequestRecorder(
      responseData: Data(#"{"session_id":"session-123"}"#.utf8),
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

    #expect(sessionID == "session-123")
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
      responseData: Data(#"{"session_id":"session-123"}"#.utf8),
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
          return (Data(#"{"session_id":"session-123"}"#.utf8), response)
        }
      )
      _ = try await exchange.prepareLogin(URL(string: "https://api.catbird.blue/auth/login")!)
      #expect(try await exchange.redeem(URL(string: callback)!) == "session-123")
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
    #expect(AuthenticationManager.gatewayURL == URL(string: "https://api.catbird.blue")!)
  }

  @Test("non-success and oversized or malformed responses fail closed")
  func boundedResponse() async throws {
    let cases: [(Data, Int, [String: String])] = [
      (Data(#"{"session_id":"session-123"}"#.utf8), 401, ["Content-Type": "application/json"]),
      (
        Data(repeating: 65, count: GatewayOAuthExchange.maximumResponseBytes + 1), 200,
        ["Content-Type": "application/json"]
      ),
      (Data(#"{"session_id":"session-123"}"#.utf8), 200, ["Content-Type": "text/plain"]),
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
