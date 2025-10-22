//
//  FeedCollectionViewControllerIntegrated.swift
//  Catbird
//
//  High-performance UIKit feed controller with SwiftUI cell hosting
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
import Petrel
import os

#if os(iOS)
@available(iOS 16.0, *)
final class FeedCollectionViewControllerIntegrated: UIViewController {
    // MARK: - Types
    
    private enum Section: Int, CaseIterable { case main }
    private enum Item: Hashable { case header; case post(String) }
    
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
    
    /// State observation with proper @Observable integration
    var stateObserver: UIKitStateObserver<FeedStateManager>?
    
    /// Theme manager observation
    var themeObserver: UIKitStateObserver<ThemeManager>?
    
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
        themeObserver = UIKitStateObserver(observing: stateManager.appState.themeManager) { [weak self] _ in
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
        updateBackgroundState()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Update theme colors when view appears to catch any missed theme changes
        updateThemeColors()
        
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
        loadMoreTask?.cancel()
        
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
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func createLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        
        // Keep list configuration transparent so SwiftUI can own the background
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false // Disable UIKit separators - let SwiftUI handle them
        
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
            let showMoreAction = UIContextualAction(style: .normal, title: nil) { [weak self] action, view, completion in
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
            let showLessAction = UIContextualAction(style: .normal, title: nil) { [weak self] action, view, completion in
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
        let postRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, postId in
            guard let self = self,
                  let post = self.stateManager.posts.first(where: { $0.id == postId }) else {
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
            cell.contentConfiguration = UIHostingConfiguration {
                FeedPostRow(
                    viewModel: viewModel,
                    navigationPath: self.navigationPath,
                    feedTypeIdentifier: self.stateManager.currentFeedType.identifier
                )
                .environment(appState)
                .environment(\.fontManager, appState.fontManager)
                .padding(0)
                .background(Color.clear)
            }
            .margins(.all, 0)
            
            // Remove cell state handler to reduce memory overhead
            cell.configurationUpdateHandler = nil
        }
        // Registration for header cell
        let headerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { [weak self] cell, indexPath, _ in
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
                return collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: ())
            case .post(let id):
                return collectionView.dequeueConfiguredReusableCell(using: postRegistration, for: indexPath, item: id)
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
                return collectionView.dequeueConfiguredReusableSupplementary(using: emptyHeaderReg, for: indexPath)
            case UICollectionView.elementKindSectionFooter:
                return collectionView.dequeueConfiguredReusableSupplementary(using: emptyFooterReg, for: indexPath)
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

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        // Prepend header cell when available
        if headerView != nil {
            snapshot.appendItems([.header], toSection: .main)
        }
        let items = stateManager.posts.map { Item.post($0.id) }
        snapshot.appendItems(items, toSection: .main)

        await dataSource.apply(snapshot, animatingDifferences: false)

        controllerLogger.debug("✅ Fast update complete - \\(items.count) items")
        updateBackgroundState()
    }
    
    @MainActor
    func loadInitialData() async {
        controllerLogger.debug("📥 Loading initial data")
        await stateManager.loadInitialData()
        await performUpdate()
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
        }
        stateObserver?.startObserving()
    }
    
    private func setupScrollToTopCallback() {
        // Note: scrollToTop functionality will be handled differently
        // as setScrollToTopCallback was part of scroll preservation system
    }
    
    private func scrollToTop() {
        guard !stateManager.posts.isEmpty else { return }
        
        let indexPath = IndexPath(item: 0, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
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
              let postIndex = stateManager.index(of: anchor.postID) else {
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
                collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height
            )
            let clampedY = min(max(adjustedOffset.y, minOffsetY), maxOffsetY)
            let clampedOffset = CGPoint(x: adjustedOffset.x, y: clampedY)
            
            collectionView.setContentOffset(clampedOffset, animated: false)
            self.controllerLogger.debug("📍 Restored scroll position for post: \(anchor.postID), offset: \(anchor.offsetFromTop)")
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
        loadMoreTask?.cancel()
    }
    
    private func handleAppWillEnterForeground() {
        controllerLogger.debug("📱 App entering foreground")
        isAppInBackground = false
    }
    
    // MARK: - State Manager Updates
    
    func updateStateManager(_ newStateManager: FeedStateManager) {
        guard newStateManager !== stateManager else { return }
        
        controllerLogger.info("🔄 Fast switching state manager: \\(self.stateManager.currentFeedType.identifier) → \\(newStateManager.currentFeedType.identifier)")
        
        // Capture scroll position for the current feed before switching
        captureCurrentScrollPosition()
        
        // Cancel ongoing operations
        loadMoreTask?.cancel()
        stateObserver?.stopObserving()
        themeObserver?.stopObserving()
        
        // Update the state manager
        stateManager = newStateManager
        
        // Restart observations
        setupObservers()
        setupScrollToTopCallback()
        setupThemeObserver()
        
        // Load fresh data for new feed
        Task { @MainActor in
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
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Track post visibility for feed feedback (interaction seen)
        if indexPath.item < stateManager.posts.count {
            let postViewModel = stateManager.posts[indexPath.item]
            if let postURI = try? ATProtocolURI(uriString: postViewModel.feedViewPost.post.uri.uriString()) {
                stateManager.appState.feedFeedbackManager.trackPostSeen(postURI: postURI)
            }
        }
        
        // Trigger load more when approaching the end
        let totalItems = stateManager.posts.count
        if indexPath.item >= totalItems - 5 {
            Task { @MainActor in
                if !stateManager.posts.isEmpty {
                    await stateManager.loadMore()
                }
            }
        }
        
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
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Prefetch content for upcoming cells
        for indexPath in indexPaths {
            if indexPath.item < stateManager.posts.count {
                let post = stateManager.posts[indexPath.item]
                // Prefetch images or other content if needed
                _ = post // Use post for prefetching
            }
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
