//
//  VideoFeedPlayerPool.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import AVFoundation
import Foundation
import Observation
import OSLog

private let vidsStallSignposter = OSSignposter(subsystem: "blue.catbird.performance", category: "Intervals")

extension PerformanceSignposts {
  static func emitVidsStall() {
    vidsStallSignposter.emitEvent("VidsStall")
  }
}

/// Standalone observable holding playback progress so 10 Hz time ticks invalidate
/// only the progress bar, not the full VideoFeedPlayerPool or parent overlay views.
@MainActor
@Observable
public final class VideoFeedPlaybackProgress {
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0
  public private(set) var bufferedTime: Double = 0
  public private(set) var canSeek: Bool = false

  public func update(currentTime: Double, duration: Double, bufferedTime: Double, canSeek: Bool) {
    if self.currentTime != currentTime { self.currentTime = currentTime }
    if self.duration != duration { self.duration = duration }
    if self.bufferedTime != bufferedTime { self.bufferedTime = bufferedTime }
    if self.canSeek != canSeek { self.canSeek = canSeek }
  }

  public func reset() {
    if currentTime != 0 { currentTime = 0 }
    if duration != 0 { duration = 0 }
    if bufferedTime != 0 { bufferedTime = 0 }
    if canSeek != false { canSeek = false }
  }
}

/// Three players retain only the active video and its immediate neighbours.
@MainActor
@Observable
public final class VideoFeedPlayerPool {
  public enum PlaybackState: Equatable {
    case idle, loading, playing, paused, failed
  }

  public static let poolSize = 3
  @ObservationIgnored private var storage: [AVPlayer]?

  public var players: [AVPlayer] {
    if let storage { return storage }
    let initialized = (0..<Self.poolSize).map { _ in
      let player = AVPlayer()
      player.automaticallyWaitsToMinimizeStalling = true
      player.actionAtItemEnd = .none
      return player
    }
    storage = initialized
    return initialized
  }

  public private(set) var activeFeedIndex = 0
  public private(set) var playbackState: PlaybackState = .idle
  public private(set) var wantsPlayback = false

  @ObservationIgnored public let progress = VideoFeedPlaybackProgress()

  @ObservationIgnored public var currentTime: Double {
    get { progress.currentTime }
    set { progress.update(currentTime: newValue, duration: progress.duration, bufferedTime: progress.bufferedTime, canSeek: progress.canSeek) }
  }
  @ObservationIgnored public var duration: Double {
    get { progress.duration }
    set { progress.update(currentTime: progress.currentTime, duration: newValue, bufferedTime: progress.bufferedTime, canSeek: progress.canSeek) }
  }
  @ObservationIgnored public var bufferedTime: Double {
    get { progress.bufferedTime }
    set { progress.update(currentTime: progress.currentTime, duration: progress.duration, bufferedTime: newValue, canSeek: progress.canSeek) }
  }

  public var isPlaying: Bool { playbackState == .playing }
  public var canSeek: Bool { progress.canSeek }

  public var isMuted = false {
    didSet {
      storage?.forEach { $0.isMuted = isMuted }
      updateAudioSessionOwnership()
    }
  }

  @ObservationIgnored private var loadedURLs: [URL?]
  @ObservationIgnored private var feedIndices: [Int?]
  @ObservationIgnored private var generations = Array(repeating: UUID(), count: poolSize)
  @ObservationIgnored private var failedSlots: Set<Int> = []
  @ObservationIgnored private var loopObservers: [NSObjectProtocol?]
  @ObservationIgnored private var failureObservers: [NSObjectProtocol?]
  @ObservationIgnored private var stallObservers: [NSObjectProtocol?]
  @ObservationIgnored private var activeObservations: [NSKeyValueObservation] = []
  @ObservationIgnored private var timeObserverPlayer: AVPlayer?
  @ObservationIgnored private var timeObserverToken: Any?
  @ObservationIgnored private var observationID = UUID()
  @ObservationIgnored private var seekID = UUID()
  @ObservationIgnored private let makeItem: (URL) -> AVPlayerItem
  @ObservationIgnored private let audioSession: any VideoPlaybackAudioSession
  @ObservationIgnored private let audioOwner = UUID()
  @ObservationIgnored private var ownsAudioSession = false
  @ObservationIgnored private var isReconcilingAudioSuspended = false

