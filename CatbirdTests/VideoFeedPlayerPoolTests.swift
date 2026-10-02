import AVFoundation
import Testing
@testable import Catbird

@MainActor
@Suite("Video feed player lifecycle")
struct VideoFeedPlayerPoolTests {
  private struct Fixture {
    let pool: VideoFeedPlayerPool
    let players: [FixtureVideoPlayer]
    let items: [FixtureVideoItem]
  }

  private func fixture() -> Fixture {
    let players = (0..<3).map { _ in FixtureVideoPlayer() }
    let items = (0..<8).map { _ in FixtureVideoItem() }
    let pool = VideoFeedPlayerPool(players: players) { url in
      items[Int(url.lastPathComponent)!]
    }
    return Fixture(pool: pool, players: players, items: items)
  }

  private func sources(_ indices: [Int]) -> [(index: Int, url: URL)] {
    indices.map { ($0, URL(fileURLWithPath: "/video-fixture/\($0)")) }
  }

  @Test("Playback readiness and waiting are not reported as playing")
  func playbackReadiness() async {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    let items = fixture.items
    items[0].fixtureStatus = .unknown
    pool.prewarm(activeIndex: 0, items: sources([0, 1]))
    pool.play(feedIndex: 0)
    #expect(pool.wantsPlayback)
    #expect(pool.playbackState == .loading)
    #expect(!pool.isPlaying)
    items[0].updateStatus(.readyToPlay)
    players[0].updateTimeControlStatus(.waitingToPlayAtSpecifiedRate)
    await drainCallbacks()
    #expect(pool.playbackState == .loading)
    players[0].updateTimeControlStatus(.playing)
    await drainCallbacks()
    #expect(pool.isPlaying)
    players[0].updateTimeControlStatus(.waitingToPlayAtSpecifiedRate)
    await drainCallbacks()
    #expect(pool.playbackState == .loading)
    pool.pauseAll()
    #expect(pool.playbackState == .paused)
    #expect(!pool.wantsPlayback)
    pool.cleanup()
  }

  @Test("Same-URL failed items are recreated and retry resumes intent")
  func failedItemRetry() {
    let players = (0..<3).map { _ in FixtureVideoPlayer() }
    var created: [FixtureVideoItem] = []
    let pool = VideoFeedPlayerPool(players: players) { _ in
      let item = FixtureVideoItem()
      created.append(item)
      return item
    }
    pool.prewarm(activeIndex: 0, items: sources([0]))
    created[0].fixtureStatus = .failed
    pool.play(feedIndex: 0)
    #expect(pool.playbackState == .failed)
    #expect(!pool.wantsPlayback)
    pool.retry(feedIndex: 0)
    #expect(created.count == 2)
    #expect(players[0].currentItem === created[1])
    #expect(pool.wantsPlayback)
    pool.cleanup()
  }

  @Test("Queued seek completion cannot restart a recycled or paused slot")
  func lateSeekCompletion() async {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    pool.prewarm(activeIndex: 0, items: sources([0, 1]))
    pool.play(feedIndex: 0)
    pool.seek(to: 20, at: 0)
    let firstCompletion = players[0].seekCompletions[0]
    pool.prewarm(activeIndex: 3, items: sources([2, 3, 4]))
    pool.play(feedIndex: 3)
    let playCount = players[0].playCount
    firstCompletion(true)
    await drainCallbacks()
    #expect(players[0].playCount == playCount)
    #expect(pool.currentTime == 0)
    pool.seek(to: 10, at: 3)
    let secondCompletion = players[0].seekCompletions[1]
    pool.pauseAll()
    secondCompletion(true)
    await drainCallbacks()
    #expect(players[0].playCount == playCount)
    #expect(!pool.wantsPlayback)
    pool.cleanup()
  }

