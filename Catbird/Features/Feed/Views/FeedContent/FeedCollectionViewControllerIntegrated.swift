//
//  FeedCollectionViewControllerIntegrated.swift
//  Catbird
//
//  Production-ready UIKit feed controller with unified scroll preservation
//  Uses OptimizedScrollPreservationSystem with UIUpdateLink for iOS 18+
//

import UIKit
import SwiftUI
import Petrel
import os

@available(iOS 16.0, *)
final class FeedCollectionViewControllerIntegrated: UIViewController {
    // MARK: - Types
    
    private enum Section: Int, CaseIterable {
        case main = 0
    }
    
    private struct PostItem: Hashable {
        let id: String
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        static func == (lhs: PostItem, rhs: PostItem) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    // MARK: - Properties
    
    var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, PostItem>!
    private var refreshControl: UIRefreshControl!
    
    /// State management
    var stateManager: FeedStateManager
    
    /// Navigation
    private let navigationPath: Binding<NavigationPath>
    
    /// Unified scroll preservation system
    private let unifiedScrollPipeline = UnifiedScrollPreservationPipeline()
    
    /// Optimized scroll system for iOS 18+
    @available(iOS 18.0, *)
    private lazy var optimizedScrollSystem = OptimizedScrollPreservationSystem()
    
    /// Gap loading manager for iOS 18+
    @available(iOS 18.0, *)
    private lazy var gapLoadingManager = FeedGapLoadingManager()
    
    /// Load more coordination
    var loadMoreTask: Task<Void, Never>?
    
    /// State observation task
    var observationTask: Task<Void, Never>?
    
    /// Callbacks
    private let onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    /// Refresh state tracking
    private var isRefreshing = false
    private var pullToRefreshAnchor: UnifiedScrollPreservationPipeline.ScrollAnchor?
    
    /// App lifecycle tracking
    private var isAppInBackground = false
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    
    /// Automatic persistence
    private var persistenceTimer: Timer?
    private var lastPersistedOffset: CGFloat = 0
    private let persistenceThreshold: CGFloat = 100 // Only persist if scrolled more than this
    
    /// Logging
    let controllerLogger = Logger(subsystem: "blue.catbird", category: "FeedCollectionIntegrated")
    
