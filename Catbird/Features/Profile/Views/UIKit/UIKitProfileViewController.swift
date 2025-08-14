import UIKit
import SwiftUI
import Petrel
import Nuke
import os

@available(iOS 18.0, *)
final class UIKitProfileViewController: UIViewController {
  // MARK: - Properties
  private let appState: AppState
  private var viewModel: ProfileViewModel
  private var navigationPath: Binding<NavigationPath>
  private var selectedTab: Binding<Int>
  private var lastTappedTab: Binding<Int?>
  private var isEditingProfile: Binding<Bool>
  private var isShowingReportSheet: Bool = false
  private var isShowingAccountSwitcher: Bool = false
  private var isShowingBlockConfirmation: Bool = false
  
  // Header reference for scroll-driven animations
  private weak var currentHeaderView: UltraSmoothProfileHeaderView?
  
  // Scroll velocity tracking for smooth animations
  private var lastScrollOffset: CGFloat = 0
  private var lastScrollTime: CFTimeInterval = 0
  private var scrollVelocity: CGFloat = 0
  
    internal let profileLogger = Logger(subsystem: "blue.catbird", category: "UIKitProfileViewController")
  
  // MARK: - UI Components
  private let bannerHeight: CGFloat = 160 // Compact modern social profile proportions
  private let avatarOverlapHeight: CGFloat = 20 // Reduced space for tighter spacing between avatar and bio
  
  
  private lazy var collectionView: UICollectionView = {
    let layout = createCompositionalLayout()
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.showsVerticalScrollIndicator = true
    collectionView.delegate = self
    collectionView.isPrefetchingEnabled = false // Disable prefetching to avoid layout issues
    
    return collectionView
  }()
  
  
  private lazy var refreshControl: UIRefreshControl = {
    let control = UIRefreshControl()
    control.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    return control
  }()
  
  // MARK: - Data Source
  private enum Section: Int, CaseIterable {
    case banner
    case profileInfo
    case followedBy  // Only shown for other users
    case tabSelector
    case content
  }
  
  private enum Item: Hashable {
    case profileInfo(AppBskyActorDefs.ProfileViewDetailed)
    case followedBy([AppBskyActorDefs.ProfileView])
    case tabSelector(ProfileTab)
    case post(AppBskyFeedDefs.FeedViewPost)
    case loadingIndicator
    case emptyState(String, String)
    case moreView
  }
  
  private lazy var dataSource = createDataSource()
  
  // MARK: - Initialization
  init(
    appState: AppState,
    viewModel: ProfileViewModel,
    navigationPath: Binding<NavigationPath>,
    selectedTab: Binding<Int>,
    lastTappedTab: Binding<Int?>,
    isEditingProfile: Binding<Bool>
  ) {
    self.appState = appState
    self.viewModel = viewModel
    self.navigationPath = navigationPath
    self.selectedTab = selectedTab
    self.lastTappedTab = lastTappedTab
    self.isEditingProfile = isEditingProfile
    super.init(nibName: nil, bundle: nil)
  }
  
  required init?(coder: NSCoder) {
    // Can't use profileLogger here since it's not initialized yet
    print("UIKitProfileViewController: Attempted initialization from coder - not supported")
    return nil
  }
  
  deinit {
    // Enhanced cleanup to prevent memory leaks
    observationTask?.cancel()
    observationTask = nil
    
    // Clear collection view references
    collectionView.dataSource = nil
    collectionView.delegate = nil
    
    // Clear collection view layout cache
    collectionView.collectionViewLayout.invalidateLayout()
    
    profileLogger.debug("UIKitProfileViewController deallocated")
  }
  
  // MARK: - Lifecycle
  override func viewDidLoad() {
    super.viewDidLoad()
    
    profileLogger.debug("🚀 UIKitProfileViewController viewDidLoad")
      profileLogger.debug("  - View size: \(NSCoder.string(for: self.view.bounds.size))")
      profileLogger.debug("  - Safe area: \(NSCoder.string(for: self.view.safeAreaInsets))")
    
    // Set up state restoration
    self.restorationIdentifier = "UIKitProfileViewController"
    self.restorationClass = UIKitProfileViewController.self
    
    setupUI()
    registerCells()
    setupObservers()
    
    // Apply initial loading snapshot BEFORE loading data
    var initialSnapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    initialSnapshot.appendSections(Section.allCases)
    initialSnapshot.appendItems([.loadingIndicator], toSection: .content)
    dataSource.apply(initialSnapshot, animatingDifferences: false)
    
    // Load initial data after showing loading state
    loadInitialData()
  }
  
  private var observationTask: Task<Void, Never>?
  
  private func setupObservers() {
    // Use simple task with weak self to prevent crashes
    observationTask = Task { @MainActor [weak self] in
      guard let self = self else { return }
      await self.observeViewModelChanges()
    }
  }
  
