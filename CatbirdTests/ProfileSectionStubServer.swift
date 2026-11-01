import CoreFoundation
import Foundation
import Testing

/// A fake AppView for one profile. Each section's first page holds one item and a cursor; the
/// next page (any request with a cursor) holds one more item and is answered only once
/// `releaseHeldPages()` is called. A first page is held too after `holdNextFirstPage(of:answering:)`,
/// and fails at once after `failNextFirstPages(of:count:)`, each in the order they were asked for.
final class ProfileSectionStubServer: @unchecked Sendable {
  enum Section: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case likes, lists, starterPacks, feeds
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
  private var cancelledHeldRequests = 0
  /// How each section's next first-page requests are answered, in order: the status, and
  /// whether the answer is held until `releaseHeldPages()`.
  private var firstPagePlans: [Section: [(status: Int, isHeld: Bool)]] = [:]

  init(port: Int) { self.port = port }

  var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
  var heldRequestCount: Int { lock.withLock { heldRequests } }
  /// Held requests that their caller cancelled before they were released.
  var cancelledHeldRequestCount: Int { lock.withLock { cancelledHeldRequests } }
  func requestCount(_ section: Section) -> Int { lock.withLock { requests[section, default: 0] } }

  /// Holds the next first-page request of `section` until `releaseHeldPages()`, then answers it
  /// with `status`: the page for 200, an XRPC error otherwise.
  func holdNextFirstPage(of section: Section, answering status: Int) {
    lock.withLock { firstPagePlans[section, default: []].append((status, true)) }
  }

  /// Answers the next `count` first-page requests of `section` at once with an XRPC error.
  func failNextFirstPages(of section: Section, count: Int) {
    lock.withLock { firstPagePlans[section, default: []] += Array(repeating: (400, false), count: count) }
  }

  func noteCancelledHeldRequest() {
    lock.withLock { cancelledHeldRequests += 1 }
  }

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
    case "/xrpc/app.bsky.feed.getActorLikes":
      section = .likes
      body = #"{"feed":[{"post":{"uri":"at://\#(Self.ownerDID)/app.bsky.feed.post/p\#(item)","cid":"\#(Self.cid)","author":\#(Self.creator),"record":{"$type":"app.bsky.feed.post","text":"Post \#(item)","createdAt":"\#(Self.indexedAt)"},"indexedAt":"\#(Self.indexedAt)"}}]\#(cursor)}"#
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
    let plan: (status: Int, isHeld: Bool)? = lock.withLock {
      requests[section, default: 0] += 1
      guard !isNextPage, firstPagePlans[section]?.isEmpty == false else { return nil }
      return firstPagePlans[section]?.removeFirst()
    }
    guard let plan else {
      return Reply(status: 200, body: Data(body.utf8), isHeld: isNextPage)
    }
    let planBody = plan.status == 200 ? body : #"{"error":"InvalidRequest","message":"planned first page"}"#
    return Reply(status: plan.status, body: Data(planBody.utf8), isHeld: plan.isHeld)
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
    stateLock.withLock { holdingServer = server }
    // Answer later on this loader thread's run loop, where URLProtocol expects its callbacks.
    nonisolated(unsafe) let runLoop = CFRunLoopGetCurrent()
    server.hold { [self] in
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
        // A request its caller cancelled meanwhile is not answered.
        guard self.takeHoldingServer() != nil else { return }
        self.answer(url: url, status: reply.status, body: reply.body)
      }
      CFRunLoopWakeUp(runLoop)
    }
  }

  override func stopLoading() {
    // Stopped while the server still held it: its caller cancelled it.
    takeHoldingServer()?.noteCancelledHeldRequest()
  }

  private let stateLock = NSLock()
  /// The server holding this request's answer, until the answer is sent or the request stops.
  private var holdingServer: ProfileSectionStubServer?

  private func takeHoldingServer() -> ProfileSectionStubServer? {
    stateLock.withLock {
      defer { holdingServer = nil }
      return holdingServer
    }
  }

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
