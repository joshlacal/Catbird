import Foundation
@testable import Petrel
import SwiftData
import Testing
import UIKit

@testable import Catbird

// Shared fixtures for the moderation-state suites. Preferences and labeler services reach AppState
// through the production network path: a URLProtocol sits under a real ATProtoClient and serves canned
// `app.bsky.actor.getPreferences` and `app.bsky.labeler.getServices` responses. Each client talks to its
// own loopback port, so every test controls its own server and several tests can run side by side.

// MARK: - Constants

enum ModerationStateFixtures {
  static let blueskyModerationDID = "did:plc:ar7c4by46qjdydhdevvrndac"
  static let customLabelerDID = "did:plc:statefixturelabeler"
  static let secondLabelerDID = "did:plc:statefixturelabelertwo"
  static let customLabelValue = "fixture-spoiler"

  /// A DID that no other test shares. Label definitions are cached process-wide by account, so reusing
  /// an account across tests could replay another test's cached response.
  static func uniqueDID(_ name: String) -> String {
    "did:plc:\(name)\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
  }
}

// MARK: - Canned server

/// One fake AppView. Tests mutate it between fetches to model server-side changes and outages.
final class ModerationStateServer: @unchecked Sendable {
  struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let requestedDIDs: [String]
    let acceptLabelers: String?
    let status: Int
  }

  private let lock = NSLock()
  private var _preferenceItems: [[String: Any]] = ModerationStateServer.preferenceItems(
    adultContentEnabled: false, contentLabelPrefs: [], labelerDIDs: [])
  private var _preferencesStatus = 200
  private var _servicesStatus = 200
  private var _servicesDelay: TimeInterval = 0
  private var _services: [String: [String: Any]] = [:]
  private var _requests: [RecordedRequest] = []

  let port: Int

  init(port: Int) {
    self.port = port
  }

  var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }

  // MARK: Scripting

  func setPreferences(
    adultContentEnabled: Bool,
    contentLabelPrefs: [(label: String, visibility: String)] = [],
    labelerDIDs: [String] = []
  ) {
    let items = Self.preferenceItems(
      adultContentEnabled: adultContentEnabled, contentLabelPrefs: contentLabelPrefs, labelerDIDs: labelerDIDs)
    lock.withLock { _preferenceItems = items }
  }

  /// Status for `getPreferences`; anything outside 2xx is an outage.
  func setPreferencesStatus(_ status: Int) {
    lock.withLock { _preferencesStatus = status }
  }

  /// Status for `getServices`; anything outside 2xx is an outage.
  func setServicesStatus(_ status: Int) {
    lock.withLock { _servicesStatus = status }
  }

  /// Holds every `getServices` response for this long before delivering it. The request is still
  /// recorded when it arrives, so a test can see that the server has it while the client waits.
  func setServicesDelay(_ delay: TimeInterval) {
    lock.withLock { _servicesDelay = delay }
  }

  fileprivate func responseDelay(forPath path: String) -> TimeInterval {
    path.hasSuffix("app.bsky.labeler.getServices") ? lock.withLock { _servicesDelay } : 0
  }

  /// A labeler that defines `identifier` as a content-blurring alert with a `warn` default.
  func publishLabeler(did: String, identifier: String = ModerationStateFixtures.customLabelValue) {
    let view: [String: Any] = [
      "$type": "app.bsky.labeler.defs#labelerViewDetailed",
      "uri": "at://\(did)/app.bsky.labeler.service/self",
      "cid": CID.fromDAGCBOR(Data("state-fixture-labeler-\(did)".utf8)).string,
      "creator": ["did": did, "handle": "labeler.state.test", "displayName": "State Fixture Labeler"],
      "policies": [
        "labelValues": [identifier],
        "labelValueDefinitions": [[
          "identifier": identifier, "severity": "alert", "blurs": "content",
          "defaultSetting": "warn", "adultOnly": false,
          "locales": [["lang": "en", "name": "Spoiler", "description": "Spoils a story."]],
        ]],
      ],
      "likeCount": 3,
      "indexedAt": "2026-01-01T00:00:00.000Z",
    ]
    lock.withLock { _services[did] = view }
  }

  /// Every request this server has seen, in order.
  var requests: [RecordedRequest] { lock.withLock { _requests } }

  func requests(forPath suffix: String) -> [RecordedRequest] {
    requests.filter { $0.path.hasSuffix(suffix) }
  }

  // MARK: Serving

  fileprivate func respond(
    method: String, path: String, requestedDIDs: [String], acceptLabelers: String?, body requestBody: Data?
  ) -> (Int, Data) {
    lock.withLock {
      let status: Int
      let body: Data
      switch (method, path) {
      case ("GET", "/xrpc/app.bsky.actor.getPreferences"):
        status = _preferencesStatus
        body = status == 200 ? preferencesBody() : Self.errorBody
      case ("POST", "/xrpc/app.bsky.actor.putPreferences"):
        // The write replaces the stored preferences with exactly what the client sent.
        status = _preferencesStatus
        if status == 200 {
          let sent = requestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
          _preferenceItems = (sent?["preferences"] as? [[String: Any]]) ?? _preferenceItems
          body = Data("{}".utf8)
        } else {
          body = Self.errorBody
        }
      case ("GET", "/xrpc/app.bsky.labeler.getServices"):
        status = _servicesStatus
        let views = requestedDIDs.compactMap { _services[$0] }
        body = status == 200
          ? ((try? JSONSerialization.data(withJSONObject: ["views": views])) ?? Self.errorBody)
          : Self.errorBody
      default:
        status = 404
        body = Self.errorBody
      }
      _requests.append(RecordedRequest(
        method: method, path: path, requestedDIDs: requestedDIDs, acceptLabelers: acceptLabelers, status: status))
      return (status, body)
    }
  }

  private static let errorBody = Data(#"{"error":"InvalidRequest","message":"state fixture outage"}"#.utf8)

  /// Called with the lock held.
  private func preferencesBody() -> Data {
    (try? JSONSerialization.data(withJSONObject: ["preferences": _preferenceItems])) ?? Self.errorBody
  }

  private static func preferenceItems(
    adultContentEnabled: Bool, contentLabelPrefs: [(label: String, visibility: String)], labelerDIDs: [String]
  ) -> [[String: Any]] {
    var items: [[String: Any]] = [
      ["$type": "app.bsky.actor.defs#adultContentPref", "enabled": adultContentEnabled],
      [
        "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
        "items": [["id": "statefixturefollowing", "type": "timeline", "value": "following", "pinned": true]],
      ],
    ]
    if !labelerDIDs.isEmpty {
      items.append([
        "$type": "app.bsky.actor.defs#labelersPref",
        "labelers": labelerDIDs.map { ["did": $0] },
      ])
    }
    for pref in contentLabelPrefs {
      items.append(["$type": "app.bsky.actor.defs#contentLabelPref", "label": pref.label, "visibility": pref.visibility])
    }
    return items
  }
}

