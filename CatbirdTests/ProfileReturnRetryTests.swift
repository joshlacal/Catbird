import Foundation
@testable import Petrel
import Testing

@testable import Catbird

/// Coming back to a profile loads again only what never arrived (puyzlntl). A first page that came
/// back empty counts as arrived, cursor or not: an account whose latest 150 items hold no replies
/// to others ends with an empty Replies tab and a cursor, and must not page five times on every
/// return; an empty "Followed by" answer is not asked again either.
@Suite("Profile return retry", .serialized)
@MainActor
struct ProfileReturnRetryTests {
  @Test("A Replies tab whose pages held no replies to others is not loaded again on return")
  func emptyRepliesWithCursorAreNotRetried() async throws {
    let server = ProfileRetryStubProtocol.makeServer()
    defer { ProfileRetryStubProtocol.release(server) }
    let viewModel = try await Self.makeViewModel(server: server)

    await viewModel.loadReplies()

    // Positive control: the old rule (empty and hasMoreReplies still true) would retry.
    #expect(server.authorFeedRequests == 5)
    #expect(viewModel.boxedReplies.isEmpty)
    #expect(viewModel.hasMoreReplies)
    #expect(!viewModel.needsFirstPageRetry(for: .replies))
  }

  @Test("Empty Posts and Media first pages with a cursor count as loaded", arguments: [ProfileTab.posts, .media])
  func emptyFirstPagesAreNotRetried(tab: ProfileTab) async throws {
    let server = ProfileRetryStubProtocol.makeServer()
    defer { ProfileRetryStubProtocol.release(server) }
    let viewModel = try await Self.makeViewModel(server: server)

    if tab == .posts {
      await viewModel.loadPosts()
    } else {
      await viewModel.loadMediaPosts()
    }

    #expect(server.authorFeedRequests == 1)
    #expect(!viewModel.needsFirstPageRetry(for: tab))
  }

  @Test("A first page that failed is loaded again on return", arguments: [ProfileTab.posts, .replies, .media])
  func failedFirstPageIsRetried(tab: ProfileTab) async throws {
    let viewModel = try await Self.makeUnreachableViewModel()

    switch tab {
    case .posts: await viewModel.loadPosts()
    case .replies: await viewModel.loadReplies()
    default: await viewModel.loadMediaPosts()
    }

    #expect(viewModel.needsFirstPageRetry(for: tab))
  }

  @Test("An empty known-followers answer counts as loaded; a failed one does not")
  func knownFollowersAnswerIsRemembered() async throws {
    let server = ProfileRetryStubProtocol.makeServer()
    defer { ProfileRetryStubProtocol.release(server) }
    let answered = try await Self.makeViewModel(server: server)
    await answered.loadKnownFollowers()
    #expect(server.knownFollowersRequests == 1)
    #expect(answered.knownFollowers.isEmpty)
    #expect(answered.hasLoadedKnownFollowers)

    let failed = try await Self.makeUnreachableViewModel()
    await failed.loadKnownFollowers()
    #expect(!failed.hasLoadedKnownFollowers)
  }

  private static func makeViewModel(server: ProfileRetryStubServer) async throws -> ProfileViewModel {
    let client = try await ModerationStateNetworkHook.withProtocol(ProfileRetryStubProtocol.self) {
      await ATProtoClient(baseURL: server.baseURL)
    }
    return ProfileViewModel(client: client, userDID: "did:plc:retryother", currentUserDID: "did:plc:retryme")
  }

  /// Nothing listens on port 9, so every request fails at once.
  private static func makeUnreachableViewModel() async throws -> ProfileViewModel {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "http://127.0.0.1:9")))
    return ProfileViewModel(client: client, userDID: "did:plc:retryother", currentUserDID: "did:plc:retryme")
  }
}

/// One fake AppView: every author-feed page is empty with a cursor, and nobody is a known follower.
final class ProfileRetryStubServer: @unchecked Sendable {
  let port: Int
  private let lock = NSLock()
  private var _authorFeedRequests = 0
  private var _knownFollowersRequests = 0

  init(port: Int) { self.port = port }

  var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
  var authorFeedRequests: Int { lock.withLock { _authorFeedRequests } }
  var knownFollowersRequests: Int { lock.withLock { _knownFollowersRequests } }

  func respond(path: String) -> (status: Int, body: Data) {
    switch path {
    case "/xrpc/app.bsky.feed.getAuthorFeed":
      lock.withLock { _authorFeedRequests += 1 }
      return (200, Data(#"{"feed":[],"cursor":"next-page"}"#.utf8))
    case "/xrpc/app.bsky.graph.getKnownFollowers":
      lock.withLock { _knownFollowersRequests += 1 }
      return (200, Data(#"{"subject":{"did":"did:plc:retryother","handle":"other.retry.test"},"followers":[]}"#.utf8))
    default:
      return (404, Data(#"{"error":"NotFound"}"#.utf8))
    }
  }
}

/// Routes each request to the server registered for its loopback port.
final class ProfileRetryStubProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [Int: ProfileRetryStubServer] = [:]
  nonisolated(unsafe) private static var nextPort = 43_000

  static func makeServer() -> ProfileRetryStubServer {
    lock.withLock {
      nextPort += 1
      let server = ProfileRetryStubServer(port: nextPort)
      servers[nextPort] = server
      return server
    }
  }

  static func release(_ server: ProfileRetryStubServer) {
    lock.withLock { _ = servers.removeValue(forKey: server.port) }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, url.host == "127.0.0.1", let port = url.port,
      let server = Self.lock.withLock({ Self.servers[port] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let (status, body) = server.respond(path: url.path)
    guard let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
