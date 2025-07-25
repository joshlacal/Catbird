import Petrel
import SwiftUI
import SwiftData
import UIKit
import os

// MARK: - Custom Feed Layout with Position Preservation
@available(iOS 18.0, *)
final class FeedCompositionalLayout: UICollectionViewCompositionalLayout {
  private var isPerformingUpdate = false
  private var preserveScrollPosition = true

  private let layoutLogger = Logger(
    subsystem: "blue.catbird", category: "FeedCompositionalLayout")

  override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
    super.prepare(forCollectionViewUpdates: updateItems)

    guard collectionView != nil, !updateItems.isEmpty else { return }

    // We'll handle position restoration manually in updateDataWithPositionPreservation
    isPerformingUpdate = true
  }

  override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint)
    -> CGPoint
  {
    // Let manual adjustment handle position restoration for better control
    return proposedContentOffset
  }

  override func finalizeCollectionViewUpdates() {
    super.finalizeCollectionViewUpdates()
    isPerformingUpdate = false
  }

  func setPreserveScrollPosition(_ preserve: Bool) {
    preserveScrollPosition = preserve
  }
}

// MARK: - Scroll Position Tracker
@available(iOS 18.0, *)
final class ScrollPositionTracker {
  private let logger = Logger(
    subsystem: "blue.catbird", category: "ScrollPositionTracker")

  struct ScrollAnchor {
    let indexPath: IndexPath
    let offsetY: CGFloat
    let itemFrameY: CGFloat
    let timestamp: Date
  }

  private var lastAnchor: ScrollAnchor?
  private(set) var isTracking = true

  func captureScrollAnchor(collectionView: UICollectionView) -> ScrollAnchor? {
    guard isTracking else { return nil }

    // Find the first visible post that's at least 30% visible
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    let visibleBounds = collectionView.bounds

    for indexPath in visibleIndexPaths {
      // Only consider post items
      if indexPath.section == FeedViewController.Section.posts.rawValue,
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
      {

        // Check if the item is sufficiently visible (at least 30% showing)
        let itemFrame = attributes.frame
        let visibleArea = itemFrame.intersection(visibleBounds)
        let visibilityRatio = visibleArea.height / itemFrame.height

        if visibilityRatio >= 0.3 {
          let anchor = ScrollAnchor(
            indexPath: indexPath,
            offsetY: collectionView.contentOffset.y,
            itemFrameY: itemFrame.origin.y,
            timestamp: Date()
          )

          lastAnchor = anchor
          logger.debug(
            "Captured scroll anchor: item[\(indexPath.section), \(indexPath.item)] at y=\(itemFrame.origin.y), offset=\(collectionView.contentOffset.y), visibility=\(visibilityRatio)"
          )
          return anchor
        }
      }
    }

    return nil
  }

  func restoreScrollPosition(collectionView: UICollectionView, to anchor: ScrollAnchor) {
    guard isTracking else { return }

    // Force layout to ensure all positions are calculated
    collectionView.layoutIfNeeded()

    // Find current position of the anchor item
    if let newAttributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) {
      let newItemY = newAttributes.frame.origin.y
      let deltaY = newItemY - anchor.itemFrameY

      // Calculate new scroll offset to maintain visual position
      let newOffset = anchor.offsetY + deltaY
      let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
      let clampedOffset = max(0, min(newOffset, maxOffset))

      if abs(collectionView.contentOffset.y - clampedOffset) > 1 {
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
        logger.debug(
          "Restored scroll position: anchor moved \(deltaY)pt, new offset=\(clampedOffset)")
      }
    }
  }

  func startTracking() {
    isTracking = true
  }

  func stopTracking() {
    isTracking = false
  }

  func getLastAnchor() -> ScrollAnchor? {
    return lastAnchor
  }
}

// MARK: - UIKit Feed Integration
@available(iOS 18.0, *)
final class FeedViewController: UICollectionViewController, StateInvalidationSubscriber {

  // MARK: - Types

