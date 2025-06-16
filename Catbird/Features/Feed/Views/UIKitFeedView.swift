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

    // Get current position of anchor item
    guard let currentAttributes = collectionView.layoutAttributesForItem(at: anchor.indexPath)
    else {
      logger.warning("Could not restore scroll position - anchor item not found")
      return
    }

    // Calculate how much content was added/removed above the anchor
    let currentItemY = currentAttributes.frame.origin.y
    let originalItemY = anchor.itemFrameY
    let heightDelta = currentItemY - originalItemY

    // Apply corrected offset
    let newOffsetY = anchor.offsetY + heightDelta
    let correctedOffset = max(0, newOffsetY)  // Don't scroll above content

    collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)

    logger.debug(
      "Restored scroll position: anchor moved from y=\(originalItemY) to y=\(currentItemY), delta=\(heightDelta), new offset=\(correctedOffset)"
    )
  }

  func pauseTracking() {
    isTracking = false
  }

  func resumeTracking() {
    isTracking = true
  }
}

// MARK: - Feed View Controller
@available(iOS 18.0, *)
final class FeedViewController: UICollectionViewController, StateInvalidationSubscriber {
  // MARK: - Properties
  private var appState: AppState
  private var feedModel: FeedModel?
  private(set) var fetchType: FetchType
  private var path: Binding<NavigationPath>

  // Callback for scroll offset changes to integrate with SwiftUI navigation
  var onScrollOffsetChanged: ((CGFloat) -> Void)?

  private var posts: [CachedFeedViewPost] = []
  private var isLoading = true
  private var hasInitialized = false
  private var isLoadingMore = false
  private var isRefreshing = false

  // Enhanced UX components
  private let userActivityTracker = UserActivityTracker()
  private lazy var smartTabCoordinator = SmartTabCoordinator(appState: appState)
  private let newPostsIndicatorManager = NewPostsIndicatorManager()

  // Background loader for smart tab coordination (placeholder for now)
  private lazy var backgroundLoader = BackgroundFeedLoader(appState: appState)

  // Smart refresh system components (simplified for production use)
  private let smartRefreshCoordinator = SmartFeedRefreshCoordinator()
  private let persistentStateManager = PersistentFeedStateManager.shared
  private let continuityManager = FeedContinuityManager()

  // New posts indicator (legacy support)
  private var newPostsAuthors: [AppBskyActorDefs.ProfileViewBasic] = []
  private var newPostsIndicatorHostingController: UIViewController?
  private var continuityBannerHostingController: UIViewController?

  // Scroll position management
  private let scrollTracker = ScrollPositionTracker()
  private var lastUpdateTime = Date.distantPast
  private let updateDebounceInterval: TimeInterval = 0.15

  // Loading state tracking
  private var pendingRefreshTask: Task<Void, Never>?
  private var pendingLoadMoreTask: Task<Void, Never>?
  private var lastRefreshTime = Date.distantPast

  // Timer management
  private var newPostsCheckTimer: Timer?
  private var tabTapObserverTimer: Timer?

  // Logger for debugging feed loading issues
  private let controllerLogger = Logger(
    subsystem: "blue.catbird", category: "FeedViewController")

  // Instance tracking for debugging
  private var instanceId: String = ""

  // MARK: - Navigation Setup
  // Navigation bar is fully controlled by SwiftUI - no UIKit manipulation needed

  // MARK: - Collection View Configuration
  private func configureCollectionView() {
    // Configure the inherited collection view from UICollectionViewController
    collectionView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    collectionView.showsVerticalScrollIndicator = true
    collectionView.prefetchDataSource = self

    // Add 10pt top content inset (matching ThreadView)
    collectionView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)

    // Enable automatic adjustment for navigation bars - critical for large title behavior
    collectionView.contentInsetAdjustmentBehavior = .automatic

    // Configure for better performance
    collectionView.isPrefetchingEnabled = true
    collectionView.remembersLastFocusedIndexPath = true

    // Enable scroll-to-top and navigation bar integration
    collectionView.scrollsToTop = true