    /// Height validation manager for debugging
    @MainActor private let heightValidationManager = HeightValidationManager()
    
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
        // Listen for theme changes from ThemeManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: NSNotification.Name("ThemeChanged"),
            object: nil
        )
    }
    
    @objc private func handleThemeChange() {
        DispatchQueue.main.async { [weak self] in
            self?.updateThemeColors()
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        // Update background colors when system appearance changes
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateThemeColors()
        }
    }
    
    private func updateThemeColors() {
        let currentScheme = getCurrentColorScheme()
        let dynamicBackgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: currentScheme))
        
        collectionView?.backgroundColor = dynamicBackgroundColor
        view.backgroundColor = dynamicBackgroundColor
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set initial theme colors
        updateThemeColors()
        
        setupCollectionView()
        setupDataSource()
        setupRefreshControl()
        setupObservers()
        setupScrollToTopCallback()
        setupAppLifecycleObservers()
        setupThemeObserver()
        setupAutomaticPersistence()
        setupHeightValidation()
        
        // Register with iOS 18+ state restoration coordinator
        if #available(iOS 18.0, *) {
            let identifier = "feed_controller_\(stateManager.currentFeedType.identifier)"
            iOS18StateRestorationCoordinator.shared.registerController(self, identifier: identifier)
            controllerLogger.debug("📝 Registered with iOS 18+ restoration coordinator: \(identifier)")
        }
        
        // Initial data load will be handled in viewWillAppear for proper position restoration
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        Task { @MainActor in
            // First, ensure we have data loaded
            await loadInitialData()
            
            // Then restore persisted scroll position if available (only for chronological feeds)
            if stateManager.currentFeedType.isChronological,
               let persistedState = loadPersistedScrollState() {
                await performUpdate(type: .viewAppearance(persistedState: persistedState))
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Resume automatic persistence
        startAutomaticPersistence()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Save current position before view disappears
        savePersistedScrollState()
        
        // Pause automatic persistence
        stopAutomaticPersistence()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        
        Task { @MainActor in
            await handleMemoryWarning()
        }
    }
    
    // MARK: - Setup
    
    private func setupCollectionView() {
        let layout = createOptimizedLayout()
        
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: getCurrentColorScheme()))
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        
        // Remove all margins and insets (match legacy controller)
        collectionView.layoutMargins = .zero
        collectionView.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
        collectionView.contentInset = .zero
        
        // Configure behavior (match legacy controller)
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.showsVerticalScrollIndicator = true
        
        // Performance optimizations
        collectionView.isPrefetchingEnabled = true
        
        view.addSubview(collectionView)
        
        // Use Auto Layout constraints like legacy controller
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func createOptimizedLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        
        // Match legacy controller's configuration exactly
        configuration.backgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: getCurrentColorScheme()))
        configuration.showsSeparators = false // Handle separators in SwiftUI
        
        // Configure header/footer
        configuration.headerMode = .none
        configuration.footerMode = .none
        
        // Remove default swipe actions that can add margins
        configuration.leadingSwipeActionsConfigurationProvider = nil
        configuration.trailingSwipeActionsConfigurationProvider = nil
        
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        
        // Remove layout margins
        layout.configuration.contentInsetsReference = .none
        
        return layout
    }
    
    private func setupDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, PostItem> { [weak self] cell, indexPath, item in
            guard let self = self,
                  let post = self.stateManager.posts.first(where: { $0.id == item.id }) else {
                cell.contentConfiguration = nil
                return
            }
            
            // Reset cell margins (match legacy controller)
            cell.layoutMargins = .zero
            cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
            
            // Remove selection background
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.selectedBackgroundView = nil
            
            let viewModel = self.stateManager.viewModel(for: post)
            
            // Configure cell with UIHostingConfiguration (match legacy exactly)
            cell.contentConfiguration = UIHostingConfiguration {
                AnyView(
                    FeedPostRow(
                        viewModel: viewModel,
                        navigationPath: self.navigationPath
                    )
                    .padding(0)
                    .background(Color.clear)
                )
            }
            .margins(.all, 0)
            
            // Remove cell state handler to reduce memory overhead (match legacy)
            cell.configurationUpdateHandler = nil
            
            // Perform height validation if enabled
            if self.heightValidationManager.isValidationEnabled {
                self.scheduleHeightValidation(for: cell, post: post, indexPath: indexPath)
            }
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, PostItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: item
            )
        }
    }
    
    private func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
    }
    
    func setupObservers() {
        observationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                let previousCount = self.stateManager.posts.count
                
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                
                let currentCount = self.stateManager.posts.count
                
                if previousCount != currentCount {
                    await self.performUpdate(type: .normalUpdate)
                }
            }
        }
    }
    
    func setupScrollToTopCallback() {
        stateManager.scrollToTopCallback = { [weak self] in
            self?.scrollToTop(animated: true)
        }
    }
    
    private func setupAppLifecycleObservers() {
        // Legacy UIKit observers for compatibility - primary lifecycle now handled via SwiftUI scene phase
        // These provide additional granularity when needed but should not conflict with scene phase handling
        
        // App resigning active (provides more specific timing than scene phase inactive)
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillResignActive()
        }
        
        // App becoming active (coordinates with scene phase active)
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidBecomeActive()
        }
        
        // Keep background/foreground observers but rely on scene phase for primary logic
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
    }
    
    private func setupAutomaticPersistence() {
        // Set up periodic persistence while scrolling
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.savePersistedScrollStateIfNeeded()
        }
    }
    
    private func setupHeightValidation() {
        // Sync validation state with app settings
        heightValidationManager.isValidationEnabled = stateManager.appState.appSettings.enableHeightValidation
        
        // Set up observation for settings changes
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // Check every 1 second
                
                guard let self = self else { return }
                
                // Update validation state based on app settings
                let shouldEnable = self.stateManager.appState.appSettings.enableHeightValidation
                if self.heightValidationManager.isValidationEnabled != shouldEnable {
                    self.heightValidationManager.isValidationEnabled = shouldEnable
                    self.controllerLogger.info("📏 Height validation \(shouldEnable ? "enabled" : "disabled")")
                }
            }
        }
        
        // Set up notification observers for debug UI
        setupValidationNotificationHandlers()
    }
    
    private func setupValidationNotificationHandlers() {
        // Handle validation report generation requests
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GenerateValidationReport"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let report = self.generateValidationReport()
            NotificationCenter.default.post(
                name: NSNotification.Name("ValidationReportGenerated"),
                object: report
            )
        }
        
        // Handle clear validation data requests
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClearValidationData"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearValidationResults()
        }
    }
    
    /// Schedule height validation for a specific cell after layout
    private func scheduleHeightValidation(for cell: UICollectionViewListCell, post: CachedFeedViewPost, indexPath: IndexPath) {
        // Use a very short delay to allow the cell to complete its layout
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self = self, let cell = cell else { return }
            self.validateCellHeight(cell: cell, post: post, indexPath: indexPath)
        }
    }
    
    /// Perform the actual height validation
    private func validateCellHeight(cell: UICollectionViewListCell, post: CachedFeedViewPost, indexPath: IndexPath) {
        guard heightValidationManager.isValidationEnabled else { return }
        
        // Get the actual rendered height
        let actualHeight = cell.bounds.height
        
        // Skip validation if cell hasn't been laid out yet
        guard actualHeight > 0 else {
            // Try again after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak cell] in
                guard let self = self, let cell = cell else { return }
                self.validateCellHeight(cell: cell, post: post, indexPath: indexPath)
            }
            return
        }
        
        // Perform validation
        let feedTypeString = stateManager.currentFeedType.identifier
        heightValidationManager.validateHeight(
            for: post.feedViewPost.post,
            actualHeight: actualHeight,
            feedType: feedTypeString,
            mode: .compact
        )
        
        // Add visual indicator if enabled and there's a significant error
        if stateManager.appState.appSettings.showHeightValidationOverlay {
            addValidationOverlay(to: cell, post: post)
        }
    }
    
    /// Add visual overlay to indicate height validation results
    private func addValidationOverlay(to cell: UICollectionViewListCell, post: CachedFeedViewPost) {
        guard let statistics = heightValidationManager.currentStatistics else { return }
        
        // Find if this specific post has significant errors
        // For now, just show a general indicator for debugging
        
        // Remove existing overlay
        cell.subviews.forEach { view in
            if view.tag == 9999 { // Tag for validation overlay
                view.removeFromSuperview()
            }
        }
        
        // Add new overlay if validation shows significant error
        if statistics.significantErrors > 0 {
            let overlay = UIView()
            overlay.tag = 9999
            overlay.backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
            overlay.layer.borderColor = UIColor.systemRed.cgColor
            overlay.layer.borderWidth = 1.0
            overlay.isUserInteractionEnabled = false
            
            cell.addSubview(overlay)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: cell.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])
        }
    }
    
    // MARK: - Height Validation Public API
    
    /// Generate a validation report for debugging
    func generateValidationReport() -> String {
        return heightValidationManager.generateReport()
    }
    
    /// Export validation results as JSON
    func exportValidationResults() -> Data? {
        return heightValidationManager.exportResults()
    }
    
    /// Clear validation results
    func clearValidationResults() {
        heightValidationManager.clearResults()
    }
    
    /// Get current validation statistics
    var currentValidationStatistics: ValidationStatistics? {
        return heightValidationManager.currentStatistics
    }
    
    private func startAutomaticPersistence() {
        persistenceTimer?.fire()
    }
    
    private func stopAutomaticPersistence() {
        persistenceTimer?.invalidate()
    }
    
    // MARK: - App Lifecycle Handling
    
    private func handleAppDidEnterBackground() {
        controllerLogger.debug("📱 UIKit: App entering background - coordinate with scene phase")
        isAppInBackground = true
        
        // Save position immediately (scene phase coordination handles the main logic)
        savePersistedScrollState(force: true)
        
        // Cancel any ongoing tasks to prevent crashes
        loadMoreTask?.cancel()
        
        // Clean up iOS 18+ resources
        if #available(iOS 18.0, *) {
            optimizedScrollSystem.cleanup()
        }
    }
    
    private func handleAppWillEnterForeground() {
        controllerLogger.debug("📱 UIKit: App entering foreground - defer to scene phase logic")
        isAppInBackground = false
        
        // Don't automatically restore here - let scene phase coordination handle it
        // This prevents double restoration attempts
        controllerLogger.debug("📱 UIKit: Foreground handling deferred to scene phase coordination")
    }
    
    private func handleAppWillResignActive() {
        controllerLogger.debug("📱 UIKit: App resigning active - proactive save")
        
        // Proactive save for precise restoration (coordinates with scene phase inactive)
        savePersistedScrollStateIfNeeded()
    }
    
    private func handleAppDidBecomeActive() {
        controllerLogger.debug("📱 UIKit: App became active - resume operations")
        
        // Resume normal operation if not in background
        if !isAppInBackground {
            startAutomaticPersistence()
        }
    }
    
    // MARK: - Scene Phase Coordination
    
    /// Handle scene phase restoration coordinated by FeedStateStore
    @MainActor
    func handleScenePhaseRestoration() async {
        controllerLogger.debug("🎭 UIKit: Handling scene phase restoration")
        
        // Only restore if we have persisted state and aren't currently loading
        guard !stateManager.isLoading else {
            controllerLogger.debug("🎭 UIKit: Currently loading - skipping restoration")
            return
        }
        
        // Make sure we have posts and collection view is ready
        guard !stateManager.posts.isEmpty,
              collectionView.numberOfSections > 0 else {
            controllerLogger.debug("🎭 UIKit: No posts or collection view not ready - skipping restoration")
            return
        }
        
        // Only load persisted state for chronological feeds
        guard stateManager.currentFeedType.isChronological,
              let persistedState = loadPersistedScrollState() else {
            controllerLogger.debug("🎭 UIKit: No persisted state or non-chronological feed - skipping restoration")
            return
        }
        
        // Perform restoration update
        await performUpdate(type: .viewAppearance(persistedState: persistedState))
        controllerLogger.debug("🎭 UIKit: Scene phase restoration completed")
    }
    
    // MARK: - Data Loading
    
    @MainActor
    func loadInitialData() async {
        await stateManager.loadInitialData()
        await performUpdate(type: .normalUpdate)
    }
    
    @objc private func handleRefresh() {
        Task { @MainActor in
            // Use pre-captured anchor if available
            let anchor = pullToRefreshAnchor ?? captureCurrentAnchor()
            await performUpdate(type: .refresh(anchor: anchor))
            pullToRefreshAnchor = nil
        }
    }
    
    @MainActor
    private func performLoadMore() async {
        guard !stateManager.isLoading, !stateManager.hasReachedEnd else { return }
        
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            await performUpdate(type: .loadMore)
        }
        
        await loadMoreTask?.value
    }
    
    @MainActor
    private func handleMemoryWarning() async {
        controllerLogger.warning("⚠️ Memory warning received")
        await performUpdate(type: .memoryWarning)
    }
    
    // MARK: - Unified Update System
    
    @MainActor
    func performUpdate(type: UnifiedScrollPreservationPipeline.UpdateType) async {
        // Don't perform updates if app is in background
        guard !isAppInBackground else {
            controllerLogger.debug("⏸️ Skipping update - app in background")
            return
        }
        
        controllerLogger.debug("🔄 Starting update: \(String(describing: type))")
        
        // Save position before update for recovery
        let preUpdateState = captureCurrentScrollState()
        
        // Determine which system to use based on iOS version
        if #available(iOS 18.0, *) {
            await performOptimizedUpdate(type: type)
        } else {
            await performStandardUpdate(type: type)
        }
        
        // If update failed and we have a pre-update state, try to restore it
        if let state = preUpdateState, collectionView.contentOffset.y <= 0 {
            // Only restore if scroll position seems lost (at top when it shouldn't be)
            _ = await restorePersistedState(state)
        }
    }
    
    @available(iOS 18.0, *)
    @MainActor
    private func performOptimizedUpdate(type: UnifiedScrollPreservationPipeline.UpdateType) async {
        // Store the old posts before update for proper scroll preservation
        let oldPosts = stateManager.posts.map { $0.id }
        
        // Use the appropriate anchor based on update type
        var capturedAnchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor?
        
        switch type {
        case .refresh(let refreshAnchor):
            // Store the old post count to detect if new posts were loaded
            let oldPostCount = oldPosts.count
            
            // Only preserve scroll position for chronological feeds
            if stateManager.currentFeedType.isChronological {
                // For refresh, use the pre-captured anchor during pull gesture
                if let refreshAnchor = refreshAnchor,
                   refreshAnchor.indexPath.item < oldPosts.count {
                    // Convert UnifiedScrollPreservationPipeline.ScrollAnchor to PreciseScrollAnchor
                    if let attributes = collectionView.layoutAttributesForItem(at: refreshAnchor.indexPath) {
                        // Calculate viewport-relative position accounting for safe area
                        let safeAreaTop = collectionView.adjustedContentInset.top
                        let currentContentOffset = collectionView.contentOffset.y
                        
                        // The viewport-relative position should be relative to the safe area top
                        let viewportRelativeY = attributes.frame.origin.y - (currentContentOffset + safeAreaTop)
                        
                        capturedAnchor = OptimizedScrollPreservationSystem.PreciseScrollAnchor(
                            indexPath: refreshAnchor.indexPath,
                            postId: oldPosts[refreshAnchor.indexPath.item], // Use OLD post ID
                            contentOffset: refreshAnchor.contentOffset,
                            viewportRelativeY: viewportRelativeY, // Use safe-area-relative position
                            itemFrameY: attributes.frame.origin.y,
                            itemHeight: attributes.frame.height,
                            visibleHeightInViewport: attributes.frame.height,
                            timestamp: CACurrentMediaTime(),
                            displayScale: UIScreen.main.scale
                        )
                    }
                } else {
                    // Fallback: capture current anchor if no refresh anchor
                    capturedAnchor = optimizedScrollSystem.capturePreciseAnchor(
                        from: collectionView,
                        preferredIndexPath: nil
                    )
                }
            } else {
                // Non-chronological feeds: no scroll preservation on refresh
                capturedAnchor = nil
                controllerLogger.debug("🔄 Non-chronological feed - will scroll to top after refresh")
                // Clear any existing new posts indicator since we're refreshing
                stateManager.clearNewPostsIndicator()
            }
            isRefreshing = true
            await stateManager.refresh()
            
            // Check if any new posts were actually loaded
            let newPostCount = stateManager.posts.count
            if newPostCount == oldPostCount && stateManager.currentFeedType.isChronological {
                // No new posts loaded - adjust anchor to show large title (only for chronological)
                capturedAnchor = adjustAnchorForLargeTitle(anchor: capturedAnchor)
                controllerLogger.debug("🔄 No new posts loaded - adjusted anchor for large title display")
            }
            
        case .loadMore:
            // For load more, capture current position before loading
            capturedAnchor = optimizedScrollSystem.capturePreciseAnchor(
                from: collectionView,
                preferredIndexPath: nil
            )
            await stateManager.loadMore()
            
        case .newPostsAtTop:
            // For new posts at top, capture current anchor before update
            capturedAnchor = optimizedScrollSystem.capturePreciseAnchor(
                from: collectionView,
                preferredIndexPath: nil
            )
            await stateManager.smartRefresh()
            
        case .memoryWarning:
            // Clear non-visible cells to free memory
            collectionView.visibleCells.forEach { cell in
                if let indexPath = collectionView.indexPath(for: cell),
                   !collectionView.indexPathsForVisibleItems.contains(indexPath) {
                    cell.contentConfiguration = nil
                }
            }
            
        case .feedSwitch:
            // Handle feed type changes
            break
            
        case .normalUpdate:
            // Standard update without special handling
            capturedAnchor = optimizedScrollSystem.capturePreciseAnchor(
                from: collectionView,
                preferredIndexPath: nil
            )
            break
            
        case .viewAppearance(let persistedState):
            if let state = persistedState {
                let restorationSucceeded = await restorePersistedState(state)
                if restorationSucceeded {
                    // Successful restoration - skip anchor-based restoration
                    return
                }
                // If restoration failed, continue to anchor-based restoration below
            }
        }
        
        // Apply the snapshot WITH position preservation to prevent visual flash
        await applyOptimizedSnapshotWithPreservation(anchor: capturedAnchor)
        
        // Check for gaps and load if needed (only for chronological feeds)
        if stateManager.currentFeedType.isChronological {
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems
            if !visibleIndexPaths.isEmpty {
                await gapLoadingManager.detectAndLoadGaps(
                    stateManager: stateManager,
                    visibleIndexPaths: visibleIndexPaths
                )
            }
        }
        
        // End refreshing if needed
        if isRefreshing {
            refreshControl.endRefreshing()
            isRefreshing = false
        }
    }
    
    @MainActor
    private func performStandardUpdate(type: UnifiedScrollPreservationPipeline.UpdateType) async {
        // Use the unified pipeline for older iOS versions
        let currentData = stateManager.posts.map { $0.id }
        
        // Perform the data operation
        switch type {
        case .refresh:
            isRefreshing = true
            await stateManager.refresh()
            
            // For non-chronological feeds, scroll to top after refresh
            if !stateManager.currentFeedType.isChronological {
                collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
                controllerLogger.debug("🔄 Non-chronological feed - scrolled to top after refresh")
            }
            
        case .loadMore:
            await stateManager.loadMore()
            
        case .memoryWarning:
            collectionView.reloadData()
            
        default:
            break
        }
        
        let newData = stateManager.posts.map { $0.id }
        
        // Create a string-based adapter for the unified pipeline
        let stringDataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            // Find the corresponding PostItem
            let postItem = PostItem(id: item)
            return self.dataSource.collectionView(collectionView, cellForItemAt: indexPath)
        }
        
        let result = await unifiedScrollPipeline.performUpdate(
            type: type,
            collectionView: collectionView,
            dataSource: stringDataSource,
            newData: newData,
            currentData: currentData,
            getPostId: { [weak self] indexPath in
                guard let self = self,
                      indexPath.item < self.stateManager.posts.count else { return nil }
                return self.stateManager.posts[indexPath.item].id
            }
        )
        
        if result.success {
            controllerLogger.debug("✅ Standard update completed: offset=\(result.finalOffset.debugDescription)")
        } else if let error = result.error {
            controllerLogger.error("❌ Update failed: \(error)")
        }
        
        if isRefreshing {
            refreshControl.endRefreshing()
            isRefreshing = false
        }
    }
    
    @available(iOS 18.0, *)
    @MainActor
    private func applyOptimizedSnapshotWithPreservation(anchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor?) async {
        var snapshot = NSDiffableDataSourceSnapshot<Section, PostItem>()
        snapshot.appendSections([.main])
        
        let items = stateManager.posts.map { PostItem(id: $0.id) }
        snapshot.appendItems(items, toSection: .main)
        
        if let anchor = anchor {
            let postIds = stateManager.posts.map { $0.id }
            
            // SIMPLIFIED APPROACH: Pre-calculate target offset using layout estimation
            // This avoids the complexity of UIUpdateLink timing issues
            var targetOffset: CGPoint?
            
            // Find where the anchor post will be in the new data
            if let newIndex = postIds.firstIndex(of: anchor.postId) {
                let newIndexPath = IndexPath(item: newIndex, section: 0)
                
                // Estimate the target position based on current layout
                if let currentFirstVisible = collectionView.indexPathsForVisibleItems.sorted().first,
                   let currentAttributes = collectionView.layoutAttributesForItem(at: currentFirstVisible) {
                    
                    // Calculate estimated position of anchor in new layout
                    let estimatedItemHeight = currentAttributes.frame.height
                    let estimatedItemY = CGFloat(newIndex) * estimatedItemHeight
                    let safeAreaTop = collectionView.adjustedContentInset.top
                    
                    // Calculate target offset to maintain viewport position
                    let targetOffsetY = estimatedItemY - anchor.viewportRelativeY
                    
                    // Clamp to valid bounds
                    let minOffset = -safeAreaTop
                    let maxEstimatedContentHeight = CGFloat(postIds.count) * estimatedItemHeight
                    let maxOffset = max(minOffset, maxEstimatedContentHeight - collectionView.bounds.height + safeAreaTop)
                    
                    targetOffset = CGPoint(
                        x: 0,
                        y: max(minOffset, min(targetOffsetY, maxOffset))
                    )
                }
            }
            
            // Apply both changes in a single, atomic operation
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            // Step 1: Apply the snapshot
            await dataSource.apply(snapshot, animatingDifferences: false)
            
            // Step 2: Immediately set target offset (estimated position)
            if let targetOffset = targetOffset {
                collectionView.setContentOffset(targetOffset, animated: false)
            }
            
            // Step 3: Force layout to get accurate positions
            collectionView.layoutIfNeeded()
            
            // Step 4: Fine-tune position with actual layout data
            if let finalTargetOffset = optimizedScrollSystem.calculateTargetOffset(
                for: anchor,
                newPostIds: postIds,
                in: collectionView
            ) {
                collectionView.setContentOffset(finalTargetOffset, animated: false)
            }
            
            CATransaction.commit()
            
            controllerLogger.debug("✅ Simplified atomic snapshot + scroll restoration completed")
            
        } else {
            // No anchor - just apply snapshot normally
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
        
        // Log the result
        if anchor != nil {
            controllerLogger.debug("✅ Applied snapshot with simplified position preservation")
        } else {
            controllerLogger.debug("✅ Applied snapshot without position preservation")
        }
    }
    
    @available(iOS 18.0, *)
    @MainActor
    private func applyOptimizedSnapshot() async {
        // Legacy method for cases without position preservation
        await applyOptimizedSnapshotWithPreservation(anchor: nil)
    }
    
    /// Adjusts the anchor to ensure large title is shown when no new posts are loaded
    @available(iOS 18.0, *)
    private func adjustAnchorForLargeTitle(anchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor?) -> OptimizedScrollPreservationSystem.PreciseScrollAnchor? {
        guard let anchor = anchor else { return nil }
        
        // Check if the user was near the top when they pulled to refresh
        let currentOffset = collectionView.contentOffset.y
        let safeAreaTop = collectionView.adjustedContentInset.top
        let largeTitleThreshold: CGFloat = -safeAreaTop + 100 // Threshold for showing large title
        
        // If user was near the top, adjust anchor to show large title
        if currentOffset <= largeTitleThreshold {
            controllerLogger.debug("📏 Adjusting anchor for large title: current offset \(currentOffset), threshold \(largeTitleThreshold)")
            
            // Create a modified anchor that forces large title display
            return OptimizedScrollPreservationSystem.PreciseScrollAnchor(
                indexPath: anchor.indexPath,
                postId: anchor.postId,
                contentOffset: CGPoint(x: 0, y: -safeAreaTop), // Force to large title position
                viewportRelativeY: max(anchor.viewportRelativeY, -safeAreaTop), // Ensure viewport shows navigation area
                itemFrameY: anchor.itemFrameY,
                itemHeight: anchor.itemHeight,
                visibleHeightInViewport: anchor.visibleHeightInViewport,
                timestamp: anchor.timestamp,
                displayScale: anchor.displayScale
            )
        }
        
        // If user was scrolled down, keep original anchor
        return anchor
    }
    
    // MARK: - Scroll Position Helpers
    
    private func captureCurrentAnchor() -> UnifiedScrollPreservationPipeline.ScrollAnchor {
        return UnifiedScrollPreservationPipeline.ScrollAnchor(from: collectionView)
    }
    
    private func scrollToTop(animated: Bool) {
        let topOffset = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        collectionView.setContentOffset(topOffset, animated: animated)
    }
    
    // MARK: - Persistence
    
    private func captureCurrentScrollState() -> PersistedScrollState? {
        guard let firstVisible = collectionView.indexPathsForVisibleItems.sorted().first,
              firstVisible.item < stateManager.posts.count else { return nil }
        
        let post = stateManager.posts[firstVisible.item]
        
        // Calculate how much the top post is scrolled out of the safe area
        // This should be the distance from the top of the safe area to the top of the post
        var offsetFromSafeArea: CGFloat = 0
        if let attributes = collectionView.layoutAttributesForItem(at: firstVisible) {
            let safeAreaTop = collectionView.adjustedContentInset.top
            let currentOffset = collectionView.contentOffset.y
            
            // Distance from safe area top to post top in content coordinates
            offsetFromSafeArea = attributes.frame.origin.y - (currentOffset + safeAreaTop)
        }
        
        return PersistedScrollState(
            postID: post.id,
            offsetFromTop: offsetFromSafeArea, // Now relative to safe area, not absolute viewport
            contentOffset: collectionView.contentOffset.y
        )
    }
    
    func savePersistedScrollState(force: Bool = false) {
        // Only save scroll state for chronological feeds
        guard stateManager.currentFeedType.isChronological else { return }
        
        guard let firstVisible = collectionView.indexPathsForVisibleItems.sorted().first,
              firstVisible.item < stateManager.posts.count else { return }
        
        let post = stateManager.posts[firstVisible.item]
        
        // Calculate how much the top post is scrolled out of the safe area
        var offsetFromSafeArea: CGFloat = 0
        if let attributes = collectionView.layoutAttributesForItem(at: firstVisible) {
            let safeAreaTop = collectionView.adjustedContentInset.top
            let currentOffset = collectionView.contentOffset.y
            
            // Distance from safe area top to post top in content coordinates
            offsetFromSafeArea = attributes.frame.origin.y - (currentOffset + safeAreaTop)
        }
        
        let state = PersistedScrollState(
            postID: post.id,
            offsetFromTop: offsetFromSafeArea, // Now relative to safe area
            contentOffset: collectionView.contentOffset.y
        )
        
        // Save to UserDefaults with timestamp
        let key = "feed_scroll_\(stateManager.currentFeedType.identifier)"
        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: key)
            UserDefaults.standard.set(Date(), forKey: "\(key)_timestamp")
            lastPersistedOffset = collectionView.contentOffset.y
            controllerLogger.debug("💾 Saved scroll position: post=\(post.id), offset=\(self.collectionView.contentOffset.y)")
        }
    }
    
    func loadPersistedScrollState() -> PersistedScrollState? {
        // Only load persisted state for chronological feeds
        guard stateManager.currentFeedType.isChronological else { return nil }
        
        let key = "feed_scroll_\(stateManager.currentFeedType.identifier)"
        
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedScrollState.self, from: data) else {
            return nil
        }
        
        // Check if state is too old (> 1 hour)
        if let timestamp = UserDefaults.standard.object(forKey: "\(key)_timestamp") as? Date {
            let age = Date().timeIntervalSince(timestamp)
            if age > 3600 { // 1 hour
                controllerLogger.debug("⏰ Persisted state too old (\(age)s), ignoring")
                return nil
            }
        }
        
        controllerLogger.debug("📖 Loaded persisted scroll state: post=\(state.postID)")
        return state
    }
    
    private func savePersistedScrollStateIfNeeded() {
        let currentOffset = collectionView.contentOffset.y
        let delta = abs(currentOffset - lastPersistedOffset)
        
        // Only save if scrolled significantly
        if delta > persistenceThreshold {
            savePersistedScrollState()
        }
    }
    
    @MainActor
    private func restorePersistedState(_ state: PersistedScrollState) async -> Bool {
        // Don't restore persisted state for non-chronological feeds
        guard stateManager.currentFeedType.isChronological else {
            controllerLogger.debug("⏭️ Skipping state restoration for non-chronological feed")
            return false
        }
        
        guard let index = stateManager.posts.firstIndex(where: { $0.id == state.postID }) else {
            controllerLogger.warning("⚠️ Could not find persisted post \(state.postID) - using smart fallback")
            // Instead of failing completely, try to restore approximate position
            await restoreApproximatePosition(contentOffset: state.contentOffset)
            return false
        }
        
        let indexPath = IndexPath(item: index, section: 0)
        
        // Ensure the collection view has data before trying to access it
        guard collectionView.numberOfSections > 0 else {
            controllerLogger.warning("⚠️ Collection view has no sections yet - deferring restoration")
            return false
        }
        
        // Wait for layout if needed
        if collectionView.numberOfItems(inSection: 0) == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Check again after waiting
            guard collectionView.numberOfSections > 0 && 
                  collectionView.numberOfItems(inSection: 0) > index else {
                controllerLogger.warning("⚠️ Collection view not ready after wait - using fallback")
                await restoreApproximatePosition(contentOffset: state.contentOffset)
                return false
            }
        }
        
        // Get the item's attributes
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            controllerLogger.warning("⚠️ No attributes for item at \(indexPath) - using smart fallback")
            // Fallback to approximate position based on saved content offset
            await restoreApproximatePosition(contentOffset: state.contentOffset)
            return false
        }
        
        // Calculate target offset to restore exact position relative to safe area
        let safeAreaTop = collectionView.adjustedContentInset.top
        let targetOffset = attributes.frame.origin.y - safeAreaTop - state.offsetFromTop
        let safeOffset = clampOffsetToContent(targetOffset)
        
        // Apply the offset
        collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        
        controllerLogger.debug("✅ Restored scroll position to post \(state.postID) at offset \(safeOffset)")
        return true
    }
    
    @MainActor
    private func restoreApproximatePosition(contentOffset: CGFloat) async {
        controllerLogger.debug("🔄 Attempting approximate position restoration to offset \(contentOffset)")
        
        // Wait for layout completion to ensure content size is accurate
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Use the saved content offset, but ensure it's within valid bounds
        let safeOffset = clampOffsetToContent(contentOffset)
        
        // Apply the offset - this maintains position relative to content, not absolute top
        collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        
        controllerLogger.debug("✅ Restored approximate position at offset \(safeOffset)")
    }
    
    private func clampOffsetToContent(_ offsetY: CGFloat) -> CGFloat {
        let contentInset = collectionView.adjustedContentInset
        let minOffset = -contentInset.top  // Allow scrolling above content (shows toolbar)
        let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        
        return max(minOffset, min(offsetY, maxOffset))
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        // Save final position
        savePersistedScrollState(force: true)
        
        // Unregister from iOS 18+ state restoration coordinator
        if #available(iOS 18.0, *) {
            let identifier = "feed_controller_\(stateManager.currentFeedType.identifier)"
            iOS18StateRestorationCoordinator.shared.unregisterController(identifier: identifier)
            controllerLogger.debug("❌ Unregistered from iOS 18+ restoration coordinator: \(identifier)")
        }
        
        // Cancel tasks
        observationTask?.cancel()
        loadMoreTask?.cancel()
        
        // Stop timers
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        
        // Remove observers
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Clean up iOS 18+ resources
        if #available(iOS 18.0, *) {
            optimizedScrollSystem.cleanup()
        }
    }
    
    deinit {
        // Remove theme observer
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ThemeChanged"), object: nil)
        cleanup()
    }
}

