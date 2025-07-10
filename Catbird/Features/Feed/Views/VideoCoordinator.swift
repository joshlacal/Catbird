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

  // PiP management
  private var pipControllers: [String: AVPictureInPictureController] = [:]
  private var pipDelegates: [String: VideoPiPDelegate] = [:]
  // CRITICAL: Persistent player layers for PiP that survive view deallocation
  private var persistentPlayerLayers: [String: AVPlayerLayer] = [:]

  private let logger = Logger(subsystem: "blue.catbird", category: "VideoCoordinator")

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
    logger.debug(
      "📹 Registering video: \(model.id) - type: \(model.type.isGif ? "GIF" : "HLS") - URL: \(model.url.absoluteString)"
    )

    // CRITICAL: Always start with muted playback
    player.isMuted = true
    player.volume = 0
    model.isMuted = true
    model.volume = 0
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
      if loopingWrappers[model.id] == nil {
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
      }
    } else {
      // Regular video, use normal player
      logger.debug("📹 Configured regular video player for \(model.id)")
      activeVideos[model.id] = (model, player, lastPosition)
    }

    logger.debug("📹 Total active videos: \(self.activeVideos.count)")

    // Update playback states after registration
    updatePlaybackStates()
  }

  // MARK: - Stream Preservation

  /// Check if a video stream should be preserved during scrolling
  func shouldPreserveStream(for modelId: String) -> Bool {
    // Always preserve if in PiP
    if isInPiPMode(modelId) {
      return true
    }

    // Preserve if video was recently visible
    if let (model, _, _) = activeVideos[modelId] {
      // Always preserve GIFs since they're small and loop
      if model.type.isGif {
        return true
      }

      // For HLS streams, preserve if recently active
      return true  // For now, preserve all streams during scroll
    }

    return false
  }

  /// Mark a video for potential cleanup instead of immediate destruction
  func markForCleanup(_ modelId: String) {
    // CRITICAL: Never mark PiP videos for cleanup
    if isInPiPMode(modelId) {
      logger.debug("📺 Refusing to mark PiP video \(modelId) for cleanup")
      return
    }

    markedForCleanup.insert(modelId)
    preservedStreams[modelId] = Date()

    // Schedule cleanup after preservation time
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(streamPreservationTime * 1_000_000_000))

      // Only clean up if still marked, not visible, and NOT in PiP
      if markedForCleanup.contains(modelId) && !visibleVideoIDs.contains(modelId)
        && !isInPiPMode(modelId)
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
    unregister(modelId)
  }

  /// Update visibility of a video model
  func updateVisibility(_ isVisible: Bool, for modelId: String) {
    // Cancel any pending visibility update tasks
    statusObservers[modelId]?.cancel()

    if isVisible {
      // For becoming visible, process immediately to avoid playback delays
      visibleVideoIDs.insert(modelId)
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
        // Don't immediately pause, let updatePlaybackStates handle it
        updatePlaybackStates()
      }

      statusObservers[modelId] = task
    }
  }

  /// Force play a video (used when user taps on thumbnail)
  func forcePlayVideo(_ modelId: String) {
    guard let (model, player, lastPlaybackTime) = activeVideos[modelId] else { return }

    logger.debug("🎬 [PiP Debug] ForcePlayVideo called for \(modelId)")

    // Pause any currently playing video
    if let currentlyPlaying = currentlyPlayingVideoId,
      currentlyPlaying != modelId
    {
      pauseVideo(currentlyPlaying)
    }

    // Start playing the requested video
    player.seek(to: lastPlaybackTime)
    player.safePlay()

    // Update states
    activeVideos[modelId]?.model.isPlaying = true
    currentlyPlayingVideoId = modelId

    // Ensure video is marked as visible
    visibleVideoIDs.insert(modelId)

    // Note: PiP status checking removed since PiP has been disabled
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
    NotificationCenter.default.removeObserver(
      self, name: .AVPlayerItemDidPlayToEndTime, object: item)

    // Add new observer for looping
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak player, weak self] _ in
      guard let player = player, let self = self else { return }

      self.logger.debug("🔄 GIF reached end, looping: \(modelId)")

      // Check if this GIF should still be playing
      if let (model, _, _) = self.activeVideos[modelId], model.isPlaying {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
          if finished {
            player.safePlay()
            self.logger.debug("✅ GIF looped successfully: \(modelId)")
          }
        }
      }
    }
  }

  /// Update the playback state of all managed videos
  private func updatePlaybackStates() {
    Task { @MainActor in
      guard !Task.isCancelled else { return }

      // Don't configure audio session at all - let videos play muted
      // Only configure when user explicitly unmutes a video

      let autoplayEnabled = shouldAutoplayVideos()
      logger.debug(
        "🎮 updatePlaybackStates - autoplay enabled: \(autoplayEnabled), visible videos: \(self.visibleVideoIDs.count), total videos: \(self.activeVideos.count)"
      )

      // Find the top visible video with improved prioritization
      let topVideoId = activeVideos.keys
        .filter { visibleVideoIDs.contains($0) }
        .sorted { id1, id2 in
          // First priority: videos that are already playing
          let isPlaying1 = activeVideos[id1]?.model.isPlaying ?? false
          let isPlaying2 = activeVideos[id2]?.model.isPlaying ?? false
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

      // Update players based on visibility
      for (id, (model, player, lastPlaybackTime)) in activeVideos {
        // CRITICALLY IMPORTANT: Always ensure videos are muted during auto-playback
        player.isMuted = true
        player.volume = 0

        if id == topVideoId {
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
            // Note: This won't affect GIFs since shouldPlay is always true for them
            logger.debug("⏸️ Pausing video due to autoplay disabled: \(id)")
            pauseVideo(id)
          }
        } else {
          // Pause non-visible videos
          if model.isPlaying {
            logger.debug("⏸️ Pausing non-visible \(model.type.isGif ? "GIF" : "video"): \(id)")
            pauseVideo(id)
          }
        }
      }
    }
  }

  /// Pause a specific video
  private func pauseVideo(_ modelId: String) {
    guard let (model, player, _) = activeVideos[modelId] else { return }
    player.pause()
    model.isPlaying = false

    // IMPORTANT: Always ensure audio is muted when pausing
    player.isMuted = true
    player.volume = 0

    // Update the last playback time
    let currentTime = player.currentTime()
    activeVideos[modelId]?.lastPlaybackTime = currentTime

    if currentlyPlayingVideoId == modelId {
      currentlyPlayingVideoId = nil
    }
  }

  /// Unregister a video from management
  func unregister(_ modelId: String) {
    // Check if video is in PiP mode
    let isInPiP = isInPiPMode(modelId)

    if isInPiP {
      logger.debug("📺 Video \(modelId) is in PiP mode, preserving everything")
      // CRITICAL: Don't clean up anything for PiP videos
      // Keep the video in activeVideos, just update visibility
      visibleVideoIDs.remove(modelId)
      // Remove from cleanup queue to prevent future cleanup
      markedForCleanup.remove(modelId)
      preservedStreams.removeValue(forKey: modelId)
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

    // Clean up PiP controller if not in PiP mode
    cleanupPiPController(for: modelId)

    // Clean up looping wrappers
    loopingWrappers.removeValue(forKey: modelId)

    // Clean up all related tasks
    statusObservers[modelId]?.cancel()
    statusObservers.removeValue(forKey: modelId)
    statusObservers["\(modelId)-wrapper"]?.cancel()
    statusObservers.removeValue(forKey: "\(modelId)-wrapper")
    statusObservers["\(modelId)-setup"]?.cancel()
    statusObservers.removeValue(forKey: "\(modelId)-setup")

    // Remove any notification observers for this model's player item
    if let (_, player, _) = activeVideos[modelId], let item = player.currentItem {
      NotificationCenter.default.removeObserver(
        self, name: .AVPlayerItemDidPlayToEndTime, object: item)
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
    visibleVideoIDs.remove(modelId)
    markedForCleanup.remove(modelId)
    preservedStreams.removeValue(forKey: modelId)

    logger.debug("🧹 Fully unregistered video \(modelId)")
    updatePlaybackStates()
  }

  /// Clean up PiP controller for a video
  private func cleanupPiPController(for modelId: String) {
    // Remove PiP controller and delegate
    if let controller = pipControllers.removeValue(forKey: modelId) {
      controller.delegate = nil
      logger.debug("📺 Cleaned up PiP controller for \(modelId)")
    }
    pipDelegates.removeValue(forKey: modelId)

    // Clean up persistent player layer
    if let persistentLayer = persistentPlayerLayers.removeValue(forKey: modelId) {
      persistentLayer.player = nil
      logger.debug("📺 Cleaned up persistent player layer for \(modelId)")
    }
  }

  /// Force cleanup of PiP (called when PiP ends)
  func forceCleanupPiP(for modelId: String) {
    logger.debug("📺 PiP ended for \(modelId), cleaning up PiP controller only")
    cleanupPiPController(for: modelId)

    // Update model state to reflect PiP is no longer active
    if let (model, _, _) = activeVideos[modelId] {
      model.isPiPActive = false
    }

    // If video is no longer visible AND not playing, mark for cleanup
    // But give it a grace period in case user wants to continue watching
    if !visibleVideoIDs.contains(modelId) {
      // Don't immediately destroy - give 5 seconds grace period
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
        // Only cleanup if still not visible after grace period
        if !visibleVideoIDs.contains(modelId) && !isInPiPMode(modelId) {
          logger.debug("📺 Grace period expired for \(modelId), cleaning up")
          forceUnregister(modelId)
        }
      }
    }
  }

  // MARK: - Background Handling

  /// Set up notifications for app state changes
  private func setupBackgroundHandling() {
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
        // Don't configure audio session at all when app becomes active
        // This preserves music playback
        self?.updatePlaybackStates()
      }
    }

    // Optionally handle app termination
    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.savePlaybackPositions()
      }
    }
  }

  /// Handle transition to background mode
  private func handleBackgroundTransition() {
    for (modelId, (model, player, _)) in activeVideos {
      // CRITICAL: Ensure videos are muted when going to background
      player.isMuted = true
      player.volume = 0

      if model.isPlaying {
        // Save position to cache when going to background
        let seconds = CMTimeGetSeconds(player.currentTime())
        positionCache.setObject(NSNumber(value: seconds), forKey: modelId as NSString)
        pauseVideo(modelId)
      }
    }
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

    logger.debug("🎬 [PiP Debug] SetUnmuted called for \(id), unmuted: \(unmuted)")

    if unmuted {
      // User explicitly wants sound - now we configure audio session
      AudioSessionManager.shared.handleVideoUnmute()
      player.isMuted = false
      player.volume = 1.0
      model.isMuted = false
      model.volume = 1.0
    } else {
      // User wants to mute - check if we can restore music
      player.isMuted = true
      player.volume = 0
      model.isMuted = true
      model.volume = 0

      // If no other videos are unmuted, restore ambient audio
      let hasOtherUnmutedVideo = activeVideos.values.contains {
        $0.model.id != id && !$0.model.isMuted
      }
      if !hasOtherUnmutedVideo {
        AudioSessionManager.shared.handleVideoMute()
      }
    }
  }

  // MARK: - PiP Management

  /// Register a PiP controller for a video
  func registerPiPController(_ controller: AVPictureInPictureController, for modelId: String) {
    guard let (model, player, _) = activeVideos[modelId] else { return }

    // Create a persistent player layer that survives view deallocation
    let persistentLayer = AVPlayerLayer()
    persistentLayer.player = player
    persistentLayer.videoGravity = .resizeAspect

    // Store the persistent layer
    persistentPlayerLayers[modelId] = persistentLayer

    // Create NEW PiP controller with persistent layer instead of view layer
    let persistentPiPController = AVPictureInPictureController(playerLayer: persistentLayer)
    persistentPiPController?.canStartPictureInPictureAutomaticallyFromInline = false

    // Create and set delegate
    let delegate = VideoPiPDelegate(modelId: modelId, coordinator: self)
    persistentPiPController?.delegate = delegate

    // Store NEW controller and delegate (replacing any existing ones)
    pipControllers[modelId] = persistentPiPController
    pipDelegates[modelId] = delegate

    // Update model state
    model.isPiPSupported = true

    logger.debug("📺 Registered PERSISTENT PiP controller for \(modelId)")
  }

  /// Create PiP setup for a video from player layer info (simplified interface)
  func setupPiPController(for modelId: String, validatedPlayerLayer: AVPlayerLayer) {
    guard let (model, player, _) = activeVideos[modelId] else { return }

    // Create a persistent player layer that survives view deallocation
    let persistentLayer = AVPlayerLayer()
    persistentLayer.player = player
    persistentLayer.videoGravity = validatedPlayerLayer.videoGravity
    persistentLayer.frame = validatedPlayerLayer.frame

    // Store the persistent layer
    persistentPlayerLayers[modelId] = persistentLayer

    // Create PiP controller with persistent layer
    let persistentPiPController = AVPictureInPictureController(playerLayer: persistentLayer)
    persistentPiPController?.canStartPictureInPictureAutomaticallyFromInline = false

    // Create and set delegate
    let delegate = VideoPiPDelegate(modelId: modelId, coordinator: self)
    persistentPiPController?.delegate = delegate

    // Store controller and delegate
    pipControllers[modelId] = persistentPiPController
    pipDelegates[modelId] = delegate

    // Update model state
    model.isPiPSupported = true

    logger.debug("📺 Created PERSISTENT PiP controller for \(modelId)")
  }

  /// Get PiP controller for a video
  func getPiPController(for modelId: String) -> AVPictureInPictureController? {
    return pipControllers[modelId]
  }

  /// Handle PiP state changes
  func updatePiPState(for modelId: String, isActive: Bool) {
    guard let (model, _, _) = activeVideos[modelId] else { return }

    model.isPiPActive = isActive

    if isActive {
      logger.debug("📺 PiP activated for \(modelId)")
      // Don't pause the video when PiP starts
    } else {
      logger.debug("📺 PiP deactivated for \(modelId)")
      // Video continues playing after PiP ends
    }
  }

  /// Check if a video is currently in PiP mode
  func isInPiPMode(_ modelId: String) -> Bool {
    return activeVideos[modelId]?.model.isPiPActive ?? false
  }
}

// MARK: - PiP Delegate

class VideoPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
  let modelId: String
  weak var coordinator: VideoCoordinator?

  init(modelId: String, coordinator: VideoCoordinator) {
    self.modelId = modelId
    self.coordinator = coordinator
    super.init()
  }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      // Configure audio session only when PiP is actually starting
      AudioSessionManager.shared.configureForPictureInPicture()
      coordinator?.updatePiPState(for: modelId, isActive: true)
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // PiP is now active
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      coordinator?.updatePiPState(for: modelId, isActive: false)
    }
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // PiP has ended, can now clean up if needed
    Task { @MainActor in
      // Reset audio session when PiP stops
      AudioSessionManager.shared.resetPiPAudioSession()
      coordinator?.forceCleanupPiP(for: modelId)
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    Task { @MainActor in

      coordinator?.updatePiPState(for: modelId, isActive: false)
    }
  }
}
