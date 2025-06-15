//
//  ModernVideoPlayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import AVKit
import Foundation
import Petrel
import SwiftUI
import os.log

@available(iOS 18.0, *)
struct ModernVideoPlayerView18: View {
  private let logger = Logger(subsystem: "blue.catbird", category: "ModernVideoPlayerView")

  // MARK: - Properties
  let model: VideoModel
  @State private var player: AVPlayer?
  @State private var isVisible = false
  @State private var showControls = false
  @State private var showFullscreen = false
  @State private var pipSetupRetryCount = 0
  private let maxPipRetries = 5
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  let postID: String
  @Namespace private var videoTransitionNamespace

  // Improved tap gesture tracking
  @GestureState private var isTapped = false
  @State private var muteButtonFrame = CGRect.zero

  // MARK: - Initializers

  // Primary initializer that takes a VideoModel directly
  init(model: VideoModel, postID: String) {
    self.model = model
    self.postID = postID
  }

  // Convenience initializer for AppBskyEmbedVideo.View
  init?(bskyVideo: AppBskyEmbedVideo.View, postID: String) {
    guard let playlistURL = bskyVideo.playlist.url else {
      return nil
    }

    let aspectRatio =
      bskyVideo.aspectRatio.map {
        CGFloat($0.width) / CGFloat($0.height)
      } ?? 16 / 9

    let aspectRatioStruct = bskyVideo.aspectRatio.map {
      VideoModel.AspectRatio(width: $0.width, height: $0.height)
    }

    // Use postID in the model's ID
    self.model = VideoModel(
      id: "\(postID)-\(bskyVideo.playlist.uriString())-\(bskyVideo.cid)",
      url: playlistURL,
      type: .hlsStream(
        playlistURL: playlistURL, cid: bskyVideo.cid, aspectRatio: aspectRatioStruct),
      aspectRatio: aspectRatio,
      thumbnailURL: bskyVideo.thumbnail?.url
    )

    self.postID = postID
  }

  // Convenience initializer for Tenor GIFs
  init?(tenorURL: URL, aspectRatio: CGFloat? = nil, postID: String) {
    let gifId = tenorURL.absoluteString
    guard let uri = URI(tenorURL.absoluteString) else {
      return nil
    }

    // Use postID in the model's ID for Tenor GIFs too
    self.model = VideoModel(
      id: "\(postID)-tenor-\(gifId)",
      url: tenorURL,
      type: .tenorGif(uri),
      aspectRatio: aspectRatio ?? 1,
      thumbnailURL: nil  // Thumbnail will be set by ExternalEmbedView if available
    )
    self.postID = postID
  }

