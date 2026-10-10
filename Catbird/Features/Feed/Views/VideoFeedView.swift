//
//  VideoFeedView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import AVFoundation
import Petrel
import Observation
import SwiftUI

/// Dedicated edge-to-edge vertical video feed presenting full-screen playable video posts from the canonical 'thevids' generator.
public struct VideoFeedView: View {
  /// Canonical public Bluesky video feed generator URI
  public static let thevidsURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids"

  public let feedURI: String
  public let initialPost: AppBskyFeedDefs.PostView?
  @Binding public var path: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  @State private var playerPool = VideoFeedPlayerPool()
  @State private var playbackIntent = VideoFeedPlaybackIntent()
  @State private var items: [VideoFeedItem] = []
  @State private var activeItemID: String?
  @State private var isVisible = false
  @State private var cursor: String?
  @State private var pagination = VideoFeedPaginationCoordinator()
  @State private var isInitialLoading: Bool = true
  @State private var didLoadInitialFeed = false
  @State private var initialLoadAttempt = 0
  @State private var initialLoadRequestID: UUID?
  @State private var hasMore: Bool = true
  @State private var errorMessage: String?
  /// Explicit Show taps, each for the cause set shown at the time. A player
  /// that appears because nothing covers the item is not a reveal, so a policy
  /// that starts covering a playing video covers it (`ModerationRevealState`).
  @State private var revealedItems: [VideoFeedItem.RevealIdentity: [ModerationCauseKey]] = [:]
  private var feedLoader: (@MainActor (String?) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?))?
  private var contentVisibilityObserver: ((VideoFeedItem) -> Void)?
  @Environment(\.moderationPolicy) private var moderationPolicy

  public init(
    feedURI: String = VideoFeedView.thevidsURI,
    initialPost: AppBskyFeedDefs.PostView? = nil,
    path: Binding<NavigationPath>? = nil
  ) {
    self.feedURI = feedURI
    self.initialPost = initialPost
    self._path = path ?? .constant(NavigationPath())
  }

  /// Exercise the production fetch/publication/remount path with local players.
  init(
    initialPost: AppBskyFeedDefs.PostView,
    playerPool: VideoFeedPlayerPool,
    playbackIntent: VideoFeedPlaybackIntent? = nil,
    feedLoader: @escaping @MainActor (String?) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?),
    contentVisibilityObserver: @escaping (VideoFeedItem) -> Void
  ) {
    self.init(initialPost: initialPost)
    self._playerPool = State(initialValue: playerPool)
    self._playbackIntent = State(initialValue: playbackIntent ?? VideoFeedPlaybackIntent())
    self.feedLoader = feedLoader
    self.contentVisibilityObserver = contentVisibilityObserver
  }
  public var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if items.isEmpty {
        VideoFeedEmptyState(isLoading: isInitialLoading, errorMessage: errorMessage) {
          initialLoadAttempt += 1
        }
      } else {
        VideoFeedPager(items: items, selection: $activeItemID) { item, size in
          if let index = items.firstIndex(where: { $0.id == item.id }) {
            VideoFeedItemView(
              item: item,
              index: index,
              pageSize: size,
              isActive: item.id == activeItemID,
              isRevealed: isItemEligibleForPlayback(item),
              attachesPlayer: abs(index - activeIndex) <= 1,
              playerPool: playerPool,
              onContentVisible: { playerDidAppear(for: item) },
              onRevealRequested: { revealItem(item) },
              onConceal: { concealItem(item) },
              onPlaybackToggle: { togglePlayback(for: item) },
              onPlaybackRetry: { retryPlayback(for: item) },
              moderation: item.moderation(policy: moderationPolicy),
              onProfileTap: { did in
                path.append(NavigationDestination.profile(did))
              },
              onPostTap: { uri in
                path.append(NavigationDestination.post(uri))
              }
            )
          }
        }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      navigationControls
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !items.isEmpty, let error = errorMessage ?? pagination.errorMessage {
        HStack(spacing: 12) {
          Text(error)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button {
            if errorMessage != nil {
              initialLoadAttempt += 1
            } else {
              requestNextPageIfNeeded(retrying: true)
            }
          } label: {
            Text("Retry")
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityIdentifier("videoLoadMoreRetry")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .background(.black)
      }
    }
    .modifier(VideoFeedNavigationModifier())
    .task(id: initialLoadAttempt) {
      if !didLoadInitialFeed {
        let requestID = UUID()
        initialLoadRequestID = requestID
        await loadInitialFeed(requestID: requestID)
      } else {
        updatePlaybackForActiveIndex(activeIndex)
      }
    }
    .onAppear {
      isVisible = true
      if !items.isEmpty {
        updatePlaybackForActiveIndex(activeIndex)
        requestNextPageIfNeeded()
      }
    }
    .onChange(of: activeItemID) { _, _ in
      updatePlaybackForActiveIndex(activeIndex)
      requestNextPageIfNeeded()
    }
    .onChange(of: playbackIntent.isPlaybackRequested) { _, _ in
      updatePlaybackForActiveIndex(activeIndex)
    }
    .onChange(of: moderationPolicy) { _, _ in
      // A new policy re-filters the loaded items and re-evaluates playback.
      publishItems(items)
    }
    .onChange(of: scenePhase) { previous, phase in
      if phase == .active {
        if isVisible {
          updatePlaybackForActiveIndex(activeIndex)
        }
      } else if previous == .active {
        playerPool.pauseAll()
      }
    }
    .onDisappear {
      isVisible = false
      initialLoadRequestID = nil
      pagination.cancel()
      playerPool.pauseAll()
    }
  }

  private var activeIndex: Int {
    items.firstIndex(where: { $0.id == activeItemID }) ?? 0
  }

  private var navigationControls: some View {
    VideoFeedNavigationControls(
      isMuted: playerPool.isMuted,
      onBack: { dismiss() },
      onMute: { playerPool.toggleMute() }
    )
  }

  private func loadInitialFeed(requestID: UUID) async {
    isInitialLoading = true
    errorMessage = nil
    defer {
      if initialLoadRequestID == requestID { isInitialLoading = false }
    }
    // The tapped post is already loaded. Show it before fetching a feed whose
    // first page may have changed or no longer contain that video.
    if items.isEmpty {
      items = VideoFeedItem.initialItems(startingAt: initialPost, feedPosts: [])
      activeItemID = items.first?.id
      updatePlaybackForActiveIndex(activeIndex)
    }

    do {
      let (feedPosts, nextCursor) = try await fetchFeedPage(cursor: nil)

      let parsedItems = VideoFeedItem.initialItems(startingAt: initialPost, feedPosts: feedPosts)
      try Task.checkCancellation()
      guard initialLoadRequestID == requestID else { return }
      publishItems(parsedItems)
      self.cursor = nextCursor
      self.hasMore = nextCursor != nil && !feedPosts.isEmpty
      self.isInitialLoading = false
      self.didLoadInitialFeed = true

      requestNextPageIfNeeded()
    } catch is CancellationError {
      // SwiftUI owns the initial request and cancels it when leaving or retrying.
    } catch {
      if initialLoadRequestID == requestID, !Task.isCancelled {
        self.errorMessage = (error as? FeedError)?.errorDescription
          ?? UserFacingError.message(for: error, action: "load videos")
      }
    }
  }

  private func requestNextPageIfNeeded(retrying: Bool = false) {
    guard isVisible, !isInitialLoading, hasMore,
          retrying || activeIndex >= items.count - 3,
          let currentCursor = cursor else { return }
    pagination.request(retrying: retrying, operation: {
      try await self.loadNextPage(cursor: currentCursor)
    }, onSuccess: {
      // A filtered or overlapping page can contain no new videos. Continue only
      // after a successful request with a new cursor, never after a failure.
      self.requestNextPageIfNeeded()
    })
  }

  private func loadNextPage(cursor currentCursor: String) async throws {
    let (feedPosts, nextCursor) = try await fetchFeedPage(cursor: currentCursor)
    // Even a transport that finishes after cancellation cannot publish an old
    // page over the new visible screen's request.
    try Task.checkCancellation()
    publishItems(VideoFeedItem.merging(items, with: feedPosts))
    if activeItemID == nil { activeItemID = items.first?.id }
    self.cursor = nextCursor
    self.hasMore = nextCursor != nil && nextCursor != currentCursor && !feedPosts.isEmpty
  }

  private func fetchFeedPage(cursor: String?) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
    if let feedLoader { return try await feedLoader(cursor) }
    guard let client = appState.atProtoClient else { throw PostViewModel.PostViewModelError.missingClient }
    let uri = try ATProtocolURI(uriString: feedURI)
    return try await FeedManager(client: client).fetchFeed(fetchType: .feed(uri), cursor: cursor)
  }

  private func publishItems(_ refreshed: [VideoFeedItem]) {
    // Items the policy filters from lists are skipped (`contentList` filter).
    let visible = refreshed.filter { !$0.moderation(policy: moderationPolicy).isFilteredFromList }
    let visibleIdentities = Set(visible.map(\.revealIdentity))
    let cleaned = revealedItems.filter { visibleIdentities.contains($0.key) }
    if cleaned != revealedItems {
      revealedItems = cleaned
    }
    items = visible
    if !items.contains(where: { $0.id == activeItemID }) {
      activeItemID = items.first?.id
    }
    // Reevaluate/evict before rebuilding the cover. Temporary holds and
    // stream replacement do not erase the selected video's requested playback.
    updatePlaybackForActiveIndex(activeIndex)
  }

  /// A covered item (`contentView` or `contentMedia` blur) must not autoplay,
  /// prewarm or play audio until the viewer shows it, and a reveal counts only
  /// for the causes it was given: a policy that changes them covers the item.
  /// A cover the viewer may no longer override (adult content turned off after
  /// the reveal) covers the item again even with the same causes.
  private func isItemEligibleForPlayback(_ item: VideoFeedItem) -> Bool {
    let moderation = item.moderation(policy: moderationPolicy)
    guard moderation.concealsPlayback else { return true }
    return !moderation.playback.noOverride
      && revealedItems[item.revealIdentity] == moderation.playback.blurs.map(\.key)
  }

  /// The viewer tapped Show on the cover.
  private func revealItem(_ item: VideoFeedItem) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    let blurs = item.moderation(policy: moderationPolicy).playback.blurs.map(\.key)
    guard revealedItems[item.revealIdentity] != blurs else { return }
    revealedItems[item.revealIdentity] = blurs
    if item.id == activeItemID {
      playbackIntent.select(item.id)
      playbackIntent.setPlaybackRequested(true, for: item.id)
      updatePlaybackForActiveIndex(index)
    } else {
      updatePrewarming(for: activeIndex)
    }
  }

  /// A player attached because nothing covers the item or the viewer showed
  /// it. A pending request resumes, while an explicit pause stays paused; the
  /// snapshot check rejects old preference callbacks.
  private func playerDidAppear(for item: VideoFeedItem) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    if item.id == activeItemID {
      playbackIntent.select(item.id)
      updatePlaybackForActiveIndex(index)
    }
    contentVisibilityObserver?(item)
  }

  /// The viewer tapped Hide.
  private func concealItem(_ item: VideoFeedItem) {
    guard revealedItems[item.revealIdentity] != nil else { return }
    revealedItems[item.revealIdentity] = nil
    guard let index = items.firstIndex(where: { $0.id == item.id }),
          index == activeIndex, !isItemEligibleForPlayback(items[index]) else { return }
    playerPool.pauseAll()
  }

  private func updatePlaybackForActiveIndex(_ index: Int) {
    playbackIntent.select(activeItemID)
    guard isVisible, scenePhase == .active, items.indices.contains(index),
          items[index].id == activeItemID else {
      playerPool.pauseAll()
      return
    }
    updatePrewarming(for: index)
    if playbackIntent.requestsPlayback(for: items[index].id), isItemEligibleForPlayback(items[index]) {
      playerPool.play(feedIndex: index)
    } else {
      playerPool.pauseAll()
    }
  }

  private func togglePlayback(for item: VideoFeedItem) {
    guard isVisible, scenePhase == .active, item.id == activeItemID,
          items.contains(where: { $0.id == item.id }),
          isItemEligibleForPlayback(item) else { return }
    if !playerPool.wantsPlayback && playerPool.playbackState == .failed {
      retryPlayback(for: item)
      return
    }
    playbackIntent.select(item.id)
    playbackIntent.setPlaybackRequested(!playerPool.wantsPlayback, for: item.id)
    updatePlaybackForActiveIndex(activeIndex)
  }

  private func retryPlayback(for item: VideoFeedItem) {
    guard isVisible, scenePhase == .active, item.id == activeItemID,
          items.contains(where: { $0.id == item.id }),
          isItemEligibleForPlayback(item) else { return }
    playbackIntent.select(item.id)
    playbackIntent.setPlaybackRequested(true, for: item.id)
    playerPool.retry(feedIndex: activeIndex)
  }

  private func updatePrewarming(for index: Int) {
    guard isVisible, scenePhase == .active, !items.isEmpty, items.indices.contains(index) else { return }
    let window = max(0, index - 1)...min(items.count - 1, index + 1)
    let prewarmTargets = window.compactMap { i -> (index: Int, url: URL)? in
      let item = items[i]
      guard isItemEligibleForPlayback(item) else { return nil }
      return (index: i, url: item.playlistURL)
    }
    playerPool.prewarm(activeIndex: index, items: prewarmTargets)
  }
}