  enum Section: Int, CaseIterable {
    case header = 0
    case posts = 1
    case loadMoreIndicator = 2
  }

  enum Item: Hashable, Sendable {
    case header(FetchType)  // Feed type for conditional header
    case post(CachedFeedViewPost)
    case loadMoreIndicator

    func hash(into hasher: inout Hasher) {
      switch self {
      case .header(let fetchType):
        hasher.combine("header")
        hasher.combine(fetchType.identifier)
      case .post(let post):
        hasher.combine("post")
        hasher.combine(post.id)
      case .loadMoreIndicator:
        hasher.combine("loadMoreIndicator")
      }
    }

    static func == (lhs: Item, rhs: Item) -> Bool {
      switch (lhs, rhs) {
      case (.header(let lhsFetch), .header(let rhsFetch)):
        return lhsFetch.identifier == rhsFetch.identifier
      case (.post(let lhsPost), .post(let rhsPost)):
        return lhsPost.id == rhsPost.id
      case (.loadMoreIndicator, .loadMoreIndicator):
        return true
      default:
        return false
      }
    }
  }

  // MARK: - Properties

  var fetchType: FetchType
  var appState: AppState
  var path: Binding<NavigationPath>
  private var modelContext: ModelContext

  /// Data source and posts
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private var posts: [CachedFeedViewPost] = []
  private var isLoading = false
  private var hasReachedEnd = false

  /// State invalidation system
  private var invalidationSubscription: UUID?

  /// Load more coordination
  private var loadMoreTask: Task<Void, Never>?

  /// New posts tracking
  private var lastRefreshTime = Date()
  private var refreshControl: UIRefreshControl!

  /// Callback for scroll offset changes (for navigation bar behavior)
  var onScrollOffsetChanged: ((CGFloat) -> Void)?

  /// Position tracking
  let scrollTracker = ScrollPositionTracker()
  private var isRefreshing = false

  /// Feed loading actions
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void

  // MARK: - Performance & Logging

  private let controllerLogger = Logger(subsystem: "blue.catbird", category: "FeedViewController")

  // MARK: - Enhanced Feed Components

  // Smart Tab Coordination
  private let smartTabCoordinator = SmartTabCoordinator()

  // New Posts Indicator Manager
  private let newPostsIndicatorManager = NewPostsIndicatorManager()
  private var newPostsIndicatorHostingController: UIHostingController<AnyView>?

  // Feed Continuity Manager
  private let continuityManager = FeedContinuityManager()
  private var continuityBannerHostingController: UIHostingController<AnyView>?

  // Activity tracking for enhanced UX
  private let userActivityTracker = UserActivityTracker()

  // Tab tap observer
  private var tabTapObserverTimer: Timer?

  // New posts check timer
  private var newPostsCheckTimer: Timer?

  // MARK: - Initialization

  init(
    appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>,
    modelContext: ModelContext,
    loadMoreAction: @escaping @Sendable () async -> Void,
    refreshAction: @escaping @Sendable () async -> Void
  ) {
    self.appState = appState
    self.fetchType = fetchType
    self.path = path
    self.modelContext = modelContext
    self.loadMoreAction = loadMoreAction
    self.refreshAction = refreshAction

    // Initialize with compositional layout
    let layout = Self.createCompositionalLayout()
    super.init(collectionViewLayout: layout)

    // Setup state invalidation
    setupStateInvalidation()

    // Log creation
    controllerLogger.debug("FeedViewController created for \(fetchType.identifier)")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupCollectionView()
    setupDataSource()
    setupRefreshControl()
    setupEnhancedComponents()
    setupPerformanceMonitoring()
    controllerLogger.debug("FeedViewController viewDidLoad completed")
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Ensure proper navigation behavior
    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.largeTitleDisplayMode = .automatic
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startActivityTracking()

    // Setup tab tap observer
    setupTabTapObserver()

    // Setup new posts check timer
    setupNewPostsCheckTimer()

    controllerLogger.debug("FeedViewController appeared")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopActivityTracking()

    // Cancel timers
    tabTapObserverTimer?.invalidate()
    newPostsCheckTimer?.invalidate()

    // Clean up enhanced components on main actor
      Task.detached { @MainActor [self] in
           smartTabCoordinator.resetAllHandlers()
           newPostsIndicatorManager.hideIndicator()
       continuityManager.hideBanner()
    }

    // Clean up hosting controllers
    newPostsIndicatorHostingController?.view.removeFromSuperview()
    newPostsIndicatorHostingController?.removeFromParent()
    newPostsIndicatorHostingController = nil

    continuityBannerHostingController?.view.removeFromSuperview()
    continuityBannerHostingController?.removeFromParent()
    continuityBannerHostingController = nil

    // Cancel load more task
    loadMoreTask?.cancel()
    loadMoreTask = nil

    controllerLogger.debug("FeedViewController disappeared")
  }

