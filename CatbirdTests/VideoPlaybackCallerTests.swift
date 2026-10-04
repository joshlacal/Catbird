#if os(iOS)
import AVFoundation
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Native hosting regressions for the production callbacks, with no media
/// downloads or shared audio-session activation. Run in the owner's app lane.
@MainActor
@Suite("Video playback caller lifecycle", .serialized)
struct VideoPlaybackCallerTests {
  @Test("A paused seed stays paused after an eligible metadata refresh remounts content")
  func pausedSeedSurvivesContentRemount() async throws {
    let seed = try videoPost(label: nil)
    let refreshed = try videoPost(label: "bot-account")
    let refreshedIdentity = try #require(VideoFeedItem(post: refreshed)).revealIdentity
    let players = (0..<3).map { _ in CallerFixturePlayer() }
    let pool = VideoFeedPlayerPool(players: players, audioSession: CallerFixtureAudioSession()) { _ in
      CallerFixtureItem()
    }
    let response = DelayedVideoFeedResponse()
    let intent = VideoFeedPlaybackIntent()
    var visibleIdentity: VideoFeedItem.RevealIdentity?
    let view = VideoFeedView(
      initialPost: seed,
      playerPool: pool,
      playbackIntent: intent,
      feedLoader: { _ in await response.wait() },
      contentVisibilityObserver: { visibleIdentity = $0.revealIdentity }
    )
    let appState = try await fixtureAppState()
    let window = host(view.environment(appState).environment(\.scenePhase, .active))
    defer {
      response.complete(with: [])
      window.isHidden = true
      window.rootViewController = nil
      pool.cleanup()
    }
    try await eventually { response.isWaiting && visibleIdentity != nil && pool.wantsPlayback }

    // The page button records this explicit action separately from pool holds.
    intent.setPlaybackRequested(false, for: seed.uri.uriString())
    try await eventually { !pool.wantsPlayback }
    #expect(!pool.wantsPlayback)
    let playCountWhenPaused = players[0].playCount
    response.complete(with: [.init(post: refreshed)])

    // Wait for the actual new ContentLabelManager/PlayerLayerView onAppear,
    // not only the merged array or changed moderation key.
    try await eventually { visibleIdentity == refreshedIdentity }
    await settle(window)
    #expect(!pool.wantsPlayback)
    #expect(players[0].playCount == playCountWhenPaused)
    #expect(players[0].timeControlStatus == .paused)
  }

  @Test("Delayed Show honors the selected video's request across a moderation hold", arguments: [
    (true, false), (false, false), (false, true)
  ])
  func delayedShowRespectsIntent(warnedSeed: Bool, explicitlyPaused: Bool) async throws {
    let seed = try videoPost(label: warnedSeed ? "nudity" : nil)
    let refreshed = try videoPost(label: "nudity")
    let refreshedIdentity = try #require(VideoFeedItem(post: refreshed)).revealIdentity
    let players = (0..<3).map { _ in CallerFixturePlayer() }
    let pool = VideoFeedPlayerPool(players: players, audioSession: CallerFixtureAudioSession()) { _ in
      CallerFixtureItem()
    }
    let intent = VideoFeedPlaybackIntent()
    let response = DelayedVideoFeedResponse()
    let preferences = DelayedVideoVisibility()
    var visibleIdentity: VideoFeedItem.RevealIdentity?
    let view = VideoFeedView(
      initialPost: seed,
      playerPool: pool,
      playbackIntent: intent,
      feedLoader: { _ in await response.wait() },
      contentVisibilityObserver: { visibleIdentity = $0.revealIdentity },
      moderationResolver: { labels, _ in
        if labels.contains(where: { $0.val == "nudity" }) { return await preferences.wait() }
        return .show
      }
    )
    let appState = try await fixtureAppState()
    let window = host(view.environment(appState).environment(\.scenePhase, .active))
    defer {
      response.complete(with: [])
      preferences.complete(with: .warn)
      window.isHidden = true
      window.rootViewController = nil
      pool.cleanup()
    }
    try await eventually { response.isWaiting && intent.selectedItemID == seed.uri.uriString() }
    if !warnedSeed {
      try await eventually { visibleIdentity != nil && pool.wantsPlayback }
      if explicitlyPaused {
        intent.setPlaybackRequested(false, for: seed.uri.uriString())
        try await eventually { !pool.wantsPlayback }
      }
    }
    let previousPlayCount = players[0].playCount
    response.complete(with: [.init(post: refreshed)])
    try await eventually { preferences.isWaiting && !pool.wantsPlayback }
    #expect(intent.requestsPlayback(for: seed.uri.uriString()) == !explicitlyPaused)
    #expect(pool.activeFeedIndex == 0)

    // Resolve the real warning manager's asynchronous visibility path using the
    // existing Show preference mapping; no new content policy is introduced.
    preferences.complete(with: ContentVisibility(fromPreference: "ignore"))
    try await eventually { visibleIdentity == refreshedIdentity }
    await settle(window)
    #expect(intent.selectedItemID == seed.uri.uriString())
    #expect(pool.activeFeedIndex == 0)
    #expect(pool.wantsPlayback == !explicitlyPaused)
    if explicitlyPaused {
      #expect(players[0].playCount == previousPlayCount)
      #expect(players[0].timeControlStatus == .paused)
    } else {
      #expect(players[0].playCount > previousPlayCount)
      #expect(players[0].timeControlStatus == .playing)
    }
  }