  public convenience init() {
    self.init(players: nil, audioSession: AudioSessionManager.shared) {
      AVPlayerItem(asset: AVURLAsset(url: $0))
    }
  }

  /// Injection keeps lifecycle tests local and independent of streaming services.
  init(
    players: [AVPlayer]? = nil, audioSession: any VideoPlaybackAudioSession,
    makeItem: @escaping (URL) -> AVPlayerItem
  ) {
    if let players {
      precondition(players.count == Self.poolSize)
      self.storage = players
      for player in players {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none
      }
    } else {
      self.storage = nil
    }
    self.makeItem = makeItem
    self.audioSession = audioSession
    loadedURLs = Array(repeating: nil, count: Self.poolSize)
    feedIndices = Array(repeating: nil, count: Self.poolSize)
    loopObservers = Array(repeating: nil, count: Self.poolSize)
    failureObservers = Array(repeating: nil, count: Self.poolSize)
    stallObservers = Array(repeating: nil, count: Self.poolSize)
  }

  isolated deinit {
    cleanup()
  }

  public func player(for feedIndex: Int) -> AVPlayer {
    players[slotIndex(for: feedIndex)]
  }

  public func slotIndex(for feedIndex: Int) -> Int {
    let raw = feedIndex % Self.poolSize
    return raw >= 0 ? raw : raw + Self.poolSize
  }

  private func pausePlayers() {
    seekID = UUID()
    storage?.forEach { $0.pause() }
  }

  public func prewarm(activeIndex: Int, items: [(index: Int, url: URL)]) {
    isReconcilingAudioSuspended = true
    defer {
      isReconcilingAudioSuspended = false
    }
    if activeFeedIndex != activeIndex {
      pausePlayers()
      resetProgress()
      activeFeedIndex = activeIndex
    }
    let neighbours = items.filter { $0.index >= 0 && abs($0.index - activeIndex) <= 1 }
    for slot in 0..<Self.poolSize {
      if let item = neighbours.first(where: { slotIndex(for: $0.index) == slot }) {
        prepareSlot(slot, feedIndex: item.index, url: item.url)
      } else {
        clearSlot(slot)
      }
    }
    refreshPlaybackState()
    updateForwardBufferDurations()
  }

  public func clearSlot(_ slot: Int) {
    generations[slot] = UUID()
    if let observer = loopObservers[slot] { NotificationCenter.default.removeObserver(observer) }
    if let observer = failureObservers[slot] { NotificationCenter.default.removeObserver(observer) }
    if let observer = stallObservers[slot] { NotificationCenter.default.removeObserver(observer) }
    loopObservers[slot] = nil
    failureObservers[slot] = nil
    stallObservers[slot] = nil
    if slot == slotIndex(for: activeFeedIndex) {
      removeActiveObservers()
      wantsPlayback = false
      playbackState = .idle
      resetProgress()
    }
    if let currentPlayers = storage, currentPlayers.indices.contains(slot) {
      currentPlayers[slot].pause()
      currentPlayers[slot].currentItem?.cancelPendingSeeks()
      currentPlayers[slot].replaceCurrentItem(with: nil)
    }
    loadedURLs[slot] = nil
    feedIndices[slot] = nil
    failedSlots.remove(slot)
    if !isReconcilingAudioSuspended {
      updateAudioSessionOwnership()
    }
  }