  deinit {
    // Unsubscribe from state invalidation
    if let subscription = invalidationSubscription {
      StateInvalidationService.shared.unsubscribe(subscription)
    }

    // Cancel timers
    newPostsCheckTimer?.invalidate()
    tabTapObserverTimer?.invalidate()

    // Clean up enhanced components on main actor
      Task.detached { @MainActor [self] in
           smartTabCoordinator.resetAllHandlers()
           newPostsIndicatorManager.hideIndicator()
       continuityManager.hideBanner()
    }

    // Clean up hosting controllers
    newPostsIndicatorHostingController?.view.removeFromSuperview()
    newPostsIndicatorHostingController?.removeFromParent()

    continuityBannerHostingController?.view.removeFromSuperview()
    continuityBannerHostingController?.removeFromParent()

    // Clear collection view
    collectionView.dataSource = nil
    collectionView.delegate = nil

    controllerLogger.debug("FeedViewController deallocated")
  }

  // MARK: - Setup

  private static func createCompositionalLayout() -> UICollectionViewCompositionalLayout {
    return UICollectionViewCompositionalLayout { (sectionIndex, layoutEnvironment) in
      let section = Section(rawValue: sectionIndex)!

      switch section {
      case .header:
        return createHeaderSection()
      case .posts:
        return createPostsSection()
      case .loadMoreIndicator:
        return createLoadMoreSection()
      }
    }
  }

