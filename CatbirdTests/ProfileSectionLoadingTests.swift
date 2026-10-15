import CoreFoundation
import Foundation
@testable import Petrel
import Testing

@testable import Catbird

/// A profile's More sections share the profile screen's view model, so one section's load must
/// not stop another's. A section page left loading by a section the reader already left (the
/// next page of Lists, or the starter-pack refresh after creating one) used to make the next
/// section's first load return without loading, and that section showed "No Feeds" until pull
/// to refresh.
@Suite("Profile section loading", .serialized)
@MainActor
struct ProfileSectionLoadingTests {
  typealias Section = ProfileSectionStubServer.Section

  @Test(
    "A section's first load runs while another section's next page is still loading",
    arguments: zip([Section.lists, .feeds, .starterPacks], [Section.feeds, .starterPacks, .lists])
  )
  func firstLoadRunsWhileAnotherSectionPages(paging: Section, opening: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    // A failed expectation must not leave the held page waiting for its timeout.
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server)

    try await Self.refresh(paging, on: viewModel)
    #expect(Self.count(of: paging, in: viewModel) == 1)

    // The server holds every next page, so this one stays in flight until released.
    let nextPage = Task { await Self.loadNextPage(of: paging, on: viewModel) }
    try await Self.waitUntil { server.heldRequestCount == 1 }

    try await Self.refresh(opening, on: viewModel)

    #expect(server.requestCount(opening) == 1)
    #expect(Self.count(of: opening, in: viewModel) == 1)

    server.releaseHeldPages()
    await nextPage.value
    #expect(Self.count(of: paging, in: viewModel) == 2)
  }

  // MARK: - Helpers

  private static func makeLoadedViewModel(server: ProfileSectionStubServer) async throws -> ProfileViewModel {
    let client = try await ModerationStateNetworkHook.withProtocol(ProfileSectionStubProtocol.self) {
      await ATProtoClient(baseURL: server.baseURL)
    }
    let viewModel = ProfileViewModel(
      client: client, userDID: ProfileSectionStubServer.ownerDID, currentUserDID: "did:plc:sectionviewer"
    )
    await viewModel.loadProfile()
    try #require(viewModel.profile != nil, "getProfile stub did not load: \(String(describing: viewModel.error))")
    return viewModel
  }

  private static func refresh(_ section: Section, on viewModel: ProfileViewModel) async throws {
    switch section {
    case .lists: try await viewModel.refreshLists()
    case .starterPacks: try await viewModel.refreshStarterPacks()
    case .feeds: try await viewModel.refreshFeeds()
    }
  }

  private static func loadNextPage(of section: Section, on viewModel: ProfileViewModel) async {
    switch section {
    case .lists: await viewModel.loadMoreLists()
    case .starterPacks: await viewModel.loadStarterPacks()
    case .feeds: await viewModel.loadMoreFeeds()
    }
  }

  private static func count(of section: Section, in viewModel: ProfileViewModel) -> Int {
    switch section {
    case .lists: viewModel.lists.count
    case .starterPacks: viewModel.starterPacks.count
    case .feeds: viewModel.feeds.count
    }
  }

  private struct TimedOut: Error {}

  private static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the next page to reach the stub server")
    throw TimedOut()
  }
}

/// A fake AppView for one profile. Each section's first page holds one item and a cursor; the
/// next page (any request with a cursor) holds one more item and is answered only once
/// `releaseHeldPages()` is called.
final class ProfileSectionStubServer: @unchecked Sendable {
  enum Section: String, Sendable, CustomTestStringConvertible {
    case lists, starterPacks, feeds
    var testDescription: String { rawValue }
  }

  static let ownerDID = "did:plc:sectionowner"
  private static let cid = "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
  private static let indexedAt = "2026-10-15T00:00:00.000Z"
  private static let creator = #"{"did":"\#(ownerDID)","handle":"owner.section.test"}"#

  let port: Int
  private let lock = NSLock()
  private var requests: [Section: Int] = [:]
  private var heldReplies: [@Sendable () -> Void] = []
  private var heldRequests = 0

  init(port: Int) { self.port = port }

