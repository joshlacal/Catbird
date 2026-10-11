//
//  PostListCollectionController.swift
//  Catbird
//
//  Recycling post lists with stable identity, native swipe actions and bounded prefetch.
//

import Foundation
import Petrel
import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Keep every model behind the existing immutable box, including bookmark payloads.
enum PostListEntry: Hashable, Identifiable, Sendable {
  case post(EquatableBox<AppBskyFeedDefs.PostView>)
  case feedPost(EquatableBox<AppBskyFeedDefs.FeedViewPost>)
  case bookmark(EquatableBox<AppBskyBookmarkDefs.BookmarkView>)

  var id: String {
    switch self {
    case .post(let box): box.value.uri.uriString()
    case .feedPost(let box): box.value.id
    case .bookmark(let box): box.value.subject.uri.uriString()
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.post(let a), .post(let b)): a == b
    case (.feedPost(let a), .feedPost(let b)): a == b
    case (.bookmark(let a), .bookmark(let b)): a == b
    default: false
    }
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

enum PostListFooterState: Equatable, Sendable {
  case hidden
  case loading
  case failed
  case end
}

struct PostListPaginationFooterView: View {
  let state: PostListFooterState
  let onRetry: @MainActor () -> Void

  var body: some View {
    switch state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityLabel("Loading more posts")
    case .failed:
      VStack(spacing: 8) {
        Text("Couldn’t load more posts.")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Try Again", action: onRetry)
          .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
    case .end, .hidden:
      EmptyView()
    }
  }
}

#if os(iOS)

@MainActor
final class PostListCollectionController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
  private enum Section { case main }
  private enum Item: Hashable {
    case header
    case row(String)
    case empty
    case footer
  }

  private(set) var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private(set) var entries: [PostListEntry] = []
  private var entriesByID: [String: PostListEntry] = [:]
  private var entryIndicesByID: [String: Int] = [:]
  private var previousEntriesByID: [String: PostListEntry] = [:]
  private var previousFooterState: PostListFooterState = .hidden
  private var needsRowReconfiguration = false
  private var snapshotRevision = 0

  var headerView: AnyView?
  var rowViewBuilder: ((PostListEntry) -> AnyView)?
  var emptyView: AnyView?
  var hostingEnvironment = EnvironmentValues() {
    didSet {
      if oldValue.colorScheme != hostingEnvironment.colorScheme
        || oldValue.dynamicTypeSize != hostingEnvironment.dynamicTypeSize
        || oldValue.layoutDirection != hostingEnvironment.layoutDirection
        || oldValue.horizontalSizeClass != hostingEnvironment.horizontalSizeClass
        || oldValue.displayScale != hostingEnvironment.displayScale {
        needsRowReconfiguration = true
      }
    }
  }
  var appState: AppState? {
    didSet { if oldValue !== appState { needsRowReconfiguration = true } }
  }
  var hasMore = false
  var isLoadingMore = false
  var footerState: PostListFooterState = .hidden
  var onRefresh: (@MainActor () async -> Void)?
  var onLoadMore: (@MainActor () async -> Void)?
  var onRemoveBookmark: (@MainActor (AppBskyBookmarkDefs.BookmarkView) async -> Bool)?
  var onScrollOffsetChanged: ((CGFloat) -> Void)?
  var isScrollsToTop = true {
    didSet { collectionView?.scrollsToTop = isScrollsToTop }
  }

