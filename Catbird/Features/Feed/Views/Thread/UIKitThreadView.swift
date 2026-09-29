#if os(iOS)
import Petrel
import SwiftUI
import AppIntents
import UIKit
import os

@available(iOS 18.0, *)
final class ThreadViewController: UIViewController, StateInvalidationSubscriber {
  // MARK: - Properties
  private var appState: AppState
  private let postURI: ATProtocolURI
  private var path: Binding<NavigationPath>
  let visibilityContext: PostVisibilityContext

  private var threadManager: ThreadManager?
  private var isLoading = true
  private var hasInitialized = false
  private var isLoadingMoreParents = false
  private var hasScrolledToMainPost = false
  private var lastParentLoadTime: Date?
  private var parentLoadAttempts = 0
  private var hasReachedTopOfThread = false
  private var pendingLoadTask: Task<Void, Never>?
  private var optimisticRetryTasks: [String: Task<Void, Never>] = [:]
  private var loadGeneration = 0
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
  private var mainPostIndex: Int?
  private var mainPostCount: Int?
  /// Every loaded thread item (server, hidden and optimistic) by URI string.
  private var threadItemsByID: [String: AppBskyUnspeccedGetPostThreadV2.ThreadItem] = [:]
  /// Replies the viewer just posted that the AppView has not returned yet.
  private var optimisticReplies: [OptimisticReply] = []
  /// Display rows for the whole thread, rebuilt by `rebuildRows()`.
  private var rows: [ThreadRow] = []
  /// Rows whose thread item changed in the last rebuild and need reconfiguring.
  private var changedRowIDs: Set<String> = []
  private var parentRows: [ThreadRow] = []
  private var anchorRow: ThreadRow?
  private var replyRows: [ThreadRow] = []

  private struct OptimisticReply {
    let threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem
    let parentID: String
  }