private struct VideoFeedEmptyState: View {
  let isLoading: Bool
  let errorMessage: String?
  let onRetry: () -> Void

  var body: some View {
    if isLoading {
      VStack(spacing: 16) {
        ProgressView()
          .tint(.white)
        Text("Loading Video Feed…")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
      }
    } else if let error = errorMessage {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundStyle(.white.opacity(0.8))

        Text(error)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)

        Button(action: onRetry) {
          Text("Retry")
            .fontWeight(.semibold)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(.white.opacity(0.2))
            .clipShape(Capsule())
        }
        .tint(.white)
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "video.slash")
          .font(.largeTitle)
          .foregroundStyle(.white.opacity(0.6))
        Text("No videos found")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
      }
    }
  }
}

// MARK: - Paging geometry

/// The page and the scroll snap use the same safe container. Only the black
/// backdrop extends behind system bars; video controls never borrow their space.
struct VideoFeedPager<Item: Identifiable, Page: View>: View {
  let items: [Item]
  @Binding var selection: Item.ID?
  @ViewBuilder let page: (Item, CGSize) -> Page

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          ForEach(items) { item in
            page(item, geometry.size)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()
              .id(item.id)
          }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(.paging)
      .scrollPosition(id: $selection, anchor: .top)
      .scrollIndicators(.hidden)
      .modifier(VideoFeedScrollEdges())
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
  }
}

