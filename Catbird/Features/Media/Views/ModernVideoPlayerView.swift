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
  // Avoid copying large structs by extracting only needed fields
  init?(bskyVideo: AppBskyEmbedVideo.View, postID: String) {
    // Safely unwrap URL first
    guard let playlistURL = bskyVideo.playlist.url else {
      return nil
    }

    // Compute aspect ratio defensively (avoid divide by zero)
    let ar: CGFloat
    if let arIn = bskyVideo.aspectRatio, arIn.height != 0 {
      ar = CGFloat(arIn.width) / CGFloat(arIn.height)
    } else {
      ar = 16.0 / 9.0
    }

    let aspectRatioStruct: VideoModel.AspectRatio? = bskyVideo.aspectRatio.map {
      VideoModel.AspectRatio(width: $0.width, height: $0.height)
    }

    // Build a stable ID without embedding large payloads
    let id = "\(postID)-\(bskyVideo.cid)"

    self.model = VideoModel(
      id: id,
      url: playlistURL,
      type: .hlsStream(playlistURL: playlistURL, cid: bskyVideo.cid, aspectRatio: aspectRatioStruct),
      aspectRatio: ar,
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
    let playerContainer = ZStack(alignment: .bottomTrailing) {
      // Video Player Layer
      ZStack {
        playerLayerView()

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

      // HLS video controls (mute button)
      if let player = player, case .hlsStream = model.type {
        videoControls(player: player)
      }
    }

    let finalView = playerContainer
      .aspectRatio(model.aspectRatio, contentMode: .fit)
      #if os(macOS)
      .frame(minHeight: 300, maxHeight: 600)
      .frame(maxWidth: 800)
      #endif
      .task {
        await setupPlayer()
      }
      .onAppear {
        // Setup player if needed
        
        if let player = player {
          VideoCoordinator.shared.appSettings = appState.appSettings
          VideoCoordinator.shared.register(model, player: player)
        }
      }
      .onDisappear {
        cleanupPlayer()
      }
#if os(iOS)
      .fullScreenCover(isPresented: $showFullscreen) {
        if let player = player {
          fullscreenPlayerView(player: player)
        }
      }
#elseif os(macOS)
      .sheet(isPresented: $showFullscreen) {
        if let player = player {
          fullscreenPlayerView(player: player)
        }
      }
#endif
      .onChange(of: scenePhase) { oldPhase, newPhase in
        handleScenePhaseChange(from: oldPhase, to: newPhase)
      }

    if #available(iOS 18.0, *) {
      finalView
        .onScrollVisibilityChange(threshold: 0.5) { visible in
          isVisible = visible
          VideoCoordinator.shared.updateVisibility(visible, for: model.id)
        }
    } else {
      finalView
        .background(
          VisibilityDetector(visibilityThreshold: 0.5) { isVisible in
            self.isVisible = isVisible
            VideoCoordinator.shared.updateVisibility(isVisible, for: model.id)
          }
        )
    }
  }

  // MARK: - View Components

  @ViewBuilder
  private func playerLayerView() -> some View {
    if let player = player {
      let playerView = PlayerLayerView(
        player: player,
        gravity: model.type.isGif ? .resizeAspectFill : .resizeAspect,
        // Loop in-feed so videos don’t freeze on the last frame
        // For GIFs, VideoCoordinator handles looping manually to ensure it works even if the view is recycled
        // For HLS, we let the layer handle it
        shouldLoop: !model.type.isGif,
        onLayerReady: nil
      )

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
      
      Spacer()
      
      // Volume and mute controls

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


  @ViewBuilder
  private func fullscreenPlayerView(player: AVPlayer) -> some View {
    let fullscreenView = FullscreenVideoPlayerView(originalPlayer: player, model: model)
    #if os(iOS)
    if #available(iOS 18.0, *) {
      fullscreenView
        .navigationTransition(.zoom(sourceID: model.id, in: videoTransitionNamespace))
    } else {
      fullscreenView
    }
    #else
    fullscreenView
    #endif
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


  private func setupPlayer() async {
    // Check if we already have a player (from restoration or previous setup)
    if player != nil {
      logger.debug("📺 Player already exists for \(model.id), skipping setup")
      return
    }
    
    // Create player
    do {
      let newPlayer = try await VideoAssetManager.shared.preparePlayer(for: model)
      await MainActor.run {
        self.player = newPlayer
        newPlayer.isMuted = true
        newPlayer.volume = 0

        switch model.type {
        case .hlsStream:
          model.isMuted = true
          model.volume = 0
          // Ensure audio session is configured for silent playback only
          AudioSessionManager.shared.configureForSilentPlayback()
        case .tenorGif, .giphyGif:
          model.isMuted = true
          model.volume = 0
          // GIFs don't need audio session configuration
        }
        VideoCoordinator.shared.register(model, player: newPlayer)
      }
    } catch {
      logger.debug("Failed to setup player: \(error)")
    }
  }

  private func cleanupPlayer() {

    if VideoCoordinator.shared.shouldPreserveStream(for: model.id) {
      logger.debug("💾 Preserving video stream for \(model.id) during scroll")
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      return
    }

    logger.debug("🧹 Fully cleaning up video \(model.id)")
    if case .hlsStream = model.type {
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