// MARK: - UICollectionViewDelegate

extension FeedCollectionViewControllerIntegrated: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        onScrollOffsetChanged?(offset)
        
        // Capture anchor during pull-to-refresh gesture
        if scrollView.isTracking && offset < -50 && pullToRefreshAnchor == nil {
            pullToRefreshAnchor = captureCurrentAnchor()
            controllerLogger.debug("📍 Captured pull-to-refresh anchor at offset: \(offset)")
        }
        
        // Check for load more trigger
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.height
        let triggerPoint = contentHeight - frameHeight * 2
        
        if offset > triggerPoint && !stateManager.isLoading && !stateManager.hasReachedEnd {
            Task { @MainActor in
                await performLoadMore()
            }
        }
        
        // Dismiss new posts indicator when scrolled to top
        // But only if user is manually scrolling (not during programmatic scrolls)
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            if stateManager.shouldDismissNewPostsIndicator(for: offset) {
                controllerLogger.debug("🔴 NEW_POSTS_INDICATOR: Dismissing indicator due to scroll to top - offset: \(offset)")
                stateManager.clearNewPostsIndicator()
            }
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Save scroll position for restoration
        savePersistedScrollState()
        
        // Preload content to prevent gaps (only for chronological feeds)
        if #available(iOS 18.0, *), stateManager.currentFeedType.isChronological {
            Task { @MainActor in
                let visibleRange = collectionView.indexPathsForVisibleItems
                    .map { $0.item }
                    .reduce(into: (min: Int.max, max: Int.min)) { result, item in
                        result.min = min(result.min, item)
                        result.max = max(result.max, item)
                    }
                
                guard visibleRange.min != Int.max else { return }
                
                let range = visibleRange.min..<(visibleRange.max + 1)
                let direction: FeedGapLoadingManager.ScrollDirection = {
                    let currentOffset = scrollView.contentOffset.y
                    let lastOffset = scrollView.contentOffset.y - scrollView.contentInset.top
                    if currentOffset > lastOffset {
                        return .down
                    } else if currentOffset < lastOffset {
                        return .up
                    } else {
                        return .none
                    }
                }()
                
                await gapLoadingManager.preloadToPreventGaps(
                    stateManager: stateManager,
                    scrollDirection: direction,
                    visibleRange: range
                )
            }
        }
    }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension FeedCollectionViewControllerIntegrated: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Trigger load more if approaching end
        let maxItem = indexPaths.map { $0.item }.max() ?? 0
        let totalItems = stateManager.posts.count
        
        if maxItem > totalItems - 10 && !stateManager.isLoading && !stateManager.hasReachedEnd {
            Task { @MainActor in
                await performLoadMore()
            }
        }
    }
}

// PersistedScrollState already conforms to Codable in UnifiedScrollPreservationPipeline.swift
