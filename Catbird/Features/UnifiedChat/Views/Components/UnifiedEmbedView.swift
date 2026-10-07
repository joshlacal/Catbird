import AVFoundation
import NukeUI
import OSLog
import Petrel
import SwiftUI

/// Renders different embed types in chat messages
struct UnifiedEmbedView: View {
  let embed: UnifiedEmbed
  var isOwnMessage: Bool = false
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    switch embed {
    case .blueskyRecord(let record):
      RecordEmbedContainer(
        uriString: record.uri,
        accountDID: appState.userDID,
        title: "Shared Post",
        subtitle: nil,
        navigationPath: $navigationPath
      )
      .id("\(ObjectIdentifier(appState)):\(String(describing: appState.atProtoClient.map(ObjectIdentifier.init))):\(record.uri)")

    case .link(let link):
      linkEmbed(link)

    case .gif(let gif):
      gifEmbed(gif)

    case .post(let post):
      RecordEmbedContainer(
        uriString: post.uri,
        accountDID: appState.userDID,
        title: post.authorHandle.map { "@\($0)" } ?? "Shared Post",
        subtitle: post.text,
        navigationPath: $navigationPath
      )
      .id("\(ObjectIdentifier(appState)):\(String(describing: appState.atProtoClient.map(ObjectIdentifier.init))):\(post.uri)")

    case .groupInvite(let invite):
      groupInviteEmbed(invite)
    }
  }

  // MARK: - Group Invite Embed

  /// Invite card for group join links. Tapping routes the link through the
  /// scene's URL handler, which presents the group join sheet.
  @ViewBuilder
  private func groupInviteEmbed(_ invite: GroupInviteEmbedData) -> some View {
    switch invite {
    case .preview(let name, let memberCount, let memberLimit, let code):
      Button {
        if let url = URL(string: "https://bsky.app/chat/\(code)") {
          _ = sceneContext.urlHandler.handle(url)
        }
      } label: {
        groupInviteCard(name: name, memberCount: memberCount, memberLimit: memberLimit)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the group invite")
      .contextMenu {
        Button {
          PlatformApplication.copyToClipboard("https://bsky.app/chat/\(code)")
        } label: {
          Label("Copy Invite Link", systemImage: "doc.on.doc")
        }
      }

    case .unavailable:
      HStack(spacing: 8) {
        Image(systemName: "person.2.slash")
          .foregroundStyle(.secondary)
        Text("This invite is no longer available")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
  }

  private func groupInviteCard(name: String, memberCount: Int, memberLimit: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: "person.2.fill")
          .foregroundStyle(.secondary)
        Text(name)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }

      Text("Group invite · \(memberCount) of \(memberLimit) members")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .embedCardStyle(colorScheme: colorScheme)
    .contentShape(Rectangle())
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
    // Tenor GIFs arrive as MP4 URLs (not image/gif data), so render via video player.
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

  /// Corner radius matches the bubble in `UnifiedMessageBubble`.
  private let bubbleCornerRadius: CGFloat = 18

  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedGIFView")

  var body: some View {
    Group {
      if let player = loopingPlayer?.player {
        ChatMediaAspectLayout(gif: gif) { playerView(player) }
      } else if isLoading {
        ChatMediaAspectLayout(gif: gif) { loadingView }
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
    .frame(maxWidth: .infinity)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
  }

  // MARK: - Loading State

  @ViewBuilder
  private var loadingView: some View {
    ZStack {
      RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
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
    .frame(maxWidth: .infinity)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
  }

  // MARK: - Error State

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
        .fill(Color.red.opacity(0.1))

      VStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 32))
          .foregroundStyle(.red)

        Text("Couldn’t load GIF")
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
    .frame(maxWidth: .infinity)
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
    .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
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
        loadError = "This GIF can’t be played right now."
      }
      logger.error("Tenor GIF setup failed: could not create LoopingPlayerWrapper for url=\(url, privacy: .public)")
      return
    }

    await MainActor.run {
      teardownDiagnostics()

      loopingPlayer = wrapper
      isLoading = false

      // Tenor MP4s are videos that may have audio tracks. Without ambient +
      // mixWithOthers, AVPlayer activation interrupts background audio (Music).
      #if os(iOS)
      AudioSessionManager.shared.configureForSilentPlayback()
      #endif
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

/// Loading and playback share one size based on the available bubble width.
private struct ChatMediaAspectLayout: Layout {
  let gif: GIFEmbedData

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    ChatMediaGeometry.size(proposedWidth: proposal.width, pixelWidth: gif.width, pixelHeight: gif.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

// MARK: - Record Embed

private struct RecordEmbedContainer: View {
  let uriString: String
  let accountDID: String
  let title: String
  let subtitle: String?
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var record: AppBskyEmbedRecord.ViewRecordUnion?
  @State private var isLoading = false
  @State private var loadFailed = false
  @State private var isUnavailable = false

  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedEmbed.Record")

  private var isActiveAccount: Bool {
    let lifecycle = AppStateManager.shared.lifecycle
    return lifecycle.appState === appState && lifecycle.userDID == accountDID
      && !appState.isTransitioningAccounts
  }

  var body: some View {
    Group {
      // Render warm data on the first sizing pass, before the task starts.
      if !isActiveAccount {
        EmptyView()
      } else if let record = record ?? ChatRecordEmbedStore.shared.cachedRecord(uri: uriString, appState: appState) {
        RecordEmbedView(record: record, labels: nil, path: $navigationPath)
          .environment(\.postID, uriString)
          .foregroundStyle(.primary)
      } else if isUnavailable {
        unavailableView
      } else if loadFailed {
        errorView
      } else {
        placeholderView
      }
    }
    .task {
      if record == nil {
        await loadRecord()
      }
    }
  }

  @ViewBuilder
  private var placeholderView: some View {
    Button {
      Task { await loadRecord() }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "quote.bubble")
            .foregroundStyle(.secondary)
            .opacity(isLoading ? 0 : 1)
            .overlay { if isLoading { ProgressView().controlSize(.mini) } }
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
          Text("Shared post")
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
    .disabled(isLoading)
  }

  private var unavailableView: some View {
    Label("Post unavailable", systemImage: "eye.slash")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
  }

  @ViewBuilder
  private var errorView: some View {
    Button {
      Task { await loadRecord() }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Label("Couldn’t load post", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)

        Text("Check your connection, then tap to try again.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  @MainActor
  private func loadRecord() async {
    guard !isLoading, !Task.isCancelled, isActiveAccount else { return }
    isLoading = true
    loadFailed = false
    defer { isLoading = false }
    do {
      let loaded = try await ChatRecordEmbedStore.shared.load(uri: uriString, appState: appState)
      try Task.checkCancellation()
      guard isActiveAccount else { return }
      record = loaded
    } catch is CancellationError {
      // Reuse, interrupted presentation and account changes are not load errors.
    } catch is ChatRecordEmbedUnavailableError {
      guard !Task.isCancelled, isActiveAccount else { return }
      isUnavailable = true
    } catch {
      guard !Task.isCancelled, isActiveAccount else { return }
      loadFailed = true
      logger.error("Failed to load record embed: \(error.localizedDescription)")
    }
  }

}

// MARK: - Embed Card Style

extension View {
  /// 12pt continuous, matching `feedEmbedCardStyle()` on the loaded quote card,
  /// so a shared post keeps its shape when it finishes loading.
  fileprivate func embedCardStyle(colorScheme: ColorScheme) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return self
      .background(
        shape
          .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.8))
      )
      .overlay(
        shape
          .stroke(Color.gray.opacity(0.2), lineWidth: 1)
      )
      .clipShape(shape)
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

    UnifiedEmbedView(
      embed: .groupInvite(
        .preview(name: "Bird Watchers", memberCount: 12, memberLimit: 50, code: "abc123")
      ),
      navigationPath: .constant(NavigationPath())
    )

    UnifiedEmbedView(
      embed: .groupInvite(.unavailable(code: "abc123")),
      navigationPath: .constant(NavigationPath())
    )
  }
  .padding()
}