  private func prepareSlot(_ slot: Int, feedIndex: Int, url: URL) {
    let currentPlayers = players
    if feedIndices[slot] == feedIndex, loadedURLs[slot] == url,
       let item = currentPlayers[slot].currentItem, item.status != .failed,
       !failedSlots.contains(slot) {
      return
    }
    clearSlot(slot)
    let player = currentPlayers[slot]
    let item = makeItem(url)
    let isActive = (slot == slotIndex(for: activeFeedIndex))
    item.preferredForwardBufferDuration = isActive ? 0 : 2
    player.isMuted = isMuted
    player.replaceCurrentItem(with: item)
    loadedURLs[slot] = url
    feedIndices[slot] = feedIndex
    let generation = generations[slot]

    loopObservers[slot] = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self, weak item] _ in
      Task { @MainActor [weak self, weak item] in
        guard let self, let item,
              self.isCurrent(slot: slot, feedIndex: feedIndex, generation: generation, item: item),
              self.wantsPlayback else { return }
        self.seek(to: 0, at: feedIndex)
      }
    }
    failureObservers[slot] = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self, let item, self.generations[slot] == generation,
              self.storage?[slot].currentItem === item else { return }
        self.failedSlots.insert(slot)
        if self.activeFeedIndex == feedIndex {
          self.storage?[slot].pause()
          self.refreshPlaybackState()
        }
      }
    }
    stallObservers[slot] = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
    ) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self, let item, self.generations[slot] == generation,
              self.storage?[slot].currentItem === item else { return }
        PerformanceSignposts.emitVidsStall()
      }
    }
  }

  public func play(feedIndex: Int) {
    guard feedIndex == activeFeedIndex else { return }
    let slot = slotIndex(for: feedIndex)
    let currentPlayers = players
    guard feedIndices[slot] == feedIndex, let item = currentPlayers[slot].currentItem else {
      pauseAll()
      playbackState = .idle
      return
    }
    for index in currentPlayers.indices where index != slot { currentPlayers[index].pause() }
    wantsPlayback = true
    setupActiveObservers(for: currentPlayers[slot], item: item)
    if item.status != .failed && !failedSlots.contains(slot) {
      updateAudioSessionOwnership()
      currentPlayers[slot].play()
    }
    refreshPlaybackState()
    updateForwardBufferDurations()
  }

  public func pauseAll() {
    wantsPlayback = false
    seekID = UUID()
    storage?.forEach { $0.pause() }
    refreshPlaybackState()
  }

  public func togglePlayPause() {
    if wantsPlayback {
      pauseAll()
    } else if playbackState == .failed {
      retry(feedIndex: activeFeedIndex)
    } else {
      play(feedIndex: activeFeedIndex)
    }
  }

  public func toggleMute() { isMuted.toggle() }

  public func retry(feedIndex: Int) {
    let slot = slotIndex(for: feedIndex)
    guard feedIndex == activeFeedIndex, feedIndices[slot] == feedIndex,
          let url = loadedURLs[slot] else { return }
    clearSlot(slot)
    prepareSlot(slot, feedIndex: feedIndex, url: url)
    play(feedIndex: feedIndex)
  }

  public func seek(to seconds: Double, at feedIndex: Int) {
    let slot = slotIndex(for: feedIndex)
    guard feedIndex == activeFeedIndex, feedIndices[slot] == feedIndex, seconds.isFinite,
          let player = storage?[slot],
          let item = player.currentItem, item.status == .readyToPlay,
          let target = VideoPlaybackTimeline.seekTime(seconds, duration: item.duration.seconds),
          !failedSlots.contains(slot) else { return }
    let generation = generations[slot]
    let requestID = UUID()
    seekID = requestID
    player.seek(
      to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
    ) { [weak self, weak item] finished in
      Task { @MainActor [weak self, weak item] in
        guard finished, let self, let item, self.seekID == requestID,
              self.isCurrent(slot: slot, feedIndex: feedIndex, generation: generation, item: item) else { return }
        self.currentTime = target
        if self.wantsPlayback { player.play() }
        self.refreshPlaybackState()
      }
    }
  }

  private func isCurrent(slot: Int, feedIndex: Int, generation: UUID, item: AVPlayerItem) -> Bool {
    activeFeedIndex == feedIndex && feedIndices[slot] == feedIndex &&
      generations[slot] == generation && storage?[slot].currentItem === item
  }

  public func cleanup() {
    removeActiveObservers()
    for slot in 0..<Self.poolSize { clearSlot(slot) }
    wantsPlayback = false
    playbackState = .idle
    resetProgress()
    updateAudioSessionOwnership()
  }

  private func updateAudioSessionOwnership() {
    guard !isReconcilingAudioSuspended else { return }
    let slot = slotIndex(for: activeFeedIndex)
    let shouldOwnAudio = wantsPlayback && !isMuted && feedIndices[slot] == activeFeedIndex &&
      storage?[slot].currentItem != nil && storage?[slot].currentItem?.status != .failed &&
      !failedSlots.contains(slot)
    guard shouldOwnAudio != ownsAudioSession else { return }
    ownsAudioSession = shouldOwnAudio
    if shouldOwnAudio {
      audioSession.acquireVideoPlayback(owner: audioOwner)
    } else {
      audioSession.releaseVideoPlayback(owner: audioOwner)
    }
  }

  private func updateForwardBufferDurations() {
    let activeSlot = slotIndex(for: activeFeedIndex)
    for slot in 0..<Self.poolSize {
      guard let player = storage?[slot], let item = player.currentItem else { continue }
      let target: TimeInterval = (slot == activeSlot) ? 0 : 2
      if item.preferredForwardBufferDuration != target {
        item.preferredForwardBufferDuration = target
      }
    }
  }
}

