//
//  FullscreenVideoPlayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

// Simplified version that uses the built-in Done button
import SwiftUI
import AVKit
import Petrel

struct FullscreenVideoPlayerView: View {
    let originalPlayer: AVPlayer
    let model: VideoModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        
        AVPlayerViewControllerWrapper(player: originalPlayer, onDismiss: {
            dismiss()
        })
        .ignoresSafeArea()
        .statusBar(hidden: true)
        .onAppear {
            // Unmute for fullscreen viewing
            AudioSessionManager.shared.handleVideoUnmute()
            originalPlayer.isMuted = false
            originalPlayer.volume = 1.0
        }
        .onDisappear {
            // Restore muted state for feed if needed
            if model.isMuted {
                originalPlayer.isMuted = true
                originalPlayer.volume = 0
            }
        }
        // Enable swipe to dismiss
        .interactiveDismissDisabled(false)
    }
}

struct AVPlayerViewControllerWrapper: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        
        // Configure for fullscreen experience
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.updatesNowPlayingInfoCenter = true
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Nothing to update
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: AVPlayerViewControllerWrapper
        
        init(_ parent: AVPlayerViewControllerWrapper) {
            self.parent = parent
        }
        
        // This is called when the user taps the built-in "Done" button
        func playerViewControllerDidEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
            parent.onDismiss()
        }
    }
}
