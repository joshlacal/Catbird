import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI
import TipKit
import UIKit
import UniformTypeIdentifiers

// MARK: - FeedsStartPage
struct FeedsStartPage: View {
  // Environment and State properties
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.colorScheme) private var colorScheme
  @State private var editMode: EditMode = .inactive
  @Binding var isDrawerOpen: Bool
  @State private var viewModel: FeedsStartPageViewModel
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String

  // State invalidation subscription
  @State private var stateInvalidationSubscriber: FeedsStartPageStateSubscriber?

  // UI State
  @State private var searchText = ""
  @State private var isSearchBarVisible = false
  @State private var isLoaded = false
  @State private var isInitialized = false
  @State private var showAddFeedSheet = false
  @State private var newFeedURI = ""
  @State private var pinNewFeed = false
  @State private var showProtectedSystemFeedAlert = false
  @State private var lastProtectedFeedAction: String = ""
  @State private var showErrorAlert = false
  @State private var errorAlertMessage = ""

  // Drag and drop state
  @State private var draggedFeedItem: String?
  @State private var isDragging: Bool = false
  @State private var draggedItemCategory: String?
  @State private var dropTargetItem: String?
  @State private var isDefaultFeedDropTarget = false

  // Profile state
  @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
  @State private var isLoadingProfile = false
  @State private var isShowingAccountSwitcher = false

  // Feeds state
  @State private var filteredPinnedFeeds: [String] = []
  @State private var filteredSavedFeeds: [String] = []
  @State private var defaultFeed: String?
  @State private var defaultFeedName: String = "Timeline"

  // Logging
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedsStartPage")

  // MARK: - Layout Calculations
  private var safeAreaTop: CGFloat {
    let window = UIApplication.shared.connectedScenes
      .filter { $0.activationState == .foregroundActive }
      .first(where: { $0 is UIWindowScene })
      .flatMap { $0 as? UIWindowScene }?.windows
      .first(where: { $0.isKeyWindow })

    return window?.safeAreaInsets.top ?? 44
  }
  
  private var navigationBarHeight: CGFloat {
    // Standard navigation bar height + safe area top
    return 44 + safeAreaTop
  }
  
  // Responsive banner height based on screen size
  private var bannerHeight: CGFloat {
    switch screenWidth {
    case ..<375: return 140  // Smaller iPhones
    case ..<768: return 160  // Standard iPhones
    default: return 200     // iPads and larger devices
    }
  }
  
  // Responsive avatar size
  private var avatarSize: CGFloat {
    switch screenWidth {
    case ..<375: return 48   // Smaller for compact screens
    case ..<768: return 54   // Standard size
    default: return 64      // Larger for iPads
    }
  }

  // Sizing properties
  private let screenWidth = UIScreen.main.bounds.width
  private let isIPad = UIDevice.current.userInterfaceIdiom == .pad
  private var drawerWidth: CGFloat {
    isIPad ? min(400, screenWidth * 0.4) : screenWidth * 0.75
  }
  private var gridSpacing: CGFloat {
    switch screenWidth {
    case ..<375: return 8
    case ..<768: return 10
    default: return 12
    }
  }
  private var horizontalPadding: CGFloat {
    switch screenWidth {
    case ..<375: return 12
    case ..<768: return 16
    default: return 20
    }
  }
  private var columns: Int {
    switch screenWidth {
    case ..<320: return 2  // Small iPhone
    case ..<375: return 3  // iPhone SE/Mini
    default: return 3  // Standard iPhone, iPad - keep at 3 for larger icons
    }
  }
  private var itemWidth: CGFloat {
    let availableWidth =
      drawerWidth - (horizontalPadding * 2) - (gridSpacing * CGFloat(columns - 1))
    return availableWidth / CGFloat(columns)
  }
  private var iconSize: CGFloat {
    switch screenWidth {
    case ..<320: return 55
    case ..<375: return 60
    case ..<768: return 70  // Larger icons for better visibility
    default: return 85  // Much larger icons on iPad for better touch targets
    }
  }

  private let impact = UIImpactFeedbackGenerator(style: .rigid)

  // MARK: - Initialization
  init(
    appState: AppState,
    selectedFeed: Binding<FetchType>,
    currentFeedName: Binding<String>,
    isDrawerOpen: Binding<Bool>
  ) {
    self._selectedFeed = selectedFeed
    self._viewModel = State(wrappedValue: FeedsStartPageViewModel(appState: appState))
    self._currentFeedName = currentFeedName
    self._isDrawerOpen = isDrawerOpen
  }

  // MARK: - Helper Methods
  private func isSelected(feedURI: String) -> Bool {
    if SystemFeedTypes.isTimelineFeed(feedURI) {
      return selectedFeed == .timeline
    } else if let uri = try? ATProtocolURI(uriString: feedURI) {
      return selectedFeed == .feed(uri)
    }
    return false
  }

  private func isDefaultFeedSelected() -> Bool {
    guard let defaultFeed = defaultFeed else { return selectedFeed == .timeline }
    return isSelected(feedURI: defaultFeed)
  }

  private func loadUserProfile() async {
    guard let client = appState.atProtoClient else { return }

    isLoadingProfile = true

    do {
      // Get the DID first
      let did: String
      if let currentUserDID = appState.currentUserDID {
        did = currentUserDID
      } else {
        did = try await client.getDid()
      }

      // Fetch the profile
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: ATIdentifier(string: did))
      )

      if responseCode == 200, let profileData = profileData {
        profile = profileData
      }
    } catch {
      logger.error("Failed to load user profile: \(error)")
    }

    isLoadingProfile = false
  }

  private func updateFilteredFeeds() async {
    // Update the caches first - this will ensure proper timeline position
    await viewModel.updateCaches()

    // Then use the sync properties
    let pinnedFeeds = viewModel.cachedPinnedFeeds
    let savedFeeds = viewModel.cachedSavedFeeds

    // Set the default feed (for big button) to the first pinned feed
    defaultFeed = pinnedFeeds.first

    // Get the name of the default feed
    if let feed = defaultFeed,
      let uri = try? ATProtocolURI(uriString: feed)
    {
      defaultFeedName =
        viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
    } else if defaultFeed != nil && SystemFeedTypes.isTimelineFeed(defaultFeed!) {
      defaultFeedName = "Timeline"
    } else {
      defaultFeedName = "Timeline"
    }

    // Filter pinned feeds - IMPORTANT: Include all feeds in the grid
    filteredPinnedFeeds = pinnedFeeds.compactMap { feed in
      // Apply search filter if needed
      if !searchText.isEmpty
        && !viewModel.filteredFeeds([feed], searchText: searchText).contains(feed)
      {
        return nil
      }

      return feed
    }

    // Filter saved feeds, excluding any that are already in pinned
    let filteredSaved = viewModel.filteredFeeds(savedFeeds, searchText: searchText)
    filteredSavedFeeds = filteredSaved.filter { feed in
      !pinnedFeeds.contains(feed)
    }
  }

  private func resetDragState() {
    withAnimation(.spring(duration: 0.3)) {
      dropTargetItem = nil
      draggedFeedItem = nil
      isDragging = false
      draggedItemCategory = nil
      isDefaultFeedDropTarget = false
    }
  }

  // MARK: - UI Components
  @ViewBuilder
  private func sectionHeader(_ title: String) -> some View {
    HStack {
        if title == "Pinned" {
          Image(systemName: "pin.fill")
                .font(
                  Font.customSystemFont(
                    size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
                    relativeTo: .title3)
                )
                .foregroundColor(.primary)
        } else if title == "Saved" {
          Image(systemName: "bookmark.fill")
                .font(
                  Font.customSystemFont(
                    size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
                    relativeTo: .title3)
                )
                .foregroundColor(.primary)
        }

      Text(title)
        .font(
          Font.customSystemFont(
            size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
            relativeTo: .title3)
        )
        .foregroundColor(.primary)

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private func searchBar() -> some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .appFont(size: 16)

      TextField("Search your feeds...", text: $searchText)
        .appFont(size: 16)
        .foregroundColor(.primary)
        .onChange(of: searchText) { _, _ in
          Task { await updateFilteredFeeds() }
        }

      if !searchText.isEmpty {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            searchText = ""
            Task { await updateFilteredFeeds() }
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
            .appFont(size: 16)
        }
        .transition(.scale.combined(with: .opacity))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(.ultraThinMaterial)
    )
    .accessibilityAddTraits(.isSearchField)
  }

  @ViewBuilder
  private func addFeedButton() -> some View {
    Button {
      showAddFeedSheet = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "plus.circle.fill")
        Text("Add New Feed")
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(.ultraThinMaterial)
      )
    }
    .interactiveGlass()
    .padding(.vertical, 8)
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var bigDefaultFeedButton: some View {
    Button {
      guard !editMode.isEditing else { return }

      impact.impactOccurred()

      if let feedURI = defaultFeed, SystemFeedTypes.isTimelineFeed(feedURI) {
        selectedFeed = .timeline
        currentFeedName = "Timeline"
      } else if let feedURI = defaultFeed, let uri = try? ATProtocolURI(uriString: feedURI) {
        selectedFeed = .feed(uri)
        currentFeedName = defaultFeedName
      } else {
        selectedFeed = .timeline
        currentFeedName = "Timeline"
      }

      isDrawerOpen = false
    } label: {
      HStack(spacing: 21) {
        ZStack {
          HStack {
            defaultFeedIcon(iconSize: iconSize)

            // Feed name
            Text(defaultFeedName)
              .padding(.leading, 6)
              .appFont(AppTextRole.headline)
              .foregroundStyle(.primary)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Spacer()

            Image(systemName: "chevron.right")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(12)
        .background {
          let isSelected = isDefaultFeedSelected()
          let gradientColors =
            isSelected
            ? [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.08)]
            : [Color.accentColor.opacity(0.05), Color.clear]
          let strokeColor =
            isSelected
            ? Color.accentColor.opacity(0.6)
            : Color(UIColor.separator).opacity(0.5)
          let strokeWidth: CGFloat = isSelected ? 1.5 : 0.5

          RoundedRectangle(cornerRadius: 14)
            .fill(.ultraThinMaterial)
            .overlay(
              LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              .clipShape(RoundedRectangle(cornerRadius: 14))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14)
                .stroke(strokeColor, lineWidth: strokeWidth)
            )
        }
      }
    }
    .buttonStyle(PlainButtonStyle())
    .padding(.vertical, 8)
    .onDrop(
      of: [UTType.plainText.identifier],
      delegate: DefaultFeedDropDelegate(
        viewModel: viewModel,
        draggedItem: $draggedFeedItem,
        isDragging: $isDragging,
        draggedItemCategory: $draggedItemCategory,
        dropTargetItem: $dropTargetItem,
        selectedFeed: $selectedFeed,
        currentFeedName: $currentFeedName,
        isDefaultFeedDropTarget: $isDefaultFeedDropTarget,
        defaultFeed: $defaultFeed,
        defaultFeedName: $defaultFeedName,
        resetDragState: resetDragState
      )
    )
    .accessibility(label: Text("Open \(defaultFeedName) feed"))
    .accessibility(hint: Text("Double tap to open this feed and close the menu"))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func defaultFeedIcon(iconSize: CGFloat) -> some View {
    Group {
      if let feedURI = defaultFeed,
        !SystemFeedTypes.isTimelineFeed(feedURI),
        let uri = try? ATProtocolURI(uriString: feedURI),
        let generator = viewModel.feedGenerators[uri]
      {
        // Custom feed avatar
        LazyImage(url: URL(string: generator.avatar?.uriString() ?? "")) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: iconSize, height: iconSize)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          } else {
            feedPlaceholder(for: defaultFeedName)
              .frame(width: iconSize, height: iconSize)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
      } else {
        // Default system "Timeline" icon
        ZStack {
          LinearGradient(
            gradient: Gradient(colors: [
              Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.6),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Image(systemName: "clock")
            .appFont(size: 24)
            .foregroundColor(.white)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
    .frame(width: iconSize, height: iconSize)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private func gridSection(for feeds: [String], category: String) -> some View {

    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
      spacing: gridSpacing
    ) {
      // Show all feeds except the first one which is the default
      ForEach(feeds.dropFirst(), id: \.self) { feed in
        if SystemFeedTypes.isTimelineFeed(feed) {
          // Special handling for Timeline feed
          timelineFeedLink(feedURI: feed, category: category)
        } else if let uri = try? ATProtocolURI(uriString: feed) {
          feedLink(for: uri, feedURI: feed, category: category)
        }
      }
    }
    .animation(.spring(duration: 0.4), value: feeds)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(category.capitalized) feeds grid")
  }

  @ViewBuilder
  private func feedLink(for uri: ATProtocolURI, feedURI: String, category: String) -> some View {
    Button {
      guard !editMode.isEditing else { return }

      impact.impactOccurred()

      selectedFeed = .feed(uri)
      currentFeedName =
        viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
      isDrawerOpen = false
    } label: {
      VStack(spacing: 6) {
        // Feed icon
        Group {
          if let generator = viewModel.feedGenerators[uri] {
            LazyImage(url: URL(string: generator.avatar?.uriString() ?? "")) { state in
              if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
              } else {
                feedPlaceholder(for: generator.displayName)
              }
            }
          } else {
            feedPlaceholder(for: viewModel.extractTitle(from: uri))
          }
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        // Feed name
          Text(viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri))
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.primary)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: itemWidth)
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(
            dropTargetItem == feedURI
              ? Color.accentColor.opacity(0.1)
            : (isSelected(feedURI: feedURI) ? Color.accentColor.opacity(0.08) : Color.clear)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                isSelected(feedURI: feedURI)
                  ? Color.accentColor.opacity(0.5)
                  : Color.clear,
                lineWidth: 1.0
              )
          )
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))

    }
    .buttonStyle(PlainButtonStyle())

    .overlay(
      Group {
        if editMode.isEditing {
          VStack {
            HStack {
              Spacer()
              Button {
                Task { await viewModel.removeFeed(feedURI) }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .appFont(size: 20)
                  .foregroundColor(.red)
                  .background(Circle().fill(Color.white))
              }
              .offset(x: -5, y: 5)
            }
            Spacer()
          }
        }
      }
    )
    .onDrag {
      draggedFeedItem = feedURI
      isDragging = true
      draggedItemCategory = category
      return NSItemProvider(object: feedURI as NSString)
    }
    .onDrop(
      of: [UTType.plainText.identifier],
      delegate: FeedDropDelegate(
        item: feedURI,
        items: category == "pinned" ? viewModel.cachedPinnedFeeds : viewModel.cachedSavedFeeds,
        category: category,
        viewModel: viewModel,
        draggedItem: $draggedFeedItem,
        isDragging: $isDragging,
        draggedItemCategory: $draggedItemCategory,
        dropTargetItem: $dropTargetItem,
        resetDragState: resetDragState,
        appSettings: appState.appSettings
      )
    )
    .accessibility(
      label: Text(viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri))
    )
    .accessibility(hint: Text("Double tap to open this feed"))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func timelineFeedLink(feedURI: String, category: String) -> some View {
    Button {
      guard !editMode.isEditing else { return }

      impact.impactOccurred()

      selectedFeed = .timeline
      currentFeedName = "Timeline"
      isDrawerOpen = false
    } label: {
      VStack(spacing: 6) {
        // Timeline icon
        ZStack {
          LinearGradient(
            gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.6)]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Image(systemName: "clock")
            .appFont(size: 24)
            .foregroundColor(.white)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        // Feed name
        Text("Timeline")
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.primary)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: itemWidth)
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(
            dropTargetItem == feedURI
              ? Color.accentColor.opacity(0.15)
              : (isSelected(feedURI: feedURI) ? Color.accentColor.opacity(0.08) : Color.clear)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                isSelected(feedURI: feedURI)
                  ? Color.accentColor.opacity(0.5)
                  : Color.clear,
                lineWidth: 1.0
              )
          )
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(PlainButtonStyle())
    .interactiveGlass()
    .onDrag {
      draggedFeedItem = feedURI
      isDragging = true
      draggedItemCategory = category
      return NSItemProvider(object: feedURI as NSString)
    }
    .onDrop(
      of: [UTType.plainText.identifier],
      delegate: FeedDropDelegate(
        item: feedURI,
        items: category == "pinned" ? viewModel.cachedPinnedFeeds : viewModel.cachedSavedFeeds,
        category: category,
        viewModel: viewModel,
        draggedItem: $draggedFeedItem,
        isDragging: $isDragging,
        draggedItemCategory: $draggedItemCategory,
        dropTargetItem: $dropTargetItem,
        resetDragState: resetDragState,
        appSettings: appState.appSettings
      )
    )
    .opacity(draggedFeedItem == feedURI && isDragging ? 0.4 : 1.0)
    .scaleEffect(draggedFeedItem == feedURI && isDragging ? 0.95 : 1.0)
    .accessibility(label: Text("Timeline"))
    .accessibility(hint: Text("Double tap to open the Timeline feed"))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func feedPlaceholder(for title: String) -> some View {
    ZStack {
      // iOS-like gradient background
      LinearGradient(
        gradient: Gradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.5)]
        ),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      // First letter of feed name
      Text(title.prefix(1).uppercased())
        .appFont(AppTextRole.from(.headline))
        .foregroundColor(.white)
    }
  }

  // MARK: - Body
  var body: some View {
    NavigationStack {
      mainContent
    }
    .applyFeedsPageModifiers(
      viewModel: viewModel,
      appState: appState,
      editMode: $editMode,
      isDrawerOpen: $isDrawerOpen,
      showAddFeedSheet: $showAddFeedSheet,
      isShowingAccountSwitcher: $isShowingAccountSwitcher,
      showProtectedSystemFeedAlert: $showProtectedSystemFeedAlert,
      lastProtectedFeedAction: lastProtectedFeedAction,
      showErrorAlert: $showErrorAlert,
      errorAlertMessage: $errorAlertMessage,
      onAppear: handleOnAppear,
      onDisappear: handleOnDisappear
    )
  }
  
  @ViewBuilder
  private var mainContent: some View {
    ScrollView {
      VStack(spacing: 0) {
        // Stretchy banner header
        GeometryReader { geometry in
          bannerHeaderView()
            .frame(width: drawerWidth)
            .frame(height: max(bannerHeight, bannerHeight + geometry.frame(in: .global).minY))
            .offset(y: geometry.frame(in: .global).minY > 0 ? -geometry.frame(in: .global).minY : 0)
            .clipped()
        }
        .frame(width: drawerWidth, height: bannerHeight)
        
        // Main content below the banner
        feedsContent()
      }
    }
    .frame(width: drawerWidth)
    .ignoresSafeArea(edges: .top)
    .refreshable {
      await handleRefresh()
    }
    .overlay(alignment: .topTrailing) {
      // Overlays
      loadingOverlay()
      initializationOverlay()
    }
  }
  
  private func handleRefresh() async {
    await viewModel.fetchFeedGenerators()
    await updateFilteredFeeds()
    if appState.isAuthenticated {
      await loadUserProfile()
    }
  }
  
  private func handleOnAppear() {
    Task {
      await viewModel.initializeWithModelContext(modelContext)
      await updateFilteredFeeds()
      isInitialized = true
      
      withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
        isLoaded = true
      }
      
      if appState.isAuthenticated {
        await loadUserProfile()
      }
      
      if stateInvalidationSubscriber == nil {
        stateInvalidationSubscriber = FeedsStartPageStateSubscriber(
          viewModel: viewModel,
          updateFilteredFeeds: updateFilteredFeeds
        )
        appState.stateInvalidationBus.subscribe(stateInvalidationSubscriber!)
      }
    }
  }
  
  private func handleOnDisappear() {
    if let subscriber = stateInvalidationSubscriber {
      appState.stateInvalidationBus.unsubscribe(subscriber)
      stateInvalidationSubscriber = nil
    }
  }

  @ViewBuilder
  private func bannerHeaderView() -> some View {
    ZStack(alignment: .bottomLeading) {
      // Banner Image
      Group {
        if let bannerURL = profile?.banner?.url {
          LazyImage(url: bannerURL) { state in
            if let image = state.image {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: drawerWidth)
            } else {
              // Fallback gradient banner
              LinearGradient(
                gradient: Gradient(colors: [
                  Color.accentColor.opacity(0.3),
                  Color.accentColor.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              .frame(width: drawerWidth)
            }
          }
        } else {
          // Default gradient banner
          LinearGradient(
            gradient: Gradient(colors: [
              Color.accentColor.opacity(0.3),
              Color.accentColor.opacity(0.1)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          .frame(width: drawerWidth)
        }
      }
      .frame(width: drawerWidth)
      .clipped()
      
      // Scrim overlay for text visibility
      LinearGradient(
        colors: [.black.opacity(0.6), .black.opacity(0.0)],
        startPoint: .bottom,
        endPoint: .center
      )
      .frame(width: drawerWidth)
      
      // Profile Info
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          // Avatar
          Group {
            if let avatarURL = profile?.avatar?.url {
              AsyncProfileImage(url: avatarURL, size: avatarSize)
            } else {
              // Fallback avatar
              ZStack {
                Circle()
                  .fill(Color.white.opacity(0.9))
                  .frame(width: avatarSize, height: avatarSize)
                
                Text(profile?.handle.description.prefix(1).uppercased() ?? "?")
                  .appFont(size: avatarSize * 0.4) // Scale text with avatar
                  .foregroundColor(.accentColor)
              }
            }
          }
          .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 2))
          
          // Display Name and Handle
          VStack(alignment: .leading, spacing: 2) {
            if let displayName = profile?.displayName, !displayName.isEmpty {
              Text(displayName)
                .font(.system(size: screenWidth < 375 ? 14 : 16, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            if let handle = profile?.handle {
              Text("@\(handle.description)")
                .font(.system(size: screenWidth < 375 ? 12 : 14))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 2)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          
          Spacer(minLength: 0)
        }
        .frame(maxWidth: drawerWidth - (horizontalPadding * 2))
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.bottom, 12)
    }
    .frame(width: drawerWidth)
    .contentShape(Rectangle())
    .onTapGesture {
      if let userDID = appState.authManager.state.userDID {
        appState.navigationManager.navigate(to: .profile(userDID))
        isDrawerOpen = false
      }
    }
    .onLongPressGesture {
      impact.impactOccurred()
      isShowingAccountSwitcher = true
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("My Profile")
    .accessibilityHint("Double tap to view your profile. Long press to switch accounts.")
  }

  @ViewBuilder
  private func feedsContent() -> some View {
      VStack(spacing: 0) {
          HStack {
              Text("Feeds")
                  .font(
                      Font.customSystemFont(
                          size: 24, weight: .bold, width: 120, opticalSize: true, design: .default,
                          relativeTo: .title)
                  )
                  .frame(maxWidth: .infinity, alignment: .leading)
              Spacer()

              HStack(spacing: 12) {
                  // Search feeds button
                  Button {
                      withAnimation(.easeInOut(duration: 0.3)) {
                          isSearchBarVisible.toggle()
                      }
                  } label: {
                      Image(systemName: isSearchBarVisible ? "xmark" : "magnifyingglass")
                          .appFont(size: 16)
                          .foregroundStyle(Color.accentColor)
                  }
                  .tint(.accentColor.opacity(0.8))
                  .accessibilityLabel(isSearchBarVisible ? "Hide Search" : "Search Feeds")
                  .accessibilityAddTraits(.isButton)

                  if editMode.isEditing {
                      Button {
                          editMode = .inactive
                      } label: {
                          Image(systemName: "checkmark")
                              .appFont(size: 16)
                      }
                      .tint(.accentColor.opacity(0.8))
                      .accessibilityLabel("Done Editing")
                      .accessibilityAddTraits(.isButton)
                  } else {
                      Button {
                          editMode = .active
                      } label: {
                          Image(systemName: "slider.horizontal.3")
                              .appFont(size: 16)
                      }
                      .tint(.accentColor.opacity(0.8))
                      .accessibility(label: Text("Edit Feeds"))
                      .accessibility(hint: Text("Double tap to enter edit mode"))
                      .accessibilityAddTraits(.isButton)
                  }
              }

          }
          .padding(.horizontal, horizontalPadding)
          .padding(.top, 24) // Add top padding to separate from banner
          .padding(.bottom, 24)

          // Search bar
          if isSearchBarVisible {
              searchBar()
                  .padding(.horizontal, horizontalPadding)
                  .padding(.bottom, gridSpacing)
                  .transition(
                      .asymmetric(
                          insertion: .opacity.combined(with: .move(edge: .top)),
                          removal: .opacity.combined(with: .move(edge: .top))
                      ))
          }

          VStack(spacing: gridSpacing) {
              // Add Feed button in edit mode
              if editMode.isEditing {
                  addFeedButton()
                      .padding(.horizontal, horizontalPadding)
              }

              // Big default feed button as first feed in hierarchy
              bigDefaultFeedButton
                  .padding(.horizontal, horizontalPadding)

              // Pinned feeds section - continue the hierarchy
              if !filteredPinnedFeeds.isEmpty {
                  sectionHeader("Pinned")
                      .padding(.horizontal, horizontalPadding)
                  gridSection(for: filteredPinnedFeeds, category: "pinned")
                      .padding(.horizontal, horizontalPadding)
              }

              // Saved feeds section
              if !filteredSavedFeeds.isEmpty {
                  sectionHeader("Saved")
                      .padding(.horizontal, horizontalPadding)
                  gridSection(for: filteredSavedFeeds, category: "saved")
                      .padding(.horizontal, horizontalPadding)
              }

              // Extra space at bottom
              Spacer(minLength: 200)
          }
      }
      .background(Color(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))) // Add background to content
  }

  // MARK: - Overlays
  @ViewBuilder
  private func loadingOverlay() -> some View {
    if viewModel.isLoading {
      VStack {
        Spacer()
        ProgressView("Loading feeds...")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(UIColor.systemBackground).opacity(0.9))
    }
  }

  @ViewBuilder
  private func initializationOverlay() -> some View {
    if !isInitialized {
      VStack {
        Spacer()
        ProgressView("Loading your feeds...")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(UIColor.systemBackground).opacity(0.9))
    }
  }
}

// Helper Extensions
extension Optional where Wrapped == String {
  var isNilOrEmpty: Bool {
    self == nil || self?.isEmpty == true
  }
}

// MARK: - State Invalidation Subscriber
@MainActor
final class FeedsStartPageStateSubscriber: StateInvalidationSubscriber {
  weak var viewModel: FeedsStartPageViewModel?
  var updateFilteredFeeds: (() async -> Void)?
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedsStartPageStateSubscriber")

  init(viewModel: FeedsStartPageViewModel, updateFilteredFeeds: @escaping () async -> Void) {
    self.viewModel = viewModel
    self.updateFilteredFeeds = updateFilteredFeeds
  }

  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    switch event {
    case .feedListChanged:
      logger.debug("Feed list changed event received - refreshing feeds")
      // Refresh the feed generators and update caches
      await viewModel?.fetchFeedGenerators()
      await viewModel?.updateCaches()
      // Update the filtered feeds to refresh the UI
      await updateFilteredFeeds?()
    default:
      break
    }
  }

nonisolated func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .feedListChanged:
      return true
    default:
      return false
    }
  }
}

// MARK: - Stretchy Header Extensions
// Removed - using inline GeometryReader approach instead for better reliability

// MARK: - View Modifier Extension
extension View {
    func applyFeedsPageModifiers(
        viewModel: FeedsStartPageViewModel,
        appState: AppState,
        editMode: Binding<EditMode>,
        isDrawerOpen: Binding<Bool>,
        showAddFeedSheet: Binding<Bool>,
        isShowingAccountSwitcher: Binding<Bool>,
        showProtectedSystemFeedAlert: Binding<Bool>,
        lastProtectedFeedAction: String,
        showErrorAlert: Binding<Bool>,
        errorAlertMessage: Binding<String>,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void
    ) -> some View {
        self
            .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isDrawerOpen.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.primary)
                    }
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .environment(\.editMode, editMode)
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onChange(of: viewModel.cachedPinnedFeeds) { _, _ in
                Task { await viewModel.updateCaches() }
            }
            .onChange(of: viewModel.cachedSavedFeeds) { _, _ in
                Task { await viewModel.updateCaches() }
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                await viewModel.fetchFeedGenerators()
            }
            .onChange(of: viewModel.feedGenerators) { _, _ in
                Task { await viewModel.updateCaches() }
            }
            .onChange(of: viewModel.errorMessage) { _, newError in
                if let errorMsg = newError {
                    errorAlertMessage.wrappedValue = errorMsg
                    showErrorAlert.wrappedValue = true
                }
            }
            .sheet(isPresented: showAddFeedSheet) {
                AddFeedSheet()
            }
            .sheet(isPresented: isShowingAccountSwitcher) {
                AccountSwitcherView()
            }
            .alert("System Feed Protected", isPresented: showProtectedSystemFeedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    "\(lastProtectedFeedAction) cannot be performed on system feeds like Timeline/Following as they are required for the app to function correctly."
                )
            }
            .alert("Error", isPresented: showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorAlertMessage.wrappedValue)
            }
    }
}
