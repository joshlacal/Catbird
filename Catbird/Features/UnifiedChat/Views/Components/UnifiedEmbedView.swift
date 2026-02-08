import AVFoundation
import NukeUI
import OSLog
import Petrel
import SwiftUI

/// Renders different embed types in chat messages
struct UnifiedEmbedView: View {
  let embed: UnifiedEmbed
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    switch embed {
    case .blueskyRecord(let record):
      RecordEmbedContainer(
        uriString: record.uri,
        title: "Shared Post",
        subtitle: nil,
        navigationPath: $navigationPath
      )

    case .link(let link):
      linkEmbed(link)

    case .gif(let gif):
      gifEmbed(gif)

    case .post(let post):
      RecordEmbedContainer(
        uriString: post.uri,
        title: post.authorHandle.map { "@\($0)" } ?? "Shared Post",
        subtitle: post.text,
        navigationPath: $navigationPath
      )
    }
  }

  // MARK: - Link Embed

  @ViewBuilder
  private func linkEmbed(_ link: LinkEmbedData) -> some View {
    Link(destination: link.url) {
      VStack(alignment: .leading, spacing: 8) {
        // Thumbnail
        if let thumbURL = link.thumbnailURL {
          LazyImage(url: thumbURL) { state in
            if let image = state.image {
              image
                .resizable()
                .scaledToFill()
            } else {
              Rectangle()
                .fill(Color.gray.opacity(0.2))
            }
          }
          .frame(height: 120)
          .frame(maxWidth: .infinity)
          .clipped()
        }

        VStack(alignment: .leading, spacing: 4) {
          // Title
          if let title = link.title {
            Text(title)
              .font(.caption)
              .fontWeight(.medium)
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }

          // Description
          if let description = link.description {
            Text(description)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }

          // Domain
          Text(link.url.host ?? link.url.absoluteString)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  // MARK: - GIF Embed

  @ViewBuilder
  private func gifEmbed(_ gif: GIFEmbedData) -> some View {
    // MLS currently provides Tenor MP4 URLs (not image/gif data), so render via video player.
    UnifiedGIFView(gif: gif)
  }
}

// MARK: - Unified GIF View

/// Renders Tenor GIFs as looping MP4s using an AVPlayerLayer-backed view (no VideoModel/VideoCoordinator).
private struct UnifiedGIFView: View {
  let gif: GIFEmbedData

  @State private var loopingPlayer: LoopingPlayerWrapper?
  @State private var isLoading = true
  @State private var loadError: String?
  @State private var playerObservers: [NSObjectProtocol] = []

  @Environment(\.scenePhase) private var scenePhase

  private let minBubbleHeight: CGFloat = 140

  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedGIFView")

  var body: some View {
    Group {
      if let player = loopingPlayer?.player {
        playerView(player)
      } else if isLoading {
        loadingView
      } else if let error = loadError {
        errorView(error)
      } else {
        placeholderView
      }
    }
    .frame(maxWidth: .infinity)
    .task {
      await setupPlayerIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard let player = loopingPlayer?.player else { return }
      switch newPhase {
      case .active:
        player.safePlay()
      default:
        player.pause()
      }
    }
    .onDisappear {
      teardown()
    }
  }

  // MARK: - Player View

  @ViewBuilder
  private func playerView(_ player: AVPlayer) -> some View {
    ZStack {
      if let previewURL = gif.previewURL {
        LazyImage(url: previewURL) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          }
        }
        .clipped()
        .opacity(0.8)
      } else {
        Color.black.opacity(0.1)
      }

      PlayerLayerView(
        player: player,
        gravity: .resizeAspect,
        // Looping is handled by AVPlayerLooper inside LoopingPlayerWrapper.
        shouldLoop: false,
        onLayerReady: nil
      )
    }
    .aspectRatio(calculateAspectRatio(), contentMode: .fit)
    .frame(maxWidth: .infinity)
    .frame(minHeight: minBubbleHeight, maxHeight: 400)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Loading State

  @ViewBuilder
  private var loadingView: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.gray.opacity(0.1))

      if let previewURL = gif.previewURL {
        LazyImage(url: previewURL) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          }
        }
        .clipped()
        .opacity(0.8)
      }

      ProgressView()
        .scaleEffect(1.2)
    }
    .aspectRatio(calculateAspectRatio(), contentMode: .fit)
    .frame(maxWidth: .infinity)
    .frame(minHeight: minBubbleHeight, maxHeight: 400)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Error State

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.red.opacity(0.1))

      VStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 32))
          .foregroundStyle(.red)

        Text("Failed to load GIF")
          .font(.callout)
          .fontWeight(.semibold)

        Text(error)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding()
    }
    .aspectRatio(calculateAspectRatio(), contentMode: .fit)
    .frame(maxWidth: .infinity)
    .frame(minHeight: minBubbleHeight, maxHeight: 400)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Placeholder State

  @ViewBuilder
  private var placeholderView: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Tenor GIF", systemImage: "play.rectangle.fill")
        .font(.callout)
        .foregroundStyle(Color.accentColor)

      Text("Tap to retry")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.gray.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .onTapGesture {
      Task { await setupPlayerIfNeeded(force: true) }
    }
  }

  // MARK: - Player Setup

  private func setupPlayerIfNeeded(force: Bool = false) async {
    if !force, loopingPlayer != nil { return }

    isLoading = true
    loadError = nil

    let url = gif.url
    logger.debug("Tenor GIF setup start url=\(url, privacy: .public) preview=\(gif.previewURL?.absoluteString ?? "nil", privacy: .public) size=\(gif.width ?? -1)x\(gif.height ?? -1)")

    let wrapper = LoopingPlayerWrapper(url: url)

    guard let wrapper else {
      await MainActor.run {
        isLoading = false
        loadError = "Could not create a looping player"
      }
      logger.error("Tenor GIF setup failed: could not create LoopingPlayerWrapper for url=\(url, privacy: .public)")
      return
    }

    await MainActor.run {
      teardownDiagnostics()

      loopingPlayer = wrapper
      isLoading = false

      wrapper.player.configureForFeedPreview()
      installDiagnostics(for: wrapper.player, url: url)
      wrapper.player.safePlay()

      logger.debug("Tenor GIF setup done; timeControl=\(String(describing: wrapper.player.timeControlStatus.rawValue), privacy: .public)")

      Task { @MainActor in
        // Small delayed snapshot helps diagnose "blank layer" cases where the item never becomes ready.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let status = wrapper.player.currentItem?.status
        let error = wrapper.player.currentItem?.error
        logger.debug(
          "Tenor GIF snapshot: itemStatus=\(String(describing: status?.rawValue), privacy: .public) timeControl=\(String(describing: wrapper.player.timeControlStatus.rawValue), privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func teardown() {
    teardownDiagnostics()
    loopingPlayer?.player.pause()
    loopingPlayer = nil
  }

  // MARK: - Helpers

  private func calculateAspectRatio() -> CGFloat {
    guard let width = gif.width, let height = gif.height, height > 0 else {
      return 16.0 / 9.0
    }
    return CGFloat(width) / CGFloat(height)
  }

  private func installDiagnostics(for player: AVPlayer, url: URL) {
    guard let item = player.currentItem else {
      logger.error("Tenor GIF diagnostics: missing currentItem for url=\(url, privacy: .public)")
      return
    }

    let center = NotificationCenter.default

    playerObservers.append(
      center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        logger.error("Tenor GIF failedToPlayToEnd url=\(url, privacy: .public) error=\(String(describing: error), privacy: .public)")
      }
    )

    playerObservers.append(
      center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
        logger.debug("Tenor GIF playbackStalled url=\(url, privacy: .public)")
      }
    )

    playerObservers.append(
      center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { _ in
        let err = item.errorLog()?.events.last
        logger.error("Tenor GIF errorLog url=\(url, privacy: .public) domain=\(err?.errorDomain ?? "nil", privacy: .public) status=\(String(describing: err?.errorStatusCode), privacy: .public) comment=\(err?.errorComment ?? "nil", privacy: .public)")
      }
    )

    playerObservers.append(
      center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { _ in
        let ev = item.accessLog()?.events.last
        logger.debug("Tenor GIF accessLog url=\(url, privacy: .public) indicatedBitrate=\(String(describing: ev?.indicatedBitrate), privacy: .public) observedBitrate=\(String(describing: ev?.observedBitrate), privacy: .public)")
      }
    )
  }

  private func teardownDiagnostics() {
    guard !playerObservers.isEmpty else { return }
    for observer in playerObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    playerObservers.removeAll()
  }
}

