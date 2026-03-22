import UIKit
import SwiftUI
import Petrel
import Nuke
import os

/// Main UIKit profile view controller.
///
/// Layer order (bottom → top):
///   1. view background (themed)
///   2. bannerView — pinned to top, behind scroll view
///   3. scrollView — full-screen, clear background
///   4. (inside scroll) contentStack: bannerSpacer / profileInfo / followedBy / tabBarPlaceholder / tabContent
///   5. tabBar (ProfileTabBar) — floats over scroll, becomes sticky at safeAreaTop
@available(iOS 18.0, *)
final class ProfileViewController: UIViewController, UIScrollViewDelegate {

  // MARK: - Dependencies
  private let appState: AppState
  private var viewModel: ProfileViewModel
  private var isEditingProfileBinding: Binding<Bool>
  private var navigationPathBinding: Binding<NavigationPath>

  // MARK: - Layout Constants
  private let bannerHeight: CGFloat = 160

  // MARK: - Observation tracking
  private var lastObservedProfileDID: String?

  // MARK: - UI Components
  private lazy var bannerView: ProfileBannerView = {
    let v = ProfileBannerView()
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private lazy var scrollView: UIScrollView = {
    let sv = UIScrollView()
    sv.translatesAutoresizingMaskIntoConstraints = false
    sv.backgroundColor = .clear
    sv.delegate = self
    sv.alwaysBounceVertical = true
    sv.contentInsetAdjustmentBehavior = .never
    sv.showsVerticalScrollIndicator = true
    sv.refreshControl = makeRefreshControl()
    return sv
  }()

  private lazy var contentStack: UIStackView = {
    let sv = UIStackView()
    sv.translatesAutoresizingMaskIntoConstraints = false
    sv.axis = .vertical
    sv.spacing = 0
    sv.alignment = .fill
    return sv
  }()

  private lazy var bannerSpacer: UIView = {
    let v = UIView()
    v.backgroundColor = .clear
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private lazy var tabBar: ProfileTabBar = {
    let tb = ProfileTabBar(isLabeler: viewModel.isLabeler)
    tb.translatesAutoresizingMaskIntoConstraints = false
    tb.selectedTab = viewModel.selectedProfileTab
    tb.onTabChange = { [weak self] tab in
      self?.handleTabSelection(tab)
    }
    return tb
  }()

  // UIHostingControllers for SwiftUI content
  private var profileInfoHostingController: UIHostingController<AnyView>?
  private var tabBarPlaceholder: UIView = {
    let v = UIView()
    v.backgroundColor = .clear
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()
  private var tabContentHostingController: UIHostingController<AnyView>?

  // MARK: - Constraint references (updated on layout)
  private var bannerHeightConstraint: NSLayoutConstraint?
  private var tabBarTopConstraint: NSLayoutConstraint?
  private var tabBarWidthConstraint: NSLayoutConstraint?

  // MARK: - Sticky Tracking
  private var profileInfoBottomY: CGFloat = 0  // Y position (in scroll coords) where tab bar naturally sits

  // MARK: - Observation
  private var observationTask: Task<Void, Never>?

  private let profileLogger = Logger(subsystem: "blue.catbird", category: "ProfileViewController")

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
    fatalError("ProfileViewController does not support coder init")
  }

  deinit {
    observationTask?.cancel()
  }

  // MARK: - Lifecycle
  override func viewDidLoad() {
    super.viewDidLoad()
    setupBackground()
    setupBannerView()
    setupScrollView()
    setupTabBar()
    setupObservation()
    rebuildContent()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateTabBarPosition(scrollOffset: scrollView.contentOffset.y)
  }

  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.updateLayoutForSize(size)
    })
  }

  // MARK: - Setup

  private func setupBackground() {
    let currentScheme = getCurrentColorScheme()
    view.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: currentScheme))
  }

  private func setupBannerView() {
    view.addSubview(bannerView)
    let bannerH = bannerView.heightAnchor.constraint(equalToConstant: bannerHeight)
    bannerH.identifier = "bannerHeight"
    bannerHeightConstraint = bannerH
    NSLayoutConstraint.activate([
      bannerView.topAnchor.constraint(equalTo: view.topAnchor),
      bannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bannerH
    ])
  }

  private func setupScrollView() {
    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])

    scrollView.addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor)
    ])

    // Banner spacer
    contentStack.addArrangedSubview(bannerSpacer)
    bannerSpacer.heightAnchor.constraint(equalToConstant: bannerHeight).isActive = true
  }

  private func setupTabBar() {
    view.addSubview(tabBar)
    let topC = tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    topC.identifier = "tabBarTop"
    tabBarTopConstraint = topC
    NSLayoutConstraint.activate([
      topC,
      tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabBar.heightAnchor.constraint(equalToConstant: ProfileTabBar.height)
    ])
  }

  // MARK: - Content Building

  private func rebuildContent() {
    guard let profile = viewModel.profile else {
      profileLogger.debug("rebuildContent: no profile yet")
      return
    }
    // Don't thrash layout mid-scroll — defer until deceleration ends
    if scrollView.isDragging || scrollView.isDecelerating {
      profileLogger.debug("rebuildContent: deferred (user is scrolling)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.rebuildContent()
      }
      return
    }

    // Remove existing hosted views (except bannerSpacer which is first)
    let viewsToRemove = contentStack.arrangedSubviews.filter { $0 !== bannerSpacer }
    viewsToRemove.forEach {
      contentStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    // Clean up old hosting controllers
    profileInfoHostingController?.willMove(toParent: nil)
    profileInfoHostingController?.view.removeFromSuperview()
    profileInfoHostingController?.removeFromParent()
    profileInfoHostingController = nil

    tabContentHostingController?.willMove(toParent: nil)
    tabContentHostingController?.view.removeFromSuperview()
    tabContentHostingController?.removeFromParent()
    tabContentHostingController = nil

    // Profile info (SwiftUI)
    let profileInfoView = AnyView(
      ProfileInfoView(
        profile: profile,
        viewModel: viewModel,
        appState: appState,
        isEditingProfile: isEditingProfileBinding,
        path: navigationPathBinding
      )
    )
    let profileInfoVC = UIHostingController(rootView: profileInfoView)
    profileInfoVC.view.backgroundColor = .clear
    profileInfoVC.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(profileInfoVC)
    contentStack.addArrangedSubview(profileInfoVC.view)
    profileInfoVC.didMove(toParent: self)
    profileInfoHostingController = profileInfoVC

    // FollowedBy (hidden for current user or no followers)
    if !viewModel.isCurrentUser && !viewModel.knownFollowers.isEmpty {
      addFollowedByView(profile: profile)
    }

    // Tab bar placeholder (reserves space where tab bar floats)
    tabBarPlaceholder.backgroundColor = .clear
    contentStack.addArrangedSubview(tabBarPlaceholder)
    tabBarPlaceholder.heightAnchor.constraint(equalToConstant: ProfileTabBar.height).isActive = true

    // Tab content
    addTabContent()

    // Update tab bar sections based on labeler status
    tabBar.updateSections(isLabeler: viewModel.isLabeler)
    tabBar.selectedTab = viewModel.selectedProfileTab

    // Configure banner image for current profile
    updateBannerForCurrentProfile()

    // Schedule profileInfoBottom calculation after layout
    DispatchQueue.main.async { [weak self] in
      self?.recalculateProfileInfoBottom()
    }
  }

  private func addFollowedByView(profile: AppBskyActorDefs.ProfileViewDetailed) {
    let followedByView = AnyView(
      FollowedByView(
        knownFollowers: viewModel.knownFollowers,
        totalFollowersCount: profile.followersCount ?? 0,
        profileDID: profile.did.didString(),
        path: navigationPathBinding
      )
      .environment(appState)
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
    )
    let vc = UIHostingController(rootView: followedByView)
    vc.view.backgroundColor = .clear
    vc.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(vc)
    contentStack.addArrangedSubview(vc.view)
    vc.didMove(toParent: self)
  }

  private func addTabContent() {
    let tabContentView = makeTabContentView()
    let vc = UIHostingController(rootView: tabContentView)
    // Do NOT use sizingOptions .intrinsicContentSize — it forces a full layout pass
    // over every item in the list just to compute height, killing scroll performance.
    // The UIStackView will use the view's systemLayoutSizeFitting instead.
    vc.view.backgroundColor = .clear
    vc.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(vc)
    contentStack.addArrangedSubview(vc.view)
    vc.didMove(toParent: self)
    tabContentHostingController = vc
  }

  private func makeTabContentView() -> AnyView {
    let tab = viewModel.selectedProfileTab
    let path = navigationPathBinding
    @Bindable var vm = viewModel
    switch tab {
    case .posts:
      return AnyView(PostsTabView(viewModel: viewModel, path: path))
    case .replies:
      return AnyView(GenericFeedTabView(
        posts: viewModel.replies,
        isLoading: viewModel.isLoading,
        isLoadingMore: viewModel.isLoadingMorePosts,
        emptyMessage: "No replies",
        loadMore: { [weak self] in await self?.viewModel.loadReplies() },
        path: path
      ))
    case .media:
      return AnyView(GenericFeedTabView(
        posts: viewModel.postsWithMedia,
        isLoading: viewModel.isLoading,
        isLoadingMore: viewModel.isLoadingMorePosts,
        emptyMessage: "No media posts",
        loadMore: { [weak self] in await self?.viewModel.loadMediaPosts() },
        path: path
      ))
    case .more:
      return AnyView(MoreView(path: path).padding(.horizontal, 16))
    default:
      return AnyView(EmptyView())
    }
  }

  // MARK: - Profile Info Bottom Calculation

  private func recalculateProfileInfoBottom() {
    guard let infoView = profileInfoHostingController?.view else { return }
    // Convert the bottom of the profile info view to scroll coordinate space
    let infoBottomInScroll = infoView.convert(
      CGPoint(x: 0, y: infoView.bounds.height),
      to: scrollView
    ).y
    profileInfoBottomY = infoBottomInScroll + scrollView.contentOffset.y
    profileLogger.debug("profileInfoBottomY = \(self.profileInfoBottomY)")
    updateTabBarPosition(scrollOffset: scrollView.contentOffset.y)
  }

  // MARK: - Sticky Tab Bar Logic

  private func updateTabBarPosition(scrollOffset: CGFloat) {
    let safeAreaTop = view.safeAreaInsets.top
    let naturalY = profileInfoBottomY - scrollOffset
    let clampedY = max(safeAreaTop, naturalY)
    // Frame-based only — bypasses the constraint engine entirely for 60fps scroll
    tabBar.frame.origin.y = clampedY
    let isSticky = clampedY <= safeAreaTop + 1
    tabBar.isAtTop = isSticky
  }

  // MARK: - Orientation

  private func updateLayoutForSize(_ size: CGSize) {
    view.setNeedsLayout()
    view.layoutIfNeeded()
    recalculateProfileInfoBottom()
  }

  // MARK: - Tab Handling

  private func handleTabSelection(_ tab: ProfileTab) {
    viewModel.selectedProfileTab = tab
    Task {
      await loadContentForTab(tab)
      await MainActor.run { [weak self] in
        self?.refreshTabContent()
      }
    }
  }

  private func refreshTabContent() {
    guard let vc = tabContentHostingController else { return }
    let newContent = makeTabContentView()
    vc.rootView = newContent
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
        self?.rebuildContent()
        UIView.animate(withDuration: 0.3) {
          self?.scrollView.refreshControl?.endRefreshing()
        }
      }
    }
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
      } onChange: {
        Task { @MainActor [weak self] in
          guard let self, !Task.isCancelled else { return }
          let newDID = self.viewModel.profile?.did.didString()
          if newDID != self.lastObservedProfileDID {
            // Profile switched — full structural rebuild
            self.lastObservedProfileDID = newDID
            self.rebuildContent()
            self.updateBannerForCurrentProfile()
          } else {
            // Only follower count changed — update tab sections, no layout thrash
            self.tabBar.updateSections(isLabeler: self.viewModel.isLabeler)
          }
        }
      }
      try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
    }
  }

  private func updateBannerForCurrentProfile() {
    guard let profile = viewModel.profile else { return }
    let bannerURL = profile.banner.flatMap { URL(string: $0.uriString()) }
    bannerView.configure(bannerURL: bannerURL, accentColor: .systemBlue)
  }

  // MARK: - UIScrollViewDelegate

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let offset = scrollView.contentOffset.y
    bannerView.update(scrollOffset: offset)
    updateTabBarPosition(scrollOffset: offset)
  }
}

