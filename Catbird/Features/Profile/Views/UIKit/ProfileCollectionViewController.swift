import UIKit
import SwiftUI
import Petrel
import os

/// Profile view controller using UICollectionViewCompositionalLayout.
///
/// Architecture:
///   1. ProfileBannerView — pinned behind the collection view, stretches on overscroll
///   2. UICollectionView (compositional layout)
///      - Section 0 (header): banner spacer → profile info → followed by → tab bar spacer
///      - Section 1 (content): posts / replies / media cells with UIHostingConfiguration
///   3. ProfileTabBar — floating over collection view, frame-based 60fps positioning
///   4. scrollViewDidScroll → drives banner stretch/blur + tab bar pinning
@available(iOS 18.0, *)
final class ProfileCollectionViewController: UIViewController {

  // MARK: - Types

  enum Section: Int, CaseIterable {
    case header
    case content
  }

  enum Item: Hashable {
    case bannerSpacer
    case profileInfo
    case followedBy
    case tabBarSpacer
    case post(uri: String)
    case loading
    case empty(message: String)
  }

  // MARK: - Dependencies

  private let appState: AppState
  private var viewModel: ProfileViewModel
  private var isEditingProfileBinding: Binding<Bool>
  private var navigationPathBinding: Binding<NavigationPath>

  // MARK: - Layout Constants

  private let bannerHeight: CGFloat = 160

  // MARK: - UI Components

