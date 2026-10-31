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
//    --feed-perf-trending         serve trending topics, topic previews and trending videos, so the
//                                 timeline shows its trending interstitial at index 6
//    --feed-perf-navigation       host the feed in the app's NavigationStack and destinations, to
//                                 exercise taps and transitions (adds a navigation bar; not for timing)
//    --native-feed-rows=off       render every post with the hosted SwiftUI row instead of the native
//                                 UIKit cell, to compare the two (read by `NativeFeedRows.isEnabled`)
//    --feed-perf-line-spacing=<s> the "Line spacing" setting: tight, normal (default) or relaxed
//
//  The benchmark scrolls the production feed controller at a constant speed with a display
//  link and records how far each frame overran its deadline. Results are printed as
//  `FEED_PERF_RESULT <json>` and written to `<tmp>/feed-perf-result.json`.
//

#if DEBUG && os(iOS)
import AVFoundation
import Nuke
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
          FeedPerformanceFeedHost(world: world, path: $path)
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

/// The feed alone for benchmarks, or inside the app's navigation stack for interaction checks.
private struct FeedPerformanceFeedHost: View {
  let world: FeedPerformanceWorld
  @Binding var path: NavigationPath

  var body: some View {
    if ProcessInfo.processInfo.arguments.contains("--feed-perf-navigation") {
      let tabPath = world.context.navigationManager.pathBinding(for: 0)
      NavigationStack(path: tabPath) {
        feed(tabPath)
          .navigationTitle("Following")
          .toolbarTitleDisplayMode(.large)
          .navigationDestination(for: NavigationDestination.self) { destination in
            NavigationHandler.viewForDestination(
              destination, path: tabPath, appState: world.appState, selectedTab: .constant(0))
          }
      }
    } else {
      feed($path)
    }
  }

  private func feed(_ path: Binding<NavigationPath>) -> some View {
    FeedCollectionViewWrapper(stateManager: world.feedStateManager, navigationPath: path)
      .accessibilityIdentifier("feedperf.feed")
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
    if FeedPerformanceTrending.isRequested {
      let clip = try await FeedPerformanceTrending.writeClip()
      FeedPerformanceProtocol.install(trending: try FeedPerformanceTrending.responses(art: art, clip: clip))
      try FeedPerformanceTrending.seedImageData(art: art)
    }
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
    if let lineSpacing = FeedPerformanceArguments.string("--feed-perf-line-spacing="),
       ["tight", "normal", "relaxed"].contains(lineSpacing) {
      state.fontManager.lineSpacing = lineSpacing
    }

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
    if FeedPerformanceTrending.isRequested {
      let trendingRequestID = "\(viewerDID)|timeline|\(appSettings.showTrendingTopics)|\(appSettings.showTrendingVideos)"
      await manager.loadTrendingIfNeeded(requestID: trendingRequestID, displayScale: 3.0)
    }

    let context = SceneNavigationContext(appState: state, sceneID: UUID())
    print("FEED_PERF_FIXTURE_READY posts=\(posts.count)")
    return FeedPerformanceWorld(appState: state, context: context, container: container, client: client,
      feedStateManager: manager)
  }

  func runBenchmarkIfRequested() async {
    guard ProcessInfo.processInfo.arguments.contains("--feed-perf-autoscroll") else { return }
    // Let the first screen settle (initial snapshot, image decode) so pass 1 measures scrolling.
    try? await Task.sleep(for: .seconds(2))

    // Strategy B: Synchronize autoscroll to await warmup completion before initiating scroll
    let expectsTrending = ProcessInfo.processInfo.arguments.contains("--feed-perf-trending")
    await MainActor.run {
      let warmup = FeedFirstUseWarmup.shared
      let needsWarmup = expectsTrending ? warmup.trendingPreparationCount == 0 : warmup.nativePreparationCount == 0
      if needsWarmup, let collectionView = FeedScrollBenchmark.feedCollectionView() {
        var responder: UIResponder? = collectionView
        while let next = responder?.next {
          if let fcvc = next as? FeedCollectionViewControllerIntegrated {
            fcvc.prepareFirstUseIfIdleForTesting(
              warmup,
              now: ProcessInfo.processInfo.systemUptime,
              visibleSince: ProcessInfo.processInfo.systemUptime - 2.0)
            break
          }
          responder = next
        }
      }
    }
    let warmupDeadline = ProcessInfo.processInfo.systemUptime + 10.0
    while ProcessInfo.processInfo.systemUptime < warmupDeadline {
      let isWarmed = await MainActor.run {
        expectsTrending
          ? FeedFirstUseWarmup.shared.trendingPreparationCount > 0
          : FeedFirstUseWarmup.shared.nativePreparationCount > 0
      }
      if isWarmed { break }
      try? await Task.sleep(for: .milliseconds(25))
    }
    // Cancel any in-flight background prefetch so network/model mutations do not interrupt the scroll window
    await MainActor.run {
      appState.cancelTopicPreviewPrefetch(owner: .timeline)
    }
    try? await Task.sleep(for: .milliseconds(100))

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
  static func string(_ prefix: String) -> String? {
    ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
  }

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
    /// Main-thread CPU time between consecutive display-link callbacks.
    let p95FrameCPUMs: Double
    let maxFrameCPUMs: Double
    /// The row at `probeItemIndex` (the trending interstitial with `--feed-perf-trending`, otherwise
    /// a post) entering the viewport: the frames from three before to six after it first intersects.
    let probeEntry: ProbeEntry?
  }

