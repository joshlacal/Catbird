//
//  FeedCollectionViewControllerIntegrated.swift
//  Catbird
//
//  High-performance UIKit feed controller with SwiftUI cell hosting
//

import AppIntents
import Petrel
import SwiftUI
import os

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

#if os(iOS)
  /// Opt-in aggregate counters used by controlled feed update measurements.
  struct FeedCollectionUpdateDiagnostics {
    var updateRequests = 0
    var snapshotConstructions = 0
    var snapshotApplications = 0
    var skippedSnapshots = 0
    var postConfigurations = 0
    var trendingConfigurations = 0
    var reconfiguredItems = 0
  }

  /// UIKit snapshot application is asynchronous and does not stop when its
  /// caller is cancelled. Drain publications behind one apply, using the newest
  /// state for the next pass instead of overlapping collection mutations.
  @MainActor
  final class FeedSnapshotUpdateScheduler {
    private var task: Task<Void, Never>?
    private var needsUpdate = false
    private(set) var requestCount = 0

    func perform(_ apply: @escaping @MainActor () async -> Void) async {
      requestCount += 1
      needsUpdate = true
      if let task {
        await task.value
        return
      }
      let task = Task { @MainActor in
        defer { self.task = nil }
        while self.needsUpdate && !Task.isCancelled {
          self.needsUpdate = false
          await apply()
        }
      }
      self.task = task
      await task.value
    }

    /// Discard queued publications. UIKit still owns the in-flight apply; a
    /// request arriving afterward must be allowed to drain behind its completion.
    func cancel() {
      needsUpdate = false
    }
  }

  /// Thread-safe row height cache keyed by post ID + width + font generation + content size category + content signature (P068 / feed-perf step 1)
  final class FeedRowHeightCache {
    struct Key: Hashable {
      let postID: String
      let width: Int
      let fontGeneration: Int
      let contentSizeCategory: UIContentSizeCategory
      let contentSignature: FeedPostContentSignature
    }
    private let capacity: Int = 1000
    private var cache: [Key: CGFloat] = [:]
    private var postIDsToKeys: [String: Set<Key>] = [:]
    private var keyAccessTimes: [Key: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    func height(for postID: String, width: Int, fontGeneration: Int, contentSizeCategory: UIContentSizeCategory, contentSignature: FeedPostContentSignature) -> CGFloat? {
      let key = Key(postID: postID, width: width, fontGeneration: fontGeneration, contentSizeCategory: contentSizeCategory, contentSignature: contentSignature)
      guard let height = cache[key] else { return nil }
      accessCounter &+= 1
      keyAccessTimes[key] = accessCounter
      return height
    }

    func store(height: CGFloat, for postID: String, width: Int, fontGeneration: Int, contentSizeCategory: UIContentSizeCategory, contentSignature: FeedPostContentSignature) {
      guard height > 0 else { return }
      let key = Key(postID: postID, width: width, fontGeneration: fontGeneration, contentSizeCategory: contentSizeCategory, contentSignature: contentSignature)
      accessCounter &+= 1
      keyAccessTimes[key] = accessCounter
      cache[key] = height
      postIDsToKeys[postID, default: []].insert(key)
      if cache.count > capacity {
        evictOldest()
      }
    }

    private func evictOldest() {
      let sortedKeys = keyAccessTimes.sorted { $0.value < $1.value }
      let toRemove = max(1, sortedKeys.count - (capacity * 9 / 10))
      for (key, _) in sortedKeys.prefix(toRemove) {
        cache.removeValue(forKey: key)
        keyAccessTimes.removeValue(forKey: key)
        postIDsToKeys[key.postID]?.remove(key)
        if postIDsToKeys[key.postID]?.isEmpty == true {
          postIDsToKeys.removeValue(forKey: key.postID)
        }
      }
    }

    func invalidate(postID: String) {
      if let keys = postIDsToKeys.removeValue(forKey: postID) {
        for key in keys {
          cache.removeValue(forKey: key)
          keyAccessTimes.removeValue(forKey: key)
        }
      }
    }

    func removeAll() {
      cache.removeAll(keepingCapacity: true)
      postIDsToKeys.removeAll(keepingCapacity: true)
      keyAccessTimes.removeAll(keepingCapacity: true)
    }
  }

  /// Custom list cell that intercepts self-sizing to return cached heights directly (P068 / feed-perf step 1)
  final class FeedPostCollectionViewCell: UICollectionViewListCell {
    var postID: String?
    var fontGeneration: Int = 0
    var contentSizeCategory: UIContentSizeCategory = .unspecified
    var contentSignature: FeedPostContentSignature?
    weak var heightCache: FeedRowHeightCache?
    var isFreshlyConfigured: Bool = false
    /// Set once the row toggles per-cell UI state (reveals, translation, gates). That state
    /// resets when the cell is reused, so heights measured with it must never be cached.
    private var hasTransientLayoutState = false

    func markConfigured() {
      isFreshlyConfigured = true
      hasTransientLayoutState = false
    }

    func markHeightNeedsRecalculation() {
      isFreshlyConfigured = false
      hasTransientLayoutState = true
      if let postID {
        heightCache?.invalidate(postID: postID)
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      postID = nil
      contentSignature = nil
      isFreshlyConfigured = false
      hasTransientLayoutState = false
    }

    override func preferredLayoutAttributesFitting(
      _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
      let width = Int(layoutAttributes.size.width)
      // Serve a cached height only for the first measurement after configuration. Every later
      // self-sizing pass is a real fit: the hosted SwiftUI content may have changed size since
      // (async text styling, reveals, link hydration), and masking that pass with a cached value
      // leaves the row at a stale height, which shows as blank gaps or rows drawing over each other.
      if isFreshlyConfigured {
        isFreshlyConfigured = false
        if let postID, let contentSignature, width > 0,
           let cached = heightCache?.height(
             for: postID,
             width: width,
             fontGeneration: fontGeneration,
             contentSizeCategory: contentSizeCategory,
             contentSignature: contentSignature
           ) {
          let attrs = layoutAttributes
          attrs.size.height = cached
          return attrs
        }
      }

      let attrs = super.preferredLayoutAttributesFitting(layoutAttributes)
      if let postID {
        if hasTransientLayoutState {
          heightCache?.invalidate(postID: postID)
        } else if let contentSignature, width > 0 {
          heightCache?.store(
            height: attrs.size.height,
            for: postID,
            width: width,
            fontGeneration: fontGeneration,
            contentSizeCategory: contentSizeCategory,
            contentSignature: contentSignature
          )
        }
      }
      return attrs
    }
  }
  @available(iOS 16.0, *)
  final class FeedCollectionViewControllerIntegrated: UIViewController {
    // MARK: - Types

    private enum Section: Int, CaseIterable { case main }
    private enum Item: Hashable {
      case header
      case trendingInterstitial
      case post(account: String, feed: String, id: String)
      case footer
    }

    // MARK: - Properties

    private(set) var updateDiagnostics: FeedCollectionUpdateDiagnostics?

    func enableUpdateDiagnostics() {
      updateDiagnostics = FeedCollectionUpdateDiagnostics()
    }

    var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    #if !targetEnvironment(macCatalyst)
      private var refreshControl: UIRefreshControl!
    #endif

    /// State management
    var stateManager: FeedStateManager
    private var sceneContext: SceneNavigationContext
    private(set) var viewportState: FeedViewportState
    private let viewportOwnerID = UUID()

    /// Navigation
    private let navigationPath: Binding<NavigationPath>

    /// Load more coordination
    var loadMoreTask: Task<Void, Never>?
    private var isLoadMoreRequestInFlight = false
    private var lastLoadMoreTriggerPostID: String?
    private var lastLoadMoreTriggerTimestamp: TimeInterval = .zero
    private var recentlySeenPostTimestamps: [String: TimeInterval] = [:]
    private let loadMorePrefetchThreshold = 5
    private let loadMoreTriggerDedupInterval: TimeInterval = 0.35
    private let seenTrackingDedupInterval: TimeInterval = 0.75

    /// Update serialization - prevents concurrent performUpdate calls
    private let updateScheduler = FeedSnapshotUpdateScheduler()

    /// Initial load serialization - de-dupes overlapping loadInitialData calls
    /// (viewWillAppear, account-switch observer, updateStateManager can race)
    private var initialLoadTask: Task<Void, Never>?

    /// State observation with proper @Observable integration
    var stateObserver: UIKitStateObserver<FeedStateManager>?

    /// Theme manager observation
    var themeObserver: UIKitStateObserver<ThemeManager>?
    /// AppState observation for account switch boundaries
    var appStateObserver: UIKitStateObserver<AppState>?
    var feedbackObserver: UIKitStateObserver<FeedStateManager>?
    /// Observer for tab tap to scroll to top
    var tabTapObserver: UIKitStateObserver<SceneNavigationContext>?

    /// Callbacks
    private let onScrollOffsetChanged: ((CGFloat) -> Void)?

    /// Refresh state tracking
    private var isRefreshing = false

    /// App lifecycle tracking
    private var isAppInBackground = false
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// Logging
    let controllerLogger = Logger(subsystem: "blue.catbird", category: "FeedCollectionIntegrated")

    /// Optional SwiftUI header that should scroll with the feed
    private var headerView: AnyView?
    /// Track header presence to avoid rebuilding during scroll updates
    private var headerPresent: Bool = false
    /// Background hosting controller for loading/empty states
    private var backgroundHostingController: UIHostingController<AnyView>?

    /// Apply a full reload on the next snapshot (set when feed switches)
    private var shouldReloadDataOnce = false
    private var shouldReconfigureAllOnce = false
    /// O(1) post lookup used during cell configuration
    private var postsByID: [String: CachedFeedViewPost] = [:]
    /// O(1) index lookup used during willDisplay / triggerLoadMore (P064)
    private var postIndicesByID: [String: Int] = [:]
    /// Measured row height cache
    private let rowHeightCache = FeedRowHeightCache()
    private var lastLayoutWidth: CGFloat = 0
    /// FirstFeedContent signpost interval state
    private var firstFeedContentSignpostState: OSSignpostIntervalState?
    /// Track fling velocity and throttle row building during fast flings (feed-perf step 3)
    private var trendingContent = TrendingFeedContent()
    private var appliedTrendingContent = TrendingFeedContent()
    private var appliedFooterState: FeedPaginationFooterState?
    private var appliedPostSignatures: [String: FeedPostContentSignature] = [:]
    private var prefetchTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var viewportInteractionGeneration = 0
    private var feedGeneration = 0
    private var appliedSnapshotGeneration: Int?
    private let scrollRestoration: FeedViewportRestoration
    /// Native UIKit rows for the posts they support (`NativeFeedRowSupport`).
    private let nativeRows: NativeFeedRowCoordinator
    #if DEBUG
    private var lastLayoutGeometry: FeedLayoutGeometry?
    #endif

    func setTrendingContent(_ content: TrendingFeedContent) {
      guard content != trendingContent else { return }
      trendingContent = content
      guard dataSource != nil else { return }
      Task { @MainActor [weak self] in await self?.performUpdate() }
    }
    
    // MARK: - Initialization

    init(
      stateManager: FeedStateManager,
      viewportState: FeedViewportState,
      sceneContext: SceneNavigationContext,
      navigationPath: Binding<NavigationPath>,
      onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    ) {
      self.stateManager = stateManager
      self.sceneContext = sceneContext
      self.viewportState = viewportState
      self.navigationPath = navigationPath
      self.onScrollOffsetChanged = onScrollOffsetChanged
      self.scrollRestoration = FeedViewportRestoration(anchor: viewportState.getScrollAnchor()?.viewportAnchor)
      self.firstFeedContentSignpostState = PerformanceSignposts.beginInterval("FirstFeedContent")
      self.nativeRows = NativeFeedRowCoordinator(
        navigationPath: navigationPath, appState: stateManager.appState, sceneContext: sceneContext)

      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    /// Rebind hosted roots and observation if SwiftUI retains the controller.
    func updateSceneContext(_ context: SceneNavigationContext) {
      guard sceneContext !== context else { return }
      tabTapObserver?.stopObserving()
      sceneContext = context
      guard isViewLoaded else { return }
      setupTabTapObserver()
      reloadAllCells()
      updateBackgroundState()
    }

    // MARK: - Theme Support

    private func setupThemeObserver() {
      // Observe ThemeManager's @Observable properties directly (P218: drop duplicate notification observer)
      themeObserver = UIKitStateObserver(observing: stateManager.appState.themeManager) {
        [weak self] _ in
        self?.handleThemeChange()
      }
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleFontChangeNotification),
        name: NSNotification.Name("FontChanged"),
        object: nil
      )
    }

    @objc private func handleFontChangeNotification() {
      rowHeightCache.removeAll()
      nativeRows.invalidateLayouts()
      forceCellReconfiguration()
    }

    private func handleThemeChange() {
      updateThemeColors()
      forceCellReconfiguration()
      updateBackgroundState()
    }

    func updateThemeColors() {
      // Let SwiftUI's .themedPrimaryBackground() provide the background.
      // Keeping UIKit views transparent prevents stale colors when the system toggles appearance (e.g., sunrise schedule).
      collectionView?.backgroundColor = .clear
      view.backgroundColor = .clear

      // Avoid resetting the layout here to prevent supplementary assertions during transitions
    }

    /// The window size embeds size their media against. Supplying it through the environment
    /// spares every link card a `WindowViewportReader` and the re-render once it reports.
    private var embedViewportSize: CGSize? {
      guard let size = view.window?.bounds.size, size.width > 0, size.height > 0 else { return nil }
      return size
    }

    private func forceCellReconfiguration() {
      guard dataSource != nil else { return }
      shouldReconfigureAllOnce = true
      Task { @MainActor [weak self] in await self?.performUpdate() }
    }

    private func reloadAllCells() {
      guard dataSource != nil else { return }
      shouldReloadDataOnce = true
      Task { @MainActor [weak self] in await self?.performUpdate() }
    }

    private func setupFeedbackObserver() {
      var previousTarget = stateManager.feedInteractionTarget
      feedbackObserver = UIKitStateObserver(
        observing: stateManager,
        tracking: { _ = $0.feedInteractionTarget }
      ) { [weak self] manager in
        let currentTarget = manager.feedInteractionTarget
        guard currentTarget != previousTarget else { return }
        previousTarget = currentTarget
        self?.handleFeedFeedbackChange()
      }
    }

    private func handleFeedFeedbackChange() {
      // When this feed starts or stops accepting feedback, reconfigure rather than reloadData (P075)
      forceCellReconfiguration()
      updateBackgroundState()
    }

    // Observe account-switch transitions to invalidate cell configurations once
    private func setupAccountSwitchObserver() {
      var previous = stateManager.appState.isTransitioningAccounts
      appStateObserver = UIKitStateObserver(observing: stateManager.appState) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          let now = self.stateManager.appState.isTransitioningAccounts
          // Trigger a one-time hard reload when the transition completes
          if previous && !now {
            self.shouldReloadDataOnce = true
            // If posts are empty (likely because load was skipped during transition), load them now
            if self.stateManager.posts.isEmpty {
              self.controllerLogger.debug("🔄 Account transition complete, loading initial data")
              await self.loadInitialData()
            } else {
              await self.performUpdate()
            }
          }
          previous = now
        }
      }
    }
    
    // Observe tab tap to scroll to top and refresh
    private func setupTabTapObserver() {
      tabTapObserver = UIKitStateObserver(observing: sceneContext) { [weak self] _ in
        guard let self else { return }
        if self.sceneContext.tabTappedAgain == 0 {
          self.controllerLogger.debug("🏠 Home tab tapped again - scrolling to top and refreshing")
          self.sceneContext.tabTappedAgain = nil
          self.scrollToTopAndRefresh()
        }
      }
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
      super.viewDidLoad()

      updateThemeColors()
      setupCollectionView()
      setupNativeRows()
      setupDataSource()
      setupRefreshControl()
      // Apply header if it was set before the view loaded
      setHeaderView(self.headerView)
      setupObservers()
      setupScrollToTopCallback()
      setupAppLifecycleObservers()
      setupThemeObserver()
      setupFeedbackObserver()
      setupAccountSwitchObserver()
      setupTabTapObserver()
      updateBackgroundState()
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      setupScrollToTopCallback()

      // Update theme colors when view appears to catch any missed theme changes
      updateThemeColors()
      sceneContext.urlHandler.registerTopViewController(self)

      Task { @MainActor in
        if stateManager.posts.isEmpty {
          controllerLogger.debug("📥 Loading initial data for empty feed")
          await loadInitialData()
        } else {
          controllerLogger.debug("📄 Feed already has \\(self.stateManager.posts.count) posts")
          await performUpdate()
        }
      }
    }

    override func viewWillDisappear(_ animated: Bool) {
      // Capture before navigation changes the outgoing view's effective insets.
      captureCurrentScrollPosition()
      viewportState.unregisterScrollToTopHandler(ownerID: viewportOwnerID)
      super.viewWillDisappear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      restoreScrollPositionIfReady()
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      if let collectionView = collectionView {
        let currentWidth = collectionView.bounds.width
        if lastLayoutWidth > 0 && abs(lastLayoutWidth - currentWidth) > 0.5 {
          rowHeightCache.removeAll()
        }
        lastLayoutWidth = currentWidth
        if let bgView = collectionView.backgroundView {
          bgView.frame = collectionView.bounds
        }
      }
      restoreScrollPositionIfReady()
      #if DEBUG
      if FeedLayoutGeometry.isTracingEnabled, let collectionView, dataSource != nil {
        let geometry = FeedLayoutGeometry.capture(in: collectionView, postIDAt: postIDAt)
        if geometry != lastLayoutGeometry {
          lastLayoutGeometry = geometry
          controllerLogger.debug("Feed layout geometry: \(String(describing: geometry), privacy: .public)")
        }
      }
      #endif
    }


    isolated deinit {
      viewportState.unregisterScrollToTopHandler(ownerID: viewportOwnerID)
      cancelPendingLoadMoreRequest()
      prefetchTasks.values.forEach { $0.task.cancel() }
      prefetchTasks.removeAll()
      updateScheduler.cancel()
      initialLoadTask?.cancel()

      if let backgroundObserver = backgroundObserver {
        NotificationCenter.default.removeObserver(backgroundObserver)
      }
      if let foregroundObserver = foregroundObserver {
        NotificationCenter.default.removeObserver(foregroundObserver)
      }

      NotificationCenter.default.removeObserver(self)
      controllerLogger.debug("🧹 FeedCollectionViewControllerIntegrated deinitialized")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      #if os(iOS)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
          rowHeightCache.removeAll()
          nativeRows.invalidateLayouts()
          forceCellReconfiguration()
        }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
          // System appearance changed; update dynamic backgrounds to reflect dim/black correctly
          updateThemeColors()
          forceCellReconfiguration()
        }
      #endif
    }

    override func didReceiveMemoryWarning() {
      super.didReceiveMemoryWarning()
      rowHeightCache.removeAll()
    }
    // MARK: - Collection View Setup

    private func setupCollectionView() {
      let layout = createLayout()

      collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
      collectionView.translatesAutoresizingMaskIntoConstraints = false
      // Keep transparent and defer background to SwiftUI themed wrapper
      collectionView.backgroundColor = .clear
      collectionView.delegate = self
      collectionView.prefetchDataSource = self

      // Remove all margins and insets
      collectionView.layoutMargins = .zero
      collectionView.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
      collectionView.contentInset = .zero

      // Configure behavior
      collectionView.contentInsetAdjustmentBehavior = .automatic
      collectionView.alwaysBounceVertical = true
      collectionView.keyboardDismissMode = .onDrag
      collectionView.showsVerticalScrollIndicator = true
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
      }
      #endif

      // Performance optimizations
      collectionView.isPrefetchingEnabled = true

      view.addSubview(collectionView)

      // Use Auto Layout constraints
      NSLayoutConstraint.activate([
        collectionView.topAnchor.constraint(equalTo: view.topAnchor),
        collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      
      // Fix 5: scrollsToTop
      // Ensure this is the primary scroll view for status bar tapping
      collectionView.scrollsToTop = true
    }

    private func createLayout() -> UICollectionViewLayout {
      var configuration = UICollectionLayoutListConfiguration(appearance: .plain)

      // Keep list configuration transparent so SwiftUI can own the background
      configuration.backgroundColor = .clear
      configuration.showsSeparators = false  // Disable UIKit separators - let SwiftUI handle them

      // We render header as a first cell (not supplementary) to avoid provider assertions
      configuration.headerMode = .none
      configuration.footerMode = .none

      // Configure swipe actions for feed feedback
      configuration.leadingSwipeActionsConfigurationProvider = nil
      configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
        guard let self = self else { return nil }

        // Only show swipe actions for post items (not header)
        guard case .post = self.dataSource?.itemIdentifier(for: indexPath) else {
          return nil
        }

        // Only feeds whose generator accepts feedback offer these actions
        guard let target = self.stateManager.feedInteractionTarget else {
          return nil
        }

        // Resolve the row's own post; header and interstitial rows shift item indexes.
        guard case .post(_, _, let postID) = self.dataSource?.itemIdentifier(for: indexPath),
          let post = self.postsByID[postID]
        else { return nil }

        // Create Show More action
        let showMoreAction = UIContextualAction(style: .normal, title: nil) {
          [weak self] action, view, completion in
          guard let self = self else {
            completion(false)
            return
          }

          if let item = try? post.feedViewPost {
            let postURI = item.post.uri
            self.stateManager.appState.feedFeedbackManager.sendShowMore(
              postURI: postURI, target: target, feedContext: item.feedContext, reqId: item.reqId)
            self.controllerLogger.debug("Sent 'show more' feedback for post: \(postURI)")

            // Show confirmation toast
            self.stateManager.appState.toastManager.show(
              ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
              )
            )
          }

          completion(true)
        }
        showMoreAction.backgroundColor = .systemGreen
        showMoreAction.image = UIImage(systemName: "hand.thumbsup.fill")
        showMoreAction.accessibilityLabel = "Show More Like This"

        // Create Show Less action
        let showLessAction = UIContextualAction(style: .normal, title: nil) {
          [weak self] action, view, completion in
          guard let self = self else {
            completion(false)
            return
          }

          if let item = try? post.feedViewPost {
            let postURI = item.post.uri
            self.stateManager.appState.feedFeedbackManager.sendShowLess(
              postURI: postURI, target: target, feedContext: item.feedContext, reqId: item.reqId)
            self.controllerLogger.debug("Sent 'show less' feedback for post: \(postURI)")

            // Show confirmation toast
            self.stateManager.appState.toastManager.show(
              ToastItem(
                message: "Feedback sent",
                icon: "checkmark.circle.fill"
              )
            )
          }

          completion(true)
        }
        showLessAction.backgroundColor = .systemRed
        showLessAction.image = UIImage(systemName: "hand.thumbsdown.fill")
        showLessAction.accessibilityLabel = "Show Less Like This"

        let configuration = UISwipeActionsConfiguration(actions: [showLessAction, showMoreAction])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
      }

      let layout = UICollectionViewCompositionalLayout.list(using: configuration)

      return layout
    }

    private func setupDataSource() {
      // Registration for post cells
      let postRegistration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, String> {
        [weak self] cell, indexPath, postId in
        let signpostId = PerformanceSignposts.beginCellConfiguration(postId: postId)
        defer { PerformanceSignposts.endCellConfiguration(id: signpostId) }
        
        guard let self = self,
          let post = self.postsByID[postId]
        else {
          cell.postID = nil
          cell.isFreshlyConfigured = false
          cell.contentConfiguration = nil
          return
        }

        self.updateDiagnostics?.postConfigurations += 1

        // Reset cell margins
        cell.layoutMargins = .zero
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero

        // Remove selection background
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.selectedBackgroundView = nil

        // Set up cell properties for row height caching
        cell.heightCache = self.rowHeightCache
        let appState = self.stateManager.appState
        cell.fontGeneration = appState.fontManager.generation
        cell.contentSizeCategory = self.traitCollection.preferredContentSizeCategory

        // The view model's signature reflects the post being configured; appliedPostSignatures
        // still holds the previous snapshot's values while a reconfigure is being applied.
        let viewModel = self.stateManager.viewModel(for: post)
        cell.postID = postId
        cell.contentSignature = viewModel.contentSignature
        cell.markConfigured()

        // Configure cell with UIHostingConfiguration and inject required environment.
        // The identity must include the post: a reused cell otherwise keeps the previous post's
        // SwiftUI state (reveals, blur, translation, measured sizes) for its first layout pass,
        // and that pass is the one that gets measured and cached.
        let accountID = appState.userDID ?? "unknown-account"
        let feedID = self.stateManager.currentFeedType.identifier
        let hostingIdentity = "\(accountID)-\(feedID)-\(postId)"
        let viewportSize = self.embedViewportSize
        cell.contentConfiguration = UIHostingConfiguration {
          FeedPostRow(
            viewModel: viewModel,
            navigationPath: self.navigationPath,
            feedTypeIdentifier: self.stateManager.currentFeedType.identifier,
            tracksVisibilityForFeedback: false,
            onHeightInvalidated: { [weak self, weak cell] in
              self?.rowHeightCache.invalidate(postID: postId)
              cell?.markHeightNeedsRecalculation()
            }
          )
          .trackingModerationPolicy(of: appState)
          .applyAppStateEnvironment(appState)
          .environment(self.sceneContext)
          .environment(\.fontManager, appState.fontManager)
          .environment(\.feedInteractionTarget, self.stateManager.feedInteractionTarget)
          .environment(\.containerViewportSize, viewportSize)
          .id(hostingIdentity)
          .padding(0)
          .background(Color.clear)
        }
        .margins(.all, 0)

        // Annotate the cell so Siri's 'View AppIntents Payload' walk can collect
        // onscreen PostEntity references. SwiftUI modifiers inside
        // UIHostingConfiguration are NOT collected; UIKit cell annotation is required.
#if compiler(>=6.4)
        if #available(anyAppleOS 26.0, *) {
          if let entityURI = AppEntityAnnotationIdentifiers.postURI(for: post) {
            cell.appEntityIdentifier = EntityIdentifier(
              for: PostEntity.self, identifier: entityURI)
          } else {
            cell.appEntityIdentifier = nil
          }
        }
#endif

        // Remove cell state handler to reduce memory overhead
        cell.configurationUpdateHandler = nil
      }
      // Registration for posts the native cell supports
      let nativePostRegistration = UICollectionView.CellRegistration<NativeFeedPostCell, NativeFeedRowCoordinator.Row> {
        [weak self] cell, _, row in
        self?.configureNativeCell(cell, row: row)
      }
      // Registration for header cell
      let headerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Void> {
        [weak self] cell, indexPath, _ in
        guard let self = self, let header = self.headerView else {
          cell.contentConfiguration = nil
          return
        }
        // Ensure full-width content and no default list/background drawing
        cell.layoutMargins = .zero
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.selectedBackgroundView = nil

        cell.contentConfiguration = UIHostingConfiguration {
          header
            .trackingModerationPolicy(of: self.stateManager.appState)
            .applyAppStateEnvironment(self.stateManager.appState)
            .environment(\.fontManager, self.stateManager.appState.fontManager)
            .environment(self.sceneContext)
        }
          .margins(.all, 0)
      }
      // Registration for trending interstitial cell
      let trendingInterstitialRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Void> {
        [weak self] cell, indexPath, _ in
        guard let self = self else {
          cell.contentConfiguration = nil
          return
        }
        self.updateDiagnostics?.trendingConfigurations += 1
        let appState = self.stateManager.appState
        cell.layoutMargins = .zero
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.selectedBackgroundView = nil

        cell.contentConfiguration = UIHostingConfiguration {
          TrendingFeedInterstitialView(content: self.trendingContent)
            .trackingModerationPolicy(of: appState)
            .applyAppStateEnvironment(appState)
            .environment(\.fontManager, appState.fontManager)
          .environment(self.sceneContext)
        }
        .margins(.all, 0)
      }

      // Registration for the pagination footer
      let footerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Void> {
        [weak self] cell, indexPath, _ in
        guard let self = self else {
          cell.contentConfiguration = nil
          return
        }
        let appState = self.stateManager.appState
        cell.layoutMargins = .zero
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.selectedBackgroundView = nil

        let state = self.currentFooterState
        cell.contentConfiguration = UIHostingConfiguration {
          FeedPaginationFooterView(state: state) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
              await self.stateManager.loadMore()
            }
          }
          .applyAppStateEnvironment(appState)
          .environment(\.fontManager, appState.fontManager)
        }
        .margins(.all, 0)
      }

      dataSource = UICollectionViewDiffableDataSource<Section, Item>(
        collectionView: collectionView
      ) { [weak self] collectionView, indexPath, item in
        switch item {
        case .header:
          return collectionView.dequeueConfiguredReusableCell(
            using: headerRegistration, for: indexPath, item: ())
        case .trendingInterstitial:
          return collectionView.dequeueConfiguredReusableCell(
            using: trendingInterstitialRegistration, for: indexPath, item: ())
        case .post(_, _, let id):
          if let row = self?.nativeRows.nativeRow(forPostID: id) {
            self?.nativeRows.recordDequeue(postID: id, native: true)
            return collectionView.dequeueConfiguredReusableCell(
              using: nativePostRegistration, for: indexPath, item: row)
          }
          self?.nativeRows.recordDequeue(postID: id, native: false)
          return collectionView.dequeueConfiguredReusableCell(
            using: postRegistration, for: indexPath, item: id)
        case .footer:
          return collectionView.dequeueConfiguredReusableCell(
            using: footerRegistration, for: indexPath, item: ())
        }
      }
      // Defensive: provide a no-op supplementary provider to satisfy any unexpected requests
      let emptyHeaderReg = UICollectionView.SupplementaryRegistration<UICollectionReusableView>(
        elementKind: UICollectionView.elementKindSectionHeader
      ) { _, _, _ in }
      let emptyFooterReg = UICollectionView.SupplementaryRegistration<UICollectionReusableView>(
        elementKind: UICollectionView.elementKindSectionFooter
      ) { _, _, _ in }
      dataSource.supplementaryViewProvider = { [weak collectionView] _, kind, indexPath in
        guard let collectionView = collectionView else { return nil }
        switch kind {
        case UICollectionView.elementKindSectionHeader:
          return collectionView.dequeueConfiguredReusableSupplementary(
            using: emptyHeaderReg, for: indexPath)
        case UICollectionView.elementKindSectionFooter:
          return collectionView.dequeueConfiguredReusableSupplementary(
            using: emptyFooterReg, for: indexPath)
        default:
          return nil
        }
      }
    }

    private func setupRefreshControl() {
      // UIRefreshControl is not supported on Mac Catalyst
      #if !targetEnvironment(macCatalyst)
        refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
      #endif
    }

    @objc private func handleRefresh() {
      guard !isRefreshing else { return }
      isRefreshing = true
      let generation = feedGeneration
      let manager = stateManager
      let accountID = manager.appState.userDID
      Task { @MainActor in
        // Only the owning refresh may end the indicator, after its final snapshot.
        // Loading-state publications also call performUpdate while the fetch awaits.
        defer {
          if generation == feedGeneration, manager === stateManager {
            #if !targetEnvironment(macCatalyst)
              refreshControl.endRefreshing()
            #endif
            isRefreshing = false
          }
        }
        guard !Task.isCancelled, generation == feedGeneration, manager === stateManager,
          manager.appState.userDID == accountID, !manager.appState.isAccountSwitchSuspended else { return }
        controllerLogger.debug("🔄 Fast refresh triggered")

        // User-initiated refresh should override background flag
        // This ensures pull-to-refresh works even if background flag is stuck
        await manager.refreshUserInitiated(displayScale: self.traitCollection.displayScale)
        guard !Task.isCancelled, generation == feedGeneration, manager === stateManager,
          manager.appState.userDID == accountID, !manager.appState.isAccountSwitchSuspended else { return }
        if case .error = manager.loadingState, !manager.posts.isEmpty {
          manager.appState.toastManager.show(
            ToastItem(
              message: "Couldn’t refresh. Check your connection and try again.",
              icon: "wifi.exclamationmark"
            )
          )
        }
        await performUpdate()
      }
    }

    // MARK: - State Management

    @MainActor
    func performUpdate() async {
      updateDiagnostics?.updateRequests += 1
      await updateScheduler.perform { [weak self] in
        await self?.applyCurrentState()
      }
    }

    private func applyCurrentState() async {
      guard !isAppInBackground, let dataSource, let collectionView else { return }
      let generation = feedGeneration
      let manager = stateManager

      if case .error(let error) = manager.loadingState {
        controllerLogger.error("Feed update error: \(error.localizedDescription)")
        // A failed supplemental request can still have accepted cached rows to display.
      }

      let capturedPosts = manager.posts
      let capturedPostsByID = Dictionary(
        capturedPosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let capturedSignatures = capturedPostsByID.mapValues(FeedPostContentSignature.init)
      nativeRows.update(
        appState: manager.appState, sceneContext: sceneContext, feedInteractionTarget: manager.feedInteractionTarget)
      nativeRows.beginSnapshot(
        posts: capturedPostsByID, signatures: capturedSignatures, traits: collectionView.traitCollection)
      let capturedTrendingContent = trendingContent
      let capturedFooterState = currentFooterState
      let capturedHeaderPresent = FeedDiscoveryHeaderVisibility.shouldShowHeader(
        headerIsPresent: headerView != nil, postCount: capturedPosts.count)
      let accountID = manager.appState.userDID ?? "unknown-account"
      let feedID = manager.currentFeedType.identifier
      let isEligibleFeed = manager.currentFeedType == .timeline
        || feedID.contains("discover") || feedID == "timeline"

      var items: [Item] = capturedHeaderPresent ? [.header] : []
      for (index, post) in capturedPosts.enumerated() {
        if !capturedTrendingContent.isEmpty && isEligibleFeed
          && capturedPosts.count >= 7 && index == 6 {
          items.append(.trendingInterstitial)
        }
        items.append(.post(account: accountID, feed: feedID, id: post.id))
      }
      if !capturedPosts.isEmpty {
        items.append(.footer)
      }

      let currentItems = dataSource.snapshot().itemIdentifiers
      let existingItems = Set(currentItems)
      let reconfiguredItems = items.filter { item in
        guard existingItems.contains(item) else { return false }
        if shouldReconfigureAllOnce { return true }
        switch item {
        case .post(_, _, let id):
          let changed = appliedPostSignatures[id] != capturedSignatures[id]
          if changed {
            rowHeightCache.invalidate(postID: id)
          }
          let requestedByNativeRow = nativeRows.takeReconfigureRequest(postID: id)
          return changed || requestedByNativeRow
        case .trendingInterstitial:
          return appliedTrendingContent != capturedTrendingContent
        case .footer:
          return appliedFooterState != capturedFooterState
        case .header:
          return false
        }
      }
      postsByID = capturedPostsByID
      postIndicesByID = Dictionary(
        capturedPosts.enumerated().map { ($1.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      guard shouldReloadDataOnce || currentItems != items || !reconfiguredItems.isEmpty else {
        updateDiagnostics?.skippedSnapshots += 1
        restoreScrollPositionIfReady()
        updateBackgroundState()
        return
      }

      updateDiagnostics?.snapshotConstructions += 1
      // A reconfigure must dequeue the cell kind the item already has; items moving between the
      // native and the hosted row are reloaded.
      let reloadedItems = Set(reconfiguredItems.filter { item in
        guard case .post(_, _, let id) = item else { return false }
        return nativeRows.cellKindChanges(postID: id)
      })
      nativeRows.didApplySnapshot()
      prepareNativeLayouts(near: capturedPosts)
      var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
      snapshot.appendSections([.main])
      snapshot.appendItems(items, toSection: .main)

      let offsetBefore = collectionView.contentOffset.y
      let heightBefore = collectionView.contentSize.height
      let interactionGeneration = viewportInteractionGeneration
      let readingAnchor = FeedViewportAnchor.capture(in: collectionView, postIDAt: postIDAt)
      let shouldPreserveReadingAnchor = !scrollRestoration.isPending
        && !collectionView.isTracking && !collectionView.isDragging && !collectionView.isDecelerating
      let signpost = PerformanceSignposts.beginFeedSnapshot(
        itemCount: items.count, reconfiguredCount: reconfiguredItems.count)
      var anchorDeltaBeforeRestore: Double?
      var anchorDeltaAfterRestore: Double?
      defer {
        PerformanceSignposts.endFeedSnapshot(id: signpost,
          offsetDelta: Double(collectionView.contentOffset.y - offsetBefore),
          heightDelta: Double(collectionView.contentSize.height - heightBefore),
          anchorDeltaBeforeRestore: anchorDeltaBeforeRestore,
          anchorDeltaAfterRestore: anchorDeltaAfterRestore)
      }

      updateDiagnostics?.snapshotApplications += 1
      shouldReconfigureAllOnce = false
      if shouldReloadDataOnce {
        shouldReloadDataOnce = false
        await dataSource.applySnapshotUsingReloadData(snapshot)
      } else {
        updateDiagnostics?.reconfiguredItems += reconfiguredItems.count
        snapshot.reconfigureItems(reconfiguredItems.filter { !reloadedItems.contains($0) })
        snapshot.reloadItems(Array(reloadedItems))
        await dataSource.apply(snapshot, animatingDifferences: false)
      }
      if let state = firstFeedContentSignpostState, !capturedPosts.isEmpty {
        PerformanceSignposts.endInterval("FirstFeedContent", state)
        firstFeedContentSignpostState = nil
      }
      guard !Task.isCancelled, generation == feedGeneration, manager === stateManager else { return }

      appliedPostSignatures = capturedSignatures
      appliedTrendingContent = capturedTrendingContent
      appliedFooterState = capturedFooterState
      appliedSnapshotGeneration = generation
      collectionView.layoutIfNeeded()
      if let readingAnchor,
        let indexPath = dataSource.indexPath(for: .post(
          account: accountID, feed: feedID, id: readingAnchor.postID)),
        let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
        anchorDeltaBeforeRestore = Double(attributes.frame.minY - collectionView.contentOffset.y
          - collectionView.adjustedContentInset.top - readingAnchor.viewportY)
        if shouldPreserveReadingAnchor && !readingAnchor.isAtTop
          && interactionGeneration == viewportInteractionGeneration
          && !collectionView.isTracking && !collectionView.isDragging && !collectionView.isDecelerating {
          readingAnchor.restore(in: collectionView, indexPath: indexPath)
        }
      }
      restoreScrollPositionIfReady()
      if let readingAnchor,
        let indexPath = dataSource.indexPath(for: .post(
          account: accountID, feed: feedID, id: readingAnchor.postID)),
        let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
        anchorDeltaAfterRestore = Double(attributes.frame.minY - collectionView.contentOffset.y
          - collectionView.adjustedContentInset.top - readingAnchor.viewportY)
      }
      updateBackgroundState()
    }

    @MainActor
    func loadInitialData() async {
      if let existing = initialLoadTask {
        controllerLogger.debug("⏭️ Initial load already in flight, awaiting existing task")
        await existing.value
        return
      }

      let generation = feedGeneration
      let manager = stateManager
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          if self.feedGeneration == generation { self.initialLoadTask = nil }
        }
        self.controllerLogger.debug("📥 Loading initial data")
        await manager.loadInitialData()
        guard !Task.isCancelled, self.feedGeneration == generation, self.stateManager === manager else { return }
        await self.performUpdate()
      }
      initialLoadTask = task
      await task.value
    }

    // MARK: - Header API
    func setHeaderView(_ view: AnyView?) {
      let newPresent = (view != nil)
      // If presence didn't change, do nothing to avoid thrashing during scroll
      if newPresent == headerPresent {
        self.headerView = view
        return
      }
      self.headerView = view
      self.headerPresent = newPresent
      guard dataSource != nil else { return }
      Task { @MainActor in await performUpdate() }
    }

    // MARK: - Observers

    private func setupObservers() {
      stateObserver = UIKitStateObserver(observing: stateManager) { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.performUpdate()
        }
        self?.updateBackgroundState()
      }
    }

    private func setupScrollToTopCallback() {
      // Commands belong to this scene's viewport, even when feed data is shared.
      viewportState.registerScrollToTopHandler(ownerID: viewportOwnerID) { [weak self] in
        self?.scrollToTopAnimated()
      }
    }

    /// Scrolls to the absolute top of the collection view (animated)
    private func scrollToTopAnimated() {
      guard let collectionView = collectionView else { return }

      scrollRestoration.cancel()
      viewportInteractionGeneration += 1
      let minOffsetY = -collectionView.adjustedContentInset.top
      let minOffsetX = -collectionView.adjustedContentInset.left

      controllerLogger.debug("🔝 Scrolling to top (animated) to y=\(minOffsetY)")
      collectionView.setContentOffset(CGPoint(x: minOffsetX, y: minOffsetY), animated: true)
    }
    
    /// Scrolls to top and refreshes to get the latest posts
    /// This is the behavior when the user taps the home tab while already on the home tab
    func scrollToTopAndRefresh() {
      guard let collectionView = collectionView else { return }
      scrollRestoration.cancel()
      
      // Only refresh when we're truly already at the top.
      let topOffset = -collectionView.adjustedContentInset.top
      let isAtTop = collectionView.contentOffset.y <= topOffset + 1.0
      
      controllerLogger.debug("🔝 Home tab tapped - isAtTop: \(isAtTop), currentOffset: \(collectionView.contentOffset.y), topOffset: \(topOffset)")
      
      if isAtTop {
        // Already at top - refresh to get new posts
        controllerLogger.debug("🔝 Already at top - refreshing feed")
        Task { @MainActor in
          await stateManager.refreshUserInitiated(displayScale: self.traitCollection.displayScale)
        }
      } else {
        // Not at top - just scroll to top (no refresh)
        controllerLogger.debug("🔝 Not at top - scrolling to top")
        scrollToTopAnimated()
      }
    }
    
    /// Scrolls to the absolute top of the content (no animation, no protection)
    private func scrollToAbsoluteTop() {
      guard let collectionView = collectionView else { return }
      
      // Force layout to ensure contentSize is accurate
      collectionView.layoutIfNeeded()
      
      let minOffsetY = -collectionView.adjustedContentInset.top
      let minOffsetX = -collectionView.adjustedContentInset.left
        controllerLogger.debug("🔝 Scrolling to absolute top: (\(minOffsetX), \(minOffsetY)), contentSize: \(collectionView.contentSize.debugDescription)")
      collectionView.setContentOffset(CGPoint(x: minOffsetX, y: minOffsetY), animated: false)
    }

    private func scrollToTop() {
      // Fix 1: Scroll to Offset, Not the Item
      // Relying on scrollToItem is unreliable with dynamic layouts.
      scrollToTopAnimated()
    }

    // MARK: - Scroll Position Management

    /// Captures this scene's position without mutating the shared feed manager.
    private func captureCurrentScrollPosition() {
      guard let collectionView = collectionView else { return }
      #if os(iOS)
        viewportState.captureScrollAnchor(from: collectionView, postIDAt: postIDAt)
      #endif
    }

    private func postIDAt(_ indexPath: IndexPath) -> String? {
      guard case .post(_, _, let id) = dataSource?.itemIdentifier(for: indexPath) else { return nil }
      return id
    }

    private func restoreScrollPositionIfReady() {
      guard scrollRestoration.isPending, let collectionView, let dataSource,
        let appliedSnapshotGeneration else { return }
      let snapshot = dataSource.snapshot()
      let postItems = snapshot.itemIdentifiers.compactMap { item -> (String, Item)? in
        if case .post(_, _, let id) = item { return (id, item) }
        return nil
      }
      scrollRestoration.restoreIfReady(in: collectionView,
        postCount: postItems.count, isLoading: stateManager.isLoading,
        snapshotGeneration: appliedSnapshotGeneration) { id in
          postItems.first(where: { $0.0 == id }).flatMap { dataSource.indexPath(for: $0.1) }
        }
    }

    private func cancelPendingLoadMoreRequest() {
      loadMoreTask?.cancel()
      loadMoreTask = nil
      isLoadMoreRequestInFlight = false
    }
    
    private func resetTriggerDedupState() {
      lastLoadMoreTriggerPostID = nil
      lastLoadMoreTriggerTimestamp = .zero
      recentlySeenPostTimestamps.removeAll(keepingCapacity: true)
    }

    private func postIndexForRow(at indexPath: IndexPath) -> Int? {
      guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
      switch item {
      case .post(_, _, let id):
        return postIndicesByID[id]
      default:
        return nil
      }
    }
    
    private func trackPostSeenIfNeeded(at indexPath: IndexPath) {
      guard stateManager.feedInteractionTarget != nil else { return } // P209: Skip on feeds without feedback target
      guard let item = dataSource.itemIdentifier(for: indexPath),
            case .post(_, _, let id) = item,
            let post = postsByID[id] else { return }
      
      let now = Date().timeIntervalSinceReferenceDate
      if let lastSeenTimestamp = recentlySeenPostTimestamps[id],
         now - lastSeenTimestamp < seenTrackingDedupInterval
      {
        return
      }
      
      recentlySeenPostTimestamps[id] = now
      if recentlySeenPostTimestamps.count > 200 {
        let cutoff = now - seenTrackingDedupInterval * 2
        recentlySeenPostTimestamps = recentlySeenPostTimestamps.filter { $0.value >= cutoff }
      }
      
      if let item = try? post.feedViewPost {
        stateManager.appState.feedFeedbackManager.trackPostSeen(
          postURI: item.post.uri, target: stateManager.feedInteractionTarget,
          feedContext: item.feedContext, reqId: item.reqId)
      }
    }
    
    private func triggerLoadMoreIfNeeded(at indexPath: IndexPath) {
      // Reaching the footer while more pages exist means an earlier page
      // request finished without filling the screen; ask for the next one.
      if case .footer = dataSource.itemIdentifier(for: indexPath) {
        guard currentFooterState == .loading, !isLoadMoreRequestInFlight else { return }
        isLoadMoreRequestInFlight = true
        loadMoreTask = Task { @MainActor [weak self] in
          guard let self else { return }
          defer {
            self.loadMoreTask = nil
            self.isLoadMoreRequestInFlight = false
          }
          guard !self.stateManager.posts.isEmpty, !self.isAppInBackground else { return }
          await self.stateManager.loadMore()
        }
        return
      }
      guard let postIndex = postIndexForRow(at: indexPath) else { return }
      let totalItems = stateManager.posts.count
      guard totalItems > .zero else { return }
      
      let triggerIndex = max(.zero, totalItems - loadMorePrefetchThreshold)
      guard postIndex >= triggerIndex else { return }
      guard !isLoadMoreRequestInFlight else { return }
      
      let triggerPostID = stateManager.posts[postIndex].id
      let now = Date().timeIntervalSinceReferenceDate
      if triggerPostID == lastLoadMoreTriggerPostID,
         now - lastLoadMoreTriggerTimestamp < loadMoreTriggerDedupInterval
      {
        return
      }
      
      lastLoadMoreTriggerPostID = triggerPostID
      lastLoadMoreTriggerTimestamp = now
      
      isLoadMoreRequestInFlight = true
      
      loadMoreTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          self.loadMoreTask = nil
          self.isLoadMoreRequestInFlight = false
        }
        
        guard !self.stateManager.posts.isEmpty, !self.isAppInBackground else { return }
        await self.stateManager.loadMore()
      }
    }

    // MARK: - App Lifecycle

    private func setupAppLifecycleObservers() {
      #if !targetEnvironment(macCatalyst)
        backgroundObserver = NotificationCenter.default.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.handleAppDidEnterBackground()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
          forName: UIApplication.willEnterForegroundNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.handleAppWillEnterForeground()
        }
      #endif
    }

    private func handleAppDidEnterBackground() {
      controllerLogger.debug("📱 App entering background")
      isAppInBackground = true
      cancelPendingLoadMoreRequest()
    }

    private func handleAppWillEnterForeground() {
      controllerLogger.debug("📱 App entering foreground")
      isAppInBackground = false
    }

    // MARK: - State Manager Updates

    func updateStateManager(_ newStateManager: FeedStateManager, viewportState newViewportState: FeedViewportState) {
      let dataManagerChanged = newStateManager !== stateManager
      guard dataManagerChanged || newViewportState !== viewportState else { return }

      controllerLogger.info(
        "🔄 Fast switching state manager: \\(self.stateManager.currentFeedType.identifier) → \\(newStateManager.currentFeedType.identifier)"
      )

      // Capture scroll position for the current feed before switching
      captureCurrentScrollPosition()
      viewportState.unregisterScrollToTopHandler(ownerID: viewportOwnerID)

      // Cancel ongoing operations and invalidate completions from the old feed.
      feedGeneration += 1
      if isRefreshing {
        #if !targetEnvironment(macCatalyst)
          refreshControl.endRefreshing()
        #endif
        isRefreshing = false
      }
      cancelPendingLoadMoreRequest()
      prefetchTasks.values.forEach { $0.task.cancel() }
      prefetchTasks.removeAll()
      nativeRows.cancelPreparation()
      initialLoadTask?.cancel()
      initialLoadTask = nil
      stateObserver?.stopObserving()
      themeObserver?.stopObserving()
      feedbackObserver?.stopObserving()
      appStateObserver?.stopObserving()
      tabTapObserver?.stopObserving()

      // Update the state manager
      stateManager = newStateManager
      viewportState = newViewportState
      scrollRestoration.reset(to: newViewportState.getScrollAnchor()?.viewportAnchor)
      resetTriggerDedupState()

      // Restart observations
      setupObservers()
      setupScrollToTopCallback()
      setupThemeObserver()
      setupFeedbackObserver()
      setupAccountSwitchObserver()
      setupTabTapObserver()

      // The snapshot/layout boundary restores this feed, without a timed callback.
      shouldReloadDataOnce = true
      let generation = feedGeneration
      Task { @MainActor [weak self] in
        guard let self, self.feedGeneration == generation else { return }
        if dataManagerChanged {
          await self.loadInitialData()
        } else {
          await self.performUpdate()
        }
      }
    }
  }

  // MARK: - Native Rows

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated {
    private func setupNativeRows() {
      nativeRows.collectionView = collectionView
      nativeRows.installPresentationHost(in: self)
      nativeRows.onNeedsReconfigure = { [weak self] in
        Task { @MainActor [weak self] in await self?.performUpdate() }
      }
      nativeRows.onSettingsChanged = { [weak self] in self?.forceCellReconfiguration() }
      nativeRows.startObservingSettings()
      registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitDisplayScale.self]) {
        (controller: FeedCollectionViewControllerIntegrated, _: UITraitCollection) in
        controller.nativeRowTraitsDidChange()
      }
    }

    /// A size class or display scale change re-resolves the row settings from the new traits and
    /// relays out the visible native rows at once, so they move with the hosted rows (whose lane
    /// follows the size class) instead of after the next snapshot. The reconfigure that follows
    /// updates rows prepared but not on screen.
    private func nativeRowTraitsDidChange() {
      guard let collectionView, dataSource != nil, nativeRows.updateTraits(traitCollection) else { return }
      relayoutVisibleNativeRows(boundsWidth: collectionView.bounds.width)
      forceCellReconfiguration()
    }

    private func configureNativeCell(_ cell: NativeFeedPostCell, row: NativeFeedRowCoordinator.Row) {
      let signpostId = PerformanceSignposts.beginCellConfiguration(postId: row.postID)
      defer { PerformanceSignposts.endCellConfiguration(id: signpostId) }
      let width = nativeRows.layoutWidth(forBoundsWidth: collectionView.bounds.width)
      // A row is only native once a snapshot resolved the row settings, so both exist here.
      guard let typography = nativeRows.typography, let content = nativeRows.content(for: row, width: width) else {
        controllerLogger.fault("Native feed row \(row.postID, privacy: .public) configured without row settings")
        return
      }
      updateDiagnostics?.postConfigurations += 1
      cell.selectedBackgroundView = nil
      cell.configure(
        content, typography: typography, actions: nativeRows.actions(for: row),
        shadowUpdates: nativeRows.shadowUpdates(for: row))

      // Annotate the cell so Siri's 'View AppIntents Payload' walk can collect
      // onscreen PostEntity references, as the hosted registration does.
#if compiler(>=6.4)
      if #available(anyAppleOS 26.0, *) {
        if let post = postsByID[row.postID], let entityURI = AppEntityAnnotationIdentifiers.postURI(for: post) {
          cell.appEntityIdentifier = EntityIdentifier(for: PostEntity.self, identifier: entityURI)
        } else {
          cell.appEntityIdentifier = nil
        }
      }
