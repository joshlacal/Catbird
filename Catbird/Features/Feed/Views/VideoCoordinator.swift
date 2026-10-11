//
//  VideoCoordinator.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import AVKit
import Foundation
import Observation
import SwiftUI
import OSLog
import os.log

/// Manages video playback and state across the app

@MainActor
final class VideoCoordinator {
  static let shared = VideoCoordinator()

  // MARK: - Properties
  private(set) var activeVideos:
    [String: (model: VideoModel, player: AVPlayer, lastPlaybackTime: CMTime)] = [:]
  internal var visibleVideoIDs: Set<String> = []
  private var currentlyPlayingVideoId: String?
  private var loopingWrappers: [String: LoopingPlayerWrapper] = [:]
  private var statusObservers: [String: Task<Void, Never>] = [:]
  private var playbackObservers: [String: NSKeyValueObservation] = [:]
  private let playbackAudioOwner = UUID()
  private var ownsPlaybackAudio = false
  private var isApplicationActive = true

  private let logger = Logger(subsystem: "blue.catbird", category: "VideoCoordinator")

  // MARK: - Loop Observers & LRU
  private var loopObserverTokens: [String: NSObjectProtocol] = [:]
  private var lastVisibleTimes: [String: Date] = [:]
  private let maxNonVisibleVideos = 6
  private var fullscreenActiveVideoIDs: Set<String> = []
  private let signposter = OSSignposter(subsystem: "blue.catbird.performance", category: "VideoRegistry")

  // App settings for autoplay preference
  weak var appSettings: AppSettings? {
    didSet {
      // When app settings change, update playback states to respect new autoplay setting
      if appSettings !== oldValue {
        updatePlaybackStates()
      }
    }
  }

  // Cache for video positions with automatic eviction
  private let positionCache: NSCache<NSString, NSNumber> = {
    let cache = NSCache<NSString, NSNumber>()
    cache.countLimit = 100  // Adjust based on your needs
    return cache
  }()

  // MARK: - Stream Preservation
  private var preservedStreams: [String: Date] = [:]
  private var markedForCleanup: Set<String> = []
  private let streamPreservationTime: TimeInterval = 30.0  // Keep streams for 30 seconds

  // MARK: - Picture in Picture
  private var pipActiveVideoIDs: Set<String> = []
  // Strong references that keep the presenting AVPlayerViewController and its
  // delegate alive after the fullscreen cover is dismantled, so an active PiP
  // session (and its delegate callbacks) survives leaving the source view.
  private var pipRetainedObjects: [String: [AnyObject]] = [:]

  // MARK: - Initialization
  private init() {
    setupBackgroundHandling()

    // Don't configure audio session at init - let it stay ambient
    // Only configure when we actually need to play unmuted audio
  }

  // MARK: - Autoplay Check

  /// Check if videos should autoplay based on user settings
  private func shouldAutoplayVideos() -> Bool {
    // Default to false if settings are not available (safer fallback)
    return appSettings?.autoplayVideos ?? false
  }

  // MARK: - Video Management

