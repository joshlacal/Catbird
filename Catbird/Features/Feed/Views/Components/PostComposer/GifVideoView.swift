import SwiftUI
import AVFoundation
import AVKit
import NukeUI

/// A view that displays Tenor GIFs as looping MP4 videos for proper animation
struct GifVideoView: View {
    /// Which MP4 rendition to stream.
    enum Rendition: Equatable {
        /// The full-size rendition, for a GIF shown at composer width.
        case full
        /// The smallest rendition that still looks sharp at this pixel width, with a still
        /// poster until the first frame. Grids show many of these at once.
        case tile(pixelWidth: CGFloat)
    }

    let gif: TenorGif
    let onTap: () -> Void
    var rendition: Rendition = .full
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var hasError = false
    @State private var isVisibleOnScreen = false
    /// Grid tiles start playing when about half visible, not at the first sliver (P179).
    private let visibilityThreshold: Double = 0.5
    @State private var observerToken: (any NSObjectProtocol)?
    
    var body: some View {
        Button(action: onTap) {
            Group {
                if hasError {
                    // Fallback to static image if video fails
                    fallbackImageView
                } else if let player = player {
                    // Use existing PlayerLayerView for proper video rendering. It stays
                    // transparent until its first frame, so the poster shows through.
                    PlayerLayerView(
                        player: player,
                        gravity: .resizeAspectFill,
                        shouldLoop: true
                    )
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .background { posterView }
                    .clipped()
                } else if isTile {
                    posterView
                } else {
                    // Loading state
                    loadingView
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .cornerRadius(8)
            .overlay(
                // GIF indicator overlay
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("GIF")
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onScrollVisibilityChange(threshold: visibilityThreshold) { isVisible in
            handleVisibilityChange(isVisible)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onDisappear {
            cleanupPlayer()
            isVisibleOnScreen = false
        }
    }
    
    @ViewBuilder
    private var fallbackImageView: some View {
        LazyImage(url: fallbackImageURL) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipped()
            } else if state.isLoading {
                loadingView
            } else {
                placeholderView
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .cornerRadius(8)
    }
    
    /// A still frame under the player until its first frame: a small one for tiles, the
    /// full-size preview for a full view such as the selected GIF in the composer. Before a
    /// full view has a player it keeps its spinner.
    @ViewBuilder
    private var posterView: some View {
        if let posterURL {
            LazyImage(url: posterURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(aspectRatio, contentMode: .fill)
                } else {
                    Color.systemGray6
                }
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.systemGray6)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                ProgressView()
            )
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.systemGray5)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            )
    }

    private func handleVisibilityChange(_ visible: Bool) {
        Task { @MainActor in
            guard visible != isVisibleOnScreen else { return }
            isVisibleOnScreen = visible

            if visible {
                guard !hasError else { return }
                if player == nil {
                    setupVideoPlayer()
                } else {
                    player?.play()
                }
            } else {
                player?.pause()
            }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        Task { @MainActor in
            guard player != nil else { return }

            if newPhase == .active {
                if isVisibleOnScreen {
                    player?.play()
                }
            } else {
                player?.pause()
            }
        }
    }

    @MainActor
    private func setupVideoPlayer() {
        guard player == nil else {
            player?.play()
            return
        }

        guard let videoURL = bestVideoURL else {
            hasError = true
            return
        }

        let playerItem = AVPlayerItem(url: videoURL)
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Configure for GIF-like behavior (PlayerLayerView manages playback looping)
        avPlayer.isMuted = true // GIFs are silent
        avPlayer.actionAtItemEnd = .none
        
        // Monitor for player errors
        observerToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.hasError = true
        }
        
        self.player = avPlayer
        
        // Start playing immediately
        avPlayer.play()
    }
    
    @MainActor
    private func cleanupPlayer() {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
            self.observerToken = nil
        }
        player?.pause()
        player = nil
    }

    private var isTile: Bool {
        if case .tile = rendition { return true }
        return false
    }

    private var bestVideoURL: URL? {
        Self.videoURL(for: gif, rendition: rendition)
    }

    static func videoURL(for gif: TenorGif, rendition: Rendition) -> URL? {
        switch rendition {
        case .full:
            return fullVideoURL(for: gif)
        case .tile(let pixelWidth):
            return tileVideoURL(for: gif, pixelWidth: pixelWidth) ?? fullVideoURL(for: gif)
        }
    }

    /// The smallest MP4 at least three quarters as wide as the tile, falling back to the
    /// regular MP4. Tiles never stream `loopedmp4`, which repeats the clip to lengthen it;
    /// the player loops by itself.
    private static func tileVideoURL(for gif: TenorGif, pixelWidth: CGFloat) -> URL? {
        let formats = gif.media_formats
        let ascending = [formats.nanomp4, formats.tinymp4, formats.mp4].compactMap { $0 }
        let minimumWidth = pixelWidth * 0.75
        let chosen = ascending.first { format in
            guard let width = format.dims.first else { return false }
            return CGFloat(width) >= minimumWidth
        } ?? formats.mp4 ?? ascending.last
        return chosen.flatMap { URL(string: $0.url) }
    }

    private var posterURL: URL? {
        Self.posterURL(for: gif, rendition: rendition)
    }

    static func posterURL(for gif: TenorGif, rendition: Rendition) -> URL? {
        let formats = gif.media_formats
        let poster: TenorMediaItem?
        switch rendition {
        case .tile:
            poster = formats.tinygifpreview ?? formats.nanogifpreview ?? formats.gifpreview
        case .full:
            poster = formats.gifpreview ?? formats.tinygifpreview ?? formats.nanogifpreview
        }
        return poster.flatMap { URL(string: $0.url) }
    }

    /// Get the best video URL for animation from Tenor's media formats
    private static func fullVideoURL(for gif: TenorGif) -> URL? {
        // Priority: loopedmp4 > mp4 > tinymp4 > nanomp4
        if let loopedMP4 = gif.media_formats.loopedmp4 {
            return URL(string: loopedMP4.url)
        } else if let mp4 = gif.media_formats.mp4 {
            return URL(string: mp4.url)
        } else if let tinyMP4 = gif.media_formats.tinymp4 {
            return URL(string: tinyMP4.url)
        } else if let nanoMP4 = gif.media_formats.nanomp4 {
            return URL(string: nanoMP4.url)
        }
        return nil
    }
    
    /// Fallback image URL if video fails to load
    private var fallbackImageURL: URL? {
        // Use preview images as fallback
        if let gifPreview = gif.media_formats.gifpreview {
            return URL(string: gifPreview.url)
        } else if let tinyGifPreview = gif.media_formats.tinygifpreview {
            return URL(string: tinyGifPreview.url)
        } else if let nanoGifPreview = gif.media_formats.nanogifpreview {
            return URL(string: nanoGifPreview.url)
        }
        return nil
    }
    
    /// Calculate aspect ratio from Tenor's media format dimensions
    private var aspectRatio: CGFloat {
        func safeRatio(_ dims: [Int]) -> CGFloat? {
            guard dims.count >= 2 else { return nil }
            let width = CGFloat(dims[0])
            let height = CGFloat(dims[1])
            guard width > 0, height > 0 else { return nil }
            let ratio = width / height
            return (ratio.isFinite && ratio > 0) ? ratio : nil
        }

        // Try to get dimensions from the best available video format
        if let mp4 = gif.media_formats.mp4, let ratio = safeRatio(mp4.dims) {
            return ratio
        } else if let loopedMP4 = gif.media_formats.loopedmp4, let ratio = safeRatio(loopedMP4.dims) {
            return ratio
        } else if let tinyMP4 = gif.media_formats.tinymp4, let ratio = safeRatio(tinyMP4.dims) {
            return ratio
        }

        // Default to square aspect ratio if no/invalid dimensions available
        return 1.0
    }
}
