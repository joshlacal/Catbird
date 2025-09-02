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
    
    /// Load more coordination
    var loadMoreTask: Task<Void, Never>?
    
    /// State observation with proper @Observable integration
    var stateObserver: UIKitStateObserver<FeedStateManager>?
    
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
    
    private func updateThemeColors() {
        let currentScheme = getCurrentColorScheme()
        let dynamicBackgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: currentScheme))
        
        collectionView?.backgroundColor = dynamicBackgroundColor
        view.backgroundColor = dynamicBackgroundColor
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        updateThemeColors()
        setupCollectionView()
        setupDataSource()
        setupRefreshControl()
        setupObservers()
        setupScrollToTopCallback()
        setupAppLifecycleObservers()
        setupThemeObserver()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
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
    
    // MARK: - Collection View Setup
    
    private func setupCollectionView() {
        let layout = createLayout()
        
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: getCurrentColorScheme()))
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
        
        // Match legacy controller's configuration exactly
        configuration.backgroundColor = UIColor(Color.dynamicBackground(stateManager.appState.themeManager, currentScheme: getCurrentColorScheme()))
        configuration.showsSeparators = false // Disable UIKit separators - let SwiftUI handle them
        
        // Configure header/footer
        configuration.headerMode = .none
        configuration.footerMode = .none
        
        // Remove default swipe actions that can add margins
        configuration.leadingSwipeActionsConfigurationProvider = nil
        configuration.trailingSwipeActionsConfigurationProvider = nil
        
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        
        return layout
    }
    
    private func setupDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, PostItem> { [weak self] cell, indexPath, item in
            guard let self = self,
                  let post = self.stateManager.posts.first(where: { $0.id == item.id }) else {
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
            
            // Configure cell with UIHostingConfiguration
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
            
            // Remove cell state handler to reduce memory overhead
            cell.configurationUpdateHandler = nil
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
    
    @objc private func handleRefresh() {
        Task { @MainActor in
            controllerLogger.debug("🔄 Fast refresh triggered")
            isRefreshing = true
            
            await stateManager.refresh()
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
        
        controllerLogger.debug("🔄 Fast update: Creating snapshot")
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, PostItem>()
        snapshot.appendSections([.main])
        
        let items = stateManager.posts.map { PostItem(id: $0.id) }
        snapshot.appendItems(items, toSection: .main)
        
        await dataSource.apply(snapshot, animatingDifferences: false)
        
        if isRefreshing {
            refreshControl.endRefreshing()
            isRefreshing = false
        }
        
        controllerLogger.debug("✅ Fast update complete - \\(items.count) items")
    }
    
    @MainActor
    func loadInitialData() async {
        controllerLogger.debug("📥 Loading initial data")
        await stateManager.loadInitialData()
        await performUpdate()
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
        
        // Update the state manager
        stateManager = newStateManager
        
        // Restart observations
        setupObservers()
        setupScrollToTopCallback()
        
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
