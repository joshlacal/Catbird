import Combine
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

// MARK: - Feed View Controller
@available(iOS 18.0, *)
final class FeedViewController: UICollectionViewController, StateInvalidationSubscriber {
  // MARK: - Properties
  private var appState: AppState
  private var feedModel: FeedModel
  private(set) var fetchType: FetchType
  private var path: Binding<NavigationPath>

  // Callback for scroll offset changes to integrate with SwiftUI navigation
  var onScrollOffsetChanged: ((CGFloat) -> Void)?

  private var posts: [CachedFeedViewPost] = []
  private var isLoading = false  // SwiftUI handles loading states
  private var hasInitialized = false
  private var isLoadingMore = false
  private var isRefreshing = false

  // Enhanced UX components
  private let userActivityTracker = UserActivityTracker()
  private lazy var smartTabCoordinator = SmartTabCoordinator(appState: appState)
  private let newPostsIndicatorManager = NewPostsIndicatorManager()
  private var cancellables = Set<AnyCancellable>()

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
    // Background will be set in configureTheme()
    collectionView.backgroundColor = .clear
    collectionView.showsVerticalScrollIndicator = true
    collectionView.prefetchDataSource = self

    // HACK: 0 top is huge, 10 is smaller(?), so using a negative inset
    collectionView.contentInset = UIEdgeInsets(top: -10, left: 0, bottom: 0, right: 0)

    // Enable automatic adjustment for navigation bars - critical for large title behavior
    collectionView.contentInsetAdjustmentBehavior = .automatic

    // Configure for better performance
    collectionView.isPrefetchingEnabled = true
    collectionView.remembersLastFocusedIndexPath = true

    // Performance: Optimize scroll view for frame-based calculations
    collectionView.delaysContentTouches = false
    collectionView.canCancelContentTouches = true
    