    // Add native pull-to-refresh
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
    collectionView.refreshControl = refreshControl
  }

  private lazy var loadingView: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))

    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.startAnimating()

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Loading feed..."
    label.textAlignment = .center
    label.font = UIFont.preferredFont(forTextStyle: .body)

    let stackView = UIStackView(arrangedSubviews: [activityIndicator, label])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 8
    stackView.alignment = .center

    container.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    return container
  }()

  // MARK: - Data Source
  enum Section: Int, CaseIterable {
    case header
    case posts
    case loadMoreIndicator
  }

  enum Item: Hashable {
    case header(FetchType)  // Feed type for conditional header
    case post(CachedFeedViewPost)
    case loadMoreIndicator
  }

  private lazy var dataSource = createDataSource()

  // MARK: - Initialization
  init(appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>, modelContext: ModelContext) {
    self.appState = appState
    self.fetchType = fetchType
    self.path = path

    // Create layout for UICollectionViewController
    let layout = FeedViewController.createCompositionalLayout()
    super.init(collectionViewLayout: layout)

    // Set up model context for persistent manager and smart refresh coordinator
    persistentStateManager.setModelContext(modelContext)
    smartRefreshCoordinator.setModelContext(modelContext)

    // Subscribe to state invalidation events
    appState.stateInvalidationBus.subscribe(self)

    // Debug instance creation
    let instanceId = UUID().uuidString.prefix(8)
    self.instanceId = String(instanceId)
    controllerLogger.debug(
      "UIKitFeedView: INIT - Created instance \(self.instanceId) for fetchType: \(fetchType.identifier)"
    )
  }

  // MARK: - Layout Creation
  private static func createCompositionalLayout() -> UICollectionViewLayout {
    let layoutProvider: UICollectionViewCompositionalLayoutSectionProvider = {
      (sectionIndex, _) -> NSCollectionLayoutSection? in
      guard let section = Section(rawValue: sectionIndex) else { return nil }

      switch section {
      case .header:
        return FeedViewController.createHeaderSection()
      case .posts:
        return FeedViewController.createPostsSection()
      case .loadMoreIndicator:
        return FeedViewController.createLoadMoreSection()
      }
    }

    let layout = FeedCompositionalLayout(sectionProvider: layoutProvider)

    let config = UICollectionViewCompositionalLayoutConfiguration()
    config.interSectionSpacing = 0
    layout.configuration = config

    return layout
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    // Save current scroll position before cleanup
    saveCurrentScrollPosition()
    
    // Unsubscribe from state invalidation events
    appState.stateInvalidationBus.unsubscribe(self)

    // Remove notification observers
    NotificationCenter.default.removeObserver(self)

    // Cancel smart refresh operations
    smartRefreshCoordinator.cancelRefresh(for: fetchType.identifier)

    // Cancel pending tasks
    pendingRefreshTask?.cancel()
    pendingLoadMoreTask?.cancel()

    // Invalidate timers to prevent infinite loops
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

    controllerLogger.debug("UIKitFeedView [\(self.instanceId)] cleaned up with persistent state saved")
  }

  // MARK: - Lifecycle Methods
  override func viewDidLoad() {
    super.viewDidLoad()
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: viewDidLoad started")

    configureCollectionView()
    registerCells()

    // Configure for accessibility
    collectionView.accessibilityTraits = .none
    collectionView.shouldGroupAccessibilityChildren = true

    // Initialize enhanced components
    setupEnhancedComponents()

    // Set up new persistent and continuity systems
    setupPersistentScrollSystem()
    setupContinuityBanner()

    // Show loading overlay initially
    setupLoadingOverlay()

    // Set up tab tap observation
    observeAppStateTabTaps()

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: viewDidLoad completed, collection view frame: \(self.collectionView.frame.debugDescription)"
    )
  }

  // MARK: - Enhanced Component Setup

  private func setupEnhancedComponents() {
    // Enhanced components are now only used during pull-to-refresh
    // No background timers or automatic checking needed
    controllerLogger.debug(
      "Enhanced UX components initialized for feed: \(self.fetchType.identifier)")
  }

  // MARK: - Persistent Scroll System Setup

  private func setupPersistentScrollSystem() {
    // Try to restore scroll position from persistent storage
    if let savedPosition = persistentStateManager.loadScrollPosition(for: self.fetchType.identifier) {
      controllerLogger.debug(
        "Found saved scroll position for \(self.fetchType.identifier): post \(savedPosition.postId)"
      )
      // We'll restore this position after posts are loaded
    }

    // Schedule background refresh if needed
    smartRefreshCoordinator.scheduleBackgroundRefresh(for: self.fetchType.identifier)

    controllerLogger.debug("Persistent scroll system initialized for \(self.fetchType.identifier)")
  }

  private func setupContinuityBanner() {
    // Set up continuity banner view
    let continuityView = FeedContinuityView(
      continuityManager: continuityManager,
      onBannerTap: { [weak self] in
        self?.handleContinuityBannerTap()
      },
      onGapLoad: { [weak self] in
        self?.loadGapContent()
      }
    )
    .environment(appState)

    let hostingController = UIHostingController(rootView: continuityView)
    hostingController.view.backgroundColor = UIColor.clear

    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    // Position at the top of the view, below navigation bar
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
    ])

    continuityBannerHostingController = hostingController

    controllerLogger.debug("Continuity banner system initialized")
  }

  @MainActor
  private func handleContinuityBannerTap() {
    controllerLogger.debug("Continuity banner tapped")
    scrollToTop()
  }

  @MainActor
  private func loadGapContent() {
    controllerLogger.debug("Loading gap content")
    Task {
      await performRefresh()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    // Apply theme
    configureTheme()

    // Critical: Ensure collection view is properly configured for large titles
    if let navigationController = navigationController {
      // Force layout to ensure proper measurements
      view.layoutIfNeeded()

      // Ensure collection view extends under navigation bar
      extendedLayoutIncludesOpaqueBars = true

      // This is crucial for smooth large title transitions
      collectionView.contentInsetAdjustmentBehavior = .automatic

      // Set additional safe area insets if needed
      additionalSafeAreaInsets = UIEdgeInsets.zero
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: viewDidAppear - posts.isEmpty: \(self.posts.isEmpty), hasInitialized: \(self.hasInitialized), isLoading: \(self.isLoading)"
    )

    // Ensure theming is applied after view appears
    DispatchQueue.main.async {
      self.configureTheme()
    }

    // CORRECTED LOGIC: Use hasInitialized as the primary trigger
    if !hasInitialized {
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: First appearance (hasInitialized is false), triggering initial load."
      )

      // Mark as initialized immediately to prevent this block from running again
      hasInitialized = true

      // Ensure collection view is fully ready before loading
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.controllerLogger.debug(
          "UIKitFeedView [\(self.instanceId)]: About to call loadInitialFeedWithRetry")
        self.loadInitialFeedWithRetry()
      }
    } else if posts.isEmpty && !isLoading {
      // Fallback for cases where the view might reappear with no posts after an error
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: View re-appeared with no posts and not loading, attempting a reload."
      )
      loadInitialFeedWithRetry()
    } else {
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: Already initialized, skipping initial load.")
    }

    // SAFETY CHECK: Remove loading overlay after timeout if still present
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      if self?.loadingView.superview != nil {
        self?.controllerLogger.warning(
          "UIKitFeedView [\(self?.self.instanceId ?? "unknown")]: Loading overlay still present after 3 seconds, removing it"
        )
        self?.loadingView.removeFromSuperview()
      }
    }
  }

  // Ensure proper content offset handling for large title behavior
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    // Adjust content inset to account for navigation bar if needed
    if let navigationController = navigationController {
      let navBarHeight = navigationController.navigationBar.frame.height
      let statusBarHeight = view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0

      // Only adjust if not already adjusted by the system
      if collectionView.adjustedContentInset.top == 0 {
        collectionView.contentInset.top = navBarHeight + statusBarHeight
        collectionView.scrollIndicatorInsets.top = navBarHeight + statusBarHeight
      }
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    // Update theme when system appearance changes
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      configureTheme()

      // Update collection view background
      collectionView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
      view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this
      loadingView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    }
  }

  // MARK: - Theme Configuration

  private func configureTheme() {
    let currentScheme = getCurrentColorScheme()
    let isDarkMode = appState.themeManager.isDarkMode(for: currentScheme)
    let isBlackMode = appState.themeManager.isUsingTrueBlack

    // Update backgrounds - let SwiftUI handle view background to avoid TabView conflicts
    let backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: currentScheme))
    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this
    collectionView.backgroundColor = backgroundColor
    loadingView.backgroundColor = backgroundColor
  }

  // MARK: - UI Setup
  private func setupLoadingOverlay() {
    // Add loading view as overlay when needed
    view.addSubview(loadingView)

    loadingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      loadingView.topAnchor.constraint(equalTo: view.topAnchor),
      loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func registerCells() {
    collectionView.register(FeedHeaderCell.self, forCellWithReuseIdentifier: "FeedHeaderCell")
    collectionView.register(FeedPostCell.self, forCellWithReuseIdentifier: "FeedPostCell")
    collectionView.register(
      LoadMoreIndicatorCell.self, forCellWithReuseIdentifier: "LoadMoreIndicatorCell")
  }

  // MARK: - CollectionView Layout

  // Reuse PostHeightCalculator for accurate height estimations (matching ThreadView)
  private lazy var heightCalculator = PostHeightCalculator()

  private static func createHeaderSection() -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(60)
    )

    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(60)
    )

    let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 0

    return section
  }

  private static func createPostsSection() -> NSCollectionLayoutSection {
    // Use standard height estimation
    let estimatedHeight: CGFloat = 200

    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(estimatedHeight)
    )

    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(estimatedHeight)
    )

    let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 0  // No spacing - dividers are built into cells

    return section
  }

  private static func createLoadMoreSection() -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(80)
    )

    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(80)
    )

    let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
    return NSCollectionLayoutSection(group: group)
  }

  // MARK: - Data Source Creation
  private func createDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
    let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
      collectionView: collectionView
    ) { [weak self] (collectionView, indexPath, item) -> UICollectionViewCell? in
      guard let self = self else { return nil }

      switch item {
      case .header(let feedType):
        self.controllerLogger.debug(
          "UIKitFeedView [\(self.self.instanceId)]: Creating header cell for section \(indexPath.section), item \(indexPath.item)"
        )
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "FeedHeaderCell", for: indexPath)
          as! FeedHeaderCell
        cell.configure(fetchType: feedType, appState: self.appState)
        return cell

      case .post(let cachedPost):
        self.controllerLogger.debug(
          "UIKitFeedView [\(self.self.instanceId)]: Creating post cell for section \(indexPath.section), item \(indexPath.item), postID: \(cachedPost.id)"
        )
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "FeedPostCell", for: indexPath)
          as! FeedPostCell
        cell.configure(
          cachedPost: cachedPost,
          appState: self.appState,
          path: self.path
        )
        return cell

      case .loadMoreIndicator:
        self.controllerLogger.debug(
          "UIKitFeedView [\(self.self.instanceId)]: Creating load more cell for section \(indexPath.section), item \(indexPath.item)"
        )
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: "LoadMoreIndicatorCell", for: indexPath) as! LoadMoreIndicatorCell
        cell.configure(isLoading: self.isLoadingMore)
        return cell
      }
    }

    return dataSource
  }

  // MARK: - Feed Loading Logic

  func loadInitialFeedWithRetry() {
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: loadInitialFeedWithRetry called")
    Task(priority: .userInitiated) { @MainActor in
      // Load feed immediately - don't wait for authentication
      controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Loading feed immediately")
      await loadInitialFeed()
    }
  }

  private func loadInitialFeed() {
    Task(priority: .userInitiated) { @MainActor in
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: Starting initial feed load for: \(self.fetchType.identifier)"
      )

      // Get or create feed model - this works even without authentication
      feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)

      guard let model = feedModel else {
        controllerLogger.error("UIKitFeedView [\(self.instanceId)]: Failed to get feed model")
        isLoading = false
        loadingView.removeFromSuperview()
        return
      }

      isLoading = true

      // First, try to load cached data for immediate display
      if let cachedPosts = smartRefreshCoordinator.loadCachedData(for: fetchType.identifier),
         !cachedPosts.isEmpty {
        controllerLogger.debug(
          "UIKitFeedView [\(self.instanceId)]: Loaded \(cachedPosts.count) cached posts immediately"
        )
        
        await updateDataWithPositionPreservation(cachedPosts, insertAt: .replace)
        await restorePersistedScrollPosition(posts: cachedPosts)
        
        loadingView.removeFromSuperview()
        isLoading = false
        
        // Check if we should refresh in background
        let shouldRefresh = persistentStateManager.shouldRefreshFeed(
          feedIdentifier: fetchType.identifier,
          lastUserRefresh: nil,
          appBecameActiveTime: nil
        )
        
        if shouldRefresh {
          // Refresh in background without disrupting UI
          Task {
            await model.loadFeedWithFiltering(
              fetch: fetchType,
              forceRefresh: true,
              strategy: .fullRefresh,
              filterSettings: appState.feedFilterSettings
            )
            
            let updatedPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
            if updatedPosts.count != cachedPosts.count {
              // Save the updated data
              persistentStateManager.saveFeedData(updatedPosts, for: fetchType.identifier)
              
              // Check for new content
              if let firstCachedId = cachedPosts.first?.id,
                 let firstUpdatedId = updatedPosts.first?.id,
                 firstCachedId != firstUpdatedId {
                let newCount = updatedPosts.firstIndex { $0.id == firstCachedId } ?? 0
                if newCount > 0 {
                  continuityManager.showNewContentBanner(count: newCount) { [weak self] in
                    self?.scrollToTop()
                  }
                }
              }
            }
          }
        }
        
        return
      }

      // No cached data - try to load from FeedModel if available, otherwise show loading
      if !model.posts.isEmpty {
        controllerLogger.debug(
          "UIKitFeedView [\(self.instanceId)]: Loading \(model.posts.count) posts from FeedModel"
        )
        let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
        await updateDataWithPositionPreservation(filteredPosts, insertAt: .replace)
        
        loadingView.removeFromSuperview()
        isLoading = false
      } else {
        // Perform fresh load if we have authentication
        if appState.atProtoClient != nil {
          await model.loadFeedWithFiltering(
            fetch: fetchType,
            forceRefresh: true,
            strategy: .fullRefresh,
            filterSettings: appState.feedFilterSettings
          )
          
          let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
          
          // Save to cache for next time
          if !filteredPosts.isEmpty {
            persistentStateManager.saveFeedData(filteredPosts, for: fetchType.identifier)
          }
          
          await updateDataWithPositionPreservation(filteredPosts, insertAt: .replace)
          
          loadingView.removeFromSuperview()
          isLoading = false
          
          lastRefreshTime = Date()
          controllerLogger.debug(
            "UIKitFeedView [\(self.instanceId)]: Initial load completed with \(filteredPosts.count) posts"
          )
        } else {
          // No authentication yet - hide loading and wait
          loadingView.removeFromSuperview()
          isLoading = false
          controllerLogger.debug(
            "UIKitFeedView [\(self.instanceId)]: No authentication available, will load when auth completes"
          )
        }
      }
    }
  }

  @MainActor
  // Smart refresh system disabled to prevent scroll position and reload issues
  private func performSmartRefresh(strategy: RefreshStrategy, showProgress: Bool = true) {
    controllerLogger.debug("Smart refresh disabled - using standard refresh methods instead")
    // Use loadInitialFeed() or standard refresh methods instead
  }

  // Removed unused handleRefreshComplete method

  // Removed unused smart refresh error handler

  @MainActor
  private func restorePersistedScrollPosition(posts: [CachedFeedViewPost]) async {
    guard let savedPosition = persistentStateManager.loadScrollPosition(for: fetchType.identifier) else {
      return
    }
    
    // Find the post in current data
    guard let postIndex = posts.firstIndex(where: { $0.id == savedPosition.postId }) else {
      controllerLogger.debug("Saved scroll position post not found in current data")
      return
    }
    
    // Wait for layout to complete
    collectionView.layoutIfNeeded()
    
    let indexPath = IndexPath(item: postIndex, section: Section.posts.rawValue)
    if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
      let targetOffset = attributes.frame.origin.y + savedPosition.offsetFromPost
      let safeOffset = max(0, targetOffset)
      
      collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
      
      controllerLogger.debug(
        "Restored scroll position to post \(savedPosition.postId) with offset \(safeOffset)"
      )
    }
  }

  private func saveCurrentScrollPosition() {
    guard let anchor = scrollTracker.captureScrollAnchor(collectionView: collectionView),
          anchor.indexPath.section == Section.posts.rawValue,
          anchor.indexPath.item < posts.count else {
      return
    }
    
    let post = posts[anchor.indexPath.item]
    let offsetFromPost = collectionView.contentOffset.y - anchor.itemFrameY
    
    persistentStateManager.saveScrollPosition(
      postId: post.id,
      offsetFromPost: offsetFromPost,
      feedIdentifier: self.fetchType.identifier
    )
    
    controllerLogger.debug("Saved current scroll position for \(self.fetchType.identifier)")
  }

  // MARK: - Pull-to-Refresh Handler

  @objc private func handlePullToRefresh() {
    Task { @MainActor in
      // Save scroll position before refresh starts
      saveCurrentScrollPosition()
      
      // Use the method that properly preserves scroll position
      await performRefreshWithPositionPreservation()
      
      // End refreshing with a slight delay to smooth the transition
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.collectionView.refreshControl?.endRefreshing()
      }
    }
  }

  @MainActor
  private func performRefreshWithPositionPreservation() async {
    guard !isRefreshing, !isLoading, let model = feedModel else { return }

    controllerLogger.debug("Starting pull-to-refresh with position preservation")

    // Store current posts count and first post ID for comparison
    let originalPostsCount = posts.count
    let originalFirstPostId = posts.first?.id

    // Capture scroll position before refresh
    let scrollAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)

    isRefreshing = true
    lastRefreshTime = Date()

    // Mark user interaction to update activity tracking
    userActivityTracker.markUserInteraction()

    // Perform refresh to get new posts
    await model.loadFeedWithFiltering(
      fetch: fetchType,
      forceRefresh: true,
      strategy: .fullRefresh,
      filterSettings: appState.feedFilterSettings
    )

    // Get updated posts
    let newPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
    
    // Save to cache
    if !newPosts.isEmpty {
      persistentStateManager.saveFeedData(newPosts, for: fetchType.identifier)
    }

    // Check if we have new posts at the top
    let hasNewPosts =
      newPosts.count > originalPostsCount
      || (originalFirstPostId != nil && newPosts.first?.id != originalFirstPostId)

    controllerLogger.debug(
      "Pull-to-refresh: originalCount=\(originalPostsCount), newCount=\(newPosts.count), hasNewPosts=\(hasNewPosts)"
    )

    if let anchor = scrollAnchor {
      // We have a scroll anchor - use position preservation
      controllerLogger.debug("Using scroll anchor for position preservation")
      await updateDataWithNewPostsAtTop(
        newPosts, originalAnchor: anchor, hasNewPosts: hasNewPosts)

      // Show indicator if we have new posts and user isn't at the top
      if hasNewPosts {
        let newAuthors = Array(
          newPosts.prefix(
            originalPostsCount < newPosts.count ? newPosts.count - originalPostsCount : 0)
        )
        .compactMap { $0.feedViewPost.post.author }

        if !newAuthors.isEmpty {
          let newPostCount =
            originalPostsCount < newPosts.count ? newPosts.count - originalPostsCount : 1

          // Use enhanced indicator manager
          newPostsIndicatorManager.showNewPostsIndicator(
            newPostCount: newPostCount,
            authors: newAuthors,
            feedType: fetchType,
            userActivity: userActivityTracker,
            scrollView: collectionView
          )

          // Also use legacy indicator for compatibility
          showNewPostsIndicator(authors: newAuthors)
        }
      }
    } else {
      // No scroll anchor (user at very top) - simple update
      controllerLogger.debug("No scroll anchor - updating without position preservation")
      await updateDataWithPositionPreservation(newPosts, insertAt: .replace)
    }

    isRefreshing = false
    controllerLogger.debug("Pull-to-refresh completed")
  }

  /// Helper method to check if header should be shown for current feed
  private func shouldShowHeaderForCurrentFeed() -> Bool {
    do {
      guard let preferences = try appState.preferencesManager.getLocalPreferences() else {
        controllerLogger.debug(
          "🔍 FeedHeader: No preferences available for \(self.fetchType.identifier), hiding header")
        return false
      }

      let feedUri = fetchType.identifier
      let isPinned = preferences.pinnedFeeds.contains(feedUri)
      let isSaved = preferences.savedFeeds.contains(feedUri)
      let shouldShow = !isPinned && !isSaved

      controllerLogger.debug(
        "🔍 FeedHeader: Feed \(feedUri) shouldShow: \(shouldShow) (pinned: \(isPinned), saved: \(isSaved))"
      )
      return shouldShow

    } catch {
      controllerLogger.debug(
        "🔍 FeedHeader: Error accessing preferences for \(self.fetchType.identifier): \(error), hiding header"
      )
      return false
    }
  }

  // MARK: - Position-Preserving Data Updates

  enum InsertPosition: String, Sendable {
    case top
    case bottom
    case replace
  }

  // MARK: - Public Methods for SwiftUI Integration
  
  @MainActor
  func loadPostsDirectly(_ posts: [CachedFeedViewPost]) async {
    await updateDataWithPositionPreservation(posts, insertAt: .replace)
  }

  @MainActor
  private func updateDataWithPositionPreservation(
    _ newPosts: [CachedFeedViewPost], insertAt: InsertPosition
  ) async {
    let now = Date()

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Starting updateDataWithPositionPreservation with \(newPosts.count) new posts, insertAt: \(String(describing: insertAt))"
    )
    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Current posts count before update: \(self.posts.count)")

    // Debounce rapid updates to prevent scroll position jumps
    if now.timeIntervalSince(lastUpdateTime) < updateDebounceInterval {
      try? await Task.sleep(nanoseconds: UInt64(updateDebounceInterval * 1_000_000_000))
    }
    lastUpdateTime = now

    // Already on main thread due to @MainActor annotation

    // Only capture scroll position for operations that need it
    let scrollAnchor: ScrollPositionTracker.ScrollAnchor? = {
      // Check if scroll tracking is active
      guard scrollTracker.isTracking else { return nil }

      switch insertAt {
      case .top:
        // Only capture for top insertion where we're adding new items
        let existingIds = Set(posts.map { $0.id })
        let hasNewItems = newPosts.contains { !existingIds.contains($0.id) }
        return hasNewItems ? scrollTracker.captureScrollAnchor(collectionView: collectionView) : nil
      case .bottom, .replace:
        // Don't capture for bottom insertion or replacement
        return nil
      }
    }()

    // Update posts data based on insert position
    switch insertAt {
    case .top:
      // For top insertion, add new posts that aren't already present
      let existingIds = Set(posts.map { $0.id })
      let newUniqueItems = newPosts.filter { !existingIds.contains($0.id) }
      posts = newUniqueItems + posts
      controllerLogger.debug(
        "🔥 FEED UPDATE [\(self.instanceId)]: Top insertion - added \(newUniqueItems.count) new items, total posts: \(self.posts.count)"
      )

    case .bottom:
      // For bottom insertion (load more), replace with all new data
      posts = newPosts
      controllerLogger.debug(
        "🔥 FEED UPDATE [\(self.instanceId)]: Bottom insertion - replaced with \(newPosts.count) posts"
      )

    case .replace:
      // Complete replacement
      posts = newPosts
      controllerLogger.debug(
        "🔥 FEED UPDATE [\(self.instanceId)]: Replace - set posts to \(newPosts.count) items")
    }

    // Create and apply snapshot
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections(Section.allCases)

    // Add header with feed type only if it should be shown
    let shouldShowHeader = shouldShowHeaderForCurrentFeed()
    controllerLogger.debug(
      "🔥 FEED UPDATE [\(self.instanceId)]: Should show header: \(shouldShowHeader)")
    if shouldShowHeader {
      snapshot.appendItems([.header(fetchType)], toSection: .header)
    }

    // Add posts (refresh indicator is handled by UIRefreshControl)
    let postItems = posts.map { Item.post($0) }
    snapshot.appendItems(postItems, toSection: .posts)
    controllerLogger.debug(
      "🔥 FEED UPDATE [\(self.instanceId)]: Added \(postItems.count) post items to snapshot")

    // Add load more indicator if we have posts and not loading
    if !posts.isEmpty && !isLoading {
      snapshot.appendItems([.loadMoreIndicator], toSection: .loadMoreIndicator)
      controllerLogger.debug("🔥 FEED UPDATE [\(self.instanceId)]: Added load more indicator")
    }

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Final snapshot sections: \(snapshot.sectionIdentifiers.count), total items: \(snapshot.itemIdentifiers.count)"
    )
    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Snapshot sections: \(snapshot.sectionIdentifiers)")
    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Should show header: \(shouldShowHeader)")

    // Disable animations during update to prevent flicker
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Apply snapshot without animation for position preservation
    await dataSource.apply(snapshot, animatingDifferences: false)
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Applied snapshot to data source")

    // Debug collection view state after snapshot application
    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: After snapshot - numberOfSections: \(self.collectionView.numberOfSections)"
    )
    for section in 0..<self.collectionView.numberOfSections {
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: After snapshot - Section \(section) has \(self.collectionView.numberOfItems(inSection: section)) items"
      )
    }

    // Restore scroll position if we have an anchor and we're inserting at top
    if insertAt == .top, let anchor = scrollAnchor {
      // Give layout a chance to complete
      collectionView.performBatchUpdates({
        self.collectionView.layoutIfNeeded()
      }) { _ in
        self.scrollTracker.restoreScrollPosition(collectionView: self.collectionView, to: anchor)
        CATransaction.commit()
      }
    } else {
      // No position restoration needed
      CATransaction.commit()
    }

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Completed updateDataWithPositionPreservation - final posts count: \(self.posts.count)"
    )

    // Force layout and check visible cells
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.collectionView.layoutIfNeeded()
      self.controllerLogger.debug(
        "UIKitFeedView [\(self.self.instanceId)]: Post-update check - visible cells: \(self.collectionView.visibleCells.count)"
      )
      self.controllerLogger.debug(
        "UIKitFeedView [\(self.self.instanceId)]: Post-update check - contentSize: \(self.collectionView.contentSize.debugDescription)"
      )
      self.controllerLogger.debug(
        "UIKitFeedView [\(self.self.instanceId)]: Post-update check - bounds: \(self.collectionView.bounds.debugDescription)"
      )
    }
  }

  @MainActor
  private func updateDataWithNewPostsAtTop(
    _ newPosts: [CachedFeedViewPost], originalAnchor: ScrollPositionTracker.ScrollAnchor,
    hasNewPosts: Bool = true
  ) async {
    controllerLogger.debug("Updating data with position preservation (hasNewPosts: \(hasNewPosts))")

    // Store the current content offset and anchor item info
    let oldContentOffsetY = collectionView.contentOffset.y
    let anchorIndexPath = originalAnchor.indexPath

    // Pre-calculate heights for better position estimates
    for post in newPosts.prefix(min(10, newPosts.count)) {
      _ = heightCalculator.calculateHeight(for: post.feedViewPost.post, mode: .compact)
    }

    // Find the anchor post ID in the current data
    guard anchorIndexPath.section == Section.posts.rawValue && anchorIndexPath.item < posts.count
    else {
      controllerLogger.warning("Invalid anchor index, falling back to regular update")
      await updateDataWithPositionPreservation(newPosts, insertAt: .replace)
      return
    }

    let anchorPostId = posts[anchorIndexPath.item].id

    // For no new posts case, we might need to find by a different method if IDs changed
    let newAnchorIndex: Int?
    if hasNewPosts {
      newAnchorIndex = newPosts.firstIndex { $0.id == anchorPostId }
    } else {
      // Try to find by ID first, then by position if IDs are different (refreshed data)
      newAnchorIndex =
        newPosts.firstIndex { $0.id == anchorPostId }
        ?? (anchorIndexPath.item < newPosts.count ? anchorIndexPath.item : nil)
    }

    guard let newIndex = newAnchorIndex else {
      controllerLogger.warning("Anchor post not found in new data, falling back to regular update")
      await updateDataWithPositionPreservation(newPosts, insertAt: .replace)
      return
    }

    // Get current position of anchor item before update
    guard let oldAnchorAttributes = collectionView.layoutAttributesForItem(at: anchorIndexPath)
    else {
      controllerLogger.warning("Could not get anchor attributes, falling back to regular update")
      await updateDataWithPositionPreservation(newPosts, insertAt: .replace)
      return
    }

    let oldAnchorY = oldAnchorAttributes.frame.origin.y

    // Update posts data
    posts = newPosts

    // Create and apply snapshot without animation
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections(Section.allCases)

    // Add header with feed type only if it should be shown
    if shouldShowHeaderForCurrentFeed() {
      snapshot.appendItems([.header(fetchType)], toSection: .header)
    }

    // Add posts
    let postItems = posts.map { Item.post($0) }
    snapshot.appendItems(postItems, toSection: .posts)

    // Add load more indicator if we have posts
    if !posts.isEmpty && !isLoading {
      snapshot.appendItems([.loadMoreIndicator], toSection: .loadMoreIndicator)
    }

    // Disable animations during the update to prevent flicker
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Apply snapshot without animation for position preservation
    await dataSource.apply(snapshot, animatingDifferences: false)

    // Use performBatchUpdates for smoother position restoration
    await withCheckedContinuation { continuation in
      collectionView.performBatchUpdates({
        // Force layout to calculate new positions
        self.collectionView.layoutIfNeeded()
      }) { _ in
        // Calculate and apply position correction after layout is complete
        let newAnchorIndexPath = IndexPath(item: newIndex, section: Section.posts.rawValue)
        if let newAnchorAttributes = self.collectionView.layoutAttributesForItem(
          at: newAnchorIndexPath)
        {
          let newAnchorY = newAnchorAttributes.frame.origin.y
          let contentHeightAddedAbove = newAnchorY - oldAnchorY

          // Calculate new offset to maintain visual position
          let newCalculatedOffsetY = oldContentOffsetY + contentHeightAddedAbove

          // Ensure within bounds
          let contentHeight = self.collectionView.contentSize.height
          let boundsHeight = self.collectionView.bounds.height
          let maxPossibleOffsetY = max(0, contentHeight - boundsHeight)
          let safeOffsetY = max(0, min(newCalculatedOffsetY, maxPossibleOffsetY))

          // Apply the corrected offset without animation
          self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffsetY), animated: false)

          self.controllerLogger.debug(
            "Enhanced position preserved: anchor moved from y=\(oldAnchorY) to y=\(newAnchorY), delta=\(contentHeightAddedAbove), new offset=\(safeOffsetY)"
          )
        } else {
          self.controllerLogger.warning(
            "Could not restore position - anchor item not found after update")
        }

        // Re-enable animations
        CATransaction.commit()
        continuation.resume()
      }
    }
  }

  // MARK: - Refresh Actions

  @MainActor
  private func performRefresh() async {
    guard !isRefreshing, !isLoading, let model = feedModel else { return }

    // Cancel any pending refresh
    pendingRefreshTask?.cancel()

    pendingRefreshTask = Task { @MainActor in
      isRefreshing = true
      lastRefreshTime = Date()

      // Mark user interaction
      userActivityTracker.markUserInteraction()

      // Perform refresh
      await model.loadFeedWithFiltering(
        fetch: fetchType,
        forceRefresh: true,
        strategy: .fullRefresh,
        filterSettings: appState.feedFilterSettings
      )

      // Update posts
      let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
      await updateDataWithPositionPreservation(filteredPosts, insertAt: .replace)

      isRefreshing = false
      pendingRefreshTask = nil

      controllerLogger.debug("Enhanced refresh completed")
    }
  }

  @MainActor
  private func performLoadMore() async {
    guard !isLoadingMore, !isLoading, !isRefreshing, let model = feedModel else {
      controllerLogger.debug(
        "Load more blocked: isLoadingMore=\(self.isLoadingMore), isLoading=\(self.isLoading), isRefreshing=\(self.isRefreshing), hasModel=\(self.feedModel != nil)"
      )
      return
    }

    controllerLogger.debug("Starting load more...")

    isLoadingMore = true
    updateLoadMoreIndicator()

    // Load more posts
    await model.loadMoreWithFiltering(filterSettings: appState.feedFilterSettings)

    // Update posts - append to bottom, not replace
    let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
    controllerLogger.debug("Load more completed: loaded \(filteredPosts.count) total posts")

    await updateDataWithPositionPreservation(filteredPosts, insertAt: .bottom)

    isLoadingMore = false
    updateLoadMoreIndicator()
  }

  // Refresh indicator is now handled by UIRefreshControl - no longer needed

  private func updateLoadMoreIndicator() {
    var snapshot = dataSource.snapshot()
    if snapshot.itemIdentifiers(inSection: .loadMoreIndicator).contains(.loadMoreIndicator) {
      snapshot.reconfigureItems([.loadMoreIndicator])
      dataSource.apply(snapshot, animatingDifferences: false)
    }
  }

  // MARK: - State Invalidation Handling (Reduced Dependency)

  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    controllerLogger.debug("Feed handling state invalidation event: \(String(describing: event))")

    switch event {
    case .postCreated(let post):
      // Add new post optimistically at the top (only for local user posts)
      if let userDID = appState.authManager.state.userDID,
         post.author.did.didString() == userDID {
        await addPostOptimistically(post)
      } else {
        // For other users' posts, just note that new content is available
        continuityManager.updateContinuityInfo(
          for: fetchType.identifier,
          posts: posts,
          hasNewContent: true
        )
      }

    case .accountSwitched:
      // Critical event - clear and reload with new authentication state
      controllerLogger.debug(
        "🔥 FEED LOAD: Account switched - clearing posts and reloading with new client")
      await MainActor.run {
        posts.removeAll()
        feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)
        
        // Cancel any ongoing operations
        smartRefreshCoordinator.cancelRefresh(for: fetchType.identifier)
      }
      
      // Force immediate refresh for account switch using standard method
      await loadInitialFeed()

    case .authenticationCompleted:
      // Authentication became available - load feed if we haven't yet
      if posts.isEmpty {
        controllerLogger.debug("🔥 FEED LOAD: Authentication completed, loading initial feed")
        await MainActor.run {
          loadingView.removeFromSuperview()
        }
        isLoading = false
        await loadInitialFeed()
      }

    case .feedUpdated(let updatedFetchType):
      // Only refresh if this is our specific feed type and user hasn't recently refreshed
      if updatedFetchType.identifier == fetchType.identifier {
        let strategy = smartRefreshCoordinator.getRefreshStrategy(for: fetchType.identifier)
        // Only refresh if data is actually stale (> 10 minutes old)
        let timeSinceLastRefresh = Date().timeIntervalSince(lastRefreshTime)
        if timeSinceLastRefresh > 600 { // 10 minutes
          Task { @MainActor in
            await loadInitialFeed()
          }
        }
      }

    default:
      // For most other events, don't automatically refresh
      // Let the smart refresh coordinator decide when to update
      controllerLogger.debug("State invalidation event ignored by smart refresh system: \(String(describing: event))")
      break
    }
  }

  @MainActor
  private func addPostOptimistically(_ post: AppBskyFeedDefs.PostView) async {
    controllerLogger.info("Adding post optimistically to feed: \(post.uri.uriString())")

    // Create a cached post
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )

    var cachedPost = CachedFeedViewPost(from: feedViewPost, feedType: fetchType.identifier)
    cachedPost.isTemporary = true

    // Insert at top with position preservation
    await updateDataWithPositionPreservation([cachedPost], insertAt: .top)

    // Schedule refresh to get real data
    Task {
      try? await Task.sleep(for: .seconds(1))
      await performRefresh()
    }
  }

  // MARK: - Feed Type Changes

  /// Handle fetch type changes from SwiftUI
  @MainActor
  func handleFetchTypeChange(to newFetchType: FetchType) {
    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: Handling fetch type change from \(self.fetchType.identifier) to \(newFetchType.identifier)"
    )

    // Update the fetch type
    fetchType = newFetchType

    // Clear current posts
    posts.removeAll()

    // Get or create new feed model for the new fetch type
    feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)

    // Reset state
    isLoading = true
    hasInitialized = false

    // Load the new feed
    Task {
      await loadInitialFeed()
    }
  }

  // MARK: - Scroll to Top

  /// Scrolls to the top of the feed with animation
    @MainActor
    func scrollToTop() {
      // Mark user interaction
      userActivityTracker.markUserInteraction()

      // Hide indicators when scrolling to top
      hideNewPostsIndicator()
      newPostsIndicatorManager.hideIndicator()

      // Read adjustedContentInset.top on the main thread before the animation block
      let topInset = self.collectionView.adjustedContentInset.top

      UIView.animate(
        withDuration: 0.3, delay: 0, options: [.curveEaseInOut],
        animations: {
          // Scroll to top with content insets considered, using the stored value
          self.collectionView.setContentOffset(
            CGPoint(x: 0, y: -topInset), animated: false)
        })
    }
    
    
  // MARK: - New Posts Indicator

  @MainActor
  private func showNewPostsIndicator(authors: [AppBskyActorDefs.ProfileViewBasic]) {
    // Enhanced check using UserActivityTracker
    guard
      userActivityTracker.shouldShowNewContentIndicator(
        scrollView: collectionView,
        distanceFromTop: 300,  // Increased from 50 to 300pts
        minimumIdleTime: 2.0
      ) && !authors.isEmpty
    else {
      controllerLogger.debug(
        "Enhanced check: Not showing indicator - user activity check failed or no authors")
      return
    }

    controllerLogger.debug("Creating enhanced new posts indicator with \(authors.count) authors")
    newPostsAuthors = authors

    // Use enhanced indicator if available, fallback to legacy
    if let currentIndicator = newPostsIndicatorManager.currentIndicator {
      controllerLogger.debug("Using enhanced indicator manager")
      // Enhanced indicator is already being managed
      return
    }

    let indicatorView = NewPostsIndicator(authors: authors) { [weak self] in
      Task { @MainActor in
        self?.scrollToTop()
      }
    }
    .environment(appState)

    let hostingController = UIHostingController(rootView: AnyView(indicatorView))
    hostingController.view.backgroundColor = .clear

    // Remove existing indicator if present
    newPostsIndicatorHostingController?.view.removeFromSuperview()
    newPostsIndicatorHostingController?.removeFromParent()

    // Add new indicator
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    // Configure constraints
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hostingController.view.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
    ])

    newPostsIndicatorHostingController = hostingController

    controllerLogger.debug("Added enhanced new posts indicator to view hierarchy")

    // Animate in
    hostingController.view.alpha = 0
    hostingController.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    UIView.animate(
      withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0
    ) {
      hostingController.view.alpha = 1
      hostingController.view.transform = .identity
    }

    // Enhanced auto-hide after 15 seconds (increased from 8)
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      self?.hideNewPostsIndicator()
    }
  }

  @MainActor
  private func hideNewPostsIndicator() {
    guard let hostingController = newPostsIndicatorHostingController else { return }

    UIView.animate(
      withDuration: 0.25,
      animations: {
        hostingController.view.alpha = 0
        hostingController.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
      }
    ) { _ in
      hostingController.view.removeFromSuperview()
      hostingController.removeFromParent()
    }

    newPostsIndicatorHostingController = nil
    newPostsAuthors.removeAll()
  }

  /// Display enhanced new posts indicator as a SwiftUI view
  @MainActor
  private func showEnhancedNewPostsIndicator(
    newPostCount: Int,
    authors: [AppBskyActorDefs.ProfileViewBasic],
    timestamp: Date
  ) {
    // Remove any existing enhanced indicator
    hideEnhancedNewPostsIndicator()

    let enhancedIndicatorView = EnhancedNewPostsIndicator(
      newPostCount: newPostCount,
      authors: authors,
      timestamp: timestamp,
      onTap: { [weak self] in
        Task { @MainActor in
          self?.handleNewPostsIndicatorTap()
        }
      },
      onDismiss: { [weak self] in
        Task { @MainActor in
          self?.hideEnhancedNewPostsIndicator()
        }
      }
    )
    .environment(appState)

    let hostingController = UIHostingController(rootView: enhancedIndicatorView)
    hostingController.view.backgroundColor = .clear

    // Add to view hierarchy
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    // Configure constraints
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hostingController.view.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
    ])

    // Store reference (reusing the same property for now)
    newPostsIndicatorHostingController = hostingController

    controllerLogger.info(
      "Enhanced new posts indicator displayed: \(newPostCount) posts from \(authors.count) authors")
  }

  @MainActor
  private func hideEnhancedNewPostsIndicator() {
    hideNewPostsIndicator()  // Use existing implementation
  }

  @MainActor
  private func handleNewPostsIndicatorTap() {
    // Hide the indicator immediately
    hideNewPostsIndicator()
    newPostsIndicatorManager.hideIndicator()

    // Simply scroll to top to show the new posts that were added during pull-to-refresh
    scrollToTop()
  }

  // MARK: - Tab Tap Handling

  /// Set up observer for AppState tab tap events
  private func observeAppStateTabTaps() {
    // Invalidate any existing timer to prevent multiple timers
    tabTapObserverTimer?.invalidate()

    // Use AppState's tabTappedAgain property changes
    Task { @MainActor in
      // Check periodically for tab tap changes
      // This is a simple approach - could be enhanced with Combine
      tabTapObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
        [weak self] timer in
        guard let self = self else {
          timer.invalidate()
          return
        }

        if let tappedTab = self.appState.tabTappedAgain, tappedTab == 0 {
          self.handleTabTappedAgain(tappedTab)
          // Reset the flag to prevent repeated triggers
          self.appState.tabTappedAgain = nil
        }
      }
    }
  }

  /// Handle tab tap events from AppState with enhanced smart behavior
  func handleTabTappedAgain(_ tabIndex: Int?) {
    guard tabIndex == 0 else { return }  // Only handle home tab

    Task { @MainActor in
      // Mark user interaction
      userActivityTracker.markUserInteraction()

      // Use smart tab coordinator for intelligent behavior
      await smartTabCoordinator.handleHomeFeedTabTap(
        scrollView: collectionView,
        userActivity: userActivityTracker,
        backgroundLoader: backgroundLoader,
        fetchType: fetchType,
        lastRefreshTime: lastRefreshTime != Date.distantPast ? lastRefreshTime : nil,
        onRefresh: { [weak self] in
          await self?.performRefresh()
        },
        onScrollToTop: { [weak self] in
          self?.scrollToTop()
        }
      )
    }
  }
}

