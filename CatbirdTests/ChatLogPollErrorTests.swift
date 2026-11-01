import Foundation
@testable import Petrel
import Testing
@testable import Catbird

/// The getLog poll runs in the background, so a failed poll backs off without raising
/// the Messages alert over a conversation list that loaded. Only a poll that needs the
/// user to sign in again is reported.
@Suite("Chat log poll errors", .serialized)
@MainActor
struct ChatLogPollErrorTests {
  @Test("A failed background getLog poll does not raise the Messages alert",
    arguments: [URLError.Code.resourceUnavailable, .cannotParseResponse, .badServerResponse])
  func failedPollStaysQuiet(code: URLError.Code) async throws {
    let manager = try await makeManager(outcome: .failure(code))

    await manager.pollGetLog()

    #expect(ChatLogStubURLProtocol.paths.contains("/xrpc/chat.bsky.convo.getLog"))
    #expect(manager.errorState == nil)
  }

  @Test("A getLog poll that needs sign-in is still reported")
  func signInRequiredIsReported() async throws {
    let manager = try await makeManager(outcome: .status(401))

    await manager.pollGetLog()

    #expect(ChatLogStubURLProtocol.paths.contains("/xrpc/chat.bsky.convo.getLog"))
    #expect(manager.errorState != nil)
  }

  private func makeManager(outcome: ChatLogStubURLProtocol.Outcome) async throws -> ChatManager {
    let previousProtocols = NetworkService.getNetworkTestProtocolClasses()
    try #require(previousProtocols == nil, "The focused transport fixture requires exclusive use of Petrel's network hook")
    ChatLogStubURLProtocol.reset(outcome)
    NetworkService.setNetworkTestProtocolClasses([ChatLogStubURLProtocol.self])
    defer { NetworkService.setNetworkTestProtocolClasses(previousProtocols) }
    // A loopback literal passes URL validation without DNS. Petrel copies the protocol
    // into its sessions during construction, so the global hook is restored before polling.
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://127.0.0.1")))
    return ChatManager(client: client)
  }
}

private final class ChatLogStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Outcome {
    case failure(URLError.Code)
    case status(Int)
  }

  private static let lock = NSLock()
  private nonisolated(unsafe) static var outcome = Outcome.failure(.resourceUnavailable)
  private nonisolated(unsafe) static var requestPaths: [String] = []

  static var paths: [String] { lock.withLock { requestPaths } }

  static func reset(_ outcome: Outcome) {
    lock.withLock {
      self.outcome = outcome
      requestPaths = []
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let outcome = Self.lock.withLock {
      if let path = request.url?.path { Self.requestPaths.append(path) }
      return Self.outcome
    }
    switch outcome {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .status(let code):
      guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
              headerFields: ["Content-Type": "application/json"]) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"error":"AuthenticationRequired","message":"Sign in again."}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
