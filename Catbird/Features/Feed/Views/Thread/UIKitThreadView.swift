import Petrel
import SwiftUI
import UIKit
import os

// MARK: - UIKit Color Scheme Helper
extension UIViewController {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
        if let activeState = AppStateManager.shared.lifecycle.appState {
            return activeState.themeManager.effectiveColorScheme(for: systemScheme)
        }
        return systemScheme
    }
}

extension UIView {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
        if let activeState = AppStateManager.shared.lifecycle.appState {
            return activeState.themeManager.effectiveColorScheme(for: systemScheme)
        }
        return systemScheme
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
  
  // Hidden replies state
  private var hasOtherReplies = false  // Whether the thread has additional hidden replies
  private var isLoadingHiddenReplies = false  // Loading state for hidden replies
  private var hasLoadedHiddenReplies = false  // Whether hidden replies have been loaded
  
  // Theme observation
  private var themeObserver: UIKitStateObserver<ThemeManager>?
  
  // MARK: - UIUpdateLink for coordinated UI updates
  #if os(iOS) && !targetEnvironment(macCatalyst)
  @available(iOS 18.0, *)
  private var updateLink: UIUpdateLink?
  #endif
  private var scrollPositionTracker = ThreadScrollPositionTracker()

  private var parentPosts: [ParentPost] = []
  private var mainPost: AppBskyFeedDefs.PostView?
  private var opThreadContinuations: [ReplyWrapper] = []  // OP's thread continuations
  private var replyWrappers: [ReplyWrapper] = []  // Regular replies only
  private var nestedRepliesMap: [String: [ReplyWrapper]] = [:]  // Maps reply URI to nested replies