// MARK: - Collection View Cells
// FeedHeaderCell is now in a separate file: UIKitFeedHeaderCell.swift

@available(iOS 18.0, *)
final class FeedPostCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupCell()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupCell() {
    // Configure cell appearance
    backgroundColor = .clear

    // Configure for better performance
    layer.shouldRasterize = false
    isOpaque = false
  }

  func configure(cachedPost: CachedFeedViewPost, appState: AppState, path: Binding<NavigationPath>)
  {
    // Set themed background color
    let currentScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let effectiveScheme = appState.themeManager.effectiveColorScheme(for: currentScheme)
    contentView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: effectiveScheme))

    // Always use enhanced feed post view for consistent rendering in feeds with divider
    let content = AnyView(
      VStack(spacing: 0) {
        EnhancedFeedPost(
          cachedPost: cachedPost,
          path: path
        )
        .environment(appState)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)

        // Add full-width divider at bottom of each post
        Divider()
          .padding(.top, 3)
      }
    )

    // Only reconfigure if needed (using post id as identity check)
    let postIdentifier = cachedPost.id
    if contentConfiguration == nil
      || postIdentifier != (contentView.tag != 0 ? String(contentView.tag) : nil)
    {

      // Store post ID in tag for comparison on reuse
      contentView.tag = postIdentifier.hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Clean up resources when cell is reused
    contentConfiguration = nil
    contentView.tag = 0
  }
}

