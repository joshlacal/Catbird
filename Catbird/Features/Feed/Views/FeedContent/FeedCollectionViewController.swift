////
////  FeedCollectionViewController.swift
////  Catbird
////
////  Created by Claude on 7/18/25.
////
////  UIKit performance layer using UIHostingConfiguration with @Observable state management
////
//
//import UIKit
//import SwiftUI
//import Petrel
//import os
//
//@available(iOS 16.0, *)
//final class FeedCollectionViewController: UIViewController {
//    // MARK: - Types
//    
//    private enum Section: Int, CaseIterable {
//        case main = 0
//    }
//    
//    private struct PostItem: Hashable {
//        let id: String
//        
//        func hash(into hasher: inout Hasher) {
//            hasher.combine(id)
//        }
//        
//        static func == (lhs: PostItem, rhs: PostItem) -> Bool {
//            lhs.id == rhs.id
//        }
//    }
//    
//    // MARK: - Properties
//    
//    var collectionView: UICollectionView!
//    private var dataSource: UICollectionViewDiffableDataSource<Section, PostItem>!
//    private var refreshControl: UIRefreshControl!
//    
//    /// State management
//    let stateManager: FeedStateManager
//    
//    /// Navigation
//    private let navigationPath: Binding<NavigationPath>
//    
//    /// Scroll state tracking
//    private var lastContentOffset: CGPoint = .zero
//    private var isUpdatingData = false
//    
//    /// Load more coordination
//    private var loadMoreTask: Task<Void, Never>?
//    
//    /// State observation task
//    private var observationTask: Task<Void, Never>?
//    
//    /// Callbacks
//    private let onScrollOffsetChanged: ((CGFloat) -> Void)?
//    
//    /// Scroll position preservation
//    let scrollTracker = ScrollPositionTracker()
//    private let persistentScrollManager = PersistentScrollStateManager.shared
//    private var isRefreshing = false
//    private var lastUpdateTime = Date.distantPast
//    private let updateDebounceInterval: TimeInterval = 0.15
//    
//    // MARK: - Performance & Logging
//    
//    private let controllerLogger = Logger(subsystem: "blue.catbird", category: "FeedCollectionViewController")
//    
//    // MARK: - Initialization
//    
//    init(
//        stateManager: FeedStateManager,
//        navigationPath: Binding<NavigationPath>,
//        onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
//    ) {
//        self.stateManager = stateManager
//        self.navigationPath = navigationPath
//        self.onScrollOffsetChanged = onScrollOffsetChanged
//        
//        super.init(nibName: nil, bundle: nil)
//    }
//    
//    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//    
//    // MARK: - Lifecycle
//    
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        
//        // Setup state restoration (use stable identifier)
//        self.restorationIdentifier = "FeedCollectionViewController_\(stateManager.currentFeedType.identifier.hash)"
//        self.restorationClass = FeedCollectionViewController.self
//        
//        setupCollectionView()
//        setupDataSource()
//        setupRefreshControl()
//        setupMemoryWarningObserver()
//        setupObservers()
//        
//        // Apply initial snapshot
//        applySnapshot(animated: false)
//        
//        controllerLogger.debug("FeedCollectionViewController loaded")
//    }
//    
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//        
//        // Ensure proper navigation bar behavior
//        navigationController?.navigationBar.prefersLargeTitles = true
//        navigationItem.largeTitleDisplayMode = .automatic
//    }
//    
//    override func viewDidDisappear(_ animated: Bool) {
//        super.viewDidDisappear(animated)
//        
//        // Cancel any ongoing tasks
//        loadMoreTask?.cancel()
//    }
//    
//    override func viewWillDisappear(_ animated: Bool) {
//        super.viewWillDisappear(animated)
//        
//        // Save current scroll position for persistence
//        saveScrollPositionForPersistence()
//        
//        // Proactively cancel tasks when view is disappearing
//        loadMoreTask?.cancel()
//        loadMoreTask = nil
//    }
//    
//    override func viewDidAppear(_ animated: Bool) {
//        super.viewDidAppear(animated)
//        
//        // Restore scroll position if we have persisted state
//        restorePersistedScrollPosition()
//    }
//    
//    // MARK: - Setup
//    
//    private func setupCollectionView() {
//        let layout = createLayout()
//        
//        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
//        collectionView.translatesAutoresizingMaskIntoConstraints = false
//        collectionView.backgroundColor = .systemBackground
//        collectionView.delegate = self
//        
//        // Remove all margins and insets
//        collectionView.layoutMargins = .zero
//        collectionView.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
//        collectionView.contentInset = .zero
//        
//        // Configure behavior
//        collectionView.contentInsetAdjustmentBehavior = .automatic
//        collectionView.alwaysBounceVertical = true
//        collectionView.keyboardDismissMode = .onDrag
//        collectionView.showsVerticalScrollIndicator = true
//        
//        // Performance optimizations
//        collectionView.isPrefetchingEnabled = true
//        
//        view.addSubview(collectionView)
//        
//        NSLayoutConstraint.activate([
//            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
//            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
//            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
//            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
//        ])
//    }
//    
//    private func createLayout() -> UICollectionViewLayout {
//        // Use list configuration for optimal performance with variable height cells
//        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
//        configuration.backgroundColor = .clear
//        configuration.showsSeparators = false // Handle separators in SwiftUI
//        
//        // Configure header/footer
//        configuration.headerMode = .none
//        configuration.footerMode = .none
//        
//        // Remove default swipe actions that can add margins
//        configuration.leadingSwipeActionsConfigurationProvider = nil
//        configuration.trailingSwipeActionsConfigurationProvider = nil
//        
//        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
//        
//        // Remove layout margins
//        layout.configuration.contentInsetsReference = .none
//        
//        return layout
//    }
//    
//    private func setupDataSource() {
//        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, PostItem> {
//            [weak self] cell, indexPath, item in
//            self?.configureCell(cell, with: item, at: indexPath)
//        }
//        
//        dataSource = UICollectionViewDiffableDataSource<Section, PostItem>(
//            collectionView: collectionView
//        ) { collectionView, indexPath, item in
//            collectionView.dequeueConfiguredReusableCell(
//                using: cellRegistration,
//                for: indexPath,
//                item: item
//            )
//        }
//    }
//    
//    private func configureCell(_ cell: UICollectionViewCell, with item: PostItem, at indexPath: IndexPath) {
//        // Check if view controller is being deallocated
//        guard !isBeingDismissed && !isMovingFromParent else {
//            controllerLogger.debug("Skipping cell configuration - view controller is being dismissed")
//            return
//        }
//        
//        guard let post = stateManager.post(withID: item.id) else {
//            controllerLogger.error("Failed to find post with ID: \(item.id)")
//            return
//        }
//        
//        // Reset cell margins
//        cell.layoutMargins = .zero
//        cell.directionalLayoutMargins = NSDirectionalEdgeInsets.zero
//        
//        // Get the persistent ViewModel
//        let viewModel = stateManager.viewModel(for: post)
//        
//        // Configure cell with UIHostingConfiguration - simplified to reduce memory pressure
//        cell.contentConfiguration = UIHostingConfiguration {
//            AnyView(
//                FeedPostRow(
//                    viewModel: viewModel,
//                    navigationPath: self.navigationPath
//                )
//                .padding(0)
//                .background(Color.clear)
//            )
//        }
//        .margins(.all, 0)
//        
//        // Remove cell state handler to reduce memory overhead
//        cell.configurationUpdateHandler = nil
//    }
//    
//    private func setupRefreshControl() {
//        refreshControl = UIRefreshControl()
//        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
//        collectionView.refreshControl = refreshControl
//    }
//    
//    private func setupMemoryWarningObserver() {
//        NotificationCenter.default.addObserver(
//            self,
//            selector: #selector(handleMemoryWarning),
//            name: UIApplication.didReceiveMemoryWarningNotification,
//            object: nil
//        )
//    }
//    
//    @objc private func handleMemoryWarning() {
//        controllerLogger.warning("Memory warning received in FeedCollectionViewController")
//        
//        // Clear non-visible cells
//        collectionView.visibleCells.forEach { cell in
//            cell.contentConfiguration = nil
//        }
//        
//        // Force garbage collection
//        collectionView.reloadData()
//    }
//    
//    private func setupObservers() {
//        // Start observing state changes
//        observationTask = Task { @MainActor [weak self] in
//            guard let self = self else { return }
//            
//            // Initial update if we have posts
//            if !self.stateManager.posts.isEmpty {
//                self.updateFromState()
//            }
//            
//            // Set up continuous observation
//            await self.observeStateChanges()
//        }
//    }
//    
//    @MainActor
//    private func observeStateChanges() async {
//        // Use withObservationTracking to detect changes to @Observable properties
//        while !Task.isCancelled {
//            do {
//                withObservationTracking {
//                    // Access the properties we want to observe
//                    _ = stateManager.posts.count
//                    _ = stateManager.loadingState
//                } onChange: {
//                    // Use weak self to prevent retain cycles
//                    Task { @MainActor [weak self] in
//                        guard let self = self, !Task.isCancelled else { return }
//                        self.updateFromState()
//                    }
//                }
//                
//                // Add delay to prevent excessive observation cycles
//                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
//            } catch {
//                // Task was cancelled
//                break
//            }
//        }
//    }
//    
//    // MARK: - Data Updates
//    
//    /// Updates the collection view from the state manager
//    @MainActor
//    func updateFromState() {
//        guard !isUpdatingData && !isRefreshing else {
//            controllerLogger.debug("🔒 SCROLL_DEBUG: updateFromState blocked - isUpdatingData=\(self.isUpdatingData), isRefreshing=\(self.isRefreshing)")
//            return
//        }
//        
//        let now = Date()
//        
//        // Debounce rapid updates to prevent scroll position jumps
//        if now.timeIntervalSince(lastUpdateTime) < updateDebounceInterval {
//            controllerLogger.debug("🔒 SCROLL_DEBUG: updateFromState debounced - last update \(now.timeIntervalSince(self.lastUpdateTime))s ago")
//            Task {
//                try? await Task.sleep(nanoseconds: UInt64(updateDebounceInterval * 1_000_000_000))
//                updateFromState()
//            }
//            return
//        }
//        lastUpdateTime = now
//        
//        // Log current scroll position before any changes
//        let currentOffset = collectionView.contentOffset
//        let contentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: updateFromState START - currentOffset=\(currentOffset.debugDescription), contentSize=\(contentSize.debugDescription)")
//        
//        isUpdatingData = true
//        defer {
//            isUpdatingData = false
//            let finalOffset = collectionView.contentOffset
//            controllerLogger.debug("📍 SCROLL_DEBUG: updateFromState END - finalOffset=\(finalOffset.debugDescription), delta=\(finalOffset.y - currentOffset.y)")
//        }
//        
//        // Detect if we have new posts at the top by comparing first post IDs
//        let currentSnapshot = dataSource.snapshot()
//        let currentPostItems = currentSnapshot.itemIdentifiers(inSection: .main)
//        
//        let currentFirstPostId = currentPostItems.first?.id
//        let newFirstPostId = stateManager.posts.first?.id
//        let currentPostCount = currentPostItems.count
//        let newPostCount = stateManager.posts.count
//        let hasNewPostsAtTop = currentFirstPostId != nil &&
//                              newFirstPostId != nil &&
//                              currentFirstPostId != newFirstPostId
//        
//        controllerLogger.debug("🔄 SCROLL_DEBUG: Post comparison - currentFirstId=\(currentFirstPostId ?? "nil"), newFirstId=\(newFirstPostId ?? "nil"), currentCount=\(currentPostCount), newCount=\(newPostCount), hasNewPostsAtTop=\(hasNewPostsAtTop)")
//        
//        if hasNewPostsAtTop {
//            // New posts detected at top - use sophisticated position preservation
//            controllerLogger.debug("🔄 SCROLL_DEBUG: New posts detected at top - using position preservation")
//            Task {
//                await updateDataWithPositionPreservation()
//            }
//        } else {
//            // No new posts at top - normal update
//            controllerLogger.debug("🔄 SCROLL_DEBUG: No new posts at top - using normal update")
//            applySnapshot(animated: false)
//        }
//    }
//    
//    @MainActor
//    private func updateDataWithPositionPreservation() async {
//        controllerLogger.debug("🔧 SCROLL_DEBUG: updateDataWithPositionPreservation START")
//        
//        // Log initial state
//        let initialOffset = collectionView.contentOffset
//        let initialContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: BEFORE - offset=\(initialOffset.debugDescription), contentSize=\(initialContentSize.debugDescription)")
//        
//        // Capture scroll anchor before update
//        let scrollAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)
//        
//        if let anchor = scrollAnchor {
//            controllerLogger.debug("⚓ SCROLL_DEBUG: Captured anchor - indexPath=\(anchor.indexPath), offsetY=\(anchor.offsetY), itemFrameY=\(anchor.itemFrameY)")
//        } else {
//            controllerLogger.debug("⚓ SCROLL_DEBUG: No anchor captured - scroll tracker not active or no visible cells")
//        }
//        
//        // Disable animations during update for smooth position preservation
//        CATransaction.begin()
//        CATransaction.setDisableActions(true)
//        
//        // Apply the snapshot
//        controllerLogger.debug("📊 SCROLL_DEBUG: Applying snapshot...")
//        applySnapshot(animated: false)
//        
//        // Log state after snapshot
//        let afterSnapshotOffset = collectionView.contentOffset
//        let afterSnapshotContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: AFTER SNAPSHOT - offset=\(afterSnapshotOffset.debugDescription), contentSize=\(afterSnapshotContentSize.debugDescription)")
//        
//        // Wait for layout
//        try? await Task.sleep(nanoseconds: 50_000_000)
//        
//        // Force layout if needed
//        collectionView.layoutIfNeeded()
//        
//        // Log state after layout
//        let afterLayoutOffset = collectionView.contentOffset
//        let afterLayoutContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: AFTER LAYOUT - offset=\(afterLayoutOffset.debugDescription), contentSize=\(afterLayoutContentSize.debugDescription)")
//        
//        // Restore scroll position if we have an anchor
//        if let anchor = scrollAnchor {
//            controllerLogger.debug("🔄 SCROLL_DEBUG: Attempting to restore position to anchor...")
//            scrollTracker.restoreScrollPosition(collectionView: collectionView, to: anchor)
//            
//            // Log final position
//            let finalOffset = collectionView.contentOffset
//            controllerLogger.debug("📍 SCROLL_DEBUG: AFTER RESTORE - offset=\(finalOffset.debugDescription), deltaFromInitial=\(finalOffset.y - initialOffset.y)")
//        } else {
//            controllerLogger.debug("🔄 SCROLL_DEBUG: No anchor to restore - position may jump")
//        }
//        
//        CATransaction.commit()
//        controllerLogger.debug("🔧 SCROLL_DEBUG: updateDataWithPositionPreservation COMPLETE")
//    }
//    
//    private func applySnapshot(animated: Bool) {
//        controllerLogger.debug("📊 SCROLL_DEBUG: applySnapshot START - animated=\(animated), isRefreshing=\(self.isRefreshing)")
//        
//        let beforeOffset = collectionView.contentOffset
//        let beforeContentSize = collectionView.contentSize
//        let currentItemCount = dataSource.snapshot().itemIdentifiers.count
//        
//        var snapshot = NSDiffableDataSourceSnapshot<Section, PostItem>()
//        snapshot.appendSections([.main])
//        
//        let items = stateManager.posts.map { PostItem(id: $0.id) }
//        snapshot.appendItems(items, toSection: .main)
//        
//        // Always disable animations during refreshing to prevent scroll jumps
//        let shouldAnimate = animated && !isRefreshing
//        
//        controllerLogger.debug("📊 SCROLL_DEBUG: Snapshot details - currentItems=\(currentItemCount), newItems=\(items.count), shouldAnimate=\(shouldAnimate)")
//        controllerLogger.debug("📍 SCROLL_DEBUG: Before apply - offset=\(beforeOffset.debugDescription), contentSize=\(beforeContentSize.debugDescription)")
//        
//        dataSource.apply(snapshot, animatingDifferences: shouldAnimate)
//        
//        let afterOffset = collectionView.contentOffset
//        let afterContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: After apply - offset=\(afterOffset.debugDescription), contentSize=\(afterContentSize.debugDescription)")
//        controllerLogger.debug("📊 SCROLL_DEBUG: Applied snapshot with \(items.count) items (animated: \(shouldAnimate))")
//    }
//    
//    // MARK: - Scroll Position Preservation
//    
//    private func preserveScrollPositionDuringUpdate(operation: @escaping () -> Void) {
//        Task { @MainActor in
//            // Capture current scroll state
//            let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
//            let contentOffset = collectionView.contentOffset
//            
//            // Find scroll anchor
//            var scrollAnchor: FeedStateManager.ScrollAnchor?
//            
//            if let firstVisibleIndexPath = visibleIndexPaths.first,
//               let cell = collectionView.cellForItem(at: firstVisibleIndexPath),
//               firstVisibleIndexPath.item < stateManager.posts.count {
//                
//                let post = stateManager.posts[firstVisibleIndexPath.item]
//                let cellFrame = collectionView.convert(cell.frame, to: collectionView)
//                let offsetFromTop = cellFrame.minY - collectionView.contentOffset.y
//                
//                scrollAnchor = FeedStateManager.ScrollAnchor(
//                    postID: post.id,
//                    offsetFromTop: offsetFromTop,
//                    timestamp: Date()
//                )
//            }
//            
//            // Perform the update
//            operation()
//            
//            // Wait for layout to complete
//            try? await Task.sleep(nanoseconds: 50_000_000)
//            
//            // Restore scroll position
//            if let anchor = scrollAnchor {
//                await restoreScrollPosition(anchor: anchor)
//            } else {
//                // Fallback: maintain approximate scroll position
//                let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
//                let clampedOffset = CGPoint(x: 0, y: min(contentOffset.y, maxY))
//                
//                if abs(collectionView.contentOffset.y - clampedOffset.y) > 1 {
//                    collectionView.setContentOffset(clampedOffset, animated: false)
//                }
//            }
//        }
//    }
//    
//    @MainActor
//    private func restoreScrollPosition(anchor: FeedStateManager.ScrollAnchor) async {
//        guard let postIndex = stateManager.index(of: anchor.postID) else {
//            controllerLogger.debug("Could not find anchor post \(anchor.postID) for scroll restoration")
//            return
//        }
//        
//        let indexPath = IndexPath(item: postIndex, section: 0)
//        
//        // Wait for layout attributes to be available
//        var attempts = 0
//        while attempts < FeedConstants.maxScrollRestorationAttempts {
//            if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
//                let targetOffset = CGPoint(
//                    x: 0,
//                    y: max(0, attributes.frame.minY - anchor.offsetFromTop)
//                )
//                
//                // Only adjust if the change is significant
//                let currentOffset = collectionView.contentOffset
//                if abs(currentOffset.y - targetOffset.y) > FeedConstants.scrollRestorationVerificationThreshold {
//                    collectionView.setContentOffset(targetOffset, animated: false)
//                    controllerLogger.debug("Restored scroll position to post \(anchor.postID)")
//                }
//                return
//            }
//            
//            attempts += 1
//            try? await Task.sleep(nanoseconds: 100_000_000)
//        }
//        
//        controllerLogger.warning("Failed to restore scroll position after \(attempts) attempts")
//    }
//    
//    // MARK: - Actions
//    
//    /// Stores the scroll anchor captured when pull-to-refresh begins
//    private var pullToRefreshAnchor: ScrollPositionTracker.ScrollAnchor?
//    
//    @objc private func handleRefresh() {
//        controllerLogger.debug("🔄 SCROLL_DEBUG: handleRefresh triggered")
//        Task { @MainActor in
//            // Use the advanced refresh method for better position preservation
//            await performAdvancedRefreshWithPositionPreservation()
//            refreshControl.endRefreshing()
//            // Clear the pull-to-refresh anchor after use
//            pullToRefreshAnchor = nil
//        }
//    }
//    
//    @MainActor
//    private func performRefreshWithPositionPreservation() async {
//        guard !isRefreshing else { return }
//        
//        controllerLogger.debug("Starting pull-to-refresh with position preservation")
//        
//        // Capture scroll position before refresh
//        let scrollAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)
//        
//        isRefreshing = true
//        
//        // Perform the actual refresh
//        await stateManager.refresh()
//        
//        // Restore scroll position if we have an anchor
//        if let anchor = scrollAnchor {
//            // Wait for layout to complete
//            try? await Task.sleep(nanoseconds: 50_000_000)
//            
//            await restoreScrollPositionAfterRefresh(anchor: anchor)
//        }
//        
//        isRefreshing = false
//        controllerLogger.debug("Pull-to-refresh completed")
//    }
//    
//    @MainActor
//    private func restoreScrollPositionAfterRefresh(anchor: ScrollPositionTracker.ScrollAnchor) async {
//        // Give the collection view time to update
//        var attempts = 0
//        let maxAttempts = 10
//        
//        while attempts < maxAttempts {
//            // Force layout calculation
//            collectionView.layoutIfNeeded()
//            
//            // Try to restore position
//            scrollTracker.restoreScrollPosition(collectionView: collectionView, to: anchor)
//            
//            // Check if restoration was successful
//            let currentOffset = collectionView.contentOffset.y
//            if abs(currentOffset - anchor.offsetY) < 50 { // Within reasonable range
//                controllerLogger.debug("Scroll position restored successfully after \(attempts + 1) attempts")
//                break
//            }
//            
//            attempts += 1
//            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
//        }
//        
//        if attempts >= maxAttempts {
//            controllerLogger.warning("Failed to restore scroll position after \(maxAttempts) attempts")
//        }
//    }
//    
//    // MARK: - Advanced Position Preservation
//    
//    /// Updates data with new posts at the top while preserving scroll position
//    /// This is the sophisticated logic ported from the old UIKitFeedView
//    @MainActor
//    private func updateDataWithNewPostsAtTop(
//        originalAnchor: ScrollPositionTracker.ScrollAnchor,
//        originalPostsCount: Int,
//        hasNewPosts: Bool = true
//    ) async {
//        controllerLogger.debug("🔧 SCROLL_DEBUG: updateDataWithNewPostsAtTop START (hasNewPosts: \(hasNewPosts))")
//        
//        // Store the current content offset and anchor item info
//        let oldContentOffsetY = collectionView.contentOffset.y
//        let anchorIndexPath = originalAnchor.indexPath
//        
//        controllerLogger.debug("📍 SCROLL_DEBUG: SOPHISTICATED - oldContentOffsetY=\(oldContentOffsetY), anchorIndexPath=\(anchorIndexPath)")
//        
//        // Find the anchor post ID in the current data
//        guard anchorIndexPath.section == Section.main.rawValue && anchorIndexPath.item < stateManager.posts.count else {
//            controllerLogger.warning("🚨 SCROLL_DEBUG: Invalid anchor index - section=\(anchorIndexPath.section), item=\(anchorIndexPath.item), postsCount=\(self.stateManager.posts.count)")
//            await updateDataWithPositionPreservation()
//            return
//        }
//        
//        let anchorPostId = stateManager.posts[anchorIndexPath.item].id
//        let originalFirstPostId = stateManager.posts.first?.id
//        controllerLogger.debug("⚓ SCROLL_DEBUG: SOPHISTICATED - anchorPostId=\(anchorPostId), originalFirstPostId=\(originalFirstPostId ?? "nil")")
//        
//        // Get the current posts from state manager - these are the posts AFTER refresh
//        let currentPosts = stateManager.posts
//        let newFirstPostId = currentPosts.first?.id
//        
//        controllerLogger.debug("📊 SCROLL_DEBUG: Posts before refresh: \(self.stateManager.posts.count), anchor was at index \(anchorIndexPath.item)")
//        
//        // Calculate how many new posts were added at the top
//        var newPostsCount = 0
//        
//        // Find where our original anchor post ended up in the new data
//        if let newAnchorPosition = currentPosts.firstIndex(where: { $0.id == anchorPostId }) {
//            // The anchor post's new position tells us how many posts were added before it
//            if anchorIndexPath.item == 0 {
//                // User was at the top - all posts before the anchor in new position are new
//                newPostsCount = newAnchorPosition
//                controllerLogger.debug("🔢 SCROLL_DEBUG: User was at top (index 0), anchor moved to \(newAnchorPosition), so \(newPostsCount) new posts added")
//            } else {
//                // User wasn't at top - calculate difference in position
//                newPostsCount = max(0, newAnchorPosition - anchorIndexPath.item)
//                controllerLogger.debug("🔢 SCROLL_DEBUG: Anchor moved from \(anchorIndexPath.item) to \(newAnchorPosition), so \(newPostsCount) new posts added")
//            }
//        } else {
//            // Anchor post not found - this means the post was replaced or removed
//            // When user was at top and first post changed, treat this as new posts at top
//            if anchorIndexPath.item == 0 && originalFirstPostId != newFirstPostId {
//                // All posts are effectively "new" since the original anchor is gone
//                newPostsCount = currentPosts.count > 0 ? 1 : 0 // At least the first post is new
//                controllerLogger.debug("🔢 SCROLL_DEBUG: Anchor post (first post) not found and first post changed - treating as new posts at top, newPostsCount=\(newPostsCount)")
//            } else {
//                // Fallback to count difference
//                let totalCountIncrease = currentPosts.count - originalPostsCount
//                newPostsCount = max(0, totalCountIncrease)
//                controllerLogger.debug("🔢 SCROLL_DEBUG: Anchor post not found after refresh, using count difference: \(newPostsCount) (current: \(currentPosts.count), original: \(originalPostsCount))")
//            }
//        }
//        
//        // Find the anchor post in the new data
//        let newAnchorIndex: Int?
//        if hasNewPosts {
//            newAnchorIndex = currentPosts.firstIndex { $0.id == anchorPostId }
//            controllerLogger.debug("🔍 SCROLL_DEBUG: hasNewPosts=true, searching for anchor in new data - found at index=\(newAnchorIndex ?? -1)")
//        } else {
//            // Try to find by ID first, then by position if IDs are different (refreshed data)
//            newAnchorIndex = currentPosts.firstIndex { $0.id == anchorPostId }
//                ?? (anchorIndexPath.item < currentPosts.count ? anchorIndexPath.item : nil)
//            controllerLogger.debug("🔍 SCROLL_DEBUG: hasNewPosts=false, fallback search - found at index=\(newAnchorIndex ?? -1)")
//        }
//        
//        guard let newIndex = newAnchorIndex else {
//            controllerLogger.warning("🚨 SCROLL_DEBUG: Anchor post '\(anchorPostId)' not found in new data with \(currentPosts.count) posts")
//            await updateDataWithPositionPreservation()
//            return
//        }
//        
//        controllerLogger.debug("⚓ SCROLL_DEBUG: SOPHISTICATED - newAnchorIndex=\(newIndex), movement=\(newIndex - anchorIndexPath.item)")
//        
//        // Get current position of anchor item before update
//        guard let oldAnchorAttributes = collectionView.layoutAttributesForItem(at: anchorIndexPath) else {
//            controllerLogger.warning("🚨 SCROLL_DEBUG: Could not get anchor attributes for \(anchorIndexPath)")
//            await updateDataWithPositionPreservation()
//            return
//        }
//        
//        let oldAnchorY = oldAnchorAttributes.frame.origin.y
//        controllerLogger.debug("📐 SCROLL_DEBUG: SOPHISTICATED - oldAnchorY=\(oldAnchorY), anchorFrame=\(oldAnchorAttributes.frame.debugDescription)")
//        
//        // Create and apply snapshot without animation
//        var snapshot = NSDiffableDataSourceSnapshot<Section, PostItem>()
//        snapshot.appendSections([.main])
//        
//        let items = currentPosts.map { PostItem(id: $0.id) }
//        snapshot.appendItems(items, toSection: .main)
//        
//        controllerLogger.debug("📊 SCROLL_DEBUG: SOPHISTICATED - applying snapshot with \(items.count) items")
//        
//        // Disable animations during the update to prevent flicker
//        CATransaction.begin()
//        CATransaction.setDisableActions(true)
//        
//        // Apply snapshot without animation for position preservation
//        await dataSource.apply(snapshot, animatingDifferences: false)
//        
//        let afterSnapshotOffset = collectionView.contentOffset
//        controllerLogger.debug("📍 SCROLL_DEBUG: SOPHISTICATED - after snapshot apply, offset=\(afterSnapshotOffset.debugDescription)")
//        
//        // Just call performBatchUpdates without trying to make it async
//        collectionView.performBatchUpdates({ [weak self] in
//            // Force layout to calculate new positions
//            self?.collectionView.layoutIfNeeded()
//            let afterLayoutOffset = self?.collectionView.contentOffset ?? .zero
//            self?.controllerLogger.debug("📍 SCROLL_DEBUG: SOPHISTICATED - after layoutIfNeeded, offset=\(afterLayoutOffset.debugDescription)")
//        }) { [weak self] _ in
//            guard let self = self else { return }
//
//            // Calculate and apply position correction after layout is complete
//            let newAnchorIndexPath = IndexPath(item: newIndex, section: Section.main.rawValue)
//            
//            // Special handling for when user was at the very top
//            if anchorIndexPath.item == 0 {
//                if newPostsCount > 0 {
//                    // Case 1: User was at top and new posts were added
//                    self.controllerLogger.debug("🎯 SCROLL_DEBUG: Special case - user was at top, \(newPostsCount) new posts added")
//                    
//                    // Calculate the height of the new posts that were added
//                    var totalNewPostsHeight: CGFloat = 0
//                    for i in 0..<newPostsCount {
//                        let indexPath = IndexPath(item: i, section: Section.main.rawValue)
//                        if let attributes = self.collectionView.layoutAttributesForItem(at: indexPath) {
//                            totalNewPostsHeight += attributes.frame.height
//                            self.controllerLogger.debug("📏 SCROLL_DEBUG: New post \(i) height: \(attributes.frame.height)")
//                        }
//                    }
//                    
//                    self.controllerLogger.debug("📏 SCROLL_DEBUG: Total height of \(newPostsCount) new posts: \(totalNewPostsHeight)")
//                    
//                    // Apply offset to keep the original content in view (scroll down by the height of new posts)
//                    let targetOffset = totalNewPostsHeight
//                    let maxOffset = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
//                    let safeOffset = min(targetOffset, maxOffset)
//                    
//                    self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
//                    self.controllerLogger.debug("✅ SCROLL_DEBUG: Applied special case offset: \(safeOffset) to preserve view of original content")
//                } else {
//                    // Case 2: User was at top but no new posts detected by count - check if content actually changed
//                    let wasUserPulling = originalAnchor.offsetY < 0
//                    let firstPostChanged = originalFirstPostId != newFirstPostId
//                    
//                    if firstPostChanged && wasUserPulling {
//                        // Content changed even though count didn't increase - handle as new posts
//                        self.controllerLogger.debug("🎯 SCROLL_DEBUG: First post changed during pull-to-refresh - treating as new content")
//                        
//                        // For pixel-perfect restoration when content changed during pull-to-refresh
//                        if let firstPostAttributes = self.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
//                            // The user pulled down and the content changed - we want to preserve the visual position
//                            // Calculate where the new first post should appear to maintain the same visual position
//                            let originalVisualPosition = originalAnchor.itemFrameY - originalAnchor.offsetY
//                            let targetOffset = firstPostAttributes.frame.origin.y - originalVisualPosition
//                            
//                            // Since content changed, we might want to show they're at the "new" top
//                            // But still account for the pull distance to some degree
//                            let adjustedOffset = max(0, min(originalVisualPosition * 0.5, 50)) // Small offset to indicate new content
//                            
//                            let maxOffset = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
//                            let safeOffset = max(0, min(adjustedOffset, maxOffset))
//                            
//                            self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
//                            self.controllerLogger.debug("✅ SCROLL_DEBUG: Content-changed restoration - originalVisualPos=\(originalVisualPosition), applied=\(safeOffset)")
//                        } else {
//                            self.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
//                            self.controllerLogger.debug("✅ SCROLL_DEBUG: Content changed - staying at top")
//                        }
//                    } else if wasUserPulling {
//                        self.controllerLogger.debug("🎯 SCROLL_DEBUG: Pull-to-refresh case - user was at top with no new posts, originalOffset=\(originalAnchor.offsetY)")
//                        
//                        // For pixel-perfect restoration during pull-to-refresh, we need to restore the exact visual position
//                        if let firstPostAttributes = self.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
//                            let originalVisualPosition = originalAnchor.itemFrameY - originalAnchor.offsetY
//                            let targetOffset = firstPostAttributes.frame.origin.y - originalVisualPosition
//                            let maxOffset = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
//                            let safeOffset = max(0, min(targetOffset, maxOffset))
//                            
//                            self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
//                            self.controllerLogger.debug("✅ SCROLL_DEBUG: Pixel-perfect restoration - originalVisualPos=\(originalVisualPosition), targetOffset=\(targetOffset), applied=\(safeOffset)")
//                        } else {
//                            self.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
//                            self.controllerLogger.debug("✅ SCROLL_DEBUG: Fallback - staying at top")
//                        }
//                    } else {
//                        // User was genuinely at the top, keep them there
//                        self.collectionView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
//                        self.controllerLogger.debug("✅ SCROLL_DEBUG: User was genuinely at top - keeping at position 0")
//                    }
//                }
//                
//            } else if let newAnchorAttributes = self.collectionView.layoutAttributesForItem(at: newAnchorIndexPath) {
//                // Standard case - calculate based on anchor movement
//                let newAnchorY = newAnchorAttributes.frame.origin.y
//                let contentHeightAddedAbove = newAnchorY - oldAnchorY
//                
//                // Calculate new offset to maintain visual position
//                let newCalculatedOffsetY = oldContentOffsetY + contentHeightAddedAbove
//                
//                // Ensure within bounds
//                let contentHeight = self.collectionView.contentSize.height
//                let boundsHeight = self.collectionView.bounds.height
//                let maxPossibleOffsetY = max(0, contentHeight - boundsHeight)
//                let safeOffsetY = max(0, min(newCalculatedOffsetY, maxPossibleOffsetY))
//                
//                self.controllerLogger.debug("📐 SCROLL_DEBUG: SOPHISTICATED MATH - oldAnchorY=\(oldAnchorY), newAnchorY=\(newAnchorY), heightDelta=\(contentHeightAddedAbove)")
//                self.controllerLogger.debug("📐 SCROLL_DEBUG: SOPHISTICATED MATH - oldOffset=\(oldContentOffsetY), calculated=\(newCalculatedOffsetY), safe=\(safeOffsetY)")
//                self.controllerLogger.debug("📐 SCROLL_DEBUG: SOPHISTICATED MATH - contentHeight=\(contentHeight), boundsHeight=\(boundsHeight), maxOffset=\(maxPossibleOffsetY)")
//                
//                // Apply the corrected offset without animation
//                let beforeSetOffset = self.collectionView.contentOffset
//                self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffsetY), animated: false)
//                let afterSetOffset = self.collectionView.contentOffset
//                
//                self.controllerLogger.debug("📍 SCROLL_DEBUG: SOPHISTICATED - setContentOffset: before=\(beforeSetOffset.debugDescription), target=\(safeOffsetY), after=\(afterSetOffset.debugDescription)")
//                self.controllerLogger.debug("✅ SCROLL_DEBUG: Enhanced position preserved: anchor moved from y=\(oldAnchorY) to y=\(newAnchorY), delta=\(contentHeightAddedAbove), new offset=\(safeOffsetY)")
//            } else {
//                self.controllerLogger.warning("🚨 SCROLL_DEBUG: Could not restore position - anchor item not found after update at index \(newIndex)")
//            }
//            
//            // Re-enable animations
//            CATransaction.commit()
//        }
//
//        // Add a small delay after the batch updates if needed
//        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
//        
//        let finalOffset = collectionView.contentOffset
//        controllerLogger.debug("🔧 SCROLL_DEBUG: updateDataWithNewPostsAtTop COMPLETE - finalOffset=\(finalOffset.debugDescription)")
//    }
//    
//    /// Enhanced refresh method that uses the sophisticated position preservation
//    @MainActor
//    private func performAdvancedRefreshWithPositionPreservation() async {
//        guard !isRefreshing else {
//            controllerLogger.debug("🔒 SCROLL_DEBUG: performAdvancedRefreshWithPositionPreservation blocked - already refreshing")
//            return
//        }
//        
//        controllerLogger.debug("🔄 SCROLL_DEBUG: Starting advanced pull-to-refresh with position preservation")
//        
//        // Log initial scroll state
//        let initialOffset = collectionView.contentOffset
//        let initialContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: REFRESH START - offset=\(initialOffset.debugDescription), contentSize=\(initialContentSize.debugDescription)")
//        
//        // Store current posts count and state for comparison
//        let originalPostsCount = stateManager.posts.count
//        let originalFirstPostId = stateManager.posts.first?.id
//        let originalPosts = stateManager.posts.map { $0.id } // Store just IDs for comparison
//        
//        controllerLogger.debug("📊 SCROLL_DEBUG: Original state - count=\(originalPostsCount), firstId=\(originalFirstPostId ?? "nil")")
//        
//        // Use pre-captured anchor from pull-to-refresh, or capture now if not available
//        let scrollAnchor = pullToRefreshAnchor ?? scrollTracker.captureScrollAnchor(collectionView: collectionView)
//        
//        if let anchor = scrollAnchor {
//            controllerLogger.debug("⚓ SCROLL_DEBUG: REFRESH - Using anchor - indexPath=\(anchor.indexPath), offsetY=\(anchor.offsetY), itemFrameY=\(anchor.itemFrameY), isPullToRefresh=\(self.pullToRefreshAnchor != nil)")
//        } else {
//            controllerLogger.debug("⚓ SCROLL_DEBUG: REFRESH - No anchor captured")
//        }
//        
//        isRefreshing = true
//        lastUpdateTime = Date()
//        
//        // Disable automatic updates during refresh
//        isUpdatingData = true
//        
//        // Perform refresh to get new posts
//        controllerLogger.debug("🔄 SCROLL_DEBUG: Calling stateManager.refresh()...")
//        await stateManager.refresh()
//        
//        // Wait a moment for state to stabilize
//        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
//        
//        // Get updated posts
//        let newPosts = stateManager.posts
//        let newPostsCount = newPosts.count
//        let newFirstPostId = newPosts.first?.id
//        
//        controllerLogger.debug("📊 SCROLL_DEBUG: After refresh - count=\(newPostsCount), firstId=\(newFirstPostId ?? "nil")")
//        
//        // Re-enable updates
//        isUpdatingData = false
//        
//        // Check if we have new posts - any change in first post ID or count indicates new content
//        let firstPostChanged = originalFirstPostId != newFirstPostId
//        let countChanged = newPostsCount != originalPostsCount
//        let hasNewPosts = firstPostChanged || countChanged
//        let countDiff = newPostsCount - originalPostsCount
//        
//        controllerLogger.debug("🔄 SCROLL_DEBUG: firstPostChanged=\(firstPostChanged), countChanged=\(countChanged), hasNewPosts=\(hasNewPosts), countDiff=\(countDiff)")
//        
//        // Additional check: even if first post and count are same, check if post IDs changed
//        if !hasNewPosts {
//            let newPostIds = newPosts.map { $0.id }
//            let postsChanged = newPostIds != originalPosts
//            if postsChanged {
//                controllerLogger.debug("🔄 SCROLL_DEBUG: Post IDs changed despite same first post and count - treating as refresh with new content")
//            }
//        }
//        
//        if let anchor = scrollAnchor {
//            // We have a scroll anchor - use sophisticated position preservation
//            controllerLogger.debug("🔄 SCROLL_DEBUG: Using advanced scroll anchor for position preservation")
//            await updateDataWithNewPostsAtTop(originalAnchor: anchor, originalPostsCount: originalPostsCount, hasNewPosts: hasNewPosts)
//        } else if hasNewPosts && countDiff > 0 {
//            // No scroll anchor but we have new posts - user was at top, apply simple offset
//            controllerLogger.debug("🔄 SCROLL_DEBUG: No scroll anchor but new posts detected - applying simple height offset")
//            
//            // Apply snapshot first
//            applySnapshot(animated: false)
//            
//            // Wait for layout
//            try? await Task.sleep(nanoseconds: 50_000_000)
//            collectionView.layoutIfNeeded()
//            
//            // Calculate height of new posts and scroll down to preserve view
//            var totalNewHeight: CGFloat = 0
//            for i in 0..<min(countDiff, newPosts.count) {
//                let indexPath = IndexPath(item: i, section: Section.main.rawValue)
//                if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
//                    totalNewHeight += attributes.frame.height
//                }
//            }
//            
//            if totalNewHeight > 0 {
//                let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
//                let targetOffset = min(totalNewHeight, maxOffset)
//                collectionView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
//                controllerLogger.debug("🎯 SCROLL_DEBUG: Applied simple offset \(targetOffset) for \(countDiff) new posts with height \(totalNewHeight)")
//            }
//        } else {
//            // No scroll anchor and no new posts - simple update
//            controllerLogger.debug("🔄 SCROLL_DEBUG: No scroll anchor and no new posts - simple update")
//            applySnapshot(animated: false)
//        }
//        
//        isRefreshing = false
//        
//        let finalOffset = collectionView.contentOffset
//        let finalContentSize = collectionView.contentSize
//        controllerLogger.debug("📍 SCROLL_DEBUG: REFRESH END - offset=\(finalOffset.debugDescription), contentSize=\(finalContentSize.debugDescription), deltaFromStart=\(finalOffset.y - initialOffset.y)")
//        controllerLogger.debug("🔄 SCROLL_DEBUG: Advanced pull-to-refresh completed")
//    }
//    
//    
//    // MARK: - Persistent Scroll State Management
//    
//    /// Saves current scroll position for persistence across app suspensions
//    private func saveScrollPositionForPersistence() {
//        guard let firstVisibleIndexPath = collectionView.indexPathsForVisibleItems.sorted().first,
//              firstVisibleIndexPath.section == Section.main.rawValue,
//              firstVisibleIndexPath.item < stateManager.posts.count else {
//            return
//        }
//        
//        let post = stateManager.posts[firstVisibleIndexPath.item]
//        let currentOffset = collectionView.contentOffset.y
//        
//        // Calculate offset from the top of the first visible cell
//        guard let cell = collectionView.cellForItem(at: firstVisibleIndexPath) else {
//            return
//        }
//        
//        let cellFrame = collectionView.convert(cell.frame, to: collectionView)
//        let offsetFromTop = cellFrame.minY - collectionView.contentOffset.y
//        
//        // Get feed identifier
//        let feedIdentifier = stateManager.currentFeedType.identifier
//        
//        persistentScrollManager.saveScrollState(
//            feedIdentifier: feedIdentifier,
//            postID: post.id,
//            offsetFromTop: offsetFromTop,
//            contentOffset: currentOffset
//        )
//        
//        controllerLogger.debug("Saved persistent scroll state for feed: \(feedIdentifier), post: \(post.id)")
//    }
//    
//    /// Restores scroll position from persistent storage
//    private func restorePersistedScrollPosition() {
//        let feedIdentifier = stateManager.currentFeedType.identifier
//        
//        guard let scrollState = persistentScrollManager.loadScrollState(for: feedIdentifier),
//              let postIndex = stateManager.posts.firstIndex(where: { $0.id == scrollState.postID }) else {
//            controllerLogger.debug("No valid persistent scroll state found for feed: \(feedIdentifier)")
//            return
//        }
//        
//        controllerLogger.debug("Restoring persistent scroll state for feed: \(feedIdentifier), post: \(scrollState.postID)")
//        
//        // Create index path for the target post
//        let targetIndexPath = IndexPath(item: postIndex, section: Section.main.rawValue)
//        
//        // Wait for layout and then restore position
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
//            guard let self = self else { return }
//            
//            // Force layout calculation
//            self.collectionView.layoutIfNeeded()
//            
//            // Get the target cell frame
//            guard let cellAttributes = self.collectionView.layoutAttributesForItem(at: targetIndexPath) else {
//                return
//            }
//            
//            // Calculate the target scroll offset
//            let targetCellY = cellAttributes.frame.origin.y
//            let targetOffset = targetCellY - scrollState.offsetFromTop
//            
//            // Ensure the offset is within bounds
//            let maxOffset = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
//            let safeOffset = max(0, min(targetOffset, maxOffset))
//            
//            // Apply the scroll position
//            self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
//            
//            self.controllerLogger.debug("Restored persistent scroll position: offset=\(safeOffset)")
//        }
//    }
//    
//    /// Saves scroll position periodically during scrolling
//    private func saveScrollPositionPeriodically() {
//        // Save state periodically to handle unexpected app termination
//        saveScrollPositionForPersistence()
//    }
//    
//    private func handleLoadMore() {
//        // Check specific loading states - allow load more if not already loading more
//        let isCurrentlyLoadingMore = stateManager.loadingState == .loadingMore
//        
//        guard !isCurrentlyLoadingMore,
//              !stateManager.hasReachedEnd else {
//            controllerLogger.debug("handleLoadMore skipped - loadingMore: \(isCurrentlyLoadingMore), hasReachedEnd: \(self.stateManager.hasReachedEnd)")
//            return
//        }
//        
//        // Cancel any existing load more task
//        loadMoreTask?.cancel()
//        
//        loadMoreTask = Task { @MainActor in
//            // Debounce load more requests
//            try? await Task.sleep(nanoseconds: FeedConstants.loadMoreDebounceDelay)
//            
//            guard !Task.isCancelled else { return }
//            
//            await stateManager.loadMore()
//        }
//    }
//    
//    // MARK: - Cleanup
//    
//    deinit {
//        // Remove notification observers
//        NotificationCenter.default.removeObserver(self)
//        
//        // Cancel tasks immediately in deinit
//        loadMoreTask?.cancel()
//        loadMoreTask = nil
//        observationTask?.cancel()
//        observationTask = nil
//        
//        // Clear collection view
//        collectionView?.delegate = nil
//        collectionView?.dataSource = nil
//        
//        // Don't access @MainActor properties from deinit - this can cause crashes
//        // The stateManager cleanup should be handled by the parent view
//        controllerLogger.debug("FeedCollectionViewController deallocated")
//    }
//}
//
//// MARK: - UICollectionViewDelegate
//
//@available(iOS 16.0, *)
//extension FeedCollectionViewController: UICollectionViewDelegate {
//    
//    // MARK: - UIScrollViewDelegate methods for pull-to-refresh tracking
//    
//    func scrollViewDidScroll(_ scrollView: UIScrollView) {
//        // Handle pull-to-refresh anchor capture FIRST (most critical for position preservation)
//        if scrollView.contentOffset.y < -20 && pullToRefreshAnchor == nil && !isRefreshing {
//            // User is pulling to refresh - capture current position
//            pullToRefreshAnchor = scrollTracker.captureScrollAnchor(collectionView: collectionView)
//            if let anchor = pullToRefreshAnchor {
//                controllerLogger.debug("🎣 SCROLL_DEBUG: Captured pull-to-refresh anchor at offset=\(anchor.offsetY)")
//            }
//        }
//        
//        // Notify about scroll offset changes for navigation bar behavior
//        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
//        onScrollOffsetChanged?(offset)
//        
//        // Update last scroll offset
//        lastContentOffset = scrollView.contentOffset
//        
//        // Save scroll position periodically (throttled to avoid performance issues)
//        let now = Date()
//        if now.timeIntervalSince(lastUpdateTime) > 5.0 { // Save every 5 seconds max to reduce overhead
//            saveScrollPositionPeriodically()
//            lastUpdateTime = now
//        }
//    }
//    
//    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
//        // Handle pull-to-refresh anchor clearing
//        if !refreshControl.isRefreshing && pullToRefreshAnchor != nil {
//            controllerLogger.debug("🎣 SCROLL_DEBUG: Pull-to-refresh cancelled, clearing anchor")
//            pullToRefreshAnchor = nil
//        }
//        
//        // Capture scroll position when user stops dragging (if not decelerating)
//        if !decelerate {
//            captureScrollAnchor()
//        }
//    }
//        
//    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
//        // Trigger load more when approaching the end
//        let threshold = max(0, stateManager.posts.count - FeedConstants.loadMorePostThreshold)
//        if indexPath.item >= threshold {
//            controllerLogger.debug("Load more triggered at index \(indexPath.item) of \(self.stateManager.posts.count) posts")
//            handleLoadMore()
//        }
//        
//        // Additional check: if we're at the very last item and think we've reached the end,
//        // double-check by trying to load more (might have been filtered posts)
//        if indexPath.item == stateManager.posts.count - 1 &&
//           stateManager.hasReachedEnd &&
//           stateManager.loadingState == .idle {
//            controllerLogger.debug("At last item with hasReachedEnd=true, attempting retry")
//            // Reset and try once more in case all posts were filtered
//            stateManager.hasReachedEnd = false
//            handleLoadMore()
//        }
//    }
//    
//    
//    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
//        // Capture scroll position when scrolling stops
//        captureScrollAnchor()
//    }
//    
//    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
//        return true
//    }
//    
//    private func captureScrollAnchor() {
//        // Capture with both new ScrollPositionTracker and existing FeedStateManager
//        _ = scrollTracker.captureScrollAnchor(collectionView: collectionView)
//        
//        // Also capture for existing FeedStateManager compatibility
//        guard let firstVisibleIndexPath = collectionView.indexPathsForVisibleItems.sorted().first,
//              let cell = collectionView.cellForItem(at: firstVisibleIndexPath),
//              firstVisibleIndexPath.item < stateManager.posts.count else { return }
//        
//        let post = stateManager.posts[firstVisibleIndexPath.item]
//        let cellFrame = collectionView.convert(cell.frame, to: collectionView)
//        let offsetFromTop = cellFrame.minY - collectionView.contentOffset.y
//        
//        let anchor = FeedStateManager.ScrollAnchor(
//            postID: post.id,
//            offsetFromTop: offsetFromTop,
//            timestamp: Date()
//        )
//        
//        stateManager.setScrollAnchor(anchor)
//    }
//}
//
//// MARK: - UICollectionViewDataSourcePrefetching
//
//@available(iOS 16.0, *)
//extension FeedCollectionViewController: UICollectionViewDataSourcePrefetching {
//    
//    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
//        // Pre-create ViewModels for upcoming cells
//        for indexPath in indexPaths {
//            guard indexPath.item < stateManager.posts.count else { continue }
//            
//            let post = stateManager.posts[indexPath.item]
//            _ = stateManager.viewModel(for: post)
//        }
//    }
//}
//
//// MARK: - UIViewControllerRestoration
//
//@available(iOS 16.0, *)
//extension FeedCollectionViewController: UIViewControllerRestoration {
//    
//    static func viewController(withRestorationIdentifierPath identifierComponents: [String], coder: NSCoder) -> UIViewController? {
//        // For UIKit state restoration, we'll let the parent SwiftUI view handle recreation
//        // since our view controller depends on SwiftUI state
//        return nil
//    }
//    
//    override func encodeRestorableState(with coder: NSCoder) {
//        super.encodeRestorableState(with: coder)
//        
//        // Save scroll position for restoration
//        let contentOffset = collectionView.contentOffset
//        coder.encode(contentOffset.y, forKey: "scrollOffset")
//        
//        controllerLogger.debug("Encoded restorable state with scroll offset: \(contentOffset.y)")
//    }
//    
//    override func decodeRestorableState(with coder: NSCoder) {
//        super.decodeRestorableState(with: coder)
//        
//        // Restore scroll position
//        let scrollOffset = coder.decodeDouble(forKey: "scrollOffset")
//        if scrollOffset > 0 {
//            DispatchQueue.main.async { [weak self] in
//                self?.collectionView.setContentOffset(CGPoint(x: 0, y: scrollOffset), animated: false)
//            }
//            controllerLogger.debug("Restored scroll offset: \(scrollOffset)")
//        }
//    }
//    
//    override func applicationFinishedRestoringState() {
//        super.applicationFinishedRestoringState()
//        controllerLogger.debug("Application finished restoring state")
//    }
//}
