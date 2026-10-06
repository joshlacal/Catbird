//
//  VideoFeedPlayerPool.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import AVFoundation
import Foundation
import Observation

/// Three players retain only the active video and its immediate neighbours.
@MainActor
@Observable
public final class VideoFeedPlayerPool {
  public enum PlaybackState: Equatable {
    case idle, loading, playing, paused, failed
  }

  public static let poolSize = 3
  public private(set) var players: [AVPlayer]
  public private(set) var activeFeedIndex = 0
  public private(set) var playbackState: PlaybackState = .idle
  public private(set) var wantsPlayback = false
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0
  public private(set) var bufferedTime: Double = 0

  public var isPlaying: Bool { playbackState == .playing }
  public var canSeek: Bool { duration > 0 && playbackState != .failed && playbackState != .idle }

  public var isMuted = false {
    didSet {
      players.forEach { $0.isMuted = isMuted }
      updateAudioSessionOwnership()
    }
  }

  @ObservationIgnored private var loadedURLs: [URL?]
  @ObservationIgnored private var feedIndices: [Int?]
  @ObservationIgnored private var generations = Array(repeating: UUID(), count: poolSize)
  @ObservationIgnored private var failedSlots: Set<Int> = []
  @ObservationIgnored private var loopObservers: [NSObjectProtocol?]
  @ObservationIgnored private var failureObservers: [NSObjectProtocol?]
  @ObservationIgnored private var activeObservations: [NSKeyValueObservation] = []
  @ObservationIgnored private var timeObserverPlayer: AVPlayer?
  @ObservationIgnored private var timeObserverToken: Any?
  @ObservationIgnored private var observationID = UUID()
  @ObservationIgnored private var seekID = UUID()
  @ObservationIgnored private let makeItem: (URL) -> AVPlayerItem
  @ObservationIgnored private let audioSession: any VideoPlaybackAudioSession
  @ObservationIgnored private let audioOwner = UUID()
  @ObservationIgnored private var ownsAudioSession = false

  public convenience init() {
    self.init(players: (0..<Self.poolSize).map { _ in AVPlayer() }, audioSession: AudioSessionManager.shared) {
      AVPlayerItem(asset: AVURLAsset(url: $0))
    }
  }

