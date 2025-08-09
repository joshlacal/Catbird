import Petrel
import SwiftUI
import UIKit
import os

// MARK: - UIKit Color Scheme Helper
extension UIViewController {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
            return AppState.shared.themeManager.effectiveColorScheme(for: systemScheme)
    }
}

extension UIView {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
            return AppState.shared.themeManager.effectiveColorScheme(for: systemScheme)
    }
}


// MARK: - Custom Thread Layout
@available(iOS 18.0, *)
final class ThreadCompositionalLayout: UICollectionViewCompositionalLayout {
  private var isPerformingUpdate = false
  private var mainPostSectionIndex: Int = 2
  
  private let layoutLogger = Logger(
    subsystem: "blue.catbird", category: "ThreadCompositionalLayout")

  override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
    super.prepare(forCollectionViewUpdates: updateItems)
    
    guard let _ = collectionView, !updateItems.isEmpty else { return }
    
    // We'll handle position restoration manually in updateDataWithNewParents
    isPerformingUpdate = true
  }

  override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint)
    -> CGPoint {
    // Let the manual adjustment in updateDataWithNewParents handle position restoration
    return proposedContentOffset
  }

  override func finalizeCollectionViewUpdates() {
    super.finalizeCollectionViewUpdates()
    isPerformingUpdate = false
  }

  func setMainPostSectionIndex(_ index: Int) {
    mainPostSectionIndex = index
  }
}

@available(iOS 18.0, *)
final class ThreadViewController: UIViewController, StateInvalidationSubscriber {
  // MARK: - Properties
  private var appState: AppState
  private let postURI: ATProtocolURI
  private var path: Binding<NavigationPath>

  private var threadManager: ThreadManager?
  private var isLoading = true
  private var hasInitialized = false
  private var isLoadingMoreParents = false
  private var hasScrolledToMainPost = false
  private var lastParentLoadTime: Date?
  private var parentLoadAttempts = 0
  private var hasReachedTopOfThread = false
  private var pendingLoadTask: Task<Void, Never>?
  
  // MARK: - UIUpdateLink for coordinated UI updates
  private var updateLink: UIUpdateLink?
  private var scrollPositionTracker = ThreadScrollPositionTracker()

  private var parentPosts: [ParentPost] = []
  private var mainPost: AppBskyFeedDefs.PostView?
  private var replyWrappers: [ReplyWrapper] = []

  private static let mainPostID = "main-post-id"
  
  // Estimated height for parent posts (used for scroll position preservation)
  private let estimatedParentPostHeight: CGFloat = 120.0
  
  // Optimized scroll system for iOS 18+
  @available(iOS 18.0, *)
  private lazy var optimizedScrollSystem = OptimizedScrollPreservationSystem()

  // Logger for debugging thread loading issues
  private let controllerLogger = Logger(
    subsystem: "blue.catbird", category: "ThreadViewController")

  // MARK: - UI Components
    private lazy var collectionView: UICollectionView = {
        let layout = createCompositionalLayout()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.showsVerticalScrollIndicator = true
        collectionView.prefetchDataSource = self
        
        // Let automatic content inset adjustment handle safe areas since we're edge-to-edge
        collectionView.contentInsetAdjustmentBehavior = .automatic

        return collectionView
    }()
    
