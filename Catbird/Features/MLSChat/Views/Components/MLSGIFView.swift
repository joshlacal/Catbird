import CatbirdMLSCore
import SwiftUI
import OSLog
import Petrel

#if os(iOS)

/// Renders Tenor GIFs as videos in MLS messages (similar to ExternalEmbedView video player)
struct MLSGIFView: View {
  let gifEmbed: MLSGIFEmbed

  @Environment(AppState.self) private var appState
  @State private var videoModel: VideoModel?
  @State private var isLoading = true
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSGIFView")

  var body: some View {
    Group {
      if let videoModel = videoModel {
        videoPlayerView(videoModel)
      } else if isLoading {
        loadingView
      } else if let error = loadError {
        errorView(error)
      } else {
        placeholderView
      }
    }
    .frame(maxWidth: .infinity)
    .onAppear {
      setupVideo()
    }
  }

  // MARK: - Video Player View

  @ViewBuilder
  private func videoPlayerView(_ model: VideoModel) -> some View {
    ModernVideoPlayerView(
      model: model,
      postID: "mls-gif-\(gifEmbed.mp4URL.hashValue)"
    )
    .frame(maxWidth: .infinity)
    .frame(maxHeight: min(calculateHeight(width: gifEmbed.width, height: gifEmbed.height), 400))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
  }

  // MARK: - Loading State

  @ViewBuilder
  private var loadingView: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.gray.opacity(0.1))
        .frame(height: 200)

      VStack(spacing: DesignTokens.Spacing.sm) {
        ProgressView()
          .scaleEffect(1.2)

        Text("Loading GIF...")
          .designFootnote()
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Error State

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.red.opacity(0.1))
        .frame(height: 200)

      VStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 32))
          .foregroundColor(.red)

        Text("Failed to load GIF")
          .designBody()
          .fontWeight(.semibold)

        Text(error)
          .designCaption()
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding()
    }
  }

  // MARK: - Placeholder State

  @ViewBuilder
  private var placeholderView: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Label("Tenor GIF", systemImage: "play.rectangle.fill")
        .appBody()
        .foregroundColor(.accentColor)

      if let title = gifEmbed.title {
        Text(title)
          .appFootnote()
          .foregroundColor(.primary)
      }

      Text("Tap to retry")
        .appCaption()
        .foregroundColor(.secondary)
    }
    .spacingSM()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(10)
    .onTapGesture {
      setupVideo()
    }
  }

  // MARK: - Video Setup

  private func setupVideo() {
    guard videoModel == nil else { return }

    isLoading = true
    loadError = nil

    // Validate MP4 URL
    guard let mp4URL = URL(string: gifEmbed.mp4URL) else {
      loadError = "Invalid video URL"
      isLoading = false
      logger.error("Invalid MP4 URL: \(gifEmbed.mp4URL)")
      return
    }

    // Tenor "GIFs" are MP4s; don't hard-fail based on MIME/header quirks.
    // If the URL is reachable, the player will handle buffering/errors.
    Task { @MainActor in
      let uri = URI(uriString: gifEmbed.tenorURL)

      videoModel = VideoModel(
        id: "mls-gif-\(gifEmbed.mp4URL.hashValue)",
        url: mp4URL,
        type: .tenorGif(uri),
        aspectRatio: calculateAspectRatio(width: gifEmbed.width, height: gifEmbed.height),
        thumbnailURL: gifEmbed.thumbnailURL.flatMap { URL(string: $0) }
      )

      isLoading = false
      logger.info("Created VideoModel for GIF: \(mp4URL)")
    }
  }

  // MARK: - Helpers

  private func calculateAspectRatio(width: Int?, height: Int?) -> CGFloat {
    guard let width = width, let height = height, height > 0 else {
      return 16.0 / 9.0 // Default aspect ratio
    }
    return CGFloat(width) / CGFloat(height)
  }

  private func calculateHeight(width: Int?, height: Int?) -> CGFloat {
    guard let width = width, let height = height, width > 0 else {
      return 300 // Default height
    }

    let aspectRatio = CGFloat(width) / CGFloat(height)
    let screenWidth = PlatformScreenInfo.width - 80 // Account for message padding
    return screenWidth / aspectRatio
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  VStack(spacing: 20) {
    // GIF with dimensions
    MLSGIFView(
      gifEmbed: MLSGIFEmbed(
        tenorURL: "https://tenor.com/view/...",
        mp4URL: "https://media.tenor.com/example/video.mp4",
        title: "Dancing Cat",
        thumbnailURL: "https://media.tenor.com/example/thumbnail.jpg",
        width: 498,
        height: 280
      )
    )

    // GIF without dimensions
    MLSGIFView(
      gifEmbed: MLSGIFEmbed(
        tenorURL: "https://tenor.com/view/...",
        mp4URL: "https://media.tenor.com/example2/video.mp4",
        title: "Funny Reaction",
        thumbnailURL: nil,
        width: nil,
        height: nil
      )
    )
  }
  .padding()
  .environment(AppStateManager.shared)
}

#endif