  @Test("Only the latest active seek can resume and stale page gestures are ignored")
  func seeksRespectActiveIdentity() async {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    pool.prewarm(activeIndex: 0, items: sources([0, 1]))
    pool.play(feedIndex: 0)
    pool.seek(to: 10, at: 0)
    pool.seek(to: 20, at: 0)
    pool.seek(to: 15, at: 3) // Same modulo slot, different feed item.
    pool.seek(to: .nan, at: 0)
    #expect(players[0].seekCompletions.count == 2)
    let playCount = players[0].playCount
    players[0].seekCompletions[0](true)
    await drainCallbacks()
    #expect(players[0].playCount == playCount)
    players[0].seekCompletions[1](true)
    await drainCallbacks()
    #expect(players[0].playCount == playCount + 1)
    pool.cleanup()
  }

  @Test("A pending end notification cannot loop after its page is deactivated")
  func inactiveLoop() async {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    let items = fixture.items
    pool.prewarm(activeIndex: 0, items: sources([0, 1]))
    pool.play(feedIndex: 0)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: items[0])
    pool.prewarm(activeIndex: 1, items: sources([0, 1, 2]))
    pool.play(feedIndex: 1)
    await drainCallbacks()
    #expect(players[0].seekCompletions.isEmpty)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: items[1])
    await drainCallbacks()
    #expect(players[1].seekCompletions.count == 1)
    pool.pauseAll()
    let playCount = players[1].playCount
    players[1].seekCompletions[0](true)
    await drainCallbacks()
    #expect(players[1].playCount == playCount)
    pool.cleanup()
  }

  @Test("Returning to the first video clears the now-unused third slot")
  func clearsUnusedSlot() {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    pool.prewarm(activeIndex: 2, items: sources([1, 2, 3]))
    pool.prewarm(activeIndex: 0, items: sources([0, 1]))
    #expect(players[2].currentItem == nil)
    #expect(pool.duration == 60)
    pool.cleanup()
    #expect(players.allSatisfy { $0.currentItem == nil })
    #expect(pool.playbackState == .idle)
    #expect(pool.duration == 0)
  }

  @Test("Cleanup removes callbacks and failed-to-end state permits retry")
  func failureAndCleanup() async {
    let fixture = fixture()
    let pool = fixture.pool
    let players = fixture.players
    let items = fixture.items
    pool.prewarm(activeIndex: 0, items: sources([0]))
    pool.play(feedIndex: 0)
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: items[0])
    await drainCallbacks()
    #expect(pool.playbackState == .failed)
    #expect(!pool.canSeek)
    pool.cleanup()
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: items[0])
    await drainCallbacks()
    #expect(players[0].seekCompletions.isEmpty)
    #expect(players[0].periodicObserver == nil)
    #expect(pool.playbackState == .idle)
  }

  @Test("Releasing an old page does not pause a pool-owned player")
  func sharedLayerTeardown() {
    let player = FixtureVideoPlayer()
    #if os(iOS)
    let view = PlayerContainer(frame: .zero)
    #elseif os(macOS)
    let view = PlayerContainerMac(frame: .zero)
    view.wantsLayer = true
    #endif
    view.shouldLoop = false
    view.pausesOnDismantle = false
    view.player = player
    let pauseCount = player.pauseCount
    view.cleanup()
    #expect(player.pauseCount == pauseCount)
    #expect(view.player == nil)
    view.cleanup()
    #expect(player.pauseCount == pauseCount)
  }

  @Test("Default layer ownership still pauses its player during teardown")
  func ownedLayerTeardown() {
    let player = FixtureVideoPlayer()
    #if os(iOS)
    let view = PlayerContainer(frame: .zero)
    #elseif os(macOS)
    let view = PlayerContainerMac(frame: .zero)
    view.wantsLayer = true
    #endif
    view.player = player
    view.cleanup()
    #expect(player.pauseCount == 1)
  }

  @Test("Pool deallocation removes observers and releases loaded items")
  func deallocation() {
    let players = (0..<3).map { _ in FixtureVideoPlayer() }
    var pool: VideoFeedPlayerPool? = VideoFeedPlayerPool(players: players) { _ in FixtureVideoItem() }
    weak var releasedPool = pool
    pool?.prewarm(activeIndex: 0, items: sources([0, 1]))
    pool?.play(feedIndex: 0)
    pool = nil
    #expect(releasedPool == nil)
    #expect(players.allSatisfy { $0.currentItem == nil && $0.periodicObserver == nil })
  }

  private func drainCallbacks() async {
    for _ in 0..<5 { await Task.yield() }
  }
}