extension VideoFeedPlayerPool {
  private func setupActiveObservers(for player: AVPlayer, item: AVPlayerItem) {
    guard timeObserverPlayer !== player || activeObservations.isEmpty else { return }
    removeActiveObservers()
    timeObserverPlayer = player
    let identifier = observationID
    let refresh: @Sendable () -> Void = { [weak self] in
      if Thread.isMainThread {
        MainActor.assumeIsolated {
          guard let self, self.observationID == identifier else { return }
          self.refreshPlaybackState()
        }
      } else {
        Task { @MainActor [weak self] in
          guard let self, self.observationID == identifier else { return }
          self.refreshPlaybackState()
        }
      }
    }
    activeObservations = [
      item.observe(\.status, options: [.initial, .new]) { _, _ in refresh() },
      item.observe(\.duration, options: [.new]) { _, _ in refresh() },
      item.observe(\.loadedTimeRanges, options: [.new]) { _, _ in refresh() },
      player.observe(\.timeControlStatus, options: [.new]) { _, _ in refresh() }
    ]
    timeObserverToken = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.observationID == identifier else { return }
        self.refreshProgress()
      }
    }
  }

  private func refreshProgress() {
    let slot = slotIndex(for: activeFeedIndex)
    guard feedIndices[slot] == activeFeedIndex, let player = storage?[slot], let item = player.currentItem else {
      progress.reset()
      return
    }
    let duration = VideoPlaybackTimeline.duration(item.duration.seconds)
    let currentTime = VideoPlaybackTimeline.time(player.currentTime().seconds, duration: duration)
    let bufferedTime = item.loadedTimeRanges.reduce(0) { result, value in
      let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
      return max(result, VideoPlaybackTimeline.time(end, duration: duration))
    }
    let canSeek = duration > 0 && item.status == .readyToPlay && !failedSlots.contains(slot)
    progress.update(currentTime: currentTime, duration: duration, bufferedTime: bufferedTime, canSeek: canSeek)
  }

  private func refreshPlaybackState() {
    defer {
      if !isReconcilingAudioSuspended {
        updateAudioSessionOwnership()
      }
    }
    let slot = slotIndex(for: activeFeedIndex)
    guard feedIndices[slot] == activeFeedIndex, let player = storage?[slot], let item = player.currentItem else {
      if playbackState != .idle { playbackState = .idle }
      progress.reset()
      return
    }
    refreshProgress()

    let newState: PlaybackState
    if item.status == .failed || failedSlots.contains(slot) {
      wantsPlayback = false
      player.pause()
      newState = .failed
    } else if !wantsPlayback {
      newState = .paused
    } else if item.status != .readyToPlay || player.timeControlStatus != .playing {
      newState = .loading
    } else {
      newState = .playing
    }
    if playbackState != newState {
      playbackState = newState
    }
  }

  private func resetProgress() {
    progress.reset()
  }

  private func removeActiveObservers() {
    observationID = UUID()
    seekID = UUID()
    activeObservations.removeAll()
    if let token = timeObserverToken, let player = timeObserverPlayer {
      player.removeTimeObserver(token)
    }
    timeObserverToken = nil
    timeObserverPlayer = nil
  }
}

/// Bounds every value used by playback controls before creating times or frames.
enum VideoPlaybackTimeline {
  static func duration(_ value: Double) -> Double {
    value.isFinite && value > 0 ? value : 0
  }

  static func time(_ value: Double, duration: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(0, value), self.duration(duration))
  }

  static func progress(_ time: Double, duration: Double) -> Double {
    let total = self.duration(duration)
    return total > 0 ? self.time(time, duration: total) / total : 0
  }

  static func seekTime(_ value: Double, duration: Double) -> Double? {
    guard value.isFinite, self.duration(duration) > 0 else { return nil }
    return time(value, duration: duration)
  }
}