  // Bottom quick reply prompt
  private let composePromptContainer = UIView()
  private var composePromptHostingController: UIHostingController<AnyView>?
  // MARK: - Snapshot Serialization
  // Prevent overlapping diffable snapshot applications which can cause
  // UICollectionView invalid item count crashes under rapid updates.
  private var isApplyingSnapshot = false
  private var pendingSnapshot: NSDiffableDataSourceSnapshot<Section, Item>?
  private var temporarySectionEstimatedHeights: [Section: CGFloat] = [:]
  private var hasLoggedInitialRevealFirstPaintDiagnostics = false

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
        #if compiler(>=6.4)
        if #available(anyAppleOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
        }
        #endif

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
    case bottomSpacer
  }

  private enum Item: Hashable, Sendable {
    case loadMoreParentsTrigger
    case parentPost(ThreadRow)
    case mainPost(ThreadRow)
    /// Anchor slot when the thread's depth-0 post is blocked. The payload lives
    /// on `threadManager.blockedAnchor`; the case is keyed by the anchor URI so
    /// the diffable snapshot has a stable identity.
    case blockedAnchor(String)
    case reply(ThreadRow)
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
    let shouldLogTemporaryInitialDiagnostics = !hasScrolledToMainPost
    if shouldLogTemporaryInitialDiagnostics {
      controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: applySnapshot begin - sections: \(snapshot.sectionIdentifiers.count), items: \(snapshot.itemIdentifiers.count), contentOffsetY: \(self.collectionView.contentOffset.y)"
      )
    }

    UIView.performWithoutAnimation {
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self else { return }
        if shouldLogTemporaryInitialDiagnostics {
          self.controllerLogger.debug(
            "🧪 TEMP THREAD JUMP: applySnapshot completion - contentOffsetY: \(self.collectionView.contentOffset.y), hasPendingSnapshot: \(self.pendingSnapshot != nil)"
          )
        }
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
  init(
    appState: AppState,
    postURI: ATProtocolURI,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public
  ) {
    self.appState = appState
    self.postURI = postURI
    self.path = path
    self.visibilityContext = visibilityContext
    super.init(nibName: nil, bundle: nil)
    // Subscribe to state invalidation events for reply updates
    appState.stateInvalidationBus.subscribe(self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  isolated deinit {
    tearDown()
  }

  func tearDown() {
    // Cancel any pending load task
    pendingLoadTask?.cancel()
    pendingLoadTask = nil

    // Cancel all optimistic retry tasks
    for task in optimisticRetryTasks.values {
      task.cancel()
    }
    optimisticRetryTasks.removeAll()

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
    
    reloadThread()
  }
  
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    // Content extends beneath the glass; reserve its occluded area for scrolling
    // without counting the system's automatic bottom safe-area inset twice.
    let coveredHeight = composePromptContainer.isHidden
      ? 0 : max(0, collectionView.frame.maxY - composePromptContainer.frame.minY)
    let systemBottomInset = collectionView.adjustedContentInset.bottom - collectionView.contentInset.bottom
    let bottomInset = max(0, coveredHeight - systemBottomInset)
    if abs(collectionView.contentInset.bottom - bottomInset) > 0.5 {
      collectionView.contentInset.bottom = bottomInset
      collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
    }
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
    
    // The indent cap depends on width, so a size-class change re-lays out replies.
    if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass,
      threadManager?.threadData != nil {
      rebuildRows()
      updateDataSnapshot(animatingDifferences: false)
    }

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
    updateLink?.addAction(handler: { [weak self] _, _ in
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

    composePromptContainer.translatesAutoresizingMaskIntoConstraints = false
    composePromptContainer.backgroundColor = .clear
    composePromptContainer.isHidden = true

    view.addSubview(collectionView)
    view.addSubview(composePromptContainer)
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

      composePromptContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      composePromptContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      composePromptContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      loadingView.topAnchor.constraint(equalTo: view.topAnchor),
      loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }

  private func registerCells() {
    collectionView.register(ThreadRowCell.self, forCellWithReuseIdentifier: "ThreadRowCell")
    collectionView.register(MainPostCell.self, forCellWithReuseIdentifier: "MainPostCell")
    collectionView.register(BlockedAnchorCell.self, forCellWithReuseIdentifier: "BlockedAnchorCell")
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

    // Rows own their spacing so connectors can run edge to edge between cells.
    layoutSection.interGroupSpacing = 0

    return layoutSection
  }

  private func createCompositionalLayout() -> UICollectionViewLayout {
    let parentPostsEstimatedHeightFloor: CGFloat = 200
    let mainPostEstimatedHeightFloor: CGFloat = 400
    let repliesEstimatedHeightFloor: CGFloat = 250

    let layoutProvider: UICollectionViewCompositionalLayoutSectionProvider = {
      [weak self] (sectionIndex, _) -> NSCollectionLayoutSection? in
      guard let self = self, let section = Section(rawValue: sectionIndex) else { return nil }

      var estimatedHeight: CGFloat

      // Use pessimistic (max) height estimates across all items in each section.
      // Overestimates cause cells to shrink (invisible), while underestimates cause
      // cells to grow and push content down (the visible "jump scare").
      switch section {
      case .loadMoreParents:
        estimatedHeight = 50  // Fixed height for load more button

      case .parentPosts:
        let computedHeight = self.parentPosts
            .map { self.heightCalculator.calculateParentPostHeight(for: $0) }
            .max() ?? parentPostsEstimatedHeightFloor
        estimatedHeight = max(computedHeight, parentPostsEstimatedHeightFloor)

      case .mainPost:
        let computedHeight = self.mainPost.map {
          self.heightCalculator.calculateHeight(
            for: $0,
            mode: .mainPost
          )
        } ?? mainPostEstimatedHeightFloor
        estimatedHeight = max(computedHeight, mainPostEstimatedHeightFloor)

      case .replies:
        let computedHeight = self.replyRows
            .compactMap { self.threadItemsByID[$0.id] }
            .map { self.heightCalculator.calculateThreadItemHeight(for: $0) }
            .max() ?? repliesEstimatedHeightFloor
        estimatedHeight = max(computedHeight, repliesEstimatedHeightFloor)

      case .bottomSpacer:
        estimatedHeight = 600
      }

      self.temporarySectionEstimatedHeights[section] = estimatedHeight

      return self.createSection(with: estimatedHeight, for: section)
    }

    // Use a stock compositional layout; scroll position is preserved
    // manually by the update/restore helpers, so no custom subclass is needed.
    let layout = UICollectionViewCompositionalLayout(sectionProvider: layoutProvider)

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

      case .parentPost(let row), .reply(let row):
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "ThreadRowCell", for: indexPath)
          as! ThreadRowCell
        self.configure(cell, for: row)
        return cell

      case .mainPost(let row):
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "MainPostCell", for: indexPath)
          as! MainPostCell
        if let mainPost = self.mainPost {
          cell.configure(
            post: mainPost,
            appState: self.appState,
            path: self.path,
            opThreadPostIndex: self.mainPostIndex,
            opThreadPostCount: self.mainPostCount,
            visibilityContext: self.visibilityContext,
            showsLineFromParent: row.lineIn
          )
        }
        return cell
      case .blockedAnchor:
        let cell =
          collectionView.dequeueReusableCell(withReuseIdentifier: "BlockedAnchorCell", for: indexPath)
          as! BlockedAnchorCell
        if let blocked = self.threadManager?.blockedAnchor {
          cell.configure(
            blocked: blocked,
            anchorURI: self.postURI,
            appState: self.appState,
            path: self.path
          )
        }
        return cell

      case .spacer:
        return collectionView.dequeueReusableCell(withReuseIdentifier: "SpacerCell", for: indexPath)
      }
    }

    return dataSource
  }

  private func configure(_ cell: ThreadRowCell, for row: ThreadRow) {
    let parentAuthor = row.parentID.flatMap { self.threadItemsByID[$0]?.post?.author }
    let action: (() -> Void)?
    switch row.kind {
    case .showOtherReplies:
      action = { [weak self] in self?.loadHiddenRepliesFromButton() }
    case .readMoreUp:
      action = { [weak self] in self?.loadMoreParents() }
    case .ancestor, .anchor, .reply, .tombstone, .readMore:
      action = nil
    }
    cell.configure(
      row: row,
      threadItem: threadItemsByID[row.id],
      parentAuthor: parentAuthor,
      appState: appState,
      path: path,
      visibilityContext: visibilityContext,
      isActionLoading: row.kind == .showOtherReplies && isLoadingHiddenReplies,
      onAction: action
    )
  }

  /// Called when user taps the "Show More Replies" button
  private func loadHiddenRepliesFromButton() {
    guard !isLoadingHiddenReplies, !hasLoadedHiddenReplies else { return }
    
    isLoadingHiddenReplies = true
    updateShowMoreRepliesCell()
    
    Task { @MainActor in
      await threadManager?.loadHiddenReplies(uri: postURI)

      hasLoadedHiddenReplies = true
      isLoadingHiddenReplies = false

      // Rebuild so the hidden replies replace the button
      rebuildRows()
      updateDataSnapshot(animatingDifferences: true)
    }
  }

  /// Update the show more replies row to reflect loading state
  private func updateShowMoreRepliesCell() {
    var snapshot = dataSource.snapshot()
    let showMoreItems = snapshot.itemIdentifiers(inSection: .replies).filter {
      if case .reply(let row) = $0 { return row.kind == .showOtherReplies }
      return false
    }
    guard !showMoreItems.isEmpty else { return }
    snapshot.reconfigureItems(showMoreItems)
    applySnapshot(snapshot, animatingDifferences: false)
  }

  // MARK: - Thread Loading Logic
  @MainActor
  private func loadInitialThread() async {
    loadGeneration += 1
    let thisGeneration = loadGeneration
    defer {
      if self.loadGeneration == thisGeneration {
        self.pendingLoadTask = nil
      }
    }

    controllerLogger.debug("🧵 THREAD LOAD: Starting initial thread load for URI: \(self.postURI.uriString()) [gen: \(thisGeneration)]")
    isLoading = true

    let manager = ThreadManager(appState: appState)
    await manager.loadThread(uri: postURI, visibilityContext: visibilityContext)

    guard !Task.isCancelled && self.loadGeneration == thisGeneration else {
      controllerLogger.debug("🧵 THREAD LOAD: Task cancelled or superseded after loadThread [gen: \(thisGeneration)]")
      return
    }

    threadManager = manager

    // Check if the thread has no parent posts
    if let threadData = manager.threadData {
      if threadData.thread.filter({ $0.depth < 0 }).isEmpty {
        controllerLogger.debug("🧵 THREAD LOAD: This thread has no parent posts, marking as top of thread")
        hasReachedTopOfThread = true
      }
      
      // Track whether there are hidden replies available
      hasOtherReplies = threadData.hasOtherReplies
      
      // If auto-load setting is enabled, load hidden replies automatically
      // Otherwise, we'll show a "Show More Replies" button
      if appState.appSettings.showHiddenPosts && threadData.hasOtherReplies {
        await manager.loadHiddenReplies(uri: postURI)
        guard !Task.isCancelled && self.loadGeneration == thisGeneration else {
          controllerLogger.debug("🧵 THREAD LOAD: Task cancelled or superseded after loadHiddenReplies [gen: \(thisGeneration)]")
          return
        }
        hasLoadedHiddenReplies = true
      }
    }

    guard !Task.isCancelled && self.loadGeneration == thisGeneration else { return }

    processThreadData()

    // Pre-calculate all post heights
    if let mainPost = self.mainPost {
      _ = heightCalculator.calculateHeight(for: mainPost, mode: .mainPost)
      
      for parent in parentPosts {
        _ = heightCalculator.calculateParentPostHeight(for: parent)
      }
      
      for row in replyRows {
        if let item = threadItemsByID[row.id] {
          _ = heightCalculator.calculateThreadItemHeight(for: item)
        }
      }
    }

    loadingView.isHidden = true
    
    // Apply snapshot synchronously without animations
    controllerLogger.debug(
      "🧪 TEMP THREAD JUMP: about to apply initial snapshot - parents: \(self.parentPosts.count), replies: \(self.replyRows.count), hasMainPost: \(self.mainPost != nil)"
    )
    updateDataSnapshot(animatingDifferences: false)
    
    isLoading = false

    if mainPost != nil && !hasScrolledToMainPost {
      // Wait for collection view to complete layout after snapshot application
      // This is crucial when load more cell is present
      controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: initial layout pass begin - contentOffsetY: \(self.collectionView.contentOffset.y)"
      )
      UIView.performWithoutAnimation {
        collectionView.performBatchUpdates({
          // Force layout update
          self.controllerLogger.debug("🧪 TEMP THREAD JUMP: initial layoutIfNeeded begin")
          self.collectionView.layoutIfNeeded()
          self.controllerLogger.debug(
            "🧪 TEMP THREAD JUMP: initial layoutIfNeeded end - contentOffsetY: \(self.collectionView.contentOffset.y)"
          )
        }) { _ in }
      }
      controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: initial layout pass end - contentOffsetY: \(self.collectionView.contentOffset.y)"
      )
      // Proceed immediately after ensuring layout without animations
      do {
        // Now scroll to main post after layout is complete
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: before scrollToMainPostWithPartialParentVisibility - contentOffsetY: \(self.collectionView.contentOffset.y)"
        )
        self.scrollToMainPostWithPartialParentVisibility(animated: false) { [weak self] in
          guard let self, !Task.isCancelled, self.loadGeneration == thisGeneration else { return }
          self.controllerLogger.debug(
            "🧪 TEMP THREAD JUMP: initial stabilization complete - contentOffsetY: \(self.collectionView.contentOffset.y)"
          )
          // Fade in collection view only after stabilization completes
          self.runInitialRevealAnimation(sequence: "initial-scroll-path")
          // If VoiceOver is running, post focus to main post
          if UIAccessibility.isVoiceOverRunning {
            self.focusVoiceOverOnMainPost()
          }
        }
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: after scrollToMainPostWithPartialParentVisibility - contentOffsetY: \(self.collectionView.contentOffset.y)"
        )
        self.hasScrolledToMainPost = true
      }
    } else {
      // Fade in collection view to mask any layout settling animations
      self.runInitialRevealAnimation(sequence: "initial-no-scroll-path")
      // If VoiceOver is running, post focus to main post
      if UIAccessibility.isVoiceOverRunning {
        self.focusVoiceOverOnMainPost()
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

    // Warm identity for every blocked author in the thread so tombstone cards
    // can render handles/avatars without a per-card fetch stampede.
    let blockedDids: [String] = threadData.thread.compactMap {
      if case .appBskyUnspeccedDefsThreadItemBlocked(let blocked) = $0.value {
        return blocked.author.did.didString()
      }
      return nil
    }
    if !blockedDids.isEmpty {
      Task { await appState.blockedAuthorHydrator?.prefetch(dids: blockedDids) }
    }

    guard let mainItem = threadData.thread.first(where: { $0.depth == 0 }) else {
      parentPosts = []
      mainPost = nil
      mainPostIndex = nil
      mainPostCount = nil
      rebuildRows()
      return
    }

    switch mainItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      mainPost = threadItemPost.post
      mainPostIndex = threadItemPost.opThreadPostIndex
      mainPostCount = threadItemPost.opThreadPostCount
    case .appBskyUnspeccedDefsThreadItemBlocked:
      // Blocked anchor: the original post is hidden, but the AppView still
      // returns its parents and replies. Keep them so the conversation stays
      // reachable — the anchor slot renders a BlockedContentCard(.anchor).
      mainPost = nil
      mainPostIndex = nil
      mainPostCount = nil
    default:
      parentPosts = []
      mainPost = nil
      mainPostIndex = nil
      mainPostCount = nil
      optimisticReplies = []
      rebuildRows()
      return
    }

    // Parent posts (depth < 0), oldest (most negative) first
    let parentItems = threadData.thread.filter { $0.depth < 0 }.sorted { $0.depth < $1.depth }
    parentPosts = collectParentPostsV2(from: parentItems)
    rebuildRows()
  }

  /// Rebuilds `rows` from the thread data, loaded hidden replies and pending
  /// optimistic replies, and settles optimistic replies the server confirmed.
  private func rebuildRows() {
    let serverItems = threadManager?.threadData?.thread ?? []
    let hiddenItems = (threadManager?.hiddenReplies ?? []).map {
      AppBskyUnspeccedGetPostThreadV2.ThreadItem(otherItem: $0)
    }

    // Optimistic replies the server now returns are confirmed.
    let serverIDs = Set((serverItems + hiddenItems).map { $0.uri.uriString() })
    let confirmedURIs = Set(optimisticReplies.map { $0.threadItem.uri.uriString() }).intersection(serverIDs)
    if !confirmedURIs.isEmpty {
      optimisticReplies.removeAll { confirmedURIs.contains($0.threadItem.uri.uriString()) }
      for confirmedURI in confirmedURIs {
        optimisticRetryTasks[confirmedURI]?.cancel()
        optimisticRetryTasks.removeValue(forKey: confirmedURI)
      }
      optimisticReplyUris.subtract(confirmedURIs)
      hasOptimisticUpdates = !optimisticReplyUris.isEmpty
    }

    let pendingItems = optimisticReplies.map {
      ThreadRowBuilder.Item(
        uri: $0.threadItem.uri,
        depth: $0.threadItem.depth,
        content: .post(recordParentID: $0.parentID, isOpThread: false, moreReplies: 0, moreParents: false)
      )
    }

    var itemsByID: [String: AppBskyUnspeccedGetPostThreadV2.ThreadItem] = [:]
    for item in serverItems + hiddenItems + optimisticReplies.map(\.threadItem) {
      itemsByID[item.uri.uriString()] = itemsByID[item.uri.uriString()] ?? item
    }
    changedRowIDs = Set(itemsByID.compactMap { id, item in
      threadItemsByID[id].map { $0 != item ? id : nil } ?? nil
    })
    threadItemsByID = itemsByID

    rows = ThreadRowBuilder.build(
      items: ThreadRowBuilder.inserting(pendingItems, into: serverItems.map(ThreadRowBuilder.Item.init)),
      otherItems: hiddenItems.map(ThreadRowBuilder.Item.init),
      mode: ThreadLayoutMode(threadedReplies: appState.appSettings.threadedReplies),
      maxIndentLevels: ThreadReplyGeometry.maxIndentLevels(
        isRegularWidth: traitCollection.horizontalSizeClass == .regular),
      showsOtherRepliesPrompt: hasOtherReplies && !hasLoadedHiddenReplies
    )
    parentRows = rows.filter { $0.depth < 0 && $0.kind != .readMoreUp }
    anchorRow = rows.first { $0.kind == .anchor }
    replyRows = rows.filter { $0.depth > 0 }
  }

  // MARK: - Compose Prompt Management

  static func makeComposePromptHostingController(
    rootView: AnyView
  ) -> UIHostingController<AnyView> {
    let hostingController = UIHostingController(
      rootView: AnyView(rootView.fixedSize(horizontal: false, vertical: true))
    )
    hostingController.view.setContentHuggingPriority(.required, for: .vertical)
    hostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
    hostingController.sizingOptions = .intrinsicContentSize
    return hostingController
  }

  private func updateComposePrompt() {
    guard isViewLoaded else { return }
    if let mainPost = self.mainPost {
      setupComposePrompt(with: mainPost)
    } else {
      hideComposePrompt()
    }
  }

  private func setupComposePrompt(with post: AppBskyFeedDefs.PostView) {
    let promptView = ThreadComposePrompt(post: post, appState: appState)
      .applyAppStateEnvironment(appState)

    if let existingHC = composePromptHostingController {
      existingHC.rootView = AnyView(promptView.fixedSize(horizontal: false, vertical: true))
      composePromptContainer.isHidden = false
      return
    }

    let hostingController = Self.makeComposePromptHostingController(rootView: AnyView(promptView))
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear

    addChild(hostingController)
    composePromptContainer.addSubview(hostingController.view)

    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: composePromptContainer.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: composePromptContainer.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: composePromptContainer.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: composePromptContainer.bottomAnchor)
    ])

    hostingController.didMove(toParent: self)
    composePromptHostingController = hostingController
    composePromptContainer.isHidden = false
  }

  private func hideComposePrompt() {
    composePromptHostingController?.rootView = AnyView(EmptyView())
    composePromptContainer.isHidden = true
  }

  private func updateDataSnapshot(animatingDifferences: Bool = false) {
    seedThreadEntityCache()
    updateComposePrompt()
    applySnapshot(makeSnapshot(), animatingDifferences: animatingDifferences)
  }

  /// A snapshot of the current rows. Rows whose thread item changed since the
  /// previous rebuild are reconfigured in place.
  private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections(Section.allCases)

    // The load more trigger stays while parents exist and the top is unreached
    if !parentPosts.isEmpty && !hasReachedTopOfThread {
      snapshot.appendItems([.loadMoreParentsTrigger], toSection: .loadMoreParents)
    }

    // Parents in chronological order (oldest first, newest last)
    snapshot.appendItems(parentRows.map { Item.parentPost($0) }, toSection: .parentPosts)

    // Main post if available, else the blocked-anchor tombstone card.
    if mainPost != nil, let anchorRow {
      snapshot.appendItems([.mainPost(anchorRow)], toSection: .mainPost)
    } else if threadManager?.blockedAnchor != nil {
      snapshot.appendItems([.blockedAnchor(postURI.uriString())], toSection: .mainPost)
    }

    snapshot.appendItems(replyRows.map { Item.reply($0) }, toSection: .replies)
    snapshot.appendItems([.spacer], toSection: .bottomSpacer)

    if !changedRowIDs.isEmpty {
      let current = dataSource.snapshot()
      let changed = snapshot.itemIdentifiers.filter { item in
        switch item {
        case .parentPost(let row), .reply(let row):
          return changedRowIDs.contains(row.id) && current.indexOfItem(item) != nil
        case .loadMoreParentsTrigger, .mainPost, .blockedAnchor, .spacer:
          return false
        }
      }
      if !changed.isEmpty {
        snapshot.reconfigureItems(changed)
      }
      changedRowIDs = []
    }

    return snapshot
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

  private func runInitialRevealAnimation(sequence: String) {
    controllerLogger.debug(
      "🧪 TEMP THREAD JUMP: \(sequence) reveal animation about to start - alpha: \(self.collectionView.alpha)"
    )
    UIView.animate(withDuration: 0.25, delay: 0.1, options: [.curveEaseOut]) {
      self.collectionView.alpha = 1
    } completion: { [weak self] finished in
      guard let self else { return }
      self.controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: \(sequence) reveal animation completion begin - finished: \(finished), alpha: \(self.collectionView.alpha)"
      )
      self.logInitialRevealFirstPaintDiagnosticsIfNeeded()
      self.controllerLogger.debug("🧪 TEMP THREAD JUMP: \(sequence) reveal animation completion end")
    }
    controllerLogger.debug("🧪 TEMP THREAD JUMP: \(sequence) reveal animation started")
  }

  private func logInitialRevealFirstPaintDiagnosticsIfNeeded() {
    guard !hasLoggedInitialRevealFirstPaintDiagnostics else { return }
    hasLoggedInitialRevealFirstPaintDiagnostics = true

    collectionView.layoutIfNeeded()

    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted {
      if $0.section == $1.section {
        return $0.item < $1.item
      }
      return $0.section < $1.section
    }

    guard !visibleIndexPaths.isEmpty else {
      controllerLogger.debug("🧪 TEMP THREAD JUMP: first-paint diagnostic - no visible cells")
      return
    }

    let visibleSections = Set(visibleIndexPaths.compactMap { Section(rawValue: $0.section) })
    for section in visibleSections.sorted(by: { $0.rawValue < $1.rawValue }) {
      let estimatedHeightText = temporarySectionEstimatedHeights[section].map { "\($0)" } ?? "unavailable"
      controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: first-paint section estimate - section: \(String(describing: section)), estimatedHeight: \(estimatedHeightText)"
      )
    }

    for indexPath in visibleIndexPaths {
      guard let section = Section(rawValue: indexPath.section) else { continue }
      let estimatedHeightText = temporarySectionEstimatedHeights[section].map { "\($0)" } ?? "unavailable"
      let actualHeightText = collectionView.layoutAttributesForItem(at: indexPath).map { "\($0.frame.height)" } ?? "unavailable"
      controllerLogger.debug(
        "🧪 TEMP THREAD JUMP: first-paint cell metrics - section: \(String(describing: section)), item: \(indexPath.item), estimatedSectionHeight: \(estimatedHeightText), actualFrameHeight: \(actualHeightText)"
      )
    }
  }

  // MARK: - Scrolling
    private func focusVoiceOverOnMainPost() {
        guard mainPost != nil else { return }

        let snapshot = dataSource.snapshot()
        
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
    
    private func scrollToMainPostWithPartialParentVisibility(animated: Bool, completion: (() -> Void)? = nil) {
        guard mainPost != nil else {
            completion?()
            return
        }
        
        // If VoiceOver is running and not animated, delay slightly
        if UIAccessibility.isVoiceOverRunning && !animated {
            // Give VoiceOver time to initialize before scrolling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScrollToMainPost(animated: false, completion: completion)
            }
        } else {
            performScrollToMainPost(animated: animated, completion: completion)
        }
    }
    
    private func performScrollToMainPost(animated: Bool, completion: (() -> Void)? = nil) {
        guard mainPost != nil else {
            completion?()
            return
        }

        // Find the index path for the main post
        let snapshot = dataSource.snapshot()
        
        guard let sectionIndex = snapshot.indexOfSection(.mainPost),
              snapshot.numberOfItems(inSection: .mainPost) > 0
        else {
            completion?()
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
            let adjustedContentInset = self.collectionView.adjustedContentInset
            let scrollTarget = ThreadMainPostScrollTarget(
                mainPostY: mainPostY,
                adjustedTopInset: adjustedContentInset.top,
                hasParentPosts: hasParentPosts
            )
            
            self.controllerLogger.debug("🔍 POSITIONING DEBUG:")
            self.controllerLogger.debug("  - adjustedContentInset.top: \(adjustedContentInset.top)")
            self.controllerLogger.debug("  - mainPostY: \(mainPostY)")
            self.controllerLogger.debug("  - hasParentPosts: \(hasParentPosts)")
            
            offset = scrollTarget.offset
            if hasParentPosts {
                self.controllerLogger.debug("  - WITH parents offset: \(offset)")
            } else {
                self.controllerLogger.debug("  - NO parents offset: \(offset)")
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
          },
          completion: { _ in
            completion?()
          })
      } else {
        // For non-animated scrolling, do multiple passes to ensure stability

        // First pass - calculate initial position
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: non-animated first pass begin - contentOffsetY: \(self.collectionView.contentOffset.y)"
        )
        let firstPassOffset = calculateAndApplyOffset(true)
        let firstPassVisibleTop = self.collectionView.layoutAttributesForItem(at: indexPath).map {
          $0.frame.origin.y - self.collectionView.contentOffset.y
        }
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: non-animated first pass end - targetOffsetY: \(firstPassOffset.map { "\($0)" } ?? "nil"), contentOffsetY: \(self.collectionView.contentOffset.y), mainVisibleTop: \(firstPassVisibleTop.map { "\($0)" } ?? "unavailable")"
        )

        // Second immediate pass - recalculate and apply refined position
        // This helps account for any layout adjustments after the first scroll
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: non-animated second pass begin - contentOffsetY: \(self.collectionView.contentOffset.y)"
        )
        let secondPassOffset = calculateAndApplyOffset(true)
        let secondPassVisibleTop = self.collectionView.layoutAttributesForItem(at: indexPath).map {
          $0.frame.origin.y - self.collectionView.contentOffset.y
        }
        self.controllerLogger.debug(
          "🧪 TEMP THREAD JUMP: non-animated second pass end - targetOffsetY: \(secondPassOffset.map { "\($0)" } ?? "nil"), contentOffsetY: \(self.collectionView.contentOffset.y), mainVisibleTop: \(secondPassVisibleTop.map { "\($0)" } ?? "unavailable")"
        )

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
          self.controllerLogger.debug(
            "🧪 TEMP THREAD JUMP: delayed verification pass begin - contentOffsetY: \(self.collectionView.contentOffset.y)"
          )
          if let attrs = self.collectionView.layoutAttributesForItem(at: indexPath) {
            let visibleTop = attrs.frame.origin.y - self.collectionView.contentOffset.y
            self.controllerLogger.debug(
              "DELAYED position check - Main post visible top offset: \(visibleTop)pt")
            self.controllerLogger.debug(
              "🧪 TEMP THREAD JUMP: delayed verification pass metrics - contentOffsetY: \(self.collectionView.contentOffset.y), mainVisibleTop: \(visibleTop)"
            )

            // If position has drifted, correct it again
            let adjustedContentInset = self.collectionView.adjustedContentInset
            let scrollTarget = ThreadMainPostScrollTarget(
              mainPostY: attrs.frame.origin.y,
              adjustedTopInset: adjustedContentInset.top,
              hasParentPosts: hasParentPosts
            )
            let expectedVisibleTop = scrollTarget.expectedVisibleTop
            let correctedOffset = scrollTarget.offset
            
            if abs(visibleTop - expectedVisibleTop) > 2 {  // Allow 2pt tolerance
              self.controllerLogger.debug("Correcting position drift to: \(correctedOffset)")

              // Use transaction to ensure it applies cleanly
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              self.collectionView.setContentOffset(CGPoint(x: 0, y: correctedOffset), animated: false)
              CATransaction.commit()
            }
          } else {
            self.controllerLogger.debug(
              "🧪 TEMP THREAD JUMP: delayed verification pass metrics unavailable - contentOffsetY: \(self.collectionView.contentOffset.y)"
            )
          }
          completion?()
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

    rebuildRows()
    seedThreadEntityCache()

    // Apply snapshot immediately for layout calculation
    applySnapshot(makeSnapshot(), animatingDifferences: false)
    
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
    currentPostIds.append(contentsOf: replyRows.filter(\.isPost).map(\.id))

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
        let maxOffset = max(minOffset, maxEstimatedContentHeight - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        
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
      guard firstVisibleIndexPath.item < replyRows.count else {
        controllerLogger.debug("⚠️ Reply index out of bounds: \(firstVisibleIndexPath.item)")
        return nil
      }
      postId = replyRows[firstVisibleIndexPath.item].id
      
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
      for (index, row) in replyRows.enumerated() where !row.id.hasPrefix("at://unknown") {
        mapping[row.id] = IndexPath(item: index, section: Section.replies.rawValue)
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

  // MARK: - State Invalidation Handling
  
  // Properties for optimistic updates
  private var hasOptimisticUpdates = false
  private var optimisticReplyUris = Set<String>()
  
  nonisolated func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .replyCreated, .threadUpdated:
      return true
    default:
      return false
    }
  }

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
      if rootUri == currentPostUri {
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
    
    // Check loaded and optimistic replies
    return threadItemsByID[parentUri].map { $0.depth > 0 } ?? false
  }
  
  /// Reload the thread to pick up new content
  private func reloadThread() {
    controllerLogger.info("Reloading thread due to state invalidation")
    
    // Cancel any pending load task
    pendingLoadTask?.cancel()
    
    // Start a new load task
    pendingLoadTask = Task { @MainActor [weak self] in
      await self?.loadInitialThread()
    }
  }

  @MainActor
  func reloadThreadFromSettingsChange() {
    reloadThread()
  }

  // MARK: - Optimistic Updates
  
  @MainActor
  private func addReplyOptimistically(_ reply: AppBskyFeedDefs.PostView, toParentUri parentUri: String) {
    let replyUriString = reply.uri.uriString()
    controllerLogger.info("Adding reply optimistically: \(replyUriString) to parent: \(parentUri)")
    
    // Replies to ancestors are not part of this thread's reply tree.
    let parentDepth: Int
    if parentUri == mainPost?.uri.uriString() {
      parentDepth = 0
    } else if let parentItem = threadItemsByID[parentUri], parentItem.depth > 0 {
      parentDepth = parentItem.depth
    } else {
      return
    }
    guard threadItemsByID[replyUriString] == nil else { return }

    optimisticReplies.append(
      OptimisticReply(
        threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem(optimisticReply: reply, depth: parentDepth + 1),
        parentID: parentUri
      ))
    rebuildRows()
    // Apply without animation for optimistic updates to avoid fly-in
    updateDataSnapshot(animatingDifferences: false)

    hasOptimisticUpdates = true
    optimisticReplyUris.insert(replyUriString)
    
    // Schedule a background refresh to get real data with retries
    optimisticRetryTasks[replyUriString]?.cancel()
    optimisticRetryTasks[replyUriString] = Task { [weak self] in
      for attempt in 1...5 {
        do {
          try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) // 1.5s, 3s, 4.5s, 6s, 7.5s
        } catch {
          return // Task cancelled
        }
        guard !Task.isCancelled else { return }
        
        let stillUnconfirmed = await MainActor.run { [weak self] () -> Bool in
          guard let self = self else { return false }
          if self.hasOptimisticUpdates && self.optimisticReplyUris.contains(replyUriString) {
            self.controllerLogger.debug("Optimistic update refresh attempt \(attempt) for reply: \(replyUriString)")
            self.reloadThread()
          }
          return self.optimisticReplyUris.contains(replyUriString)
        }
        
        if !stillUnconfirmed {
          await MainActor.run { [weak self] in
            self?.controllerLogger.debug("Optimistic reply confirmed after attempt \(attempt)")
            self?.optimisticRetryTasks.removeValue(forKey: replyUriString)
          }
          return
        }
      }
      
      // Final cleanup after all attempts
      await MainActor.run { [weak self] in
        guard let self = self else { return }
        defer { self.optimisticRetryTasks.removeValue(forKey: replyUriString) }
        if self.optimisticReplyUris.contains(replyUriString) {
          self.controllerLogger.warning("Failed to confirm optimistic reply after 5 attempts, removing: \(replyUriString)")
          self.optimisticReplyUris.remove(replyUriString)
          self.optimisticReplies.removeAll { $0.threadItem.uri.uriString() == replyUriString }
          if self.optimisticReplyUris.isEmpty {
            self.hasOptimisticUpdates = false
          }
          self.reloadThread()
        }
      }
    }
  }
  
  /// Writes every post represented by the upcoming UIKit snapshot before its
  /// responder annotations become visible to Siri/AppIntentsTesting.
  private func seedThreadEntityCache() {
    var posts: [AppBskyFeedDefs.PostView] = rows.compactMap { self.threadItemsByID[$0.id]?.post }
    if let mainPost, !posts.contains(where: { $0.uri == mainPost.uri }) {
      posts.append(mainPost)
    }
    PostEntityCache.upsert(posts)
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

#endif