  private static func createHeaderSection() -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(100)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(100)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0)

    return section
  }

  private static func createPostsSection() -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(200)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(200)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 1  // Minimal spacing between posts

    return section
  }

  private static func createLoadMoreSection() -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(60)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(60)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    return section
  }

  private func setupCollectionView() {
    collectionView.backgroundColor = .systemBackground
    collectionView.delegate = self

    // Configure behavior
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .onDrag
    collectionView.showsVerticalScrollIndicator = true

    // Performance optimizations
    collectionView.isPrefetchingEnabled = true
    collectionView.prefetchDataSource = self
  }

  private func setupDataSource() {
    // Register cells
    let headerRegistration = UICollectionView.CellRegistration<
      UICollectionViewListCell, FetchType
    > { [weak self] cell, indexPath, fetchType in
      self?.configureHeaderCell(cell, with: fetchType, at: indexPath)
    }

    let postRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, CachedFeedViewPost> {
      [weak self] cell, indexPath, post in
      self?.configurePostCell(cell, with: post, at: indexPath)
    }

    let loadMoreRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Void> {
      [weak self] cell, indexPath, _ in
      self?.configureLoadMoreCell(cell, at: indexPath)
    }

    dataSource = UICollectionViewDiffableDataSource<Section, Item>(
      collectionView: collectionView
    ) { collectionView, indexPath, item in
      switch item {
      case .header(let fetchType):
        return collectionView.dequeueConfiguredReusableCell(
          using: headerRegistration, for: indexPath, item: fetchType)
      case .post(let post):
        return collectionView.dequeueConfiguredReusableCell(
          using: postRegistration, for: indexPath, item: post)
      case .loadMoreIndicator:
        return collectionView.dequeueConfiguredReusableCell(
          using: loadMoreRegistration, for: indexPath, item: ())
      }
    }
  }

  private func configureHeaderCell(
    _ cell: UICollectionViewListCell, with fetchType: FetchType, at indexPath: IndexPath
  ) {
    // Only show header for specific feed types
    switch fetchType {
    case .feed(let uri):
      cell.contentConfiguration = UIHostingConfiguration {
        FeedDiscoveryHeaderView(feedURI: uri)
      }
    default:
      cell.contentConfiguration = nil
    }
  }

  private func configurePostCell(
    _ cell: UICollectionViewListCell, with post: CachedFeedViewPost, at indexPath: IndexPath
  ) {
    cell.contentConfiguration = UIHostingConfiguration {
      PostView(
        post: post.feedViewPost.post,
        showThreadIndicator: post.feedViewPost.showThreadIndicator,
        isThreadViewMain: false,
        path: self.path
      )
      .environment(self.appState)
    }
    .margins(.all, 0)

    // Clear background to prevent overlapping
    cell.backgroundColor = .clear
    cell.backgroundConfiguration = nil
  }

  private func configureLoadMoreCell(_ cell: UICollectionViewListCell, at indexPath: IndexPath) {
    cell.contentConfiguration = UIHostingConfiguration {
      HStack {
        Spacer()
        if self.isLoading {
          ProgressView()
            .scaleEffect(0.8)
        } else if self.hasReachedEnd {
          Text("End of feed")
            .foregroundStyle(.secondary)
            .appFont(AppTextRole.caption)
        } else {
          ProgressView()
            .scaleEffect(0.8)
        }
        Spacer()
      }
      .padding(.vertical, 16)
    }
    .margins(.all, 0)

    cell.backgroundColor = .clear
    cell.backgroundConfiguration = nil
  }

  private func setupRefreshControl() {
    refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    collectionView.refreshControl = refreshControl
  }

  // MARK: - Enhanced Components Setup

  private func setupEnhancedComponents() {
    setupSmartTabCoordination()
    setupNewPostsIndicator()
    setupFeedContinuityManager()
  }

  private func setupSmartTabCoordination() {
    smartTabCoordinator.configure(
      feedType: fetchType,
      collectionView: collectionView,
      appState: appState
    )
  }

  private func setupNewPostsIndicator() {
    let indicatorView = AnyView(
      EnhancedNewPostsIndicator(
        manager: newPostsIndicatorManager,
        onTapAction: { [weak self] in
          await self?.scrollToTopWithNewPosts()
        }
      )
    )

    let hostingController = UIHostingController(rootView: indicatorView)
    hostingController.view.backgroundColor = .clear

    // Add to parent view controller if available
    if let parentVC = parent {
      parentVC.addChild(hostingController)
      parentVC.view.addSubview(hostingController.view)
      hostingController.didMove(toParent: parentVC)

      // Position at top of feed
      hostingController.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        hostingController.view.topAnchor.constraint(
          equalTo: parentVC.view.safeAreaLayoutGuide.topAnchor, constant: 8),
        hostingController.view.leadingAnchor.constraint(
          equalTo: parentVC.view.leadingAnchor, constant: 16),
        hostingController.view.trailingAnchor.constraint(
          equalTo: parentVC.view.trailingAnchor, constant: -16),
      ])
    } else {
      // Add to collection view if no parent
      view.addSubview(hostingController.view)
      hostingController.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        hostingController.view.topAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        hostingController.view.trailingAnchor.constraint(
          equalTo: view.trailingAnchor, constant: -16),
      ])
    }

    newPostsIndicatorHostingController = hostingController
  }

  private func setupFeedContinuityManager() {
    let bannerView = AnyView(
      FeedContinuityIndicators(
        manager: continuityManager,
        onReconnectAction: { [weak self] in
          await self?.handleContinuityReconnect()
        }
      )
    )

    let hostingController = UIHostingController(rootView: bannerView)
    hostingController.view.backgroundColor = .clear

    // Add to parent view controller if available
    if let parentVC = parent {
      parentVC.addChild(hostingController)
      parentVC.view.addSubview(hostingController.view)
      hostingController.didMove(toParent: parentVC)

      // Position at top, below new posts indicator
      hostingController.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        hostingController.view.topAnchor.constraint(
          equalTo: parentVC.view.safeAreaLayoutGuide.topAnchor, constant: 60),
        hostingController.view.leadingAnchor.constraint(
          equalTo: parentVC.view.leadingAnchor, constant: 16),
        hostingController.view.trailingAnchor.constraint(
          equalTo: parentVC.view.trailingAnchor, constant: -16),
      ])
    } else {
      // Add to collection view if no parent
      view.addSubview(hostingController.view)
      hostingController.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        hostingController.view.topAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        hostingController.view.trailingAnchor.constraint(
          equalTo: view.trailingAnchor, constant: -16),
      ])
    }

    continuityBannerHostingController = hostingController
  }

  private func setupPerformanceMonitoring() {
    // Monitor scroll performance
    collectionView.addGestureRecognizer(
      UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:))))
  }

  @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
    // Track user interaction patterns for enhanced UX
    userActivityTracker.recordScrollGesture(gesture.state)
  }

  // MARK: - Tab Tap Observer

  private func setupTabTapObserver() {
    tabTapObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.checkForTabTap()
      }
    }
  }

  @MainActor
  private func checkForTabTap() async {
    if let tapped = appState.tabTappedAgain, tapped == 0 {
      await scrollToTopWithNewPosts()
      appState.tabTappedAgain = nil
    }
  }

  // MARK: - New Posts Check Timer

  private func setupNewPostsCheckTimer() {
    newPostsCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        await self?.checkForNewPosts()
      }
    }
  }

  @MainActor
  private func checkForNewPosts() async {
    // Only check if we're not already refreshing and it's been at least 1 minute
    guard !isRefreshing,
      Date().timeIntervalSince(lastRefreshTime) > 60,
      collectionView.contentOffset.y > 100  // User isn't at the top
    else { return }

    // Subtle background check for new posts
    // This could integrate with your feed manager to check for new posts without disrupting the user
    // For now, we'll just track that we checked
    lastRefreshTime = Date()
  }

  // MARK: - Activity Tracking

  private func startActivityTracking() {
    userActivityTracker.startSession(feedType: fetchType)
  }

  private func stopActivityTracking() {
    userActivityTracker.endSession()
  }

  // MARK: - State Invalidation

  private func setupStateInvalidation() {
    invalidationSubscription = StateInvalidationService.shared.subscribe { [weak self] in
      Task { @MainActor in
        await self?.handleStateInvalidation()
      }
    }
  }

  @MainActor
  private func handleStateInvalidation() async {
    controllerLogger.debug("State invalidation received, refreshing data")
    // Refresh data when state is invalidated
    await refreshData()
  }

  // MARK: - Data Management

  @MainActor
  func loadPostsDirectly(_ newPosts: [CachedFeedViewPost]) async {
    let oldPostsCount = posts.count
    posts = newPosts

    // Update data source
    await updateDataWithPositionPreservation(newPosts, insertAt: .replace)

    controllerLogger.debug(
      "Updated posts: \(oldPostsCount) -> \(newPosts.count) for \(fetchType.identifier)")
  }

  func handleFetchTypeChange(to newFetchType: FetchType) {
    fetchType = newFetchType
    controllerLogger.debug("Feed type changed to \(newFetchType.identifier)")
  }

  @MainActor
  private func refreshData() async {
    guard !isRefreshing else { return }

    isRefreshing = true
    controllerLogger.debug("Starting data refresh")

    await refreshAction()

    isRefreshing = false
    lastRefreshTime = Date()
    controllerLogger.debug("Data refresh completed")
  }

  @MainActor
  private func loadMore() async {
    guard !isLoading && !hasReachedEnd else { return }

    isLoading = true
    controllerLogger.debug("Loading more posts")

    await loadMoreAction()

    isLoading = false
    controllerLogger.debug("Load more completed")
  }

  // MARK: - Enhanced Actions

  @MainActor
  private func scrollToTopWithNewPosts() async {
    smartTabCoordinator.handleTabTap()

    // Hide new posts indicator
    newPostsIndicatorManager.hideIndicator()

    // Scroll to top with animation
    collectionView.setContentOffset(.zero, animated: true)

    // Refresh data to show new posts
    await refreshData()
  }

  @MainActor
  private func handleContinuityReconnect() async {
    continuityManager.hideBanner()
    await refreshData()
  }

  func scrollToTop() {
    collectionView.setContentOffset(.zero, animated: true)
  }

  // MARK: - Data Source Updates with Position Preservation

  @MainActor
  private func updateDataWithPositionPreservation(
    _ newPosts: [CachedFeedViewPost], insertAt position: DataInsertPosition
  ) async {
    // Capture current scroll position before making changes
    let scrollAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)

    // Update internal posts array
    switch position {
    case .replace:
      posts = newPosts
    case .append:
      posts.append(contentsOf: newPosts)
    case .prepend:
      posts = newPosts + posts
    }

    // Create and apply snapshot
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

    // Add sections
    snapshot.appendSections(Section.allCases)

    // Add header if needed
    switch fetchType {
    case .feed:
      snapshot.appendItems([.header(fetchType)], toSection: .header)
    default:
      break
    }

    // Add posts
    let postItems = posts.map { Item.post($0) }
    snapshot.appendItems(postItems, toSection: .posts)

    // Add load more indicator if not at end
    if !hasReachedEnd {
      snapshot.appendItems([.loadMoreIndicator], toSection: .loadMoreIndicator)
    }

    // Apply snapshot
    await dataSource.apply(snapshot, animatingDifferences: false)

    // Restore scroll position if we had an anchor
    if let anchor = scrollAnchor {
      // Wait for layout to complete
      try? await Task.sleep(nanoseconds: 50_000_000)
      scrollTracker.restoreScrollPosition(collectionView: collectionView, to: anchor)
    }
  }

  enum DataInsertPosition {
    case replace
    case append
    case prepend
  }

  // MARK: - Actions

  @objc private func handleRefresh() {
    Task { @MainActor in
      await refreshData()
      refreshControl.endRefreshing()
    }
  }
}