private struct VideoFeedScrollEdges: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .all)
    } else {
      content
    }
  }
}

struct VideoFeedNavigationModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .navigationBarBackButtonHidden(true)
      .toolbar(.hidden, for: .navigationBar)
    #else
    content.toolbar(.hidden, for: .windowToolbar)
    #endif
  }
}

// MARK: - Single Video Item View

private struct VideoFeedItemView: View {
  let item: VideoFeedItem
  let index: Int
  let pageSize: CGSize
  let isActive: Bool
  /// The player is shown: nothing covers the item, or the viewer showed it.
  let isRevealed: Bool
  let attachesPlayer: Bool
  let playerPool: VideoFeedPlayerPool
  let onContentVisible: () -> Void
  let onRevealRequested: () -> Void
  let onConceal: () -> Void
  let onPlaybackToggle: () -> Void
  let onPlaybackRetry: () -> Void
  let moderation: VideoFeedItemModeration
  let onProfileTap: (String) -> Void
  let onPostTap: (ATProtocolURI) -> Void
  @Environment(AppState.self) private var appState
  @State private var actions: VideoFeedPostActions?

  private var postText: String {
    if case .knownType(let record) = item.post.record,
       let postRecord = record as? AppBskyFeedPost {
      return postRecord.text
    }
    return ""
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black
      Group {
        if !isRevealed {
          // No player is attached while covered, so nothing prewarms or plays.
          VideoFeedModerationCover(ui: moderation.playback, onShow: onRevealRequested)
        } else {
          ZStack {
            if attachesPlayer {
              PlayerLayerView(
                player: playerPool.player(for: index),
                gravity: .resizeAspect,
                shouldLoop: false,
                pausesOnDismantle: false
              )
              .onAppear(perform: onContentVisible)
            }

            Button(action: onPlaybackToggle) {
              Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActive)
            .accessibilityLabel(playerPool.wantsPlayback ? "Pause video" : "Play video")

          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay(alignment: .topTrailing) {
            if moderation.concealsPlayback {
              Button(action: onConceal) {
                Label("Hide", systemImage: "eye.slash")
                  .font(.caption)
                  .padding(.horizontal, 10)
                  .frame(minHeight: 28)
                  .background(Color.black.opacity(0.6), in: Capsule())
                  .foregroundStyle(.white)
              }
              .buttonStyle(.plain)
              .padding(.top, 8)
              .padding(.trailing, 16)
              .accessibilityHint("Covers the video again")
            }
          }
        }
      }
      .id(item.revealIdentity)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      LinearGradient(
        colors: [.clear, .black.opacity(0.25), .black.opacity(0.85)],
        startPoint: .center,
        endPoint: .bottom
      )
      .allowsHitTesting(false)

      VideoFeedPageOverlays(
        status: {
          if isActive && isRevealed {
            VideoFeedPlaybackStatus(state: playerPool.playbackState, onRetry: onPlaybackRetry)
          }
        },
        footer: { footer }
      )
    }
    .clipped()
    .task(id: appState.userDID) {
      let model = VideoFeedPostActions(post: item.post, appState: appState)
      actions = model
      defer { model.invalidate() }
      await model.observe()
    }
    .onChange(of: isActive) { _, active in
      if !active { actions?.cancel() }
    }
    .onDisappear {
      actions?.cancel()
      actions = nil
    }
    .alert("Action unsuccessful", isPresented: Binding(
      get: { actions?.errorMessage != nil },
      set: { if !$0 { actions?.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { actions?.errorMessage = nil }
    } message: {
      Text(actions?.errorMessage ?? "")
    }
  }

  /// The caption is part of the post body: a `contentView` cover hides it with
  /// the player until the viewer shows the item.
  private var showsCaption: Bool {
    !postText.isEmpty && (isRevealed || !moderation.concealsCaption)
  }

  private var footer: some View {
    VideoFeedOverlayControls(
      pageSize: pageSize,
      hasCaption: showsCaption,
      author: { author(compact: $0) },
      caption: { postCaption(lines: $0) },
      actions: { actionControls(horizontal: $0) },
      progress: {
        VideoFeedProgressSlot(
          progress: playerPool.progress,
          pool: playerPool,
          index: index,
          isActive: isActive
        )
      }
    )
  }
  private func author(compact: Bool) -> some View {
    Button { onProfileTap(item.post.author.did.didString()) } label: {
      HStack(spacing: 8) {
        // Drawn through the engine's `avatar` context: a moderated author keeps
        // the neutral placeholder and no image is requested.
        AsyncProfileImage(
          url: item.post.author.finalAvatarURL(),
          size: 38,
          did: item.post.author.did.didString(),
          labels: item.post.author.labels
        )
        .frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 1) {
          Text(item.post.author.displayName ?? item.post.author.handle.description)
            .font(.subheadline.bold())
            .lineLimit(1)
          if !compact {
            Text("@\(item.post.author.handle)")
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.8))
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func postCaption(lines: Int) -> some View {
    Button { onPostTap(item.post.uri) } label: {
      Text(postText)
        .font(.subheadline)
        .lineLimit(lines)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens the thread")
  }

  private func actionControls(horizontal: Bool) -> some View {
    VideoFeedReactionControls(
      horizontal: horizontal,
      isLiked: actions?.state.isLiked ?? (item.post.viewer?.like != nil),
      isReposted: actions?.state.isReposted ?? (item.post.viewer?.repost != nil),
      replyCount: actions?.state.replyCount ?? item.post.replyCount ?? 0,
      likeCount: actions?.state.likeCount ?? item.post.likeCount ?? 0,
      repostCount: actions?.state.repostCount ?? item.post.repostCount ?? 0,
      canAct: isActive && actions?.accountDID == appState.userDID && actions?.canAct == true,
      onComments: { onPostTap(item.post.uri) },
      onLike: { actions?.toggle(.like) },
      onRepost: { actions?.toggle(.repost) }
    )
  }
}

/// The full-page cover over a moderated video (`contentView` or `contentMedia`
/// blur). Show is offered unless the cause forbids override.
private struct VideoFeedModerationCover: View {
  let ui: ModerationUI
  let onShow: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "eye.slash.fill")
        .font(.largeTitle)
        .accessibilityHidden(true)
      Text(ModerationPresentation.title(for: ui))
        .font(.headline)
      Text(ModerationGateText.explanation(for: ui))
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.85))
      if !ui.noOverride {
        Button(action: onShow) {
          Text("Show")
            .fontWeight(.semibold)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(.white.opacity(0.2))
            .clipShape(Capsule())
        }
        .tint(.white)
        .accessibilityHint("Shows the video")
      }
    }
    .foregroundStyle(.white)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("moderation.videoCover")
  }
}

// MARK: - Playback status placement

/// The video remains behind the footer, but playback status controls get the
/// measured space above it. No fixed footer-height estimate is involved.
struct VideoFeedPageOverlays<Status: View, Footer: View>: View {
  @ViewBuilder let status: () -> Status
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    ViewThatFits(in: .vertical) {
      VideoFeedOverlayLayout {
        // LayoutSubviews omits EmptyView and false conditional branches. Keep
        // the status slot structurally present after playback starts or when
        // moderation hides it, without adding a hit-test surface.
        ZStack { status() }
        footer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // If even the minimum status control and footer cannot fit, keep all
      // controls reachable by scrolling instead of clipping the Retry target.
      ScrollView(.vertical) {
        VStack(spacing: 8) {
          status()
          footer()
        }
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .modifier(VideoFeedScrollEdges())
      .accessibilityIdentifier("videoControlsScroll")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct VideoFeedOverlayLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.replacingUnspecifiedDimensions().width
    let footerSize = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
    let minimumStatus = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: 0))
    let minimumHeight = footerSize.height + minimumStatus.height + 8
    return CGSize(width: width, height: max(proposal.height ?? minimumHeight, minimumHeight))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let footerSize = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
    let statusHeight = max(0, bounds.height - footerSize.height - 8)
    subviews[0].place(
      at: CGPoint(x: bounds.midX, y: bounds.minY + statusHeight / 2),
      anchor: .center,
      proposal: ProposedViewSize(width: bounds.width, height: statusHeight)
    )
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.maxY),
      anchor: .bottomLeading,
      proposal: ProposedViewSize(width: bounds.width, height: footerSize.height)
    )
  }
}

