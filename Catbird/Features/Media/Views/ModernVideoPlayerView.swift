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

// MARK: - Playback Position Provider

/// Registry for current playback positions of active videos (WS-J -> WS-E handoff)
public final class VideoPlaybackPositionProvider: @unchecked Sendable {
    public static let shared = VideoPlaybackPositionProvider()
    
    private let lock = NSLock()
    private var positions: [String: Double] = [:]
    
    public func setPosition(_ seconds: Double, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        positions[key] = seconds
    }
    
    public func getPosition(for key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return positions[key]
    }
    
    public func removePosition(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        positions.removeValue(forKey: key)
    }
    
    /// Look up position for any key matching postID, post URI, or CID
    public func getPosition(forSubject subjectKey: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if let exact = positions[subjectKey] {
            return exact
        }
        for (k, v) in positions {
            if k.contains(subjectKey) || subjectKey.contains(k) {
                return v
            }
        }
        return nil
    }
}

// MARK: - Main Player View

@available(iOS 17.0, *)
struct ModernVideoPlayerView: View {
  private let logger = Logger(subsystem: "blue.catbird", category: "ModernVideoPlayerView")

  // MARK: - Properties
  let model: VideoModel
  @State private var player: AVPlayer?
  @State private var timeObserverToken: Any?
  @State private var isVisible = false
  @State private var showControls = false
  @State private var showFullscreen = false
  @State private var loadFailed = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  let postID: String
  private var preparePlayer: (@MainActor (VideoModel) async throws -> AVPlayer)?
  private var registerPlayer: (@MainActor (VideoModel, AVPlayer) -> Void)?

  // For iOS 18+ transitions
  @Namespace private var videoTransitionNamespace

  // For iOS 17 transition effect
  @State private var playerScale: CGFloat = 1.0

  // Improved tap gesture tracking
  @GestureState private var isTapped = false
  @State private var muteButtonFrame = CGRect.zero

  // MARK: - Initializers

