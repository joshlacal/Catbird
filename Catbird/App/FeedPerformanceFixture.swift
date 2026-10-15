//
//  FeedPerformanceFixture.swift
//  Catbird
//
//  Offline, deterministic home feed used to benchmark and profile feed scrolling.
//  Launch with `--feed-perf-fixture`. Optional arguments:
//    --feed-perf-count=<n>        number of feed items (default 400)
//    --feed-perf-autoscroll       run the scripted scroll benchmark once the feed is ready
//    --feed-perf-speed=<pt/s>     scripted scroll speed (default 3000)
//    --feed-perf-passes=<n>       down/up passes to run (default 3: down, up, down)
//    --feed-perf-content=<kind>   mixed (default), text, images, links, quotes, threads or reposts
//    --native-feed-rows=off       render every post with the hosted SwiftUI row instead of the native
//                                 UIKit cell, to compare the two (read by `NativeFeedRows.isEnabled`)
//
//  The benchmark scrolls the production feed controller at a constant speed with a display
//  link and records how far each frame overran its deadline. Results are printed as
//  `FEED_PERF_RESULT <json>` and written to `<tmp>/feed-perf-result.json`.
//

#if DEBUG && os(iOS)
import OSLog
@testable import Petrel
import QuartzCore
import SwiftData
import SwiftUI
import UIKit

private let feedPerfLogger = Logger(subsystem: "blue.catbird", category: "FeedPerformanceFixture")

struct FeedPerformanceFixture: View {
  @State private var phase: Phase = .preparing
  @State private var path = NavigationPath()