@Suite("Video feed timeline bounds")
struct VideoFeedPlayerTimelineTests {
  @Test("Invalid and overrun values cannot escape the track bounds")
  func bounds() {
    for value in [Double.nan, .infinity, -.infinity, -12, 0] {
      #expect(VideoPlaybackTimeline.duration(value) == 0)
      #expect(VideoPlaybackTimeline.progress(value, duration: 60) == 0)
      #expect(VideoPlaybackTimeline.progress(10, duration: value) == 0)
    }
    #expect(VideoPlaybackTimeline.progress(90, duration: 60) == 1)
    #expect(VideoPlaybackTimeline.progress(15, duration: 60) == 0.25)
    #expect(VideoPlaybackTimeline.seekTime(.nan, duration: 60) == nil)
    #expect(VideoPlaybackTimeline.seekTime(4, duration: .infinity) == nil)
    #expect(VideoPlaybackTimeline.seekTime(-4, duration: 60) == 0)
    #expect(VideoPlaybackTimeline.seekTime(64, duration: 60) == 60)
  }
}

// AVFoundation declares these classes Sendable. Test mutations and callbacks are
// confined to the suite's MainActor; neither double schedules background work.
private final class FixtureVideoItem: AVPlayerItem, @unchecked Sendable {
  var fixtureStatus: AVPlayerItem.Status = .readyToPlay
  override var status: AVPlayerItem.Status { fixtureStatus }
  override var duration: CMTime { CMTime(seconds: 60, preferredTimescale: 600) }
  override var loadedTimeRanges: [NSValue] { [] }

  init() { super.init(asset: AVMutableComposition(), automaticallyLoadedAssetKeys: [] as [String]) }

  func updateStatus(_ value: AVPlayerItem.Status) {
    willChangeValue(forKey: "status")
    fixtureStatus = value
    didChangeValue(forKey: "status")
  }
}

private final class FixtureVideoPlayer: AVPlayer, @unchecked Sendable {
  var fixtureItem: AVPlayerItem?
  var fixtureTimeControlStatus: AVPlayer.TimeControlStatus = .paused
  var playCount = 0
  var pauseCount = 0
  var seekCompletions: [(Bool) -> Void] = []
  var periodicObserver: ((CMTime) -> Void)?
  override var currentItem: AVPlayerItem? { fixtureItem }
  override var timeControlStatus: AVPlayer.TimeControlStatus { fixtureTimeControlStatus }

  func updateTimeControlStatus(_ value: AVPlayer.TimeControlStatus) {
    willChangeValue(forKey: "timeControlStatus")
    fixtureTimeControlStatus = value
    didChangeValue(forKey: "timeControlStatus")
  }

  override func replaceCurrentItem(with item: AVPlayerItem?) { fixtureItem = item }
  override func play() { playCount += 1 }
  override func pause() { pauseCount += 1; fixtureTimeControlStatus = .paused }
  override func currentTime() -> CMTime { .zero }
  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: @escaping @Sendable (Bool) -> Void
  ) {
    seekCompletions.append(completionHandler)
  }
  override func addPeriodicTimeObserver(
    forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void
  ) -> Any {
    periodicObserver = block
    return NSObject()
  }
  override func removeTimeObserver(_ observer: Any) { periodicObserver = nil }
}
