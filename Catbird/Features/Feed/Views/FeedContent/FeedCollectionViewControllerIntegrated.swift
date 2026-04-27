//
//  FeedCollectionViewControllerIntegrated.swift
//  Catbird
//
//  High-performance UIKit feed controller with SwiftUI cell hosting
//

import Petrel
import SwiftUI
import os

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

#if os(iOS)
  @available(iOS 16.0, *)
  final class FeedCollectionViewControllerIntegrated: UIViewController {
    // MARK: - Types

    private enum Section: Int, CaseIterable { case main }
    private enum Item: Hashable {
      case header
      case post(account: String, feed: String, id: String)
    }

    // MARK: - Properties

    var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    #if !targetEnvironment(macCatalyst)
      private var refreshControl: UIRefreshControl!
    #endif

    /// State management
    var stateManager: FeedStateManager

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
    private var updateTask: Task<Void, Never>?
    private var isPerformingUpdate = false

    /// Initial load serialization - de-dupes overlapping loadInitialData calls
    /// (viewWillAppear, account-switch observer, updateStateManager can race)
    private var initialLoadTask: Task<Void, Never>?

    /// State observation with proper @Observable integration
    var stateObserver: UIKitStateObserver<FeedStateManager>?

    /// Theme manager observation
    var themeObserver: UIKitStateObserver<ThemeManager>?
    /// AppState observation for account switch boundaries
    var appStateObserver: UIKitStateObserver<AppState>?
    var feedbackObserver: UIKitStateObserver<FeedFeedbackManager>?
    /// Observer for tab tap to scroll to top
    var tabTapObserver: UIKitStateObserver<AppState>?

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
    /// O(1) post lookup used during cell configuration
    private var postsByID: [String: CachedFeedViewPost] = [:]
    
    // MARK: - Initialization

    init(
      stateManager: FeedStateManager,
      navigationPath: Binding<NavigationPath>,
      onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    ) {
      self.stateManager = stateManager
      self.navigationPath = navigationPath
      self.onScrollOffsetChanged = onScrollOffsetChanged

      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme Support

    private func setupThemeObserver() {
      // Observe ThemeManager's @Observable properties directly
      themeObserver = UIKitStateObserver(observing: stateManager.appState.themeManager) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleThemeChange()
        }
      }
      themeObserver?.startObserving()

      // Keep the notification observer as a fallback for explicit theme changes
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleThemeChangeNotification),
        name: NSNotification.Name("ThemeChanged"),
        object: nil
      )
    }

    @objc private func handleThemeChangeNotification() {
      DispatchQueue.main.async { [weak self] in
        self?.handleThemeChange()
      }
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

    private func forceCellReconfiguration() {
      guard let dataSource = dataSource else { return }

      // Get current snapshot and reapply it to force cell reconfiguration
      let currentSnapshot = dataSource.snapshot()
      dataSource.apply(currentSnapshot, animatingDifferences: false)
    }

    // INSERTED
    private func reloadAllCells() {
      guard let dataSource = dataSource else { return }
      let snapshot = dataSource.snapshot()
      #if os(iOS)
        if #available(iOS 15.0, *) {
          dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
          dataSource.apply(snapshot, animatingDifferences: false)
        }
      #else
        dataSource.apply(snapshot, animatingDifferences: false)
      #endif
    }

    private func setupFeedbackObserver() {
      feedbackObserver = UIKitStateObserver(observing: stateManager.appState.feedFeedbackManager) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleFeedFeedbackChange()
        }
      }
      feedbackObserver?.startObserving()
    }

    private func handleFeedFeedbackChange() {
      // When feed feedback enablement or feed identity changes, cells must rebuild
      reloadAllCells()
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
      appStateObserver?.startObserving()
    }
    
    // Observe tab tap to scroll to top and refresh
    private func setupTabTapObserver() {
      tabTapObserver = UIKitStateObserver(observing: stateManager.appState) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          
          // Check if home tab (0) was tapped again
          if let tappedTab = self.stateManager.appState.tabTappedAgain, tappedTab == 0 {
            self.controllerLogger.debug("🏠 Home tab tapped again - scrolling to top and refreshing")
            
            // Clear the signal immediately to prevent re-triggering
            self.stateManager.appState.tabTappedAgain = nil
            
            // Scroll to top and refresh
            self.scrollToTopAndRefresh()
          }
        }
      }
      tabTapObserver?.startObserving()
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
      super.viewDidLoad()

      updateThemeColors()
      setupCollectionView()
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

      // Update theme colors when view appears to catch any missed theme changes
      updateThemeColors()
      stateManager.appState.urlHandler.registerTopViewController(self)

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

    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)

      // Capture scroll position when view disappears to preserve it
      captureCurrentScrollPosition()
    }

    deinit {
      stateObserver?.stopObserving()
      themeObserver?.stopObserving()
      feedbackObserver?.stopObserving()
      appStateObserver?.stopObserving()
      tabTapObserver?.stopObserving()
      cancelPendingLoadMoreRequest()
      updateTask?.cancel()
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
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
          // System appearance changed; update dynamic backgrounds to reflect dim/black correctly
          updateThemeColors()
          forceCellReconfiguration()
        }
      #endif
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

        // Check if feed feedback is enabled
        guard self.stateManager.appState.feedFeedbackManager.isEnabled else {
          return nil
        }

        // Get the post for this index
        guard indexPath.item < self.stateManager.posts.count else { return nil }
        let post = self.stateManager.posts[indexPath.item]

        // Create Show More action
        let showMoreAction = UIContextualAction(style: .normal, title: nil) {
          [weak self] action, view, completion in
          guard let self = self else {
            completion(false)
            return
          }

          if let postURI = try? post.feedViewPost.post.uri {
            self.stateManager.appState.feedFeedbackManager.sendShowMore(postURI: postURI)
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

        // Create Show Less action
        let showLessAction = UIContextualAction(style: .normal, title: nil) {
          [weak self] action, view, completion in
          guard let self = self else {
            completion(false)
            return
          }

          if let postURI = try? post.feedViewPost.post.uri {
            self.stateManager.appState.feedFeedbackManager.sendShowLess(postURI: postURI)
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

        let configuration = UISwipeActionsConfiguration(actions: [showLessAction, showMoreAction])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
      }

      let layout = UICollectionViewCompositionalLayout.list(using: configuration)

      return layout
    }

    private func setupDataSource() {
      // Registration for post cells
      let postRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, indexPath, postId in
        let signpostId = PerformanceSignposts.beginCellConfiguration(postId: postId)
        defer { PerformanceSignposts.endCellConfiguration(id: signpostId) }
        
        guard let self = self,
          let post = self.postsByID[postId]
        else {
          cell.contentConfiguration = nil
          return
        }

        // Reset cell margins
        cell.layoutMargins = .zero
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero

        // Remove selection background
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.selectedBackgroundView = nil

        let viewModel = self.stateManager.viewModel(for: post)

        // Configure cell with UIHostingConfiguration and inject required environment
        let appState = self.stateManager.appState
        let accountID = appState.userDID ?? "unknown-account"
        let feedID = self.stateManager.currentFeedType.identifier
        let hostingIdentity = "\(accountID)-\(feedID)-\(post.id)"
        cell.contentConfiguration = UIHostingConfiguration {
          FeedPostRow(
            viewModel: viewModel,
            navigationPath: self.navigationPath,
            feedTypeIdentifier: self.stateManager.currentFeedType.identifier,
            tracksVisibilityForFeedback: false
          )
          .applyAppStateEnvironment(appState)
          .environment(\.fontManager, appState.fontManager)
          .id(hostingIdentity)
          .padding(0)
          .background(Color.clear)
        }
        .margins(.all, 0)

        // Remove cell state handler to reduce memory overhead
        cell.configurationUpdateHandler = nil
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

        cell.contentConfiguration = UIHostingConfiguration { header }
          .margins(.all, 0)
      }

      dataSource = UICollectionViewDiffableDataSource<Section, Item>(
        collectionView: collectionView
      ) { collectionView, indexPath, item in
        switch item {
        case .header:
          return collectionView.dequeueConfiguredReusableCell(
            using: headerRegistration, for: indexPath, item: ())
        case .post(_, _, let id):
          return collectionView.dequeueConfiguredReusableCell(
            using: postRegistration, for: indexPath, item: id)
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
      Task { @MainActor in
        controllerLogger.debug("🔄 Fast refresh triggered")
        isRefreshing = true

        // User-initiated refresh should override background flag
        // This ensures pull-to-refresh works even if background flag is stuck
        await stateManager.refreshUserInitiated()
        await performUpdate()
      }
    }

    // MARK: - State Management

    @MainActor
    func performUpdate() async {
      guard !isAppInBackground else {
        controllerLogger.debug("⏸️ Skipping update - app in background")
        return
      }

      // Prevent concurrent updates - if already updating, cancel previous and wait
      if isPerformingUpdate {
        controllerLogger.debug("⚠️ Update already in progress, cancelling previous")
        updateTask?.cancel()
        // Brief wait to allow cancellation to complete
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
      }

      // Cancel any pending update task
      updateTask?.cancel()

      // Create new update task
      updateTask = Task { @MainActor in
        // Mark as performing update
        isPerformingUpdate = true
        defer {
          isPerformingUpdate = false
        }

        guard !Task.isCancelled else { return }

        // Always end refreshing, even on error
        if isRefreshing {
          #if !targetEnvironment(macCatalyst)
            refreshControl.endRefreshing()
          #endif
          isRefreshing = false
        }

        // Check for errors before updating UI
        if case .error(let error) = stateManager.loadingState {
          controllerLogger.error("❌ Feed update error: \(error.localizedDescription)")
          // Keep existing posts visible, user can retry
          updateBackgroundState()
          return
        }

        controllerLogger.debug("🔄 Fast update: Creating snapshot")

        // CRITICAL: Capture state at this moment to prevent race conditions
        // Do NOT read from stateManager during snapshot application
        let capturedPosts = stateManager.posts
        let capturedPostsByID = Dictionary(
          capturedPosts.map { ($0.id, $0) },
          uniquingKeysWith: { first, _ in first }
        )
        let capturedHeaderPresent = headerView != nil
        let accountID = stateManager.appState.userDID ?? "unknown-account"
        let feedID = stateManager.currentFeedType.identifier

        guard !Task.isCancelled else { return }

        // Build snapshot from captured immutable state
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])

        // Prepend header cell when available
        if capturedHeaderPresent {
          snapshot.appendItems([.header], toSection: .main)
        }

        let items = capturedPosts.map { Item.post(account: accountID, feed: feedID, id: $0.id) }
        snapshot.appendItems(items, toSection: .main)
        postsByID = capturedPostsByID

        guard !Task.isCancelled else { return }

        let currentItemIdentifiers = dataSource.snapshot().itemIdentifiers

        // Apply snapshot with targeted reconfiguration to avoid full reload churn
        if #available(iOS 15.0, *), shouldReloadDataOnce {
          shouldReloadDataOnce = false
          await dataSource.applySnapshotUsingReloadData(snapshot)
        } else if #available(iOS 15.0, *) {
          if currentItemIdentifiers == snapshot.itemIdentifiers {
            snapshot.reconfigureItems(items)
          }
          await dataSource.apply(snapshot, animatingDifferences: false)
        } else {
          // Fallback for iOS 14 (though minimum is iOS 16)
          await dataSource.apply(snapshot, animatingDifferences: false)
        }

        guard !Task.isCancelled else { return }

        controllerLogger.debug("✅ Fast update complete - \\(items.count) items")
        updateBackgroundState()
      }

      await updateTask?.value
    }

    @MainActor
    func loadInitialData() async {
      if let existing = initialLoadTask {
        controllerLogger.debug("⏭️ Initial load already in flight, awaiting existing task")
        await existing.value
        return
      }

      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.initialLoadTask = nil }
        self.controllerLogger.debug("📥 Loading initial data")
        await self.stateManager.loadInitialData()
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
      stateObserver = UIKitStateObserver.observeFeedStateManager(
        stateManager,
        onPostsChanged: { [weak self] _ in
          Task { @MainActor in
            await self?.performUpdate()
          }
        },
        onLoadingStateChanged: { [weak self] _ in
          self?.updateBackgroundState()
        },
        onScrollAnchorChanged: { _ in }
      )
      stateObserver?.startObserving()
    }

    private func setupScrollToTopCallback() {
      // Register the callback so FeedStateManager can trigger scroll-to-top
      stateManager.scrollToTopCallback = { [weak self] in
        self?.scrollToTopAnimated()
      }
    }

    /// Scrolls to the absolute top of the collection view (animated)
    private func scrollToTopAnimated() {
      guard let collectionView = collectionView else { return }

      let minOffsetY = -collectionView.adjustedContentInset.top
      let minOffsetX = -collectionView.adjustedContentInset.left

      controllerLogger.debug("🔝 Scrolling to top (animated) to y=\(minOffsetY)")
      collectionView.setContentOffset(CGPoint(x: minOffsetX, y: minOffsetY), animated: true)
    }
    
    /// Scrolls to top and refreshes to get the latest posts
    /// This is the behavior when the user taps the home tab while already on the home tab
    func scrollToTopAndRefresh() {
      guard let collectionView = collectionView else { return }
      
      // Only refresh when we're truly already at the top.
      let topOffset = -collectionView.adjustedContentInset.top
      let isAtTop = collectionView.contentOffset.y <= topOffset + 1.0
      
      controllerLogger.debug("🔝 Home tab tapped - isAtTop: \(isAtTop), currentOffset: \(collectionView.contentOffset.y), topOffset: \(topOffset)")
      
      if isAtTop {
        // Already at top - refresh to get new posts
        controllerLogger.debug("🔝 Already at top - refreshing feed")
        Task { @MainActor in
          await stateManager.refreshUserInitiated()
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

    /// Captures the current scroll position and saves it to the state manager
    private func captureCurrentScrollPosition() {
      guard let collectionView = collectionView else { return }
      #if os(iOS)
        stateManager.captureScrollAnchor(from: collectionView)
      #endif
    }

    /// Restores scroll position from the state manager's scroll anchor
    private func restoreScrollPosition() {
      guard let collectionView = collectionView,
        let anchor = stateManager.getScrollAnchor(),
        let postIndex = stateManager.index(of: anchor.postID)
      else {
        // No saved position or post not found, scroll to top
        resetScrollToTop()
        return
      }

      let indexPath = IndexPath(item: postIndex, section: 0)

      // Scroll to the post first
      collectionView.scrollToItem(at: indexPath, at: .top, animated: false)

      // Then adjust by the saved offset
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let collectionView = self.collectionView else { return }

        let currentOffset = collectionView.contentOffset
        let adjustedOffset = CGPoint(
          x: currentOffset.x,
          y: currentOffset.y + anchor.offsetFromTop
        )

        // Ensure we don't scroll beyond bounds. Respect adjusted content insets
        let minOffsetY = -collectionView.adjustedContentInset.top
        let maxOffsetY = max(
          minOffsetY,
          collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            - collectionView.bounds.height
        )
        let clampedY = min(max(adjustedOffset.y, minOffsetY), maxOffsetY)
        let clampedOffset = CGPoint(x: adjustedOffset.x, y: clampedY)

        collectionView.setContentOffset(clampedOffset, animated: false)
        self.controllerLogger.debug(
          "📍 Restored scroll position for post: \(anchor.postID), offset: \(anchor.offsetFromTop)")
      }
    }

    /// Resets scroll position to the top (aligned to large title scroll edge)
    private func resetScrollToTop() {
      guard let collectionView = collectionView else { return }
      let minOffsetY = -collectionView.adjustedContentInset.top
      let minOffsetX = -collectionView.adjustedContentInset.left
      collectionView.setContentOffset(CGPoint(x: minOffsetX, y: minOffsetY), animated: false)
      controllerLogger.debug("🔝 Reset scroll position to top (respecting adjustedContentInset)")
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
      let postIndex = headerPresent ? indexPath.item - 1 : indexPath.item
      guard postIndex >= .zero, postIndex < stateManager.posts.count else { return nil }
      return postIndex
    }
    
    private func trackPostSeenIfNeeded(at indexPath: IndexPath) {
      guard let postIndex = postIndexForRow(at: indexPath) else { return }
      
      let postViewModel = stateManager.posts[postIndex]
      let postID = postViewModel.id
      let now = Date().timeIntervalSinceReferenceDate
      if let lastSeenTimestamp = recentlySeenPostTimestamps[postID],
         now - lastSeenTimestamp < seenTrackingDedupInterval
      {
        return
      }
      
      recentlySeenPostTimestamps[postID] = now
      if recentlySeenPostTimestamps.count > 200 {
        let cutoff = now - seenTrackingDedupInterval * 2
        recentlySeenPostTimestamps = recentlySeenPostTimestamps.filter { $0.value >= cutoff }
      }
      
      if let postURI = try? ATProtocolURI(
        uriString: postViewModel.feedViewPost.post.uri.uriString())
      {
        stateManager.appState.feedFeedbackManager.trackPostSeen(postURI: postURI)
      }
    }
    
    private func triggerLoadMoreIfNeeded(at indexPath: IndexPath) {
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
      #if os(iOS)
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

    func updateStateManager(_ newStateManager: FeedStateManager) {
      guard newStateManager !== stateManager else { return }

      controllerLogger.info(
        "🔄 Fast switching state manager: \\(self.stateManager.currentFeedType.identifier) → \\(newStateManager.currentFeedType.identifier)"
      )

      // Capture scroll position for the current feed before switching
      captureCurrentScrollPosition()

      // Cancel ongoing operations
      cancelPendingLoadMoreRequest()
      initialLoadTask?.cancel()
      initialLoadTask = nil
      stateObserver?.stopObserving()
      themeObserver?.stopObserving()
      feedbackObserver?.stopObserving()
      appStateObserver?.stopObserving()
      tabTapObserver?.stopObserving()

      // Update the state manager
      stateManager = newStateManager
      resetTriggerDedupState()

      // Restart observations
      setupObservers()
      setupScrollToTopCallback()
      setupThemeObserver()
      setupFeedbackObserver()
      setupAccountSwitchObserver()
      setupTabTapObserver()

      // Load fresh data for new feed
      Task { @MainActor in
        self.shouldReloadDataOnce = true
        await loadInitialData()

        // After loading data, restore the scroll position for the new feed
        // Give the collection view a moment to update its content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          self?.restoreScrollPosition()
        }
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

      // Notify scroll offset callback
      onScrollOffsetChanged?(collectionView.contentOffset.y)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onScrollOffsetChanged?(scrollView.contentOffset.y)
    }
  }

  // MARK: - UICollectionViewDataSourcePrefetching

  @available(iOS 16.0, *)
  extension FeedCollectionViewControllerIntegrated: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath])
    {
      // Prefetch images for upcoming cells
      let posts = indexPaths.compactMap { indexPath -> CachedFeedViewPost? in
        guard indexPath.item < stateManager.posts.count else { return nil }
        return stateManager.posts[indexPath.item]
      }
      
      guard !posts.isEmpty else { return }
      
      Task {
        await FeedPrefetchingManager.shared.prefetchAssets(for: posts)
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
    case emptyTimeline(action: () -> Void)
    case emptyFeed(feedName: String, action: () -> Void)

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
      if stateManager.posts.isEmpty && stateManager.isLoading {
        let message: String
        switch stateManager.currentFeedType {
        case .timeline:
          message = "Loading your timeline..."
        default:
          message = "Loading \(stateManager.currentFeedType.displayName.lowercased())..."
        }
        return .loading(message: message)
      } else if stateManager.posts.isEmpty && !stateManager.isLoading {
        switch stateManager.currentFeedType {
        case .timeline:
          return .emptyTimeline { [weak self] in
            self?.stateManager.appState.navigationManager.tabSelection?(1)
          }
        default:
          return .emptyFeed(feedName: stateManager.currentFeedType.displayName) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
              await self.stateManager.refreshUserInitiated()
            }
          }
        }
      } else {
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
      case .emptyTimeline(let action):
        ContentUnavailableStateView.emptyFollowingFeed(onDiscover: action)
          .background(Color.clear)
      case .emptyFeed(let feedName, let action):
        ContentUnavailableStateView.emptyFeed(feedName: feedName, onRefresh: action, onExplore: nil)
          .background(Color.clear)
      }
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
        let backgroundView = AnyView(backgroundViewForState(currentState))

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

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      if let collectionView = collectionView, let bgView = collectionView.backgroundView {
        bgView.frame = collectionView.bounds
      }
    }
  }

#else
  // MARK: - macOS Stub

  @available(macOS 13.0, *)
  final class FeedCollectionViewControllerIntegrated: NSViewController {
    var stateManager: FeedStateManager
    private let navigationPath: Binding<NavigationPath>
    private let onScrollOffsetChanged: ((CGFloat) -> Void)?

    init(
      stateManager: FeedStateManager,
      navigationPath: Binding<NavigationPath>,
      onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    ) {
      self.stateManager = stateManager
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