#endif
      cell.configurationUpdateHandler = nil
    }

    /// Prepares the layouts of native rows from the first visible post through the next screens,
    /// off the main actor, so cells that scroll in find them cached.
    private func prepareNativeLayouts(near posts: [CachedFeedViewPost]) {
      let firstVisibleID = collectionView.indexPathsForVisibleItems.sorted().compactMap { postIDAt($0) }.first
      let start = firstVisibleID.flatMap { id in posts.firstIndex { $0.id == id } } ?? 0
      let window = posts[start..<min(posts.count, start + Self.nativeLayoutPreparationWindow)]
      nativeRows.prepareLayouts(forPostIDs: window.map(\.id), boundsWidth: collectionView.bounds.width)
    }

    /// Posts ahead of the first visible one whose native layouts each snapshot prepares.
    private static let nativeLayoutPreparationWindow = 24

    /// Configures the visible native cells with layouts for `boundsWidth` right away, during a size
    /// transition, instead of waiting for the reconfigure that follows it.
    private func relayoutVisibleNativeRows(boundsWidth: CGFloat) {
      guard let collectionView, boundsWidth > 0 else { return }
      for indexPath in collectionView.indexPathsForVisibleItems {
        guard let cell = collectionView.cellForItem(at: indexPath) as? NativeFeedPostCell,
          let id = postIDAt(indexPath), let row = nativeRows.nativeRow(forPostID: id),
          let typography = nativeRows.typography,
          let content = nativeRows.content(for: row, width: nativeRows.layoutWidth(forBoundsWidth: boundsWidth))
        else { continue }
        cell.configure(
          content, typography: typography, actions: nativeRows.actions(for: row),
          shadowUpdates: nativeRows.shadowUpdates(for: row))
      }
    }
  }

  // MARK: - UICollectionViewDelegate

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated: UICollectionViewDelegate {
    func collectionView(
      _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      trackPostSeenIfNeeded(at: indexPath)
      triggerLoadMoreIfNeeded(at: indexPath)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      scrollRestoration.cancel()
      viewportInteractionGeneration += 1
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        captureCurrentScrollPosition()
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      captureCurrentScrollPosition()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      captureCurrentScrollPosition()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onScrollOffsetChanged?(scrollView.contentOffset.y)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
      super.viewWillTransition(to: size, with: coordinator)
      rowHeightCache.removeAll()
      nativeRows.invalidateLayouts(includingCellWidths: true)
      // Native rows get layouts for the new width before the collection view resizes them, so a
      // rotation never draws a row with frames for the old width.
      coordinator.animate(alongsideTransition: { [weak self] _ in
        guard let self else { return }
        // The new size can come with a new size class; lay out with the settings it implies.
        _ = self.nativeRows.updateTraits(self.traitCollection)
        self.relayoutVisibleNativeRows(boundsWidth: size.width)
      }) { [weak self] _ in
        // Rows carry the window size for embed media; refresh it once the new size is in place.
        self?.forceCellReconfiguration()
      }
    }
  }

  // MARK: - UICollectionViewDataSourcePrefetching

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath])
    {
      nativeRows.prepareLayouts(
        forPostIDs: indexPaths.compactMap { postIDAt($0) }, boundsWidth: collectionView.bounds.width)
      let appState = stateManager.appState
      guard let client = appState.atProtoClient else { return }
      let autoplayVideos = appState.appSettings.autoplayVideos
      let policy = appState.moderationPolicy

      for indexPath in indexPaths {
        guard prefetchTasks.count < 6,
              let item = dataSource.itemIdentifier(for: indexPath),
              case .post(_, _, let id) = item,
              prefetchTasks[id] == nil,
              let cached = postsByID[id],
              let feedViewPost = try? cached.feedViewPost else { continue }

        // A cancelled prefetch can finish after a new one for the same post was scheduled;
        // the token keeps it from removing its replacement.
        let token = UUID()
        let task = Task { [weak self] in
          defer {
            if self?.prefetchTasks[id]?.token == token {
              self?.prefetchTasks[id] = nil
            }
          }
          guard !Task.isCancelled else { return }
          await FeedPrefetchingManager.shared.prefetchPostData(post: feedViewPost, client: client)
          guard !Task.isCancelled, autoplayVideos else { return }
          if case .appBskyEmbedVideoView(let video)? = feedViewPost.post.embed,
             let url = video.playlist.url {
            let media = policy.decide(post: feedViewPost.post).ui(.contentMedia)
            if !media.filter, !media.blur {
              let model = VideoModel(
                id: url.absoluteString, url: url,
                type: .hlsStream(playlistURL: url, cid: video.cid, aspectRatio: nil),
                aspectRatio: 16.0 / 9.0)
              await VideoAssetManager.shared.prewarm(model)
            }
          }
        }
        prefetchTasks[id] = (token, task)
      }
    }

    func collectionView(
      _ collectionView: UICollectionView,
      cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
      for indexPath in indexPaths {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .post(_, _, let id) = item else { continue }
        prefetchTasks.removeValue(forKey: id)?.task.cancel()
      }
    }
  }

  // MARK: - Helper Functions

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated {
    private func getEffectiveColorScheme() -> ColorScheme {
      #if os(iOS)
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        return stateManager.appState.themeManager.effectiveColorScheme(for: systemScheme)
      #else
        return .light
      #endif
    }
  }

  // MARK: - Background State (Loading / Empty)

  // MARK: - Background State Management

  enum FeedBackgroundState {
    case content
    case loading(message: String)
    case error(message: String, retry: () -> Void)
    case emptyTimeline(action: () -> Void)
    case emptyFeed(action: () -> Void)

    var isContent: Bool {
      if case .content = self {
        return true
      }
      return false
    }
  }

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated {
    private var currentBackgroundState: FeedBackgroundState {
      switch stateManager.contentState {
      case .error:
        let message = stateManager.feedLoadError.flatMap {
          UserFacingError.message(for: $0, action: "load this feed")
        } ?? "Couldn’t load this feed. Try again."
        return .error(message: message) { [weak self] in
          guard let self else { return }
          Task { @MainActor in
            await self.stateManager.retry()
          }
        }
      case .loading:
        return .loading(message: "Loading feed…")
      case .empty:
        switch stateManager.currentFeedType {
        case .timeline:
          return .emptyTimeline { [weak self] in
            self?.sceneContext.navigationManager.tabSelection?(1)
          }
        default:
          return .emptyFeed { [weak self] in
            guard let self else { return }
            Task { @MainActor in
              await self.stateManager.refreshUserInitiated(displayScale: self.traitCollection.displayScale)
            }
          }
        }
      case .content:
        return .content
      }
    }

    @ViewBuilder
    private func backgroundViewForState(_ state: FeedBackgroundState) -> some View {
      switch state {
      case .content:
        EmptyView()
      case .loading(let message):
        LoadingStateView(message: message)
          .background(Color.clear)
      case .error(let message, let retry):
        ContentUnavailableStateView(
          title: "Couldn’t Load Feed",
          description: message,
          systemImage: "wifi.exclamationmark",
          actionTitle: "Try Again",
          action: retry
        )
        .background(Color.clear)
      case .emptyTimeline(let action):
        ContentUnavailableStateView.emptyFollowingFeed(onDiscover: action)
          .background(Color.clear)
      case .emptyFeed(let action):
        ContentUnavailableStateView(
          title: "No Posts Yet",
          description: "There’s nothing in this feed right now. Pull down to refresh or try again later.",
          systemImage: "tray",
          actionTitle: "Refresh",
          action: action
        )
        .background(Color.clear)
      }
    }

    /// What the end of a non-empty feed shows: a spinner while more pages may load,
    /// a retry after a failed page, or a quiet end-of-feed line.
    private var currentFooterState: FeedPaginationFooterState {
      if stateManager.paginationError != nil { return .failed }
      if stateManager.hasReachedEnd { return .end }
      return .loading
    }

    private func updateBackgroundState() {
      guard let collectionView = collectionView else { return }

      let currentState = currentBackgroundState

      if currentState.isContent {
        // Remove background when showing content
        collectionView.backgroundView = nil
        backgroundHostingController = nil
      } else {
        // Show appropriate background view
        let backgroundView = AnyView(
          backgroundViewForState(currentState)
            .environment(stateManager.appState)
            .environment(\.fontManager, stateManager.appState.fontManager)
        )

        // Create or update hosting controller
        if let host = backgroundHostingController {
          host.rootView = backgroundView
          host.view.frame = collectionView.bounds
        } else {
          let host = UIHostingController(rootView: backgroundView)
          host.view.backgroundColor = .clear
          host.view.frame = collectionView.bounds
          host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          collectionView.backgroundView = host.view
          backgroundHostingController = host
        }
      }
    }

  }

  // MARK: - Pagination Footer

  enum FeedPaginationFooterState: Equatable {
    case loading
    case failed
    case end
  }

  struct FeedPaginationFooterView: View {
    let state: FeedPaginationFooterState
    let onRetry: () -> Void

    var body: some View {
      Group {
        switch state {
        case .loading:
          ProgressView()
            .accessibilityLabel("Loading more posts")
        case .failed:
          VStack(spacing: 8) {
            Text("Couldn’t load more posts.")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(Color.secondary)
              .multilineTextAlignment(.center)
            Button("Try Again", action: onRetry)
              .buttonStyle(.bordered)
          }
        case .end:
          Text("You’re all caught up")
            .appFont(AppTextRole.footnote)
            .foregroundStyle(Color.secondary)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
    }
  }

#else
  // MARK: - macOS Stub

  @available(macOS 13.0, *)
  final class FeedCollectionViewControllerIntegrated: NSViewController {
    var stateManager: FeedStateManager
    private var sceneContext: SceneNavigationContext
    private let navigationPath: Binding<NavigationPath>
    private let onScrollOffsetChanged: ((CGFloat) -> Void)?

    init(
      stateManager: FeedStateManager,
      sceneContext: SceneNavigationContext,
      navigationPath: Binding<NavigationPath>,
      onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    ) {
      self.stateManager = stateManager
      self.sceneContext = sceneContext
      self.navigationPath = navigationPath
      self.onScrollOffsetChanged = onScrollOffsetChanged
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func updateStateManager(_ newStateManager: FeedStateManager) {
      stateManager = newStateManager
    }
  }
#endif