  /// Register a video to be managed by the coordinator
  // Update your register method to use the looping wrapper
  func register(_ model: VideoModel, player: AVPlayer) {
    // Re-registering while PiP owns the player would force-mute it and stomp
    // playback state; the existing registration is still valid.
    if pipActiveVideoIDs.contains(model.id) {
      logger.debug("📺 Skipping re-register for PiP-active video \(model.id)")
      return
    }

    // P099: Skip re-registering if already managed on the exact same player instance
    if let existing = activeVideos[model.id], existing.player === player {
      logger.debug("📹 Player for \(model.id) already registered on the same instance, updating state")
      player.isMuted = model.isMuted
      player.volume = model.isMuted ? 0 : model.volume
      lastVisibleTimes[model.id] = Date()
      updatePlaybackStates()
      return
    }

    logger.debug(
      "📹 Registering video: \(model.id) - type: \(model.type.isGif ? "GIF" : "HLS") - URL: \(model.url.absoluteString)"
    )

    // A fresh model defaults to muted. Re-registering a returning model must
    // preserve the user's choice even though its old audio lease was retired.
    player.isMuted = model.isMuted
    player.volume = model.isMuted ? 0 : model.volume
    player.preventsDisplaySleepDuringVideoPlayback = false

    // Check cache for last position
    let lastPosition: CMTime
    if let seconds = positionCache.object(forKey: model.id as NSString)?.doubleValue {
      lastPosition = CMTime(seconds: seconds, preferredTimescale: 600)
      logger.debug("📹 Restored cached position for \(model.id): \(seconds)s")
    } else {
      lastPosition = .zero
      logger.debug("📹 Starting from beginning for \(model.id)")
    }

    // Create a looping wrapper for GIFs
    if model.type.isGif {
      logger.debug("🎬 Configuring GIF player for \(model.id)")
      // For GIFs, try to use looping wrapper for smooth playback
      /*
       * DISABLED for performance/architecture reasons:
       * LoopingPlayerWrapper creates a new AVQueuePlayer, but the View holds the original AVPlayer.
       * This causes the view to show a static/stale player while the wrapper plays in background.
       * Falling back to manual looping (configureGifPlayer) works on the same instance and is now optimized.
       */
      if false && loopingWrappers[model.id] == nil {
        // Give the player a moment to load if needed, then try wrapper
        let wrapperTask = Task { @MainActor in
          // Small delay to ensure player item is ready
          try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms for better reliability

          // Check if the video is still active (user might have scrolled away)
          guard activeVideos[model.id] != nil else {
            logger.debug("🚫 Video \(model.id) no longer active, skipping wrapper creation")
            return
          }

          if let wrapper = LoopingPlayerWrapper(fromPlayer: player) {
            logger.debug("✅ Created looping wrapper for GIF \(model.id)")
            loopingWrappers[model.id] = wrapper
            // Update to use the wrapped player
            activeVideos[model.id] = (model, wrapper.player, lastPosition)
            // Trigger a playback state update to start the GIF if visible
            updatePlaybackStates()
          } else {
            logger.debug(
              "⚠️ Failed to create looping wrapper, keeping manual looping for \(model.id)")
            // Manual looping is already set up, no need to reconfigure
          }
        }

        // Store the task to clean it up later
        statusObservers["\(model.id)-wrapper"] = wrapperTask

        // Initially use the original player with manual looping
        activeVideos[model.id] = (model, player, lastPosition)
        configureGifPlayer(player, for: model.id)
      } else {
        // Wrapper path is intentionally disabled; always configure manual looping on the same AVPlayer instance.
        activeVideos[model.id] = (model, player, lastPosition)
        configureGifPlayer(player, for: model.id)
      }
    } else {
      // Regular video, use normal player
      logger.debug("📹 Configured regular video player for \(model.id)")
      activeVideos[model.id] = (model, player, lastPosition)
    }

    lastVisibleTimes[model.id] = Date()
    enforceLRUCap()

    signposter.emitEvent("PlayerRegistered", "count: \(self.activeVideos.count), visible: \(self.visibleVideoIDs.count)")
    logger.debug("📹 Total active videos: \(self.activeVideos.count), visible: \(self.visibleVideoIDs.count)")

    playbackObservers[model.id] = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.updateAudioSessionOwnership() }
    }

    // Update playback states after registration
    updatePlaybackStates()
  }

  // MARK: - Stream Preservation

  /// Check if a video stream should be preserved during scrolling
  func shouldPreserveStream(for modelId: String) -> Bool {
    // Only preserve streams that are actively playing in PiP or Fullscreen
    pipActiveVideoIDs.contains(modelId) || fullscreenActiveVideoIDs.contains(modelId)
  }

  /// Track fullscreen active status
  func setFullscreenActive(_ active: Bool, for modelId: String) {
    if active {
      fullscreenActiveVideoIDs.insert(modelId)
      markedForCleanup.remove(modelId)
      preservedStreams.removeValue(forKey: modelId)
      if let (model, player, _) = activeVideos[modelId] {
        player.configureForEngagedPlayback(isUnmuted: !model.isMuted)
      }
    } else {
      fullscreenActiveVideoIDs.remove(modelId)
      if let (model, player, _) = activeVideos[modelId], model.isMuted {
        player.configureForFeedPreview()
      }
      if !visibleVideoIDs.contains(modelId) {
        markForCleanup(modelId)
      }
    }
  }

  func isFullscreenActive(_ modelId: String) -> Bool {
    fullscreenActiveVideoIDs.contains(modelId)
  }

  func isRegistered(_ modelId: String) -> Bool {
    activeVideos[modelId] != nil
  }

  /// Mark a video for potential cleanup instead of immediate destruction
  func markForCleanup(_ modelId: String) {
    markedForCleanup.insert(modelId)
    preservedStreams[modelId] = Date()

    // Schedule cleanup after preservation time
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(streamPreservationTime * 1_000_000_000))

      // Only clean up if still marked, not visible, and not playing in PiP or Fullscreen
      if markedForCleanup.contains(modelId) && !visibleVideoIDs.contains(modelId)
        && !pipActiveVideoIDs.contains(modelId) && !fullscreenActiveVideoIDs.contains(modelId)
      {
        logger.debug("⏰ Delayed cleanup triggered for \(modelId)")
        forceUnregister(modelId)
      }
    }
  }

  /// Force unregister with immediate cleanup
  func forceUnregister(_ modelId: String) {
    markedForCleanup.remove(modelId)
    preservedStreams.removeValue(forKey: modelId)
    lastVisibleTimes.removeValue(forKey: modelId)
    unregister(modelId)
  }

  /// Evict oldest non-visible, non-PiP videos exceeding LRU cap
  private func enforceLRUCap() {
    let nonVisibleCandidates = activeVideos.keys.filter { id in
      !visibleVideoIDs.contains(id)
        && !pipActiveVideoIDs.contains(id)
        && !fullscreenActiveVideoIDs.contains(id)
        && markedForCleanup.contains(id)
    }
    guard nonVisibleCandidates.count > maxNonVisibleVideos else { return }

    let sortedByAge = nonVisibleCandidates.sorted { id1, id2 in
      let time1 = lastVisibleTimes[id1] ?? .distantPast
      let time2 = lastVisibleTimes[id2] ?? .distantPast
      return time1 < time2
    }

    let excessCount = nonVisibleCandidates.count - maxNonVisibleVideos
    for id in sortedByAge.prefix(excessCount) {
      logger.debug("🗑️ LRU evicting non-visible video \(id)")
      forceUnregister(id)
    }
  }

  /// Update visibility of a video model
  func updateVisibility(_ isVisible: Bool, for modelId: String) {
    // Cancel any pending visibility update tasks
    statusObservers[modelId]?.cancel()

    if isVisible {
      // For becoming visible, process immediately to avoid playback delays
      visibleVideoIDs.insert(modelId)
      lastVisibleTimes[modelId] = Date()
      // Remove from cleanup queue if becoming visible again
      markedForCleanup.remove(modelId)
      preservedStreams.removeValue(forKey: modelId)

      logger.debug("👀 Video \(modelId) became visible, restoring immediately")

      // If video was preserved, we might need to restore its state
      if let (model, player, lastPlaybackTime) = activeVideos[modelId] {
        // Video still exists, just update playback states
        updatePlaybackStates()
      }
    } else {
      // For becoming invisible, use debouncing to avoid flickering during scroll
      let task = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms debounce for hiding
        guard !Task.isCancelled else { return }

        visibleVideoIDs.remove(modelId)
        lastVisibleTimes[modelId] = Date()
        enforceLRUCap()
        // Don't immediately pause, let updatePlaybackStates handle it
        updatePlaybackStates()
      }

      statusObservers[modelId] = task
    }
  }

  /// Force play a video (used when user taps on thumbnail)
  func forcePlayVideo(_ modelId: String) {
    guard let (model, player, lastPlaybackTime) = activeVideos[modelId] else { return }

    logger.debug("🎬 ForcePlayVideo called for \(modelId)")

    // Pause any currently playing video (unless it's running in PiP)
    if let currentlyPlaying = currentlyPlayingVideoId,
      currentlyPlaying != modelId,
      !pipActiveVideoIDs.contains(currentlyPlaying)
    {
      pauseVideo(currentlyPlaying)
    }

    if !model.isMuted {
      player.configureForEngagedPlayback(isUnmuted: true)
    } else {
      player.configureForFeedPreview()
    }

    player.seek(to: lastPlaybackTime)
    player.safePlay()

    // Update states
    activeVideos[modelId]?.model.isPlaying = true
    currentlyPlayingVideoId = modelId

    // Ensure video is marked as visible
    visibleVideoIDs.insert(modelId)
    lastVisibleTimes[modelId] = Date()
    updateAudioSessionOwnership()
  }

  // MARK: - Private Methods

  /// Configure a player for GIF-like behavior (looping, muted)
  private func configureGifPlayer(_ player: AVPlayer, for modelId: String) {
    logger.debug("🔄 Configuring manual GIF looping for \(modelId)")

    // Ensure GIF player configuration
    player.isMuted = true
    player.volume = 0
    player.preventsDisplaySleepDuringVideoPlayback = false
    player.actionAtItemEnd = .none  // Prevent automatic pause

    // Setup manual looping with notification observer
    // Wait for item to be ready if needed
    if player.currentItem == nil {
      // Set up a KVO observer to wait for the item
      let observation = player.observe(\.currentItem, options: [.new]) {
        [weak self] observedPlayer, _ in
        if let item = observedPlayer.currentItem {
          self?.setupLoopingObserver(for: observedPlayer, item: item, modelId: modelId)
        }
      }

      // Store the observation to clean it up later
      statusObservers["\(modelId)-setup"] = Task {
        // Keep the observation alive for a bit
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
        observation.invalidate()
      }
    } else {
      setupLoopingObserver(for: player, item: player.currentItem!, modelId: modelId)
    }
  }

  /// Setup the looping observer for manual GIF looping
  private func setupLoopingObserver(for player: AVPlayer, item: AVPlayerItem, modelId: String) {
    logger.debug("🔄 Setting up looping observer for \(modelId)")

    // Remove any existing observers for this item
    if let oldToken = loopObserverTokens.removeValue(forKey: modelId) {
      NotificationCenter.default.removeObserver(oldToken)
    }
    // Add new observer for looping
    // Add new observer for looping (P099: retain token)
    let token = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak player, weak self] _ in
      guard let player = player, let self = self else { return }

      self.logger.debug("🔄 GIF reached end, looping: \(modelId)")

      // Check if this GIF should still be playing
      if let (model, _, _) = self.activeVideos[modelId], model.isPlaying {
        // Use default tolerance for faster seeking (performance over frame accuracy)
        player.seek(
          to: .zero, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity
        ) { finished in
          if finished {
            player.safePlay()
            self.logger.debug("✅ GIF looped successfully: \(modelId)")
          }
        }
      }
    }
    loopObserverTokens[modelId] = token
  }

  /// Update the playback state of all managed videos
  private func updatePlaybackStates() {
    Task { @MainActor in
      guard !Task.isCancelled, isApplicationActive else { return }
      defer { updateAudioSessionOwnership() }

      let autoplayEnabled = shouldAutoplayVideos()

      // Only inspect currently visible active videos (stops walking all registered players)
      let visibleActiveIDs = visibleVideoIDs.filter { activeVideos[$0] != nil }

      logger.debug(
        "🎮 updatePlaybackStates - autoplay enabled: \(autoplayEnabled), visible videos: \(visibleActiveIDs.count), total active: \(self.activeVideos.count)"
      )

      // Find the top visible video with improved prioritization
      let topVideoId = visibleActiveIDs
        .sorted { id1, id2 in
          // First priority: videos that are currently playing (timeControlStatus != .paused)
          let isPlaying1 = activeVideos[id1]?.player.timeControlStatus != .paused
          let isPlaying2 = activeVideos[id2]?.player.timeControlStatus != .paused
          if isPlaying1 != isPlaying2 {
            return isPlaying1
          }

          // Second priority: GIFs over regular videos (for auto-start)
          let isGif1 = activeVideos[id1]?.model.type.isGif ?? false
          let isGif2 = activeVideos[id2]?.model.type.isGif ?? false
          if isGif1 != isGif2 {
            return isGif1
          }

          return id1 < id2  // Stable sort for same types
        }
        .first

      if let topVideoId = topVideoId {
        let isGif = activeVideos[topVideoId]?.model.type.isGif ?? false
        logger.debug("🎯 Top visible video: \(topVideoId) - isGIF: \(isGif)")
      } else {
        logger.debug("🎯 No visible videos")
      }

      // If previous playing video is no longer top, pause it and restore preview config
      if let oldPlayingId = currentlyPlayingVideoId, oldPlayingId != topVideoId {
        if !pipActiveVideoIDs.contains(oldPlayingId) && !fullscreenActiveVideoIDs.contains(oldPlayingId) {
          pauseVideo(oldPlayingId)
          activeVideos[oldPlayingId]?.player.configureForFeedPreview()
        }
      }

      // Update visible players only
      for id in visibleActiveIDs {
        // Leave PiP and Fullscreen owned players alone
        if pipActiveVideoIDs.contains(id) || fullscreenActiveVideoIDs.contains(id) { continue }
        guard let (model, player, lastPlaybackTime) = activeVideos[id] else { continue }

        // Mirror model.isMuted onto the player
        if model.isMuted {
          if player.isMuted == false { player.isMuted = true }
          if player.volume != 0 { player.volume = 0 }
        } else {
          if player.isMuted { player.isMuted = false }
          if player.volume == 0 { player.volume = 1.0 }
        }

        if id == topVideoId {
          // Engaged playback config only when unmuted; capped bitrate/buffer for muted autoplay
          if !model.isMuted {
            player.configureForEngagedPlayback(isUnmuted: true)
          } else {
            player.configureForFeedPreview()
          }

          // For GIFs, always autoplay regardless of autoplay setting since they're silent
          // For regular videos, respect the autoplay setting
          let shouldPlay = model.type.isGif || autoplayEnabled

          if !model.isPlaying && shouldPlay {
            logger.debug(
              "▶️ Starting playback for top visible \(model.type.isGif ? "GIF" : "video"): \(id)")
            player.seek(to: lastPlaybackTime)
            player.safePlay()

            // Update states
            activeVideos[id]?.model.isPlaying = true
            currentlyPlayingVideoId = id
          } else if !shouldPlay && model.isPlaying {
            // If autoplay is disabled for regular videos but video is playing, pause it
            logger.debug("⏸️ Pausing video due to autoplay disabled: \(id)")
            pauseVideo(id)
          }
        } else {
          // Non-top visible videos should not play. Keep them lightweight.
          player.configureForFeedPreview()
          if model.isPlaying {
            logger.debug("⏸️ Pausing non-top visible \(model.type.isGif ? "GIF" : "video"): \(id)")
            pauseVideo(id)
          }
        }
      }
    }
  }

  /// Pause a specific video
  private func pauseVideo(_ modelId: String) {
    guard !pipActiveVideoIDs.contains(modelId) else { return }
    guard let (model, player, _) = activeVideos[modelId] else { return }
    player.pause()
    model.isPlaying = false

    // Mute only if the model says so. Force-muting on pause discarded the
    // user's unmute intent the next time the video resumed.
    if model.isMuted {
      player.isMuted = true
      player.volume = 0
    }

    // Update the last playback time
    let currentTime = player.currentTime()
    activeVideos[modelId]?.lastPlaybackTime = currentTime

    if currentlyPlayingVideoId == modelId {
      currentlyPlayingVideoId = nil
    }
    updateAudioSessionOwnership()
  }

  /// Unregister a video from management
  func unregister(_ modelId: String) {
    // An active PiP session owns this player; tearing it down (pause +
    // replaceCurrentItem(nil)) would kill PiP. Teardown re-runs on PiP stop.
    if pipActiveVideoIDs.contains(modelId) || fullscreenActiveVideoIDs.contains(modelId) {
      logger.debug("📺 Deferring unregister for PiP/Fullscreen-active video \(modelId)")
      return
    }

    // Save position to cache before cleanup
    if let (_, player, _) = activeVideos[modelId] {
      let seconds = CMTimeGetSeconds(player.currentTime())
      positionCache.setObject(NSNumber(value: seconds), forKey: modelId as NSString)

      // CRITICAL: Ensure audio is muted before removing
      player.isMuted = true
      player.volume = 0
    }

    // Clean up looping wrappers
    loopingWrappers.removeValue(forKey: modelId)

    // Clean up all related tasks
    statusObservers[modelId]?.cancel()
    statusObservers.removeValue(forKey: modelId)
    statusObservers["\(modelId)-wrapper"]?.cancel()
    statusObservers.removeValue(forKey: "\(modelId)-wrapper")
    statusObservers["\(modelId)-setup"]?.cancel()
    statusObservers.removeValue(forKey: "\(modelId)-setup")

    // P099: Remove any looping notification observer for this model
    if let token = loopObserverTokens.removeValue(forKey: modelId) {
      NotificationCenter.default.removeObserver(token)
    }

    // Pause and remove the video
    if let (_, player, _) = activeVideos[modelId] {
      player.pause()
      // Actually clean up the player item now
      player.replaceCurrentItem(with: nil)

      if currentlyPlayingVideoId == modelId {
        currentlyPlayingVideoId = nil
      }
    }

    activeVideos.removeValue(forKey: modelId)
    playbackObservers.removeValue(forKey: modelId)?.invalidate()
    visibleVideoIDs.remove(modelId)
    markedForCleanup.remove(modelId)
    preservedStreams.removeValue(forKey: modelId)
    lastVisibleTimes.removeValue(forKey: modelId)
    updateAudioSessionOwnership()

    signposter.emitEvent("PlayerUnregistered", "count: \(self.activeVideos.count), visible: \(self.visibleVideoIDs.count)")
    logger.debug("🧹 Fully unregistered video \(modelId). Total live players: \(self.activeVideos.count)")
    updatePlaybackStates()
  }

  // MARK: - Background Handling

  /// Set up notifications for app state changes
  private func setupBackgroundHandling() {
    #if os(iOS)
      NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleBackgroundTransition()
          self?.savePlaybackPositions()  // Save positions when going to background
        }
      }

      NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          // Reacquire only if an unmuted visible player actually resumes.
          self?.isApplicationActive = true
          self?.updatePlaybackStates()
        }
      }
    #elseif os(macOS)
      NotificationCenter.default.addObserver(
        forName: NSApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleBackgroundTransition()
          self?.savePlaybackPositions()  // Save positions when going to background
        }
      }

      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          // Reacquire only if an unmuted visible player actually resumes.
          self?.isApplicationActive = true
          self?.updatePlaybackStates()
        }
      }
    #endif

    // Optionally handle app termination
    #if os(iOS)
      NotificationCenter.default.addObserver(
        forName: UIApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.savePlaybackPositions()
        }
      }
    #elseif os(macOS)
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.savePlaybackPositions()
        }
      }
    #endif
  }

  /// Handle transition to background mode
  private func handleBackgroundTransition() {
    isApplicationActive = false
    for (modelId, (model, player, _)) in activeVideos {
      // PiP keeps playing in the background; muting or pausing here kills it
      if pipActiveVideoIDs.contains(modelId) { continue }

      if model.isPlaying || player.timeControlStatus != .paused {
        // Save position to cache when going to background
        let seconds = CMTimeGetSeconds(player.currentTime())
        positionCache.setObject(NSNumber(value: seconds), forKey: modelId as NSString)
      }
      // Pausing silences the player without turning lifecycle cleanup into a
      // user mute action through fullscreen's mute observer.
      pauseVideo(modelId)
    }
    updateAudioSessionOwnership()
  }

  // MARK: - Playback Position Persistence

  /// Save playback positions to UserDefaults
  private func savePlaybackPositions() {
    var positions: [String: Double] = [:]
    for (id, (_, player, _)) in activeVideos {
      positions[id] = CMTimeGetSeconds(player.currentTime())
    }
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(
      positions, forKey: "VideoPlaybackPositions")
  }

  /// Load playback positions from UserDefaults
  private func loadPlaybackPositions() -> [String: CMTime] {
    guard
      let positions = UserDefaults(suiteName: "group.blue.catbird.shared")?.dictionary(
        forKey: "VideoPlaybackPositions") as? [String: Double]
    else {
      return [:]
    }
    var cmTimePositions: [String: CMTime] = [:]
    for (id, seconds) in positions {
      cmTimePositions[id] = CMTime(seconds: seconds, preferredTimescale: 600)
    }
    return cmTimePositions
  }

  // Only use this method when explicitly requested by user action
  func setUnmuted(_ id: String, unmuted: Bool) {
    guard let (model, player, _) = activeVideos[id] else { return }
    defer { updateAudioSessionOwnership() }

    logger.debug("🎬 SetUnmuted called for \(id), unmuted: \(unmuted)")

    // Idempotency: avoid redundant property churn that can trigger KVO storms
    if unmuted {
      if model.isMuted == false && player.isMuted == false && player.volume > 0 {
        return
      }
      if player.isMuted { player.isMuted = false }
      if player.volume == 0 { player.volume = 1.0 }
      model.isMuted = false
      model.volume = 1.0
      player.configureForEngagedPlayback(isUnmuted: true)
    } else {
      if model.isMuted == true && player.isMuted == true && player.volume == 0 {
        return
      }
      // User wants to mute - check if we can restore music
      if player.isMuted == false { player.isMuted = true }
      if player.volume != 0 { player.volume = 0 }
      model.isMuted = true
      model.volume = 0
      player.configureForFeedPreview()
    }
  }

  /// Mute preference belongs to the model; session ownership belongs only to a
  /// visible, running player. Fullscreen/PiP hold their own scoped leases.
  private func updateAudioSessionOwnership() {
    let needsAudio = isApplicationActive && activeVideos.contains { id, entry in
      visibleVideoIDs.contains(id) && !pipActiveVideoIDs.contains(id)
        && !entry.model.isMuted && !entry.player.isMuted
        && entry.player.timeControlStatus != .paused
    }
    guard needsAudio != ownsPlaybackAudio else { return }
    ownsPlaybackAudio = needsAudio
    if needsAudio {
      AudioSessionManager.shared.acquireVideoPlayback(owner: playbackAudioOwner)
    } else {
      AudioSessionManager.shared.releaseVideoPlayback(owner: playbackAudioOwner)
    }
  }

  // MARK: - Picture in Picture Lifecycle

  /// Whether the given video is currently playing in Picture in Picture
  func isPictureInPictureActive(_ modelId: String) -> Bool {
    pipActiveVideoIDs.contains(modelId)
  }

  /// Mark a video as entering PiP, retaining the objects (player view
  /// controller + delegate) that must outlive the presenting view for the
  /// session to keep running and delivering callbacks.
  func pictureInPictureWillStart(for modelId: String, retaining objects: [AnyObject]) {
    logger.debug("📺 PiP starting for \(modelId)")
    pipActiveVideoIDs.insert(modelId)
    pipRetainedObjects[modelId] = objects
    markedForCleanup.remove(modelId)
    preservedStreams.removeValue(forKey: modelId)
    if let (model, player, _) = activeVideos[modelId] {
      player.configureForEngagedPlayback(isUnmuted: !model.isMuted)
    }
    updateAudioSessionOwnership()
  }

  /// Mark a video as having left PiP and run any teardown that was deferred
  /// while the session was active.
  func pictureInPictureDidStop(for modelId: String) {
    guard pipActiveVideoIDs.contains(modelId) else { return }
    logger.debug("📺 PiP stopped for \(modelId)")
    pipActiveVideoIDs.remove(modelId)
    pipRetainedObjects.removeValue(forKey: modelId)

    // The source view may have gone away while PiP was running; reschedule
    // the cleanup that was skipped to keep the session alive.
    if !visibleVideoIDs.contains(modelId) {
      markForCleanup(modelId)
    }
    updatePlaybackStates()
  }

}