  // MARK: - Body
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottomTrailing) {
        // Video Player Layer
        if let player = player {
          ZStack {
            PlayerLayerView(
              player: player,
              gravity: model.type.isGif ? .resizeAspectFill : .resizeAspect,
              size: CGSize(
                width: geometry.size.width,
                height: geometry.size.width / model.aspectRatio
              ),
              shouldLoop: true,
              onLayerReady: setupPiPIfNeeded
            )
            .matchedTransitionSource(id: model.id, in: videoTransitionNamespace) { source in
              source
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.size.width / model.aspectRatio)

            // Show thumbnail overlay if video is not playing and autoplay is disabled
            if !model.isPlaying && !appState.appSettings.autoplayVideos,
              let thumbnailURL = model.thumbnailURL
            {
              VideoThumbnailView(thumbnailURL: thumbnailURL, aspectRatio: model.aspectRatio)
                .allowsHitTesting(false)  // Let taps pass through to the player
            }
          }
          .contentShape(Rectangle())
          .onTapGesture { location in
            // Check if tap is not on control buttons area
            if !muteButtonFrame.contains(location) {
              if !model.isPlaying && !appState.appSettings.autoplayVideos {
                // Start playing if thumbnail is shown (works for both HLS and GIFs)
                VideoCoordinator.shared.forcePlayVideo(model.id)
              } else if case .hlsStream(_, _, _) = model.type {
                // Full-screen video should only be available for HLS videos
                showFullscreen = true
              }
              // For GIFs, single tap doesn't do anything when already playing
            }
          }
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // HLS video controls (mute and PiP buttons)
        // Only show for HLS videos, not for GIFs
        if let player = player, case .hlsStream = model.type {
          HStack {
            // Picture-in-Picture button - get from coordinator
            if let pipController = VideoCoordinator.shared.getPiPController(for: model.id) {
              PiPButton(controller: pipController)
                .padding(.trailing, 8)
                .zIndex(10)
            } else {
              // Show disabled PiP button while controller is being set up
              Button(action: {}) {
                Image(systemName: "pip.enter")
                  .foregroundStyle(.gray)
                  .frame(width: 32, height: 32)
                  .background(Circle().fill(Color.black.opacity(0.6)))
              }
              .disabled(true)
              .padding(.trailing, 8)
              .zIndex(10)
            }

            // Mute button
            MuteButton(player: player, model: model)
          }
          .padding(12)
          .background(
            GeometryReader { geo in
              Color.clear
                .onAppear {
                  // Store the frame of the control area for hit-testing
                  muteButtonFrame = geo.frame(in: .global)
                }
            }
          )
          .allowsHitTesting(true)
          .zIndex(5)  // Ensure controls are above video tap gesture
        }
      }
      .onScrollVisibilityChange(threshold: 0.5) { visible in
        isVisible = visible
        VideoCoordinator.shared.updateVisibility(visible, for: model.id)
      }
    }
    .aspectRatio(model.aspectRatio, contentMode: .fit)
    .task {
      await setupPlayer()
    }
    .onAppear {
      if let player = player {
        // Ensure VideoCoordinator has access to app settings
        VideoCoordinator.shared.appSettings = appState.appSettings
        VideoCoordinator.shared.register(model, player: player)
      }
    }
    .onDisappear {
      cleanupPlayer()
    }
    .fullScreenCover(isPresented: $showFullscreen) {
      if let player = player {
        FullscreenVideoPlayerView(originalPlayer: player, model: model)
          .navigationTransition(.zoom(sourceID: model.id, in: videoTransitionNamespace))
      }
    }
    // Keep track of app state changes
    .onChange(of: scenePhase) { oldPhase, newPhase in
      handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
  }

  // MARK: - Private Methods

  /// Helper method for PiP setup from layer callback
  private func setupPiPIfNeeded(layer: AVPlayerLayer) {
    logger.debug(
      "🎬 PlayerLayerView onLayerReady called for model type: \(String(describing: model.type))")
    if case .hlsStream(_, _, _) = model.type {
      setupPictureInPicture(with: layer)
    }
  }

  /// Set up the player for this video
  private func setupPlayer() async {
    do {
      let player = try await VideoAssetManager.shared.preparePlayer(for: model)
      await MainActor.run {
        self.player = player

        // CRITICAL: Always start with muted playback
        player.isMuted = true
        player.volume = 0

        switch model.type {
        case .hlsStream(_, _, _):
          model.isMuted = true
          model.volume = 0
          // Configure audio session for PiP support early
          AudioSessionManager.shared.configureForPictureInPicture()
        case .tenorGif, .giphyGif:
          player.isMuted = true
          model.isMuted = true
          model.volume = 0
        }

        VideoCoordinator.shared.register(model, player: player)

        // PiP setup now happens in PlayerLayerView callback
      }
    } catch {
      logger.debug("Failed to setup player: \(error)")
    }
  }

  /// Clean up resources when view disappears
  private func cleanupPlayer() {
    // CRITICAL: Check if video is in PiP mode before ANY cleanup
    if VideoCoordinator.shared.isInPiPMode(model.id) {
      logger.debug("📺 Video \(model.id) is in PiP mode, preserving everything")
      // For PiP videos, only update visibility but preserve all resources
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      // Clear local player reference but DON'T destroy the coordinator's player
      player = nil
      return
    }

    // Check if we should preserve the stream for performance (non-PiP)
    if VideoCoordinator.shared.shouldPreserveStream(for: model.id) {
      logger.debug("💾 Preserving video stream for \(model.id) during scroll")
      // Just mark as not visible but keep the stream alive
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      return
    }

    logger.debug("🧹 Fully cleaning up video \(model.id)")

    // Reset PiP audio session when cleaning up HLS video (only for non-PiP)
    if case .hlsStream = model.type {
      AudioSessionManager.shared.resetPiPAudioSession()
    }

    // Pause and clean up player only when really needed
    if let currentPlayer = player {
      currentPlayer.pause()
      // Don't immediately destroy the player item, let coordinator handle it
    }

    // Update model state before unregistering
    model.isPlaying = false

    // Unregister from coordinator (coordinator will decide whether to fully clean up)
    VideoCoordinator.shared.markForCleanup(model.id)

    // Clear local player reference but don't destroy the actual player yet
    player = nil
  }

  /// Handle app state changes
  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      // Resume playback if becoming active and visible
      if isVisible, let player = player, model.isPlaying {
        player.play()
      }
    case .background, .inactive:
      // Pause playback when going to background
      player?.pause()
    @unknown default:
      break
    }
  }

  /// Setup Picture-in-Picture for HLS streams
  private func setupPictureInPicture(with playerLayer: AVPlayerLayer) {
    logger.debug("🎬 Starting PiP setup for HLS stream (attempt \(pipSetupRetryCount + 1))")

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      logger.debug("❌ Picture-in-Picture not supported on this device")
      return
    }

    // Ensure the player layer has a player and is ready
    guard let player = playerLayer.player else {
      logger.debug("❌ Cannot setup PiP: player layer not ready")
      retryPipSetup(with: playerLayer)
      return
    }

    logger.debug("✅ Player layer ready, checking player item status")

    // Check if player has a current item ready
    guard let playerItem = player.currentItem else {
      logger.debug("⚠️ Player item not ready yet, delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Check player item status
    let status = playerItem.status
    guard status == .readyToPlay else {
      logger.debug("⚠️ Player item status not ready: \(status.rawValue), delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Additional validation: ensure the player layer is properly configured
    guard playerLayer.frame.width > 0 && playerLayer.frame.height > 0 else {
      logger.debug(
        "⚠️ Player layer frame not ready: \(playerLayer.frame.debugDescription), delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Ensure video tracks are available
    let videoTracks = playerItem.tracks.filter { $0.assetTrack?.mediaType == .video }
    guard !videoTracks.isEmpty else {
      logger.debug("⚠️ No video tracks found, retrying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Configure audio session for PiP support
    AudioSessionManager.shared.configureForPictureInPicture()

    // Create PiP controller with the actual player layer from the view
    let pipController = AVPictureInPictureController(playerLayer: playerLayer)
    pipController?.canStartPictureInPictureAutomaticallyFromInline = false

    // Register with coordinator instead of storing locally
    VideoCoordinator.shared.registerPiPController(pipController!, for: model.id)

    // Reset retry count on successful setup
    pipSetupRetryCount = 0

    logger.debug("✅ Picture-in-Picture controller setup completed for HLS stream")
    logger.debug(
      "🎬 PiP possible: \(String(describing: pipController?.isPictureInPicturePossible)), PiP supported: \(String(describing: AVPictureInPictureController.isPictureInPictureSupported))"
    )
    logger.debug(
      "🎬 Player item status: \(playerItem.status.rawValue), duration: \(CMTimeGetSeconds(playerItem.duration))"
    )
    logger.debug("🎬 Player rate: \(player.rate), time: \(CMTimeGetSeconds(player.currentTime()))")
    logger.debug("🎬 Video tracks: \(videoTracks.count)")
    logger.debug("🎬 Player layer frame: \(playerLayer.frame.debugDescription)")

    // Force a check of PiP possibility after a brief delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.logger.debug(
        "🎬 [0.5s later] PiP possible: \(String(describing: pipController?.isPictureInPicturePossible))"
      )

      // If still not possible, try one more setup
      if pipController?.isPictureInPicturePossible == false {
        self.logger.debug("🎬 PiP still not possible, attempting one final setup")
        self.retryPipSetup(with: playerLayer)
      }
    }
  }

  /// Retry PiP setup with exponential backoff
  private func retryPipSetup(with playerLayer: AVPlayerLayer) {
    guard pipSetupRetryCount < maxPipRetries else {
      logger.debug("❌ Max PiP setup retries reached, giving up")
      return
    }

    pipSetupRetryCount += 1
    let delay = min(0.5 * pow(2.0, Double(pipSetupRetryCount - 1)), 4.0)  // Cap at 4 seconds

    logger.debug("🔄 Retrying PiP setup in \(delay) seconds (attempt \(pipSetupRetryCount))")

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      self.setupPictureInPicture(with: playerLayer)
    }
  }
}

// MARK: - Missing Components

/// Video thumbnail view for showing previews
struct VideoThumbnailView: View {
  let thumbnailURL: URL
  let aspectRatio: CGFloat

  var body: some View {
    AsyncImage(url: thumbnailURL) { image in
      image
        .resizable()
        .aspectRatio(contentMode: .fill)
    } placeholder: {
      Rectangle()
        .fill(Color.gray.opacity(0.3))
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .clipped()
  }
}

/// Picture-in-Picture button for iOS 18
struct PiPButton: View {
  let controller: AVPictureInPictureController

  var body: some View {
    Button(action: {
      if controller.isPictureInPictureActive {
        controller.stopPictureInPicture()
      } else {
        controller.startPictureInPicture()
      }
    }) {
      Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    .disabled(!controller.isPictureInPicturePossible)
  }
}

/// Button style for mute buttons
struct MuteButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.7 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// Visibility detector for iOS 17 compatibility
@available(iOS 17.0, *)
struct VisibilityDetector: View {
  let visibilityThreshold: Double
  let onVisibilityChange: (Bool) -> Void

  var body: some View {
    Color.clear
      .onAppear {
        onVisibilityChange(true)
      }
      .onDisappear {
        onVisibilityChange(false)
      }
  }
}

// MARK: - iOS 17 Specific Components

@available(iOS 17.0, *)
struct MuteButton17: View {
  let player: AVPlayer
  let model: VideoModel

  // Track local state to avoid unwanted audio playback
  @State private var isMuted: Bool = true

  var body: some View {
    Button(action: toggleMute) {
      ZStack {
        Circle()
          .fill(Color.black.opacity(0.6))
          .frame(width: 32, height: 32)

        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .foregroundColor(.white)
          .font(.system(size: 14))
      }
    }
    // Make the hit target larger with explicit padding for better touch area
    .padding(4)
    .contentShape(Circle().scale(1.5))
    .buttonStyle(MuteButtonStyle())
    .onAppear {
      // Ensure button state matches model state
      isMuted = model.isMuted
    }
  }

  /// Toggle mute state with proper coordination
  private func toggleMute() {
    // Update local state
    isMuted.toggle()

    // Delegate the actual work to the coordinator
    VideoCoordinator.shared.setUnmuted(model.id, unmuted: !isMuted)
  }
}

@available(iOS 17.0, *)
struct PiPButton17: View {
  let controller: AVPictureInPictureController

  var body: some View {
    Button(action: {
      if controller.isPictureInPictureActive {
        controller.stopPictureInPicture()
      } else {
        controller.startPictureInPicture()
      }
    }) {
      ZStack {
        Circle()
          .fill(Color.black.opacity(0.6))
          .frame(width: 32, height: 32)

        Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
          .foregroundColor(.white)
          .appFont(size: 14)
      }
    }
    .disabled(!controller.isPictureInPicturePossible)
  }
}

/// iOS 17 version of ModernVideoPlayerView (single definition)
@available(iOS 17.0, *)
struct ModernVideoPlayerView17: View {
  private let logger = Logger(subsystem: "blue.catbird", category: "ModernVideoPlayerView")

  // MARK: - Properties
  let model: VideoModel
  @State private var player: AVPlayer?
  @State private var isVisible = false
  @State private var showControls = false
  @State private var showFullscreen = false
  @State private var pipSetupRetryCount = 0
  private let maxPipRetries = 5
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  let postID: String

  // For transition effect (iOS 17 alternative to namespace)
  @State private var playerScale: CGFloat = 1.0

  // Improved tap gesture tracking
  @GestureState private var isTapped = false
  @State private var muteButtonFrame = CGRect.zero

  // MARK: - Initializers

  // Primary initializer that takes a VideoModel directly
  init(model: VideoModel, postID: String) {
    self.model = model
    self.postID = postID
  }

  // Convenience initializer for AppBskyEmbedVideo.View
  init?(bskyVideo: AppBskyEmbedVideo.View, postID: String) {
    guard let playlistURL = bskyVideo.playlist.url else {
      return nil
    }

    let aspectRatio =
      bskyVideo.aspectRatio.map {
        CGFloat($0.width) / CGFloat($0.height)
      } ?? 16 / 9

    let aspectRatioStruct = bskyVideo.aspectRatio.map {
      VideoModel.AspectRatio(width: $0.width, height: $0.height)
    }

    // Use postID in the model's ID
    self.model = VideoModel(
      id: "\(postID)-\(bskyVideo.playlist.uriString())-\(bskyVideo.cid)",
      url: playlistURL,
      type: .hlsStream(
        playlistURL: playlistURL, cid: bskyVideo.cid, aspectRatio: aspectRatioStruct),
      aspectRatio: aspectRatio,
      thumbnailURL: bskyVideo.thumbnail?.url
    )

    self.postID = postID
  }

  // Convenience initializer for Tenor GIFs
  init?(tenorURL: URL, aspectRatio: CGFloat? = nil, postID: String) {
    let gifId = tenorURL.absoluteString
    guard let uri = URI(tenorURL.absoluteString) else {
      return nil
    }

    // Use postID in the model's ID for Tenor GIFs too
    self.model = VideoModel(
      id: "\(postID)-tenor-\(gifId)",
      url: tenorURL,
      type: .tenorGif(uri),
      aspectRatio: aspectRatio ?? 1,
      thumbnailURL: nil  // Thumbnail will be set by ExternalEmbedView if available
    )
    self.postID = postID
  }

  // MARK: - Body
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottomTrailing) {
        // Video Player Layer
        if let player = player {
          ZStack {
            PlayerLayerView(
              player: player,
              gravity: model.type.isGif ? .resizeAspectFill : .resizeAspect,
              size: CGSize(
                width: geometry.size.width,
                height: geometry.size.width / model.aspectRatio
              ),
              shouldLoop: true,
              onLayerReady: setupPiPIfNeeded
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity)
            .frame(height: geometry.size.width / model.aspectRatio)

            // Show thumbnail overlay if video is not playing and autoplay is disabled
            if !model.isPlaying && !appState.appSettings.autoplayVideos,
              let thumbnailURL = model.thumbnailURL
            {
              VideoThumbnailView(thumbnailURL: thumbnailURL, aspectRatio: model.aspectRatio)
                .allowsHitTesting(false)  // Let taps pass through to the player
            }
          }
          .contentShape(Rectangle())
          .scaleEffect(playerScale)
          .animation(.spring(), value: playerScale)
          .onTapGesture { location in
            // Check if tap is not on control buttons area
            if !muteButtonFrame.contains(location) {
              if case .hlsStream(_, _, _) = model.type {
                if !model.isPlaying && !appState.appSettings.autoplayVideos {
                  // Start playing if thumbnail is shown
                  VideoCoordinator.shared.forcePlayVideo(model.id)
                } else {
                  // Animate scale before showing fullscreen
                  withAnimation(.easeInOut(duration: 0.2)) {
                    playerScale = 0.95
                  }

                  // Reset scale and show fullscreen
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    playerScale = 1.0
                    showFullscreen = true
                  }
                }
              }
            }
          }
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // HLS video controls (mute and PiP buttons)
        // Only show for HLS videos, not for GIFs
        if let player = player, case .hlsStream = model.type {
          HStack {
            // Picture-in-Picture button - get from coordinator
            if let pipController = VideoCoordinator.shared.getPiPController(for: model.id) {
              PiPButton17(controller: pipController)
                .padding(.trailing, 8)
                .zIndex(10)
            } else {
              // Show disabled PiP button while controller is being set up
              Button(action: {}) {
                ZStack {
                  Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 32, height: 32)

                  Image(systemName: "pip.enter")
                    .foregroundColor(.gray)
                    .appFont(size: 14)
                }
              }
              .disabled(true)
              .padding(.trailing, 8)
              .zIndex(10)
            }

            // Mute button
            MuteButton17(player: player, model: model)
          }
          .padding(12)
          .background(
            GeometryReader { geo in
              Color.clear
                .onAppear {
                  // Store the frame of the control area for hit-testing
                  muteButtonFrame = geo.frame(in: .global)
                }
            }
          )
          .allowsHitTesting(true)
          .zIndex(5)  // Ensure controls are above video tap gesture
        }
      }
      .background(
        VisibilityDetector(visibilityThreshold: 0.5) { isVisible in
          self.isVisible = isVisible
          VideoCoordinator.shared.updateVisibility(isVisible, for: model.id)
        }
      )
    }
    .aspectRatio(model.aspectRatio, contentMode: .fit)
    .task {
      await setupPlayer()
    }
    .onAppear {
      if let player = player {
        // Ensure VideoCoordinator has access to app settings
        VideoCoordinator.shared.appSettings = appState.appSettings
        VideoCoordinator.shared.register(model, player: player)
      }
    }
    .onDisappear {
      cleanupPlayer()
    }
    .fullScreenCover(isPresented: $showFullscreen) {
      if let player = player {
        FullscreenVideoPlayerView(originalPlayer: player, model: model)
      }
    }
    // Keep track of app state changes
    .onChange(of: scenePhase) { oldPhase, newPhase in
      handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
  }

  // MARK: - Private Methods

  /// Helper method for PiP setup from layer callback
  private func setupPiPIfNeeded(layer: AVPlayerLayer) {
    logger.debug(
      "🎬 PlayerLayerView onLayerReady called for model type: \(String(describing: model.type))")
    if case .hlsStream(_, _, _) = model.type {
      setupPictureInPicture(with: layer)
    }
  }

  /// Set up the player for this video
  private func setupPlayer() async {
    do {
      let player = try await VideoAssetManager.shared.preparePlayer(for: model)
      await MainActor.run {
        self.player = player

        // CRITICAL: Always start with muted playback
        player.isMuted = true
        player.volume = 0

        switch model.type {
        case .hlsStream(_, _, _):
          model.isMuted = true
          model.volume = 0
          // Configure audio session for PiP support early
          AudioSessionManager.shared.configureForPictureInPicture()
        case .tenorGif, .giphyGif:
          player.isMuted = true
          model.isMuted = true
          model.volume = 0
        }

        VideoCoordinator.shared.register(model, player: player)

        // PiP setup now happens in PlayerLayerView callback
      }
    } catch {
      logger.debug("Failed to setup player: \(error)")
    }
  }

  /// Clean up resources when view disappears
  private func cleanupPlayer() {
    // CRITICAL: Check if video is in PiP mode before ANY cleanup
    if VideoCoordinator.shared.isInPiPMode(model.id) {
      logger.debug("📺 Video \(model.id) is in PiP mode, preserving everything")
      // For PiP videos, only update visibility but preserve all resources
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      // Clear local player reference but DON'T destroy the coordinator's player
      player = nil
      return
    }

    // Check if we should preserve the stream for performance (non-PiP)
    if VideoCoordinator.shared.shouldPreserveStream(for: model.id) {
      logger.debug("💾 Preserving video stream for \(model.id) during scroll")
      // Just mark as not visible but keep the stream alive
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      return
    }

    logger.debug("🧹 Fully cleaning up video \(model.id)")

    // Reset PiP audio session when cleaning up HLS video (only for non-PiP)
    if case .hlsStream = model.type {
      AudioSessionManager.shared.resetPiPAudioSession()
    }

    // Pause and clean up player only when really needed
    if let currentPlayer = player {
      currentPlayer.pause()
      // Don't immediately destroy the player item, let coordinator handle it
    }

    // Update model state before unregistering
    model.isPlaying = false

    // Unregister from coordinator (coordinator will decide whether to fully clean up)
    VideoCoordinator.shared.markForCleanup(model.id)

    // Clear local player reference but don't destroy the actual player yet
    player = nil
  }

  /// Handle app state changes
  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      // Resume playback if becoming active and visible
      if isVisible, let player = player, model.isPlaying {
        player.play()
      }
    case .background, .inactive:
      // Pause playback when going to background
      player?.pause()
    @unknown default:
      break
    }
  }

  /// Setup Picture-in-Picture for HLS streams
  private func setupPictureInPicture(with playerLayer: AVPlayerLayer) {
    logger.debug("🎬 Starting PiP setup for HLS stream (attempt \(pipSetupRetryCount + 1))")

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      logger.debug("❌ Picture-in-Picture not supported on this device")
      return
    }

    // Ensure the player layer has a player and is ready
    guard let player = playerLayer.player else {
      logger.debug("❌ Cannot setup PiP: player layer not ready")
      retryPipSetup(with: playerLayer)
      return
    }

    logger.debug("✅ Player layer ready, checking player item status")

    // Check if player has a current item ready
    guard let playerItem = player.currentItem else {
      logger.debug("⚠️ Player item not ready yet, delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Check player item status
    let status = playerItem.status
    guard status == .readyToPlay else {
      logger.debug("⚠️ Player item status not ready: \(status.rawValue), delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Additional validation: ensure the player layer is properly configured
    guard playerLayer.frame.width > 0 && playerLayer.frame.height > 0 else {
      logger.debug(
        "⚠️ Player layer frame not ready: \(playerLayer.frame.debugDescription), delaying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Ensure video tracks are available
    let videoTracks = playerItem.tracks.filter { $0.assetTrack?.mediaType == .video }
    guard !videoTracks.isEmpty else {
      logger.debug("⚠️ No video tracks found, retrying PiP setup")
      retryPipSetup(with: playerLayer)
      return
    }

    // Configure audio session for PiP support
    AudioSessionManager.shared.configureForPictureInPicture()

    // Create PiP controller with the actual player layer from the view
    let pipController = AVPictureInPictureController(playerLayer: playerLayer)
    pipController?.canStartPictureInPictureAutomaticallyFromInline = false

    // Register with coordinator instead of storing locally
    VideoCoordinator.shared.registerPiPController(pipController!, for: model.id)

    // Reset retry count on successful setup
    pipSetupRetryCount = 0

    logger.debug("✅ Picture-in-Picture controller setup completed for HLS stream")
    logger.debug(
      "🎬 PiP possible: \(String(describing: pipController?.isPictureInPicturePossible)), PiP supported: \(String(describing: AVPictureInPictureController.isPictureInPictureSupported))"
    )
    logger.debug(
      "🎬 Player item status: \(playerItem.status.rawValue), duration: \(CMTimeGetSeconds(playerItem.duration))"
    )
    logger.debug("🎬 Player rate: \(player.rate), time: \(CMTimeGetSeconds(player.currentTime()))")
    logger.debug("🎬 Video tracks: \(videoTracks.count)")
    logger.debug("🎬 Player layer frame: \(playerLayer.frame.debugDescription)")

    // Force a check of PiP possibility after a brief delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.logger.debug(
        "🎬 [0.5s later] PiP possible: \(String(describing: pipController?.isPictureInPicturePossible))"
      )

      // If still not possible, try one more setup
      if pipController?.isPictureInPicturePossible == false {
        self.logger.debug("🎬 PiP still not possible, attempting one final setup")
        self.retryPipSetup(with: playerLayer)
      }
    }
  }

  /// Retry PiP setup with exponential backoff
  private func retryPipSetup(with playerLayer: AVPlayerLayer) {
    guard pipSetupRetryCount < maxPipRetries else {
      logger.debug("❌ Max PiP setup retries reached, giving up")
      return
    }

    pipSetupRetryCount += 1
    let delay = min(0.5 * pow(2.0, Double(pipSetupRetryCount - 1)), 4.0)  // Cap at 4 seconds

    logger.debug("🔄 Retrying PiP setup in \(delay) seconds (attempt \(pipSetupRetryCount))")

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      self.setupPictureInPicture(with: playerLayer)
    }
  }
}

/// Video thumbnail view for showing previews
// MARK: - Mute Button Components

/// Mute button for iOS 18
struct MuteButton: View {
  let player: AVPlayer
  let model: VideoModel

  // Track local state to avoid unwanted audio playback
  @State private var isMuted: Bool = true

  var body: some View {
    Button(action: toggleMute) {
      Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    // Make the hit target larger with explicit padding for better touch area
    .padding(4)
    .contentShape(Circle().scale(1.5))
    .buttonStyle(MuteButtonStyle())
    .onAppear {
      // Ensure button state matches model state
      isMuted = model.isMuted
    }
  }

  /// Toggle mute state with proper coordination
  private func toggleMute() {
    // Update local state
    isMuted.toggle()

    // Delegate the actual work to the coordinator
    VideoCoordinator.shared.setUnmuted(model.id, unmuted: !isMuted)
  }
}

/// Mute button specifically for iOS 18 (if needed for different styling)
@available(iOS 18.0, *)
struct MuteButton18: View {
  let player: AVPlayer
  let model: VideoModel

  // Track local state to avoid unwanted audio playback
  @State private var isMuted: Bool = true

  var body: some View {
    Button(action: toggleMute) {
      Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    // Make the hit target larger with explicit padding for better touch area
    .padding(4)
    .contentShape(Circle().scale(1.5))
    .buttonStyle(MuteButtonStyle())
    .onAppear {
      // Ensure button state matches model state
      isMuted = model.isMuted
    }
  }

  /// Toggle mute state with proper coordination
  private func toggleMute() {
    // Update local state
    isMuted.toggle()

    // Delegate the actual work to the coordinator
    VideoCoordinator.shared.setUnmuted(model.id, unmuted: !isMuted)
  }
}
