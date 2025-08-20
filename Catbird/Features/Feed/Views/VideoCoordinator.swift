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
    // CRITICAL: Only clean up if NOT in PiP mode
    if isInPiPMode(modelId) {
      logger.debug("📺 Refusing to cleanup PiP controller for active PiP video \(modelId)")
      return
    }
    
    // Remove PiP controller and delegate
    if let controller = pipControllers.removeValue(forKey: modelId) {
      controller.delegate = nil
      logger.debug("📺 Cleaned up PiP controller for \(modelId)")
    }
    pipDelegates.removeValue(forKey: modelId)

    // Clean up persistent player layer only if not in PiP
    if let persistentLayer = persistentPlayerLayers.removeValue(forKey: modelId) {
      persistentLayer.player = nil
      logger.debug("📺 Cleaned up persistent player layer for \(modelId)")
    }
  }

  /// Force cleanup of PiP (called when PiP ends)
  func forceCleanupPiP(for modelId: String) {
    logger.debug("📺 PiP ended for \(modelId), cleaning up PiP controller only")
    cleanupPiPController(for: modelId)

    // PiP is no longer active for this video

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
        // Don't configure audio session at all when app becomes active
        // This preserves music playback
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
        // Don't configure audio session at all when app becomes active
        // This preserves music playback
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
  
  /// Transfer player to persistent storage during PiP mode
  func transferPlayerToPersistentStorage(_ player: AVPlayer, for modelId: String) {
    #if os(iOS)
    logger.debug("📺 Transferring player \(modelId) to persistent storage for PiP")
    
    // Update the activeVideos entry to keep the player reference
    if var (model, _, lastPlaybackTime) = activeVideos[modelId] {
      activeVideos[modelId] = (model, player, lastPlaybackTime)
      
      // Ensure persistent layer is also updated
      if let persistentLayer = persistentPlayerLayers[modelId] {
        persistentLayer.player = player
        logger.debug("📺 Updated persistent layer for \(modelId)")
      } else {
        // Create persistent layer if it doesn't exist
        let newPersistentLayer = AVPlayerLayer()
        newPersistentLayer.player = player
        newPersistentLayer.videoGravity = .resizeAspect
        persistentPlayerLayers[modelId] = newPersistentLayer
        logger.debug("📺 Created new persistent layer for \(modelId)")
      }
    }
    #else
    // PiP not available on macOS, do nothing
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Restore player from persistent storage when view returns
  func restorePlayerFromPersistentStorage(for modelId: String) -> AVPlayer? {
    #if os(iOS)
    logger.debug("📺 Attempting to restore player \(modelId) from persistent storage")
    
    if let (_, player, _) = activeVideos[modelId] {
      logger.debug("📺 Successfully restored player for \(modelId)")
      return player
    }
    
    logger.debug("⚠️ No persistent player found for \(modelId)")
    return nil
    #else
    // PiP not available on macOS, return nil
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    return nil
    #endif
  }
  
  // MARK: - PiP Delegate Methods
  
  /// Called when PiP will start
  func willStartPiP(for modelId: String) {
    #if os(iOS)
    logger.debug("📺 Will start PiP for video: \(modelId)")
    AudioSessionManager.shared.configureForPictureInPicture()
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Called when PiP did start
  func didStartPiP(for modelId: String) {
    #if os(iOS)
    logger.debug("📺 Did start PiP for video: \(modelId)")
    updatePiPState(for: modelId, isActive: true)
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Called when PiP will stop
  func willStopPiP(for modelId: String) {
    #if os(iOS)
    logger.debug("📺 Will stop PiP for video: \(modelId)")
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Called when PiP did stop
  func didStopPiP(for modelId: String) {
    #if os(iOS)
    logger.debug("📺 Did stop PiP for video: \(modelId)")
    updatePiPState(for: modelId, isActive: false)
    AudioSessionManager.shared.resetPiPAudioSession()
    forceCleanupPiP(for: modelId)
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Called when PiP failed to start
  func didFailToStartPiP(for modelId: String, error: Error) {
    #if os(iOS)
    logger.error("❌ PiP failed to start for video \(modelId): \(error.localizedDescription)")
    updatePiPState(for: modelId, isActive: false)
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }
  
  /// Called when PiP needs to restore user interface
  func restoreUserInterface(for modelId: String, completion: @escaping (Bool) -> Void) {
    #if os(iOS)
    logger.debug("📺 Restoring UI for video: \(modelId)")
    
    // Post notification to restore UI - this will be handled by the app's navigation system
    NotificationCenter.default.post(
      name: NSNotification.Name("RestorePiPInterface"),
      object: nil,
      userInfo: ["videoId": modelId]
    )
    
    // For now, always return success
    completion(true)
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    completion(false)
    #endif
  }

  /// Register a PiP controller for a video
  func registerPiPController(_ controller: AVPictureInPictureController, for modelId: String, with delegate: VideoPiPDelegate? = nil) {
    #if os(iOS)
    guard let (model, player, _) = activeVideos[modelId] else { return }

    // Create a persistent player layer that survives view deallocation
    let persistentLayer = AVPlayerLayer()
    persistentLayer.player = player
    persistentLayer.videoGravity = .resizeAspect

    // Store the persistent layer
    persistentPlayerLayers[modelId] = persistentLayer

    // Use provided delegate or create new one
    let pipDelegate = delegate ?? VideoPiPDelegate(modelId: modelId, coordinator: self)
    
    // Set delegate on the provided controller
    controller.delegate = pipDelegate

    // Store controller and delegate
    pipControllers[modelId] = controller
    pipDelegates[modelId] = pipDelegate

    // Update model state
    // PiP support configured

    logger.debug("📺 Registered PiP controller for \(modelId)")
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }

  /// Create PiP setup for a video from player layer info (simplified interface)
  func setupPiPController(for modelId: String, validatedPlayerLayer: AVPlayerLayer) {
    #if os(iOS)
    guard let (model, player, _) = activeVideos[modelId] else { 
      logger.debug("❌ No active video found for \(modelId)")
      return 
    }

    logger.debug("📺 Setting up PiP controller for \(modelId)")

    // Create a persistent player layer that survives view deallocation
    let persistentLayer = AVPlayerLayer()
    persistentLayer.player = player
    persistentLayer.videoGravity = validatedPlayerLayer.videoGravity
    
    // CRITICAL: Set proper frame using server-provided aspect ratio if the original layer has zero dimensions
    if validatedPlayerLayer.frame.width == 0 || validatedPlayerLayer.frame.height == 0 {
      // Use the server-provided aspect ratio to calculate proper dimensions
      let aspectRatio = model.aspectRatio
      let baseWidth: CGFloat = 320 // Base width for PiP
      let calculatedHeight = baseWidth / aspectRatio
      
      persistentLayer.frame = CGRect(x: 0, y: 0, width: baseWidth, height: calculatedHeight)
      logger.debug("📺 Using server aspect ratio \(aspectRatio) for persistent layer: \(persistentLayer.frame.debugDescription)")
    } else {
      persistentLayer.frame = validatedPlayerLayer.frame
      logger.debug("📺 Using validated frame for persistent layer: \(persistentLayer.frame.debugDescription)")
    }

    // Store the persistent layer
    persistentPlayerLayers[modelId] = persistentLayer

    // Create PiP controller with persistent layer
    guard let persistentPiPController = AVPictureInPictureController(playerLayer: persistentLayer) else {
      logger.debug("❌ Failed to create PiP controller for \(modelId)")
      return
    }
    
    persistentPiPController.canStartPictureInPictureAutomaticallyFromInline = false

    // Create and set delegate
    let delegate = VideoPiPDelegate(modelId: modelId, coordinator: self)
    persistentPiPController.delegate = delegate

    // Store controller and delegate
    pipControllers[modelId] = persistentPiPController
    pipDelegates[modelId] = delegate

    // Update model state
    // PiP support configured

    logger.debug("📺 Created PERSISTENT PiP controller for \(modelId) - isPossible: \(persistentPiPController.isPictureInPicturePossible)")
    
    // Add validation for player layer setup
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let playerStatus = persistentLayer.player?.currentItem?.status.rawValue ?? -1
      let hasVideoTracks = persistentLayer.player?.currentItem?.tracks.contains { $0.assetTrack?.mediaType == .video } ?? false
        self.logger.debug("📺 PiP validation - status: \(playerStatus), hasVideo: \(hasVideoTracks), frame: \(persistentLayer.frame.debugDescription)")
    }
    #else
    logger.debug("📺 PiP not available on macOS for \(modelId)")
    #endif
  }

  /// Get PiP controller for a video
  func getPiPController(for modelId: String) -> AVPictureInPictureController? {
    #if os(iOS)
    return pipControllers[modelId]
    #else
    return nil
    #endif
  }

  /// Handle PiP state changes
  func updatePiPState(for modelId: String, isActive: Bool) {
    guard let (model, _, _) = activeVideos[modelId] else { return }

    // PiP state updated

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
    return false // PiP functionality disabled
  }
}

// MARK: - PiP Delegate

#if os(iOS)
class VideoPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
  private let pipLogger = Logger(subsystem: "blue.catbird", category: "VideoPiPDelegate")
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
      pipLogger.debug("📺 PiP will start for video: \(self.modelId)")
    Task { @MainActor in
      coordinator?.willStartPiP(for: modelId)
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
      pipLogger.debug("📺 PiP did start for video: \(self.modelId)")
    Task { @MainActor in
      coordinator?.didStartPiP(for: modelId)
    }
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
      pipLogger.debug("📺 PiP will stop for video: \(self.modelId)")
    Task { @MainActor in
      coordinator?.willStopPiP(for: modelId)
    }
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
      pipLogger.debug("📺 PiP did stop for video: \(self.modelId)")
    Task { @MainActor in
      coordinator?.didStopPiP(for: modelId)
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
      pipLogger.error("❌ PiP failed to start for video \(self.modelId): \(error.localizedDescription)")
      pipLogger.error("❌ PiP error code: \((error as NSError).code), domain: \((error as NSError).domain)")
      pipLogger.error("❌ PiP userInfo: \((error as NSError).userInfo)")
      print("❌ PiP DETAILED ERROR - Code: \((error as NSError).code), Domain: \((error as NSError).domain), Description: \(error.localizedDescription)")
    Task { @MainActor in
      coordinator?.didFailToStartPiP(for: modelId, error: error)
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
      pipLogger.debug("📺 Restoring UI for video: \(self.modelId)")
    Task { @MainActor in
      coordinator?.restoreUserInterface(for: modelId) { success in
        completionHandler(success)
      }
    }
  }
}
#else
// PiP not available on macOS
class VideoPiPDelegate: NSObject {
  private let pipLogger = Logger(subsystem: "blue.catbird", category: "VideoPiPDelegate")
  let modelId: String
  weak var coordinator: VideoCoordinator?

  init(modelId: String, coordinator: VideoCoordinator) {
    self.modelId = modelId
    self.coordinator = coordinator
    super.init()
    pipLogger.debug("VideoPiPDelegate created but PiP not available on macOS")
  }
}
#endif