  private func observeViewModelChanges() async {
    // Enhanced observation pattern with better error handling
    var lastUpdateTime = CFAbsoluteTimeGetCurrent()
    let minUpdateInterval: CFTimeInterval = 0.25 // Increased to 250ms to reduce updates
    
    while !Task.isCancelled {
      do {
        await withObservationTracking {
          // Track relevant properties with safe access
          _ = viewModel.profile?.did
          _ = viewModel.posts.count
          _ = viewModel.replies.count
          _ = viewModel.postsWithMedia.count
          _ = viewModel.isLoading
          _ = viewModel.selectedProfileTab
          _ = viewModel.error
        } onChange: {
          Task { @MainActor [weak self] in
            guard let self = self, !Task.isCancelled else { return }
            
            // Skip updates if user is actively scrolling
            guard !self.collectionView.isTracking && !self.collectionView.isDragging else {
              self.profileLogger.debug("Skipping update during active scrolling")
              return
            }
            
            let currentTime = CFAbsoluteTimeGetCurrent()
            if currentTime - lastUpdateTime >= minUpdateInterval {
              self.updateSnapshot()
              lastUpdateTime = currentTime
            }
          }
        }
        
        // Increased sleep duration to reduce observation frequency
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
      } catch {
        if Task.isCancelled {
          profileLogger.debug("Observation task cancelled gracefully")
          break
        }
        
        profileLogger.error("Observation error: \(error.localizedDescription, privacy: .public)")
        
        // Exponential backoff for error recovery
        let backoffTime = min(5.0, pow(2.0, Double.random(in: 0...2)))
        try? await Task.sleep(nanoseconds: UInt64(backoffTime * 1_000_000_000))
      }
    }
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureNavigationAndToolbarTheme()
  }
  
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    
    // Update insets for safe area changes
    updateContentInsetsForSafeArea()
  }
  
  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    
    // Update content insets when safe area changes
    updateContentInsetsForSafeArea()
  }
  
  private func updateContentInsetsForSafeArea() {
    // Only adjust scroll indicators, not content insets
    // This prevents conflicts with automatic adjustment
    let topInset = max(0, view.safeAreaInsets.top - bannerHeight)
    
    collectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: topInset,
      left: 0,
      bottom: 0,
      right: 0
    )
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    // Handle theme changes
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      configureNavigationAndToolbarTheme()
      collectionView.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    }
    
    // Handle size class changes for responsive design
    if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass ||
       previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass {
      
      // Batch updates to avoid multiple invalidations
      Task { @MainActor in
        // Delay slightly to avoid interfering with active layout
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        self.collectionView.collectionViewLayout.invalidateLayout()
        self.updateHeaderView()
      }
    }
    
    // Handle accessibility changes
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      // Batch invalidation with snapshot update
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000)
        self.collectionView.collectionViewLayout.invalidateLayout()
        self.updateSnapshot()
      }
    }
  }
  
  // MARK: - Setup
  private func setupRefreshControl() {
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    refreshControl.tintColor = .white // White tint for visibility over banner
    refreshControl.backgroundColor = .clear // Transparent background
    
    collectionView.refreshControl = refreshControl
    
    // FIXED: Use automatic content inset adjustment for better stability
    collectionView.contentInsetAdjustmentBehavior = .automatic
    collectionView.alwaysBounceVertical = true
    collectionView.bounces = true
    
    profileLogger.debug("✅ Configured refresh control with automatic insets")
  }
  
  private func setupUI() {
    view.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    
    // Add collection view to main view
    view.addSubview(collectionView)
    
    // Setup refresh control after collection view is created
    setupRefreshControl()
    
    NSLayoutConstraint.activate([
      // Edge-to-edge for both top and bottom to allow content under translucent bars
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    
    // FIXED: Already set in setupRefreshControl, no need to set again
    // collectionView.contentInsetAdjustmentBehavior is set in setupRefreshControl()
  }
  
  private func registerCells() {
    collectionView.register(ProfileInfoCell.self, forCellWithReuseIdentifier: "ProfileInfoCell")
    collectionView.register(FollowedByCell.self, forCellWithReuseIdentifier: "FollowedByCell")
    collectionView.register(TabSelectorCell.self, forCellWithReuseIdentifier: "TabSelectorCell")
    collectionView.register(PostCell.self, forCellWithReuseIdentifier: "PostCell")
    collectionView.register(LoadingCell.self, forCellWithReuseIdentifier: "LoadingCell")
    collectionView.register(EmptyStateCell.self, forCellWithReuseIdentifier: "EmptyStateCell")
    collectionView.register(MoreViewCell.self, forCellWithReuseIdentifier: "MoreViewCell")
    
    // Register ultra-smooth header view for banner section
    collectionView.register(
      UltraSmoothProfileHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: UltraSmoothProfileHeaderView.reuseIdentifier
    )
  }
  
  // MARK: - Height Calculator
  private lazy var heightCalculator = PostHeightCalculator()
  
  // MARK: - Performance Tracking
  private var lastLayoutTime: CFTimeInterval = 0
  private let performanceLogger = Logger(subsystem: "blue.catbird", category: "ProfilePerformance")
  
  // MARK: - Configuration Tracking
  private var lastProfileConfigurationTime: CFTimeInterval = 0
  
  // MARK: - Error Handling
  private func handleLoadError(_ error: Error) {
    profileLogger.error("Profile load error: \(error.localizedDescription, privacy: .public)")
    
    // Update UI to show error state
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.content])
    snapshot.appendItems([.emptyState("Error Loading Profile", "Please try again later")], toSection: .content)
    dataSource.apply(snapshot, animatingDifferences: true)
  }
  
  private func showRefreshError() {
    // Show subtle error feedback without blocking UI
    let feedbackGenerator = UINotificationFeedbackGenerator()
    feedbackGenerator.notificationOccurred(.error)
    
    profileLogger.debug("Refresh error feedback shown")
  }
  
  // Timeout wrapper for async operations
  private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw TimeoutError()
      }
      
      guard let result = try await group.next() else {
        throw TimeoutError()
      }
      
      group.cancelAll()
      return result
    }
  }
  
  private struct TimeoutError: Error {
    let localizedDescription = "Operation timed out"
  }
  
  private enum ProfileLoadError: Error {
    case profileNotFound
    
    var localizedDescription: String {
      switch self {
      case .profileNotFound:
        return "Profile not found"
      }
    }
  }
  
  
  // MARK: - Fallback Cell Creation
  private func createFallbackCell(for indexPath: IndexPath, message: String) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmptyStateCell", for: indexPath) as? EmptyStateCell
      ?? EmptyStateCell()
    
    if let emptyCell = cell as? EmptyStateCell {
      emptyCell.configure(title: "Unavailable", message: message, appState: appState)
    }
    
    return cell
  }
  
  // MARK: - Layout
  private func createCompositionalLayout() -> UICollectionViewLayout {
    SimplifiedProfileLayout { [weak self] sectionIndex, environment in
      guard let self = self else {
        // Return a safe default section if self is nil
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
      }
      
      guard let section = Section(rawValue: sectionIndex) else { 
        // Return a default section if we can't create the proper one
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
      }
      
      let screenWidth = environment.container.contentSize.width
      let isCompact = screenWidth < 768
      let responsivePadding = isCompact ? 16 : max(24, (screenWidth - 600) / 2)
      let sectionSpacing: CGFloat = isCompact ? 4 : 6 // Reduced spacing for tighter profile layout
      
      switch section {
      case .banner:
        // Banner section (completely empty, just has header)
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(0) // No height since content is in header
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(0) // No height
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        // Calculate total header height including avatar overlap
        let dynamicBannerHeight = self.bannerHeight
        let totalHeaderHeight = dynamicBannerHeight + self.avatarOverlapHeight
        
        self.profileLogger.debug("📏 Banner section layout:")
        self.profileLogger.debug("  - Banner height: \(dynamicBannerHeight)")
        self.profileLogger.debug("  - Avatar overlap: \(self.avatarOverlapHeight)")
        self.profileLogger.debug("  - Total header height: \(totalHeaderHeight)")
        self.profileLogger.debug("  - Screen width: \(screenWidth)")
        
        let headerSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(totalHeaderHeight)
        )
        let header = NSCollectionLayoutBoundarySupplementaryItem(
          layoutSize: headerSize,
          elementKind: UICollectionView.elementKindSectionHeader,
          alignment: .top
        )
        header.pinToVisibleBounds = false // Allow stretching
        
        let section = NSCollectionLayoutSection(group: group)
        section.boundarySupplementaryItems = [header]
        section.contentInsets = NSDirectionalEdgeInsets.zero
        return section
        
      case .profileInfo:
        // Profile info with responsive padding
        // Minimal top spacing for tighter layout since avatar is in header
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(120) // Reduced for tighter layout
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(120)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0, // No top padding for tighter spacing between avatar and bio
          leading: responsivePadding,
          bottom: sectionSpacing,
          trailing: responsivePadding
        )
        return section
        
      case .followedBy:
        // Followed by section
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
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0,
          leading: responsivePadding,
          bottom: sectionSpacing,
          trailing: responsivePadding
        )
        return section
        
      case .tabSelector:
        // Tab selector
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(44)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(44)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0,
          leading: responsivePadding,
          bottom: sectionSpacing,
          trailing: responsivePadding
        )
        return section
        
      case .content:
        // Use estimated heights to allow natural content sizing
        // This prevents overlapping by allowing cells to size themselves properly
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(300) // Estimated height allows natural sizing
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(300) // Estimated height for proper autosizing
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = sectionSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0,
          leading: 0,
          bottom: sectionSpacing,
          trailing: 0
        )
        return section
      }
    }
  }
  
  // MARK: - Data Source
  private func createDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
    let dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
      guard let self = self else { 
        // Return a basic cell as fallback
        return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
      }
      
      switch item {
      case .profileInfo(let profile):
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ProfileInfoCell", for: indexPath) as? ProfileInfoCell else {
          self.profileLogger.error("Failed to dequeue ProfileInfoCell - returning fallback")
          return self.createFallbackCell(for: indexPath, message: "Profile info unavailable")
        }
        
        do {
          cell.configure(
            profile: profile,
            viewModel: self.viewModel,
            appState: self.appState,
            isEditingProfile: self.isEditingProfile,
            path: self.navigationPath
          )
          return cell
        } catch {
          self.profileLogger.error("Failed to configure ProfileInfoCell: \(error.localizedDescription, privacy: .public)")
          return self.createFallbackCell(for: indexPath, message: "Profile configuration error")
        }
        
      case .followedBy(let knownFollowers):
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FollowedByCell", for: indexPath) as? FollowedByCell else {
          self.profileLogger.error("Failed to dequeue FollowedByCell - returning fallback")
          return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        }
        cell.configure(
          knownFollowers: knownFollowers,
          totalFollowersCount: self.viewModel.profile?.followersCount ?? 0,
          profileDID: self.viewModel.profile?.did.didString() ?? "",
          path: self.navigationPath
        )
        return cell
        
      case .tabSelector(let selectedTab):
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "TabSelectorCell", for: indexPath) as? TabSelectorCell else {
          self.profileLogger.error("Failed to dequeue TabSelectorCell - returning fallback")
          return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        }
        cell.configure(
          selectedTab: selectedTab,
          path: self.navigationPath,
          viewModel: self.viewModel,
          onTabChanged: { [weak self] in
            Task { @MainActor in
              self?.preCalculateContentHeights()
            }
          }
        )
        return cell
        
      case .post(let feedPost):
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PostCell", for: indexPath) as? PostCell else {
          self.profileLogger.error("Failed to dequeue PostCell - returning fallback")
          return self.createFallbackCell(for: indexPath, message: "Post unavailable")
        }
        
        do {
          cell.configure(
            post: feedPost,
            appState: self.appState,
            path: self.navigationPath
          )
          return cell
        } catch {
          self.profileLogger.error("Failed to configure PostCell: \(error.localizedDescription, privacy: .public)")
          return self.createFallbackCell(for: indexPath, message: "Post configuration error")
        }
        
      case .loadingIndicator:
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath) as? LoadingCell else {
          return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        }
        cell.startAnimating()
        return cell
        
      case .emptyState(let title, let message):
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmptyStateCell", for: indexPath) as? EmptyStateCell else {
          self.profileLogger.error("Failed to dequeue EmptyStateCell - returning fallback")
          return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        }
        cell.configure(title: title, message: message, appState: self.appState)
        return cell
        
      case .moreView:
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "MoreViewCell", for: indexPath) as? MoreViewCell else {
          self.profileLogger.error("Failed to dequeue MoreViewCell - returning fallback")
          return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        }
        cell.configure(
          viewModel: self.viewModel,
          appState: self.appState,
          path: self.navigationPath
        )
        return cell
      }
    }
    
    // Configure supplementary view provider for headers
    dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard let self = self,
            kind == UICollectionView.elementKindSectionHeader,
            let section = Section(rawValue: indexPath.section) else {
        return nil
      }
      
      switch section {
      case .banner:
        self.profileLogger.debug("📌 Creating/Dequeuing ultra-smooth banner header view")
        guard let headerView = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: UltraSmoothProfileHeaderView.reuseIdentifier,
          for: indexPath
        ) as? UltraSmoothProfileHeaderView else {
          self.profileLogger.error("❌ Failed to dequeue UltraSmoothProfileHeaderView - returning nil")
          return nil
        }
        
        if let profile = self.viewModel.profile {
          self.profileLogger.debug("✅ Configuring ultra-smooth header with profile: @\(profile.handle, privacy: .public)")
          headerView.configure(profile: profile, appState: self.appState, viewModel: self.viewModel)
        } else {
          self.profileLogger.debug("⚠️ No profile available for header configuration")
        }
        
        // Store reference for scroll-driven animations
        self.currentHeaderView = headerView
        
        self.profileLogger.debug("📐 Ultra-smooth header view frame: \(headerView.frame.debugDescription)")
        return headerView
        
      default:
        return nil
      }
    }
    
    return dataSource
  }
  
  // MARK: - Data Loading
  private func loadInitialData() {
    Task {
      do {
        profileLogger.debug("🚀 Starting initial data load")
        
        // Load profile first with error handling
        await viewModel.loadProfile()
        
        // Update UI on main thread after profile loads
        await MainActor.run {
          self.updateSnapshot()
        }
        
        // Verify profile loaded successfully
        guard viewModel.profile != nil else {
          profileLogger.warning("Profile failed to load, skipping dependent operations")
          await MainActor.run {
            self.handleLoadError(ProfileLoadError.profileNotFound)
          }
          return
        }
        
        // Load known followers for other users
        if !viewModel.isCurrentUser {
          await viewModel.loadKnownFollowers()
        }
        
        // Load initial tab content (usually posts)
        await loadContentForCurrentTab()
        
        // Final UI update and pre-calculate heights for better scroll performance
        await MainActor.run {
          self.updateSnapshot()
          self.preCalculateContentHeights()
        }
        
        profileLogger.debug("✅ Initial data load completed successfully")
        
      } catch {
        profileLogger.error("❌ Failed to load initial data: \(error.localizedDescription, privacy: .public)")
        
        await MainActor.run {
          self.handleLoadError(error)
        }
      }
    }
  }
  
  @MainActor
  private func preCalculateContentHeights() {
    // Pre-calculate heights for all current content to improve scroll performance
    // and prevent overlapping by ensuring proper sizing
    switch viewModel.selectedProfileTab {
    case .posts:
      for post in viewModel.posts {
          let height = heightCalculator.calculateHeight(for: post.post, mode: .compact)
          profileLogger.debug("Pre-calculated height for post: \(height)")
      }
    case .replies:
      for reply in viewModel.replies {
          let height = heightCalculator.calculateHeight(for: reply.post, mode: .compact)
          profileLogger.debug("Pre-calculated height for reply: \(height)")
      }
    case .media:
      for mediaPost in viewModel.postsWithMedia {
          let height = heightCalculator.calculateHeight(for: mediaPost.post, mode: .compact)
          profileLogger.debug("Pre-calculated height for media post: \(height)")
      }
    case .likes:
      for like in viewModel.likes {
          let height = heightCalculator.calculateHeight(for: like.post, mode: .compact)
          profileLogger.debug("Pre-calculated height for liked post: \(height)")
      }
    default:
      break
    }
    
    // Force layout update after height calculation
    collectionView.collectionViewLayout.invalidateLayout()
  }
  
  @objc private func handleRefresh() {
    Task {
      do {
        // Add timeout for refresh operations
          try await withTimeout(seconds: 10) { [self] in
          await viewModel.loadProfile()
          
          if !viewModel.isCurrentUser {
            await viewModel.loadKnownFollowers()
          }
          
          await loadContentForCurrentTab()
        }
        
        await MainActor.run {
          updateSnapshot()
          
          // Smooth refresh control dismissal
          UIView.animate(withDuration: 0.3) {
            self.refreshControl.endRefreshing()
          }
        }
        
      } catch {
        profileLogger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        
        await MainActor.run {
          // End refreshing even on error
          UIView.animate(withDuration: 0.3) {
            self.refreshControl.endRefreshing()
          }
          
          // Show error feedback
          showRefreshError()
        }
      }
    }
  }
  
  private func loadContentForCurrentTab() async {
    switch viewModel.selectedProfileTab {
    case .posts:
      await viewModel.loadPosts()
    case .replies:
      await viewModel.loadReplies()
    case .media:
      await viewModel.loadMediaPosts()
    case .likes:
      await viewModel.loadLikes()
    case .lists:
      await viewModel.loadLists()
    case .starterPacks:
      await viewModel.loadStarterPacks()
    case .feeds:
      await viewModel.loadFeeds()
    default:
      break
    }
  }
  
  @MainActor
  private func handleTabChange(_ tab: ProfileTab) {
    viewModel.selectedProfileTab = tab
    
    Task {
      await loadContentForCurrentTab()
      await MainActor.run {
        updateSnapshot()
      }
    }
  }
  
  // MARK: - Snapshot Updates
  private var isUpdatingSnapshot = false
  
  @MainActor
  private func updateSnapshot() {
    // Prevent concurrent snapshot updates
    guard !isUpdatingSnapshot else {
      profileLogger.debug("Skipping snapshot update - already updating")
      return
    }
    
    // Throttle rapid updates to prevent performance issues
    let currentTime = CFAbsoluteTimeGetCurrent()
    let timeSinceLastUpdate = currentTime - lastProfileConfigurationTime
    
    if timeSinceLastUpdate < 0.1 && !viewModel.posts.isEmpty { // Don't throttle initial load
      return
    }
    
    isUpdatingSnapshot = true
    defer { isUpdatingSnapshot = false }
    
    lastProfileConfigurationTime = currentTime
    
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    
    // Add sections
    snapshot.appendSections(Section.allCases)
    
    // Banner section stays empty (header only)
    
    // Banner section (completely empty, content is purely in header)
    // No items needed here to avoid visual conflicts
    
    // Profile info
    if let profile = viewModel.profile {
      snapshot.appendItems([.profileInfo(profile)], toSection: .profileInfo)
    }
    
    // Followed by (only for other users)
    if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
      snapshot.appendItems([.followedBy(viewModel.knownFollowers)], toSection: .followedBy)
    }
    
    // Tab selector
    snapshot.appendItems([.tabSelector(viewModel.selectedProfileTab)], toSection: .tabSelector)
    
    // Content based on selected tab
    switch viewModel.selectedProfileTab {
    case .posts:
      if viewModel.isLoading && viewModel.posts.isEmpty {
        snapshot.appendItems([.loadingIndicator], toSection: .content)
      } else if viewModel.posts.isEmpty {
        snapshot.appendItems([.emptyState("No posts", "No posts yet")], toSection: .content)
      } else {
        let postItems = viewModel.posts.map { Item.post($0) }
        snapshot.appendItems(postItems, toSection: .content)
      }
      
    case .replies:
      if viewModel.isLoading && viewModel.replies.isEmpty {
        snapshot.appendItems([.loadingIndicator], toSection: .content)
      } else if viewModel.replies.isEmpty {
        snapshot.appendItems([.emptyState("No replies", "No replies yet")], toSection: .content)
      } else {
        let postItems = viewModel.replies.map { Item.post($0) }
        snapshot.appendItems(postItems, toSection: .content)
      }
      
    case .media:
      if viewModel.isLoading && viewModel.postsWithMedia.isEmpty {
        snapshot.appendItems([.loadingIndicator], toSection: .content)
      } else if viewModel.postsWithMedia.isEmpty {
        snapshot.appendItems([.emptyState("No media", "No media posts yet")], toSection: .content)
      } else {
        let postItems = viewModel.postsWithMedia.map { Item.post($0) }
        snapshot.appendItems(postItems, toSection: .content)
      }
      
    case .likes:
      if viewModel.isLoading && viewModel.likes.isEmpty {
        snapshot.appendItems([.loadingIndicator], toSection: .content)
      } else if viewModel.likes.isEmpty {
        snapshot.appendItems([.emptyState("No likes", "No liked posts yet")], toSection: .content)
      } else {
        let postItems = viewModel.likes.map { Item.post($0) }
        snapshot.appendItems(postItems, toSection: .content)
      }
      
    case .more:
      // More tab shows the actual MoreView
      snapshot.appendItems([.moreView], toSection: .content)
      
    default:
      // Other specific tabs (lists, feeds, etc.) show placeholder for now
      snapshot.appendItems([.emptyState("Coming Soon", "This content will be available soon")], toSection: .content)
    }
    
    dataSource.apply(snapshot, animatingDifferences: true)
    
    // Update header view after applying snapshot (throttled)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      self.updateHeaderView()
    }
  }
  
  @MainActor
  private func updateHeaderView() {
    // Update the ultra-smooth header view
    if let headerView = collectionView.supplementaryView(
      forElementKind: UICollectionView.elementKindSectionHeader,
      at: IndexPath(item: 0, section: 0)
    ) as? UltraSmoothProfileHeaderView,
       let profile = viewModel.profile {
      headerView.configure(profile: profile, appState: appState, viewModel: viewModel)
      
      // Update our reference for scroll animations
      currentHeaderView = headerView
    }
  }
  
  // MARK: - Theme Configuration
  private func configureNavigationAndToolbarTheme() {
    let currentScheme = getCurrentColorScheme()
    let isDarkMode = appState.themeManager.isDarkMode(for: currentScheme)
    let isBlackMode = appState.themeManager.isUsingTrueBlack
    
    // Configure tab bar
    guard let tabBarController = self.tabBarController else { return }
    
    let tabBarAppearance = UITabBarAppearance()
    
//    if isDarkMode && isBlackMode {
//      tabBarAppearance.configureWithOpaqueBackground()
//      tabBarAppearance.backgroundColor = UIColor.black
//      tabBarAppearance.shadowColor = .clear
//      tabBarController.tabBar.tintColor = UIColor.systemBlue
//    } else if isDarkMode {
//      tabBarAppearance.configureWithOpaqueBackground()
//      tabBarAppearance.backgroundColor = UIColor(appState.themeManager.dimBackgroundColor)
//      tabBarAppearance.shadowColor = .clear
//      tabBarController.tabBar.tintColor = nil
//    } else {
//      tabBarAppearance.configureWithDefaultBackground()
//      tabBarAppearance.backgroundColor = UIColor.systemBackground
//      tabBarController.tabBar.tintColor = UIColor.systemBlue
//    }
      tabBarAppearance.configureWithTransparentBackground()

    
    tabBarController.tabBar.standardAppearance = tabBarAppearance
    tabBarController.tabBar.scrollEdgeAppearance = tabBarAppearance
    
    if #available(iOS 13.0, *) {
      tabBarController.tabBar.overrideUserInterfaceStyle = currentScheme == .dark ? .dark : .light
    }
  }
}