  /// Injection keeps lifecycle tests local and independent of streaming services.
  init(
    players: [AVPlayer], audioSession: any VideoPlaybackAudioSession,
    makeItem: @escaping (URL) -> AVPlayerItem
  ) {
    precondition(players.count == Self.poolSize)
    self.players = players
    self.makeItem = makeItem
    self.audioSession = audioSession
    loadedURLs = Array(repeating: nil, count: Self.poolSize)
    feedIndices = Array(repeating: nil, count: Self.poolSize)
    loopObservers = Array(repeating: nil, count: Self.poolSize)
    failureObservers = Array(repeating: nil, count: Self.poolSize)
    for player in players {
      player.automaticallyWaitsToMinimizeStalling = true
      player.actionAtItemEnd = .none
    }
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

  public func prewarm(activeIndex: Int, items: [(index: Int, url: URL)]) {
    if activeFeedIndex != activeIndex {
      pauseAll()
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
  }

  public func clearSlot(_ slot: Int) {
    guard players.indices.contains(slot) else { return }
    generations[slot] = UUID()
    if let observer = loopObservers[slot] { NotificationCenter.default.removeObserver(observer) }
    if let observer = failureObservers[slot] { NotificationCenter.default.removeObserver(observer) }
    loopObservers[slot] = nil
    failureObservers[slot] = nil
    if slot == slotIndex(for: activeFeedIndex) {
      removeActiveObservers()
      wantsPlayback = false
      playbackState = .idle
      resetProgress()
    }
    players[slot].pause()
    players[slot].currentItem?.cancelPendingSeeks()
    players[slot].replaceCurrentItem(with: nil)
    loadedURLs[slot] = nil
    feedIndices[slot] = nil
    failedSlots.remove(slot)
    updateAudioSessionOwnership()
  }

  private func prepareSlot(_ slot: Int, feedIndex: Int, url: URL) {
    if feedIndices[slot] == feedIndex, loadedURLs[slot] == url,
       let item = players[slot].currentItem, item.status != .failed,
       !failedSlots.contains(slot) {
      return
    }
    clearSlot(slot)
    let player = players[slot]
    let item = makeItem(url)
    item.preferredForwardBufferDuration = 2
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
      Task { @MainActor [weak self, weak item] in
        guard let self, let item, self.generations[slot] == generation,
              self.players[slot].currentItem === item else { return }
        self.failedSlots.insert(slot)
        if self.activeFeedIndex == feedIndex {
          self.players[slot].pause()
          self.refreshPlaybackState()
        }
      }
    }
  }

  public func play(feedIndex: Int) {
    guard feedIndex == activeFeedIndex else { return }
    let slot = slotIndex(for: feedIndex)
    guard feedIndices[slot] == feedIndex, let item = players[slot].currentItem else {
      pauseAll()
      playbackState = .idle
      return
    }
    for index in players.indices where index != slot { players[index].pause() }
    wantsPlayback = true
    setupActiveObservers(for: players[slot], item: item)
    if item.status != .failed && !failedSlots.contains(slot) {
      updateAudioSessionOwnership()
      players[slot].play()
    }
    refreshPlaybackState()
  }

  public func pauseAll() {
    wantsPlayback = false
    seekID = UUID()
    players.forEach { $0.pause() }
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
          let item = players[slot].currentItem, item.status == .readyToPlay,
          let target = VideoPlaybackTimeline.seekTime(seconds, duration: item.duration.seconds),
          !failedSlots.contains(slot) else { return }
    let player = players[slot]
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
      generations[slot] == generation && players[slot].currentItem === item
  }

  public func cleanup() {
    removeActiveObservers()
    for slot in players.indices { clearSlot(slot) }
    wantsPlayback = false
    playbackState = .idle
    resetProgress()
    updateAudioSessionOwnership()
  }

  private func updateAudioSessionOwnership() {
    let slot = slotIndex(for: activeFeedIndex)
    let shouldOwnAudio = wantsPlayback && !isMuted && feedIndices[slot] == activeFeedIndex &&
      players[slot].currentItem != nil && players[slot].currentItem?.status != .failed &&
      !failedSlots.contains(slot)
    guard shouldOwnAudio != ownsAudioSession else { return }
    ownsAudioSession = shouldOwnAudio
    if shouldOwnAudio {
      audioSession.acquireVideoPlayback(owner: audioOwner)
    } else {
      audioSession.releaseVideoPlayback(owner: audioOwner)
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
      Task { @MainActor [weak self] in
        guard let self, self.observationID == identifier else { return }
        self.refreshPlaybackState()
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
      Task { @MainActor [weak self] in
        guard let self, self.observationID == identifier else { return }
        self.refreshPlaybackState()
      }
    }
  }

  private func refreshPlaybackState() {
    defer { updateAudioSessionOwnership() }
    let slot = slotIndex(for: activeFeedIndex)
    guard feedIndices[slot] == activeFeedIndex, let item = players[slot].currentItem else {
      playbackState = .idle
      resetProgress()
      return
    }
    duration = VideoPlaybackTimeline.duration(item.duration.seconds)
    currentTime = VideoPlaybackTimeline.time(players[slot].currentTime().seconds, duration: duration)
    bufferedTime = item.loadedTimeRanges.reduce(0) { result, value in
      let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
      return max(result, VideoPlaybackTimeline.time(end, duration: duration))
    }
    if item.status == .failed || failedSlots.contains(slot) {
      wantsPlayback = false
      players[slot].pause()
      playbackState = .failed
    } else if !wantsPlayback {
      playbackState = .paused
    } else if item.status != .readyToPlay || players[slot].timeControlStatus != .playing {
      playbackState = .loading
    } else {
      playbackState = .playing
    }
  }

  private func resetProgress() {
    currentTime = 0
    duration = 0
    bufferedTime = 0
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