// MARK: - UICollectionViewDelegate

@available(iOS 18.0, *)
extension FeedViewController: UICollectionViewDelegate {

  func collectionView(
    _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    // Trigger load more when approaching the end
    if indexPath.section == Section.posts.rawValue {
      let threshold = max(0, posts.count - 3)
      if indexPath.item >= threshold {
        Task { @MainActor in
          await loadMore()
        }
      }
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Notify about scroll offset changes for navigation bar behavior
    let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    onScrollOffsetChanged?(offset)

    // Track user activity
    userActivityTracker.recordScrollOffset(offset)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      // Capture scroll position when user stops dragging
      _ = scrollTracker.captureScrollAnchor(collectionView: collectionView)
    }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    // Capture scroll position when scrolling stops
    _ = scrollTracker.captureScrollAnchor(collectionView: collectionView)
  }
}

// MARK: - UICollectionViewDataSourcePrefetching

@available(iOS 18.0, *)
extension FeedViewController: UICollectionViewDataSourcePrefetching {

  func collectionView(
    _ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]
  ) {
    // Pre-load data for upcoming cells
    for indexPath in indexPaths {
      if indexPath.section == Section.posts.rawValue && indexPath.item < posts.count {
        let post = posts[indexPath.item]
        // Pre-cache any heavy computations for the post
        _ = post.feedViewPost.post.indexedAt  // Access computed properties early
      }
    }
  }
}