struct VideoFeedPlaybackStatus: View {
  let state: VideoFeedPlayerPool.PlaybackState
  let onRetry: () -> Void

  @ViewBuilder var body: some View {
    switch state {
    case .loading:
      ViewThatFits(in: .vertical) {
        ProgressView("Loading video")
          .padding(16)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        ProgressView().accessibilityLabel("Loading video")
      }
      .tint(.white)
      .foregroundStyle(.white)
      .allowsHitTesting(false)
    case .failed:
      ViewThatFits(in: .vertical) {
        VStack(spacing: 12) {
          failureText
          retryButton
        }
        .padding(16)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))

        HStack(spacing: 12) {
          failureText.lineLimit(1)
          retryButton
        }
        .padding(8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))

        retryButton
      }
      .foregroundStyle(.white)
    case .paused:
      Image(systemName: "play.fill")
        .font(.system(size: 48))
        .foregroundStyle(.white.opacity(0.9))
        .shadow(radius: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    case .idle, .playing:
      EmptyView()
    }
  }

  private var failureText: some View {
    Text("Unable to play this video")
      .font(.subheadline)
      .multilineTextAlignment(.center)
  }

  private var retryButton: some View {
    Button(action: onRetry) {
      Text("Retry")
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderedProminent)
    .accessibilityLabel("Unable to play video. Retry")
    .accessibilityIdentifier("videoPlaybackRetry")
  }
}