  private lazy var bannerView: ProfileBannerView = {
    let v = ProfileBannerView()
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

  private lazy var tabBar: ProfileTabBar = {
    let tb = ProfileTabBar(isLabeler: viewModel.isLabeler)
    tb.translatesAutoresizingMaskIntoConstraints = false
    tb.selectedTab = viewModel.selectedProfileTab
    tb.onTabChange = { [weak self] tab in
      self?.handleTabSelection(tab)
    }
    return tb
  }()

  // MARK: - Sticky Tracking

  /// Y position (in collection view content coordinates) where tab bar naturally sits
  private var tabBarNaturalY: CGFloat = 0

  // MARK: - Post Data Cache

  /// Maps post URIs to FeedViewPost for cell configuration
  private var postsByURI: [String: AppBskyFeedDefs.FeedViewPost] = [:]

  // MARK: - Observation

  private var observationTask: Task<Void, Never>?
  private var lastObservedProfileDID: String?

    internal let profileLogger = Logger(subsystem: "blue.catbird", category: "ProfileCollectionVC")

  // MARK: - Initialization

  init(
    appState: AppState,
    viewModel: ProfileViewModel,
    isEditingProfile: Binding<Bool>,
    navigationPath: Binding<NavigationPath>
  ) {
    self.appState = appState
    self.viewModel = viewModel
    self.isEditingProfileBinding = isEditingProfile
    self.navigationPathBinding = navigationPath
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("ProfileCollectionViewController does not support coder init")
  }

  deinit {
    observationTask?.cancel()
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupBackground()
    setupBannerView()
    setupCollectionView()
    setupDataSource()
    setupTabBar()
    setupObservation()
    applyInitialSnapshot()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    recalculateTabBarNaturalY()
    updateTabBarPosition(scrollOffset: collectionView.contentOffset.y)
    tabBar.frame.size.width = view.bounds.width
  }

  // MARK: - Setup

  private func setupBackground() {
    let scheme: ColorScheme = view.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    view.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: scheme))
  }

  private func setupBannerView() {
    view.addSubview(bannerView)
    NSLayoutConstraint.activate([
      bannerView.topAnchor.constraint(equalTo: view.topAnchor),
      bannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bannerView.heightAnchor.constraint(equalToConstant: bannerHeight)
    ])
  }

  private func setupCollectionView() {
    let layout = createLayout()
    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.alwaysBounceVertical = true
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.showsVerticalScrollIndicator = true
    collectionView.refreshControl = makeRefreshControl()

    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }

  private func setupTabBar() {
    view.addSubview(tabBar)
    tabBar.frame = CGRect(
      x: 0,
      y: bannerHeight,
      width: view.bounds.width,
      height: ProfileTabBar.height
    )
  }

  // MARK: - Compositional Layout

  private func createLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
      guard let section = Section(rawValue: sectionIndex) else { return nil }
      switch section {
      case .header:
        return self?.createHeaderSection(environment: environment)
      case .content:
        return self?.createContentSection(environment: environment)
      }
    }
  }

  /// Header section: full-width, self-sizing items stacked vertically.
  /// Contains banner spacer, profile info, optionally followed-by, and tab bar spacer.
  private func createHeaderSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(200)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(200)
      ),
      subitems: [item]
    )
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 0
    return section
  }

  /// Content section: vertical list of feed items (posts, replies, media).
  /// Each cell self-sizes via UIHostingConfiguration.
  ///
  /// Returns an NSCollectionLayoutSection configured for a vertical feed:
  ///   1. Item size — full width, estimated height for self-sizing
  ///   2. Group — vertical, wrapping the item
  ///   3. Section — with appropriate spacing
  ///
  /// Use .estimated() height so UIHostingConfiguration cells can self-size.
  /// The estimated value is just the initial guess for the layout engine.
  private func createContentSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(300)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(300)
      ),
      subitems: [item]
    )
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 8
    section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0)
    return section
  }

  // MARK: - Data Source

  private func setupDataSource() {
    let bannerHeight = self.bannerHeight

    // Banner spacer: transparent cell reserving space for the banner behind the collection view
    let bannerSpacerReg = UICollectionView.CellRegistration<UICollectionViewCell, Void> {
      cell, _, _ in
      cell.contentConfiguration = UIHostingConfiguration {
        Color.clear.frame(height: bannerHeight)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Profile info: SwiftUI ProfileInfoView hosted in a cell
    let profileInfoReg = UICollectionView.CellRegistration<UICollectionViewCell, Void> {
      [weak self] cell, _, _ in
      guard let self, let profile = self.viewModel.profile else { return }
      cell.contentConfiguration = UIHostingConfiguration {
        ProfileInfoView(
          profile: profile,
          viewModel: self.viewModel,
          appState: self.appState,
          isEditingProfile: self.isEditingProfileBinding,
          path: self.navigationPathBinding
        )
        .environment(self.appState)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Followed-by row
    let followedByReg = UICollectionView.CellRegistration<UICollectionViewCell, Void> {
      [weak self] cell, _, _ in
      guard let self, let profile = self.viewModel.profile else { return }
      cell.contentConfiguration = UIHostingConfiguration {
        FollowedByView(
          knownFollowers: self.viewModel.knownFollowers,
          totalFollowersCount: profile.followersCount ?? 0,
          profileDID: profile.did.didString(),
          path: self.navigationPathBinding
        )
        .environment(self.appState)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Tab bar spacer: reserves height for the floating tab bar
    let tabBarSpacerReg = UICollectionView.CellRegistration<UICollectionViewCell, Void> {
      cell, _, _ in
      cell.contentConfiguration = UIHostingConfiguration {
        Color.clear.frame(height: ProfileTabBar.height)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Post cell: feed item rendered via UIHostingConfiguration
    let postReg = UICollectionView.CellRegistration<UICollectionViewCell, String> {
      [weak self] cell, _, uri in
      guard let self, let feedPost = self.postsByURI[uri] else { return }
      guard let cached = CachedFeedViewPost(feedViewPost: feedPost) else { return }
      cell.contentConfiguration = UIHostingConfiguration {
        VStack(spacing: 0) {
          EnhancedFeedPost(cachedPost: cached, path: self.navigationPathBinding)
          Divider().padding(.top, 8)
        }
        .environment(self.appState)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Loading indicator cell
    let loadingReg = UICollectionView.CellRegistration<UICollectionViewCell, Void> {
      cell, _, _ in
      cell.contentConfiguration = UIHostingConfiguration {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    // Empty state cell
    let emptyReg = UICollectionView.CellRegistration<UICollectionViewCell, String> {
      cell, _, message in
      cell.contentConfiguration = UIHostingConfiguration {
        VStack(spacing: 16) {
          Image(systemName: "square.stack.3d.up.slash")
            .font(.system(size: 48, weight: .light))
            .foregroundStyle(.tertiary)
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.top, 40)
      }
      .margins(.all, 0)
      cell.backgroundConfiguration = .clear()
    }

    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
      collectionView, indexPath, item in
      switch item {
      case .bannerSpacer:
        return collectionView.dequeueConfiguredReusableCell(using: bannerSpacerReg, for: indexPath, item: ())
      case .profileInfo:
        return collectionView.dequeueConfiguredReusableCell(using: profileInfoReg, for: indexPath, item: ())
      case .followedBy:
        return collectionView.dequeueConfiguredReusableCell(using: followedByReg, for: indexPath, item: ())
      case .tabBarSpacer:
        return collectionView.dequeueConfiguredReusableCell(using: tabBarSpacerReg, for: indexPath, item: ())
      case .post(let uri):
        return collectionView.dequeueConfiguredReusableCell(using: postReg, for: indexPath, item: uri)
      case .loading:
        return collectionView.dequeueConfiguredReusableCell(using: loadingReg, for: indexPath, item: ())
      case .empty(let message):
        return collectionView.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: message)
      }
    }
  }

  // MARK: - Snapshot Management

  private func applyInitialSnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.header, .content])
    snapshot.appendItems([.bannerSpacer, .tabBarSpacer], toSection: .header)
    snapshot.appendItems([.loading], toSection: .content)
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  private func rebuildHeaderSnapshot() {
    guard viewModel.profile != nil else { return }

    var snapshot = dataSource.snapshot()
    let existing = snapshot.itemIdentifiers(inSection: .header)
    snapshot.deleteItems(existing)

    var items: [Item] = [.bannerSpacer, .profileInfo]
    if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
      items.append(.followedBy)
    }
    items.append(.tabBarSpacer)
    snapshot.appendItems(items, toSection: .header)

    dataSource.apply(snapshot, animatingDifferences: false)

    DispatchQueue.main.async { [weak self] in
      self?.recalculateTabBarNaturalY()
    }
  }

  private func updateContentSnapshot(animated: Bool = true) {
    let tab = viewModel.selectedProfileTab
    let posts: [AppBskyFeedDefs.FeedViewPost]

    switch tab {
    case .posts:
      var all: [AppBskyFeedDefs.FeedViewPost] = []
      let pinnedURI = viewModel.pinnedPost?.post.uri.uriString()
      if let pinned = viewModel.pinnedPost { all.append(pinned) }
      all.append(contentsOf: viewModel.posts.filter { $0.post.uri.uriString() != pinnedURI })
      posts = all
    case .replies:
      posts = viewModel.replies
    case .media:
      posts = viewModel.postsWithMedia
    default:
      posts = []
    }

    // Rebuild URI → post cache
    postsByURI.removeAll(keepingCapacity: true)
    for post in posts {
      postsByURI[post.post.uri.uriString()] = post
    }

    var snapshot = dataSource.snapshot()
    let existing = snapshot.itemIdentifiers(inSection: .content)
    snapshot.deleteItems(existing)

    if viewModel.isLoading && posts.isEmpty {
      snapshot.appendItems([.loading], toSection: .content)
    } else if posts.isEmpty {
      let message: String
      switch tab {
      case .posts: message = "No posts yet"
      case .replies: message = "No replies"
      case .media: message = "No media posts"
      default: message = "Nothing here"
      }
      snapshot.appendItems([.empty(message: message)], toSection: .content)
    } else {
      let items = posts.map { Item.post(uri: $0.post.uri.uriString()) }
      snapshot.appendItems(items, toSection: .content)
    }

    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  // MARK: - Tab Bar Positioning

  private func recalculateTabBarNaturalY() {
    let snapshot = dataSource.snapshot()
    let headerItems = snapshot.itemIdentifiers(inSection: .header)
    guard let spacerIndex = headerItems.firstIndex(of: .tabBarSpacer) else { return }
    let indexPath = IndexPath(item: spacerIndex, section: Section.header.rawValue)

    // Prefer visible cell frame; fall back to layout attributes
    if let cell = collectionView.cellForItem(at: indexPath) {
      tabBarNaturalY = cell.frame.origin.y
    } else if let attrs = collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath) {
      tabBarNaturalY = attrs.frame.origin.y
    }
  }

  private func updateTabBarPosition(scrollOffset: CGFloat) {
    let safeAreaTop = view.safeAreaInsets.top
    let naturalY = tabBarNaturalY - scrollOffset
    let clampedY = max(safeAreaTop, naturalY)
    // Frame-based — bypasses constraint engine for 60fps scroll
    tabBar.frame.origin.y = clampedY
    tabBar.isAtTop = clampedY <= safeAreaTop + 1
  }

  // MARK: - Tab Handling

  private func handleTabSelection(_ tab: ProfileTab) {
    viewModel.selectedProfileTab = tab
    Task {
      await loadContentForTab(tab)
      await MainActor.run { [weak self] in
        self?.updateContentSnapshot(animated: true)
      }
    }
  }

  private func loadContentForTab(_ tab: ProfileTab) async {
    switch tab {
    case .posts: await viewModel.loadPosts()
    case .replies: await viewModel.loadReplies()
    case .media: await viewModel.loadMediaPosts()
    case .likes: await viewModel.loadLikes()
    case .lists: await viewModel.loadLists()
    case .starterPacks: await viewModel.loadStarterPacks()
    case .feeds: await viewModel.loadFeeds()
    case .labelerInfo:
      if viewModel.labelerDetails == nil { await viewModel.loadLabelerDetails() }
    default: break
    }
  }

  // MARK: - Refresh

  private func makeRefreshControl() -> UIRefreshControl {
    let rc = UIRefreshControl()
    rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    rc.tintColor = .white
    return rc
  }

  @objc private func handleRefresh() {
    Task {
      await viewModel.loadProfile()
      if !viewModel.isCurrentUser { await viewModel.loadKnownFollowers() }
      await loadContentForTab(viewModel.selectedProfileTab)
      await MainActor.run { [weak self] in
        self?.rebuildHeaderSnapshot()
        self?.updateContentSnapshot(animated: false)
        self?.updateBannerForCurrentProfile()
        UIView.animate(withDuration: 0.3) {
          self?.collectionView.refreshControl?.endRefreshing()
        }
      }
    }
  }

  // MARK: - Banner

  private func updateBannerForCurrentProfile() {
    guard let profile = viewModel.profile else { return }
    let bannerURL = profile.banner.flatMap { URL(string: $0.uriString()) }
    bannerView.configure(bannerURL: bannerURL, accentColor: .systemBlue)
  }

  // MARK: - Observation

  private func setupObservation() {
    observationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.observeViewModel()
    }
  }

  private func observeViewModel() async {
    while !Task.isCancelled {
      await withObservationTracking {
        _ = viewModel.profile?.did
        _ = viewModel.knownFollowers.count
        _ = viewModel.posts.count
        _ = viewModel.replies.count
        _ = viewModel.postsWithMedia.count
        _ = viewModel.isLoading
      } onChange: {
        Task { @MainActor [weak self] in
          guard let self, !Task.isCancelled else { return }
          let newDID = self.viewModel.profile?.did.didString()
          if newDID != self.lastObservedProfileDID {
            self.lastObservedProfileDID = newDID
            self.rebuildHeaderSnapshot()
            self.updateContentSnapshot(animated: false)
            self.updateBannerForCurrentProfile()
            self.tabBar.updateSections(isLabeler: self.viewModel.isLabeler)
            self.tabBar.selectedTab = self.viewModel.selectedProfileTab
          } else {
            self.updateContentSnapshot(animated: true)
          }
        }
      }
      try? await Task.sleep(nanoseconds: 500_000_000)
    }
  }
}

// MARK: - UICollectionViewDelegate

@available(iOS 18.0, *)
extension ProfileCollectionViewController: UICollectionViewDelegate {

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let offset = scrollView.contentOffset.y
    bannerView.update(scrollOffset: offset)
    updateTabBarPosition(scrollOffset: offset)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard indexPath.section == Section.content.rawValue else { return }
    let contentItems = dataSource.snapshot().itemIdentifiers(inSection: .content)
    let isNearEnd = indexPath.item >= contentItems.count - 3

    if isNearEnd && !viewModel.isLoadingMorePosts {
      Task {
        await loadContentForTab(viewModel.selectedProfileTab)
        await MainActor.run { [weak self] in
          self?.updateContentSnapshot(animated: true)
        }
      }
    }
  }
}