  private var refreshTask: Task<Void, Never>?
  private var loadMoreTask: Task<Void, Never>?
  private var prefetchTasks: [String: Task<Void, Never>] = [:]
  private let loadMorePrefetchThreshold = 5
  private var scrollPositionKey: String?
  private var savedOffsets: [String: CGFloat] = [:]
  private var scrollToTopRequestID = 0
  private var pendingScrollOffset: CGFloat?
  private var animatePendingScroll = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    setupCollectionView()
    setupDataSource()
    applySnapshot()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    cancelPrefetching()
  }

  func cancelTasks() {
    refreshTask?.cancel()
    refreshTask = nil
    loadMoreTask?.cancel()
    loadMoreTask = nil
    collectionView?.refreshControl?.endRefreshing()
    cancelPrefetching()
  }

  private func cancelPrefetching() {
    for task in prefetchTasks.values { task.cancel() }
    prefetchTasks.removeAll()
  }

  func updateScrollPosition(key: String?, requestID: Int) {
    if key != scrollPositionKey {
      if let oldKey = scrollPositionKey, let collectionView {
        savedOffsets[oldKey] = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
      }
      cancelTasks()
      scrollPositionKey = key
      needsRowReconfiguration = true
      pendingScrollOffset = key.flatMap { savedOffsets[$0] } ?? 0
      animatePendingScroll = false
    }
    if requestID != scrollToTopRequestID {
      scrollToTopRequestID = requestID
      pendingScrollOffset = 0
      animatePendingScroll = true
    }
  }

  func setEntries(
    _ newEntries: [PostListEntry],
    hasMore: Bool,
    isLoadingMore: Bool,
    footerState: PostListFooterState,
    animated: Bool = false
  ) {
    self.hasMore = hasMore
    self.isLoadingMore = isLoadingMore
    self.footerState = footerState
    entries.removeAll(keepingCapacity: true)
    entriesByID.removeAll(keepingCapacity: true)
    entryIndicesByID.removeAll(keepingCapacity: true)
    for entry in newEntries {
      let id = entry.id
      guard entriesByID[id] == nil else { continue }
      entryIndicesByID[id] = entries.count
      entriesByID[id] = entry
      entries.append(entry)
    }
    for id in Array(prefetchTasks.keys) where entriesByID[id] == nil {
      prefetchTasks.removeValue(forKey: id)?.cancel()
    }
    if isViewLoaded { applySnapshot(animated: animated) }
  }

  func scrollToTop(animated: Bool = true) {
    guard let collectionView else { return }
    collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: animated)
  }

  private func setupCollectionView() {
    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
    configuration.backgroundColor = .clear
    configuration.showsSeparators = false
    configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
      guard let self, let onRemoveBookmark = self.onRemoveBookmark,
            case .row(let id)? = self.dataSource.itemIdentifier(for: indexPath),
            case .bookmark(let box)? = self.entriesByID[id] else { return nil }
      let action = UIContextualAction(style: .destructive, title: "Remove Bookmark") { _, _, completion in
        Task { @MainActor in
          completion(await onRemoveBookmark(box.value))
        }
      }
      action.image = UIImage(systemName: "bookmark.slash")
      return UISwipeActionsConfiguration(actions: [action])
    }
    let layout = UICollectionViewCompositionalLayout.list(using: configuration)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.directionalLayoutMargins = .zero
    collectionView.contentInsetAdjustmentBehavior = .automatic
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .onDrag
    collectionView.scrollsToTop = isScrollsToTop
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    #if !targetEnvironment(macCatalyst)
    let refresh = UIRefreshControl()
    refresh.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    collectionView.refreshControl = refresh
    #endif
  }

  @objc private func handleRefresh() {
    guard let onRefresh, refreshTask == nil else {
      collectionView.refreshControl?.endRefreshing()
      return
    }
    let pendingPage = loadMoreTask
    pendingPage?.cancel()
    loadMoreTask = nil
    refreshTask = Task { @MainActor [weak self] in
      await pendingPage?.value
      guard !Task.isCancelled else { return }
      await onRefresh()
      guard !Task.isCancelled, let self else { return }
      self.refreshTask = nil
      self.collectionView.refreshControl?.endRefreshing()
    }
  }

  private func hosted(_ content: AnyView) -> AnyView {
    // UIKit hosting roots do not inherit the representable's SwiftUI environment.
    // Copy scene/custom values, then use the same live policy/font injection as the feed.
    if let appState {
      return AnyView(content
        .trackingModerationPolicy(of: appState)
        .applyAppStateEnvironment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.self, hostingEnvironment))
    }
    return AnyView(content.environment(\.self, hostingEnvironment))
  }

  private func setupDataSource() {
    let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
      [weak self] cell, _, item in
      guard let self else { return }
      cell.backgroundConfiguration = .clear()
      cell.selectedBackgroundView = nil
      cell.directionalLayoutMargins = .zero
      let content: AnyView
      switch item {
      case .header:
        content = self.headerView ?? AnyView(EmptyView())
      case .row(let id):
        guard let entry = self.entriesByID[id], let rowViewBuilder = self.rowViewBuilder else {
          cell.contentConfiguration = nil
          return
        }
        content = rowViewBuilder(entry)
      case .empty:
        content = self.emptyView ?? AnyView(EmptyView())
      case .footer:
        content = AnyView(PostListPaginationFooterView(state: self.footerState) { [weak self] in
          self?.triggerLoadMoreTask()
        })
      }
      let root = self.hosted(content)
      let accountID = self.appState?.userDID
      cell.contentConfiguration = UIHostingConfiguration {
        root.id(accountID).id(item)
      }
      .margins(.all, 0)
    }
    dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
      collectionView, indexPath, item in
      collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }
  }

  private func applySnapshot(animated: Bool = false) {
    guard let dataSource else { return }
    let previous = dataSource.snapshot()
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.main])
    if headerView != nil { snapshot.appendItems([.header]) }
    snapshot.appendItems(entries.map { .row($0.id) })
    if entries.isEmpty, emptyView != nil { snapshot.appendItems([.empty]) }
    if footerState != .hidden, footerState != .end { snapshot.appendItems([.footer]) }

    var changed: [Item] = []
    for entry in entries {
      let item = Item.row(entry.id)
      if previous.indexOfItem(item) != nil,
         needsRowReconfiguration || previousEntriesByID[entry.id].map({ $0 != entry }) == true {
        changed.append(item)
      }
    }
    for item in [Item.header, .empty] where previous.indexOfItem(item) != nil && snapshot.indexOfItem(item) != nil {
      changed.append(item)
    }
    if previousFooterState != footerState,
       previous.indexOfItem(.footer) != nil, snapshot.indexOfItem(.footer) != nil {
      changed.append(.footer)
    }
    snapshot.reconfigureItems(changed)
    previousEntriesByID = entriesByID
    previousFooterState = footerState
    needsRowReconfiguration = false
    snapshotRevision &+= 1
    let revision = snapshotRevision
    dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
      guard let self, self.snapshotRevision == revision else { return }
      if let offset = self.pendingScrollOffset {
        self.collectionView.layoutIfNeeded()
        let inset = self.collectionView.adjustedContentInset
        let maximum = max(-inset.top, self.collectionView.contentSize.height - self.collectionView.bounds.height + inset.bottom)
        let target = min(maximum, max(-inset.top, offset - inset.top))
        self.pendingScrollOffset = nil
        self.collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: self.animatePendingScroll)
        self.onScrollOffsetChanged?(target + inset.top)
      }
      self.triggerLoadMoreForVisibleRows()
    }
  }

  func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
    triggerLoadMoreIfNeeded(at: indexPath)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard pendingScrollOffset == nil else { return }
    onScrollOffsetChanged?(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
  }

  private func triggerLoadMoreIfNeeded(at indexPath: IndexPath) {
    guard footerState != .failed, let item = dataSource.itemIdentifier(for: indexPath) else { return }
    switch item {
    case .footer:
      triggerLoadMoreTask()
    case .row(let id):
      if let index = entryIndicesByID[id], index >= max(0, entries.count - loadMorePrefetchThreshold) {
        triggerLoadMoreTask()
      }
    case .header, .empty:
      break
    }
  }

  private func triggerLoadMoreForVisibleRows() {
    guard isViewLoaded else { return }
    for indexPath in collectionView.indexPathsForVisibleItems {
      triggerLoadMoreIfNeeded(at: indexPath)
    }
  }

  private func triggerLoadMoreTask() {
    guard hasMore, !isLoadingMore, loadMoreTask == nil, refreshTask == nil, let onLoadMore else { return }
    loadMoreTask = Task { @MainActor [weak self] in
      await onLoadMore()
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      self.loadMoreTask = nil
      self.triggerLoadMoreForVisibleRows()
    }
  }

  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    guard let appState, let client = appState.atProtoClient else { return }
    for indexPath in indexPaths {
      // Match the small look-ahead window instead of retaining work for a whole fling.
      guard prefetchTasks.count < 6 else { break }
      guard case .row(let id)? = dataSource.itemIdentifier(for: indexPath),
            let entry = entriesByID[id], prefetchTasks[id] == nil else { continue }
      prefetchTasks[id] = Task { @MainActor [weak self] in
        guard !Task.isCancelled else { return }
        switch entry {
        case .post(let box):
          await FeedPrefetchingManager.shared.prefetchPostData(post: box.value, client: client)
          await Self.prewarmVideo(for: box.value, appState: appState)
        case .feedPost(let box):
          await FeedPrefetchingManager.shared.prefetchPostData(post: box.value, client: client)
          await Self.prewarmVideo(for: box.value.post, appState: appState)
        case .bookmark(let box):
          if case .appBskyFeedDefsPostView(let post) = box.value.item {
            await FeedPrefetchingManager.shared.prefetchPostData(post: post, client: client)
            await Self.prewarmVideo(for: post, appState: appState)
          }
        }
        guard !Task.isCancelled else { return }
        self?.prefetchTasks[id] = nil
      }
    }
  }

  func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    for indexPath in indexPaths {
      guard case .row(let id)? = dataSource.itemIdentifier(for: indexPath) else { continue }
      prefetchTasks.removeValue(forKey: id)?.cancel()
    }
  }

  private static func prewarmVideo(for post: AppBskyFeedDefs.PostView, appState: AppState) async {
    guard !Task.isCancelled, appState.appSettings.autoplayVideos,
          case .appBskyEmbedVideoView(let video)? = post.embed,
          let url = video.playlist.url else { return }
    let media = appState.moderationPolicy.decide(post: post).ui(.contentMedia)
    guard !media.filter, !media.blur else { return }
    let model = VideoModel(
      id: url.absoluteString, url: url,
      type: .hlsStream(playlistURL: url, cid: video.cid, aspectRatio: nil),
      aspectRatio: 16.0 / 9.0
    )
    await VideoAssetManager.shared.prewarm(model)
  }
}