// MARK: - Video controls presentation

struct VideoFeedNavigationControls: View {
  let isMuted: Bool
  let onBack: () -> Void
  let onMute: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onBack) {
        Image(systemName: "chevron.left")
          .font(.system(size: 18, weight: .bold))
          .frame(width: 44, height: 44)
          .background(.white.opacity(0.12), in: Circle())
      }
      .accessibilityLabel("Back")

      Spacer(minLength: 0)
      Text("The Vids")
        .font(.headline.bold())
        .lineLimit(1)
      Spacer(minLength: 0)

      Button(action: onMute) {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(.white.opacity(0.12), in: Circle())
      }
      .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.black)
  }
}

private struct VideoFeedProgressSlot: View {
  let progress: VideoFeedPlaybackProgress
  let pool: VideoFeedPlayerPool
  let index: Int
  let isActive: Bool

  var body: some View {
    VideoProgressBar(
      currentTime: isActive ? progress.currentTime : 0,
      duration: isActive ? progress.duration : 0,
      bufferedTime: isActive ? progress.bufferedTime : 0,
      onSeek: { seconds in pool.seek(to: seconds, at: index) }
    )
    .disabled(!isActive || !progress.canSeek)
    .accessibilityIdentifier("videoProgress")
  }
}


struct VideoFeedOverlayControls<Author: View, Caption: View, Actions: View, Progress: View>: View {
  let pageSize: CGSize
  let hasCaption: Bool
  @ViewBuilder let author: (Bool) -> Author
  @ViewBuilder let caption: (Int) -> Caption
  @ViewBuilder let actions: (Bool) -> Actions
  @ViewBuilder let progress: () -> Progress
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var compact: Bool {
    pageSize.height < 420 || pageSize.width < 300 || dynamicTypeSize.isAccessibilitySize
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if compact {
        author(true)
        if hasCaption, pageSize.height >= 320 { caption(1) }
        actions(true)
      } else {
        HStack(alignment: .bottom, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            author(false)
            if hasCaption { caption(3) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          actions(false)
        }
      }
      progress()
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .foregroundStyle(.white)
  }
}

struct VideoFeedReactionControls: View {
  let horizontal: Bool
  let isLiked: Bool
  let isReposted: Bool
  let replyCount: Int
  let likeCount: Int
  let repostCount: Int
  let canAct: Bool
  let onComments: () -> Void
  let onLike: () -> Void
  let onRepost: () -> Void