// MARK: - UICollectionViewDelegate
@available(iOS 18.0, *)
extension UIKitProfileViewController: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
    // Check if we need to load more posts
    guard let section = Section(rawValue: indexPath.section),
          section == .content else { return }
    
    let snapshot = dataSource.snapshot()
    let items = snapshot.itemIdentifiers(inSection: .content)
    
    // Load more when reaching the last 3 items (with safety check)
    if items.count > 3 && indexPath.item >= items.count - 3 && !viewModel.isLoadingMorePosts {
      Task {
        switch viewModel.selectedProfileTab {
        case .posts:
          await viewModel.loadPosts()
        case .replies:
          await viewModel.loadReplies()
        case .media:
          await viewModel.loadMediaPosts()
        default:
          break
        }
        await MainActor.run {
          updateSnapshot()
        }
      }
    }
  }
  
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let currentTime = CFAbsoluteTimeGetCurrent()
    let currentOffset = scrollView.contentOffset.y
    
    // Calculate scroll velocity for momentum-based animations
    if lastScrollTime > 0 {
      let deltaTime = currentTime - lastScrollTime
      let deltaOffset = currentOffset - lastScrollOffset
      if deltaTime > 0 {
        scrollVelocity = deltaOffset / deltaTime
      }
    }
    
    lastScrollOffset = currentOffset
    lastScrollTime = currentTime
    
    // Ultra-smooth header animation (called every frame)
    if let headerView = currentHeaderView {
      headerView.updateForScrollOffset(currentOffset)
    }
    
    // Navigation bar updates (throttled for performance)
    if currentTime - lastLayoutTime > 0.033 { // 30fps throttling
      updateNavigationBarAppearance(offset: currentOffset)
      lastLayoutTime = currentTime
    }
  }
  
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    // Header animations are handled smoothly in scrollViewDidScroll
    // No additional reset needed since we use frame-based animations
  }
  
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    // Ensure header is in correct final state
    if let headerView = currentHeaderView {
      headerView.updateForScrollOffset(scrollView.contentOffset.y)
    }
  }
  
  
  private func updateNavigationBarAppearance(offset: CGFloat) {
    let transitionStart: CGFloat = 120
    let transitionEnd: CGFloat = 180
    
    // Calculate transition progress with easing
    let rawProgress = (offset - transitionStart) / (transitionEnd - transitionStart)
    let progress = min(1, max(0, rawProgress))
    let easedProgress = sin(progress * .pi / 2) // Ease-out curve
    
    // Smooth navigation bar background transition
    let backgroundColor = UIColor.systemBackground.withAlphaComponent(easedProgress)
    navigationController?.navigationBar.backgroundColor = backgroundColor
    
    // Smooth title transition with animation
    let shouldShowTitle = progress > 0.6
    let currentTitle = navigationItem.title
    let targetTitle = shouldShowTitle ? (viewModel.profile?.displayName ?? viewModel.profile?.handle.description) : nil
    
    if currentTitle != targetTitle {
      UIView.transition(with: navigationController?.navigationBar ?? UIView(), duration: 0.25, options: .transitionCrossDissolve) {
        self.navigationItem.title = targetTitle
      }
    }
    
    // Update status bar style based on header visibility
    let statusBarStyle: UIStatusBarStyle = progress < 0.5 ? .lightContent : .default
        navigationController?.navigationBar.overrideUserInterfaceStyle = progress < 0.5 ? .dark : .unspecified
  }
}

