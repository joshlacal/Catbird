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

// MARK: - Main Player View

@available(iOS 17.0, *)
struct ModernVideoPlayerView: View {
  private let logger = Logger(subsystem: "blue.catbird", category: "ModernVideoPlayerView")

  // MARK: - Properties
  let model: VideoModel
  @State private var player: AVPlayer?
  @State private var isVisible = false
  @State private var showControls = false
  @State private var showFullscreen = false
  private let maxPipRetries = 5
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  let postID: String

  // For iOS 18+ transitions
  @Namespace private var videoTransitionNamespace

  // For iOS 17 transition effect
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

    let aspectRatio = bskyVideo.aspectRatio.map {
      CGFloat($0.width) / CGFloat($0.height)
    } ?? 16 / 9

    let aspectRatioStruct = bskyVideo.aspectRatio.map {
      VideoModel.AspectRatio(width: $0.width, height: $0.height)
    }

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
      let playerContainer = ZStack(alignment: .bottomTrailing) {
        // Video Player Layer
          ZStack {
            playerLayerView(geometry: geometry)

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
            handleTap(location: location)
          }
        

        // HLS video controls (mute and PiP buttons)
        if let player = player, case .hlsStream = model.type {
          videoControls(player: player)
        }
      }

      if #available(iOS 18.0, *) {
        playerContainer
          .onScrollVisibilityChange(threshold: 0.5) { visible in
            isVisible = visible
            VideoCoordinator.shared.updateVisibility(visible, for: model.id)
          }
      } else {
        playerContainer
          .background(
            VisibilityDetector(visibilityThreshold: 0.5) { isVisible in
              self.isVisible = isVisible
              VideoCoordinator.shared.updateVisibility(isVisible, for: model.id)
            }
          )
      }
    }
    .aspectRatio(model.aspectRatio, contentMode: .fit)
    .task {
      await setupPlayer()
    }
    .onAppear {
      if let player = player {
        VideoCoordinator.shared.appSettings = appState.appSettings
        VideoCoordinator.shared.register(model, player: player)
      }
    }
    .onDisappear {
      cleanupPlayer()
    }
    .fullScreenCover(isPresented: $showFullscreen) {
      if let player = player {
        fullscreenPlayerView(player: player)
      }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
  }

  // MARK: - View Components

  @ViewBuilder
  private func playerLayerView(geometry: GeometryProxy) -> some View {
      if let player = player {

    let playerView = PlayerLayerView(
      player: player,
      gravity: model.type.isGif ? .resizeAspectFill : .resizeAspect,
      size: CGSize(
        width: geometry.size.width,
        height: geometry.size.width / model.aspectRatio
      ),
      shouldLoop: true,
      onLayerReady: setupPiPIfNeeded
    )
    .frame(maxWidth: .infinity)
    .frame(height: geometry.size.width / model.aspectRatio)

    if #available(iOS 18.0, *) {
      playerView
        .matchedTransitionSource(id: model.id, in: videoTransitionNamespace) { source in
          source
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    } else {
      playerView
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .scaleEffect(playerScale)
        .animation(.spring(), value: playerScale)
    }
          
      } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
  }

  @ViewBuilder
  private func videoControls(player: AVPlayer) -> some View {
    HStack {
      // Picture-in-Picture button
//      if let pipController = VideoCoordinator.shared.getPiPController(for: model.id) {
//        PiPButton(controller: pipController)
//          .padding(.trailing, 8)
//          .zIndex(10)
//      } else {
//        disabledPiPButton
//          .padding(.trailing, 8)
//          .zIndex(10)
//      }

      // Mute button
      MuteButton(player: player, model: model)
    }
    .padding(12)
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear {
            muteButtonFrame = geo.frame(in: .global)
          }
      }
    )
    .allowsHitTesting(true)
    .zIndex(5)
  }

  private var disabledPiPButton: some View {
    Button(action: {}) {
      Image(systemName: "pip.enter")
        .foregroundStyle(.gray)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    .disabled(true)
  }

  @ViewBuilder
  private func fullscreenPlayerView(player: AVPlayer) -> some View {
    let fullscreenView = FullscreenVideoPlayerView(originalPlayer: player, model: model)
    if #available(iOS 18.0, *) {
      fullscreenView
        .navigationTransition(.zoom(sourceID: model.id, in: videoTransitionNamespace))
    } else {
      fullscreenView
    }
  }

  // MARK: - Gesture Handling

  private func handleTap(location: CGPoint) {
    guard !muteButtonFrame.contains(location) else { return }

    if !model.isPlaying && !appState.appSettings.autoplayVideos {
      VideoCoordinator.shared.forcePlayVideo(model.id)
    } else if case .hlsStream = model.type {
      if #available(iOS 18.0, *) {
        showFullscreen = true
      } else {
        // Animate scale before showing fullscreen on older OS
        withAnimation(.easeInOut(duration: 0.2)) {
          playerScale = 0.95
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          playerScale = 1.0
          showFullscreen = true
        }
      }
    }
  }

  // MARK: - Private Methods

  private func setupPiPIfNeeded(layer: AVPlayerLayer) {
    logger.debug(
      "🎬 PlayerLayerView onLayerReady called for model type: \(String(describing: model.type))")
    if case .hlsStream = model.type {
      setupPictureInPicture(with: layer)
    }
  }

  private func setupPlayer() async {
    do {
      let player = try await VideoAssetManager.shared.preparePlayer(for: model)
      await MainActor.run {
        self.player = player
        player.isMuted = true
        player.volume = 0

        switch model.type {
        case .hlsStream:
          model.isMuted = true
          model.volume = 0
          // Don't configure audio session until needed (when unmuting or starting PiP)
        case .tenorGif, .giphyGif:
          model.isMuted = true
          model.volume = 0
        }
        VideoCoordinator.shared.register(model, player: player)
      }
    } catch {
      logger.debug("Failed to setup player: \(error)")
    }
  }

  private func cleanupPlayer() {
    if VideoCoordinator.shared.isInPiPMode(model.id) {
      logger.debug("📺 Video \(model.id) is in PiP mode, preserving everything")
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      player = nil
      return
    }

    if VideoCoordinator.shared.shouldPreserveStream(for: model.id) {
      logger.debug("💾 Preserving video stream for \(model.id) during scroll")
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      return
    }

    logger.debug("🧹 Fully cleaning up video \(model.id)")
    if case .hlsStream = model.type {
      AudioSessionManager.shared.resetPiPAudioSession()
    }
    player?.pause()
    model.isPlaying = false
    VideoCoordinator.shared.markForCleanup(model.id)
    player = nil
  }

  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      if isVisible, let player = player, model.isPlaying {
        player.safePlay()
      }
    case .background, .inactive:
      player?.pause()
    @unknown default:
      break
    }
  }

  private func setupPictureInPicture(with playerLayer: AVPlayerLayer, retryCount: Int = 0) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      logger.debug("❌ PiP not supported")
      return
    }
    
    guard let player = playerLayer.player,
          let playerItem = player.currentItem,
          playerItem.status == .readyToPlay,
          playerLayer.frame.width > 0,
          playerLayer.frame.height > 0,
          !playerItem.tracks.filter({ $0.assetTrack?.mediaType == .video }).isEmpty
    else {
      logger.debug("⚠️ PiP not ready, retrying")
      retryPipSetup(with: playerLayer, currentCount: retryCount)
      return
    }

    let pipController = AVPictureInPictureController(playerLayer: playerLayer)
    pipController?.canStartPictureInPictureAutomaticallyFromInline = false
    VideoCoordinator.shared.registerPiPController(pipController!, for: model.id)
    
    // Only configure audio session when PiP is actually started, not during setup
    logger.debug("✅ PiP controller setup completed")
    
    // Check if PiP is possible after a brief delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if pipController?.isPictureInPicturePossible == false {
        self.logger.debug("🎬 PiP still not possible, attempting one final setup")
        self.retryPipSetup(with: playerLayer, currentCount: retryCount)
      }
    }
  }

  private func retryPipSetup(with playerLayer: AVPlayerLayer, currentCount: Int) {
    let nextCount = currentCount + 1
    guard nextCount < maxPipRetries else {
      logger.debug("❌ Max PiP setup retries reached")
      return
    }
    let delay = min(0.5 * pow(2.0, Double(currentCount)), 4.0)
    logger.debug("🔄 Retrying PiP setup in \(delay) seconds (attempt \(nextCount))")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      self.setupPictureInPicture(with: playerLayer, retryCount: nextCount)
    }
  }
}

// MARK: - Helper Components

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

/// Unified Picture-in-Picture button
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

/// Unified Mute button
struct MuteButton: View {
  let player: AVPlayer
  let model: VideoModel

  @State private var isMuted: Bool = true

  var body: some View {
    Button(action: toggleMute) {
      Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    .padding(4)
    .contentShape(Circle().scale(1.5))
    .buttonStyle(MuteButtonStyle())
    .onAppear {
      isMuted = model.isMuted
    }
  }

  private func toggleMute() {
    isMuted.toggle()
    VideoCoordinator.shared.setUnmuted(model.id, unmuted: !isMuted)
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