  var body: some View {
    let layout = horizontal ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 8))
    layout {
      VideoFeedReactionButton(
        icon: "bubble.right.fill", count: replyCount, label: "Comments",
        color: .white, identifier: "videoComments", action: onComments
      )
      .accessibilityHint("Opens the thread")

      VideoFeedReactionButton(
        icon: isLiked ? "heart.fill" : "heart", count: likeCount,
        label: isLiked ? "Unlike" : "Like", color: isLiked ? .red : .white,
        identifier: "videoLike", action: onLike
      )
      .disabled(!canAct)
      .opacity(canAct ? 1 : 0.45)

      VideoFeedReactionButton(
        icon: "arrow.2.squarepath", count: repostCount,
        label: isReposted ? "Undo repost" : "Repost", color: isReposted ? .green : .white,
        identifier: "videoRepost", action: onRepost
      )
      .disabled(!canAct)
      .opacity(canAct ? 1 : 0.45)
    }
    .frame(maxWidth: horizontal ? .infinity : nil)
  }
}

private struct VideoFeedReactionButton: View {
  let icon: String
  let count: Int
  let label: String
  let color: Color
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 2) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(color)
        Text(max(0, count), format: .number.notation(.compactName))
          .font(.caption2.bold())
          .foregroundStyle(.white)
          .lineLimit(1)
      }
      .frame(minWidth: 44, minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(label). Count: \(max(0, count))")
    .accessibilityIdentifier(identifier)
  }
}