  private lazy var loadingView: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
      container.backgroundColor = .systemBackground

    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.startAnimating()

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Loading thread..."
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
      stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor)
    ])

    return container
  }()

  // MARK: - Data Source
  private enum Section: Int, CaseIterable {
    case loadMoreParents
    case parentPosts
    case mainPost
    case replies
    case bottomSpacer
  }

  private enum Item: Hashable, Sendable {
    case loadMoreParentsTrigger
    case parentPost(ParentPost)
    case mainPost(AppBskyFeedDefs.PostView)
    case reply(ReplyWrapper)
    case spacer
  }

  private lazy var dataSource = createDataSource()

  // MARK: - Initialization
  init(appState: AppState, postURI: ATProtocolURI, path: Binding<NavigationPath>) {
    self.appState = appState
    self.postURI = postURI
    self.path = path
    super.init(nibName: nil, bundle: nil)
    
    // Subscribe to state invalidation events for reply updates
    appState.stateInvalidationBus.subscribe(self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  deinit {
    // Clean up UIUpdateLink
    updateLink?.isEnabled = false
    updateLink = nil
    
    // Clean up iOS 18+ optimized scroll system
    if #available(iOS 18.0, *) {
      let scrollSystem = optimizedScrollSystem
      Task { @MainActor in
        scrollSystem.cleanup()
      }
    }
    
    // Unsubscribe from state invalidation events
    appState.stateInvalidationBus.unsubscribe(self)
  }

  // MARK: - Lifecycle Methods
  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    registerCells()
    collectionView.delegate = self
    
    // Prevent VoiceOver from auto-scrolling
    collectionView.accessibilityTraits = .none
    collectionView.shouldGroupAccessibilityChildren = true
    
    loadInitialThread()
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    // Apply theme directly to this view controller's navigation and toolbar
    configureNavigationAndToolbarTheme()
    
    // Apply width=120 fonts to this navigation bar
    if let navigationBar = navigationController?.navigationBar {
      NavigationFontConfig.applyFonts(to: navigationBar)
    }
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    
    // Setup UIUpdateLink now that view is in window hierarchy
    if updateLink == nil {
      setupUIUpdateLink()
    }
    
    // Ensure theming is applied after view appears (helps with material effects)
    DispatchQueue.main.async {
      self.configureNavigationAndToolbarTheme()
    }
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    // Update theme when system appearance changes
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      // Apply theme directly to this view controller
      configureNavigationAndToolbarTheme()
      
      // Update collection view background
        collectionView.backgroundColor = .systemBackground
        view.backgroundColor = .systemBackground
        loadingView.backgroundColor = .systemBackground
    }
  }
  
  // MARK: - Theme Configuration
  
  private func configureNavigationAndToolbarTheme() {
    let currentScheme = getCurrentColorScheme()
    let isDarkMode = appState.themeManager.isDarkMode(for: currentScheme)
    let isBlackMode = appState.themeManager.isUsingTrueBlack
    
    // MARK: - Configure Navigation Bar
//    if let navigationBar = navigationController?.navigationBar {
//        let navAppearance = UINavigationBarAppearance()
//        
//        if isDarkMode && isBlackMode {
//            // True black mode
//            navAppearance.configureWithOpaqueBackground()
//            navAppearance.backgroundColor = UIColor.black
//            navAppearance.shadowColor = .clear
//        } else if isDarkMode {
//            // Dim mode
//            navAppearance.configureWithOpaqueBackground()
//            navAppearance.backgroundColor = UIColor(appState.themeManager.dimBackgroundColor)
//            navAppearance.shadowColor = .clear
//        } else {
//            // Light mode
//            navAppearance.configureWithDefaultBackground()
//        }
//        
//        // Apply width=120 fonts to navigation bar
//        NavigationFontConfig.applyFonts(to: navAppearance)
//        
//        // Apply the navigation bar appearance
//        navigationBar.standardAppearance = navAppearance
//        navigationBar.scrollEdgeAppearance = navAppearance
//        navigationBar.compactAppearance = navAppearance
//    }
//    
    // MARK: - Configure Tab Bar (only if present)
    guard let tabBarController = self.tabBarController else { return }
    
    let tabBarAppearance = UITabBarAppearance()
    
//    if isDarkMode && isBlackMode {
//        // True black mode - solid black background
//        tabBarAppearance.configureWithOpaqueBackground()
//        tabBarAppearance.backgroundColor = UIColor.black
//        tabBarAppearance.shadowColor = .clear
//        
//        // Set blue tint color for better visibility on black
//        tabBarController.tabBar.tintColor = UIColor.systemBlue
//    } else if isDarkMode {
//        // Dim mode - use dim background color
//        tabBarAppearance.configureWithOpaqueBackground()
//        tabBarAppearance.backgroundColor = UIColor(appState.themeManager.dimBackgroundColor)
//        tabBarAppearance.shadowColor = .clear
//        
//        // Reset tint color to system default (not black)
//        tabBarController.tabBar.tintColor = nil
//    } else {
//        // Light mode - use system background
//        tabBarAppearance.configureWithDefaultBackground()
//        tabBarAppearance.backgroundColor = UIColor.systemBackground
//        
//        // Explicitly set blue tint color to ensure visibility
//        tabBarController.tabBar.tintColor = UIColor.systemBlue
//    }
      
      tabBarAppearance.configureWithTransparentBackground()
    
    // Apply the tab bar appearance
    tabBarController.tabBar.standardAppearance = tabBarAppearance
    tabBarController.tabBar.scrollEdgeAppearance = tabBarAppearance
    
    // Ensure proper color scheme for tab bar icons and text
    if #available(iOS 13.0, *) {
        tabBarController.tabBar.overrideUserInterfaceStyle = currentScheme == .dark ? .dark : .light
    }
  }
  
  private func configureParentNavigationTheme() {
    // Theme configuration is handled by SwiftUI's themedNavigationBar modifier
    // No need to modify UIKit navigation bar appearance directly
  }

  // MARK: - UIUpdateLink Setup
  private func setupUIUpdateLink() {
    guard let windowScene = view.window?.windowScene else {
      controllerLogger.warning("Cannot setup UIUpdateLink: windowScene not available")
      return
    }
    
    // Create UIUpdateLink for the window scene for smooth transitions
    updateLink = UIUpdateLink(windowScene: windowScene)
    
    // Add action for coordinating smooth animations during updates
    updateLink?.addAction(handler: { [weak self] link, info in
      // Use UIUpdateLink for what it's designed for - coordinating with display refresh
      // Position restoration is handled separately using the proven ScrollPositionTracker pattern
    })
    
    // Configure UIUpdateLink preferences for smooth transitions
    updateLink?.isEnabled = true
    updateLink?.requiresContinuousUpdates = false
    updateLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
    
    controllerLogger.debug("UIUpdateLink setup completed for smooth transitions")
  }

  // MARK: - UI Setup
  private func setupUI() {
      view.backgroundColor = .systemBackground

    // Initially hide collection view to prevent content flickering
    collectionView.alpha = 0

    view.addSubview(collectionView)
    view.addSubview(loadingView)

    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      loadingView.topAnchor.constraint(equalTo: view.topAnchor),
      loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }

  private func registerCells() {
    collectionView.register(ParentPostCell.self, forCellWithReuseIdentifier: "ParentPostCell")
    collectionView.register(MainPostCell.self, forCellWithReuseIdentifier: "MainPostCell")
    collectionView.register(ReplyCell.self, forCellWithReuseIdentifier: "ReplyCell")
    collectionView.register(LoadMoreCell.self, forCellWithReuseIdentifier: "LoadMoreCell")
    collectionView.register(SpacerCell.self, forCellWithReuseIdentifier: "SpacerCell")
  }

  // MARK: - CollectionView Layout

  // Reuse PostHeightCalculator for accurate height estimations
  private lazy var heightCalculator = PostHeightCalculator()

  // Extract section creation to a separate method for better organization
  private func createSection(with estimatedHeight: CGFloat, for section: Section)
    -> NSCollectionLayoutSection {
    // Handle the spacer section differently
    if section == .bottomSpacer {
      // Create a large spacer (600 points, matching SwiftUI implementation)
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(600)
      )

      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(600)
      )

      let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
      return NSCollectionLayoutSection(group: group)
    }

    // Standard layout for other sections
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

    let layoutSection = NSCollectionLayoutSection(group: group)

    // Add spacing based on section type
    switch section {
    case .loadMoreParents:
      layoutSection.interGroupSpacing = 0
    case .parentPosts:
      layoutSection.interGroupSpacing = 3
      layoutSection.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 0, bottom: 0, trailing: 0)
    case .mainPost:
      layoutSection.interGroupSpacing = 0
    case .replies:
      layoutSection.interGroupSpacing = 9
    case .bottomSpacer:
      break
    }

    return layoutSection
  }

  private func createCompositionalLayout() -> UICollectionViewLayout {
    // Cache height estimates to avoid redundant calculations
    let heightCache = NSCache<NSString, NSNumber>()

    let layoutProvider: UICollectionViewCompositionalLayoutSectionProvider = {
      [weak self] (sectionIndex, _) -> NSCollectionLayoutSection? in
      guard let self = self, let section = Section(rawValue: sectionIndex) else { return nil }

      // Check cache first to avoid redundant calculations
      let cacheKey = "section_\(sectionIndex)" as NSString
      if let cachedHeight = heightCache.object(forKey: cacheKey) {
        return self.createSection(with: cachedHeight.doubleValue, for: section)
      }

      // Get snapshot for item-specific height calculations
      var estimatedHeight: CGFloat

      // Use more accurate height estimates based on content
      switch section {
      case .loadMoreParents:
        estimatedHeight = 50  // Fixed height for load more button

      case .parentPosts:
        if !self.parentPosts.isEmpty {
          // Try to use real content for better estimates
          if let firstParent = self.parentPosts.first {
            estimatedHeight = self.heightCalculator.calculateParentPostHeight(for: firstParent)
          } else {
            estimatedHeight = 150  // Fallback
          }
        } else {
          estimatedHeight = 150  // Default if no parents
        }

      case .mainPost:
        if let mainPost = self.mainPost {
          // Calculate main post height including any special styling
          estimatedHeight = self.heightCalculator.calculateHeight(
            for: mainPost,
            mode: .mainPost
          )
        } else {
          estimatedHeight = 300  // Default fallback
        }

      case .replies:
        if !self.replyWrappers.isEmpty {
          // Get average height from actual replies
          if let firstReply = self.replyWrappers.first {
            estimatedHeight = self.heightCalculator.calculateReplyHeight(
              for: firstReply,
              showingNestedReply: firstReply.hasReplies
            )
          } else {
            estimatedHeight = 180  // Fallback
          }
        } else {
          estimatedHeight = 180  // Default if no replies
        }

      case .bottomSpacer:
        estimatedHeight = 600
      }

      // Cache for future use
      heightCache.setObject(NSNumber(value: Double(estimatedHeight)), forKey: cacheKey)

      return self.createSection(with: estimatedHeight, for: section)
    }

    // Use our custom layout that maintains scroll position
    let layout = ThreadCompositionalLayout(sectionProvider: layoutProvider)

    // Tell the layout which section contains the main post
    layout.setMainPostSectionIndex(Section.mainPost.rawValue)

    // Add configuration for self-sizing cells
    let config = UICollectionViewCompositionalLayoutConfiguration()
    config.interSectionSpacing = 0
    layout.configuration = config

    return layout
  }

  // MARK: - Data Source Creation
  private func createDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
    let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
      collectionView: collectionView
    ) { [weak self] (collectionView, indexPath, item) -> UICollectionViewCell? in
      guard let self = self else { return nil }

      switch item {
      case .loadMoreParentsTrigger:
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "LoadMoreCell", for: indexPath)
          as! LoadMoreCell
        cell.configure(isLoading: self.isLoadingMoreParents)
        return cell

      case .parentPost(let parentPost):
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "ParentPostCell", for: indexPath)
          as! ParentPostCell
        cell.configure(
          parentPost: parentPost,
          appState: self.appState,
          path: self.path
        )
        return cell

      case .mainPost(let post):
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "MainPostCell", for: indexPath)
          as! MainPostCell
        cell.configure(
          post: post,
          appState: self.appState,
          path: self.path
        )
        return cell

      case .reply(let replyWrapper):
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "ReplyCell", for: indexPath)
          as! ReplyCell
        cell.configure(
          replyWrapper: replyWrapper,
          opAuthorID: self.mainPost?.author.did.didString() ?? "",
          appState: self.appState,
          path: self.path
        )
        return cell
      case .spacer:
        return collectionView.dequeueReusableCell(withReuseIdentifier: "SpacerCell", for: indexPath)
      }
    }

    return dataSource
  }

  // MARK: - Thread Loading Logic
  private func loadInitialThread() {
    Task(priority: .userInitiated) { @MainActor in
      controllerLogger.debug("🧵 THREAD LOAD: Starting initial thread load for URI: \(self.postURI.uriString())")
      isLoading = true

      threadManager = ThreadManager(appState: appState)
      await threadManager?.loadThread(uri: postURI)

      // Check if the thread has no parent posts
      if let threadViewPost = threadManager?.threadViewPost,
        case .appBskyFeedDefsThreadViewPost(let threadData) = threadViewPost {
        if !threadData.hasParentPosts() {
          controllerLogger.debug("🧵 THREAD LOAD: This thread has no parent posts, marking as top of thread")
          hasReachedTopOfThread = true
        }
      }

      processThreadData()

      // Pre-calculate all post heights
      if let mainPost = self.mainPost {
        _ = heightCalculator.calculateHeight(for: mainPost, mode: .mainPost)
        
        for parent in parentPosts {
          _ = heightCalculator.calculateParentPostHeight(for: parent)
        }
        
        for reply in replyWrappers {
          _ = heightCalculator.calculateReplyHeight(for: reply, showingNestedReply: reply.hasReplies)
        }
      }

      loadingView.isHidden = true
      
      // Apply snapshot synchronously
      updateDataSnapshot(animatingDifferences: false)
      
      isLoading = false

      if mainPost != nil && !hasScrolledToMainPost {
        // Wait for collection view to complete layout after snapshot application
        // This is crucial when load more cell is present
        collectionView.performBatchUpdates({
          // Force layout update
          self.collectionView.layoutIfNeeded()
        }) { _ in
          // Now scroll to main post after layout is complete
          self.scrollToMainPostWithPartialParentVisibility(animated: false)
          self.hasScrolledToMainPost = true
          
          // Fade in collection view
          UIView.animate(withDuration: 0.25) {
            self.collectionView.alpha = 1
          } completion: { _ in
            // If VoiceOver is running, post focus to main post
            if UIAccessibility.isVoiceOverRunning {
              self.focusVoiceOverOnMainPost()
            }
          }
        }
      } else {
        UIView.animate(withDuration: 0.25) {
          self.collectionView.alpha = 1
        } completion: { _ in
          // If VoiceOver is running, post focus to main post
          if UIAccessibility.isVoiceOverRunning {
            self.focusVoiceOverOnMainPost()
          }
        }
      }
    }
  }

  private func processThreadData() {
    guard let threadManager = threadManager,
      let threadUnion = threadManager.threadViewPost
    else {
      return
    }

    switch threadUnion {
    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
      parentPosts = collectParentPosts(from: threadViewPost.parent)
      mainPost = threadViewPost.post

      if let replies = threadViewPost.replies {
        var newReplyWrappers = selectRelevantReplies(
          replies, opAuthorID: threadViewPost.post.author.did.didString())
        
        // If we have optimistic updates, merge them with server data
        if hasOptimisticUpdates && !optimisticReplyUris.isEmpty {
          // Keep track of which optimistic replies are confirmed by server
          var confirmedOptimisticUris = Set<String>()
          
          // Check if any server replies match our optimistic URIs
          for wrapper in newReplyWrappers {
            if case .appBskyFeedDefsThreadViewPost(let post) = wrapper.reply {
              if optimisticReplyUris.contains(post.post.uri.uriString()) {
                confirmedOptimisticUris.insert(post.post.uri.uriString())
              }
            }
          }
          
          // Add unconfirmed optimistic replies back to the list
          for existingWrapper in replyWrappers {
            if case .appBskyFeedDefsThreadViewPost(let post) = existingWrapper.reply {
              let uri = post.post.uri.uriString()
              if optimisticReplyUris.contains(uri) && !confirmedOptimisticUris.contains(uri) {
                // This is an optimistic reply not yet on server, keep it
                newReplyWrappers.append(existingWrapper)
              }
            }
          }
          
          // Remove confirmed optimistic URIs
          optimisticReplyUris.subtract(confirmedOptimisticUris)
          
          // Clear optimistic state if all updates are confirmed
          if optimisticReplyUris.isEmpty {
            hasOptimisticUpdates = false
          }
        }
        
        replyWrappers = newReplyWrappers
      } else {
        // No replies from server, but check if we have optimistic ones
        if hasOptimisticUpdates && !replyWrappers.isEmpty {
          // Keep existing optimistic replies
          let optimisticReplies = replyWrappers.filter { wrapper in
            if case .appBskyFeedDefsThreadViewPost(let post) = wrapper.reply {
              return optimisticReplyUris.contains(post.post.uri.uriString())
            }
            return false
          }
          replyWrappers = optimisticReplies
        } else {
          replyWrappers = []
        }
      }

    default:
      parentPosts = []
      mainPost = nil
      replyWrappers = []
    }
  }

  private func updateDataSnapshot(animatingDifferences: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

    // Add all sections
    snapshot.appendSections(Section.allCases)

    // Add load more trigger if we have parent posts and haven't reached the top
    if !parentPosts.isEmpty && !hasReachedTopOfThread {
      snapshot.appendItems([.loadMoreParentsTrigger], toSection: .loadMoreParents)
    }

    // Add parent posts in reverse chronological order (oldest first, newest last)
    let parentItems = parentPosts.reversed().map { Item.parentPost($0) }
    snapshot.appendItems(parentItems, toSection: .parentPosts)

    // Add main post if available
    if let mainPost = mainPost {
      snapshot.appendItems([.mainPost(mainPost)], toSection: .mainPost)
    }

    // Add replies
    let replyItems = replyWrappers.map { Item.reply($0) }
    snapshot.appendItems(replyItems, toSection: .replies)

    // Add bottom spacer
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)

    // Apply snapshot synchronously
    dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
  }

  private func updateLoadingCell(isLoading: Bool) {
    // Update the load more cell to show loading state
    var snapshot = dataSource.snapshot()
    guard let loadMoreItem = snapshot.itemIdentifiers(inSection: .loadMoreParents).first else {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: No loading cell found to update")
      return
    }

    snapshot.reconfigureItems([loadMoreItem])
    dataSource.apply(snapshot, animatingDifferences: false)
    controllerLogger.debug("⬆️ LOAD MORE PARENTS: Updated loading cell, isLoading = \(isLoading)")
  }

  // Helper method to detect content changes between parent posts arrays
  private func hasParentPostContentChanged(oldPosts: [ParentPost], newPosts: [ParentPost]) -> Bool {
    // Different length means different content
    if oldPosts.count != newPosts.count {
      return true
    }

    // Check for content differences
    for i in 0..<oldPosts.count {
      let oldPost = oldPosts[i]
      let newPost = newPosts[i]

      // If IDs are different, content has definitely changed
      if oldPost.id != newPost.id {
        return true
      }

      // Check for content differences in the post data
      // Even if IDs match, the post content could have been updated
      switch (oldPost.post, newPost.post) {
      case (
        .appBskyFeedDefsThreadViewPost(let oldThreadPost),
        .appBskyFeedDefsThreadViewPost(let newThreadPost)
      ):
        // Compare post URIs
        if oldThreadPost.post.uri.uriString() != newThreadPost.post.uri.uriString() {
          return true
        }

        // Check if parent structures are different
        if (oldThreadPost.parent == nil) != (newThreadPost.parent == nil) {
          return true
        }

        // If both have parents, check the parent type and ID
        if let oldParent = oldThreadPost.parent, let newParent = newThreadPost.parent {
          switch (oldParent, newParent) {
          case (
            .appBskyFeedDefsThreadViewPost(let oldParentPost),
            .appBskyFeedDefsThreadViewPost(let newParentPost)
          ):
            if oldParentPost.post.uri.uriString() != newParentPost.post.uri.uriString() {
              return true
            }
          default:
            // Different parent types
            if type(of: oldParent) != type(of: newParent) {
              return true
            }
          }
        }

        // Check for reply chain differences
        if (oldThreadPost.replies?.count ?? 0) != (newThreadPost.replies?.count ?? 0) {
          return true
        }

      default:
        // Different post types
        if type(of: oldPost.post) != type(of: newPost.post) {
          return true
        }
      }
    }

    // If we got here, no significant differences were found
    return false
  }

  // MARK: - Scrolling
    private func focusVoiceOverOnMainPost() {
        guard let mainPost = mainPost else { return }
        
        let snapshot = dataSource.snapshot()
        _ = Item.mainPost(mainPost)
        
        guard let sectionIndex = snapshot.indexOfSection(.mainPost),
              snapshot.numberOfItems(inSection: .mainPost) > 0 else {
            return
        }
        
        let indexPath = IndexPath(item: 0, section: sectionIndex)
        
        // Get the cell and post accessibility focus to it
        if let cell = collectionView.cellForItem(at: indexPath) {
            UIAccessibility.post(notification: .screenChanged, argument: cell)
        }
    }
    
    private func scrollToMainPostWithPartialParentVisibility(animated: Bool) {
        guard mainPost != nil else { return }
        
        // If VoiceOver is running and not animated, delay slightly
        if UIAccessibility.isVoiceOverRunning && !animated {
            // Give VoiceOver time to initialize before scrolling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScrollToMainPost(animated: false)
            }
        } else {
            performScrollToMainPost(animated: animated)
        }
    }
    
    private func performScrollToMainPost(animated: Bool) {
        guard let mainPost = mainPost else { return }
        
        // Find the index path for the main post
        let snapshot = dataSource.snapshot()
        _ = Item.mainPost(mainPost)
        
        guard let sectionIndex = snapshot.indexOfSection(.mainPost),
              snapshot.numberOfItems(inSection: .mainPost) > 0
        else {
            return
        }
        
        let indexPath = IndexPath(item: 0, section: sectionIndex)
        
        // Check if we have parent posts
        let hasParentPosts = !parentPosts.isEmpty
        
        let calculateAndApplyOffset = { (applyImmediately: Bool) -> CGFloat? in
            // First, layout the collection view to ensure all sizes are calculated
            self.collectionView.layoutIfNeeded()
            
            // Get the attributes for the main post
            guard let attributes = self.collectionView.layoutAttributesForItem(at: indexPath) else {
                // Fallback if we can't get attributes
                if applyImmediately {
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                }
                return nil
            }
            
            // Calculate offset to show main post with partial parent visibility
            let mainPostY = attributes.frame.origin.y
            
            let offset: CGFloat
            // Debug content insets
            let adjustedContentInset = self.collectionView.adjustedContentInset
            let safeAreaTop = self.view.safeAreaInsets.top
            
            self.controllerLogger.debug("🔍 POSITIONING DEBUG:")
            self.controllerLogger.debug("  - adjustedContentInset.top: \(adjustedContentInset.top)")
            self.controllerLogger.debug("  - safeAreaInsets.top: \(safeAreaTop)")
            self.controllerLogger.debug("  - mainPostY: \(mainPostY)")
            self.controllerLogger.debug("  - hasParentPosts: \(hasParentPosts)")
            
            if hasParentPosts {
                // Show 10pt of parent content when there are parent posts
                // Position main post just below navigation bar, with 10pt of parent showing above
                let partialParentVisibility: CGFloat = 10
                offset = max(0, mainPostY - safeAreaTop - partialParentVisibility)
                self.controllerLogger.debug("  - WITH parents offset: \(offset)")
            } else {
                // When there are no parent posts, the main post is at position 0
                // We want to scroll to show it just below the navigation bar
                // Since mainPostY is 0, we use negative offset to let automatic content inset handle positioning
                offset = -adjustedContentInset.top + 10
                self.controllerLogger.debug("  - NO parents offset: \(offset) (using negative offset for top positioning)")
            }
            
            // Apply the offset if requested
            if applyImmediately {
                // Apply the offset without animation for smoother experience
                self.collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                
                // Log the scroll position for debugging
                self.controllerLogger.debug("Scrolled to main post. Position: \(offset), hasParents: \(hasParentPosts)")
            }
            
            return offset
        }

      if animated {
        // For animated scrolling, use UIView animation with completion
        UIView.animate(
          withDuration: 0.2,
          animations: {
            _ = calculateAndApplyOffset(true)
          })
      } else {
        // For non-animated scrolling, do multiple passes to ensure stability

        // First pass - calculate initial position
        _ = calculateAndApplyOffset(true)

        // Second immediate pass - recalculate and apply refined position
        // This helps account for any layout adjustments after the first scroll
        _ = calculateAndApplyOffset(true)

        // Log position after immediate passes
        if let attrs = self.collectionView.layoutAttributesForItem(at: indexPath) {
          let visibleTop = attrs.frame.origin.y - self.collectionView.contentOffset.y
          self.controllerLogger.debug("INITIAL position - Main post visible top offset: \(visibleTop)pt")
        }

        // Final pass with transaction to track completion
        CATransaction.begin()
        CATransaction.setCompletionBlock {
          // Log positions after transaction completes to verify final position
          if let attrs = self.collectionView.layoutAttributesForItem(at: indexPath) {
            let visibleTop = attrs.frame.origin.y - self.collectionView.contentOffset.y
            self.controllerLogger.debug("FINAL position - Main post visible top offset: \(visibleTop)pt")
          }
        }
        CATransaction.setDisableActions(true)
        _ = calculateAndApplyOffset(true)
        CATransaction.commit()

        // Add a delayed verification pass to catch any post-layout position drift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
          if let attrs = self.collectionView.layoutAttributesForItem(at: indexPath) {
            let visibleTop = attrs.frame.origin.y - self.collectionView.contentOffset.y
            self.controllerLogger.debug(
              "DELAYED position check - Main post visible top offset: \(visibleTop)pt")

            // If position has drifted, correct it again
            let adjustedContentInset = self.collectionView.adjustedContentInset
            let safeAreaTop = self.view.safeAreaInsets.top
            
            let expectedVisibleTop: CGFloat
            let correctedOffset: CGFloat
            
            if hasParentPosts {
              // For threads with parents, expect main post to be positioned with 10pt of parent visible above nav bar
              expectedVisibleTop = safeAreaTop + 10
              correctedOffset = max(0, attrs.frame.origin.y - safeAreaTop - 10)
            } else {
              // For top-level posts, expect them 10pt below nav bar
              expectedVisibleTop = 10
              correctedOffset = -adjustedContentInset.top + 10
            }
            
            if abs(visibleTop - expectedVisibleTop) > 2 {  // Allow 2pt tolerance
              self.controllerLogger.debug("Correcting position drift to: \(correctedOffset)")

              // Use transaction to ensure it applies cleanly
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              self.collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)
              CATransaction.commit()
            }
          }
        }
      }
    }

  // MARK: - Load More Parents
  @MainActor
  func loadMoreParents() {
    controllerLogger.debug(
      "⬆️ LOAD MORE PARENTS TRIGGERED - attempt #\(self.parentLoadAttempts+1), scrollY: \(self.collectionView.contentOffset.y), parentPosts: \(self.parentPosts.count)"
    )

    // Check if we can load more
    guard !hasReachedTopOfThread,
          !isLoadingMoreParents,
          let threadManager = threadManager,
          !parentPosts.isEmpty,
          mainPost != nil else {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Skipped - conditions not met")
      return
    }

    // Cooldown check
    if let lastLoadTime = lastParentLoadTime, Date().timeIntervalSince(lastLoadTime) < 0.2 {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Cooldown active")
      return
    }

    parentLoadAttempts += 1
    isLoadingMoreParents = true
    lastParentLoadTime = Date()
    
    // Capture scroll anchor BEFORE any changes (critical for thread reverse infinite scroll)
    let scrollAnchor = scrollPositionTracker.captureScrollAnchor(collectionView: collectionView)
    
    // Log anchor capture for debugging
    if let anchor = scrollAnchor {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Captured scroll anchor - section: \(anchor.indexPath.section), item: \(anchor.indexPath.item), mainPostY: \(anchor.mainPostFrameY)")
    } else {
      controllerLogger.warning("⬆️ LOAD MORE PARENTS: Failed to capture scroll anchor - position may jump")
    }
    
    // Enable smooth transitions during the update
    updateLink?.requiresContinuousUpdates = true
    
    let oldestParent = parentPosts.last!
    
    // Start loading animation
    updateLoadingCell(isLoading: true)
    
    Task { @MainActor in
      // Get oldest parent URI
      var postURI: ATProtocolURI?
      
      var oldestParentPost = oldestParent.post
      if case .pending = oldestParentPost {
        await oldestParentPost.loadPendingData()
      }
      
      if case .appBskyFeedDefsThreadViewPost(let threadViewPost) = oldestParentPost {
        postURI = threadViewPost.post.uri
      } else {
        // Search for valid parent
        for i in (0..<parentPosts.count - 1).reversed() {
          if case .appBskyFeedDefsThreadViewPost(let post) = parentPosts[i].post {
            postURI = post.post.uri
            break
          }
        }
      }
      
      guard let postURI = postURI else {
        isLoadingMoreParents = false
        updateLoadingCell(isLoading: false)
        return
      }
      
      // Load more parents
      let success = await threadManager.loadMoreParents(uri: postURI)
      
      guard success,
            let threadUnion = threadManager.threadViewPost,
            case .appBskyFeedDefsThreadViewPost(let threadViewPost) = threadUnion else {
        isLoadingMoreParents = false
        updateLoadingCell(isLoading: false)
        return
      }
      
      // Get new parent chain
      let fullChainFromManager = collectParentPosts(from: threadViewPost.parent)
      
      // Check if we have the complete chain with root post
      let hasRootPost = fullChainFromManager.last.map { parent in
        if case .appBskyFeedDefsThreadViewPost(let post) = parent.post {
          return post.parent == nil
        }
        return false
      } ?? false
      
      // Check if we actually got new parents or content changes
      if fullChainFromManager.count <= parentPosts.count {
        controllerLogger.debug("⬆️ LOAD MORE PARENTS: No new parents added (current: \(self.parentPosts.count), new: \(fullChainFromManager.count))")
        
        // Even if count is same, we might have gotten the root post now
        if hasRootPost {
          controllerLogger.debug("⬆️ LOAD MORE PARENTS: Found root post, updating view")
          // Update the view with the complete chain including root
          updateDataWithNewParents(fullChainFromManager, scrollAnchor: scrollAnchor)
          return
        }
        
        // Only mark as reached top if we truly have no more parents to load
        if fullChainFromManager.isEmpty {
          controllerLogger.debug("⬆️ LOAD MORE PARENTS: No parents at all, reached top")
          hasReachedTopOfThread = true
          
          // Remove the load more trigger
          var snapshot = dataSource.snapshot()
          if let loadMoreItem = snapshot.itemIdentifiers(inSection: .loadMoreParents).first {
            snapshot.deleteItems([loadMoreItem])
              await dataSource.apply(snapshot, animatingDifferences: true)
          }
        }
        
        isLoadingMoreParents = false
        updateLoadingCell(isLoading: false)
        return
      }
      
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Adding \(fullChainFromManager.count - self.parentPosts.count) new parents")
      
      // Update data with coordinated updates
      updateDataWithNewParents(fullChainFromManager, scrollAnchor: scrollAnchor)
    }
  }

  // Coordinated update method using proven scroll position restoration pattern adapted for threads
  @MainActor
  private func updateDataWithNewParents(_ newParents: [ParentPost], scrollAnchor: ThreadScrollPositionTracker.ScrollAnchor?) {
    controllerLogger.debug("⬆️ LOAD MORE PARENTS: Starting update with thread-aware scroll position restoration")
    
    // Pre-calculate heights for new parents for better layout stability
    let newParentsCount = newParents.count - parentPosts.count
    controllerLogger.debug("⬆️ LOAD MORE PARENTS: Pre-calculating heights for \(newParentsCount) new parents")
    for parent in newParents.prefix(newParentsCount) {
      _ = heightCalculator.calculateParentPostHeight(for: parent)
    }
    
    // Update model data
    let oldParentCount = parentPosts.count
    parentPosts = newParents
    
    // Check if we now have the root post
    let hasRootPost = parentPosts.last.map { parent in
      if case .appBskyFeedDefsThreadViewPost(let post) = parent.post {
        return post.parent == nil
      }
      return false
    } ?? false
    
    if hasRootPost {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Root post found, marking thread top reached")
      hasReachedTopOfThread = true
    }
    
    // Create new snapshot with updated data
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections(Section.allCases)
    
    // Add load more trigger only if we haven't reached the top
    if !parentPosts.isEmpty && !hasReachedTopOfThread {
      snapshot.appendItems([.loadMoreParentsTrigger], toSection: .loadMoreParents)
    }
    
    // Add parent posts in reverse chronological order (oldest first, newest last)
    let parentItems = parentPosts.reversed().map { Item.parentPost($0) }
    snapshot.appendItems(parentItems, toSection: .parentPosts)
    
    // Add main post
    if let mainPost = mainPost {
      snapshot.appendItems([.mainPost(mainPost)], toSection: .mainPost)
    }
    
    // Add replies 
    let replyItems = replyWrappers.map { Item.reply($0) }
    snapshot.appendItems(replyItems, toSection: .replies)
    
    // Add bottom spacer
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)
    
    // Apply snapshot immediately for layout calculation
    dataSource.apply(snapshot, animatingDifferences: false)
    
    // Use sophisticated position preservation like feed view
    Task { @MainActor in
      if #available(iOS 18.0, *) {
        await applyParentPostsWithPrecisePreservation(
          newParentsCount: newParentsCount,
          oldParentCount: oldParentCount,
          scrollAnchor: scrollAnchor
        )
      } else {
        // Fallback to simple position preservation for older iOS
        await applyParentPostsWithSimplePreservation(newParentsCount: newParentsCount)
      }
      
      // Clean up loading state after positioning
      isLoadingMoreParents = false
      updateLoadingCell(isLoading: false)
      
      // Disable continuous updates now that loading is complete
      updateLink?.requiresContinuousUpdates = false
      
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Successfully added \(newParentsCount) parents with precise position preservation")
    }
  }
  
  // MARK: - Precise Position Preservation for Parent Posts (iOS 18+)
  
  @available(iOS 18.0, *)
  @MainActor
  private func applyParentPostsWithPrecisePreservation(
    newParentsCount: Int,
    oldParentCount: Int,
    scrollAnchor: ThreadScrollPositionTracker.ScrollAnchor?
  ) async {
    // Capture precise scroll anchor before any changes (thread-specific approach)
    let preciseAnchor = captureThreadPreciseAnchor(from: collectionView)
    
    guard let anchor = preciseAnchor else {
      // Fallback to simple preservation if anchor capture fails
      await applyParentPostsWithSimplePreservation(newParentsCount: newParentsCount)
      return
    }
    
    // Store current post URIs to track content changes (include all thread content)
    let currentPostIds = (
      parentPosts.map { $0.post.uri.uriString() } + 
      [mainPost?.uri.uriString()].compactMap { $0 } +
      replyWrappers.map { $0.post.uri.uriString() }
    )
    
    // Apply atomic update with position preservation (like feed view does)
    await applyAtomicParentUpdateWithPreservation(
      anchor: anchor,
      newParentsCount: newParentsCount,
      currentPostIds: currentPostIds
    )
    
    controllerLogger.debug("✅ Applied precise position preservation for \(newParentsCount) parent posts")
  }
  
  @available(iOS 18.0, *)
  @MainActor
  private func applyAtomicParentUpdateWithPreservation(
    anchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor,
    newParentsCount: Int,
    currentPostIds: [String]
  ) async {
    // Step 1: Calculate target position using layout estimation (like feed view)
    var targetOffset: CGPoint?
    
    // Find where the anchor post will be after parent posts are added
    if let anchorIndex = currentPostIds.firstIndex(of: anchor.postId) {
      // Account for the new parents that will be inserted above
      let newAnchorIndex = anchorIndex + newParentsCount
      
      // Estimate the new position based on current layout
      if let currentFirstVisible = collectionView.indexPathsForVisibleItems.sorted().first,
         let currentAttributes = collectionView.layoutAttributesForItem(at: currentFirstVisible) {
        
        let estimatedItemHeight = currentAttributes.frame.height
        let estimatedItemY = CGFloat(newAnchorIndex) * estimatedItemHeight
        let safeAreaTop = collectionView.adjustedContentInset.top
        
        // Calculate target offset to maintain viewport position (viewport-relative positioning)
        let targetOffsetY = estimatedItemY - anchor.viewportRelativeY
        
        // Clamp to valid bounds
        let minOffset = -safeAreaTop
        let maxEstimatedContentHeight = CGFloat(currentPostIds.count + newParentsCount) * estimatedItemHeight
        let maxOffset = max(minOffset, maxEstimatedContentHeight - collectionView.bounds.height + safeAreaTop)
        
        targetOffset = CGPoint(
          x: 0,
          y: max(minOffset, min(targetOffsetY, maxOffset))
        )
      }
    }
    
    // Step 2: Apply atomic changes with UIUpdateLink coordination (like feed view)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Enable UIUpdateLink for smooth coordination
    updateLink?.requiresContinuousUpdates = true
    
    // Step 3: Set estimated position immediately to prevent visual flash
    if let targetOffset = targetOffset {
      collectionView.setContentOffset(targetOffset, animated: false)
    }
    
    // Step 4: Force layout to get accurate positions
    collectionView.layoutIfNeeded()
    
    // Step 5: Fine-tune position with actual layout data using thread-specific calculation
    if let finalTargetOffset = calculateThreadTargetOffset(
      for: anchor,
      newPostIds: currentPostIds,
      in: collectionView
    ) {
      collectionView.setContentOffset(finalTargetOffset, animated: false)
      controllerLogger.debug("🎯 Applied fine-tuned thread position: \(finalTargetOffset.y)")
    } else {
      controllerLogger.debug("⚠️ Thread fine-tuning failed - using estimated position")
    }
    
    CATransaction.commit()
    
    controllerLogger.debug("✅ Applied atomic parent update with precise position preservation")
  }
  
  @MainActor
  private func applyParentPostsWithSimplePreservation(newParentsCount: Int) async {
    // Fallback implementation for iOS < 18
    let newParentHeight = CGFloat(newParentsCount) * estimatedParentPostHeight
    let currentOffset = collectionView.contentOffset.y
    let adjustedOffset = CGPoint(x: 0, y: currentOffset + newParentHeight)
    
    // Preserve scroll position by offsetting for new content above
    collectionView.setContentOffset(adjustedOffset, animated: false)
    
    controllerLogger.debug("✅ Applied simple position preservation for \(newParentsCount) parent posts")
  }
  
  // MARK: - Thread-Specific Anchor Capture
  
  @available(iOS 18.0, *)
  @MainActor
  private func captureThreadPreciseAnchor(from collectionView: UICollectionView) -> OptimizedScrollPreservationSystem.PreciseScrollAnchor? {
    // Get the first visible item to use as anchor
    guard let firstVisibleIndexPath = collectionView.indexPathsForVisibleItems.sorted().first,
          let attributes = collectionView.layoutAttributesForItem(at: firstVisibleIndexPath) else {
      controllerLogger.debug("⚠️ No visible items for anchor capture")
      return nil
    }
    
    // Get the post URI for this index path from thread structure
    let postId: String
    switch firstVisibleIndexPath.section {
    case 0: // Parent posts
      guard firstVisibleIndexPath.item < parentPosts.count else {
        controllerLogger.debug("⚠️ Parent index out of bounds: \(firstVisibleIndexPath.item)")
        return nil
      }
      postId = parentPosts[firstVisibleIndexPath.item].post.uri.uriString()
      
    case 1: // Main post
      guard let mainPostUri = mainPost?.uri.uriString() else {
        controllerLogger.debug("⚠️ Main post has no URI")
        return nil
      }
      postId = mainPostUri
      
    case 2: // Replies
      guard firstVisibleIndexPath.item < replyWrappers.count else {
        controllerLogger.debug("⚠️ Reply index out of bounds: \(firstVisibleIndexPath.item)")
        return nil
      }
      postId = replyWrappers[firstVisibleIndexPath.item].post.uri.uriString()
      
    default:
      controllerLogger.debug("⚠️ Unknown section for anchor capture: \(firstVisibleIndexPath.section)")
      return nil
    }
    
    // Calculate viewport-relative position
    let safeAreaTop = collectionView.adjustedContentInset.top
    let currentContentOffset = collectionView.contentOffset.y
    let viewportRelativeY = attributes.frame.origin.y - (currentContentOffset + safeAreaTop)
    
    let anchor = OptimizedScrollPreservationSystem.PreciseScrollAnchor(
      indexPath: firstVisibleIndexPath,
      postId: postId,
      contentOffset: collectionView.contentOffset,
      viewportRelativeY: viewportRelativeY,
      itemFrameY: attributes.frame.origin.y,
      itemHeight: attributes.frame.height,
      visibleHeightInViewport: min(attributes.frame.height, collectionView.bounds.height),
      timestamp: CACurrentMediaTime(),
      displayScale: UIScreen.main.scale
    )
    
    controllerLogger.debug("🎯 Thread anchor captured - section: \(firstVisibleIndexPath.section), item: \(firstVisibleIndexPath.item), postId: \(postId)")
    return anchor
  }
  
  // MARK: - Thread-Specific Position Calculation
  
  @available(iOS 18.0, *)
  @MainActor
  private func calculateThreadTargetOffset(
    for anchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor,
    newPostIds: [String],
    in collectionView: UICollectionView
  ) -> CGPoint? {
    // Create a mapping from thread content to collection view indices
    let threadContentToIndexPath: [String: IndexPath] = {
      var mapping: [String: IndexPath] = [:]
      
      // Parent posts section (section 0)
      for (index, parentPost) in parentPosts.enumerated() {
        mapping[parentPost.post.uri.uriString()] = IndexPath(item: index, section: 0)
      }
      
      // Main post section (section 1, item 0)
      if let mainPostUri = mainPost?.uri.uriString() {
        mapping[mainPostUri] = IndexPath(item: 0, section: 1)
      }
      
      // Replies section (section 2)
      for (index, replyWrapper) in replyWrappers.enumerated() {
        mapping[replyWrapper.post.uri.uriString()] = IndexPath(item: index, section: 2)
      }
      
      return mapping
    }()
    
    // Find the anchor post's new index path
    guard let anchorIndexPath = threadContentToIndexPath[anchor.postId] else {
      controllerLogger.debug("⚠️ Thread anchor post not found: \(anchor.postId)")
      return nil
    }
    
    // Get the actual layout attributes for the anchor post
    guard let anchorAttributes = collectionView.layoutAttributesForItem(at: anchorIndexPath) else {
      controllerLogger.debug("⚠️ No layout attributes for anchor at \(anchorIndexPath)")
      return nil
    }
    
    // Calculate target offset using viewport-relative positioning
    let safeAreaTop = collectionView.adjustedContentInset.top
    let targetOffsetY = anchorAttributes.frame.origin.y - safeAreaTop - anchor.viewportRelativeY
    
    // Clamp to valid content bounds
    let minOffset = -safeAreaTop
    let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    
    let clampedOffsetY = max(minOffset, min(targetOffsetY, maxOffset))
    
    controllerLogger.debug("🎯 Thread target calculation - anchor: \(anchor.postId), indexPath: \(anchorIndexPath), targetY: \(clampedOffsetY)")
    
    return CGPoint(x: 0, y: clampedOffsetY)
  }
  
  // MARK: - Scroll Position Restoration with Retry Logic
  
  @MainActor
  private func restoreScrollPositionWithRetry(anchor: ThreadScrollPositionTracker.ScrollAnchor?, newParentsCount: Int, oldParentCount: Int) async {
    guard let anchor = anchor else {
      controllerLogger.warning("⬆️ RESTORE: No anchor available - position may jump")
      return
    }
    
    controllerLogger.debug("⬆️ RESTORE: Starting position restoration with \(FeedConstants.maxScrollRestorationAttempts) max attempts")
    
    var attempts = 0
    let maxAttempts = FeedConstants.maxScrollRestorationAttempts
    var lastOffset: CGFloat = collectionView.contentOffset.y
    
    while attempts < maxAttempts {
      attempts += 1
      
      // Force layout calculation
      collectionView.layoutIfNeeded()
      
      // Attempt restoration
      scrollPositionTracker.restoreScrollPosition(collectionView: collectionView, to: anchor)
      
      // Verify restoration success
      let currentOffset = collectionView.contentOffset.y
      let offsetDifference = abs(currentOffset - lastOffset)
      
      // If position stabilized or we have reasonable position, we're done
      if offsetDifference < FeedConstants.scrollRestorationVerificationThreshold || isPositionReasonable(currentOffset: currentOffset, anchor: anchor) {
        controllerLogger.debug("⬆️ RESTORE: Position restored successfully after \(attempts) attempts (offset: \(currentOffset))")
        break
      }
      
      lastOffset = currentOffset
      
      // Wait before next attempt (exponential backoff)
      let delay = Double(attempts) * 0.1 // 100ms, 200ms, 300ms
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      
      controllerLogger.debug("⬆️ RESTORE: Attempt \(attempts) incomplete, offset difference: \(offsetDifference)")
    }
    
    if attempts >= maxAttempts {
      controllerLogger.warning("⬆️ RESTORE: Failed to restore position after \(maxAttempts) attempts - using final position")
    }
  }
  
  /// Validates if the current scroll position is reasonable for the thread layout
  private func isPositionReasonable(currentOffset: CGFloat, anchor: ThreadScrollPositionTracker.ScrollAnchor) -> Bool {
    // Check bounds
    let contentHeight = collectionView.contentSize.height
    let viewHeight = collectionView.bounds.height
    let maxOffset = max(0, contentHeight - viewHeight)
    
    guard currentOffset >= 0 && currentOffset <= maxOffset else {
      return false
    }
    
    // For main post anchors, verify main post is reasonably positioned
    if anchor.isMainPostAnchor {
      let mainPostIndexPath = IndexPath(item: 0, section: ThreadScrollPositionTracker.ThreadSection.mainPost.rawValue)
      if let mainPostAttributes = collectionView.layoutAttributesForItem(at: mainPostIndexPath) {
        let mainPostVisibleY = mainPostAttributes.frame.origin.y - currentOffset
        // Main post should be somewhere in the viewport (not completely off-screen)
        return mainPostVisibleY >= -mainPostAttributes.frame.height && mainPostVisibleY <= viewHeight
      }
    }
    
    return true
  }

  // MARK: - Helper Functions
  /// Gets the measured height of a cell if it has already been rendered
  private func getMeasuredCellHeight(section: Section, item: Int) -> CGFloat? {
    // Only try to get measured height if section exists and has items
    let snapshot = dataSource.snapshot()
    guard snapshot.numberOfSections > 0,
      snapshot.indexOfSection(section) != nil
    else {
      return nil
    }

    let items = snapshot.itemIdentifiers(inSection: section)
    guard items.count > item else {
      return nil
    }

    // Create an index path for the specified section and item
    let indexPath = IndexPath(item: item, section: section.rawValue)

    // Try to get the layout attributes for this cell
    if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
      // Return the measured height if the cell has been laid out
      let height = attributes.frame.height
      return height > 0 ? height : nil
    }

    // No valid measurement available
    return nil
  }

  private func collectParentPosts(from initialPost: AppBskyFeedDefs.ThreadViewPostParentUnion?)
    -> [ParentPost] {
    var parents: [ParentPost] = []
    var currentPost = initialPost
    var grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
    var depth = 0

    while let post = currentPost {
      depth += 1
      switch post {
      case .appBskyFeedDefsThreadViewPost(let threadViewPost):
        let postURI = threadViewPost.post.uri.uriString()
        parents.append(ParentPost(id: postURI, post: post, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = threadViewPost.post.author
        currentPost = threadViewPost.parent

      case .appBskyFeedDefsNotFoundPost(let notFoundPost):
        let uri = notFoundPost.uri.uriString()
        parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
        currentPost = nil

      case .appBskyFeedDefsBlockedPost(let blockedPost):
        let uri = blockedPost.uri.uriString()
        parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
        currentPost = nil

      case .pending(let pendingData):
        // Generate a more consistent ID for pending posts based on the type
        let pendingID = "pending-\(pendingData.type)-\(depth)"

        parents.append(ParentPost(id: pendingID, post: post, grandparentAuthor: grandparentAuthor))

        // Important: Don't terminate the chain, try to access parent if possible
        if let threadViewPost = try? post.getThreadViewPost() {
          currentPost = threadViewPost.parent
          controllerLogger.debug("collectParentPosts: Accessed parent through pending post")
        } else {
          currentPost = nil
          controllerLogger.debug("collectParentPosts: Could not access parent through pending post")
        }

      case .unexpected:
        let unexpectedID = "unexpected-\(depth)-\(UUID().uuidString.prefix(8))"
        controllerLogger.debug(
          "collectParentPosts: Found unexpected post type at depth \(depth): \(unexpectedID)")
        parents.append(
          ParentPost(id: unexpectedID, post: post, grandparentAuthor: grandparentAuthor))
        currentPost = nil
      }
    }

    if !parents.isEmpty {
      //        controllerLogger.debug("collectParentPosts: Parent URIs in order: \(parents.map { $0.id }.joined(separator: ", ")}")
    }

    return parents
  }

  private func selectRelevantReplies(
    _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion], opAuthorID: String
  ) -> [ReplyWrapper] {
    // First, convert replies to ReplyWrapper and extract relevant information
    let wrappedReplies = replies.map { reply -> ReplyWrapper in
      let id = getReplyID(reply)
      let isFromOP =
        if case .appBskyFeedDefsThreadViewPost(let post) = reply {
          post.post.author.did.didString() == opAuthorID
        } else {
          false
        }
      let hasReplies =
        if case .appBskyFeedDefsThreadViewPost(let post) = reply {
          !(post.replies?.isEmpty ?? true)
        } else {
          false
        }
      return ReplyWrapper(id: id, reply: reply, depth: 0, isFromOP: isFromOP, hasReplies: hasReplies)
    }

    // Sort replies to prioritize:
    // 1. Replies from the original poster
    // 2. Replies that have their own replies (indicating discussion)
    // 3. Most recent replies
    return wrappedReplies.sorted { first, second in
      if first.isFromOP != second.isFromOP {
        return first.isFromOP
      }
      if first.hasReplies != second.hasReplies {
        return first.hasReplies
      }
      return first.id > second.id  // Assuming IDs are chronological
    }
  }

  private func getReplyID(_ reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion) -> String {
    switch reply {
    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
      return threadViewPost.post.uri.uriString()
    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
      return notFoundPost.uri.uriString()
    case .appBskyFeedDefsBlockedPost(let blockedPost):
      return blockedPost.uri.uriString()
    case .unexpected:
      return UUID().uuidString
    case .pending:
      return UUID().uuidString
    }
  }
  
  // MARK: - State Invalidation Handling
  
  // Properties for optimistic updates
  private var hasOptimisticUpdates = false
  private var optimisticReplyUris = Set<String>()
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    controllerLogger.debug("Thread handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .replyCreated(let reply, let parentUri):
      // Check if this reply is for our thread
      let currentPostUri = postURI.uriString()
      if parentUri == currentPostUri || isReplyToThreadPost(parentUri) {
        await MainActor.run {
          // Add the reply optimistically instead of reloading entire thread
          addReplyOptimistically(reply, toParentUri: parentUri)
        }
      }
      
    case .threadUpdated(let rootUri):
      // Check if this is our thread being updated
      let currentPostUri = postURI.uriString()
      if rootUri == currentPostUri || isThreadRelated(rootUri) {
        await MainActor.run {
          // Only reload if we don't already have the updates from optimistic additions
          if !hasOptimisticUpdates {
            reloadThread()
          }
        }
      }
      
    default:
      // Ignore other events
      break
    }
  }
  
  /// Helper function to check if a reply wrapper contains a post with given URI
  private func checkReplyWrapper(_ wrapper: ReplyWrapper, containsPostWithURI uri: String) -> Bool {
    switch wrapper.reply {
    case .appBskyFeedDefsThreadViewPost(let post):
      // Check if this post matches
      if post.post.uri.uriString() == uri {
        return true
      }
      // Check nested replies
      if let replies = post.replies {
        for reply in replies {
          if case .appBskyFeedDefsThreadViewPost(let nestedPost) = reply,
             nestedPost.post.uri.uriString() == uri {
            return true
          }
        }
      }
      return false
    default:
      return false
    }
  }
  
  /// Check if a post URI is a reply to any post in this thread
  private func isReplyToThreadPost(_ parentUri: String) -> Bool {
    // Check main post
    if let mainPost = mainPost, mainPost.uri.uriString() == parentUri {
      return true
    }
    
    // Check parent posts (ancestors)
    if parentPosts.contains(where: { $0.post.uri.uriString() == parentUri }) {
      return true
    }
    
    // Check existing replies
    for wrapper in replyWrappers {
      if checkReplyWrapper(wrapper, containsPostWithURI: parentUri) {
        return true
      }
    }
    
    return false
  }
  
  /// Check if a root URI is related to this thread
  private func isThreadRelated(_ rootUri: String) -> Bool {
    return rootUri == postURI.uriString()
  }
  
  /// Reload the thread to pick up new content
  private func reloadThread() {
    controllerLogger.info("Reloading thread due to state invalidation")
    
    // Cancel any pending load task
    pendingLoadTask?.cancel()
    
    // Start a new load task
    pendingLoadTask = Task { [weak self] in
      await self?.loadInitialThread()
    }
  }
  
  // MARK: - Optimistic Updates
  
  @MainActor
  private func addReplyOptimistically(_ reply: AppBskyFeedDefs.PostView, toParentUri parentUri: String) {
    controllerLogger.info("Adding reply optimistically: \(reply.uri.uriString()) to parent: \(parentUri)")
    
    // Mark that we have optimistic updates
    hasOptimisticUpdates = true
    optimisticReplyUris.insert(reply.uri.uriString())
    
    // Find where to insert the reply
    if parentUri == mainPost?.uri.uriString() {
      // Reply to main post - add to replies section
      let newReply = createReplyWrapper(from: reply)
      replyWrappers.append(newReply)
      
      // Update the collection view
      applySnapshotOptimistically()
    } else {
      // Reply to another reply - need to find and update the parent
      for (index, var wrapper) in replyWrappers.enumerated() {
        if updateReplyWrapper(&wrapper, withNewReply: reply, toParent: parentUri) {
          // Update the specific reply wrapper
          replyWrappers[index] = wrapper
          applySnapshotOptimistically()
          break
        }
      }
    }
    
    // Schedule a background refresh to get real data with retries
    Task {
      // Try multiple times to get the real data from server
      for attempt in 1...5 {
        try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) // 1.5s, 3s, 4.5s, 6s, 7.5s
        
        await MainActor.run {
          // Only reload if we still have unconfirmed optimistic updates
          if hasOptimisticUpdates && optimisticReplyUris.contains(reply.uri.uriString()) {
            controllerLogger.debug("Optimistic update refresh attempt \(attempt) for reply: \(reply.uri.uriString())")
            reloadThread()
          }
        }
        
        // Check if the optimistic update was confirmed
        let isConfirmed = await MainActor.run {
          !optimisticReplyUris.contains(reply.uri.uriString())
        }
        
        if isConfirmed {
          controllerLogger.debug("Optimistic reply confirmed after attempt \(attempt)")
          break
        }
      }
      
      // Final cleanup after all attempts
      await MainActor.run {
        if optimisticReplyUris.contains(reply.uri.uriString()) {
          controllerLogger.warning("Failed to confirm optimistic reply after 5 attempts, removing: \(reply.uri.uriString())")
          // Remove this specific optimistic reply
          optimisticReplyUris.remove(reply.uri.uriString())
          if optimisticReplyUris.isEmpty {
            hasOptimisticUpdates = false
          }
          // Reload one more time to clean up
          reloadThread()
        }
      }
    }
  }
  
  // Helper to create a reply wrapper from a PostView
  private func createReplyWrapper(from post: AppBskyFeedDefs.PostView) -> ReplyWrapper {
    // Create a ThreadViewPost from the PostView
    let threadViewPost = AppBskyFeedDefs.ThreadViewPost(
      post: post,
      parent: nil,
      replies: nil,
      threadContext: nil
    )
    
    let isFromOP = post.author.did.didString() == mainPost?.author.did.didString()
    
    return ReplyWrapper(
      id: post.uri.uriString(),
      reply: .appBskyFeedDefsThreadViewPost(threadViewPost),
      depth: 0,
      isFromOP: isFromOP,
      hasReplies: false
    )
  }
  
  // Helper to update nested replies
  private func updateReplyWrapper(_ wrapper: inout ReplyWrapper, withNewReply reply: AppBskyFeedDefs.PostView, toParent parentUri: String) -> Bool {
    switch wrapper.reply {
    case .appBskyFeedDefsThreadViewPost(var threadPost):
      // Check if this is the parent
      if threadPost.post.uri.uriString() == parentUri {
        // Add the new reply to this post's replies
        var replies = threadPost.replies ?? []
        let newReplyThread = AppBskyFeedDefs.ThreadViewPost(
          post: reply,
          parent: nil,
          replies: nil,
          threadContext: nil
        )
        replies.append(.appBskyFeedDefsThreadViewPost(newReplyThread))
        
        // Create a new ThreadViewPost with updated replies
        let updatedThreadPost = AppBskyFeedDefs.ThreadViewPost(
          post: threadPost.post,
          parent: threadPost.parent,
          replies: replies,
          threadContext: threadPost.threadContext
        )
        
        // Create a new wrapper with updated values
        wrapper = ReplyWrapper(
          id: wrapper.id,
          reply: .appBskyFeedDefsThreadViewPost(updatedThreadPost),
          depth: wrapper.depth,
          isFromOP: wrapper.isFromOP,
          hasReplies: true
        )
        return true
      }
      
      // Check nested replies recursively
      if var replies = threadPost.replies {
        for i in 0..<replies.count {
          if case .appBskyFeedDefsThreadViewPost(let nestedPost) = replies[i] {
            var nestedWrapper = ReplyWrapper(
              id: nestedPost.post.uri.uriString(),
              reply: replies[i],
              depth: wrapper.depth + 1,
              isFromOP: nestedPost.post.author.did.didString() == mainPost?.author.did.didString(),
              hasReplies: !(nestedPost.replies?.isEmpty ?? true)
            )
            
            if updateReplyWrapper(&nestedWrapper, withNewReply: reply, toParent: parentUri) {
              replies[i] = nestedWrapper.reply
              
              // Create a new ThreadViewPost with updated replies
              let updatedThreadPost = AppBskyFeedDefs.ThreadViewPost(
                post: threadPost.post,
                parent: threadPost.parent,
                replies: replies,
                threadContext: threadPost.threadContext
              )
              
              wrapper = ReplyWrapper(
                id: wrapper.id,
                reply: .appBskyFeedDefsThreadViewPost(updatedThreadPost),
                depth: wrapper.depth,
                isFromOP: wrapper.isFromOP,
                hasReplies: wrapper.hasReplies
              )
              return true
            }
          }
        }
      }
      
    default:
      break
    }
    
    return false
  }
  
  // Helper to apply snapshot with optimistic updates
  @MainActor
  private func applySnapshotOptimistically() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    
    // Add sections
    snapshot.appendSections(Section.allCases)
    
    if !hasReachedTopOfThread && !parentPosts.isEmpty {
      snapshot.appendItems([.loadMoreParentsTrigger], toSection: .loadMoreParents)
    }
    
    let parentItems = parentPosts.reversed().map { Item.parentPost($0) }
    snapshot.appendItems(parentItems, toSection: .parentPosts)
    
    if let mainPost = mainPost {
      snapshot.appendItems([.mainPost(mainPost)], toSection: .mainPost)
    }
    
    let replyItems = replyWrappers.map { Item.reply($0) }
    snapshot.appendItems(replyItems, toSection: .replies)
    
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)
    
    // Apply with animation for optimistic updates
    dataSource.apply(snapshot, animatingDifferences: true)
  }
}