private struct PostListCollectionRepresentable: UIViewControllerRepresentable {
  let list: PostListCollectionView

  func makeUIViewController(context: Context) -> PostListCollectionController {
    let controller = PostListCollectionController()
    updateUIViewController(controller, context: context)
    return controller
  }

  func updateUIViewController(_ controller: PostListCollectionController, context: Context) {
    controller.updateScrollPosition(key: list.scrollPositionKey, requestID: list.scrollToTopRequestID)
    controller.hostingEnvironment = context.environment
    controller.appState = list.appState
    controller.headerView = list.headerView
    controller.rowViewBuilder = list.rowView
    controller.emptyView = list.emptyView
    controller.onLoadMore = list.onLoadMore
    controller.onRefresh = list.onRefresh
    controller.onRemoveBookmark = list.onRemoveBookmark
    controller.onScrollOffsetChanged = list.onScrollOffsetChanged
    controller.isScrollsToTop = list.scrollsToTop
    controller.setEntries(list.entries, hasMore: list.hasMore, isLoadingMore: list.isLoadingMore, footerState: list.footerState)
    controller.view.accessibilityIdentifier = list.accessibilityIdentifier
  }

  static func dismantleUIViewController(_ controller: PostListCollectionController, coordinator: ()) {
    controller.cancelTasks()
  }
}
#endif