// MARK: - Enhanced UX Components

@available(iOS 18.0, *)
final class SmartTabCoordinator {
  private var lastTabTapTime: Date?
  private var consecutiveTaps = 0

  func configure(
    feedType: FetchType, collectionView: UICollectionView, appState: AppState
  ) {
    // Configure based on feed type
  }

  func handleTabTap() {
    let now = Date()
    if let lastTap = lastTabTapTime, now.timeIntervalSince(lastTap) < 1.0 {
      consecutiveTaps += 1
    } else {
      consecutiveTaps = 1
    }
    lastTabTapTime = now

    // Handle different behaviors based on consecutive taps
    switch consecutiveTaps {
    case 1:
      // Single tap: scroll to top
      break
    case 2:
      // Double tap: refresh
      break
    default:
      break
    }
  }

  func resetAllHandlers() {
    lastTabTapTime = nil
    consecutiveTaps = 0
  }
}

@available(iOS 18.0, *)
final class NewPostsIndicatorManager: ObservableObject {
  @Published var isVisible = false
  @Published var newPostCount = 0
  @Published var newAuthors: [Petrel.AppBskyActorDefs.ProfileViewBasic] = []

  func showNewPostsIndicator(
    newPostCount: Int, authors: [Petrel.AppBskyActorDefs.ProfileViewBasic],
    feedType: FetchType, userActivity: UserActivityTracker
  ) {
    self.newPostCount = newPostCount
    self.newAuthors = Array(authors.prefix(3))  // Show up to 3 authors
    self.isVisible = true
  }