// MARK: - UICollectionViewDelegate
extension ThreadViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)

    // Handle item selection if needed
    guard let section = Section(rawValue: indexPath.section) else { return }

    switch section {
    case .loadMoreParents:
      loadMoreParents()
    default:
      break
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // iOS 18: Simplified trigger detection
    let triggerThreshold = min(scrollView.frame.height * 0.2, 100.0)
    let isNearTop = scrollView.contentOffset.y < triggerThreshold
    
    // Check if we should trigger loading
    let shouldTrigger = isNearTop &&
                       !isLoadingMoreParents &&
                       !parentPosts.isEmpty &&
                       !hasReachedTopOfThread &&
                       pendingLoadTask == nil
    
    if shouldTrigger {
      // Cancel any existing task
      pendingLoadTask?.cancel()
      
      // Create debounced load task
      pendingLoadTask = Task { @MainActor [weak self] in
        guard let self = self else { return }
        
        do {
          // Debounce delay
          try await Task.sleep(nanoseconds: 150_000_000) // 150ms
          
          if !Task.isCancelled {
            self.loadMoreParents()
          }
        } catch {
          // Task cancelled
        }
        
        self.pendingLoadTask = nil
      }
    }
  }

  // MARK: - Prefetching
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    // Start loading content for these cells ahead of time
    // This can be implemented to preload images or other data
  }

  func collectionView(
    _ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    // Cancel any pending prefetch operations
  }
}

