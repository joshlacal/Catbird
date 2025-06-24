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
  
    internal let profileLogger = Logger(subsystem: "blue.catbird", category: "UIKitProfileViewController")
  
  // MARK: - UI Components
  private lazy var collectionView: UICollectionView = {
    let layout = createCompositionalLayout()
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.showsVerticalScrollIndicator = true
    collectionView.delegate = self
    
    // Use automatic content inset adjustment for proper safe area handling
    collectionView.contentInsetAdjustmentBehavior = .automatic
    
    // Register refresh control
    collectionView.refreshControl = refreshControl
    
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
    case banner
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
    fatalError("init(coder:) has not been implemented")
  }
  
  // MARK: - Lifecycle
  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    registerCells()
    setupObservers()
    loadInitialData()
  }
  
  private func setupObservers() {
    // Use withObservationTracking to observe ProfileViewModel changes
    Task { @MainActor in
      await observeViewModelChanges()
    }
  }
  
  @MainActor
  private func observeViewModelChanges() async {
    while !Task.isCancelled {
        withObservationTracking {
        // Access the properties we want to observe
        _ = viewModel.profile
        _ = viewModel.posts
        _ = viewModel.replies
        _ = viewModel.postsWithMedia
        _ = viewModel.isLoading
        _ = viewModel.selectedProfileTab
      } onChange: {
        Task { @MainActor in
            self.updateSnapshot()
        }
      }
      
      // Small delay to prevent excessive updates
      try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    }
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureNavigationAndToolbarTheme()
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      configureNavigationAndToolbarTheme()
      collectionView.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    }
  }
  
  // MARK: - Setup
  private func setupUI() {
    view.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: getCurrentColorScheme()))
    
    view.addSubview(collectionView)
    
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
    ])
  }
  
  private func registerCells() {
    collectionView.register(ProfileBannerCell.self, forCellWithReuseIdentifier: "ProfileBannerCell")
    collectionView.register(ProfileInfoCell.self, forCellWithReuseIdentifier: "ProfileInfoCell")
    collectionView.register(FollowedByCell.self, forCellWithReuseIdentifier: "FollowedByCell")
    collectionView.register(TabSelectorCell.self, forCellWithReuseIdentifier: "TabSelectorCell")
    collectionView.register(PostCell.self, forCellWithReuseIdentifier: "PostCell")
    collectionView.register(LoadingCell.self, forCellWithReuseIdentifier: "LoadingCell")
    collectionView.register(EmptyStateCell.self, forCellWithReuseIdentifier: "EmptyStateCell")
    collectionView.register(MoreViewCell.self, forCellWithReuseIdentifier: "MoreViewCell")
  }
  
  // MARK: - Height Calculator
  private lazy var heightCalculator = PostHeightCalculator()
  
  // MARK: - Layout
  private func createCompositionalLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
      guard let self = self,
            let section = Section(rawValue: sectionIndex) else { 
        // Return a default section if we can't create the proper one
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
      }
      
      let screenWidth = environment.container.contentSize.width
      let responsivePadding = max(16, (screenWidth - 600) / 2)
      
      switch section {
      case .banner:
        // Simple banner section
        let bannerHeight: CGFloat = 150
        
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(bannerHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .absolute(bannerHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        return section
        
      case .profileInfo:
        // Profile info with responsive padding
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(200)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(200)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0,
          leading: responsivePadding,
          bottom: 8,
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
          bottom: 8,
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
          bottom: 0,
          trailing: responsivePadding
        )
        return section
        
      case .content:
        // Content section (posts, etc.) - use calculated heights for better performance
        var estimatedHeight: CGFloat = 200 // default fallback
        
        // Calculate more accurate height based on current content
        switch self.viewModel.selectedProfileTab {
        case .posts:
          if let firstPost = self.viewModel.posts.first {
              estimatedHeight = self.heightCalculator.calculateHeight(for: firstPost.post, mode: .compact)
          }
        case .replies:
          if let firstReply = self.viewModel.replies.first {
              estimatedHeight = self.heightCalculator.calculateHeight(for: firstReply.post, mode: .compact)
          }
        case .media:
          if let firstMediaPost = self.viewModel.postsWithMedia.first {
              estimatedHeight = self.heightCalculator.calculateHeight(for: firstMediaPost.post, mode: .compact)
          }
        default:
          estimatedHeight = 200
        }
        
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
        
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8 // Add spacing between posts like other views
        return section
      }
    }
  }
  
  // MARK: - Data Source
  private func createDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
    UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
      guard let self = self else { 
        // Return a basic cell as fallback
        return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
      }
      
      switch item {
      case .banner:
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ProfileBannerCell", for: indexPath) as! ProfileBannerCell
        cell.configure(bannerURL: self.viewModel.profile?.banner?.uriString(), appState: self.appState)
        return cell
        
      case .profileInfo(let profile):
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ProfileInfoCell", for: indexPath) as! ProfileInfoCell
        cell.configure(
          profile: profile,
          viewModel: self.viewModel,
          appState: self.appState,
          isEditingProfile: self.isEditingProfile,
          path: self.navigationPath
        )
        return cell
        
      case .followedBy(let knownFollowers):
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FollowedByCell", for: indexPath) as! FollowedByCell
        cell.configure(
          knownFollowers: knownFollowers,
          totalFollowersCount: self.viewModel.profile?.followersCount ?? 0,
          profileDID: self.viewModel.profile?.did.didString() ?? "",
          path: self.navigationPath
        )
        return cell
        
      case .tabSelector(let selectedTab):
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "TabSelectorCell", for: indexPath) as! TabSelectorCell
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
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PostCell", for: indexPath) as! PostCell
        cell.configure(
          post: feedPost,
          appState: self.appState,
          path: self.navigationPath
        )
        return cell
        
      case .loadingIndicator:
        return collectionView.dequeueReusableCell(withReuseIdentifier: "LoadingCell", for: indexPath)
        
      case .emptyState(let title, let message):
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmptyStateCell", for: indexPath) as! EmptyStateCell
        cell.configure(title: title, message: message, appState: self.appState)
        return cell
        
      case .moreView:
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "MoreViewCell", for: indexPath) as! MoreViewCell
        cell.configure(
          viewModel: self.viewModel,
          appState: self.appState,
          path: self.navigationPath
        )
        return cell
      }
    }
  }
  
  // MARK: - Data Loading
  private func loadInitialData() {
    Task {
      // Load profile first
      await viewModel.loadProfile()
      
      // Load known followers for other users
      if !viewModel.isCurrentUser {
        await viewModel.loadKnownFollowers()
      }
      
      // Load initial tab content (usually posts)
      await loadContentForCurrentTab()
      
      // Pre-calculate heights for better scroll performance
      await MainActor.run {
        preCalculateContentHeights()
      }
    }
  }
  
  @MainActor
  private func preCalculateContentHeights() {
    // Pre-calculate heights for all current content to improve scroll performance
    switch viewModel.selectedProfileTab {
    case .posts:
      for post in viewModel.posts {
          _ = heightCalculator.calculateHeight(for: post.post, mode: .compact)
      }
    case .replies:
      for reply in viewModel.replies {
          _ = heightCalculator.calculateHeight(for: reply.post, mode: .compact)
      }
    case .media:
      for mediaPost in viewModel.postsWithMedia {
          _ = heightCalculator.calculateHeight(for: mediaPost.post, mode: .compact)
      }
    case .likes:
      for like in viewModel.likes {
          _ = heightCalculator.calculateHeight(for: like.post, mode: .compact)
      }
    default:
      break
    }
  }
  
  @objc private func handleRefresh() {
    Task {
      await viewModel.loadProfile()
      
      if !viewModel.isCurrentUser {
        await viewModel.loadKnownFollowers()
      }
      
      await loadContentForCurrentTab()
      
      await MainActor.run {
        updateSnapshot()
        refreshControl.endRefreshing()
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
  @MainActor
  private func updateSnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    
    // Add sections
    snapshot.appendSections(Section.allCases)
    
    // Banner
    snapshot.appendItems([.banner], toSection: .banner)
    
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
  }
  
  // MARK: - Theme Configuration
  private func configureNavigationAndToolbarTheme() {
    let currentScheme = getCurrentColorScheme()
    let isDarkMode = appState.themeManager.isDarkMode(for: currentScheme)
    let isBlackMode = appState.themeManager.isUsingTrueBlack
    
    // Configure tab bar
    guard let tabBarController = self.tabBarController else { return }
    
    let tabBarAppearance = UITabBarAppearance()
    
    if isDarkMode && isBlackMode {
      tabBarAppearance.configureWithOpaqueBackground()
      tabBarAppearance.backgroundColor = UIColor.black
      tabBarAppearance.shadowColor = .clear
      tabBarController.tabBar.tintColor = UIColor.systemBlue
    } else if isDarkMode {
      tabBarAppearance.configureWithOpaqueBackground()
      tabBarAppearance.backgroundColor = UIColor(appState.themeManager.dimBackgroundColor)
      tabBarAppearance.shadowColor = .clear
      tabBarController.tabBar.tintColor = nil
    } else {
      tabBarAppearance.configureWithDefaultBackground()
      tabBarAppearance.backgroundColor = UIColor.systemBackground
      tabBarController.tabBar.tintColor = UIColor.systemBlue
    }
    
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
    
    // Load more when reaching the last 3 items
    if indexPath.item >= items.count - 3 && !viewModel.isLoadingMorePosts {
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
final class ProfileBannerCell: UICollectionViewCell {
  private var bannerImageView: UIImageView!
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupViews() {
    bannerImageView = UIImageView()
    bannerImageView.contentMode = .scaleAspectFill
    bannerImageView.clipsToBounds = true
    bannerImageView.backgroundColor = UIColor.systemGray5
    bannerImageView.translatesAutoresizingMaskIntoConstraints = false
    
    contentView.addSubview(bannerImageView)
    
    NSLayoutConstraint.activate([
      bannerImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      bannerImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      bannerImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      bannerImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    ])
  }
  
  func configure(bannerURL: String?, appState: AppState) {
    if let bannerURL = bannerURL,
       let url = URL(string: bannerURL) {
      // Use Nuke to load the image
      let request = ImageRequest(url: url)
      
      // Clear any existing image
      bannerImageView.image = nil
      bannerImageView.backgroundColor = UIColor(Color.accentColor.opacity(0.3))
      
      ImagePipeline.shared.loadImage(with: request) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success(let response):
            self?.bannerImageView.image = response.image
            self?.bannerImageView.backgroundColor = .clear
          case .failure(_):
            // Keep the default background color on failure
            break
          }
        }
      }
    } else {
      // Default background
      bannerImageView.image = nil
      bannerImageView.backgroundColor = UIColor(Color.accentColor.opacity(0.3))
    }
  }
}

@available(iOS 18.0, *)
final class ProfileInfoCell: UICollectionViewCell {
  func configure(
    profile: AppBskyActorDefs.ProfileViewDetailed,
    viewModel: ProfileViewModel,
    appState: AppState,
    isEditingProfile: Binding<Bool>,
    path: Binding<NavigationPath>
  ) {
    let screenWidth = contentView.bounds.width > 0 ? contentView.bounds.width : UIScreen.main.bounds.width
    
    contentConfiguration = UIHostingConfiguration {
      ProfileHeader(
        profile: profile,
        viewModel: viewModel,
        appState: appState,
        isEditingProfile: isEditingProfile,
        path: path,
        screenWidth: screenWidth
      )
    }
    .margins(.all, 0)
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
  func configure(
    post: AppBskyFeedDefs.FeedViewPost,
    appState: AppState,
    path: Binding<NavigationPath>
  ) {
    contentConfiguration = UIHostingConfiguration {
      VStack(spacing: 0) {
        EnhancedFeedPost(
          cachedPost: CachedFeedViewPost(feedViewPost: post),
          path: path
        )
        
        // Add divider like other views
        Divider()
          .padding(.top, 8)
      }
    }
    .margins(.all, 0)
  }
}

@available(iOS 18.0, *)
final class LoadingCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    
    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.startAnimating()
    
    contentView.addSubview(activityIndicator)
    
    NSLayoutConstraint.activate([
      activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
    ])
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@available(iOS 18.0, *)
final class EmptyStateCell: UICollectionViewCell {
  func configure(title: String, message: String, appState: AppState) {
    contentConfiguration = UIHostingConfiguration {
      VStack(spacing: 16) {
        Spacer()
        
        Image(systemName: "square.stack.3d.up.slash")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        
        Text(title)
          .font(.title3)
          .fontWeight(.semibold)
        
        Text(message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
        
        Spacer()
      }
      .frame(minHeight: 300)
      .frame(maxWidth: .infinity)
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