  var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
  var heldRequestCount: Int { lock.withLock { heldRequests } }
  func requestCount(_ section: Section) -> Int { lock.withLock { requests[section, default: 0] } }

  struct Reply {
    let status: Int
    let body: Data
    /// Answered only once `releaseHeldPages()` is called.
    let isHeld: Bool
  }

  /// The answer to `url`.
  func reply(for url: URL) -> Reply {
    let isNextPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.contains { $0.name == "cursor" } ?? false
    let item = isNextPage ? "2" : "1"
    let cursor = isNextPage ? "" : #","cursor":"page-2""#
    let section: Section
    let body: String
    switch url.path {
    case "/xrpc/app.bsky.actor.getProfile":
      return Reply(status: 200, body: Data(Self.creator.utf8), isHeld: false)
    case "/xrpc/app.bsky.graph.getLists":
      section = .lists
      body = #"{"lists":[{"uri":"at://\#(Self.ownerDID)/app.bsky.graph.list/l\#(item)","cid":"\#(Self.cid)","creator":\#(Self.creator),"name":"List \#(item)","purpose":"app.bsky.graph.defs#curatelist","indexedAt":"\#(Self.indexedAt)"}]\#(cursor)}"#
    case "/xrpc/app.bsky.graph.getActorStarterPacks":
      section = .starterPacks
      body = #"{"starterPacks":[{"uri":"at://\#(Self.ownerDID)/app.bsky.graph.starterpack/s\#(item)","cid":"\#(Self.cid)","record":{"$type":"app.bsky.graph.starterpack","name":"Pack \#(item)","list":"at://\#(Self.ownerDID)/app.bsky.graph.list/l1","createdAt":"\#(Self.indexedAt)"},"creator":\#(Self.creator),"indexedAt":"\#(Self.indexedAt)"}]\#(cursor)}"#
    case "/xrpc/app.bsky.feed.getActorFeeds":
      section = .feeds
      body = #"{"feeds":[{"uri":"at://\#(Self.ownerDID)/app.bsky.feed.generator/f\#(item)","cid":"\#(Self.cid)","did":"did:web:feed.section.test","creator":\#(Self.creator),"displayName":"Feed \#(item)","indexedAt":"\#(Self.indexedAt)"}]\#(cursor)}"#
    default:
      return Reply(status: 404, body: Data(#"{"error":"NotFound"}"#.utf8), isHeld: false)
    }
    lock.withLock { requests[section, default: 0] += 1 }
    return Reply(status: 200, body: Data(body.utf8), isHeld: isNextPage)
  }

  func hold(_ answer: @escaping @Sendable () -> Void) {
    lock.withLock {
      heldRequests += 1
      heldReplies.append(answer)
    }
  }

  func releaseHeldPages() {
    let replies = lock.withLock {
      defer { heldReplies.removeAll() }
      return heldReplies
    }
    replies.forEach { $0() }
  }
}

/// Routes each request to the server registered for its loopback port.
final class ProfileSectionStubProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [Int: ProfileSectionStubServer] = [:]
  nonisolated(unsafe) private static var nextPort = 44_000

  static func makeServer() -> ProfileSectionStubServer {
    lock.withLock {
      nextPort += 1
      let server = ProfileSectionStubServer(port: nextPort)
      servers[nextPort] = server
      return server
    }
  }

  static func release(_ server: ProfileSectionStubServer) {
    lock.withLock { _ = servers.removeValue(forKey: server.port) }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, url.host == "127.0.0.1", let port = url.port,
      let server = Self.lock.withLock({ Self.servers[port] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let reply = server.reply(for: url)
    guard reply.isHeld else {
      answer(url: url, status: reply.status, body: reply.body)
      return
    }
    // Answer later on this loader thread's run loop, where URLProtocol expects its callbacks.
    nonisolated(unsafe) let runLoop = CFRunLoopGetCurrent()
    server.hold { [self] in
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
        self.answer(url: url, status: reply.status, body: reply.body)
      }
      CFRunLoopWakeUp(runLoop)
    }
  }

  override func stopLoading() {}

  private func answer(url: URL, status: Int, body: Data) {
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
}