  struct ProbeEntry: Encodable {
    let frames: Int
    let worstFrameMs: Double
    let peakFrameCPUMs: Double
    let windowCPUMs: Double
  }

  struct Result: Encodable {
    let content: String
    let itemCount: Int
    let speedPointsPerSecond: Double
    let nominalFrameMs: Double
    let contentHeight: Double
    let probeItemIndex: Int
    let probeItemIsTrending: Bool
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
  private var frameCPU: [Double] = []
  private var lastFrameCPUMs: Double?
  /// Index into `frameDeltas` of the first frame after the probe row became visible.
  private var probeEntryFrame: Int?
  private var probeWasVisible = false
  /// The production controller inserts the trending interstitial at index 6 of a headerless feed.
  static let probeItemIndex = 6
  private var passContinuation: CheckedContinuation<Void, Never>?

  init(collectionView: UICollectionView, speed: CGFloat, passes: Int, itemCount: Int) {
    self.collectionView = collectionView
    self.speed = speed
    self.passes = passes
    self.itemCount = itemCount
  }

  private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
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
      frameCPU = []
      lastTimestamp = nil
      lastFrameCPUMs = nil
      probeEntryFrame = nil
      probeWasVisible = isProbeVisible()
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
      probeItemIndex: Self.probeItemIndex,
      probeItemIsTrending: FeedPerformanceTrending.isRequested,
      passes: results,
      totalHitchRatioMsPerS: totalDuration > 0 ? totalHitch / (totalDuration / 1000) : 0)
  }

  @objc private func step(_ link: CADisplayLink) {
    let now = link.timestamp
    let delta = lastTimestamp.map { now - $0 } ?? link.duration
    let cpuNow = Self.currentThreadCPUMs()
    if lastTimestamp != nil {
      frameDeltas.append(delta)
      frameCPU.append(cpuNow - (lastFrameCPUMs ?? cpuNow))
    }
    lastTimestamp = now
    lastFrameCPUMs = cpuNow
    // The previous frame's layout ran after the last callback, so a row that is visible now was
    // created during the frame just recorded.
    let probeVisible = isProbeVisible()
    if probeVisible && !probeWasVisible && probeEntryFrame == nil {
      probeEntryFrame = max(0, frameDeltas.count - 1)
    }
    probeWasVisible = probeVisible

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

  private func isProbeVisible() -> Bool {
    let indexPath = IndexPath(item: Self.probeItemIndex, section: 0)
    guard collectionView.numberOfSections > 0,
          collectionView.numberOfItems(inSection: 0) > Self.probeItemIndex,
          let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return false }
    return attributes.frame.intersects(collectionView.bounds)
  }

  private func probeEntry() -> ProbeEntry? {
    guard let entry = probeEntryFrame, !frameDeltas.isEmpty else { return nil }
    let window = max(0, entry - 3)...min(frameDeltas.count - 1, entry + 6)
    return ProbeEntry(
      frames: window.count,
      worstFrameMs: (frameDeltas[window].max() ?? 0) * 1000,
      peakFrameCPUMs: frameCPU[window].max() ?? 0,
      windowCPUMs: frameCPU[window].reduce(0, +))
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
      mainThreadCPUMsPerItem: cpuMsPerItem,
      p95FrameCPUMs: Self.percentile(frameCPU, 0.95),
      maxFrameCPUMs: frameCPU.max() ?? 0,
      probeEntry: probeEntry())
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
/// With `--feed-perf-trending` it also serves the trending reads.
private final class FeedPerformanceProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var trendingResponses: [String: Data] = [:]

  static func install(trending: [String: Data]) {
    lock.withLock { trendingResponses = trending }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let isLocalGet = request.url?.host == "127.0.0.1" && (request.httpMethod ?? "GET").uppercased() == "GET"
    guard isLocalGet, let url = request.url, let body = Self.body(for: url) else {
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

  private static func body(for url: URL) -> Data? {
    let object: [String: Any]
    switch url.path {
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
      let feed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "feed" }?.value
      let key = FeedPerformanceTrending.responseKey(path: url.path, feed: feed)
      return lock.withLock { trendingResponses[key] }
    }
    return try? JSONSerialization.data(withJSONObject: object)
  }
}