// MARK: - Cell Types
@available(iOS 18.0, *)
final class ParentPostCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(parentPost: ParentPost, appState: AppState, path: Binding<NavigationPath>) {
    // Set themed background color
      contentView.backgroundColor = .systemBackground
    
    let content = AnyView(
      ParentPostView(
        parentPost: parentPost,
        path: path,
        appState: appState
      )
      .padding(.horizontal, 3)
      .padding(.vertical, 3)
    )

    // Only reconfigure if needed (using post id as identity check)
    if contentConfiguration == nil
      || parentPost.id != (contentView.tag != 0 ? String(contentView.tag) : nil) {

      // Store post ID in tag for comparison on reuse
      contentView.tag = parentPost.id.hashValue

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
  }
}

@available(iOS 18.0, *)
final class MainPostCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
    
    // Make this an accessibility element container
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    contentView.shouldGroupAccessibilityChildren = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(post: AppBskyFeedDefs.PostView, appState: AppState, path: Binding<NavigationPath>) {
    // Set themed background color
      contentView.backgroundColor = .systemBackground
    
    // Avoid removing/readding subviews if configuration hasn't changed
    let content = AnyView(
      VStack(spacing: 0) {
        ThreadViewMainPostView(
          post: post,
          showLine: false,
          path: path,
          appState: appState
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 6)

        Divider()
          .padding(.bottom, 9)
      }
    )

    // Only reconfigure if needed (using post URI as identity check)
    if contentConfiguration == nil
      || post.uri.uriString() != (contentView.tag != 0 ? String(contentView.tag) : nil) {

      // Store identity in tag for comparison on reuse
      contentView.tag = post.uri.uriString().hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentConfiguration = nil
  }
}