  private enum Phase {
    case preparing
    case ready(FeedPerformanceWorld)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .preparing:
        ProgressView("Preparing feed performance fixture")
      case .failed(let message):
        ContentUnavailableView("Feed performance fixture failed", systemImage: "exclamationmark.triangle",
          description: Text(message))
          .accessibilityIdentifier("feedperf.fixture.failure")
      case .ready(let world):
        SceneNavigationHost(appState: world.appState, appStateManager: .shared, context: world.context) {
          FeedCollectionViewWrapper(stateManager: world.feedStateManager, navigationPath: $path)
            .accessibilityIdentifier("feedperf.feed")
        }
        .environment(\.fontManager, world.appState.fontManager)
        .modelContainer(world.container)
        .task { await world.runBenchmarkIfRequested() }
      }
    }
    .task { await prepare() }
  }

  private func prepare() async {
    guard case .preparing = phase else { return }
    do {
      phase = .ready(try await FeedPerformanceWorld.make())
    } catch {
      feedPerfLogger.error("fixture failed: \(error.localizedDescription, privacy: .public)")
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - World

@MainActor
private final class FeedPerformanceWorld {
  let appState: AppState
  let context: SceneNavigationContext
  let container: ModelContainer
  /// PreferencesManager holds its client weakly, so the world keeps it alive.
  let client: ATProtoClient
  let feedStateManager: FeedStateManager

  private init(appState: AppState, context: SceneNavigationContext, container: ModelContainer,
    client: ATProtoClient, feedStateManager: FeedStateManager) {
    self.appState = appState
    self.context = context
    self.container = container
    self.client = client
    self.feedStateManager = feedStateManager
  }

  static let viewerDID = "did:plc:feedperfviewer"

  static func make() async throws -> FeedPerformanceWorld {
    let art = try FeedPerformanceArt.render()
    guard URLProtocol.registerClass(FeedPerformanceProtocol.self) else { throw FixtureError.transport }
    NetworkService.setNetworkTestProtocolClasses([FeedPerformanceProtocol.self])
    // 127.0.0.1 is the only host Petrel's URL policy accepts without DNS.
    let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)

    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self, DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    let appSettings = AppSettingsModel(accountDID: viewerDID)
    appSettings.autoplayVideos = false
    container.mainContext.insert(appSettings)
    container.mainContext.insert(Preferences(accountDID: viewerDID))
    try container.mainContext.save()

    let state = AppState(userDID: viewerDID, client: client, regulatoryChecker: NoAgePrompt())
    state.composerDraftManager.configureForTesting(modelContext: container.mainContext)
    state.initializePreferencesManager(with: container.mainContext)
    state.preferencesManager.updateClient(client)
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    await state.postHidingManager.loadFromPreferences()
    try await state.preferencesManager.syncPreferencesWithAppSettings(state)

    let count = FeedPerformanceArguments.integer("--feed-perf-count=", default: 400)
    var generator = FeedPerformanceData.Generator(art: art)
    var posts: [CachedFeedViewPost] = []
    posts.reserveCapacity(count)
    for index in 0..<count {
      let item = try FeedPerformanceData.decode(AppBskyFeedDefs.FeedViewPost.self, generator.feedItem(index))
      guard let cached = CachedFeedViewPost(from: item, feedType: "timeline") else { throw FixtureError.cachedPost }
      posts.append(cached)
    }

    let feedModel = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: state)
    feedModel.posts = posts
    let manager = FeedStateManager(appState: state, feedModel: feedModel, feedType: .timeline)
    manager.hasReachedEnd = true

    let context = SceneNavigationContext(appState: state, sceneID: UUID())
    print("FEED_PERF_FIXTURE_READY posts=\(posts.count)")
    return FeedPerformanceWorld(appState: state, context: context, container: container, client: client,
      feedStateManager: manager)
  }

  func runBenchmarkIfRequested() async {
    guard ProcessInfo.processInfo.arguments.contains("--feed-perf-autoscroll") else { return }
    // Let the first screen settle (initial snapshot, image decode) so pass 1 measures scrolling.
    try? await Task.sleep(for: .seconds(2))
    guard let collectionView = FeedScrollBenchmark.feedCollectionView() else {
      print("FEED_PERF_RESULT {\"error\":\"feed collection view not found\"}")
      return
    }
    let benchmark = FeedScrollBenchmark(
      collectionView: collectionView,
      speed: CGFloat(FeedPerformanceArguments.integer("--feed-perf-speed=", default: 3000)),
      passes: FeedPerformanceArguments.integer("--feed-perf-passes=", default: 3),
      itemCount: feedStateManager.posts.count)
    let result = await benchmark.run()
    result.publish()
  }

  private enum FixtureError: LocalizedError {
    case transport, cachedPost
    var errorDescription: String? {
      switch self {
      case .transport: "The fixture URLProtocol could not be registered."
      case .cachedPost: "A synthetic feed item could not be cached."
      }
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

private enum FeedPerformanceArguments {
  static func integer(_ prefix: String, default value: Int) -> Int {
    ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
      .flatMap { Int($0.dropFirst(prefix.count)) }
      .map { max(1, $0) } ?? value
  }
}

// MARK: - Scroll benchmark

@MainActor
private final class FeedScrollBenchmark {
  struct PassResult: Encodable {
    let direction: String
    let frames: Int
    let durationMs: Double
    let hitchCount: Int
    let hitchTimeMs: Double
    let hitchRatioMsPerS: Double
    let worstFrameMs: Double
    let p95FrameMs: Double
    /// Main-thread CPU time spent during the pass, divided by the rows scrolled through.
    let mainThreadCPUMsPerItem: Double
  }

  struct Result: Encodable {
    let content: String
    let itemCount: Int
    let speedPointsPerSecond: Double
    let nominalFrameMs: Double
    let contentHeight: Double
    let passes: [PassResult]
    let totalHitchRatioMsPerS: Double

    func publish() {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else { return }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-perf-result.json")
      try? data.write(to: url, options: .atomic)
      print("FEED_PERF_RESULT \(json)")
    }
  }

  private let collectionView: UICollectionView
  private let speed: CGFloat
  private let passes: Int
  private let itemCount: Int

  private var displayLink: CADisplayLink?
  private var direction: CGFloat = 1
  private var lastTimestamp: CFTimeInterval?
  private var frameDeltas: [Double] = []
  private var passContinuation: CheckedContinuation<Void, Never>?

  init(collectionView: UICollectionView, speed: CGFloat, passes: Int, itemCount: Int) {
    self.collectionView = collectionView
    self.speed = speed
    self.passes = passes
    self.itemCount = itemCount
  }

  /// User plus system CPU time of the calling thread, in milliseconds.
  private static func currentThreadCPUMs() -> Double {
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
    let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
    return user + system
  }

  static func feedCollectionView() -> UICollectionView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var best: UICollectionView?
    func visit(_ view: UIView) {
      if let collection = view as? UICollectionView,
         collection.contentSize.height > (best?.contentSize.height ?? 0) {
        best = collection
      }
      view.subviews.forEach(visit)
    }
    windows.forEach(visit)
    return best
  }

  func run() async -> Result {
    let nominal = 1.0 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
    var results: [PassResult] = []
    for pass in 0..<passes {
      direction = pass.isMultiple(of: 2) ? 1 : -1
      frameDeltas = []
      lastTimestamp = nil
      let cpuStart = Self.currentThreadCPUMs()
      await withCheckedContinuation { continuation in
        passContinuation = continuation
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
      let cpuMs = Self.currentThreadCPUMs() - cpuStart
      results.append(summarize(direction: direction > 0 ? "down" : "up", nominal: nominal,
        cpuMsPerItem: cpuMs / Double(max(itemCount, 1))))
      try? await Task.sleep(for: .milliseconds(500))
    }
    let totalDuration = results.reduce(0) { $0 + $1.durationMs }
    let totalHitch = results.reduce(0) { $0 + $1.hitchTimeMs }
    return Result(
      content: FeedPerformanceData.ContentKind.requested.rawValue,
      itemCount: itemCount,
      speedPointsPerSecond: Double(speed),
      nominalFrameMs: nominal * 1000,
      contentHeight: Double(collectionView.contentSize.height),
      passes: results,
      totalHitchRatioMsPerS: totalDuration > 0 ? totalHitch / (totalDuration / 1000) : 0)
  }

  @objc private func step(_ link: CADisplayLink) {
    let now = link.timestamp
    let delta = lastTimestamp.map { now - $0 } ?? link.duration
    if lastTimestamp != nil { frameDeltas.append(delta) }
    lastTimestamp = now

    let minY = -collectionView.adjustedContentInset.top
    let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height
      + collectionView.adjustedContentInset.bottom)
    // Advance by elapsed time, so a long frame jumps further just as a real fling does.
    var next = collectionView.contentOffset.y + direction * speed * CGFloat(delta)
    var finished = false
    if next >= maxY { next = maxY; finished = direction > 0 }
    if next <= minY { next = minY; finished = direction < 0 }
    collectionView.contentOffset.y = next
    if finished {
      link.invalidate()
      displayLink = nil
      passContinuation?.resume()
      passContinuation = nil
    }
  }

  private func summarize(direction: String, nominal: Double, cpuMsPerItem: Double) -> PassResult {
    // A frame is a hitch once it overruns by more than half a frame; its hitch time is the overrun.
    let hitches = frameDeltas.filter { $0 > nominal * 1.5 }
    let hitchTime = hitches.reduce(0) { $0 + ($1 - nominal) } * 1000
    let duration = frameDeltas.reduce(0, +) * 1000
    let sorted = frameDeltas.sorted()
    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
    return PassResult(
      direction: direction,
      frames: frameDeltas.count,
      durationMs: duration,
      hitchCount: hitches.count,
      hitchTimeMs: hitchTime,
      hitchRatioMsPerS: duration > 0 ? hitchTime / (duration / 1000) : 0,
      worstFrameMs: (sorted.last ?? 0) * 1000,
      p95FrameMs: p95,
      mainThreadCPUMsPerItem: cpuMsPerItem)
  }
}

// MARK: - Synthetic data

private enum FeedPerformanceData {
  static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }

  private static let isoFormatter = ISO8601DateFormatter()
  private static let referenceDate = Date()

  static func iso(minutesAgo: Double) -> String {
    isoFormatter.string(from: referenceDate.addingTimeInterval(-minutesAgo * 60))
  }

  static func cid(_ seed: String) -> String {
    CID.fromDAGCBOR(Data(seed.utf8)).string
  }

  /// Deterministic SplitMix64 so every run renders the same feed.
  struct Random {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int {
      range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func chance(_ percent: Int) -> Bool { int(0..<100) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0..<values.count)] }
  }

  /// Restricts the generated feed to one kind of row, to compare their costs.
  enum ContentKind: String {
    case mixed, text, images, links, quotes, threads, reposts

    static var requested: ContentKind {
      let prefix = "--feed-perf-content="
      return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
        .flatMap { ContentKind(rawValue: String($0.dropFirst(prefix.count))) } ?? .mixed
    }
  }

  struct Generator {
    let art: FeedPerformanceArt
    let content = ContentKind.requested
    var random = Random(seed: 0xCA7B_12D5)

    private static let words = """
      the quick brown fox jumps over lazy dogs while protocol federation keeps every timeline \
      moving across small servers and large ones alike with labels feeds lists threads replies \
      quotes images video links custom feeds moderation services relays and app views working \
      together so people can follow whoever they like and build the experience they want today
      """.split(separator: " ").map(String.init)

    private static let emoji = ["🦋", "🎉", "🌊", "🔥", "☕️", "👩🏽‍💻", "🏳️‍🌈", "🇨🇦"]

    mutating func feedItem(_ index: Int) -> [String: Any] {
      let post = postView(index: index, minutesAgo: Double(index) * 3 + 1)
      var item: [String: Any] = ["post": post]
      let wantsRepost = content == .reposts || (content == .mixed && random.chance(12))
      let wantsThread = content == .threads || (content == .mixed && random.chance(18))
      if wantsRepost {
        item["reason"] = [
          "$type": "app.bsky.feed.defs#reasonRepost",
          "by": profile(art.authors[random.int(0..<art.authors.count)]),
          "indexedAt": iso(minutesAgo: Double(index) * 3),
        ]
      } else if wantsThread {
        let root = postView(index: 100_000 + index, minutesAgo: Double(index) * 3 + 40, allowEmbeds: false)
        item["reply"] = [
          "root": root.merging(["$type": "app.bsky.feed.defs#postView"]) { $1 },
          "parent": root.merging(["$type": "app.bsky.feed.defs#postView"]) { $1 },
        ]
      }
      return item
    }

    mutating func postView(index: Int, minutesAgo: Double, allowEmbeds: Bool = true) -> [String: Any] {
      let author = art.authors[random.int(0..<art.authors.count)]
      let uri = "at://\(author.did)/app.bsky.feed.post/perf\(index)"
      let (text, facets) = postText()
      var record: [String: Any] = [
        "$type": "app.bsky.feed.post", "text": text, "createdAt": iso(minutesAgo: minutesAgo), "langs": ["en"],
      ]
      if !facets.isEmpty { record["facets"] = facets }
      var post: [String: Any] = [
        "uri": uri, "cid": cid("feed-perf-\(index)"), "author": profile(author), "record": record,
        "replyCount": random.int(0..<40), "repostCount": random.int(0..<120),
        "likeCount": random.int(0..<900), "quoteCount": random.int(0..<12),
        "indexedAt": iso(minutesAgo: minutesAgo),
      ]
      if allowEmbeds, let embed = embed(index: index) {
        post["embed"] = embed
      }
      return post
    }

    private mutating func postText() -> (String, [[String: Any]]) {
      if random.chance(4) {
        return ((0..<random.int(1..<4)).map { _ in random.pick(Self.emoji) }.joined(), [])
      }
      let wordCount = random.chance(30) ? random.int(40..<60) : random.int(4..<24)
      var text = (0..<wordCount).map { _ in random.pick(Self.words) }.joined(separator: " ")
      var facets: [[String: Any]] = []
      func appendFacet(_ fragment: String, feature: [String: Any]) {
        let start = text.utf8.count + 1
        text += " " + fragment
        facets.append([
          "index": ["byteStart": start, "byteEnd": start + fragment.utf8.count],
          "features": [feature],
        ])
      }
      if random.chance(25) {
        let target = random.pick(art.authors)
        appendFacet("@\(target.handle)", feature: ["$type": "app.bsky.richtext.facet#mention", "did": target.did])
      }
      if random.chance(20) {
        appendFacet("example.com/read/\(random.int(1..<999))",
          feature: ["$type": "app.bsky.richtext.facet#link", "uri": "https://example.com/read/\(random.int(1..<999))"])
      }
      if random.chance(20) {
        let tag = random.pick(["catbird", "swiftui", "atproto", "photography"])
        appendFacet("#\(tag)", feature: ["$type": "app.bsky.richtext.facet#tag", "tag": tag])
      }
      if random.chance(10) { text += " " + random.pick(Self.emoji) }
      return (text, facets)
    }

    private mutating func embed(index: Int) -> [String: Any]? {
      switch content {
      case .text, .threads, .reposts: return nil
      case .images: return imagesView(count: random.chance(75) ? 1 : random.int(2..<5))
      case .links: return externalView(index: index)
      case .quotes: return ["$type": "app.bsky.embed.record#view", "record": quotedRecord(index: index)]
      case .mixed: break
      }
      switch random.int(0..<100) {
      case 0..<30: return imagesView(count: 1)
      case 30..<40: return imagesView(count: random.int(2..<5))
      case 40..<55: return externalView(index: index)
      case 55..<65: return ["$type": "app.bsky.embed.record#view", "record": quotedRecord(index: index)]
      case 65..<70:
        return [
          "$type": "app.bsky.embed.recordWithMedia#view",
          "record": ["record": quotedRecord(index: index)],
          "media": imagesView(count: 1),
        ]
      default: return nil
      }
    }

    private mutating func imagesView(count: Int) -> [String: Any] {
      let images: [[String: Any]] = (0..<count).map { _ in
        let photo = random.pick(art.photos)
        return [
          "thumb": photo.url.absoluteString, "fullsize": photo.url.absoluteString,
          "alt": random.chance(50) ? "Synthetic benchmark image" : "",
          "aspectRatio": ["width": photo.width, "height": photo.height],
        ]
      }
      return ["$type": "app.bsky.embed.images#view", "images": images]
    }

    private mutating func externalView(index: Int) -> [String: Any] {
      var external: [String: Any] = [
        "uri": "https://example.com/articles/\(index)",
        "title": (0..<random.int(4..<12)).map { _ in random.pick(Self.words) }.joined(separator: " ").capitalized,
        "description": (0..<random.int(8..<30)).map { _ in random.pick(Self.words) }.joined(separator: " "),
      ]
      if random.chance(70) { external["thumb"] = random.pick(art.photos).url.absoluteString }
      return ["$type": "app.bsky.embed.external#view", "external": external]
    }

    private mutating func quotedRecord(index: Int) -> [String: Any] {
      let author = random.pick(art.authors)
      let uri = "at://\(author.did)/app.bsky.feed.post/perfquote\(index)"
      var record: [String: Any] = [
        "$type": "app.bsky.embed.record#viewRecord",
        "uri": uri, "cid": cid("feed-perf-quote-\(index)"), "author": profile(author),
        "value": [
          "$type": "app.bsky.feed.post",
          "text": (0..<random.int(6..<40)).map { _ in random.pick(Self.words) }.joined(separator: " "),
          "createdAt": iso(minutesAgo: 600),
        ] as [String: Any],
        "indexedAt": iso(minutesAgo: 600),
      ]
      if random.chance(40) { record["embeds"] = [imagesView(count: 1)] }
      return record
    }

    private func profile(_ author: FeedPerformanceArt.Author) -> [String: Any] {
      [
        "did": author.did, "handle": author.handle, "displayName": author.name,
        "avatar": author.avatar.absoluteString, "createdAt": iso(minutesAgo: 90_000),
      ]
    }
  }
}