// RefreshIndicatorCell removed - using UIRefreshControl instead

@available(iOS 18.0, *)
final class LoadMoreIndicatorCell: UICollectionViewCell {
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private var isCurrentlyLoading = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear

    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Load more posts"
    label.font = UIFont.preferredFont(forTextStyle: .subheadline)
    label.textColor = UIColor.systemBlue
    label.textAlignment = .center

    let stackView = UIStackView(arrangedSubviews: [activityIndicator, label])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center

    contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])

    // Make it tappable
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
    addGestureRecognizer(tapGesture)
  }

  @objc private func cellTapped() {
    // Trigger load more action through delegate pattern
    // This will be handled by the collection view's didSelectItem
  }

  func configure(isLoading: Bool) {
    // Only update if the state is changing to avoid unnecessary UI updates
    guard isLoading != isCurrentlyLoading else { return }

    isCurrentlyLoading = isLoading

    if isLoading {
      activityIndicator.startAnimating()
      label.text = "Loading more..."
      label.textColor = UIColor.systemGray
    } else {
      activityIndicator.stopAnimating()
      label.text = "Load more posts"
      label.textColor = UIColor.systemBlue
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityIndicator.stopAnimating()
    isCurrentlyLoading = false
  }
}

// MARK: - UICollectionViewDelegate
@available(iOS 18.0, *)
extension FeedViewController: UICollectionViewDataSourcePrefetching {
  override func collectionView(
    _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
  ) {
    collectionView.deselectItem(at: indexPath, animated: true)

    guard let section = Section(rawValue: indexPath.section) else { return }

    switch section {
    case .header:
      // Header tapped - could show feed settings or do nothing
      break
    case .posts:
      // Post tapped - handled by the post cell itself
      break
    case .loadMoreIndicator:
      Task {
        await performLoadMore()
      }
    }
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let scrollOffset = scrollView.contentOffset.y

    // Update user activity tracking
    userActivityTracker.updateScrollActivity(scrollView: scrollView)

    // Notify SwiftUI about scroll offset changes for navigation bar integration
    onScrollOffsetChanged?(scrollOffset)

    // Update new posts indicator visibility based on enhanced logic
    newPostsIndicatorManager.updateVisibilityForScrollPosition(
      userActivity: userActivityTracker,
      scrollView: scrollView
    )

    // Legacy indicator support
    let isNearTop = scrollOffset <= -scrollView.adjustedContentInset.top + 100
    if isNearTop && newPostsIndicatorHostingController != nil {
      hideNewPostsIndicator()
    }

    // Periodically save scroll position (throttled to avoid excessive saves)
    let now = Date()
    if now.timeIntervalSince(lastUpdateTime) > 2.0 { // Save every 2 seconds max
      saveCurrentScrollPosition()
      lastUpdateTime = now
    }

    // Simple infinite scroll trigger (matching SwiftUI LoadMoreTrigger pattern)
    let contentHeight = scrollView.contentSize.height
    let scrollHeight = scrollView.frame.height

    // Trigger when within 2 screen heights of the bottom (more eager than before)
    let triggerThreshold = scrollHeight * 2.0
    let isNearBottom = (scrollOffset + scrollHeight) > (contentHeight - triggerThreshold)

    if isNearBottom && !isLoadingMore && !isLoading && !posts.isEmpty {
      // Cancel any existing load more task
      pendingLoadMoreTask?.cancel()

      // Immediate trigger with minimal debounce (matching SwiftUI pattern)
      pendingLoadMoreTask = Task { @MainActor [weak self] in
        guard let self = self else { return }

        do {
          // Minimal debounce to prevent rapid-fire (matching SwiftUI 200ms but reduced)
          try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

          if !Task.isCancelled {
            controllerLogger.debug("Triggering load more...")
            await self.performLoadMore()
          }
        } catch {
          // Task cancelled
          controllerLogger.debug("Load more task cancelled")
        }

        self.pendingLoadMoreTask = nil
      }
    }
  }