@available(iOS 18.0, *)
final class ReplyCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // Background color will be set in configure method
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    replyWrapper: ReplyWrapper, opAuthorID: String, appState: AppState,
    path: Binding<NavigationPath>
  ) {
    // Set themed background color
      contentView.backgroundColor = .systemBackground
    
    let content = AnyView(
      VStack(spacing: 0) {
        ReplyView(
          replyWrapper: replyWrapper,
          opAuthorID: opAuthorID,
          path: path,
          appState: appState
        )
        .padding(.horizontal, 10)

        Divider()
          .padding(.vertical, 3)
      }
    )

    // Only reconfigure if needed (using reply id as identity check)
    if contentConfiguration == nil
      || replyWrapper.id != (contentView.tag != 0 ? String(contentView.tag) : nil) {

      // Store reply ID in tag for comparison on reuse
      contentView.tag = replyWrapper.id.hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentConfiguration = nil
  }
}

@available(iOS 18.0, *)
final class LoadMoreCell: UICollectionViewCell {
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
    // Background color will be set when we have access to appState
    
    // Make the entire cell invisible to VoiceOver
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    contentView.accessibilityElementsHidden = true
    
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.isAccessibilityElement = false
    
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Loading more parents..."
    label.font = UIFont.preferredFont(forTextStyle: .subheadline)
    label.textColor = UIColor.systemGray
    label.isAccessibilityElement = false
    