  @Test("Modern player setup preserves the same model across player recreation", arguments: [false, true])
  func recreationPreservesMute(isMuted: Bool) async throws {
    let url = URL(fileURLWithPath: "/video-caller-fixture/asset")
    let model = VideoModel(
      id: UUID().uuidString, url: url, type: .tenorGif(URI(uriString: url.absoluteString)), aspectRatio: 1
    )
    // Leave the true case at the fresh-model default.
    if !isMuted { model.isMuted = false; model.volume = 0.42 }
    let expectedVolume = model.volume
    let appState = try await fixtureAppState()
    var preparedPlayers: [CallerFixturePlayer] = []
    var registeredPlayers: Set<ObjectIdentifier> = []

    func makeView() -> some View {
      ModernVideoPlayerView(
        model: model, postID: model.id,
        preparePlayer: { _ in
          let player = CallerFixturePlayer()
          // Simulate VideoAssetManager's muted prepared-player defaults.
          player.isMuted = true
          player.volume = 0
          preparedPlayers.append(player)
          return player
        },
        registerPlayer: { actualModel, player in
          #expect(actualModel === model)
          #expect(actualModel.isMuted == isMuted)
          #expect(actualModel.volume == expectedVolume)
          #expect(player.isMuted == isMuted)
          #expect(player.volume == expectedVolume)
          registeredPlayers.insert(ObjectIdentifier(player))
        }
      )
      .environment(appState)
      .environment(\.scenePhase, .active)
    }

    let window = host(makeView())
    defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { registeredPlayers.count == 1 }
    window.rootViewController = UIHostingController(rootView: Color.clear)
    await settle(window)
    #expect(model.isMuted == isMuted)
    #expect(model.volume == expectedVolume)

    window.rootViewController = UIHostingController(rootView: makeView())
    await settle(window)
    try await eventually { registeredPlayers.count == 2 }
    #expect(preparedPlayers.count == 2)
    #expect(preparedPlayers[0] !== preparedPlayers[1])
    #expect(model.isMuted == isMuted)
    #expect(model.volume == expectedVolume)
  }

  private func fixtureAppState() async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://video-caller.invalid")))
    return AppState(userDID: "did:plc:videocallerfixture", client: client)
  }

  private func videoPost(label: String?) throws -> AppBskyFeedDefs.PostView {
    let uri = try ATProtocolURI(uriString: "at://did:plc:videocallerfixture/app.bsky.feed.post/selected")
    let base = PublicPostTestFixtures.makePostView(uri: uri, authorDID: try DID(didString: "did:plc:videocallerfixture"))
    let timestamp = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    return AppBskyFeedDefs.PostView(
      uri: uri, cid: base.cid, author: base.author, record: base.record,
      embed: .appBskyEmbedVideoView(.init(cid: base.cid, playlist: URI(uriString: "https://video.invalid/selected.m3u8"))),
      indexedAt: timestamp,
      labels: label.map { [.init(src: base.author.did, uri: URI(uriString: uri.uriString()), val: $0, cts: timestamp)] }
    )
  }

  private func host(_ view: some View) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = UIHostingController(rootView: view)
    window.isHidden = false
    window.layoutIfNeeded()
    return window
  }

  private func settle(_ window: UIWindow) async {
    for _ in 0..<12 {
      window.setNeedsLayout()
      window.layoutIfNeeded()
      await Task.yield()
    }
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("The production video callback did not reach the expected state")
    throw CallerFixtureError.timeout
  }
}

private enum CallerFixtureError: Error { case timeout }

@MainActor
private final class DelayedVideoFeedResponse {
  private var continuation: CheckedContinuation<([AppBskyFeedDefs.FeedViewPost], String?), Never>?
  var isWaiting: Bool { continuation != nil }

  func wait() async -> ([AppBskyFeedDefs.FeedViewPost], String?) {
    await withCheckedContinuation { continuation = $0 }
  }

  func complete(with posts: [AppBskyFeedDefs.FeedViewPost]) {
    continuation?.resume(returning: (posts, nil))
    continuation = nil
  }
}

@MainActor
private final class DelayedVideoVisibility {
  private var continuations: [CheckedContinuation<ContentVisibility, Never>] = []
  private var resolvedVisibility: ContentVisibility?
  var isWaiting: Bool { !continuations.isEmpty }

  func wait() async -> ContentVisibility {
    if let resolvedVisibility { return resolvedVisibility }
    return await withCheckedContinuation { continuations.append($0) }
  }

  func complete(with visibility: ContentVisibility) {
    resolvedVisibility = visibility
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume(returning: visibility) }
  }
}

private final class CallerFixtureAudioSession: VideoPlaybackAudioSession {
  func acquireVideoPlayback(owner: UUID) {}
  func releaseVideoPlayback(owner: UUID) {}
}

// Mutations are confined to the native suite's MainActor, like the pool fixtures.
private final class CallerFixtureItem: AVPlayerItem, @unchecked Sendable {
  override var status: AVPlayerItem.Status { .readyToPlay }
  override var duration: CMTime { CMTime(seconds: 10, preferredTimescale: 600) }
  override var loadedTimeRanges: [NSValue] { [] }
  init() { super.init(asset: AVMutableComposition(), automaticallyLoadedAssetKeys: [] as [String]) }
}

private final class CallerFixturePlayer: AVPlayer, @unchecked Sendable {
  var item: AVPlayerItem?
  var fixtureStatus: AVPlayer.TimeControlStatus = .paused
  var playCount = 0
  override var currentItem: AVPlayerItem? { item }
  override var timeControlStatus: AVPlayer.TimeControlStatus { fixtureStatus }
  override func replaceCurrentItem(with item: AVPlayerItem?) { self.item = item }
  override func play() { playCount += 1; fixtureStatus = .playing }
  override func pause() { fixtureStatus = .paused }
  override func addPeriodicTimeObserver(
    forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void
  ) -> Any { NSObject() }
  override func removeTimeObserver(_ observer: Any) {}
}
#endif