// MARK: - Shared post actions

/// Keeps Vids on the same optimistic/shadow-state path as ordinary feed rows.
@MainActor @Observable
private final class VideoFeedPostActions {
  enum Action { case like, repost }

  let state: PostInteractionState
  let accountDID: String
  private let operation = VideoFeedActionCoordinator()
  var errorMessage: String? {
    get { operation.errorMessage }
    set { operation.errorMessage = newValue }
  }
  private(set) var isReady = false
  private let post: AppBskyFeedDefs.PostView
  private let appState: AppState
  private let postViewModel: PostViewModel
  private let actions: ActionButtonViewModel

  var canAct: Bool { isReady && !operation.isBusy && appState.atProtoClient != nil }

  init(post: AppBskyFeedDefs.PostView, appState: AppState) {
    self.post = post
    self.appState = appState
    self.accountDID = appState.userDID
    self.state = PostInteractionState(post: post)
    self.postViewModel = PostViewModel(post: post, appState: appState)
    self.actions = ActionButtonViewModel(
      postId: post.uri.uriString(), postViewModel: postViewModel, appState: appState
    )
  }

  func observe() async {
    await postViewModel.initializeFromServerState(post: post)
    guard !Task.isCancelled else { return }
    for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
      guard !Task.isCancelled else { return }
      await refresh()
      isReady = true
    }
  }

  func toggle(_ action: Action) {
    guard canAct else { return }
    operation.perform {
      do {
        guard let client = self.appState.atProtoClient,
              try await client.getDid() == self.accountDID else {
          throw PostViewModel.PostViewModelError.missingClient
        }
        try Task.checkCancellation()
        switch action {
        case .like: try await self.actions.toggleLike()
        case .repost: try await self.actions.toggleRepost()
        }
      } catch {
        await self.refresh()
        throw error
      }
      await self.refresh()
    }
  }

  func cancel() { operation.cancel() }

  func invalidate() {
    isReady = false
    operation.cancel()
  }

  private func refresh() async {
    let merged = await appState.postShadowManager.mergeShadow(post: post)
    state.update(from: merged)
    await postViewModel.checkInteractionState()
    postViewModel.updateCounts(from: merged)
  }
}