// MARK: - Synthetic trending content

/// Six trending topics (each with a preview feed of image posts and three participants) and ten
/// trending videos, matching what `getTrends` and The Vids return. The JSON is served by
/// `FeedPerformanceProtocol` through the production loading path. Trending art must use https
/// URLs (the preview policy rejects anything else), so its bytes are seeded into the image
/// pipeline's data cache under those URLs: images still go through disk read, decode and resize.
private enum FeedPerformanceTrending {
  static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--feed-perf-trending") }

  private static let artPathPrefix = "/feed-perf-art/"
  private static let creatorDID = "did:plc:feedperftrends"

  private static func artURL(_ file: URL) -> String {
    "https://127.0.0.1\(artPathPrefix)\(file.lastPathComponent)"
  }

  @MainActor
  static func seedImageData(art: FeedPerformanceArt) throws {
    let cache = ImageLoadingManager.shared.pipeline.cache
    for file in art.authors.map(\.avatar) + art.photos.map(\.url) {
      guard let url = URL(string: artURL(file)) else { continue }
      let data = try Data(contentsOf: file)
      cache.storeCachedData(data, for: ImageRequest(url: url))
      guard let image = UIImage(data: data) else { continue }
      let container = ImageContainer(image: image)
      cache[ImageRequest(url: url)] = container

      for scale in [1.0, 2.0, 3.0] as [CGFloat] {
        let cardReqNormal = TrendingTopicImageRequests.request(
          url, size: TrendingTopicImageRequests.cardSize, displayScale: scale, priority: .normal)
        cache[cardReqNormal] = container
        let cardReqLow = TrendingTopicImageRequests.request(
          url, size: TrendingTopicImageRequests.cardSize, displayScale: scale, priority: .low)
        cache[cardReqLow] = container

        let avatarReqNormal = TrendingTopicImageRequests.avatarRequest(
          url, size: TrendingTopicImageRequests.avatarSize, displayScale: scale, priority: .normal)
        cache[avatarReqNormal] = container
        let avatarReqLow = TrendingTopicImageRequests.avatarRequest(
          url, size: TrendingTopicImageRequests.avatarSize, displayScale: scale, priority: .low)
        cache[avatarReqLow] = container

        for cardWidth in [TrendingInterstitialMetrics.videoCardWidth, TrendingInterstitialMetrics.videoCardAccessibilityWidth] {
          let thumbSize = CGSize(width: cardWidth, height: TrendingInterstitialMetrics.videoThumbnailHeight)
          let thumbReqNormal = TrendingTopicImageRequests.request(
            url, size: thumbSize, displayScale: scale, priority: .normal)
          cache[thumbReqNormal] = container
          let thumbReqLow = TrendingTopicImageRequests.request(
            url, size: thumbSize, displayScale: scale, priority: .low)
          cache[thumbReqLow] = container
        }

        for avatarSide in [16.0, 18.0, 20.0, 22.0, 24.0, 26.0, 36.0, 40.0, 42.0] as [CGFloat] {
          if let resizedReq = AsyncProfileImage.resizedRequest(for: url, sizeInPoints: avatarSide, displayScale: scale) {
            cache[resizedReq] = container
          }
        }
      }
    }
  }

  static func responseKey(path: String, feed: String?) -> String {
    feed.map { "\(path)?feed=\($0)" } ?? path
  }

  private static let topics: [(name: String, category: String?, description: String?)] = [
    ("Aurora Watch", "science", "Northern lights are visible much farther south than usual tonight."),
    ("Cup Final", "sports", "Extra time, a goal-line save and a penalty shootout decide the cup."),
    ("Budget Vote", "politics", "Lawmakers debate the spending bill ahead of the midnight deadline."),
    ("Indie Game Fest", "video-games", nil),
    ("Album Drop", "music", "Fans react to the surprise release and its closing track."),
    ("Heat Dome", "weather", "Record temperatures stretch across the region for a fifth day."),
  ]

  /// A two-second H.264 clip every trending video plays, so The Vids opens on a playable item.
  @MainActor
  static func writeClip() async throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-perf-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("trending-clip.mp4")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let partial = directory.appendingPathComponent("trending-clip-partial.mp4")
    try? FileManager.default.removeItem(at: partial)

