//
//  VideoFeedPlayerPool.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import AVFoundation
import Foundation
import Observation
import os

/// Fixed pool of 3 reusable AVPlayer instances for seamless vertical video feed playback.
@MainActor
@Observable
public final class VideoFeedPlayerPool {
  public static let poolSize = 3

  public private(set) var players: [AVPlayer]
  private var loadedURLs: [URL?]
  private var loopObservers: [NSObjectProtocol?]

  public var isMuted: Bool = false {
    didSet {
      for player in players {
        player.isMuted = isMuted
      }
    }
  }

  public private(set) var activeFeedIndex: Int = 0
  public private(set) var isPlaying: Bool = false
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0
  public private(set) var bufferedTime: Double = 0

  private var timeObserverPlayer: AVPlayer?
  private var timeObserverToken: Any?
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "VideoFeedPlayerPool")

  public init() {
    var initialPlayers: [AVPlayer] = []
    var initialURLs: [URL?] = []
    var initialObservers: [NSObjectProtocol?] = []

    for _ in 0..<Self.poolSize {
      let player = AVPlayer()
      player.automaticallyWaitsToMinimizeStalling = true
      player.actionAtItemEnd = .none
      initialPlayers.append(player)
      initialURLs.append(nil)
      initialObservers.append(nil)
    }

    self.players = initialPlayers
    self.loadedURLs = initialURLs
    self.loopObservers = initialObservers

    logger.info("VideoFeedPlayerPool: Initialized fixed pool of \(Self.poolSize) AVPlayers")
  }

  deinit {
    // Teardown observers if called on dealloc
  }

  /// Returns the pool player assigned to the specified feed item index (modulo 3).
  public func player(for feedIndex: Int) -> AVPlayer {
    let slot = slotIndex(for: feedIndex)
    return players[slot]
  }

  public func slotIndex(for feedIndex: Int) -> Int {
    let raw = feedIndex % Self.poolSize
    return raw >= 0 ? raw : raw + Self.poolSize
  }

  /// Prewarms the active item, previous item (if any), and next item (if any).
  public func prewarm(activeIndex: Int, items: [(index: Int, url: URL)]) {
    self.activeFeedIndex = activeIndex

    let activeSlot = slotIndex(for: activeIndex)

    // Prepare current item
    if let current = items.first(where: { $0.index == activeIndex }) {
      prepareSlot(activeSlot, url: current.url)
    } else {
      clearSlot(activeSlot)
    }

    // Prepare previous item
    if activeIndex > 0 {
      let prevSlot = slotIndex(for: activeIndex - 1)
      if prevSlot != activeSlot {
        if let previous = items.first(where: { $0.index == activeIndex - 1 }) {
          prepareSlot(prevSlot, url: previous.url)
        } else {
          clearSlot(prevSlot)
        }
      }
    }

    // Prepare next item
    let nextSlot = slotIndex(for: activeIndex + 1)
    if nextSlot != activeSlot {
      if let next = items.first(where: { $0.index == activeIndex + 1 }) {
        prepareSlot(nextSlot, url: next.url)
      } else {
        clearSlot(nextSlot)
      }
    }
  }

  public func clearSlot(_ slot: Int) {
    guard slot >= 0, slot < Self.poolSize else { return }

    if let oldObserver = loopObservers[slot] {
      NotificationCenter.default.removeObserver(oldObserver)
      loopObservers[slot] = nil
    }

    if players[slot] === timeObserverPlayer {
      removeTimeObserver()
    }

    players[slot].pause()
    players[slot].replaceCurrentItem(with: nil)
    loadedURLs[slot] = nil
  }
  private func prepareSlot(_ slot: Int, url: URL) {
    guard slot >= 0, slot < Self.poolSize else { return }

    if loadedURLs[slot] == url, players[slot].currentItem != nil {
      // Already prepared with this URL
      return
    }

    // Remove old loop observer
    if let oldObserver = loopObservers[slot] {
      NotificationCenter.default.removeObserver(oldObserver)
      loopObservers[slot] = nil
    }

    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    let player = players[slot]
    player.isMuted = isMuted
    player.replaceCurrentItem(with: playerItem)
    loadedURLs[slot] = url

    // Setup looping observer
    let observer = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak player] _ in
      player?.seek(to: .zero)
      player?.play()
    }
    loopObservers[slot] = observer
    logger.debug("VideoFeedPlayerPool: Slot \(slot) prepared for URL \(url.lastPathComponent)")
  }

  /// Starts playback of the active feed item, pausing all other slots.
  public func play(feedIndex: Int) {
    self.activeFeedIndex = feedIndex
    let activeSlot = slotIndex(for: feedIndex)

    for i in 0..<Self.poolSize {
      if i == activeSlot {
        if players[i].currentItem != nil {
          players[i].isMuted = isMuted
          players[i].play()
          self.isPlaying = true
          setupTimeObserver(for: players[i])
          logger.debug("VideoFeedPlayerPool: Playing active slot \(i) for feed index \(feedIndex)")
        } else {
          players[i].pause()
          self.isPlaying = false
          removeTimeObserver()
        }
      } else {
        players[i].pause()
      }
    }
  }

  /// Pauses playback on all pool players.
  public func pauseAll() {
    removeTimeObserver()
    for player in players {
      player.pause()
    }
    self.isPlaying = false
  }

  /// Toggles playback on the active player.
  public func togglePlayPause() {
    let activeSlot = slotIndex(for: activeFeedIndex)
    let player = players[activeSlot]

    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      player.play()
      isPlaying = true
    }
  }

  /// Toggles global mute state across all players in the pool.
  public func toggleMute() {
    isMuted.toggle()
  }

  /// Seeks the active player to a specific second and resumes playback if currently playing.
  public func seek(to seconds: Double, at feedIndex: Int) {
    let slot = slotIndex(for: feedIndex)
    let player = players[slot]
    let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)

    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      guard let self = self else { return }
      self.currentTime = seconds
      if self.isPlaying {
        player.play()
      }
    }
  }

  private func setupTimeObserver(for player: AVPlayer) {
    removeTimeObserver()

    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserverPlayer = player
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
      guard let self = self, let player = player else { return }

      self.currentTime = time.seconds.isFinite ? time.seconds : 0

      if let currentItem = player.currentItem {
        let dur = currentItem.duration.seconds
        self.duration = dur.isFinite ? dur : 0

        if let timeRange = currentItem.loadedTimeRanges.first?.timeRangeValue {
          let buffered = (timeRange.start + timeRange.duration).seconds
          self.bufferedTime = buffered.isFinite ? buffered : 0
        }
      }
    }
  }

  private func removeTimeObserver() {
    if let token = timeObserverToken, let player = timeObserverPlayer {
      player.removeTimeObserver(token)
      timeObserverToken = nil
      timeObserverPlayer = nil
    }
  }

  /// Cleans up observers, pauses all players, and releases player items.
  public func cleanup() {
    removeTimeObserver()

    for i in 0..<Self.poolSize {
      if let observer = loopObservers[i] {
        NotificationCenter.default.removeObserver(observer)
        loopObservers[i] = nil
      }
      players[i].pause()
      players[i].replaceCurrentItem(with: nil)
      loadedURLs[i] = nil
    }

    self.isPlaying = false
    self.currentTime = 0
    self.duration = 0
    self.bufferedTime = 0
    logger.info("VideoFeedPlayerPool: Released all 3 players, observers, and player items")
  }
}