    let stackView = UIStackView(arrangedSubviews: [activityIndicator, label])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    stackView.isAccessibilityElement = false
    
    contentView.addSubview(stackView)
    
    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
    ])
  }

  func configure(isLoading: Bool) {
    // Only update if the state is changing to avoid unnecessary UI updates
    guard isLoading != isCurrentlyLoading else { return }

    isCurrentlyLoading = isLoading

    if isLoading {
      activityIndicator.startAnimating()
      label.isHidden = false
      label.text = "Loading more parents..."
      label.alpha = 1.0
    } else {
      activityIndicator.stopAnimating()
      label.isHidden = true
    }
  }

  private func findParentViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      responder = nextResponder
      if let viewController = responder as? UIViewController {
        return viewController
      }
    }
    return nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityIndicator.stopAnimating()
  }
}

@available(iOS 18.0, *)
final class SpacerCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // This cell doesn't need special background handling
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - Supporting SwiftUI Views
struct ParentPostView: View {
  let parentPost: ParentPost
  @Binding var path: NavigationPath
  var appState: AppState

  var body: some View {
    switch parentPost.post {
    case .appBskyFeedDefsThreadViewPost(let post):
      PostView(
        post: post.post,
        grandparentAuthor: nil,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .contentShape(Rectangle())
      .onTapGesture {
        path.append(NavigationDestination.post(post.post.uri))
      }

    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
      Text("Parent post not found \(notFoundPost.uri)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.red)

    case .appBskyFeedDefsBlockedPost(let blockedPost):
      BlockedPostView(blockedPost: blockedPost, path: $path)
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .unexpected(let unexpected):
      Text("Unexpected parent post type: \(unexpected.textRepresentation)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.orange)

    case .pending:
      EmptyView()
    }
  }
}

struct ReplyView: View {
  let replyWrapper: ReplyWrapper
  let opAuthorID: String
  @Binding var path: NavigationPath
  var appState: AppState

  var body: some View {
    switch replyWrapper.reply {
    case .appBskyFeedDefsThreadViewPost(let replyPost):
      recursiveReplyView(
        reply: replyPost,
        opAuthorID: opAuthorID,
        depth: 0,
        maxDepth: 3
      )
      .padding(.vertical, 3)
      .frame(maxWidth: 550, alignment: .leading)

    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
      Text("Reply not found: \(notFoundPost.uri.uriString())")
        .foregroundColor(.red)

    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedPostView(blockedPost: blocked, path: $path)

    case .unexpected(let unexpected):
      Text("Unexpected reply type: \(unexpected.textRepresentation)")
        .foregroundColor(.orange)

    case .pending:
      EmptyView()
    }
  }

  @ViewBuilder
  private func recursiveReplyView(
    reply: AppBskyFeedDefs.ThreadViewPost,
    opAuthorID: String,
    depth: Int,
    maxDepth: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Display the current reply
      // Only show connecting line if it has replies AND we haven't reached max depth
      let showConnectingLine = reply.replies?.isEmpty == false && depth < maxDepth

      PostView(
        post: reply.post,
        grandparentAuthor: nil,
        isParentPost: showConnectingLine,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .contentShape(Rectangle())
      .onTapGesture {
        path.append(NavigationDestination.post(reply.post.uri))
      }
      .padding(.vertical, 3)

      // If we're at max depth but there are more replies, show "Continue thread" button
      if depth == maxDepth && reply.replies?.isEmpty == false {
        Button(action: {
          path.append(NavigationDestination.post(reply.post.uri))
        }) {
          HStack {
            Text("Continue thread")
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.accentColor)
            Image(systemName: "chevron.right")
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.accentColor)
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
      }
      // If we haven't reached max depth and there are replies, show the next post
      else if depth < maxDepth, let replies = reply.replies, !replies.isEmpty {
        let topReply = selectMostRelevantReply(replies, opAuthorID: opAuthorID)

        if case .appBskyFeedDefsThreadViewPost(let nestedPost) = topReply {
          AnyView(
            recursiveReplyView(
              reply: nestedPost,
              opAuthorID: opAuthorID,
              depth: depth + 1,
              maxDepth: maxDepth
            )
          )
        }
      }
    }
  }

  // Helper function to select the most relevant nested reply to show
  private func selectMostRelevantReply(
    _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion], opAuthorID: String
  ) -> AppBskyFeedDefs.ThreadViewPostRepliesUnion {
    // Priority: 1) From OP, 2) Has replies itself, 3) Most recent

    // Check for replies from OP
    if let opReply = replies.first(where: { reply in
      if case .appBskyFeedDefsThreadViewPost(let post) = reply {
        return post.post.author.did.didString() == opAuthorID
      }
      return false
    }) {
      return opReply
    }

    // Check for replies that have their own replies
    if let threadReply = replies.first(where: { reply in
      if case .appBskyFeedDefsThreadViewPost(let post) = reply {
        return !(post.replies?.isEmpty ?? true)
      }
      return false
    }) {
      return threadReply
    }

    // Default to first reply
    return replies.first!
  }
}

// MARK: - SwiftUI Integration
@available(iOS 18.0, *)
struct ThreadViewControllerRepresentable: UIViewControllerRepresentable {
  @Environment(AppState.self) private var appState: AppState
  let postURI: ATProtocolURI
  @Binding var path: NavigationPath

  func makeUIViewController(context: Context) -> ThreadViewController {
    return ThreadViewController(appState: appState, postURI: postURI, path: $path)
  }

  func updateUIViewController(_ uiViewController: ThreadViewController, context: Context) {
    // Update controller if needed
  }
}

struct ThreadView: View {
  @Environment(AppState.self) private var appState: AppState
  let postURI: ATProtocolURI
  @Binding var path: NavigationPath

  var body: some View {
    ThreadViewControllerRepresentable(postURI: postURI, path: $path)
      .frame(maxWidth: 600)  // Ensure 600pt maximum width for better iPad experience
      .ignoresSafeArea()
//      .themedNavigationBar(appState.themeManager)
//      .applyTheme(appState.themeManager)
  }
}

extension AppBskyFeedDefs.ThreadViewPostParentUnion {
  func getThreadViewPost() throws -> AppBskyFeedDefs.ThreadViewPost? {
    switch self {
    case .appBskyFeedDefsThreadViewPost(let post):
      return post
    case .pending(let data):
      // Try to decode the pending data to get a ThreadViewPost
      if data.type == "app.bsky.feed.defs#threadViewPost" {
        do {
          let threadViewPost = try JSONDecoder().decode(
            AppBskyFeedDefs.ThreadViewPost.self, from: data.rawData)
          return threadViewPost
        } catch {
          return nil
        }
      }
      return nil
    default:
      return nil
    }
  }
  
  var uri: ATProtocolURI {
    switch self {
    case .appBskyFeedDefsThreadViewPost(let post):
      return post.post.uri
    case .appBskyFeedDefsNotFoundPost(let notFound):
      return notFound.uri
    case .appBskyFeedDefsBlockedPost(let blocked):
      return blocked.uri
    default:
      // Return a placeholder URI for other cases
      return try! ATProtocolURI(uriString: "at://unknown/unknown/unknown")
    }
  }
}

// Add helper methods to ThreadViewPostUnion to improve parent checking
extension AppBskyFeedGetPostThread.OutputThreadUnion {
  func getParent() -> AppBskyFeedDefs.ThreadViewPostParentUnion? {
    switch self {
    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
      return threadViewPost.parent
    default:
      return nil
    }
  }

  func hasParentPosts() -> Bool {
    if let parent = getParent() {
      switch parent {
      case .appBskyFeedDefsThreadViewPost:
        return true
      case .pending:
        return true
      default:
        return false
      }
    }
    return false
  }
}

extension AppBskyFeedDefs.ThreadViewPost {
  func hasParentPosts() -> Bool {
    if let parent = self.parent {
      switch parent {
      case .appBskyFeedDefsThreadViewPost:
        return true
      case .pending:
        return true
      default:
        return false
      }
    }
    return false
  }
}