  func hideIndicator() {
    isVisible = false
    newPostCount = 0
    newAuthors = []
  }
}

@available(iOS 18.0, *)
final class FeedContinuityManager: ObservableObject {
  @Published var showReconnectBanner = false
  @Published var gapMessage = ""

  func showContinuityGap(message: String) {
    gapMessage = message
    showReconnectBanner = true
  }

  func hideBanner() {
    showReconnectBanner = false
    gapMessage = ""
  }
}

@available(iOS 18.0, *)
final class UserActivityTracker {
  private var sessionStartTime: Date?
  private var totalScrollDistance: CGFloat = 0
  private var lastScrollOffset: CGFloat = 0

  func startSession(feedType: FetchType) {
    sessionStartTime = Date()
    totalScrollDistance = 0
    lastScrollOffset = 0
  }

  func endSession() {
    sessionStartTime = nil
    totalScrollDistance = 0
  }

  func recordScrollOffset(_ offset: CGFloat) {
    if lastScrollOffset > 0 {
      totalScrollDistance += abs(offset - lastScrollOffset)
    }
    lastScrollOffset = offset
  }

  func recordScrollGesture(_ state: UIGestureRecognizer.State) {
    // Track scroll gesture patterns
  }
}

// MARK: - UI Components

struct EnhancedNewPostsIndicator: View {
  @ObservedObject var manager: NewPostsIndicatorManager
  let onTapAction: () async -> Void