  // MARK: - Snapshot Serialization
  // Prevent overlapping diffable snapshot applications which can cause
  // UICollectionView invalid item count crashes under rapid updates.
  private var isApplyingSnapshot = false
  private var pendingSnapshot: NSDiffableDataSourceSnapshot<Section, Item>?

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
    label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)

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
    case showMoreReplies
    case bottomSpacer
  }

  private enum Item: Hashable, Sendable {
    case loadMoreParentsTrigger
    case parentPost(ParentPost)
    case mainPost(AppBskyFeedDefs.PostView)
    case reply(ReplyWrapper)
    case showMoreRepliesButton
    case spacer
  }

  private lazy var dataSource = createDataSource()

  // Centralized, serialized snapshot application to avoid race conditions
  @MainActor
  private func applySnapshot(
    _ snapshot: NSDiffableDataSourceSnapshot<Section, Item>,
    animatingDifferences: Bool
  ) {
    // If an apply is in-flight, coalesce to the latest snapshot
    if isApplyingSnapshot {
      pendingSnapshot = snapshot
      return
    }

    isApplyingSnapshot = true

    UIView.performWithoutAnimation {
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self else { return }
        self.isApplyingSnapshot = false

        // If another snapshot arrived while applying, apply the latest now
        if let next = self.pendingSnapshot {
          self.pendingSnapshot = nil
          self.applySnapshot(next, animatingDifferences: false)
        }
      }
    }
  }

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
    #if os(iOS) && !targetEnvironment(macCatalyst)
    if #available(iOS 18.0, *) {
      updateLink?.isEnabled = false
      updateLink = nil
    }
    #endif
    
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
    
    // Apply initial themed colors and start observing theme changes
    updateThemeColors()
    setupThemeObserver()
    
    // Prevent VoiceOver from auto-scrolling
    collectionView.accessibilityTraits = .none
    collectionView.shouldGroupAccessibilityChildren = true
    
    loadInitialThread()
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    // Apply theme directly to this view controller's navigation and toolbar
    configureNavigationAndToolbarTheme()
    updateThemeColors()
    
    // Apply width=120 fonts to this navigation bar
    if let navigationBar = navigationController?.navigationBar {
      NavigationFontConfig.applyFonts(to: navigationBar)
    }
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    
    // Setup UIUpdateLink now that view is in window hierarchy
    #if os(iOS) && !targetEnvironment(macCatalyst)
    if #available(iOS 18.0, *), updateLink == nil {
      setupUIUpdateLink()
    }
    #endif
    
    // Ensure theming is applied after view appears (helps with material effects)
    DispatchQueue.main.async {
      self.configureNavigationAndToolbarTheme()
      self.updateThemeColors()
    }
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    // Update theme when system appearance changes
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      // Apply theme directly to this view controller
      configureNavigationAndToolbarTheme()
      // Update themed colors
      updateThemeColors()
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
    if isDarkMode && isBlackMode {
      tabBarAppearance.configureWithOpaqueBackground()
      tabBarAppearance.backgroundColor = .black
      tabBarAppearance.shadowColor = .clear
      tabBarController.tabBar.tintColor = UIColor.systemBlue
    } else if isDarkMode {
      tabBarAppearance.configureWithOpaqueBackground()
      tabBarAppearance.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: .dark)
      )
      tabBarAppearance.shadowColor = .clear
      tabBarController.tabBar.tintColor = nil
    } else {
      tabBarAppearance.configureWithDefaultBackground()
      tabBarAppearance.backgroundColor = UIColor.systemBackground
      tabBarController.tabBar.tintColor = UIColor.systemBlue
    }
    
    // Apply the tab bar appearance
    tabBarController.tabBar.standardAppearance = tabBarAppearance
    tabBarController.tabBar.scrollEdgeAppearance = tabBarAppearance
    
    // Ensure proper color scheme for tab bar icons and text
    if #available(iOS 13.0, *) {
        tabBarController.tabBar.overrideUserInterfaceStyle = currentScheme == .dark ? .dark : .light
    }
  }

  // MARK: - Theme Observation and Updates
  private func setupThemeObserver() {
    // Observe ThemeManager changes via @Observable and fallback notification
    themeObserver = UIKitStateObserver(observing: appState.themeManager) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleThemeChange()
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleThemeChangeNotification),
      name: NSNotification.Name("ThemeChanged"),
      object: nil
    )
  }

  @objc private func handleThemeChangeNotification() {
    handleThemeChange()
  }

  private func handleThemeChange() {
    configureNavigationAndToolbarTheme()
    updateThemeColors()
    // Force cells to re-read backgrounds where needed
    let snapshot = dataSource.snapshot()
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  private func updateThemeColors() {
    let currentScheme = getCurrentColorScheme()
    let bgColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: currentScheme))
    let secondaryBG = UIColor(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: currentScheme))
    let textSecondary = UIColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: currentScheme))
    
    view.backgroundColor = bgColor
    collectionView.backgroundColor = bgColor
    loadingView.backgroundColor = bgColor
    
    // Update loading label color if present
    if let stack = loadingView.subviews.first(where: { $0 is UIStackView }) as? UIStackView,
       let lbl = stack.arrangedSubviews.compactMap({ $0 as? UILabel }).first {
      lbl.textColor = textSecondary
    }
  }
  
  private func configureParentNavigationTheme() {
    // Theme configuration is handled by SwiftUI's themedNavigationBar modifier
    // No need to modify UIKit navigation bar appearance directly
  }

  // MARK: - UIUpdateLink Setup
  #if os(iOS) && !targetEnvironment(macCatalyst)
  @available(iOS 18.0, *)
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
  #endif

  // MARK: - UI Setup
  private func setupUI() {
      view.backgroundColor = .systemBackground

    // Start collection view hidden, will fade in after layout settles
    collectionView.alpha = 0

    view.addSubview(collectionView)
    view.addSubview(loadingView)

    // Disable implicit Core Animation on common layer actions to prevent fly-in
    collectionView.layer.actions = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]

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
    collectionView.register(ShowMoreRepliesCell.self, forCellWithReuseIdentifier: "ShowMoreRepliesCell")
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
    case .showMoreReplies:
      layoutSection.interGroupSpacing = 0
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
          // Get estimated height from first reply
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
        
      case .showMoreReplies:
        estimatedHeight = 50  // Fixed height for show more button

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
        
        // Get nested replies for this reply (if any)
        let nestedReplies = self.nestedRepliesMap[replyWrapper.id] ?? []
        
        cell.configure(
          replyWrapper: replyWrapper,
          nestedReplies: nestedReplies,
          opAuthorID: self.mainPost?.author.did.didString() ?? "",
          appState: self.appState,
          path: self.path
        )
        return cell
        
      case .showMoreRepliesButton:
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "ShowMoreRepliesCell", for: indexPath)
          as! ShowMoreRepliesCell
        cell.configure(isLoading: self.isLoadingHiddenReplies) { [weak self] in
          self?.loadHiddenRepliesFromButton()
        }
        return cell
        
      case .spacer:
        return collectionView.dequeueReusableCell(withReuseIdentifier: "SpacerCell", for: indexPath)
      }
    }

    return dataSource
  }
  
  /// Called when user taps the "Show More Replies" button
  private func loadHiddenRepliesFromButton() {
    guard !isLoadingHiddenReplies, !hasLoadedHiddenReplies else { return }
    
    isLoadingHiddenReplies = true
    updateShowMoreRepliesCell()
    
    Task { @MainActor in
      await threadManager?.loadHiddenReplies(uri: postURI)
      processHiddenReplies()
      
      hasLoadedHiddenReplies = true
      isLoadingHiddenReplies = false
      
      // Refresh the snapshot to show the new replies and remove the button
      updateDataSnapshot(animatingDifferences: true)
    }
  }
  
  /// Update the show more replies cell to reflect loading state
  private func updateShowMoreRepliesCell() {
    var snapshot = dataSource.snapshot()
    guard let showMoreItem = snapshot.itemIdentifiers(inSection: .showMoreReplies).first else {
      return
    }
    snapshot.reconfigureItems([showMoreItem])
    applySnapshot(snapshot, animatingDifferences: false)
  }

  // MARK: - Thread Loading Logic
  private func loadInitialThread() {
    Task(priority: .userInitiated) { @MainActor in
      controllerLogger.debug("🧵 THREAD LOAD: Starting initial thread load for URI: \(self.postURI.uriString())")
      isLoading = true

      threadManager = ThreadManager(appState: appState)
      await threadManager?.loadThread(uri: postURI)

      // Check if the thread has no parent posts
      if let threadData = threadManager?.threadData {
        if threadData.thread.filter({ $0.depth < 0 }).isEmpty {
          controllerLogger.debug("🧵 THREAD LOAD: This thread has no parent posts, marking as top of thread")
          hasReachedTopOfThread = true
        }
        
        // Track whether there are hidden replies available
        hasOtherReplies = threadData.hasOtherReplies
        
        // If auto-load setting is enabled, load hidden replies automatically
        // Otherwise, we'll show a "Show More Replies" button
        if appState.appSettings.showHiddenPosts && threadData.hasOtherReplies {
          await threadManager?.loadHiddenReplies(uri: postURI)
          hasLoadedHiddenReplies = true
        }
      }

      processThreadData()
      processHiddenReplies()

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
      
      // Apply snapshot synchronously without animations
      updateDataSnapshot(animatingDifferences: false)
      
      isLoading = false

      if mainPost != nil && !hasScrolledToMainPost {
        // Wait for collection view to complete layout after snapshot application
        // This is crucial when load more cell is present
        UIView.performWithoutAnimation {
          collectionView.performBatchUpdates({
            // Force layout update
            self.collectionView.layoutIfNeeded()
          }) { _ in }
        }
        // Proceed immediately after ensuring layout without animations
        do {
          // Now scroll to main post after layout is complete
          self.scrollToMainPostWithPartialParentVisibility(animated: false)
          self.hasScrolledToMainPost = true
          
          // Fade in collection view to mask any layout settling animations
          UIView.animate(withDuration: 0.25, delay: 0.1, options: [.curveEaseOut]) {
            self.collectionView.alpha = 1
          }
          // If VoiceOver is running, post focus to main post
          if UIAccessibility.isVoiceOverRunning {
            self.focusVoiceOverOnMainPost()
          }
        }
      } else {
        // Fade in collection view to mask any layout settling animations
        UIView.animate(withDuration: 0.25, delay: 0.1, options: [.curveEaseOut]) {
          self.collectionView.alpha = 1
        }
        // If VoiceOver is running, post focus to main post
        if UIAccessibility.isVoiceOverRunning {
          self.focusVoiceOverOnMainPost()
        }
      }
    }
  }

    private func processThreadData() {
    guard let threadManager = threadManager,
      let threadData = threadManager.threadData
    else {
      return
    }

    // V2 API returns a flat list of ThreadItems with depth indicators
    // Negative depth = parent posts, 0 = main post, positive = replies
    
    // Find main post (depth = 0)
    guard let mainItem = threadData.thread.first(where: { $0.depth == 0 }) else {
      parentPosts = []
      mainPost = nil
      replyWrappers = []
      return
    }
    
    // Extract main post
    if case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = mainItem.value {
      mainPost = threadItemPost.post
      
      // Collect parent posts (depth < 0), sorted by depth (oldest = most negative)
      let parentItems = threadData.thread.filter { $0.depth < 0 }.sorted { $0.depth < $1.depth }
      parentPosts = collectParentPostsV2(from: parentItems)
      
      // Collect reply posts (depth > 0) - Keep API order which has chains grouped together
      let replyItems = threadData.thread.filter { $0.depth > 0 }
      
      // Group replies into chains:
      // - depth 1 = top-level reply to main post (starts a new chain)
      // - depth 2+ = continuation of the current chain
      var topLevelReplies: [ReplyWrapper] = []
      var nestedMap: [String: [ReplyWrapper]] = [:]
      var currentChainTopLevelURI: String? = nil
      
      for item in replyItems {
        guard case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value else {
          continue
        }
        
        let id = item.uri.uriString()
        let isFromOP = threadItemPost.post.author.did.didString() == mainPost!.author.did.didString()
        let isOpThread = threadItemPost.opThread
        let hasReplies = threadItemPost.moreReplies > 0
        
        let wrapper = ReplyWrapper(
          id: id,
          threadItem: item,
          depth: item.depth,
          isFromOP: isFromOP,
          isOpThread: isOpThread,
          hasReplies: hasReplies
        )
        
        if item.depth == 1 {
          // Top-level reply to main post - starts a new chain
          topLevelReplies.append(wrapper)
          currentChainTopLevelURI = id
          // Initialize nested array for this chain
          nestedMap[id] = []
        } else if item.depth > 1, let chainRoot = currentChainTopLevelURI {
          // Nested reply (depth 2+) - belongs to the current chain
          nestedMap[chainRoot]?.append(wrapper)
        }
      }
      
      // Store the nested replies map
      self.nestedRepliesMap = nestedMap
      
      // Separate OP thread continuations from regular replies (only depth-1)
      opThreadContinuations = topLevelReplies.filter { $0.isOpThread }
      var regularReplies = topLevelReplies.filter { !$0.isOpThread }
      
      // If we have optimistic updates, merge them with server data
      if hasOptimisticUpdates && !optimisticReplyUris.isEmpty {
        // Keep track of which optimistic replies are confirmed by server
        var confirmedOptimisticUris = Set<String>()
        
        // Check if any server replies match our optimistic URIs
        for wrapper in regularReplies {
          if case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = wrapper.threadItem.value {
            if optimisticReplyUris.contains(itemPost.post.uri.uriString()) {
              confirmedOptimisticUris.insert(itemPost.post.uri.uriString())
            }
          }
        }
        
        // Add unconfirmed optimistic replies back to the list
        for existingWrapper in replyWrappers {
          if case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = existingWrapper.threadItem.value {
            let uri = itemPost.post.uri.uriString()
            if optimisticReplyUris.contains(uri) && !confirmedOptimisticUris.contains(uri) {
              // This is an optimistic reply not yet on server, keep it
              regularReplies.append(existingWrapper)
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
      
      replyWrappers = regularReplies
    } else {
      parentPosts = []
      mainPost = nil
      opThreadContinuations = []
      replyWrappers = []
    }
  }
  
  /// Process hidden replies from the threadManager and merge into replyWrappers
  /// These are replies that Bluesky's algorithm filtered out but the user wants to see
  private func processHiddenReplies() {
    guard let hiddenReplies = threadManager?.hiddenReplies, !hiddenReplies.isEmpty else {
      return
    }
    
    guard let mainPost = mainPost else { return }
    
    // Get existing reply URIs to avoid duplicates
    let existingURIs = Set(replyWrappers.map { $0.id })
    
    var additionalReplies: [ReplyWrapper] = []
    
    for item in hiddenReplies {
      guard case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value else {
        continue
      }
      
      let id = item.uri.uriString()
      
      // Skip if already in the main replies
      if existingURIs.contains(id) {
        continue
      }
      
      let isFromOP = threadItemPost.post.author.did.didString() == mainPost.author.did.didString()
      let isOpThread = threadItemPost.opThread
      let hasReplies = threadItemPost.moreReplies > 0
      
      // Convert to the v2 ThreadItem type by creating a compatible wrapper
      // We create a v2 ThreadItem using the same underlying ThreadItemPost
      let v2Value = AppBskyUnspeccedGetPostThreadV2.ThreadItemValueUnion.appBskyUnspeccedDefsThreadItemPost(threadItemPost)
      let v2ThreadItem = AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: item.uri,
        depth: item.depth,
        value: v2Value
      )
      
      let wrapper = ReplyWrapper(
        id: id,
        threadItem: v2ThreadItem,
        depth: item.depth,
        isFromOP: isFromOP,
        isOpThread: isOpThread,
        hasReplies: hasReplies
      )
      additionalReplies.append(wrapper)
    }
    
    // Append hidden replies to the main replies list
    if !additionalReplies.isEmpty {
      replyWrappers.append(contentsOf: additionalReplies)
      controllerLogger.debug("🧵 THREAD LOAD: Merged \(additionalReplies.count) previously-filtered replies into thread")
    }
  }

  private func updateDataSnapshot(animatingDifferences: Bool = false) {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

    // Add all sections
    snapshot.appendSections(Section.allCases)

    // Add load more trigger if we have parent posts and haven't reached the top
    if !parentPosts.isEmpty && !hasReachedTopOfThread {
      snapshot.appendItems([.loadMoreParentsTrigger], toSection: .loadMoreParents)
    }

    // Add parent posts in chronological order (oldest first, newest last)
    // parentPosts is already sorted by depth with oldest (most negative) first
    let parentItems = parentPosts.map { Item.parentPost($0) }
    snapshot.appendItems(parentItems, toSection: .parentPosts)

    // Add main post if available
    if let mainPost = mainPost {
      snapshot.appendItems([.mainPost(mainPost)], toSection: .mainPost)
    }

    // Add OP thread continuations first (these are part of OP's continued thread)
    let opThreadItems = opThreadContinuations.map { Item.reply($0) }
    snapshot.appendItems(opThreadItems, toSection: .replies)
    
    // Then add regular replies (from other users) - includes merged hidden replies
    let replyItems = replyWrappers.map { Item.reply($0) }
    snapshot.appendItems(replyItems, toSection: .replies)
    
    // Add "Show More Replies" button if there are hidden replies and they haven't been loaded yet
    if hasOtherReplies && !hasLoadedHiddenReplies {
      snapshot.appendItems([.showMoreRepliesButton], toSection: .showMoreReplies)
    }

    // Add bottom spacer
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)

    // Apply snapshot via serialized helper to avoid overlap
    applySnapshot(snapshot, animatingDifferences: animatingDifferences)
  }

  private func updateLoadingCell(isLoading: Bool) {
    // Update the load more cell to show loading state
    var snapshot = dataSource.snapshot()
    guard let loadMoreItem = snapshot.itemIdentifiers(inSection: .loadMoreParents).first else {
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: No loading cell found to update")
      return
    }

    snapshot.reconfigureItems([loadMoreItem])
    applySnapshot(snapshot, animatingDifferences: false)
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
      switch (oldPost.threadItem.value, newPost.threadItem.value) {
      case (
        .appBskyUnspeccedDefsThreadItemPost(let oldThreadPost),
        .appBskyUnspeccedDefsThreadItemPost(let newThreadPost)
      ):
        // Compare post URIs
        if oldThreadPost.post.uri.uriString() != newThreadPost.post.uri.uriString() {
          return true
        }

        // With v2, we can check moreParents and moreReplies flags
        if oldThreadPost.moreParents != newThreadPost.moreParents {
          return true
        }
        
        if oldThreadPost.moreReplies != newThreadPost.moreReplies {
          return true
        }

      default:
        // Different post types
        if type(of: oldPost.threadItem.value) != type(of: newPost.threadItem.value) {
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
    #if os(iOS) && !targetEnvironment(macCatalyst)
    if #available(iOS 18.0, *) {
      updateLink?.requiresContinuousUpdates = true
    }
    #endif
    
    // Get the oldest parent (first element since parentPosts is sorted oldest-to-newest)
    let oldestParent = parentPosts.first!
    
    // Start loading animation
    updateLoadingCell(isLoading: true)
    
    Task { @MainActor in
      // Get oldest parent URI - with v2 API it's directly on the thread item
      let postURI = oldestParent.threadItem.uri
      
      // Load more parents
      let success = await threadManager.loadMoreParents(uri: postURI)
      
      guard success,
            let threadData = threadManager.threadData else {
        isLoadingMoreParents = false
        updateLoadingCell(isLoading: false)
        return
      }
      
      // Get new parent chain from thread data
      let fullChainFromManager = collectParentPostsV2(
        from: threadData.thread.filter { $0.depth < 0 }.sorted { $0.depth < $1.depth }
      )
      
      // Check if we have the complete chain with root post (topmost parent has moreParents = false)
      let hasRootPost = fullChainFromManager.last.map { parent in
        if case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = parent.threadItem.value {
          return !itemPost.moreParents
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
            applySnapshot(snapshot, animatingDifferences: false)
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
    
    // Capture precise anchor BEFORE mutating data/applying snapshot to avoid anchoring to load-more
    var preUpdatePreciseAnchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor?
    if #available(iOS 18.0, *) {
      preUpdatePreciseAnchor = captureThreadPreciseAnchor(from: collectionView)
    }
    
    // Update model data
    let oldParentCount = parentPosts.count
    parentPosts = newParents
    
    // Check if we now have the root post (topmost parent has moreParents = false)
    let hasRootPost = parentPosts.last.map { parent in
      if case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = parent.threadItem.value {
        return !itemPost.moreParents
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
    
    // Add parent posts in chronological order (oldest first, newest last)
    // parentPosts is already sorted by depth with oldest (most negative) first
    let parentItems = parentPosts.map { Item.parentPost($0) }
    snapshot.appendItems(parentItems, toSection: .parentPosts)
    
    // Add main post
    if let mainPost = mainPost {
      snapshot.appendItems([.mainPost(mainPost)], toSection: .mainPost)
    }
    
    // Add regular replies as flat items
    let replyItems = replyWrappers.map { Item.reply($0) }
    snapshot.appendItems(replyItems, toSection: .replies)
    
    // Add bottom spacer
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)
    
    // Apply snapshot immediately for layout calculation
    applySnapshot(snapshot, animatingDifferences: false)
    
    // Use sophisticated position preservation like feed view
    Task { @MainActor in
        await applyParentPostsWithPrecisePreservation(
          newParentsCount: newParentsCount,
          oldParentCount: oldParentCount,
          preciseAnchor: preUpdatePreciseAnchor,
          coarseAnchor: scrollAnchor
        )
        
      // Clean up loading state after positioning
      isLoadingMoreParents = false
      updateLoadingCell(isLoading: false)
      
      // Disable continuous updates now that loading is complete
      #if os(iOS) && !targetEnvironment(macCatalyst)
      if #available(iOS 18.0, *) {
        updateLink?.requiresContinuousUpdates = false
      }
      #endif
      
      controllerLogger.debug("⬆️ LOAD MORE PARENTS: Successfully added \(newParentsCount) parents with precise position preservation")
    }
  }
  
  // MARK: - Precise Position Preservation for Parent Posts (iOS 18+)
  
  @available(iOS 18.0, *)
  @MainActor
  private func applyParentPostsWithPrecisePreservation(
    newParentsCount: Int,
    oldParentCount: Int,
    preciseAnchor: OptimizedScrollPreservationSystem.PreciseScrollAnchor?,
    coarseAnchor: ThreadScrollPositionTracker.ScrollAnchor?
  ) async {
    // Use provided pre-update anchor if available, otherwise attempt a fresh capture
    let anchorToUse = preciseAnchor ?? captureThreadPreciseAnchor(from: collectionView)
    
    guard let anchor = anchorToUse else {
      // If precise anchor capture fails, try coarse restoration using pre-captured thread anchor
      if let coarseAnchor {
        controllerLogger.debug("⚠️ Precise anchor unavailable, using coarse restoration with retry")
        await restoreScrollPositionWithRetry(anchor: coarseAnchor, newParentsCount: newParentsCount, oldParentCount: oldParentCount)
      } else {
        // As a last resort, apply simple height-based preservation
        controllerLogger.debug("⚠️ No anchors available, falling back to simple preservation")
        await applyParentPostsWithSimplePreservation(newParentsCount: newParentsCount)
      }
      return
    }
    
    // Store current post URIs to track content changes (include all thread content)
    var currentPostIds: [String] = []

    // Add parent post URIs
    currentPostIds.append(contentsOf: parentPosts.compactMap { $0.uri?.uriString() })

    // Add main post URI if available
    if let mainPostUri = mainPost?.uri.uriString() {
      currentPostIds.append(mainPostUri)
    }

    // Add reply URIs
    currentPostIds.append(contentsOf: replyWrappers.compactMap { $0.post?.uri.uriString() })

    // Filter out unknown URIs
    currentPostIds = currentPostIds.filter { !$0.hasPrefix("at://unknown") }
    
    // Apply atomic update with position preservation (like feed view does)
    await applyAtomicParentUpdateWithPreservation(
      anchor: anchor,
      newParentsCount: newParentsCount,
      currentPostIds: currentPostIds
    )
    
    // If we unexpectedly ended at the very top without having reached the true root,
    // use coarse restoration to keep the viewport stable.
    if hasReachedTopOfThread == false {
      let safeTop = collectionView.adjustedContentInset.top
      if abs(collectionView.contentOffset.y - (-safeTop)) < 1.0, let coarseAnchor {
        controllerLogger.debug("⚠️ Ended at top unexpectedly; applying coarse restoration retry")
        await restoreScrollPositionWithRetry(anchor: coarseAnchor, newParentsCount: newParentsCount, oldParentCount: oldParentCount)
      }
    }
    
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
      // Anchor index is already in the updated list; no extra shift needed
      let newAnchorIndex = anchorIndex
      
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
    #if os(iOS) && !targetEnvironment(macCatalyst)
    if #available(iOS 18.0, *) {
      updateLink?.requiresContinuousUpdates = true
    }
    #endif
    
    // Step 3: Set estimated position immediately to prevent visual flash
    if let targetOffset = targetOffset {
      collectionView.setContentOffset(targetOffset, animated: false)
    }
    
    // Step 4: Force layout to get accurate positions
    collectionView.layoutIfNeeded()
    
    // Step 5: Fine-tune position with actual layout data using thread-specific calculation
    var appliedFineTune = false
    let anchorIsUnknown = anchor.postId.hasPrefix("at://unknown")
    if !anchorIsUnknown, let finalTargetOffset = calculateThreadTargetOffset(
      for: anchor,
      newPostIds: currentPostIds,
      in: collectionView
    ) {
      collectionView.setContentOffset(finalTargetOffset, animated: false)
      controllerLogger.debug("🎯 Applied fine-tuned thread position: \(finalTargetOffset.y)")
      appliedFineTune = true
    }

    // Index-path fallback for parent section when we can't key by URI (pending/unexpected parents)
    if !appliedFineTune {
      if anchor.indexPath.section == Section.parentPosts.rawValue {
        let safeTop = collectionView.adjustedContentInset.top
        let totalItems = collectionView.numberOfItems(inSection: Section.parentPosts.rawValue)
        let shiftedIndex = min(anchor.indexPath.item + newParentsCount, max(0, totalItems - 1))
        let newIndexPath = IndexPath(item: shiftedIndex, section: Section.parentPosts.rawValue)
        if let attrs = collectionView.layoutAttributesForItem(at: newIndexPath) {
          let targetY = attrs.frame.origin.y - safeTop - anchor.viewportRelativeY
          let minOffset = -safeTop
          let maxOffset = max(minOffset, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
          let clampedY = max(minOffset, min(targetY, maxOffset))
          collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
          controllerLogger.debug("🎯 Applied index-based fallback position: \(clampedY) for shifted index: \(shiftedIndex)")
          appliedFineTune = true
        }
      }
    }

    if !appliedFineTune {
      controllerLogger.debug("⚠️ Thread fine-tuning failed - using estimated position")
    }
    
    CATransaction.commit()
    
    // Delayed verification pass to correct any drift from late layout (e.g., TextKit/image sizing)
    let verificationDelay: DispatchTimeInterval = .milliseconds(100)
    DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay) { [weak self] in
      guard let self = self else { return }
      self.collectionView.layoutIfNeeded()
      let safeTop = self.collectionView.adjustedContentInset.top
      let currentY = self.collectionView.contentOffset.y

      var correctedOffset: CGPoint?
      if !anchorIsUnknown, let verifyOffset = self.calculateThreadTargetOffset(
        for: anchor,
        newPostIds: currentPostIds,
        in: self.collectionView
      ) {
        correctedOffset = verifyOffset
      } else if anchor.indexPath.section == Section.parentPosts.rawValue {
        let totalItems = self.collectionView.numberOfItems(inSection: Section.parentPosts.rawValue)
        let shiftedIndex = min(anchor.indexPath.item + newParentsCount, max(0, totalItems - 1))
        let newIndexPath = IndexPath(item: shiftedIndex, section: Section.parentPosts.rawValue)
        if let attrs = self.collectionView.layoutAttributesForItem(at: newIndexPath) {
          let targetY = attrs.frame.origin.y - safeTop - anchor.viewportRelativeY
          let minOffset = -safeTop
          let maxOffset = max(minOffset, self.collectionView.contentSize.height - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom)
          let clampedY = max(minOffset, min(targetY, maxOffset))
          correctedOffset = CGPoint(x: 0, y: clampedY)
        }
      }

      if let corrected = correctedOffset {
        let delta = abs(corrected.y - currentY)
        if delta > 1.5 {
          self.collectionView.setContentOffset(corrected, animated: false)
          self.controllerLogger.debug("🩺 Delayed verification corrected position by \(delta)pt to: \(corrected.y)")
        } else {
          self.controllerLogger.debug("🩺 Delayed verification within tolerance (\(delta)pt)")
        }
      }
    }

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
    // Prefer the first visible CONTENT item (skip load-more trigger)
    let sortedVisible = collectionView.indexPathsForVisibleItems.sorted()
    var candidateIndexPath = sortedVisible.first(where: { $0.section != Section.loadMoreParents.rawValue }) ?? sortedVisible.first
    
    // If the only visible item is the load-more trigger, try anchoring to the first parent or main post
    if let idx = candidateIndexPath, idx.section == Section.loadMoreParents.rawValue {
      candidateIndexPath = nil
    }
    
    if candidateIndexPath == nil {
      // Try first parent item if any
      if !parentPosts.isEmpty {
        let parentIdx = IndexPath(item: 0, section: Section.parentPosts.rawValue)
        if collectionView.layoutAttributesForItem(at: parentIdx) != nil {
          candidateIndexPath = parentIdx
        }
      }
      // Else try main post
      if candidateIndexPath == nil {
        let mainIdx = IndexPath(item: 0, section: Section.mainPost.rawValue)
        if collectionView.layoutAttributesForItem(at: mainIdx) != nil {
          candidateIndexPath = mainIdx
        }
      }
    }
    
    guard let firstVisibleIndexPath = candidateIndexPath,
          let attributes = collectionView.layoutAttributesForItem(at: firstVisibleIndexPath) else {
      controllerLogger.debug("⚠️ No visible items for anchor capture")
      return nil
    }
    
    // Get the post URI for this index path from thread structure
    // CRITICAL FIX: Use correct section mappings from Section enum
    let postId: String
    switch firstVisibleIndexPath.section {
    case Section.loadMoreParents.rawValue: // Section 0 - Load more trigger
      // We already tried to skip this above; if we land here, bail out
      controllerLogger.debug("⚠️ Cannot anchor to load more trigger, skipping")
      return nil
      
    case Section.parentPosts.rawValue: // Section 1 - Parent posts
      guard firstVisibleIndexPath.item < parentPosts.reversed().count else {
        controllerLogger.debug("⚠️ Parent index out of bounds: \(firstVisibleIndexPath.item)")
        return nil
      }
      // parentPosts are displayed in reverse order, so map the index correctly
      let reversedIndex = parentPosts.count - 1 - firstVisibleIndexPath.item
      if let pid = parentPosts[reversedIndex].uri?.uriString() {
        postId = pid
      } else {
        controllerLogger.debug("⚠️ Parent post at index has no stable URI (pending/unexpected)")
        return nil
      }
      
    case Section.mainPost.rawValue: // Section 2 - Main post
      guard let mainPostUri = mainPost?.uri.uriString() else {
        controllerLogger.debug("⚠️ Main post has no URI")
        return nil
      }
      postId = mainPostUri
      
    case Section.replies.rawValue: // Section 3 - Replies
      guard firstVisibleIndexPath.item < replyWrappers.count else {
        controllerLogger.debug("⚠️ Reply index out of bounds: \(firstVisibleIndexPath.item)")
        return nil
      }
      if let replyPost = replyWrappers[firstVisibleIndexPath.item].post {
        postId = replyPost.uri.uriString()
      } else {
        // Use the reply wrapper's URI for non-accessible posts
        postId = replyWrappers[firstVisibleIndexPath.item].uri.uriString()
      }
      
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
    // CRITICAL FIX: Use correct section mappings from Section enum
    let threadContentToIndexPath: [String: IndexPath] = {
      var mapping: [String: IndexPath] = [:]
      
      // Parent posts section (Section.parentPosts.rawValue = 1)
      // Parents are displayed in reverse order, so map accordingly
      for (displayIndex, parentPost) in parentPosts.reversed().enumerated() {
        let key = parentPost.threadItem.uri.uriString()
        // Skip placeholder/unknown URIs to avoid mapping the wrong item
        if key.hasPrefix("at://unknown") == false {
          mapping[key] = IndexPath(item: displayIndex, section: Section.parentPosts.rawValue)
        }
      }
      
      // Main post section (Section.mainPost.rawValue = 2, item 0)
      if let mainPostUri = mainPost?.uri.uriString(), mainPostUri.hasPrefix("at://unknown") == false {
        mapping[mainPostUri] = IndexPath(item: 0, section: Section.mainPost.rawValue)
      }
      
      // Replies section (Section.replies.rawValue = 3)
      for (index, replyWrapper) in replyWrappers.enumerated() {
        let key = replyWrapper.uri.uriString()
        if key.hasPrefix("at://unknown") == false {
          mapping[key] = IndexPath(item: index, section: Section.replies.rawValue)
        }
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

  private func collectParentPostsV2(from parentItems: [AppBskyUnspeccedGetPostThreadV2.ThreadItem]) -> [ParentPost] {
    var parents: [ParentPost] = []
    var grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
    
    // Parent items are already sorted by depth (oldest = most negative depth first)
    for item in parentItems {
      switch item.value {
      case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
        let postURI = item.uri.uriString()
        parents.append(ParentPost(id: postURI, threadItem: item, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = threadItemPost.post.author
        
      case .appBskyUnspeccedDefsThreadItemNotFound:
        let uri = item.uri.uriString()
        parents.append(ParentPost(id: uri, threadItem: item, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = nil
        
      case .appBskyUnspeccedDefsThreadItemBlocked:
        let uri = item.uri.uriString()
        parents.append(ParentPost(id: uri, threadItem: item, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = nil
        
      case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
        let uri = item.uri.uriString()
        parents.append(ParentPost(id: uri, threadItem: item, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = nil
        
      case .unexpected:
        let unexpectedID = "unexpected-\(item.depth)-\(UUID().uuidString.prefix(8))"
        controllerLogger.debug("collectParentPostsV2: Found unexpected post type at depth \(item.depth): \(unexpectedID)")
        parents.append(ParentPost(id: unexpectedID, threadItem: item, grandparentAuthor: grandparentAuthor))
        grandparentAuthor = nil
      }
    }
    
    return parents
  }

  private func collectParentPosts(from initialPost: AppBskyFeedDefs.ThreadViewPostParentUnion?) async
    -> [ParentPost] {
    var parents: [ParentPost] = []
    var currentPost = initialPost
    var grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
    var depth = 0

    while let post = currentPost {
      depth += 1
      // This method should never be called with v2 API - it's kept for backwards compatibility only
      controllerLogger.error("collectParentPosts: Old API method called - this should not happen with v2 API")
      currentPost = nil
    }

    if !parents.isEmpty {
      //        controllerLogger.debug("collectParentPosts: Parent URIs in order: \(parents.map { $0.id }.joined(separator: ", ")}")
    }

    return parents
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
    // With v2 flat structure, just check the direct URI
    return wrapper.threadItem.uri.uriString() == uri
  }
  
  /// Check if a post URI is a reply to any post in this thread
  private func isReplyToThreadPost(_ parentUri: String) -> Bool {
    // Check main post
    if let mainPost = mainPost, mainPost.uri.uriString() == parentUri {
      return true
    }
    
    // Check parent posts (ancestors)
    if parentPosts.contains(where: { $0.threadItem.uri.uriString() == parentUri }) {
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
    // Create a ThreadItem for the optimistic reply with v2 structure
    let threadItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
      post: post,
      moreParents: false,
      moreReplies: 0,
      opThread: false,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    
    let threadItem = AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: post.uri,
      depth: 1, // Direct reply depth
      value: .appBskyUnspeccedDefsThreadItemPost(threadItemPost)
    )
    
    let isFromOP = post.author.did.didString() == mainPost?.author.did.didString()
    
    return ReplyWrapper(
      id: post.uri.uriString(),
      threadItem: threadItem,
      depth: 1,
      isFromOP: isFromOP,
      isOpThread: false,  // Optimistic replies are not part of OP thread
      hasReplies: false
    )
  }
  
  // Helper to update nested replies - simplified for v2 flat structure
  private func updateReplyWrapper(_ wrapper: inout ReplyWrapper, withNewReply reply: AppBskyFeedDefs.PostView, toParent parentUri: String) -> Bool {
    // In v2 flat structure, we don't have nested reply structures to update
    // This would need to be handled differently, potentially by reloading the thread
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
    
    // Apply without animation for optimistic updates to avoid fly-in
    applySnapshot(snapshot, animatingDifferences: false)
  }
}

// MARK: - ParentPost Extensions
extension ParentPost {
  /// Safely extracts URI from parent post thread item
  var uri: ATProtocolURI? {
    return threadItem.uri
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
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(parentPost: ParentPost, appState: AppState, path: Binding<NavigationPath>) {
    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )
    
    let content = AnyView(
      WidthLimitedContainer(maxWidth: 600) {
        ParentPostView(
          parentPost: parentPost,
          path: path,
          appState: appState
        )
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
      }
    )

    // Only reconfigure if needed (using post id as identity check)
    if contentConfiguration == nil
      || parentPost.id != (contentView.tag != 0 ? String(contentView.tag) : nil) {

      // Store post ID in tag for comparison on reuse
      contentView.tag = parentPost.id.hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
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

    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(post: AppBskyFeedDefs.PostView, appState: AppState, path: Binding<NavigationPath>) {
    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )
    
    // Avoid removing/readding subviews if configuration hasn't changed
    let content =
      VStack(spacing: 0) {
        WidthLimitedContainer(maxWidth: 600) {
          ThreadViewMainPostView(
            post: post,
            showLine: false,
            path: path,
            appState: appState
          )
          .equatable()
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }

        // Full-bleed divider across entire screen width
        Divider()
          .padding(.bottom, 9)
      }
    .id(post.uri.uriString())

    // Only reconfigure if needed (using post URI as identity check)
    if contentConfiguration == nil
      || post.uri.uriString() != (contentView.tag != 0 ? String(contentView.tag) : nil) {

      // Store identity in tag for comparison on reuse
      contentView.tag = post.uri.uriString().hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
          content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
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
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    replyWrapper: ReplyWrapper, 
    nestedReplies: [ReplyWrapper],
    opAuthorID: String, 
    appState: AppState,
    path: Binding<NavigationPath>
  ) {
    // Set themed background color
      contentView.backgroundColor = UIColor(
        Color.dynamicBackground(appState.themeManager, currentScheme: contentView.getCurrentColorScheme())
      )
    
    let content = AnyView(
      VStack(spacing: 0) {
        WidthLimitedContainer(maxWidth: 600) {
          ReplyView(
            replyWrapper: replyWrapper,
            opAuthorID: opAuthorID,
            nestedReplies: nestedReplies,
            path: path,
            appState: appState
          )
          .padding(.horizontal, 10)
        }

        // Full-bleed divider across entire screen width
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
        content.transaction { txn in txn.animation = nil }.fixedSize(horizontal: false, vertical: true)
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
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
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
      label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.subheadline)
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

// MARK: - Show More Replies Cell
@available(iOS 18.0, *)
final class ShowMoreRepliesCell: UICollectionViewCell {
  private let button = UIButton(type: .system)
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private var tapAction: (() -> Void)?
  private var isCurrentlyLoading = false
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    
    // Disable implicit layer animations
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupViews() {
    // Configure button
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("Show More Replies", for: .normal)
    // Apply medium weight to the preferred subheadline font without using non-existent withWeight API
      let baseFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.subheadline)
    let descriptor = baseFont.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
    button.titleLabel?.font = UIFont(descriptor: descriptor, size: 0)
    button.setTitleColor(.systemBlue, for: .normal)
    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    
    // Configure activity indicator
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.hidesWhenStopped = true
    
    // Container stack
    let stackView = UIStackView(arrangedSubviews: [button, activityIndicator])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    
    contentView.addSubview(stackView)
    
    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
    ])
    
    // Accessibility
    isAccessibilityElement = true
    accessibilityLabel = "Show more replies"
    accessibilityTraits = .button
  }
  
  func configure(isLoading: Bool, onTap: @escaping () -> Void) {
    tapAction = onTap
    
    guard isLoading != isCurrentlyLoading else { return }
    isCurrentlyLoading = isLoading
    
    if isLoading {
      button.isEnabled = false
      button.setTitle("Loading...", for: .normal)
      activityIndicator.startAnimating()
    } else {
      button.isEnabled = true
      button.setTitle("Show More Replies", for: .normal)
      activityIndicator.stopAnimating()
    }
  }
  
  @objc private func buttonTapped() {
    tapAction?()
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    tapAction = nil
    isCurrentlyLoading = false
    button.isEnabled = true
    button.setTitle("Show More Replies", for: .normal)
    activityIndicator.stopAnimating()
  }
}

@available(iOS 18.0, *)
final class SpacerCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // This cell doesn't need special background handling
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - Supporting SwiftUI Views
/// Centers its content and constrains it to a maximum width while allowing the
/// surrounding container (e.g., collection view cell) to be full-width.
struct WidthLimitedContainer<Content: View>: View {
  let maxWidth: CGFloat
  @ViewBuilder var content: Content

  init(maxWidth: CGFloat = 600, @ViewBuilder content: () -> Content) {
    self.maxWidth = maxWidth
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      content
        .frame(maxWidth: maxWidth, alignment: .center)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }
}

struct ParentPostView: View {
  let parentPost: ParentPost
  @Binding var path: NavigationPath
  var appState: AppState

  var body: some View {
    switch parentPost.threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      PostView(
        post: threadItemPost.post,
        grandparentAuthor: nil,
        isParentPost: true,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .contentShape(Rectangle())
      .onTapGesture {
        path.append(NavigationDestination.post(threadItemPost.post.uri))
      }

    case .appBskyUnspeccedDefsThreadItemNotFound:
      PostNotFoundView(
        uri: parentPost.threadItem.uri,
        reason: .notFound,
        path: $path
      )
      .applyAppStateEnvironment(appState)

    case .appBskyUnspeccedDefsThreadItemBlocked:
      Text("Blocked post")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      Text("Post not available (authentication required)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .unexpected(let unexpected):
      Text("Unexpected parent post type: \(unexpected.textRepresentation)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.orange)
    }
  }
}

struct ReplyView: View {
  let replyWrapper: ReplyWrapper
  let opAuthorID: String
  let nestedReplies: [ReplyWrapper]  // Nested replies for this post
  let maxDepth: Int = 3
  @Binding var path: NavigationPath
  var appState: AppState

  var body: some View {
    switch replyWrapper.threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      VStack(alignment: .leading, spacing: 0) {
        // Show the top-level reply (depth 1)
        let showLine = !nestedReplies.isEmpty
        
        PostView(
          post: threadItemPost.post,
          grandparentAuthor: nil,
          isParentPost: showLine,  // Show connecting line if there are nested replies
          isSelectable: false,
          path: $path,
          appState: appState
        )
        .contentShape(Rectangle())
        .onTapGesture {
          path.append(NavigationDestination.post(threadItemPost.post.uri))
        }
        .padding(.vertical, 3)
        .frame(maxWidth: 550, alignment: .leading)
        
        // Show nested replies (depth 2+) in a chain
        if !nestedReplies.isEmpty {
          // Only the slice we'll actually consider rendering
          let visible = Array(nestedReplies.prefix(maxDepth - 1))
          
          // Find the last element in `visible` that is actually renderable as a Post
          let lastRenderableIndex: Int? = visible.lastIndex(where: {
            if case .appBskyUnspeccedDefsThreadItemPost = $0.threadItem.value { return true }
            return false
          })
          
          ForEach(Array(visible.enumerated()), id: \.element.id) { idx, nestedWrapper in
            switch nestedWrapper.threadItem.value {
              
            case .appBskyUnspeccedDefsThreadItemPost(let nestedPost):
              // "Renderable last" = last visible Post cell in the chain (ignoring placeholders)
              let isLastRenderable = (idx == lastRenderableIndex)
              // Draw the connecting line unless this is the last rendered post and it has no more replies
              let showNestedLine = !(isLastRenderable && !nestedWrapper.hasReplies)
              
              PostView(
                post: nestedPost.post,
                grandparentAuthor: nil,
                isParentPost: showNestedLine,
                isSelectable: false,
                path: $path,
                appState: appState
              )
              .contentShape(Rectangle())
              .onTapGesture { path.append(NavigationDestination.post(nestedPost.post.uri)) }
              .padding(.vertical, 3)
              .frame(maxWidth: 550, alignment: .leading)
              
                let shouldShowContinue = isLastRenderable && nestedPost.post.replyCount ?? 0 > 0
              
              if shouldShowContinue {
                Button(action: {
                  // Jump into the last rendered post; the server will expand from here
                  path.append(NavigationDestination.post(nestedPost.post.uri))
                }) {
                  HStack {
                    Text("Continue thread").appFont(AppTextRole.subheadline)
                    Image(systemName: "chevron.right").appFont(AppTextRole.subheadline)
                  }
                  .foregroundColor(.accentColor)
                  .padding(.vertical, 8)
                  .padding(.horizontal, 12)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
              }
              
            case .appBskyUnspeccedDefsThreadItemNotFound:
              PostNotFoundView(
                uri: nestedWrapper.threadItem.uri,
                reason: .notFound,
                path: $path
              )
              .applyAppStateEnvironment(appState)
              
              // Offer a way to jump into the missing leg of the chain
              Button(action: { path.append(NavigationDestination.post(nestedWrapper.uri)) }) {
                HStack {
                  Text("Continue thread").appFont(AppTextRole.subheadline)
                  Image(systemName: "chevron.right").appFont(AppTextRole.subheadline)
                }
                .foregroundColor(.accentColor)
                .padding(.vertical, 6)
              }
              
            case .appBskyUnspeccedDefsThreadItemBlocked:
              Text("Blocked reply")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.gray)
              
            case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
              Text("Reply not available (authentication required)")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.gray)
              
            case .unexpected(let unexpected):
              Text("Unexpected reply type: \(unexpected.textRepresentation)")
                .foregroundColor(.orange)
            }
          }
        }
      }

    case .appBskyUnspeccedDefsThreadItemNotFound:
      PostNotFoundView(
        uri: replyWrapper.threadItem.uri,
        reason: .notFound,
        path: $path
      )
      .applyAppStateEnvironment(appState)

    case .appBskyUnspeccedDefsThreadItemBlocked:
      Text("Blocked reply")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      Text("Reply not available (authentication required)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.gray)

    case .unexpected(let unexpected):
      Text("Unexpected reply type: \(unexpected.textRepresentation)")
        .foregroundColor(.orange)
    }
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

// MARK: - ReplyWrapper Extensions
extension ReplyWrapper {
  /// Computed property to access the post from the thread item
  /// Returns nil for non-accessible post types (not found, blocked, etc.)
  var post: AppBskyFeedDefs.PostView? {
    switch threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      return threadItemPost.post
    case .appBskyUnspeccedDefsThreadItemNotFound, .appBskyUnspeccedDefsThreadItemBlocked,
         .appBskyUnspeccedDefsThreadItemNoUnauthenticated, .unexpected:
      return nil
    }
  }

  /// URI accessor that works for all thread item types
  var uri: ATProtocolURI {
    return threadItem.uri
  }
}