/// Keep construction shared across platforms; macOS retains native List behavior.
struct PostListCollectionView: View {
  var entries: [PostListEntry]
  var headerView: AnyView?
  var rowView: (PostListEntry) -> AnyView
  var emptyView: AnyView?
  var hasMore: Bool
  var isLoadingMore: Bool
  var footerState: PostListFooterState
  var onLoadMore: (@MainActor () async -> Void)?
  var onRefresh: (@MainActor () async -> Void)?
  var onRemoveBookmark: (@MainActor (AppBskyBookmarkDefs.BookmarkView) async -> Bool)?
  var onScrollOffsetChanged: ((CGFloat) -> Void)?
  var scrollsToTop: Bool
  var scrollPositionKey: String?
  var scrollToTopRequestID: Int
  var appState: AppState?
  var accessibilityIdentifier: String?

  init(
    entries: [PostListEntry],
    headerView: AnyView? = nil,
    rowView: @escaping (PostListEntry) -> AnyView,
    emptyView: AnyView? = nil,
    hasMore: Bool = false,
    isLoadingMore: Bool = false,
    footerState: PostListFooterState = .hidden,
    onLoadMore: (@MainActor () async -> Void)? = nil,
    onRefresh: (@MainActor () async -> Void)? = nil,
    onRemoveBookmark: (@MainActor (AppBskyBookmarkDefs.BookmarkView) async -> Bool)? = nil,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
    scrollsToTop: Bool = true,
    scrollPositionKey: String? = nil,
    scrollToTopRequestID: Int = 0,
    appState: AppState? = nil,
    accessibilityIdentifier: String? = nil
  ) {
    self.entries = entries
    self.headerView = headerView
    self.rowView = rowView
    self.emptyView = emptyView
    self.hasMore = hasMore
    self.isLoadingMore = isLoadingMore
    self.footerState = footerState
    self.onLoadMore = onLoadMore
    self.onRefresh = onRefresh
    self.onRemoveBookmark = onRemoveBookmark
    self.onScrollOffsetChanged = onScrollOffsetChanged
    self.scrollsToTop = scrollsToTop
    self.scrollPositionKey = scrollPositionKey
    self.scrollToTopRequestID = scrollToTopRequestID
    self.appState = appState
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  init(
    posts: [AppBskyFeedDefs.PostView],
    headerView: AnyView? = nil,
    emptyView: AnyView? = nil,
    hasMore: Bool = false,
    isLoadingMore: Bool = false,
    footerState: PostListFooterState = .hidden,
    onLoadMore: (@MainActor () async -> Void)? = nil,
    onRefresh: (@MainActor () async -> Void)? = nil,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
    scrollsToTop: Bool = true,
    scrollPositionKey: String? = nil,
    scrollToTopRequestID: Int = 0,
    appState: AppState? = nil,
    accessibilityIdentifier: String? = nil,
    @ViewBuilder rowView: @escaping (AppBskyFeedDefs.PostView) -> some View
  ) {
    self.init(
      entries: posts.map { .post(EquatableBox($0)) },
      headerView: headerView,
      rowView: { entry in
        if case .post(let box) = entry { return AnyView(rowView(box.value)) }
        return AnyView(EmptyView())
      },
      emptyView: emptyView, hasMore: hasMore, isLoadingMore: isLoadingMore,
      footerState: footerState, onLoadMore: onLoadMore, onRefresh: onRefresh,
      onScrollOffsetChanged: onScrollOffsetChanged, scrollsToTop: scrollsToTop,
      scrollPositionKey: scrollPositionKey, scrollToTopRequestID: scrollToTopRequestID,
      appState: appState, accessibilityIdentifier: accessibilityIdentifier
    )
  }

  init(
    boxedPosts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>],
    headerView: AnyView? = nil,
    emptyView: AnyView? = nil,
    hasMore: Bool = false,
    isLoadingMore: Bool = false,
    footerState: PostListFooterState = .hidden,
    onLoadMore: (@MainActor () async -> Void)? = nil,
    onRefresh: (@MainActor () async -> Void)? = nil,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
    scrollsToTop: Bool = true,
    scrollPositionKey: String? = nil,
    scrollToTopRequestID: Int = 0,
    appState: AppState? = nil,
    accessibilityIdentifier: String? = nil,
    @ViewBuilder rowView: @escaping (EquatableBox<AppBskyFeedDefs.FeedViewPost>) -> some View
  ) {
    self.init(
      entries: boxedPosts.map { .feedPost($0) },
      headerView: headerView,
      rowView: { entry in
        if case .feedPost(let box) = entry { return AnyView(rowView(box)) }
        return AnyView(EmptyView())
      },
      emptyView: emptyView, hasMore: hasMore, isLoadingMore: isLoadingMore,
      footerState: footerState, onLoadMore: onLoadMore, onRefresh: onRefresh,
      onScrollOffsetChanged: onScrollOffsetChanged, scrollsToTop: scrollsToTop,
      scrollPositionKey: scrollPositionKey, scrollToTopRequestID: scrollToTopRequestID,
      appState: appState, accessibilityIdentifier: accessibilityIdentifier
    )
  }