    // Performance: Reduce Auto Layout overhead during scrolling
    if #available(iOS 16.0, *) {
      collectionView.selfSizingInvalidation = .enabledIncludingConstraints
    }

    // Enable scroll-to-top and navigation bar integration
    collectionView.scrollsToTop = true

    // Add native pull-to-refresh
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
    collectionView.refreshControl = refreshControl
  }

  // DISABLED: SwiftUI handles loading states
  private lazy var loadingView: UIView = UIView()
  
  // DISABLED: SwiftUI handles empty states
  private lazy var emptyStateView: UIView = UIView() /*{
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .clear

      let imageView = UIImageView(image: UIImage(systemName: "wind"))
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.tintColor = UIColor.secondaryLabel
    imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)

    let titleLabel = UILabel()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "No Posts Available"
    titleLabel.textAlignment = .center
    titleLabel.font = UIFont.preferredFont(forTextStyle: .title2)
    titleLabel.textColor = UIColor.label

    let messageLabel = UILabel()
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.text = "Check back later for new content"
    messageLabel.textAlignment = .center
    messageLabel.font = UIFont.preferredFont(forTextStyle: .body)
    messageLabel.textColor = UIColor.secondaryLabel
    messageLabel.numberOfLines = 0

    let retryButton = UIButton(type: .system)
    retryButton.translatesAutoresizingMaskIntoConstraints = false
    retryButton.setTitle("Retry", for: .normal)
    retryButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    retryButton.backgroundColor = UIColor.systemBlue
    retryButton.setTitleColor(.white, for: .normal)
    retryButton.layer.cornerRadius = 8
    retryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
    retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)

    let stackView = UIStackView(arrangedSubviews: [imageView, titleLabel, messageLabel, retryButton])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 16
    stackView.alignment = .center

    container.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stackView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
      stackView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
    ])

    return container
  }() */

  // MARK: - Data Source
  enum Section: Int, CaseIterable {
    case header
    case posts
    // DISABLED: loadMoreIndicator breaks infinite scroll
    // case loadMoreIndicator
  }

  enum Item: Hashable {
    case header(FetchType)  // Feed type for conditional header
    case post(CachedFeedViewPost)
    case gapIndicator(String)  // Gap indicator with unique ID
    // DISABLED: loadMoreIndicator breaks infinite scroll
    // case loadMoreIndicator
  }

  private lazy var dataSource = createDataSource()

  // MARK: - Loading State Management
  
  @MainActor
  private func showLoadingView() {
    // DISABLED: SwiftUI layer handles all loading states
    // UIKit should never show loading view to prevent flashing
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Loading view disabled - SwiftUI handles loading states")
  }
  
  @MainActor
  private func hideLoadingView() {
    guard loadingView.superview != nil else { return }
    loadingView.removeFromSuperview()
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Loading view hidden")
  }
  
  @MainActor
  private func showEmptyStateView() {
    // DISABLED: SwiftUI layer handles all empty states
    // UIKit should never show empty state view to prevent flashing
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Empty state view disabled - SwiftUI handles empty states")
  }
  
  @MainActor
  private func hideEmptyStateView() {
    guard emptyStateView.superview != nil else { return }
    emptyStateView.removeFromSuperview()
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Empty state view hidden")
  }
  
  @objc private func retryButtonTapped() {
    // DISABLED: SwiftUI handles all data loading
    // UIKit retry should not load data independently
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Retry button disabled - SwiftUI handles loading")
  }

  // MARK: - Initialization
  init(appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>, modelContext: ModelContext) {
    self.appState = appState
    self.fetchType = fetchType
    self.path = path
    self.feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)

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
      // DISABLED: loadMoreIndicator breaks infinite scroll
      // case .loadMoreIndicator:
      //   return FeedViewController.createLoadMoreSection()
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

    // Note: We cannot call @MainActor methods from deinit
    // The UI components will be cleaned up when their hosting controllers are removed below

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
    
    // Set up new posts indicator observer
    setupNewPostsIndicatorObserver()

    // Initialize feedModel even if we're not loading initial data
    // This is needed for infinite scroll functionality
    feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Initialized feedModel for infinite scroll")

    controllerLogger.debug(
      "UIKitFeedView [\(self.instanceId)]: viewDidLoad completed, collection view frame: \(self.collectionView.frame.debugDescription)"
    )
  }

  // MARK: - Enhanced Component Setup

  private func setupEnhancedComponents() {
    // Enhanced components are now only used during pull-to-refresh
    // No background timers or automatic checking needed
    setupContinuityBannerObserver()
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
        Task { @MainActor in
          self?.handleContinuityBannerTap()
        }
      },
      onGapLoad: { [weak self] in
        Task { @MainActor in
          self?.loadGapContent()
        }
      }
    )
    .environment(appState)

    let hostingController = UIHostingController(rootView: continuityView)
    hostingController.view.backgroundColor = UIColor.clear
    
    // Enable intrinsic content size for proper SwiftUI layout
    hostingController.sizingOptions = [.intrinsicContentSize]

    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    // Position at the top of the view, below navigation bar
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])

    continuityBannerHostingController = hostingController

      controllerLogger.debug("Continuity banner system initialized - hosting controller: \(hostingController.debugDescription), view frame: \(hostingController.view.frame.debugDescription)")
  }
  
  private func setupContinuityBannerObserver() {
    // Setup the continuity banner UI integration
    setupContinuityBannerUI()
  }
  
  private func setupNewPostsIndicatorObserver() {
    // Observe changes to the new posts indicator manager's currentIndicator
    newPostsIndicatorManager.$currentIndicator
      .receive(on: DispatchQueue.main)
      .sink { [weak self] indicator in
        if let indicator = indicator {
          self?.showEnhancedNewPostsIndicator(
            newPostCount: indicator.newPostCount,
            authors: indicator.authors,
            timestamp: indicator.timestamp
          )
        } else {
          self?.hideEnhancedNewPostsIndicator()
        }
      }
      .store(in: &cancellables)
    
    controllerLogger.debug("New posts indicator observer initialized")
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
    Task { @MainActor in
      self.configureTheme()
    }

    // DISABLED: SwiftUI handles all data loading
    // UIKit should only display posts provided by SwiftUI
    if !hasInitialized {
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: First appearance - waiting for SwiftUI to provide posts"
      )
      hasInitialized = true
    }
    
    controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: UIKit view ready - posts count: \(self.posts.count)"
    )

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

      // Update collection view background - just call configureTheme which handles all theming
      // (removed duplicate theming code that's handled in configureTheme)
    }
  }

  // MARK: - Theme Configuration

  private func configureTheme() {
    let currentScheme = currentColorScheme()
    let isDarkMode = appState.themeManager.isDarkMode(for: currentScheme)
    let isBlackMode = appState.themeManager.isUsingTrueBlack

    // Update backgrounds - let SwiftUI handle view background to avoid TabView conflicts
    let backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: currentScheme))
    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this
    collectionView.backgroundColor = backgroundColor
    // Loading and empty state views disabled - SwiftUI handles these states
  }

  private func currentColorScheme() -> ColorScheme {
    let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    // Use ThemeManager's effective color scheme to account for manual overrides
    return appState.themeManager.effectiveColorScheme(for: systemScheme)
  }

  // MARK: - UI Setup
  private func setupLoadingOverlay() {
    // Add loading view as overlay and ensure it's visible immediately
    view.addSubview(loadingView)
    
    // Ensure loading view is visible on top
    loadingView.isHidden = false
    view.bringSubviewToFront(loadingView)

    loadingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      loadingView.topAnchor.constraint(equalTo: view.topAnchor),
      loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Loading overlay setup and made visible")
  }

  private func registerCells() {
    collectionView.register(FeedHeaderCell.self, forCellWithReuseIdentifier: "FeedHeaderCell")
    collectionView.register(FeedPostCell.self, forCellWithReuseIdentifier: "FeedPostCell")
    collectionView.register(FeedGapCell.self, forCellWithReuseIdentifier: "FeedGapCell")
    // DISABLED: LoadMoreIndicatorCell breaks infinite scroll
    // collectionView.register(
    //   LoadMoreIndicatorCell.self, forCellWithReuseIdentifier: "LoadMoreIndicatorCell")
  }

  // MARK: - CollectionView Layout

  // Reuse PostHeightCalculator for accurate height estimations (matching ThreadView)
  private lazy var heightCalculator = PostHeightCalculator()
  
  // Performance: Height caching to avoid recalculation during scroll
  private var heightCache: [String: CGFloat] = [:]
  private let heightCacheLimit = 500  // Limit cache size to prevent memory issues
  
  /// Calculate height with caching for better performance
  private func calculateHeightWithCache(for post: AppBskyFeedDefs.FeedViewPost, mode: PostHeightCalculator.CalculationMode = .compact) -> CGFloat {
    let cacheKey = "\(post.post.uri.description)_\(mode.rawValue)"
    
    if let cachedHeight = heightCache[cacheKey] {
      return cachedHeight
    }
    
    let calculatedHeight = heightCalculator.calculateHeight(for: post.post, mode: mode)
    
    // Cache the result but limit cache size
    if heightCache.count >= heightCacheLimit {
      // Remove oldest entries when cache is full
      let keysToRemove = Array(heightCache.keys.prefix(100))
      for key in keysToRemove {
        heightCache.removeValue(forKey: key)
      }
    }
    
    heightCache[cacheKey] = calculatedHeight
    return calculatedHeight
  }

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
        
        // Performance: Enable rasterization for static header content
        cell.layer.shouldRasterize = true
        cell.layer.rasterizationScale = UIScreen.main.scale
        
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
        
        // Performance: Selective rasterization for post cells
        // Only rasterize for static content to improve scrolling
        if cachedPost.feedViewPost.post.embed == nil {
          // Posts without media can be safely rasterized
          cell.layer.shouldRasterize = true
          cell.layer.rasterizationScale = UIScreen.main.scale
        } else {
          // Posts with media should not be rasterized to avoid memory issues
          cell.layer.shouldRasterize = false
        }
        
        return cell

      case .gapIndicator(let gapId):
        self.controllerLogger.debug(
          "UIKitFeedView [\(self.self.instanceId)]: Creating gap indicator cell for section \(indexPath.section), item \(indexPath.item), gapID: \(gapId)"
        )
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "FeedGapCell", for: indexPath)
          as! FeedGapCell
        cell.configure(gapId: gapId)
        
        // Performance: Enable rasterization for gap indicator cells (static content)
        cell.layer.shouldRasterize = true
        cell.layer.rasterizationScale = UIScreen.main.scale
        
        return cell

      // DISABLED: loadMoreIndicator breaks infinite scroll
      // case .loadMoreIndicator:
      //   self.controllerLogger.debug(
      //     "UIKitFeedView [\(self.self.instanceId)]: Creating load more cell for section \(indexPath.section), item \(indexPath.item)"
      //   )
      //   let cell =
      //     collectionView.dequeueReusableCell(
      //       withReuseIdentifier: "LoadMoreIndicatorCell", for: indexPath) as! LoadMoreIndicatorCell
      //   cell.configure(isLoading: self.isLoadingMore)
      //   return cell
      }
    }

    return dataSource
  }

  // MARK: - Feed Loading Logic

  func loadInitialFeedWithRetry() {
    // DISABLED: SwiftUI handles all data loading
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: loadInitialFeedWithRetry disabled - SwiftUI handles loading")
  }

  private func loadInitialFeed() {
    Task(priority: .userInitiated) { @MainActor in
      controllerLogger.debug(
        "UIKitFeedView [\(self.instanceId)]: Starting initial feed load for: \(self.fetchType.identifier)"
      )

      // Get or create feed model - this works even without authentication
      feedModel = FeedModelContainer.shared.getModel(for: fetchType, appState: appState)
      let model = feedModel

      // DISABLED: SwiftUI handles loading states
      // isLoading = true
      // showLoadingView()

      // First, try to load cached data for immediate display
      if let cachedPosts = smartRefreshCoordinator.loadCachedData(for: fetchType.identifier),
         !cachedPosts.isEmpty {
        controllerLogger.debug(
          "UIKitFeedView [\(self.instanceId)]: Loaded \(cachedPosts.count) cached posts immediately"
        )
        
        await updateDataWithPositionPreservation(cachedPosts, insertAt: .replace)
        await restorePersistedScrollPosition(posts: cachedPosts)
        
        hideLoadingView()
        isLoading = false
        
        // Check if we should refresh in background
        let shouldRefresh = persistentStateManager.shouldRefreshFeed(
          feedIdentifier: fetchType.identifier,
          lastUserRefresh: nil,
          appBecameActiveTime: nil
        )
        
        if shouldRefresh {
          // Refresh in background without disrupting UI
          Task { [weak self, fetchType, cachedPosts, persistentStateManager, appState] in
            guard let self = self else { return }
            await self.feedModel.loadFeedWithFiltering(
              fetch: fetchType,
              forceRefresh: true,
              strategy: .fullRefresh,
              filterSettings: appState.feedFilterSettings
            )
            
            let updatedPosts = self.feedModel.applyFilters(withSettings: appState.feedFilterSettings)
            if updatedPosts.count != cachedPosts.count {
              // Save the updated data
              persistentStateManager.saveFeedData(updatedPosts, for: fetchType.identifier)
              
              // Check for new content
              if let firstCachedId = cachedPosts.first?.id,
                 let firstUpdatedId = updatedPosts.first?.id,
                 firstCachedId != firstUpdatedId {
                let newCount = updatedPosts.firstIndex { $0.id == firstCachedId } ?? 0
                if newCount > 0 {
                  // Get authors from new posts for capsule indicator
                  let newAuthors = Array(updatedPosts.prefix(newCount))
                    .compactMap { $0.feedViewPost.post.author }
                    .uniqued(by: \.did)
                  
                  if !newAuthors.isEmpty {
                      self.showNewPostsIndicator(authors: newAuthors, forceShow: true)
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
            "UIKitFeedView [\(self.instanceId)]: Loading \(model.posts.count) p?osts from FeedModel"
        )
        let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
        await updateDataWithPositionPreservation(filteredPosts, insertAt: .replace)
        
        loadingView.removeFromSuperview()
        isLoading = false
      } else {
        // Perform fresh load if we have authentication
        if appState.atProtoClient != nil {
          do {
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
            
            lastRefreshTime = Date()
            controllerLogger.debug(
              "UIKitFeedView [\(self.instanceId)]: Initial load completed with \(filteredPosts.count) posts"
            )
          } catch {
            controllerLogger.error(
              "UIKitFeedView [\(self.instanceId)]: Failed to load feed: \(error.localizedDescription)"
            )
            // Show error state instead of infinite loading
            await showErrorState(error: error)
          }
          
          // Always remove loading view, whether success or error
          hideLoadingView()
          isLoading = false
        } else {
          // No authentication yet - hide loading and wait
          hideLoadingView()
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
  
  @MainActor
  private func showErrorState(error: Error) async {
    controllerLogger.error("UIKitFeedView [\(self.instanceId)]: Showing error state for: \(error.localizedDescription)")
    await updateDataWithPositionPreservation([], insertAt: .replace)
    
    // Hide loading state and show empty state - updateDataWithPositionPreservation will handle this
    isLoading = false
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
    guard !isRefreshing, !isLoading, feedModel != nil else { return }
      let model = feedModel

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

    // Check for new content and show continuity banner if appropriate
    if hasNewPosts {
      let newPostsCount = max(1, newPosts.count - originalPostsCount)
      continuityManager.checkForNewContent(
        currentPosts: newPosts,
        feedIdentifier: fetchType.identifier,
        onNewContentFound: { [weak self] count in
          Task { @MainActor in
            // Show continuity banner for in-feed gaps
            self?.continuityManager.showNewContentBanner(count: count) {
              Task { @MainActor in
                self?.handleContinuityBannerTap()
              }
            }
            self?.controllerLogger.debug("Continuity banner triggered for \(count) new posts")
          }
        }
      )
      
      // Update continuity info
      continuityManager.updateContinuityInfo(
        for: fetchType.identifier,
        posts: newPosts,
        hasNewContent: true
      )
    }

    // Show indicator if we have new posts, regardless of scroll position
    if hasNewPosts {
      // Calculate actual new posts count, ensuring it's at least 1
      let actualNewPostsCount = max(1, newPosts.count - originalPostsCount)
      
      // Get authors from new posts, avoiding empty arrays
      let newAuthors: [AppBskyActorDefs.ProfileViewBasic]
      if newPosts.count > originalPostsCount {
        // We have actual new posts - get authors from the new ones
        newAuthors = Array(newPosts.prefix(actualNewPostsCount))
          .compactMap { $0.feedViewPost.post.author }
          .uniqued(by: \.did) // Remove duplicate authors
      } else {
        // Post IDs changed but count is same - get author from first post
        if let firstAuthor = newPosts.first?.feedViewPost.post.author {
          newAuthors = [firstAuthor]
        } else {
          newAuthors = []
        }
      }

      if !newAuthors.isEmpty {
        controllerLogger.debug(
          "Showing new posts indicator: \(actualNewPostsCount) posts from \(newAuthors.count) unique authors"
        )
        
        // Show legacy indicator, forcing it to appear after a pull-to-refresh
        showNewPostsIndicator(authors: newAuthors, forceShow: true)
      } else {
        controllerLogger.debug("No authors found for new posts indicator")
      }
    }

    if let anchor = scrollAnchor {
      // We have a scroll anchor - use position preservation
      controllerLogger.debug("Using scroll anchor for position preservation")
      await updateDataWithNewPostsAtTop(
        newPosts, originalAnchor: anchor, hasNewPosts: hasNewPosts)
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
    controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: loadPostsDirectly called with \(posts.count) posts")
    
    // Quick check: if posts are identical to current posts, skip update entirely
    let currentPosts = self.posts
    let currentPostsNotEmpty = !currentPosts.isEmpty
    let postCountMatches = posts.count == currentPosts.count
    let postsAreEqual = posts.elementsEqual(currentPosts, by: { post1, post2 in
      let idsMatch = post1.id == post2.id
        let timestampsMatch = post1.cachedAt == post2.cachedAt
      return idsMatch && timestampsMatch
    })
    let postsUnchanged = currentPostsNotEmpty && postCountMatches && postsAreEqual
    
    if postsUnchanged {
      controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Posts unchanged - skipping update")
      return
    }
    
    // Determine the appropriate insert mode by comparing with existing posts
    let insertMode: InsertPosition
    let shouldTriggerContinuity: Bool
    
    if currentPosts.isEmpty {
      // First load - use replace mode
      insertMode = .replace
      shouldTriggerContinuity = false
      controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: First load - using replace mode")
    } else {
      // Check if we have new posts at the top
      let existingIds = Set(currentPosts.map { $0.id })
      let newPostsAtTop = posts.prefix(while: { !existingIds.contains($0.id) })
      
      if !newPostsAtTop.isEmpty {
        // New posts detected at top - use top insertion with scroll preservation
        insertMode = .top
        shouldTriggerContinuity = true
        controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: \(newPostsAtTop.count) new posts detected - using top insertion mode")
        
        // Show capsule indicator for new posts
        if newPostsAtTop.count > 0 {
          let newAuthors = newPostsAtTop
            .compactMap { $0.feedViewPost.post.author }
            .uniqued(by: \.did)
          
          if !newAuthors.isEmpty {
            showNewPostsIndicator(authors: newAuthors, forceShow: true)
          }
        }
      } else {
        // No new posts at top - check if this is a refresh/update
        let countChanged = posts.count != currentPosts.count
        let idsChanged = !posts.elementsEqual(currentPosts, by: { $0.id == $1.id })
        let hasSignificantChanges = countChanged || idsChanged
        
        if hasSignificantChanges {
          insertMode = .replace
          shouldTriggerContinuity = false
          controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Significant changes detected - using replace mode")
        } else {
          // Posts are essentially the same - minimal update
          insertMode = .replace
          shouldTriggerContinuity = false
          controllerLogger.debug("UIKitFeedView [\(self.instanceId)]: Minimal changes - using replace mode")
        }
      }
    }
    
    await updateDataWithPositionPreservation(posts, insertAt: insertMode)
    
    // Update continuity info after successful update
    if shouldTriggerContinuity {
      continuityManager.updateContinuityInfo(
        for: fetchType.identifier,
        posts: posts,
        hasNewContent: true
      )
    } else {
      continuityManager.updateContinuityInfo(
        for: fetchType.identifier,
        posts: posts,
        hasNewContent: false
      )
    }
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

    // Debounce rapid updates to prevent scroll position jumps, but skip for initial loads
    let shouldDebounce = !posts.isEmpty && now.timeIntervalSince(lastUpdateTime) < updateDebounceInterval
    if shouldDebounce {
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
    controllerLogger.debug("🔥 FEED UPDATE [\(self.instanceId)]: Added \(postItems.count) post items to snapshot")

    // DISABLED: Load more indicator interferes with infinite scroll
    // Infinite scroll is handled by scroll detection in scrollViewDidScroll
    // controllerLogger.debug("🔥 FEED UPDATE [\(self.instanceId)]: Infinite scroll via scroll detection")

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

    // DISABLED: SwiftUI layer handles all loading/empty states
    // UIKit layer should only display the collection view content
    hideLoadingView()
    hideEmptyStateView()

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
    
    // Update continuity info for this feed
    continuityManager.updateContinuityInfo(
      for: fetchType.identifier,
      posts: posts,
      hasNewContent: false
    )
    
    // After data update, check for gaps and insert gap indicators if needed
    Task {
      await detectAndInsertGaps()
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

    // Pre-calculate heights for better position estimates (with caching)
    for post in newPosts.prefix(min(10, newPosts.count)) {
      _ = calculateHeightWithCache(for: post.feedViewPost, mode: .compact)
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

    // DISABLED: Load more indicator interferes with infinite scroll
    // controllerLogger.debug("🔥 FEED UPDATE: Infinite scroll via scroll detection")

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
    guard !isRefreshing, !isLoading, feedModel != nil else { return }
      let model = feedModel

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
    guard !isLoadingMore, !isLoading, !isRefreshing, feedModel != nil else {
      controllerLogger.debug(
        "Load more blocked: isLoadingMore=\(self.isLoadingMore), isLoading=\(self.isLoading), isRefreshing=\(self.isRefreshing), hasModel=\(self.feedModel != nil)"
      )
      return
    }
      let model = feedModel

    controllerLogger.debug("Starting load more...")

    isLoadingMore = true
    // DISABLED: updateLoadMoreIndicator() - no longer using load more button

    // Load more posts
    await model.loadMoreWithFiltering(filterSettings: appState.feedFilterSettings)

    // Update posts - append to bottom, not replace
    let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
    controllerLogger.debug("Load more completed: loaded \(filteredPosts.count) total posts")

    await updateDataWithPositionPreservation(filteredPosts, insertAt: .bottom)

    isLoadingMore = false
    // DISABLED: updateLoadMoreIndicator() - no longer using load more button
  }

  @MainActor
  private func performGapLoad(gapId: String) async {
    guard feedModel != nil else {
      controllerLogger.debug("Gap load blocked: no feed model available")
      return
    }
      let model = feedModel

    controllerLogger.debug("Starting targeted gap load for gapId: \(gapId)")
    
    // Extract the post ID from the gap ID
    let postId = gapId.replacingOccurrences(of: "gap_after_", with: "")
    
    // Find the post and its position to determine what range to load
    guard let gapPostIndex = posts.firstIndex(where: { $0.id == postId }) else {
      controllerLogger.warning("Could not find gap post for ID: \(postId)")
      return
    }
    
    // Store current scroll position for this specific gap
    let scrollAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)
    
    // Determine the cursor range for this gap
    // This would ideally use the specific cursor from the post at gapPostIndex
    let gapCursor = getGapCursor(for: gapPostIndex)
    
    controllerLogger.debug("Loading gap with cursor: \(gapCursor ?? "none") at index: \(gapPostIndex)")
    
    // TODO: Implement targeted loading with specific cursor
    // For now, do a more targeted refresh that tries to fill this specific gap
    if let cursor = gapCursor {
      await loadSpecificGapRange(model: model, cursor: cursor, gapIndex: gapPostIndex)
    } else {
      // Fallback to full refresh if we can't determine the cursor
      await model.loadFeedWithFiltering(
        fetch: fetchType,
        forceRefresh: true,
        strategy: .fullRefresh,
        filterSettings: appState.feedFilterSettings
      )
    }

    // Update posts with position preservation at the gap location
    let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
    controllerLogger.debug("Gap load completed: loaded \(filteredPosts.count) total posts")

    // Insert new content while preserving scroll position
    if let anchor = scrollAnchor {
      await updateDataWithNewPostsAtGap(filteredPosts, originalAnchor: anchor, gapIndex: gapPostIndex)
    } else {
      await updateDataWithPositionPreservation(filteredPosts, insertAt: .replace)
    }
    
    // Recalculate gaps after loading
    await detectAndInsertGaps()
  }
  
  private func getGapCursor(for postIndex: Int) -> String? {
    // IMPORTANT: Cursors are opaque and must come from AT Protocol responses
    // We cannot generate them from timestamps or URIs
    
    guard postIndex < posts.count else { return nil }
    
    let post = posts[postIndex]
    
    // In a proper implementation, cursors would be stored with each post
    // from the original AT Protocol response. For now, we don't have access
    // to the original pagination cursors, so we can't do targeted loading.
    
    controllerLogger.debug("Cannot generate cursor for gap after post \(post.id) - cursors must come from AT Protocol API")
    
    // Return nil to indicate we should fall back to full refresh
    return nil
  }
  
  private func loadSpecificGapRange(model: FeedModel, cursor: String, gapIndex: Int) async {
    // This method would need FeedManager support for cursor-based range loading
    // Something like: await model.loadPostsAfterCursor(cursor, limit: 20)
    
    controllerLogger.debug("Targeted gap loading not yet implemented - falling back to full refresh")
    
    // For now, use full refresh since we don't have cursor-based range loading
    await model.loadFeedWithFiltering(
      fetch: fetchType,
      forceRefresh: true,
      strategy: .fullRefresh,
      filterSettings: appState.feedFilterSettings
    )
  }
  
  @MainActor
  private func updateDataWithNewPostsAtGap(
    _ newPosts: [CachedFeedViewPost],
    originalAnchor: ScrollPositionTracker.ScrollAnchor,
    gapIndex: Int
  ) async {
    controllerLogger.debug("Updating data with new posts at gap index: \(gapIndex)")
    
    // This is where we'd intelligently merge the new posts at the gap location
    // while preserving scroll position
    
    // For now, fall back to the existing position preservation logic
    await updateDataWithNewPostsAtTop(newPosts, originalAnchor: originalAnchor, hasNewPosts: true)
  }

  @MainActor
  private func detectAndInsertGaps() async {
    // Detect gaps based on feed continuity, not time
    let detectedGaps = detectFeedSequenceGaps()
    
    controllerLogger.debug("Detected \(detectedGaps.count) sequence gaps in feed")
    
    // If we have gaps, update the data source to include gap indicators
    if !detectedGaps.isEmpty {
      await insertGapIndicators(at: detectedGaps)
    }
  }
  
  private func detectFeedSequenceGaps() -> [String] {
    // Only detect gaps for chronological feeds
    guard shouldDetectGaps(for: self.fetchType) else {
      controllerLogger.debug("Gap detection disabled for feed type: \(self.fetchType.identifier)")
      return []
    }
    
    guard posts.count > 1 else { return [] }
    
    var gaps: [String] = []
    
    // Use continuity manager to detect sequence breaks
    // This is the proper way - let the continuity system determine gaps
    if let continuityInfo = persistentStateManager.loadFeedContinuityInfo(for: fetchType.identifier) {
      
      // Main gap detection: missing content at the top
      if let lastKnownTopId = continuityInfo.lastKnownTopPostId {
        
        // Find where our last known content appears in the current feed
        if let knownPostIndex = posts.firstIndex(where: { $0.id == lastKnownTopId }) {
          
          // If the last known post is deep in our current feed (not near top),
          // there's likely missing content between the top and this known post
          if knownPostIndex >= 3 { // Conservative threshold
            gaps.append(posts[min(1, posts.count - 1)].id) // Gap after second post
            controllerLogger.debug("Gap detected: last known post '\(lastKnownTopId)' found at index \(knownPostIndex), indicating missing top content")
          }
        } else if !posts.isEmpty {
          // Last known post not found at all - might be a gap or very old content
          // Only create gap if continuity system specifically detected one
          if continuityInfo.gapDetected {
            gaps.append(posts[0].id) // Gap after first post
            controllerLogger.debug("Gap detected: last known post '\(lastKnownTopId)' not found and continuity system flagged gap")
          }
        }
      }
    }
    
    return gaps
  }
  
  private func shouldDetectGaps(for fetchType: FetchType) -> Bool {
    // Only enable gap detection for chronological feeds
    switch fetchType {
    case .timeline:
      return true // Following timeline is chronological
    case .list(_):
      // Custom lists might be chronological, but we can't be sure
      // Conservative approach: disable for now
      return false
    case .feed(_):
      // Custom feeds could be chronological or algorithmic
      // Conservative approach: disable unless we know it's chronological
      return false
    case .author(_):
      return true // Author posts are chronological
    case .likes(_):
      return true // Liked posts are chronological
    }
  }
  
  @MainActor
  private func insertGapIndicators(at gapPostIds: [String]) async {
    // Create a new snapshot with gap indicators inserted
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections(Section.allCases)

    // Add header with feed type only if it should be shown
    if shouldShowHeaderForCurrentFeed() {
      snapshot.appendItems([.header(fetchType)], toSection: .header)
    }

    // Build posts section with gap indicators
    var postsWithGaps: [Item] = []
    
    for (index, post) in posts.enumerated() {
      // Add the post
      postsWithGaps.append(.post(post))
      
      // Check if we need to add a gap indicator after this post
      if gapPostIds.contains(post.id) && index < posts.count - 1 {
        let gapId = "gap_after_\(post.id)"
        postsWithGaps.append(.gapIndicator(gapId))
        controllerLogger.debug("Inserted gap indicator after post: \(post.id)")
      }
    }
    
    snapshot.appendItems(postsWithGaps, toSection: .posts)

    // DISABLED: Load more indicator interferes with infinite scroll
    // controllerLogger.debug("🔥 FEED UPDATE: Infinite scroll via scroll detection")

    // Apply the snapshot
    await dataSource.apply(snapshot, animatingDifferences: true)
    
    controllerLogger.debug("Applied snapshot with \(gapPostIds.count) gap indicators")
  }

  // Refresh indicator is now handled by UIRefreshControl - no longer needed

  // DISABLED: loadMoreIndicator breaks infinite scroll
  // private func updateLoadMoreIndicator() {
  //   var snapshot = dataSource.snapshot()
  //   if snapshot.itemIdentifiers(inSection: .loadMoreIndicator).contains(.loadMoreIndicator) {
  //     snapshot.reconfigureItems([.loadMoreIndicator])
  //     dataSource.apply(snapshot, animatingDifferences: false)
  //   }
  // }

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

    // Reset state - SwiftUI handles loading states
    // isLoading = true
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

      DispatchQueue.main.async {
        let topInset = self.collectionView.adjustedContentInset.top

        UIView.animate(
          withDuration: 0.3, delay: 0, options: [.curveEaseInOut],
          animations: {
            // Scroll to top with content insets considered, using the stored value
            self.collectionView.setContentOffset(
              CGPoint(x: 0, y: -topInset), animated: false)
          })
      }
    }
    
    
  // MARK: - New Posts Indicator

  @MainActor
  private func showNewPostsIndicator(authors: [AppBskyActorDefs.ProfileViewBasic], forceShow: Bool = false) {
    // Simplified check - forceShow overrides all conditions
    guard !authors.isEmpty else {
      controllerLogger.debug("Not showing indicator - no authors provided")
      return
    }
    
    // If forceShow is true (like after pull-to-refresh), skip all other checks
    if !forceShow {
      // Log the current scroll position and activity state for debugging
      let scrollOffset = collectionView.contentOffset.y
      let distanceFromTop = scrollOffset + collectionView.adjustedContentInset.top
      controllerLogger.debug("Checking indicator visibility - scrollOffset: \(scrollOffset), distanceFromTop: \(distanceFromTop)")
      
      guard userActivityTracker.shouldShowNewContentIndicator(
        scrollView: collectionView,
        distanceFromTop: 100,  // Further reduced from 150 to 100pts for better visibility
        minimumIdleTime: 0.5   // Reduced from 1.0 to 0.5 seconds for quicker response
      ) else {
        controllerLogger.debug("Not showing indicator - user activity check failed (distance: \(distanceFromTop), required: 100)")
        return
      }
    } else {
      controllerLogger.debug("Force showing indicator after pull-to-refresh")
    }

    controllerLogger.debug("Creating enhanced new posts indicator with \(authors.count) authors")
    newPostsAuthors = authors

    // Use capsule-style indicator with avatar stack
    showSimpleNewPostsIndicator(authors: authors)
    
    // Also update the indicator manager for consistency
    newPostsIndicatorManager.showNewPostsIndicator(
      newPostCount: authors.count,
      authors: authors,
      feedType: fetchType,
      userActivity: userActivityTracker,
      scrollView: collectionView,
      forceShow: forceShow
    )
    
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
      Task { @MainActor in
        hostingController.view.removeFromSuperview()
        hostingController.removeFromParent()
      }
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
    
    // Enable intrinsic content size for proper SwiftUI layout
    hostingController.sizingOptions = [.intrinsicContentSize]

    // Add to view hierarchy
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)
    
    // Ensure it appears above the collection view
    view.bringSubviewToFront(hostingController.view)

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

  /// Display simple capsule-style new posts indicator
  @MainActor
  private func showSimpleNewPostsIndicator(authors: [AppBskyActorDefs.ProfileViewBasic]) {
    // Remove any existing indicator
    hideNewPostsIndicator()

    let indicatorView = NewPostsIndicator(
      authors: authors,
      onTap: { [weak self] in
        Task { @MainActor in
          self?.handleNewPostsIndicatorTap()
        }
      }
    )
    .environment(appState)

    let hostingController = UIHostingController(rootView: indicatorView)
    hostingController.view.backgroundColor = .clear
    
    // Enable intrinsic content size for proper SwiftUI layout
    hostingController.sizingOptions = [.intrinsicContentSize]

    // Add to view hierarchy
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)
    
    // Ensure it appears above the collection view
    view.bringSubviewToFront(hostingController.view)

    // Configure constraints
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hostingController.view.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
    ])

    // Store reference
    newPostsIndicatorHostingController = hostingController

    controllerLogger.info(
      "Simple capsule indicator displayed for \(authors.count) authors")
  }

  // MARK: - Continuity Banner Methods

  private func setupContinuityBannerUI() {
    // Delegate to the main setup method
    // This method exists for compatibility but just calls the main setup
    // No need for duplicate implementation
    controllerLogger.debug("setupContinuityBannerUI called - delegating to setupContinuityBanner")
  }

  @MainActor
  private func handleContinuityBannerTap() {
    // Hide the banner
    continuityManager.hideBanner()
    
    // Scroll to top to show new content
    scrollToTop()
    
    controllerLogger.debug("Continuity banner tapped - scrolling to top")
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
      // Check if this is a gap indicator or regular post
      guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
      
      switch item {
      case .gapIndicator(let gapId):
        Task {
          await performGapLoad(gapId: gapId)
        }
      case .post, .header: // DISABLED: .loadMoreIndicator
        // Post tapped - handled by the post cell itself
        break
      }
    // DISABLED: loadMoreIndicator breaks infinite scroll
    // case .loadMoreIndicator:
    //   Task {
    //     await performLoadMore()
    //   }
    }
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Performance: Use frame-based calculations instead of heavy Auto Layout operations
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