  // Pull-to-refresh is now handled by UIRefreshControl

  // MARK: - Prefetching
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    let postIndexPaths = indexPaths.filter {
      $0.section == Section.posts.rawValue && $0.item < posts.count
    }
    guard !postIndexPaths.isEmpty else { return }

    // Extract posts for prefetching
    let postsToPreload = postIndexPaths.compactMap { indexPath in
      posts[indexPath.item].feedViewPost
    }

    guard !postsToPreload.isEmpty else { return }

    Task {
      // Prefetch individual post data if we have an AT Proto client
      if let client = appState.atProtoClient {
        for post in postsToPreload {
          await FeedPrefetchingManager.shared.prefetchPostData(post: post, client: client)
        }
      }
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    // The FeedPrefetchingManager handles its own task cancellation and cache management
    // No explicit cancellation needed as it uses intelligent deduplication
  }
}

// MARK: - SwiftUI Integration

@available(iOS 18.0, *)
struct UIKitFeedViewRepresentable: UIViewRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  @Environment(\.modelContext) private var modelContext
  
  func makeUIView(context: Context) -> UICollectionView {
    // Create the feed controller to use its layout and configuration
    let feedController = FeedViewController(
      appState: appState,
      fetchType: fetchType,
      path: $path,
      modelContext: modelContext
    )
    
    // Get the collection view safely
    guard let collectionView = feedController.collectionView else {
      // Fallback: create a basic collection view if feedController's is nil
      let layout = FeedCompositionalLayout(sectionProvider: { _, _ in
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(200)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
      })
      return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }
    
    // Set up the coordinator to bridge UIKit and SwiftUI
    let coordinator = context.coordinator
    coordinator.feedController = feedController
    
    // Set the scroll offset callback on the feed controller
    feedController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Keep the feed controller as the delegate (don't override with coordinator)
    // The feed controller will handle scroll events and call our callback
    
    // Ensure proper navigation bar integration for large title behavior
    collectionView.contentInsetAdjustmentBehavior = .automatic
    
    return collectionView
  }
  
  func updateUIView(_ uiView: UICollectionView, context: Context) {
    // Update the feed controller with new posts
    if let feedController = context.coordinator.feedController {
      Task { @MainActor in
        await feedController.loadPostsDirectly(posts)
      }
      
      // Update scroll offset callback on the feed controller
      feedController.onScrollOffsetChanged = onScrollOffsetChanged
    }
    
    // Update scroll offset callback on coordinator as backup
    context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(
      feedController: nil,
      loadMoreAction: loadMoreAction,
      refreshAction: refreshAction,
      onScrollOffsetChanged: onScrollOffsetChanged
    )
  }
  
  // MARK: - Coordinator
  
  class Coordinator: NSObject, UICollectionViewDelegate {
    var feedController: FeedViewController?
    let loadMoreAction: @Sendable () async -> Void
    let refreshAction: @Sendable () async -> Void
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    init(
      feedController: FeedViewController?,
      loadMoreAction: @escaping @Sendable () async -> Void,
      refreshAction: @escaping @Sendable () async -> Void,
      onScrollOffsetChanged: ((CGFloat) -> Void)?
    ) {
      self.feedController = feedController
      self.loadMoreAction = loadMoreAction
      self.refreshAction = refreshAction
      self.onScrollOffsetChanged = onScrollOffsetChanged
    }
    
    // Delegate scroll events - SwiftUI NavigationStack will automatically detect these
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onScrollOffsetChanged?(scrollView.contentOffset.y)
    }
    
    // Handle selection and other collection view events
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      feedController?.collectionView(collectionView, didSelectItemAt: indexPath)
    }
  }
}