// MARK: - Tab Content SwiftUI Views

/// Posts tab with pinned post support
@available(iOS 18.0, *)
private struct PostsTabView: View {
  let viewModel: ProfileViewModel
  @Binding var path: NavigationPath

  private var cachedPinnedPost: CachedFeedViewPost? {
    viewModel.pinnedPost.flatMap { CachedFeedViewPost(feedViewPost: $0) }
  }

  var body: some View {
    LazyVStack(spacing: 0) {
      if viewModel.isLoading && viewModel.posts.isEmpty {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      } else if viewModel.posts.isEmpty && viewModel.pinnedPost == nil {
        emptyView(message: "No posts yet")
      } else {
        if let pinned = cachedPinnedPost {
          VStack(spacing: 0) {
            EnhancedFeedPost(cachedPost: pinned, path: $path)
            Divider().padding(.top, 8)
          }
        }
        ForEach(viewModel.posts, id: \.post.uri) { feedPost in
          VStack(spacing: 0) {
            if let cached = CachedFeedViewPost(feedViewPost: feedPost) {
              EnhancedFeedPost(cachedPost: cached, path: $path)
            }
            Divider().padding(.top, 8)
          }
          .onAppear {
            if feedPost.post.uri == viewModel.posts.last?.post.uri, !viewModel.isLoadingMorePosts {
              Task { await viewModel.loadPosts() }
            }
          }
        }
        if viewModel.isLoadingMorePosts {
          ProgressView().padding().frame(maxWidth: .infinity)
        }
      }
    }
  }
}

@available(iOS 18.0, *)
private struct GenericFeedTabView: View {
  let posts: [AppBskyFeedDefs.FeedViewPost]
  let isLoading: Bool
  let isLoadingMore: Bool
  let emptyMessage: String
  let loadMore: @MainActor () async -> Void
  @Binding var path: NavigationPath

  var body: some View {
    LazyVStack(spacing: 0) {
      if isLoading && posts.isEmpty {
        ProgressView("Loading...")
          .frame(maxWidth: .infinity, minHeight: 100)
          .padding()
      } else if posts.isEmpty {
        emptyView(message: emptyMessage)
      } else {
        ForEach(posts, id: \.post.uri) { feedPost in
          VStack(spacing: 0) {
            if let cached = CachedFeedViewPost(feedViewPost: feedPost) {
              EnhancedFeedPost(cachedPost: cached, path: $path)
            }
            Divider().padding(.top, 8)
          }
          .onAppear {
            if feedPost.post.uri == posts.last?.post.uri, !isLoadingMore {
              Task { await loadMore() }
            }
          }
        }
        if isLoadingMore {
          ProgressView().padding().frame(maxWidth: .infinity)
        }
      }
    }
  }
}

private func emptyView(message: String) -> some View {
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