    let width = 360, height = 640, frames = 60
    let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var buffer: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
        throw CocoaError(.fileWriteUnknown)
      }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        // BGRA: a solid color that shifts each frame, so playback is visible.
        var pattern = UInt32(0xFF00_0000) | UInt32(40 + frame * 3) << 16 | UInt32(90) << 8 | UInt32(200 - frame * 2)
        memset_pattern4(base, &pattern, CVPixelBufferGetBytesPerRow(buffer) * height)
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    try FileManager.default.moveItem(at: partial, to: url)
    return url
  }

  static func responses(art: FeedPerformanceArt, clip: URL) throws -> [String: Data] {
    var random = FeedPerformanceData.Random(seed: 0x7E2D_1A9C)
    func profile(_ author: FeedPerformanceArt.Author) -> [String: Any] {
      ["did": author.did, "handle": author.handle, "displayName": author.name, "avatar": artURL(author.avatar),
       "createdAt": FeedPerformanceData.iso(minutesAgo: 90_000)]
    }
    func post(uri: String, author: FeedPerformanceArt.Author, text: String, embed: [String: Any],
      minutesAgo: Double) -> [String: Any] {
      ["post": [
        "uri": uri, "cid": FeedPerformanceData.cid(uri), "author": profile(author),
        "record": ["$type": "app.bsky.feed.post", "text": text, "createdAt": FeedPerformanceData.iso(minutesAgo: minutesAgo),
          "langs": ["en"]] as [String: Any],
        "embed": embed, "replyCount": random.int(0..<40), "repostCount": random.int(0..<200),
        "likeCount": random.int(0..<2000), "quoteCount": random.int(0..<20),
        "indexedAt": FeedPerformanceData.iso(minutesAgo: minutesAgo),
      ] as [String: Any]]
    }

    var result: [String: Data] = [:]
    var trends: [[String: Any]] = []
    for (index, topic) in topics.enumerated() {
      let slug = "topic\(index)"
      var trend: [String: Any] = [
        "topic": slug, "displayName": topic.name, "link": "/profile/\(creatorDID)/feed/\(slug)",
        "startedAt": FeedPerformanceData.iso(minutesAgo: Double(30 + index * 25)),
        "postCount": [48_200, 12_900, 7_350, 2_100, 31_800, 960][index], "status": "hot",
        "actors": (0..<3).map { profile(art.authors[(index * 3 + $0) % art.authors.count]) },
      ]
      if let category = topic.category { trend["category"] = category }
      if let description = topic.description { trend["description"] = description }
      trends.append(trend)

      let previews = (0..<6).map { offset -> [String: Any] in
        let author = art.authors[(index * 5 + offset) % art.authors.count]
        let photo = art.photos[(index * 4 + offset) % art.photos.count]
        let image: [String: Any] = [
          "thumb": artURL(photo.url), "fullsize": artURL(photo.url), "alt": "",
          "aspectRatio": ["width": photo.width, "height": photo.height],
        ]
        return post(uri: "at://\(author.did)/app.bsky.feed.post/trend\(index)-\(offset)", author: author,
          text: "\(topic.name) preview \(offset + 1)",
          embed: ["$type": "app.bsky.embed.images#view", "images": [image]], minutesAgo: Double(offset * 4 + 2))
      }
      let feedURI = "at://\(creatorDID)/app.bsky.feed.generator/\(slug)"
      result[responseKey(path: "/xrpc/app.bsky.feed.getFeed", feed: feedURI)] =
        try JSONSerialization.data(withJSONObject: ["feed": previews])
    }
    result[responseKey(path: "/xrpc/app.bsky.unspecced.getTrends", feed: nil)] =
      try JSONSerialization.data(withJSONObject: ["trends": trends])

    let videos = (0..<10).map { index -> [String: Any] in
      let author = art.authors[(index * 7 + 3) % art.authors.count]
      let photo = art.photos[(index * 5 + 1) % art.photos.count]
      let uri = "at://\(author.did)/app.bsky.feed.post/vid\(index)"
      let video: [String: Any] = [
        "$type": "app.bsky.embed.video#view", "cid": FeedPerformanceData.cid("feed-perf-video-\(index)"),
        "playlist": clip.absoluteString,
        "thumbnail": artURL(photo.url), "aspectRatio": ["width": 9, "height": 16],
      ]
      if index.isMultiple(of: 3) {
        return post(uri: uri, author: author, text: "Clip \(index + 1)", embed: video.merging(["alt": "Synthetic clip \(index + 1)"]) { $1 },
          minutesAgo: Double(index * 9 + 5))
      }
      return post(uri: uri, author: author, text: "Clip \(index + 1)", embed: video, minutesAgo: Double(index * 9 + 5))
    }
    result[responseKey(path: "/xrpc/app.bsky.feed.getFeed", feed: TrendingVideosSection.thevidsURI)] =
      try JSONSerialization.data(withJSONObject: ["feed": videos])
    return result
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