// MARK: - Full UIKit Navigation Wrapper

/// A complete UIKit navigation controller that provides native navigation bar behavior
struct FullUIKitNavigationWrapper: UIViewControllerRepresentable {
  let appState: AppState
  let fetchType: FetchType
  let feedName: String
  @Binding var path: NavigationPath
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  let isDrawerOpenBinding: Binding<Bool>
  let showingSettingsBinding: Binding<Bool>
@Environment(\.modelContext) private var modelContext
    
  func makeUIViewController(context: Context) -> UIKitNavigationController {
    let controller = UIKitNavigationController(
      appState: appState,
      fetchType: fetchType,
      feedName: feedName,
      path: $path,
      isDrawerOpenBinding: isDrawerOpenBinding,
      showingSettingsBinding: showingSettingsBinding,
        modelContext: modelContext
    )
    controller.feedController.onScrollOffsetChanged = onScrollOffsetChanged
    return controller
  }

  func updateUIViewController(_ uiViewController: UIKitNavigationController, context: Context) {
    // Update scroll offset callback
    uiViewController.feedController.onScrollOffsetChanged = onScrollOffsetChanged

    // Update navigation title if changed
    if uiViewController.feedController.title != feedName {
      uiViewController.feedController.title = feedName
    }

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

// MARK: - UIKit Navigation Controller

/// A UIKit navigation controller that provides complete control over navigation behavior
@available(iOS 18.0, *)
final class UIKitNavigationController: UINavigationController {
  let feedController: FeedViewController
  private let appState: AppState
  private let isDrawerOpenBinding: Binding<Bool>
  private let showingSettingsBinding: Binding<Bool>
  private let navigationPath: Binding<NavigationPath>
  private var navigationObservation: Any?
  private var lastPathCount = 0
  private var navigationPathTimer: Timer?

  init(
    appState: AppState,
    fetchType: FetchType,
    feedName: String,
    path: Binding<NavigationPath>,
    isDrawerOpenBinding: Binding<Bool>,
    showingSettingsBinding: Binding<Bool>,
    modelContext: ModelContext
  ) {
    self.appState = appState
    self.isDrawerOpenBinding = isDrawerOpenBinding
    self.showingSettingsBinding = showingSettingsBinding
    self.navigationPath = path
    self.feedController = FeedViewController(appState: appState, fetchType: fetchType, path: path, modelContext: modelContext)

    super.init(nibName: nil, bundle: nil)

    // Set the feed controller as the root view controller
    viewControllers = [feedController]

    // Configure the navigation bar
    setupNavigationBar()

    // Set the navigation title
    feedController.title = feedName

    // Set up navigation bridge
    setupNavigationBridge()
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Apply theme
    applyTheme()

    // Setup toolbar items
    setupToolbarItems()

    // Configure collection view for large title behavior
    if let collectionView = feedController.collectionView {
      // Critical: Collection view must be the first subview and aligned to top
      // This is required for large title collapse behavior to work properly
      collectionView.contentInsetAdjustmentBehavior = .automatic
      collectionView.scrollsToTop = true
    }

    // Navigation is now handled by SwiftUI NavigationStack in the hybrid approach
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    // Ensure navigation bar is configured properly
    navigationBar.prefersLargeTitles = true
    feedController.navigationItem.largeTitleDisplayMode = .automatic

    // Apply custom fonts
    NavigationFontConfig.applyFonts(to: navigationBar)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyTheme()
    }
  }

  private func setupNavigationBar() {
    // Enable large titles
    navigationBar.prefersLargeTitles = true

    // Use the global navigation bar appearance set by ThemeManager
    // instead of creating our own custom appearance that conflicts
    let globalStandardAppearance = UINavigationBar.appearance().standardAppearance
    let globalScrollEdgeAppearance =
      UINavigationBar.appearance().scrollEdgeAppearance ?? globalStandardAppearance
    let globalCompactAppearance =
      UINavigationBar.appearance().compactAppearance ?? globalStandardAppearance

    // Apply the global appearances to this specific navigation bar
    navigationBar.standardAppearance = globalStandardAppearance
    navigationBar.scrollEdgeAppearance = globalScrollEdgeAppearance
    navigationBar.compactAppearance = globalCompactAppearance
  }

  private func setupToolbarItems() {
    // Leading toolbar item - feeds drawer
    let feedsButton = UIBarButtonItem(
      image: UIImage(systemName: "circle.grid.3x3.circle"),
      style: .plain,
      target: self,

      action: #selector(openDrawer)
    )
    feedsButton.tintColor = UIColor(
      Color.dynamicText(appState.themeManager, style: .primary, currentScheme: currentColorScheme())
    )

    // Trailing toolbar item - settings avatar
    let avatarButton = UIBarButtonItem(
      image: UIImage(systemName: "person.circle"),
      style: .plain,
      target: self,
      action: #selector(openSettings)
    )
    avatarButton.tintColor = UIColor(
      Color.dynamicText(appState.themeManager, style: .primary, currentScheme: currentColorScheme())
    )

    // Set the navigation items
    feedController.navigationItem.leftBarButtonItem = feedsButton
    feedController.navigationItem.rightBarButtonItem = avatarButton
  }

  @objc private func openDrawer() {
    isDrawerOpenBinding.wrappedValue = true
  }

  @objc private func openSettings() {
    showingSettingsBinding.wrappedValue = true
  }

  private func applyTheme() {
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let effectiveScheme = appState.themeManager.effectiveColorScheme(
      for: isDarkMode ? .dark : .light)

    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this

    // Reapply navigation bar theme
    setupNavigationBar()

    // Update toolbar item colors
    setupToolbarItems()
  }

  private func currentColorScheme() -> ColorScheme {
    let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    // Use ThemeManager's effective color scheme to account for manual overrides
    return appState.themeManager.effectiveColorScheme(for: systemScheme)
  }

  // MARK: - SwiftUI Navigation Integration

  private func setupNavigationBridge() {
    // Set up monitoring of the navigation path
    lastPathCount = navigationPath.wrappedValue.count

    // Invalidate any existing timer
    navigationPathTimer?.invalidate()

    // Monitor navigation path changes
    navigationPathTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
      [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }

      let currentPathCount = self.navigationPath.wrappedValue.count

      if currentPathCount != self.lastPathCount {
        self.handleNavigationPathChange(from: self.lastPathCount, to: currentPathCount)
        self.lastPathCount = currentPathCount
      }
    }
  }