// MARK: - Record Embed (Bluesky + MLS)

private struct RecordEmbedContainer: View {
  let uriString: String
  let title: String
  let subtitle: String?
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var record: AppBskyEmbedRecord.ViewRecordUnion?
  @State private var isLoading = false
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedEmbed.Record")

  var body: some View {
    Group {
      if let record {
        RecordEmbedView(record: record, labels: nil, path: $navigationPath)
          .environment(\.postID, uriString)
          .foregroundStyle(.primary)
      } else if isLoading {
        loadingView
      } else if let error = loadError {
        errorView(error)
      } else {
        placeholderView
      }
    }
    .task {
      if record == nil {
        await loadRecord(force: false)
      }
    }
  }

  @ViewBuilder
  private var placeholderView: some View {
    Button {
      Task { await loadRecord(force: true) }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "quote.bubble")
            .foregroundStyle(.secondary)
          Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
        }

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        } else {
          Text(uriString)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var loadingView: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading post…")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .embedCardStyle(colorScheme: colorScheme)
  }

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    Button {
      Task { await loadRecord(force: true) }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Label("Failed to load post", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)

        Text(error)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        Text("Tap to retry")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  private func mapEmbeds(
    from embed: AppBskyFeedDefs.PostViewEmbedUnion
  ) -> [AppBskyEmbedRecord.ViewRecordEmbedsUnion] {
    switch embed {
    case .appBskyEmbedImagesView(let imageView):
      return [.appBskyEmbedImagesView(imageView)]
    case .appBskyEmbedExternalView(let externalView):
      return [.appBskyEmbedExternalView(externalView)]
    case .appBskyEmbedRecordView(let recordView):
      return [.appBskyEmbedRecordView(recordView)]
    case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
      return [.appBskyEmbedRecordWithMediaView(recordWithMediaView)]
    case .appBskyEmbedVideoView(let videoView):
      return [.appBskyEmbedVideoView(videoView)]
    case .unexpected:
      return []
    }
  }

  @MainActor
  private func loadRecord(force: Bool) async {
    guard !isLoading else { return }

    if !force, let cached = RecordEmbedCache.cache[uriString] {
      record = cached
      return
    }

    guard let uri = try? ATProtocolURI(uriString: uriString) else {
      loadError = "Invalid post URI"
      return
    }

    guard let client = appState.atProtoClient else {
      loadError = "AT Protocol client not available"
      return
    }

    isLoading = true
    loadError = nil

    do {
      let (responseCode, response) = try await client.app.bsky.feed.getPosts(
        input: .init(uris: [uri])
      )

      guard responseCode == 200, let post = response?.posts.first else {
        isLoading = false
        loadError = "Post not found"
        return
      }

      let embeds: [AppBskyEmbedRecord.ViewRecordEmbedsUnion]? = post.embed.flatMap { embed in
        let mapped = mapEmbeds(from: embed)
        return mapped.isEmpty ? nil : mapped
      }

      let viewRecord = AppBskyEmbedRecord.ViewRecord(
        uri: post.uri,
        cid: post.cid,
        author: post.author,
        value: post.record,
        labels: post.labels,
        replyCount: post.replyCount,
        repostCount: post.repostCount,
        likeCount: post.likeCount,
        quoteCount: post.quoteCount,
        embeds: embeds,
        indexedAt: post.indexedAt
      )

      let union = AppBskyEmbedRecord.ViewRecordUnion.appBskyEmbedRecordViewRecord(viewRecord)
      RecordEmbedCache.cache[uriString] = union
      record = union

      logger.debug("Loaded record embed: \(uriString)")
    } catch {
      loadError = error.localizedDescription
      logger.error("Failed to load record embed: \(error.localizedDescription)")
    }

    isLoading = false
  }

  @MainActor
  private enum RecordEmbedCache {
    static var cache: [String: AppBskyEmbedRecord.ViewRecordUnion] = [:]
  }
}

// MARK: - Embed Card Style

extension View {
  fileprivate func embedCardStyle(colorScheme: ColorScheme) -> some View {
    self
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.8))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.gray.opacity(0.2), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    UnifiedEmbedView(
      embed: .link(
        LinkEmbedData(
          url: URL(string: "https://example.com")!,
          title: "Example Article Title",
          description: "This is a description of the linked content.",
          thumbnailURL: nil
        )),
      navigationPath: .constant(NavigationPath())
    )

    UnifiedEmbedView(
      embed: .blueskyRecord(
        recordData: BlueskyRecordEmbedData(
          uri: "at://did:plc:123/app.bsky.feed.post/abc",
          cid: "bafyreib..."
        )),
      navigationPath: .constant(NavigationPath())
    )
  }
  .padding()
}
