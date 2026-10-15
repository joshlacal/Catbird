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
  private enum Section: Hashable {
    /// The only section; with a pinned header, the one above it, holding `headerView`.
    case main
    /// With a pinned header: the section under it, holding rows, `emptyView` and the footer.
    case content
  }
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
  /// A header that scrolls with the content until it reaches the navigation bar, then
  /// stays pinned under it (the profile tab picker). Lists without one keep one section.
  var pinnedHeaderView: AnyView?
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
  /// Set while SwiftUI updates this controller. A scroll report made then (a restored
  /// offset, or UIKit clamping the offset to new content) would write SwiftUI state during
  /// its view update, so it waits for this controller's next layout pass instead.
  private var isApplyingSwiftUIUpdate = false
  private var needsScrollReport = false
  /// Whether the pinned header is at its pin line, under the bars.
  private(set) var isHeaderPinned = false
  /// The pin offset at the end of the last layout pass.
  private var laidOutPinOffset: CGFloat?
  /// Lets the first row (a profile banner) sit under a transparent navigation
  /// bar instead of below it, where UIKit's automatic top inset would put it.
  var extendsUnderTopBar = false {
    didSet {
      guard extendsUnderTopBar != oldValue, isViewLoaded else { return }
      applyContentInsetBehavior()
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    setupCollectionView()
    setupDataSource()
    applySnapshot()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard needsScrollReport, !isApplyingSwiftUIUpdate, let collectionView else { return }
    needsScrollReport = false
    onScrollOffsetChanged?(collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    if extendsUnderTopBar { applyContentInsetBehavior() }
    // The pin line and the minimum content height follow the bars.
    if pinnedLayout?.pinnedSection != nil { collectionView.collectionViewLayout.invalidateLayout() }
  }

  /// Keeps UIKit's automatic insets and cancels only the top one, so the header
  /// starts under the bar. `.never` is not an option: it hands each cell the safe
  /// area it overlaps, UIHostingConfiguration adds that to the cell's height, and
  /// a row straddling the tab bar then grows on every pass (layout feedback loop).
  private func applyContentInsetBehavior() {
    guard let collectionView else { return }
    collectionView.contentInsetAdjustmentBehavior = .automatic
    let top = extendsUnderTopBar ? -view.safeAreaInsets.top : 0
    if collectionView.contentInset.top != top {
      collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
    }
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
      let currentOffset = collectionView.map { max(0, $0.contentOffset.y + $0.adjustedContentInset.top) }
      if let oldKey = scrollPositionKey, let currentOffset {
        savedOffsets[oldKey] = currentOffset
      }
      cancelTasks()
      scrollPositionKey = key
      needsRowReconfiguration = true
      pendingScrollOffset = PostListPinnedScrollRestoration.offset(
        saved: key.flatMap { savedOffsets[$0] },
        current: currentOffset ?? 0,
        pinOffset: pinnedLayout?.pinOffset
      )
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
    let layout = PostListPinnedHeaderLayout { [weak self] sectionIndex, environment in
      self?.layoutSection(at: sectionIndex, environment: environment)
    }
    let collectionView = LayoutReportingCollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.didLayoutSubviews = { [weak self] in self?.pinnedHeaderDidLayout() }
    self.collectionView = collectionView
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.directionalLayoutMargins = .zero
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .onDrag
    collectionView.scrollsToTop = isScrollsToTop
    applyContentInsetBehavior()
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
    let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] view, _, _ in
      self?.configurePinnedHeader(view)
    }
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
        // Per-item identity: a reused cell must not carry the previous row's SwiftUI state.
        root.id(accountID).id(item)
      }
      .margins(.all, 0)
    }
    dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
      collectionView, indexPath, item in
      collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }
    // Only the section under a pinned header has a header, so this is the only kind asked for.
    dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
      collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
    }
  }

  private func applySnapshot(animated: Bool = false) {
    guard let dataSource else { return }
    let previous = dataSource.snapshot()
    var snapshot = makeSnapshot()
    preparePinnedHeader(for: snapshot)

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
        self.reportScrollOffset(target + inset.top)
      }
      self.updatePinnedHeaderState()
      self.triggerLoadMoreForVisibleRows()
    }
  }

  func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
    triggerLoadMoreIfNeeded(at: indexPath)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updatePinnedHeaderState()
    guard pendingScrollOffset == nil else { return }
    reportScrollOffset(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
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

// MARK: - Scroll reports

extension PostListCollectionController {
  /// Runs SwiftUI's changes to this controller, holding back scroll reports they cause.
  func applySwiftUIUpdate(_ update: () -> Void) {
    isApplyingSwiftUIUpdate = true
    update()
    isApplyingSwiftUIUpdate = false
  }

  private func reportScrollOffset(_ offset: CGFloat) {
    guard isApplyingSwiftUIUpdate else {
      onScrollOffsetChanged?(offset)
      return
    }
    needsScrollReport = true
    viewIfLoaded?.setNeedsLayout()
  }
}

// MARK: - Layout and pinned header

extension PostListCollectionController {
  private var pinnedLayout: PostListPinnedHeaderLayout? {
    collectionView?.collectionViewLayout as? PostListPinnedHeaderLayout
  }

  /// One section, or with a pinned header two: the header item above it, everything else under it.
  private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.main])
    if headerView != nil { snapshot.appendItems([.header]) }
    if pinnedHeaderView != nil { snapshot.appendSections([.content]) }
    snapshot.appendItems(entries.map { .row($0.id) })
    if entries.isEmpty, emptyView != nil { snapshot.appendItems([.empty]) }
    if footerState != .hidden, footerState != .end { snapshot.appendItems([.footer]) }
    return snapshot
  }

  /// Points the layout at the snapshot's pinned section, sets the matching edge style, and
  /// refreshes the visible header, which the snapshot's reconfigured items don't include.
  private func preparePinnedHeader(for snapshot: NSDiffableDataSourceSnapshot<Section, Item>) {
    pinnedLayout?.pinnedSection = snapshot.indexOfSection(.content)
    applyPinnedHeaderEdgeStyle()
    reconfigureVisiblePinnedHeaders()
  }

  /// The plain, separator-free list every section uses. Only the section under a pinned
  /// header has a (supplementary) header; rows keep the bookmark swipe action either way.
  func listConfiguration(hasPinnedHeader: Bool) -> UICollectionLayoutListConfiguration {
    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
    configuration.backgroundColor = .clear
    configuration.showsSeparators = false
    if hasPinnedHeader {
      configuration.headerMode = .supplementary
      configuration.headerTopPadding = 0
    }
    configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
      self?.trailingSwipeActions(for: indexPath)
    }
    return configuration
  }

  func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard let onRemoveBookmark,
          case .row(let id)? = dataSource.itemIdentifier(for: indexPath),
          case .bookmark(let box)? = entriesByID[id] else { return nil }
    let action = UIContextualAction(style: .destructive, title: "Remove Bookmark") { _, _, completion in
      Task { @MainActor in
        completion(await onRemoveBookmark(box.value))
      }
    }
    action.image = UIImage(systemName: "bookmark.slash")
    return UISwipeActionsConfiguration(actions: [action])
  }

  private func layoutSection(at index: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
    if let layout = pinnedLayout, let pinnedSection = layout.pinnedSection, index < pinnedSection {
      return layout.sectionAbovePinnedHeader()
    }
    let hasPinnedHeader = dataSource?.sectionIdentifier(for: index) == .content
    let section = NSCollectionLayoutSection.list(
      using: listConfiguration(hasPinnedHeader: hasPinnedHeader), layoutEnvironment: environment
    )
    for header in section.boundarySupplementaryItems
    where header.elementKind == UICollectionView.elementKindSectionHeader {
      header.pinToVisibleBounds = true
      // Rows scroll underneath it.
      header.zIndex = 10
    }
    return section
  }

  private func configurePinnedHeader(_ view: UICollectionViewListCell) {
    view.backgroundConfiguration = .clear()
    view.directionalLayoutMargins = .zero
    let root = hosted(pinnedHeaderView ?? AnyView(EmptyView()))
    let accountID = appState?.userDID
    view.contentConfiguration = UIHostingConfiguration {
      root.id(accountID)
    }
    .margins(.all, 0)
    updateScrollEdgeEffect(behind: view)
  }

  /// Others are configured when dequeued.
  private func reconfigureVisiblePinnedHeaders() {
    guard pinnedHeaderView != nil, let collectionView else { return }
    for case let view as UICollectionViewListCell in collectionView.visibleSupplementaryViews(
      ofKind: UICollectionView.elementKindSectionHeader
    ) {
      configurePinnedHeader(view)
    }
  }

  /// Tracks whether the header sits at its pin line, and extends the top edge effect behind
  /// it only then: the interaction carries the effect down to the header wherever it is, so
  /// while the header is still in the content it would blur everything above it.
  private func updatePinnedHeaderState() {
    guard let layout = pinnedLayout, let collectionView else { return }
    let pinOffset = layout.pinOffset
    // While a layout change moves the pin line, a scroll (an offset clamped to new content)
    // says nothing about whether the header should stay pinned; the end of the pass decides.
    guard pinOffset == laidOutPinOffset else { return }
    let offset = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    let isPinned = pinOffset.map { offset >= $0 - PostListPinnedScrollRestoration.pinTolerance } ?? false
    guard isPinned != isHeaderPinned else { return }
    isHeaderPinned = isPinned
    for view in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
      updateScrollEdgeEffect(behind: view)
    }
  }

  /// Runs after each layout pass. A pass that moved the pin offset changed the height of the
  /// content above the header: more profile information, larger text, or rewrapping after a
  /// rotation. A header that was pinned goes back to its pin line. Scrolling never moves the
  /// pin offset, so this never works against someone scrolling, VoiceOver or scroll-to-top.
  private func pinnedHeaderDidLayout() {
    let pinOffset = pinnedLayout?.pinOffset
    guard pinOffset != laidOutPinOffset, let collectionView else { return }
    laidOutPinOffset = pinOffset
    if isHeaderPinned, pendingScrollOffset == nil, let pinOffset {
      let inset = collectionView.adjustedContentInset.top
      if collectionView.contentOffset.y + inset < pinOffset - PostListPinnedScrollRestoration.pinTolerance {
        collectionView.setContentOffset(CGPoint(x: 0, y: pinOffset - inset), animated: false)
      }
    }
    updatePinnedHeaderState()
  }

  /// Carries the navigation bar's top edge effect down behind the pinned header, as on a
  /// contact card, so rows fade out under the picker rather than at the bar.
  private func updateScrollEdgeEffect(behind view: UIView) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let existing = view.interactions.filter { $0 is UIScrollEdgeElementContainerInteraction }
      if isHeaderPinned, existing.isEmpty {
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = collectionView
        interaction.edge = .top
        view.addInteraction(interaction)
      } else if !isHeaderPinned {
        existing.forEach(view.removeInteraction)
      }
    }
    #endif
  }

  /// A list with a pinned header uses the soft top edge, so the blur behind the header fades
  /// out instead of ending in a line; other lists keep the automatic style.
  private func applyPinnedHeaderEdgeStyle() {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let collectionView {
      let style: UIScrollEdgeEffect.Style = pinnedLayout?.pinnedSection != nil ? .soft : .automatic
      if collectionView.topEdgeEffect.style != style { collectionView.topEdgeEffect.style = style }
    }
    #endif
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
    controller.applySwiftUIUpdate {
      controller.updateScrollPosition(key: list.scrollPositionKey, requestID: list.scrollToTopRequestID)
      controller.hostingEnvironment = context.environment
      controller.appState = list.appState
      controller.headerView = list.headerView
      controller.pinnedHeaderView = list.pinnedHeaderView
      controller.rowViewBuilder = list.rowView
      controller.emptyView = list.emptyView
      controller.onLoadMore = list.onLoadMore
      controller.onRefresh = list.onRefresh
      controller.onRemoveBookmark = list.onRemoveBookmark
      controller.onScrollOffsetChanged = list.onScrollOffsetChanged
      controller.isScrollsToTop = list.scrollsToTop
      controller.extendsUnderTopBar = list.extendsUnderTopBar
      controller.setEntries(list.entries, hasMore: list.hasMore, isLoadingMore: list.isLoadingMore, footerState: list.footerState)
      controller.view.accessibilityIdentifier = list.accessibilityIdentifier
    }
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
  /// Sits under `headerView` and pins below the navigation bar once scrolled up to it (iOS).
  var pinnedHeaderView: AnyView?
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
  var extendsUnderTopBar = false

  /// Draws the first row under a transparent navigation bar (profile banners).
  /// Pair with `.ignoresSafeArea(edges: .top)`.
  func extendingUnderTopBar() -> Self {
    var copy = self
    copy.extendsUnderTopBar = true
    return copy
  }

  init(
    entries: [PostListEntry],
    headerView: AnyView? = nil,
    pinnedHeaderView: AnyView? = nil,
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
    self.pinnedHeaderView = pinnedHeaderView
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
    pinnedHeaderView: AnyView? = nil,
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
      pinnedHeaderView: pinnedHeaderView,
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
        if let pinnedHeaderView { pinnedHeaderView.listRowSeparator(.hidden) }
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