// MARK: - UIViewControllerRestoration
@available(iOS 18.0, *)
extension UIKitProfileViewController: UIViewControllerRestoration {
  static func viewController(withRestorationIdentifierPath identifierComponents: [String], coder: NSCoder) -> UIViewController? {
    // Let SwiftUI handle view controller recreation since this is embedded in SwiftUI
    return nil
  }
  
  override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    
    // Save current profile DID and tab selection
    if let profileDID = viewModel.profile?.did.didString() {
      coder.encode(profileDID, forKey: "profileDID")
    }
    coder.encode(viewModel.selectedProfileTab.rawValue, forKey: "selectedTab")
    
    // Save scroll position
    let contentOffset = collectionView.contentOffset
    coder.encode(contentOffset.y, forKey: "scrollOffset")
    
    profileLogger.debug("Encoded restorable state for profile")
  }
  
  override func decodeRestorableState(with coder: NSCoder) {
    super.decodeRestorableState(with: coder)
    
    // Restore profile and tab selection
    let savedProfileDID = coder.decodeObject(forKey: "profileDID") as? String
    let currentProfileDID = viewModel.profile?.did.didString()
    
    // Only restore if we're viewing the same profile
    guard savedProfileDID == currentProfileDID else {
      profileLogger.debug("Profile DID mismatch - skipping state restoration")
      return
    }
    
    // Restore tab selection
    if let tabRawValue = coder.decodeObject(forKey: "selectedTab") as? String,
       let restoredTab = ProfileTab(rawValue: tabRawValue) {
      viewModel.selectedProfileTab = restoredTab
    }
    
    // Restore scroll position
    let scrollOffset = coder.decodeDouble(forKey: "scrollOffset")
    if scrollOffset > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        guard let self = self else { return }
        
        let maxOffset = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
        let safeOffset = min(scrollOffset, maxOffset)
        
        self.collectionView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        self.profileLogger.debug("Restored scroll position: \(safeOffset)")
      }
    }
    
    profileLogger.debug("Decoded restorable state for profile")
  }
}

