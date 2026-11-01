import AVFoundation
import CatbirdMLSCore
import NukeUI
import Observation
import OSLog
import Petrel
import SwiftUI

#if DEBUG
private struct ChatPresentationFixtureRecordsKey: EnvironmentKey {
  static let defaultValue: [String: AppBskyEmbedRecord.ViewRecordUnion] = [:]
}

extension EnvironmentValues {
  /// Explicit local presentation fixtures supply resolved records without account services.
  var chatPresentationFixtureRecords: [String: AppBskyEmbedRecord.ViewRecordUnion] {
    get { self[ChatPresentationFixtureRecordsKey.self] }
    set { self[ChatPresentationFixtureRecordsKey.self] = newValue }
  }
}

@MainActor @Observable
final class ChatPresentationFixtureRecordStore {
  var records: [String: AppBskyEmbedRecord.ViewRecordUnion] = [:]
}

struct ChatPresentationFixtureRecordsModifier: ViewModifier {
  let store: ChatPresentationFixtureRecordStore

  func body(content: Content) -> some View {
    content.environment(\.chatPresentationFixtureRecords, store.records)
  }
}
#endif

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
    case .blueskyRecord, .post:
      // Built from the URI alone: an MLS post's sender-supplied handle and text never reach the card.
      if let card = ChatSharedPostCard(embed: embed) {
        RecordEmbedContainer(card: card, accountDID: appState.userDID, navigationPath: $navigationPath)
          .id("\(ObjectIdentifier(appState)):\(String(describing: appState.atProtoClient.map(ObjectIdentifier.init))):\(card.uri)")
      }

    case .link(let link):
      linkEmbed(link)

    case .gif(let gif):
      gifEmbed(gif)

    case .tile(let tile):
      TileCardView(tile: tile)

    case .image(let imageData):
      imageEmbed(imageData)

    case .audio(let audioData):
      audioEmbed(audioData)

    case .groupInvitation(let reference):
      MLSGroupInvitationCard(reference: reference)

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

  // MARK: - Image Embed

  @ViewBuilder
  private func imageEmbed(_ imageData: ImageEmbedData) -> some View {
    #if os(iOS)
    let embed = MLSImageEmbed(
      blobId: imageData.blobId,
      key: imageData.key,
      iv: imageData.iv,
      sha256: imageData.sha256,
      contentType: imageData.contentType,
      size: imageData.size,
      width: imageData.width,
      height: imageData.height,
      altText: imageData.altText,
      blurhash: imageData.blurhash
    )
    MLSImageView(imageEmbed: embed)
    #else
    Text("Image embed")
      .foregroundStyle(.secondary)
    #endif
  }

  // MARK: - Audio Embed

  @ViewBuilder
  private func audioEmbed(_ audioData: AudioEmbedData) -> some View {
    #if os(iOS)
    VoiceMessagePlayerView(
      audioData: audioData,
      isOwnMessage: isOwnMessage
    )
    #else
    HStack(spacing: 8) {
      Image(systemName: "waveform")
        .foregroundStyle(.secondary)
      Text("Voice message (\(audioData.durationMs / 1000)s)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(8)
    #endif
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

// MARK: - Record Embed (Bluesky + MLS)

/// A shared post. It renders only a record the store keeps under the labeler scope now in effect, so the
/// viewer's labelers have been consulted and the policy can act on every label it carries. Until then
/// the card shows its placeholder: no author, text or media (`ChatSharedPostCard.placeholder`).
private struct RecordEmbedContainer: View {
  let card: ChatSharedPostCard
  let accountDID: String
  @Binding var navigationPath: NavigationPath

  private var uriString: String { card.uri }

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  #if DEBUG
  @Environment(\.chatPresentationFixtureRecords) private var fixtureRecords
  #endif

  /// The record this card loaded and the scope it was confirmed under. It keeps the card on screen if
  /// the store drops the entry at capacity, and is never shown under another scope.
  @State private var loaded: LoadedRecord?
  @State private var loadingScope: ChatRecordEmbedStore.Scope?
  @State private var failedScope: ChatRecordEmbedStore.Scope?
  @State private var isResolvingLabelScope = false

  private let logger = Logger(subsystem: "blue.catbird", category: "UnifiedEmbed.Record")

  private struct LoadedRecord {
    let scope: ChatRecordEmbedStore.Scope
    let record: AppBskyEmbedRecord.ViewRecordUnion
  }

  /// Loads run when the scope changes or the card has nothing to show under it.
  private struct LoadTrigger: Equatable {
    let scope: ChatRecordEmbedStore.Scope?
    let needsRecord: Bool
  }

  private var store: ChatRecordEmbedStore { ChatRecordEmbedStore.shared }

  private var isActiveAccount: Bool {
    let lifecycle = AppStateManager.shared.lifecycle
    return lifecycle.appState === appState && lifecycle.userDID == accountDID
      && !appState.isTransitioningAccounts
  }

  private var suppliedFixtureRecord: AppBskyEmbedRecord.ViewRecordUnion? {
    #if DEBUG
    return fixtureRecords[uriString]
    #else
    return nil
    #endif
  }

  /// The scope the account's policy and its applied accept-labelers header agree on; nil until they do.
  private var labelScope: ChatRecordEmbedStore.Scope? {
    guard isActiveAccount else { return nil }
    return store.scope(for: appState)
  }

  private func confirmedRecord(under scope: ChatRecordEmbedStore.Scope) -> AppBskyEmbedRecord.ViewRecordUnion? {
    if let record = store.cachedRecord(uri: uriString, scope: scope) { return record }
    if let loaded, loaded.scope == scope { return loaded.record }
    return nil
  }

  private func needsRecord(under scope: ChatRecordEmbedStore.Scope?) -> Bool {
    guard suppliedFixtureRecord == nil, let scope else { return false }
    return confirmedRecord(under: scope) == nil && !store.isUnavailable(uri: uriString, scope: scope)
      && failedScope != scope
  }

  private var labelScopeFailed: Bool {
    guard case .error = appState.preferencesManager.state else { return false }
    return !isResolvingLabelScope
  }

  var body: some View {
    let scope = labelScope
    content(scope: scope)
      .task(id: LoadTrigger(scope: scope, needsRecord: needsRecord(under: scope))) {
        guard let scope, needsRecord(under: scope) else { return }
        await loadRecord(scope: scope)
      }
  }

  @ViewBuilder
  private func content(scope: ChatRecordEmbedStore.Scope?) -> some View {
    if let suppliedFixtureRecord {
      recordView(suppliedFixtureRecord)
    } else if !isActiveAccount {
      EmptyView()
    } else if let scope {
      if store.isUnavailable(uri: uriString, scope: scope) {
        unavailableView
      } else if let record = confirmedRecord(under: scope) {
        if ChatRecordEmbedStore.awaitsLabelDefinitions(
          record, policy: appState.moderationPolicy,
          definitionsLoading: appState.isLoadingModerationDefinitions) {
          placeholderView(showsProgress: true, action: nil)
        } else {
          recordView(record)
            // Gate with exactly the policy the scope was checked against.
            .trackingModerationPolicy(of: appState)
        }
      } else if failedScope == scope {
        errorView(message: "Couldn’t load post") { await loadRecord(scope: scope) }
      } else if loadingScope == scope {
        placeholderView(showsProgress: true, action: nil)
      } else {
        placeholderView(showsProgress: false) { await loadRecord(scope: scope) }
      }
    } else if labelScopeFailed {
      errorView(message: "Couldn’t check this post’s labels") { await resolveLabelScope() }
    } else if isResolvingLabelScope {
      placeholderView(showsProgress: true, action: nil)
    } else {
      // Waiting on the header or the policy, which normally settle on their own; a tap re-applies them.
      placeholderView(showsProgress: true) { await resolveLabelScope() }
    }
  }

  @ViewBuilder
  private func recordView(_ record: AppBskyEmbedRecord.ViewRecordUnion) -> some View {
    switch record {
    case .appBskyEmbedRecordViewNotFound, .appBskyEmbedRecordViewBlocked, .appBskyEmbedRecordViewDetached:
      unavailableView
    default:
      RecordEmbedView(record: record, path: $navigationPath)
        .environment(\.postID, uriString)
        .foregroundStyle(.primary)
    }
  }

  /// Neutral for every post and every pre-confirmation state, the covered one included.
  @ViewBuilder
  private func placeholderView(showsProgress: Bool, action: (@MainActor () async -> Void)?) -> some View {
    let placeholder = card.placeholder
    Button {
      guard let action else { return }
      Task { await action() }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "quote.bubble")
            .foregroundStyle(.secondary)
            .opacity(showsProgress ? 0 : 1)
            .overlay { if showsProgress { ProgressView().controlSize(.mini) } }
          Text(placeholder.title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
        }

        Text(placeholder.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .embedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .accessibilityLabel(placeholder.accessibilityLabel)
    .accessibilityValue(showsProgress ? Text("Loading") : Text(verbatim: ""))
    .accessibilityHint(action == nil ? Text(verbatim: "") : Text("Loads the post"))
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
  private func errorView(message: LocalizedStringKey, retry: @escaping @MainActor () async -> Void) -> some View {
    Button {
      Task { await retry() }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Label(message, systemImage: "exclamationmark.triangle")
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
  private func loadRecord(scope: ChatRecordEmbedStore.Scope) async {
    guard !Task.isCancelled, isActiveAccount else { return }
    loadingScope = scope
    failedScope = nil
    defer { if loadingScope == scope { loadingScope = nil } }
    do {
      let record = try await store.load(uri: uriString, appState: appState)
      try Task.checkCancellation()
      guard isActiveAccount, labelScope == scope else { return }
      loaded = LoadedRecord(scope: scope, record: record)
    } catch is CancellationError {
      // Reuse, interrupted presentation, header and account changes are not load errors.
    } catch is ChatRecordEmbedUnavailableError {
      // The store keeps the post as unavailable under this scope.
    } catch {
      guard !Task.isCancelled, isActiveAccount else { return }
      failedScope = scope
      logger.error("Failed to load record embed: \(error.localizedDescription)")
    }
  }

  /// The card waits on the accept-labelers header and the policy; this brings them back into agreement.
  @MainActor
  private func resolveLabelScope() async {
    guard !isResolvingLabelScope, isActiveAccount else { return }
    isResolvingLabelScope = true
    defer { isResolvingLabelScope = false }
    await store.resolveLabelScope(appState: appState)
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
