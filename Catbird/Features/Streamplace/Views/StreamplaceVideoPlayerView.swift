import AVKit
import SwiftUI

struct StreamplaceVideoPlayerView: View {
  let video: StreamplaceService.VideoRecord
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer?

  var body: some View {
    AVPlayerViewControllerRepresentable(player: player, onDismiss: { dismiss() })
      .ignoresSafeArea()
      .background(.black)
      .task {
        let avPlayer = AVPlayer(url: video.hlsURL)
        player = avPlayer
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        avPlayer.play()
      }
      .onDisappear {
        player?.pause()
        player = nil
      }
  }
}

#if os(iOS)
private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
  let player: AVPlayer?
  let onDismiss: () -> Void

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let vc = AVPlayerViewController()
    vc.player = player
    vc.allowsPictureInPicturePlayback = true
    vc.delegate = context.coordinator
    return vc
  }

  func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
    if vc.player !== player {
      vc.player = player
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onDismiss: onDismiss)
  }

  class Coordinator: NSObject, AVPlayerViewControllerDelegate {
    let onDismiss: () -> Void
    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
      coordinator.animate(alongsideTransition: nil) { _ in
        self.onDismiss()
      }
    }
  }
}
#elseif os(macOS)
private struct AVPlayerViewControllerRepresentable: NSViewRepresentable {
  let player: AVPlayer?
  let onDismiss: () -> Void

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    return view
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    if nsView.player !== player {
      nsView.player = player
    }
  }
}
#endif