// MARK: - Property Binding Extension
@available(iOS 18.0, *)
extension UIKitProfileViewController {
  @discardableResult
  func setEditingProfileBinding(_ isEditing: Binding<Bool>) -> Self {
    // For now, we'll handle editing state through the SwiftUI wrapper
    // This method can be used for future binding if needed
    return self
  }
}



// MARK: - Cell Types

@available(iOS 18.0, *)
final class ProfileInfoCell: UICollectionViewCell {
  private var lastConfiguredProfile: String?
  
  override func prepareForReuse() {
    super.prepareForReuse()
    lastConfiguredProfile = nil
  }
  
  func configure(
    profile: AppBskyActorDefs.ProfileViewDetailed,
    viewModel: ProfileViewModel,
    appState: AppState,
    isEditingProfile: Binding<Bool>,
    path: Binding<NavigationPath>
  ) {
    // Skip redundant configurations
    let profileID = profile.did.didString()
    guard lastConfiguredProfile != profileID else { return }
    lastConfiguredProfile = profileID
    
    let screenWidth = contentView.bounds.width > 0 ? contentView.bounds.width : UIScreen.main.bounds.width
    
    contentConfiguration = UIHostingConfiguration {
      ProfileHeader(
        profile: profile,
        viewModel: viewModel,
        appState: appState,
        isEditingProfile: isEditingProfile,
        path: path,
        screenWidth: screenWidth,
        hideAvatar: true // Hide avatar since it's shown in the enhanced header
      )
    }
    .margins(.all, 0)
    .minSize(width: screenWidth, height: 180) // Set minimum size to prevent layout changes
  }
}