// MARK: - Transport

/// Serves the preference and labeler reads the app makes at startup and refuses everything else.
private final class FeedPerformanceProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let isLocalGet = request.url?.host == "127.0.0.1" && (request.httpMethod ?? "GET").uppercased() == "GET"
    guard isLocalGet, let url = request.url, let body = Self.body(for: url.path) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static func body(for path: String) -> Data? {
    let object: [String: Any]
    switch path {
    case "/xrpc/app.bsky.actor.getPreferences":
      object = ["preferences": [
        ["$type": "app.bsky.actor.defs#adultContentPref", "enabled": false],
        [
          "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
          "items": [["id": "feedperffollowing", "type": "timeline", "value": "following", "pinned": true]],
        ],
      ]]
    case "/xrpc/app.bsky.labeler.getServices":
      object = ["views": []]
    default:
      return nil
    }
    return try? JSONSerialization.data(withJSONObject: object)
  }
}

// MARK: - Synthetic images

/// Deterministic, plainly synthetic JPEGs rendered once into the temporary directory, sized like
/// the thumbnails an AppView serves so decoding cost is representative.
private struct FeedPerformanceArt {
  struct Author {
    let did: String
    let handle: String
    let name: String
    let avatar: URL
  }

  struct Photo {
    let url: URL
    let width: Int
    let height: Int
  }