/// Serializes a page's interaction requests and owns their visible failure state.
/// The injected operation stays on the ordinary post-action path in production.
@MainActor @Observable
final class VideoFeedActionCoordinator {
  private(set) var isBusy = false
  var errorMessage: String?
  private var actionTask: Task<Void, Never>?

  func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    actionTask = Task {
      defer {
        self.isBusy = false
        self.actionTask = nil
      }
      do {
        try Task.checkCancellation()
        try await operation()
      } catch {
        if !Task.isCancelled {
          self.errorMessage = "Your action could not be completed. Please try again."
        }
      }
    }
  }

  func cancel() {
    actionTask?.cancel()
    errorMessage = nil
  }
}

/// Owns next-page requests independently of the selected video, so moving among
/// the last few videos cannot cancel/restart the same cursor task accidentally.
@MainActor @Observable
final class VideoFeedPaginationCoordinator {
  private(set) var isLoading = false
  private(set) var errorMessage: String?
  private var requestID: UUID?
  private var requestTask: Task<Void, Never>?

  func request(
    retrying: Bool = false,
    operation: @escaping @MainActor () async throws -> Void,
    onSuccess: @escaping @MainActor () -> Void
  ) {
    guard !isLoading, retrying || errorMessage == nil else { return }
    let id = UUID()
    requestID = id
    isLoading = true
    errorMessage = nil
    requestTask = Task {
      var succeeded = false
      defer {
        if self.requestID == id {
          self.requestID = nil
          self.requestTask = nil
          self.isLoading = false
          if succeeded { onSuccess() }
        }
      }
      do {
        try Task.checkCancellation()
        try await operation()
        try Task.checkCancellation()
        succeeded = true
      } catch {
        if self.requestID == id, !Task.isCancelled {
          self.errorMessage = "More videos couldn’t load."
        }
      }
    }
  }

  func cancel() {
    requestID = nil
    requestTask?.cancel()
    requestTask = nil
    isLoading = false
  }
}