  init(
    bookmarks: [AppBskyBookmarkDefs.BookmarkView],
    headerView: AnyView? = nil,
    emptyView: AnyView? = nil,
    hasMore: Bool = false,
    isLoadingMore: Bool = false,
    footerState: PostListFooterState = .hidden,
    onLoadMore: (@MainActor () async -> Void)? = nil,
    onRefresh: (@MainActor () async -> Void)? = nil,
    onRemoveBookmark: (@MainActor (AppBskyBookmarkDefs.BookmarkView) async -> Bool)? = nil,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
    scrollsToTop: Bool = true,
    scrollPositionKey: String? = nil,
    scrollToTopRequestID: Int = 0,
    appState: AppState? = nil,
    accessibilityIdentifier: String? = nil,
    @ViewBuilder rowView: @escaping (AppBskyBookmarkDefs.BookmarkView) -> some View
  ) {
    self.init(
      entries: bookmarks.map { .bookmark(EquatableBox($0)) },
      headerView: headerView,
      rowView: { entry in
        if case .bookmark(let box) = entry { return AnyView(rowView(box.value)) }
        return AnyView(EmptyView())
      },
      emptyView: emptyView, hasMore: hasMore, isLoadingMore: isLoadingMore,
      footerState: footerState, onLoadMore: onLoadMore, onRefresh: onRefresh,
      onRemoveBookmark: onRemoveBookmark,
      onScrollOffsetChanged: onScrollOffsetChanged, scrollsToTop: scrollsToTop,
      scrollPositionKey: scrollPositionKey, scrollToTopRequestID: scrollToTopRequestID,
      appState: appState, accessibilityIdentifier: accessibilityIdentifier
    )
  }