  let authors: [Author]
  let photos: [Photo]

  static func render() throws -> FeedPerformanceArt {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-perf-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ name: String, size: CGSize, hue: CGFloat, label: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { return url }
      let image = image(size: size, hue: hue, label: label)
      guard let data = image.jpegData(compressionQuality: 0.8) else { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: url, options: .atomic)
      return url
    }

    let names = ["Alice Rivera", "Ben Okafor", "Cara Lindqvist", "Dev Patel", "Eun-ji Park", "Farah Haddad",
      "Gus Moreau", "Hana Sato", "Ivo Novak", "Jade Morales", "Kofi Mensah", "Lena Fischer"]
    let authors = try names.enumerated().map { index, name in
      let first = name.split(separator: " ")[0].lowercased()
      return Author(
        did: "did:plc:feedperf\(first)", handle: "\(first).perf.test", name: name,
        avatar: try write("avatar-\(index).jpg", size: CGSize(width: 256, height: 256),
          hue: CGFloat(index) / CGFloat(names.count), label: String(name.prefix(1))))
    }
    let shapes: [(Int, Int)] = [(1000, 667), (667, 1000), (1000, 1000), (1000, 563), (750, 1000), (1000, 420)]
    let photos = try (0..<18).map { index in
      let (width, height) = shapes[index % shapes.count]
      return Photo(
        url: try write("photo-\(index).jpg", size: CGSize(width: width, height: height),
          hue: CGFloat(index) / 18, label: "SYNTHETIC \(index)"),
        width: width, height: height)
    }
    return FeedPerformanceArt(authors: authors, photos: photos)
  }

  private static func image(size: CGSize, hue: CGFloat, label: String) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      let context = renderer.cgContext
      let start = UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor
      let end = UIColor(hue: fmod(hue + 0.3, 1), saturation: 0.8, brightness: 0.6, alpha: 1).cgColor
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [start, end] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
      }
      UIColor.white.withAlphaComponent(0.2).setFill()
      context.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.1,
        width: size.width * 0.5, height: size.width * 0.5))
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let fontSize = min(size.width, size.height) * 0.14
      (label as NSString).draw(
        in: CGRect(x: 0, y: size.height / 2 - fontSize * 0.6, width: size.width, height: fontSize * 1.3),
        withAttributes: [
          .font: UIFont.systemFont(ofSize: fontSize, weight: UIFont.Weight.heavy), .foregroundColor: UIColor.white,
          .paragraphStyle: paragraph,
        ])
    }
  }
}
#endif