  deinit {
    // Clean up navigation path timer
    navigationPathTimer?.invalidate()
  }

  private func handleNavigationPathChange(from oldCount: Int, to newCount: Int) {
    if newCount > oldCount {
      // Navigation forward - we need to use a different approach since we can't extract individual destinations
      // Let's fall back to SwiftUI navigation when needed
      fallbackToSwiftUINavigation()
    } else if newCount < oldCount {
      // Navigation back
      let targetCount = max(1, newCount + 1)  // +1 for root controller
      if viewControllers.count > targetCount {
        let targetViewController = viewControllers[targetCount - 1]
        popToViewController(targetViewController, animated: true)
      }
    }
  }

  private func fallbackToSwiftUINavigation() {
    // When SwiftUI navigation is needed, we can present a SwiftUI navigation stack
    // This is a hybrid approach that maintains UIKit nav bar for the main feed
    // but uses SwiftUI for detailed navigation

    // For now, we'll let the navigation be handled by the post views themselves
    // which can present modally or use other navigation patterns
  }

  // Method to handle navigation back to root
  override func popToRootViewController(animated: Bool) -> [UIViewController]? {
    // Also clear the SwiftUI navigation path
    DispatchQueue.main.async {
      self.navigationPath.wrappedValue = NavigationPath()
    }
    return super.popToRootViewController(animated: animated)
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
    
    // Update posts when they change
    Task { @MainActor in
      await uiViewController.feedController.loadPostsDirectly(posts)
    }
    
    // Handle fetch type changes
    if uiViewController.feedController.fetchType.identifier != fetchType.identifier {
      uiViewController.feedController.handleFetchTypeChange(to: fetchType)
    }

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

// MARK: - UIKit Feed Wrapper Controller

/// A UIKit view controller that properly integrates with navigation hierarchy
@available(iOS 18.0, *)
final class UIKitFeedWrapperController: UIViewController {
  let feedController: FeedViewController
  private let appState: AppState

  init(appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>, modelContext: ModelContext) {
    self.appState = appState
    self.feedController = FeedViewController(appState: appState, fetchType: fetchType, path: path, modelContext: modelContext)
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
    feedController.didMove(toParent: self)

    // Set up constraints - extend under navigation bar for proper large title behavior
    feedController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      feedController.view.topAnchor.constraint(equalTo: view.topAnchor),
      feedController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      feedController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      feedController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    // Apply theme
    applyTheme()
    
    // Load content immediately like FeedView does
    Task { @MainActor in
      await loadContentImmediately()
    }
  }
  
  @MainActor
  private func loadContentImmediately() async {
    // Get or create feed model like FeedView does
    let feedModel = FeedModelContainer.shared.getModel(for: feedController.fetchType, appState: appState)
    
    // If the model already has posts, load them immediately
    if !feedModel.posts.isEmpty {
      let filteredPosts = feedModel.applyFilters(withSettings: appState.feedFilterSettings)
      await feedController.loadPostsDirectly(filteredPosts)
    } else {
      // Call the public method to trigger loading
      feedController.loadInitialFeedWithRetry()
    }
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    // Ensure proper navigation bar integration for large title behavior
    if let navigationController = navigationController {
      // Force the collection view to extend under the navigation bar
      extendedLayoutIncludesOpaqueBars = true
      
      // Make sure the feed controller's collection view has proper content inset behavior
      feedController.collectionView.contentInsetAdjustmentBehavior = .automatic
    }
  }

  private func applyTheme() {
    let currentScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let effectiveScheme = appState.themeManager.effectiveColorScheme(for: currentScheme)
    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyTheme()
    }
  }
}

// MARK: - New Posts Indicator

struct NewPostsIndicator: View {
  let authors: [AppBskyActorDefs.ProfileViewBasic]
  let onTap: () -> Void
  @Environment(AppState.self) private var appState: AppState