/// Routes each request to the server registered for its loopback port.
final class ModerationStateProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [Int: ModerationStateServer] = [:]
  nonisolated(unsafe) private static var nextPort = 41_000

  static func makeServer() -> ModerationStateServer {
    lock.withLock {
      nextPort += 1
      let server = ModerationStateServer(port: nextPort)
      servers[nextPort] = server
      return server
    }
  }

  static func release(_ server: ModerationStateServer) {
    lock.withLock { _ = servers.removeValue(forKey: server.port) }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Guards a delayed delivery against `stopLoading`, which URLSession calls when the client cancels
  /// the request. Each protocol instance serves one request.
  private let deliveryLock = NSLock()
  private var isStopped = false

  override func startLoading() {
    guard let url = request.url, url.host == "127.0.0.1", let port = url.port,
      let server = Self.lock.withLock({ Self.servers[port] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let dids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == "dids" }.compactMap(\.value) ?? []
    let (status, body) = server.respond(
      method: (request.httpMethod ?? "GET").uppercased(), path: url.path, requestedDIDs: dids,
      acceptLabelers: request.value(forHTTPHeaderField: "atproto-accept-labelers"),
      body: Self.body(of: request))
    guard let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let delay = server.responseDelay(forPath: url.path)
    guard delay > 0 else {
      deliver(response: response, body: body)
      return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
      if deliveryLock.withLock({ !isStopped }) { deliver(response: response, body: body) }
    }
  }

  private func deliver(response: HTTPURLResponse, body: Data) {
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    deliveryLock.withLock { isStopped = true }
  }

  /// URLSession hands upload bodies to protocols as a stream.
  private static func body(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

// MARK: - Harness

struct ModerationStateNoAgePrompt: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
}

/// A signed-in account backed by a fake server and a shared in-memory store.
@MainActor
struct ModerationStateAccount {
  let did: String
  let server: ModerationStateServer
  let client: ATProtoClient
  let appState: AppState
}

@MainActor
final class ModerationStateHarness {
  let container: ModelContainer
  private var accounts: [ModerationStateAccount] = []

  init() throws {
    container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
  }

  /// Ends the accounts' background work and releases their servers.
  func tearDown() {
    for account in accounts {
      account.appState.cleanup()
      ModerationStateProtocol.release(account.server)
    }
    accounts = []
  }

  /// Persists a row the way an earlier session would have left it.
  func persistRow(
    did: String, adultContentEnabled: Bool, contentLabelPrefs: [ContentLabelPreference] = [],
    confirmed: Bool
  ) throws {
    let row = Preferences(
      accountDID: did, contentLabelPrefs: contentLabelPrefs, adultContentEnabled: adultContentEnabled)
    row.hasConfirmedServerPreferences = confirmed
    container.mainContext.insert(row)
    try container.mainContext.save()
  }

  /// Builds an account the way sign-in does: client, AppState, preferences manager with its store.
  func makeAccount(
    did: String, initializePreferences: Bool = true, server: ModerationStateServer? = nil
  ) async throws -> ModerationStateAccount {
    let server = server ?? ModerationStateProtocol.makeServer()
    let client = try await Self.makeClient(for: server)
    container.mainContext.insert(AppSettingsModel(accountDID: did))
    try container.mainContext.save()
    let appState = AppState(userDID: did, client: client, regulatoryChecker: ModerationStateNoAgePrompt())
    if initializePreferences {
      appState.initializePreferencesManager(with: container.mainContext)
      appState.preferencesManager.updateClient(client)
    }
    let account = ModerationStateAccount(did: did, server: server, client: client, appState: appState)
    accounts.append(account)
    return account
  }

  private static func makeClient(for server: ModerationStateServer) async throws -> ATProtoClient {
    try await ModerationStateNetworkHook.withProtocol(ModerationStateProtocol.self) {
      // A loopback literal passes Petrel's URL policy without DNS.
      await ATProtoClient(baseURL: server.baseURL)
    }
  }
}

// MARK: - Network hook

/// Petrel's `NetworkService.setNetworkTestProtocolClasses` is one process-wide slot, and a client copies
/// it into its sessions while it is constructed. Swift Testing runs suites concurrently, so this gate
/// keeps the moderation-state suites out of each other's way and out of any other suite's way:
///
/// - Moderation-state clients are built one at a time.
/// - A client is never built while another suite holds the slot. The gate waits for it to empty rather
///   than overwrite it, and fails the test if it never does.
/// - The slot is cleared afterwards only if it still holds this gate's protocol, so a value another
///   suite installed in the meantime is never clobbered by a stale "previous" value.
///
/// A suite outside `CatbirdTests/ModerationState` that uses the slot can only be protected from this
/// gate's window (a few milliseconds per client) if it also goes through `withProtocol`.
@MainActor
enum ModerationStateNetworkHook {
  struct SlotStayedBusy: Error, CustomStringConvertible {
    var description: String { "Petrel's network test hook stayed occupied by another suite" }
  }

  private static var isHeld = false
  private static var waiters: [CheckedContinuation<Void, Never>] = []

  private static func acquire() async {
    if isHeld {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      isHeld = true
    }
  }

  private static func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  /// Runs `construct` with `protocolClass` installed in Petrel's test slot.
  static func withProtocol<Result>(
    _ protocolClass: AnyClass, timeout: Duration = .seconds(30),
    construct: () async -> Result
  ) async throws -> Result {
    await acquire()
    defer { release() }
    try await waitForEmptySlot(timeout: timeout)
    NetworkService.setNetworkTestProtocolClasses([protocolClass])
    defer { clearSlot(ifHolding: protocolClass) }
    return await construct()
  }

  private static func waitForEmptySlot(timeout: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while NetworkService.getNetworkTestProtocolClasses() != nil {
      guard ContinuousClock.now < deadline else { throw SlotStayedBusy() }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func clearSlot(ifHolding protocolClass: AnyClass) {
    guard let current = NetworkService.getNetworkTestProtocolClasses(), current.count == 1,
      ObjectIdentifier(current[0]) == ObjectIdentifier(protocolClass)
    else { return }
    NetworkService.setNetworkTestProtocolClasses(nil)
  }
}

// MARK: - Subjects

enum ModerationStatePosts {
  /// A post by an unrelated author, carrying one label from `source` when `value` is given.
  static func json(
    labeled value: String? = nil, source: String = ModerationStateFixtures.blueskyModerationDID,
    slug: String = "labeled"
  ) -> [String: Any] {
    let uri = "at://did:plc:statefixtureauthor/app.bsky.feed.post/3statefixture\(slug)"
    var json: [String: Any] = [
      "uri": uri,
      "cid": CID.fromDAGCBOR(Data(uri.utf8)).string,
      "author": ["did": "did:plc:statefixtureauthor", "handle": "author.state.test"],
      "record": ["$type": "app.bsky.feed.post", "text": "Fixture post", "createdAt": "2026-01-01T00:00:00.000Z"],
      "indexedAt": "2026-01-01T00:00:00.000Z",
    ]
    if let value {
      json["labels"] = [["ver": 1, "src": source, "uri": uri, "val": value, "cts": "2026-01-01T00:00:00.000Z"]]
    }
    return json
  }

  static func post(labeled value: String, source: String = ModerationStateFixtures.blueskyModerationDID) throws
    -> AppBskyFeedDefs.PostView
  {
    try decode(AppBskyFeedDefs.PostView.self, json(labeled: value, source: source, slug: value.filter(\.isLetter)))
  }

  /// A timeline entry as the feed holds it after loading.
  static func cachedFeedPost(labeled value: String?, slug: String) throws -> CachedFeedViewPost {
    let item = try decode(AppBskyFeedDefs.FeedViewPost.self, ["post": json(labeled: value, slug: slug)])
    return try #require(CachedFeedViewPost(from: item, feedType: "timeline"))
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }
}

// MARK: - Waiting

/// Collects `ModerationPolicyDidChange` posts for one account.
@MainActor
final class ModerationPolicyChangeRecorder {
  private var token: NSObjectProtocol?
  private(set) var count = 0

  init(accountDID: String) {
    token = NotificationCenter.default.addObserver(
      forName: .moderationPolicyDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      guard notification.userInfo?["accountDID"] as? String == accountDID else { return }
      MainActor.assumeIsolated { self?.count += 1 }
    }
  }

  deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }
}