@available(iOS 18.0, *)
final class FollowedByCell: UICollectionViewCell {
  func configure(
    knownFollowers: [AppBskyActorDefs.ProfileView],
    totalFollowersCount: Int,
    profileDID: String,
    path: Binding<NavigationPath>
  ) {
    contentConfiguration = UIHostingConfiguration {
      FollowedByView(
        knownFollowers: knownFollowers,
        totalFollowersCount: totalFollowersCount,
        profileDID: profileDID,
        path: path
      )
    }
    .margins(.all, 0)
  }
}

@available(iOS 18.0, *)
final class TabSelectorCell: UICollectionViewCell {
  func configure(
    selectedTab: ProfileTab,
    path: Binding<NavigationPath>,
    viewModel: ProfileViewModel,
    onTabChanged: @escaping () -> Void
  ) {
    contentConfiguration = UIHostingConfiguration {
      ProfileTabSelector(
        path: path,
        selectedTab: Binding(
          get: { viewModel.selectedProfileTab },
          set: { newTab in
            viewModel.selectedProfileTab = newTab
          }
        ),
        onTabChange: { newTab in
          Task {
            // Load content for the new tab
            switch newTab {
            case .posts:
              await viewModel.loadPosts()
            case .replies:
              await viewModel.loadReplies()
            case .media:
              await viewModel.loadMediaPosts()
            case .likes:
              await viewModel.loadLikes()
            case .lists:
              await viewModel.loadLists()
            case .starterPacks:
              await viewModel.loadStarterPacks()
            case .feeds:
              await viewModel.loadFeeds()
            default:
              break
            }
            
            // Pre-calculate heights for the new content
            onTabChanged()
          }
        }
      )
    }
    .margins(.all, 0)
  }
}