  private var avatarStack: some View {
    HStack(spacing: -8) {
      ForEach(Array(authors.prefix(3).enumerated()), id: \.element.did) { index, author in
        authorAvatar(author: author, index: index)
      }
    }
  }

  private func authorAvatar(author: AppBskyActorDefs.ProfileViewBasic, index: Int) -> some View {
    AsyncImage(url: author.avatar?.url) { image in
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
        .stroke(Color.white, lineWidth: 1.5)
    )
    .zIndex(Double(authors.count - index))
  }

  private var textContent: some View {
    HStack(spacing: 4) {
      Text(authors.count == 1 ? "New post" : "\(authors.count) new posts")
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)

      Image(systemName: "arrow.up")
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white)
    }
  }

  private var buttonBackground: some View {
    Capsule()
      .fill(Color.blue)
      .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 8) {
        avatarStack
        textContent
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(buttonBackground)
    }
    .buttonStyle(PlainButtonStyle())
  }
}

// MARK: - Native FeedContentView with UIViewControllerRepresentable

struct NativeFeedContentView: View {
  // MARK: - Properties
  let posts: [CachedFeedViewPost]
  let appState: AppState
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let feedType: FetchType
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  @Environment(\.modelContext) private var modelContext

  init(
    posts: [CachedFeedViewPost],
    appState: AppState,
    path: Binding<NavigationPath>,
    loadMoreAction: @escaping @Sendable () async -> Void,
    refreshAction: @escaping @Sendable () async -> Void,
    feedType: FetchType,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
  ) {
    self.posts = posts
    self.appState = appState
    self._path = path
    self.loadMoreAction = loadMoreAction
    self.refreshAction = refreshAction
    self.feedType = feedType
    self.onScrollOffsetChanged = onScrollOffsetChanged
  }

  var body: some View {
    if #available(iOS 18.0, *) {
      // Use UIViewControllerRepresentable for native NavigationStack integration
      NativeFeedViewControllerRepresentable(
        posts: posts,
        appState: appState,
        fetchType: feedType,
        path: $path,
        loadMoreAction: loadMoreAction,
        refreshAction: refreshAction,
        modelContext: modelContext,
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

// MARK: - Native UIViewControllerRepresentable

@available(iOS 18.0, *)
struct NativeFeedViewControllerRepresentable: UIViewControllerRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let modelContext: ModelContext
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  func makeUIViewController(context: Context) -> FeedViewController {
    let feedController = FeedViewController(
      appState: appState,
      fetchType: fetchType,
      path: $path,
      modelContext: modelContext
    )
    
    // Configure for SwiftUI navigation integration
    feedController.collectionView.contentInsetAdjustmentBehavior = .automatic
    feedController.collectionView.scrollsToTop = true
    
    // Set up scroll offset callback for navigation bar behavior
    feedController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Load initial posts
    Task { @MainActor in
      await feedController.loadPostsDirectly(posts)
    }
    
    return feedController
  }
  
  func updateUIViewController(_ uiViewController: FeedViewController, context: Context) {
    // Update scroll offset callback
    uiViewController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Update with new posts when they change
    Task { @MainActor in
      await uiViewController.loadPostsDirectly(posts)
    }
    
    // Handle fetch type changes
    if uiViewController.fetchType.identifier != fetchType.identifier {
      uiViewController.handleFetchTypeChange(to: fetchType)
    }
  }
}

