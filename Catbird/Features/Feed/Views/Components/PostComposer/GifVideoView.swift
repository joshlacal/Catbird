import SwiftUI
import AVFoundation
import AVKit
import NukeUI

/// A view that displays Tenor GIFs as looping MP4 videos for proper animation
struct GifVideoView: View {
    let gif: TenorGif
    let onTap: () -> Void
    
    @State private var player: AVPlayer?
    @State private var hasError = false
    
    var body: some View {
        Button(action: onTap) {
            Group {
                if hasError {
                    // Fallback to static image if video fails
                    fallbackImageView
                } else if let player = player {
                    // Use existing PlayerLayerView for proper video rendering
                    PlayerLayerView(
                        player: player,
                        gravity: .resizeAspectFill,
                        size: CGSize(width: 200, height: 200 / aspectRatio),
                        shouldLoop: true
                    )
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipped()
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
        .onAppear {
            setupVideoPlayer()
        }
        .onDisappear {
            cleanupPlayer()
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
    
    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray6))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                ProgressView()
            )
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            )
    }
    
    private func setupVideoPlayer() {
        guard let videoURL = bestVideoURL else {
            hasError = true
            return
        }
        
        let playerItem = AVPlayerItem(url: videoURL)
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Configure for GIF-like behavior
        avPlayer.isMuted = true // GIFs are silent
        avPlayer.actionAtItemEnd = .none
        
        // Set up looping notification
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            avPlayer.seek(to: .zero)
            avPlayer.play()
        }
        
        // Monitor for player errors
        NotificationCenter.default.addObserver(
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
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Get the best video URL for animation from Tenor's media formats
    private var bestVideoURL: URL? {
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
        // Try to get dimensions from the best available video format
        if let mp4 = gif.media_formats.mp4, mp4.dims.count >= 2 {
            let width = CGFloat(mp4.dims[0])
            let height = CGFloat(mp4.dims[1])
            return width / height
        } else if let loopedMP4 = gif.media_formats.loopedmp4, loopedMP4.dims.count >= 2 {
            let width = CGFloat(loopedMP4.dims[0])
            let height = CGFloat(loopedMP4.dims[1])
            return width / height
        } else if let tinyMP4 = gif.media_formats.tinymp4, tinyMP4.dims.count >= 2 {
            let width = CGFloat(tinyMP4.dims[0])
            let height = CGFloat(tinyMP4.dims[1])
            return width / height
        }
        // Default to square aspect ratio if no dimensions available
        return 1.0
    }
}