  // Primary initializer that takes a VideoModel directly
  init(
    model: VideoModel, postID: String,
    preparePlayer: (@MainActor (VideoModel) async throws -> AVPlayer)? = nil,
    registerPlayer: (@MainActor (VideoModel, AVPlayer) -> Void)? = nil
  ) {
    self.model = model
    self.postID = postID
    self.preparePlayer = preparePlayer
    self.registerPlayer = registerPlayer
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

    let videoType: VideoModel.VideoType
    if bskyVideo.presentation == "gif" {
      videoType = .bskyGif(
        playlistURL: playlistURL, cid: bskyVideo.cid, aspectRatio: aspectRatioStruct)
    } else {
      videoType = .hlsStream(
        playlistURL: playlistURL, cid: bskyVideo.cid, aspectRatio: aspectRatioStruct)
    }

    self.model = VideoModel(
      id: id,
      url: playlistURL,
      type: videoType,
      aspectRatio: ar,
      thumbnailURL: bskyVideo.thumbnail?.url,
      alt: bskyVideo.alt
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
        if !model.isPlaying && !appState.appSettings.autoplayVideos && !loadFailed,
           let thumbnailURL = model.thumbnailURL
        {
          ZStack {
            VideoThumbnailView(thumbnailURL: thumbnailURL, aspectRatio: model.aspectRatio)
            Image(systemName: "play.fill")
              .font(.title2)
              .foregroundStyle(.white)
              .frame(width: 52, height: 52)
              .background(.ultraThinMaterial, in: Circle())
              .accessibilityHidden(true)
          }
          .allowsHitTesting(false)  // Let taps pass through to the player
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { location in
        handleTap(location: location)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(videoAccessibilityLabel)
      .accessibilityAddTraits(.startsMediaSession)
      .accessibilityAction {
        handleAccessibilityActivate()
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
          // The existing player may be owned by PiP with a native mute change
          // still awaiting model synchronization. Let its guard run first.
          VideoCoordinator.shared.register(model, player: player)
        }
      }
      .onDisappear {
        // Fullscreen presents over this view, firing onDisappear while the same
        // AVPlayer is still playing in the cover. Skipping cleanup keeps the
        // coordinator from muting/pausing the shared player.
        if !showFullscreen {
          cleanupPlayer()
        }
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
        gravity: .resizeAspect,
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

    } else if loadFailed {
      ZStack {
        if let thumbnailURL = model.thumbnailURL {
          VideoThumbnailView(thumbnailURL: thumbnailURL, aspectRatio: model.aspectRatio)
        } else {
          Rectangle()
            .fill(Color.gray.opacity(0.3))
        }
        VStack(spacing: 8) {
          Label(model.type.isGif ? "GIF Unavailable" : "Video Unavailable", systemImage: "exclamationmark.triangle")
            .appFont(AppTextRole.subheadline)
          Button("Try Again") {
            Task { await setupPlayer() }
          }
          .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var videoAccessibilityLabel: String {
    let kind = model.type.isGif ? "GIF" : "Video"
    if loadFailed {
      return "\(kind) unavailable"
    }
    if let alt = model.alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
      return "\(kind): \(alt)"
    }
    return kind
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

  private func handleAccessibilityActivate() {
    if loadFailed {
      Task { await setupPlayer() }
    } else if !model.isPlaying && !appState.appSettings.autoplayVideos {
      VideoCoordinator.shared.forcePlayVideo(model.id)
    } else if case .hlsStream = model.type, player != nil {
      showFullscreen = true
    }
  }

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
    
    loadFailed = false

    // Create player
    do {
      let newPlayer: AVPlayer
      if let preparePlayer {
        newPlayer = try await preparePlayer(model)
      } else {
        newPlayer = try await VideoAssetManager.shared.preparePlayer(for: model)
      }
      await MainActor.run {
        self.player = newPlayer
        registerPreparedPlayer(newPlayer)
        
        // Observe playback time to publish current position for reporting (WS-E / WS-J handoff)
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let token = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [model = model, postID = postID] time in
            let seconds = time.seconds
            if seconds.isFinite && seconds >= 0 {
                VideoPlaybackPositionProvider.shared.setPosition(seconds, for: postID)
                VideoPlaybackPositionProvider.shared.setPosition(seconds, for: model.id)
                switch model.type {
                case .hlsStream(_, let cid, _), .bskyGif(_, let cid, _):
                    VideoPlaybackPositionProvider.shared.setPosition(seconds, for: cid.string)
                default:
                    break
                }
            }
        }
        self.timeObserverToken = token
      }
    } catch {
      logger.debug("Failed to setup player: \(error)")
      if !Task.isCancelled {
        loadFailed = true
      }
    }
  }

  private func registerPreparedPlayer(_ player: AVPlayer) {
    // A new model supplies the muted default. Recreating a player for an
    // existing model must retain the user's current mute and volume choices.
    player.isMuted = model.isMuted
    player.volume = model.isMuted ? 0 : model.volume
    if let registerPlayer {
      registerPlayer(model, player)
    } else {
      if model.isMuted { AudioSessionManager.shared.configureForSilentPlayback() }
      VideoCoordinator.shared.register(model, player: player)
    }
  }

  private func cleanupPlayer() {
    if let player = player {
      let seconds = player.currentTime().seconds
      if seconds.isFinite && seconds >= 0 {
        VideoPlaybackPositionProvider.shared.setPosition(seconds, for: postID)
        VideoPlaybackPositionProvider.shared.setPosition(seconds, for: model.id)
        switch model.type {
        case .hlsStream(_, let cid, _), .bskyGif(_, let cid, _):
            VideoPlaybackPositionProvider.shared.setPosition(seconds, for: cid.string)
        default:
            break
        }
      }
    }
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    
    if VideoCoordinator.shared.isPictureInPictureActive(model.id) {
      logger.debug("📺 PiP active for \(model.id), keeping player alive")
      VideoCoordinator.shared.updateVisibility(false, for: model.id)
      return
    }

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
      // Pausing here would end an active PiP session when the app backgrounds
      if !VideoCoordinator.shared.isPictureInPictureActive(model.id) {
        player?.pause()
      }
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

  var body: some View {
    Button(action: toggleMute) {
      Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Color.black.opacity(0.6)))
    }
    .padding(4)
    .contentShape(Circle().scale(1.5))
    .buttonStyle(MuteButtonStyle())
    .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
  }

  private func toggleMute() {
    // Muted now means the user is asking to unmute.
    VideoCoordinator.shared.setUnmuted(model.id, unmuted: model.isMuted)
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