  var body: some View {
    #if os(iOS)
    PostListCollectionRepresentable(list: self)
    #else
    ScrollViewReader { proxy in
      List {
        Color.clear.frame(height: 0).id("post-list-top")
          .listRowInsets(EdgeInsets())
        if let headerView { headerView.listRowSeparator(.hidden) }
        if entries.isEmpty, let emptyView { emptyView.listRowSeparator(.hidden) }
        ForEach(entries) { entry in
          rowView(entry)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              if case .bookmark(let box) = entry, let onRemoveBookmark {
                Button(role: .destructive) {
                  Task { _ = await onRemoveBookmark(box.value) }
                } label: {
                  Label("Remove Bookmark", systemImage: "bookmark.slash")
                }
              }
            }
        }
        if footerState == .failed {
          PostListPaginationFooterView(state: .failed) {
            Task { await onLoadMore?() }
          }
          .listRowSeparator(.hidden)
        } else if hasMore {
          VStack {
            if isLoadingMore {
              ProgressView()
            } else {
              Button("Load More") { Task { await onLoadMore?() } }
            }
          }
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
          .task(id: entries.last?.id) {
            guard !isLoadingMore else { return }
            await onLoadMore?()
          }
        }
      }
      .listStyle(.plain)
      .refreshable { await onRefresh?() }
      .accessibilityIdentifier(accessibilityIdentifier ?? "post-list")
      .onChange(of: scrollToTopRequestID) { _, _ in
        withAnimation { proxy.scrollTo("post-list-top", anchor: .top) }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top
      } action: { _, offset in
        onScrollOffsetChanged?(offset)
      }
    }
    #endif
  }
}