  var body: some View {
    if manager.isVisible {
      Button(action: {
        Task {
          await onTapAction()
        }
      }) {
        HStack(spacing: 8) {
          if !manager.newAuthors.isEmpty {
            HStack(spacing: -4) {
              ForEach(Array(manager.newAuthors.enumerated()), id: \.offset) { index, author in
                AsyncImage(url: URL(string: author.avatar ?? "")) { image in
                  image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                } placeholder: {
                  Circle()
                    .fill(Color.gray.opacity(0.3))
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(
                  Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1)
                )
                .zIndex(Double(manager.newAuthors.count - index))
              }
            }
            .padding(.leading, 4)
          }

          VStack(alignment: .leading, spacing: 2) {
            Text("\(manager.newPostCount) new post\(manager.newPostCount == 1 ? "" : "s")")
              .font(.subheadline)
              .fontWeight(.medium)

            if !manager.newAuthors.isEmpty {
              Text("from \(manager.newAuthors.first?.displayName ?? manager.newAuthors.first?.handle ?? "")\(manager.newAuthors.count > 1 ? " and others" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Spacer()

          Image(systemName: "arrow.up")
            .font(.caption)
            .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(.thinMaterial)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        )
      }
      .buttonStyle(PlainButtonStyle())
      .transition(.move(edge: .top).combined(with: .opacity))
      .animation(.spring(response: 0.6, dampingFraction: 0.8), value: manager.isVisible)
    }
  }
}

struct FeedContinuityIndicators: View {
  @ObservedObject var manager: FeedContinuityManager
  let onReconnectAction: () async -> Void

  var body: some View {
    if manager.showReconnectBanner {
      Button(action: {
        Task {
          await onReconnectAction()
        }
      }) {
        HStack(spacing: 12) {
          Image(systemName: "wifi.exclamationmark")
            .foregroundStyle(.orange)

          VStack(alignment: .leading, spacing: 2) {
            Text("Connection gap detected")
              .font(.subheadline)
              .fontWeight(.medium)

            if !manager.gapMessage.isEmpty {
              Text(manager.gapMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Spacer()

          Text("Reconnect")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
            )
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(.thinMaterial)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        )
      }
      .buttonStyle(PlainButtonStyle())
      .transition(.move(edge: .top).combined(with: .opacity))
      .animation(.spring(response: 0.6, dampingFraction: 0.8), value: manager.showReconnectBanner)
    }
  }
}

// MARK: - Legacy UIKit Feed Wrapper (keeping for compatibility)

/// A complete UIKit implementation that provides native navigation bar behavior
struct FullUIKitFeedWrapper: UIViewControllerRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
@Environment(\.modelContext) private var modelContext
    
  func makeUIViewController(context: Context) -> UIKitFeedWrapperController {
    let controller = UIKitFeedWrapperController(
        appState: appState, fetchType: fetchType, path: $path, modelContext: modelContext)
    controller.feedController.onScrollOffsetChanged = onScrollOffsetChanged
    return controller
  }

  func updateUIViewController(_ uiViewController: UIKitFeedWrapperController, context: Context) {
    // Update scroll offset callback
    uiViewController.feedController.onScrollOffsetChanged = onScrollOffsetChanged

    // Handle tab tap to scroll to top
    if let tapped = appState.tabTappedAgain, tapped == 0 {
      uiViewController.feedController.scrollToTop()

      // Reset the tabTappedAgain value after handling
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        appState.tabTappedAgain = nil
      }
    }
  }
}

/// Wrapper controller that manages the feed controller
final class UIKitFeedWrapperController: UIViewController {
  let feedController: FeedViewController

  init(appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>, modelContext: ModelContext) {
    self.feedController = FeedViewController(
      appState: appState, fetchType: fetchType, path: path, modelContext: modelContext,
      loadMoreAction: {
        // This would be connected to your actual load more logic
      },
      refreshAction: {
        // This would be connected to your actual refresh logic
      }
    )

    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Add the feed controller as a child
    addChild(feedController)
    view.addSubview(feedController.view)
    feedController.view.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      feedController.view.topAnchor.constraint(equalTo: view.topAnchor),
      feedController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      feedController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      feedController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    feedController.didMove(toParent: self)
  }
}

// MARK: - Legacy Support for existing views

/// Provides backward compatibility with existing FeedContentView
struct NativeFeedContentView: View {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType
  let onScrollOffsetChanged: ((CGFloat) -> Void)?

  @Environment(\.modelContext) private var modelContext

  var body: some View {
    if #available(iOS 18.0, *) {
      FullUIKitFeedWrapper(
        posts: posts,
        appState: appState,
        fetchType: feedType,
        path: $path,
        onScrollOffsetChanged: onScrollOffsetChanged
      )
    } else {
      // Fallback to existing SwiftUI implementation
      FeedContentView(
        posts: posts,
        appState: appState,
        path: $path,
        loadMoreAction: loadMoreAction,
        refreshAction: refreshAction,
        feedType: feedType
      )
    }
  }
}
