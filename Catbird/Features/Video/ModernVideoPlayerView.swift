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

struct ModernVideoPlayerView: View {
    // MARK: - Properties
    let model: VideoModel
    @State private var player: AVPlayer?
    @State private var isVisible = false
    @State private var showControls = false
    @State private var showFullscreen = false
    @Environment(\.scenePhase) private var scenePhase
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
        
        let aspectRatio = bskyVideo.aspectRatio.map {
            CGFloat($0.width) / CGFloat($0.height)
        } ?? 16 / 9
        
        // Use postID in the model's ID
        self.model = VideoModel(
            id: "\(postID)-\(bskyVideo.playlist.uriString())-\(bskyVideo.cid)",
            url: playlistURL,
            type: .hlsStream(bskyVideo),
            aspectRatio: aspectRatio
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
            aspectRatio: aspectRatio ?? 1
        )
        self.postID = postID
    }
    
    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                // Video Player Layer
                if let player = player {
                    PlayerLayerView(
                        player: player,
                        gravity: model.type.isGif ? .resizeAspectFill : .resizeAspect,
                        size: CGSize(
                            width: geometry.size.width,
                            height: geometry.size.width / model.aspectRatio
                        ),
                        shouldLoop: true
                    )
                    .matchedTransitionSource(id: model.id, in: videoTransitionNamespace) { source in
                      source
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.size.width / model.aspectRatio)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // Check if tap is not on the mute button
                        if !muteButtonFrame.contains(location), case .hlsStream = model.type {
                            // Full-screen video should only be available for HLS videos
                            showFullscreen = true
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Mute toggle button overlaid at the bottom right
                // Only show for HLS videos, not for GIFs
                if let player = player, case .hlsStream = model.type {
                    MuteButton(player: player, model: model)
                        .padding(12)
                        .background(
                            GeometryReader { geo -> Color in
                                Task { @MainActor in
                                    // Store the frame of the mute button for hit-testing
                                    muteButtonFrame = geo.frame(in: .global)
                                }
                                return Color.clear
                            }
                        )
                        .contentShape(Circle())
                        .allowsHitTesting(true)
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
                case .hlsStream:
                    model.isMuted = true
                    model.volume = 0
                case .tenorGif:
                    player.isMuted = true
                    model.isMuted = true
                    model.volume = 0
                }
                
                VideoCoordinator.shared.register(model, player: player)
            }
        } catch {
            logger.debug("Failed to setup player: \(error)")
        }
    }
    
    /// Clean up resources when view disappears
    private func cleanupPlayer() {
        player?.pause()
        model.isPlaying = false
        VideoCoordinator.shared.unregister(model.id)
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
}

// MARK: - Mute Button Component

/// Separate component for the mute button to improve tap targeting
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

// MARK: - Custom Button Style

/// Custom button style to improve tap handling in nested views
struct MuteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .allowsHitTesting(true)
    }
}