@available(iOS 18.0, *)
final class PostCell: UICollectionViewCell {
  private var lastConfiguredPost: String?
  
  override func prepareForReuse() {
    super.prepareForReuse()
    lastConfiguredPost = nil
  }
  
  func configure(
    post: AppBskyFeedDefs.FeedViewPost,
    appState: AppState,
    path: Binding<NavigationPath>
  ) {
    // Skip redundant configurations
    let postID = post.post.uri.uriString()
    guard lastConfiguredPost != postID else { return }
    lastConfiguredPost = postID
    
    let screenWidth = contentView.bounds.width > 0 ? contentView.bounds.width : UIScreen.main.bounds.width
    
    contentConfiguration = UIHostingConfiguration {
      VStack(spacing: 0) {
        EnhancedFeedPost(
          cachedPost: CachedFeedViewPost(feedViewPost: post),
          path: path
        )
        .frame(maxWidth: screenWidth) // Constrain width
        .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
        
        // Add divider like other views
        Divider()
          .padding(.top, 8)
      }
    }
    .margins(.all, 0)
    .minSize(width: 0, height: 100) // Set minimum height to prevent compression
  }
}

@available(iOS 18.0, *)
final class LoadingCell: UICollectionViewCell {
  private var activityIndicator: UIActivityIndicatorView!
  private var pulseView: UIView!
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupLoadingUI()
  }
  
  required init?(coder: NSCoder) {
    return nil
  }
  
  private func setupLoadingUI() {
    // Subtle pulse background
    pulseView = UIView()
    pulseView.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.3)
    pulseView.layer.cornerRadius = 8
    pulseView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(pulseView)
    
    activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.hidesWhenStopped = true
    activityIndicator.color = .systemBlue
    contentView.addSubview(activityIndicator)
    
    NSLayoutConstraint.activate([
      pulseView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      pulseView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      pulseView.widthAnchor.constraint(equalToConstant: 60),
      pulseView.heightAnchor.constraint(equalToConstant: 60),
      
      activityIndicator.centerXAnchor.constraint(equalTo: pulseView.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: pulseView.centerYAnchor),
      
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
    ])
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    stopAnimating()
  }
  
  func startAnimating() {
    activityIndicator.startAnimating()
    
    UIView.animate(withDuration: 1.5, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
      self.pulseView.alpha = 0.1
    }
  }
  
  func stopAnimating() {
    activityIndicator.stopAnimating()
    pulseView.layer.removeAllAnimations()
    pulseView.alpha = 0.3
  }
}

@available(iOS 18.0, *)
final class EmptyStateCell: UICollectionViewCell {
  func configure(title: String, message: String, appState: AppState) {
    contentConfiguration = UIHostingConfiguration {
      VStack(spacing: 20) {
        Spacer()
        
        // Animated icon
        Image(systemName: "square.stack.3d.up.slash")
          .font(.system(size: 56, weight: .light))
          .foregroundStyle(.tertiary)
          .symbolEffect(.pulse.byLayer, options: .repeat(.continuous).speed(0.5))
        
        VStack(spacing: 8) {
          Text(title)
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
          
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        
        Spacer()
      }
      .frame(minHeight: 320)
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(title). \(message)")
    }
    .margins(.all, 0)
  }
}

@available(iOS 18.0, *)
final class MoreViewCell: UICollectionViewCell {
  func configure(
    viewModel: ProfileViewModel,
    appState: AppState,
    path: Binding<NavigationPath>
  ) {
    contentConfiguration = UIHostingConfiguration {
      MoreView(path: path)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    .margins(.all, 0)
  }
}
