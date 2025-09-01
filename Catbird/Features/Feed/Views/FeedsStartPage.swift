import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI
import TipKit
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

// MARK: - FeedsStartPage
struct FeedsStartPage: View {
  // Environment and State properties
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.colorScheme) private var colorScheme
  @State private var isEditingFeeds = false
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
#if os(iOS)
    let window = UIApplication.shared.connectedScenes
      .filter { $0.activationState == .foregroundActive }
      .first(where: { $0 is UIWindowScene })
      .flatMap { $0 as? UIWindowScene }?.windows
      .first(where: { $0.isKeyWindow })

    return window?.safeAreaInsets.top ?? 44
#elseif os(macOS)
    return 44  // Standard navigation bar height for macOS
#endif
  }
  
  private var navigationBarHeight: CGFloat {
    // Standard navigation bar height + safe area top
    return 44 + safeAreaTop
  }
  
  // Responsive banner height based on screen size and drawer width
  private var bannerHeight: CGFloat {
    // Scale banner height based on drawer width and available space
    let baseHeight: CGFloat = {
      switch screenWidth {
      case ..<375: return 130   // Compact iPhones
      case ..<768: return 150   // Standard iPhones
      case ..<1024: return 170  // iPhone Landscape / Small iPad
      case ..<1200: return 190  // Standard iPad
      case ..<1600: return 210  // Large iPad / Small Mac
      default: return 240       // Very large displays
      }
    }()
    
    // Ensure banner doesn't take up more than 25% of screen height
    return min(baseHeight, screenHeight * 0.25)
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
  private let screenWidth = PlatformScreenInfo.width
  private let screenHeight = PlatformScreenInfo.height
  private let isIPad = PlatformDeviceInfo.isIPad
  private var drawerWidth: CGFloat {
    PlatformScreenInfo.responsiveDrawerWidth
  }
  private var gridSpacing: CGFloat {
    switch screenWidth {
    case ..<375: return 4
    case ..<768: return 6
    case ..<1024: return 8
    case ..<1200: return 10
    case ..<1600: return 12
    default: return 14  // Very large displays
    }
  }
  private var horizontalPadding: CGFloat {
    switch screenWidth {
    case ..<375: return 12
    case ..<768: return 16
    case ..<1024: return 20
    case ..<1200: return 24
    case ..<1600: return 28
    default: return 32  // Very large displays
    }
  }
  private var columns: Int {
    switch drawerWidth {
    case ..<300: return 2  // Very small screens
    case ..<380: return 3  // Standard layout
    case ..<500: return 3  // Still prefer 3 columns for readability
    case ..<600: return 4  // Large iPad/Mac - can fit 4 nicely
    default: return 4      // Very large displays
    }
  }
  private var itemWidth: CGFloat {
    let availableWidth = drawerWidth - (horizontalPadding * 2) - (gridSpacing * CGFloat(columns - 1))
    let calculatedWidth = availableWidth / CGFloat(columns)
    
    // Ensure minimum and maximum item widths for usability
    return max(80, min(calculatedWidth, 140))
  }
  private var iconSize: CGFloat {
    // Base icon size on item width for better proportions - increased from 0.55 to 0.70
    let baseSize = itemWidth * 0.70
    
    switch screenWidth {
    case ..<320: return max(60, min(baseSize, 70))   // Very small screens - increased minimums
    case ..<375: return max(65, min(baseSize, 80))   // Small screens
    case ..<768: return max(70, min(baseSize, 90))   // Standard phones
    case ..<1024: return max(75, min(baseSize, 100)) // Large phones/small tablets
    case ..<1200: return max(80, min(baseSize, 110)) // Standard tablets
    case ..<1600: return max(85, min(baseSize, 120)) // Large tablets
    default: return max(90, min(baseSize, 130))      // Very large displays
    }
  }

  #if os(iOS)
  private let impact = UIImpactFeedbackGenerator(style: .rigid)
  #endif

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

  @MainActor
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
      guard !isEditingFeeds else { return }

      #if os(iOS)
      impact.impactOccurred()
      #endif

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
          let strokeColor: Color = {
            if isSelected {
              return Color.accentColor.opacity(0.6)
            } else {
              return Color.separator.opacity(0.5)
            }
          }()
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
      guard !isEditingFeeds else { return }

      #if os(iOS)
      impact.impactOccurred()
      #endif

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
        if isEditingFeeds {
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
          .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: isEditingFeeds)
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
      guard !isEditingFeeds else { return }

      #if os(iOS)
      impact.impactOccurred()
      #endif

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
      isEditingFeeds: $isEditingFeeds,
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
    GeometryReader { geometry in
      let availableWidth = geometry.size.width
      let contentWidth = min(availableWidth, drawerWidth)
      
      ScrollView {
        VStack(spacing: 0) {
          // Banner header using Apple's flexible header system
          bannerHeaderView()
            .flexibleHeaderContent()
            .background(Color.accentColor.opacity(0.05))
          
          // Main content below the banner
          feedsContent()
            .frame(maxWidth: contentWidth)
        }
        .frame(maxWidth: contentWidth, alignment: .center)
      }
      .flexibleHeaderScrollView()
      .frame(width: contentWidth)
      .frame(maxWidth: drawerWidth)
      .clipped()
      .ignoresSafeArea(edges: [.top, .bottom])
      .refreshable {
        await handleRefresh()
      }
    }
    .frame(maxWidth: drawerWidth)
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
      // Banner Image - constrained to drawer width
      bannerImageView
        .frame(maxWidth: drawerWidth)
      
      // Scrim overlay for text visibility
      LinearGradient(
        colors: [.black.opacity(0.6), .clear],
        startPoint: .bottom,
        endPoint: .center
      )
      .frame(maxWidth: drawerWidth)
      
      // Profile Info - responsive layout
      HStack(spacing: max(8, horizontalPadding * 0.4)) {
        // Avatar with responsive sizing
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
                .appFont(size: avatarSize * 0.4)
                .foregroundColor(.accentColor)
            }
          }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: max(1.5, avatarSize * 0.025)))
        .frame(width: avatarSize, height: avatarSize)
        
        // Display Name and Handle - responsive text sizing
        VStack(alignment: .leading, spacing: 2) {
          if let displayName = profile?.displayName, !displayName.isEmpty {
            Text(displayName)
              .font(.system(size: responsiveTextSize(base: 16, min: 14, max: 18), weight: .bold))
              .foregroundStyle(.white)
              .shadow(radius: 2)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          if let handle = profile?.handle {
            Text("@\(handle.description)")
              .font(.system(size: responsiveTextSize(base: 14, min: 12, max: 16)))
              .foregroundStyle(.white.opacity(0.9))
              .shadow(radius: 2)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        
        Spacer(minLength: 0)
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.bottom, max(12, bannerHeight * 0.08))
      .frame(maxWidth: drawerWidth)
    }
    .frame(maxWidth: drawerWidth)
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture {
      if let userDID = appState.authManager.state.userDID {
        appState.navigationManager.navigate(to: .profile(userDID))
        isDrawerOpen = false
      }
    }
    .onLongPressGesture {
      #if os(iOS)
      impact.impactOccurred()
      #endif
      isShowingAccountSwitcher = true
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("My Profile")
    .accessibilityHint("Double tap to view your profile. Long press to switch accounts.")
  }
  
  // Helper function for responsive text sizing
  private func responsiveTextSize(base: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    let scaleFactor = drawerWidth / 375.0  // Base on iPhone standard width
    let scaledSize = base * scaleFactor
    return Swift.max(min, Swift.min(scaledSize, max))
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

                  if isEditingFeeds {
                      Button {
                          withAnimation(.easeInOut(duration: 0.2)) {
                              isEditingFeeds = false
                          }
                      } label: {
                          Image(systemName: "checkmark")
                              .appFont(size: 16)
                      }
                      .tint(.accentColor.opacity(0.8))
                      .accessibilityLabel("Done Editing")
                      .accessibilityAddTraits(.isButton)
                  } else {
                      Button {
                          withAnimation(.easeInOut(duration: 0.2)) {
                              isEditingFeeds = true
                          }
                      } label: {
                          Image(systemName: "pencil")
                              .appFont(size: 16)
                      }
                      .tint(.accentColor.opacity(0.8))
                      .accessibility(label: Text("Edit Feeds"))
                      .accessibility(hint: Text("Double tap to enter edit mode"))
                      .accessibilityAddTraits(.isButton)
                  }
              }

          }
          .padding(.top, 24) // Add top padding to separate from banner
          .padding(.bottom, 24)
          .animation(.easeInOut(duration: 0.2), value: isEditingFeeds)

          // Search bar
          if isSearchBarVisible {
              searchBar()
                  .padding(.bottom, gridSpacing)
                  .transition(
                      .asymmetric(
                          insertion: .opacity.combined(with: .move(edge: .top)),
                          removal: .opacity.combined(with: .move(edge: .top))
                      ))
          }

          VStack(spacing: gridSpacing) {
              // Add Feed button in edit mode
              if isEditingFeeds {
                  addFeedButton()
                      .transition(.asymmetric(
                          insertion: .opacity.combined(with: .move(edge: .top)),
                          removal: .opacity.combined(with: .move(edge: .top))
                      ))
              }

              // Big default feed button as first feed in hierarchy
              bigDefaultFeedButton

              // Pinned feeds section - continue the hierarchy
              if !filteredPinnedFeeds.isEmpty {
                  sectionHeader("Pinned")
                  gridSection(for: filteredPinnedFeeds, category: "pinned")
              }

              // Saved feeds section
              if !filteredSavedFeeds.isEmpty {
                  sectionHeader("Saved")
                  gridSection(for: filteredSavedFeeds, category: "saved")
              }

              // Extra space at bottom
              Spacer(minLength: 200)
          }
          .animation(.easeInOut(duration: 0.3), value: isEditingFeeds)
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, max(20, horizontalPadding * 0.75))
      .frame(maxWidth: .infinity)
      .background(Color(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)))
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
      .background(Color.systemBackground.opacity(0.9))
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
      .background(Color.systemBackground.opacity(0.9))
    }
  }
  
  // MARK: - Banner Image Components
  
  @ViewBuilder
  private var bannerImageView: some View {
    Group {
      if let bannerURL = profile?.banner?.url {
        LazyImage(url: bannerURL) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .overlay(Color.black.opacity(0.15).blendMode(.overlay))
          } else if state.error != nil {
            fallbackGradientBanner
          } else {
            fallbackGradientBanner
              .overlay(ProgressView().tint(.white))
          }
        }
      } else {
        defaultGradientBanner
      }
    }
    .clipped()
  }
  
  @ViewBuilder
  private var fallbackGradientBanner: some View {
    LinearGradient(
      gradient: Gradient(colors: [
        Color.accentColor.opacity(0.3),
        Color.accentColor.opacity(0.1)
      ]),
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
  
  @ViewBuilder
  private var defaultGradientBanner: some View {
    LinearGradient(
      gradient: Gradient(colors: [
        Color.accentColor.opacity(0.3),
        Color.accentColor.opacity(0.1)
      ]),
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
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
      // Update the filtered feeds to refresh the UI with animation
      await MainActor.run {
        withAnimation(.spring(duration: 0.4)) {
          Task {
            await updateFilteredFeeds?()
          }
        }
      }
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


// MARK: - View Modifier Extension
extension View {
    func applyFeedsPageModifiers(
        viewModel: FeedsStartPageViewModel,
        appState: AppState,
        isEditingFeeds: Binding<Bool>,
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
            .configuredToolbar(
                isDrawerOpen: isDrawerOpen,
                showErrorAlert: showErrorAlert,
                errorAlertMessage: errorAlertMessage,
                onAppear: onAppear,
                onDisappear: onDisappear
            )
            .configuredSheets(
                showAddFeedSheet: showAddFeedSheet,
                isShowingAccountSwitcher: isShowingAccountSwitcher,
                showProtectedSystemFeedAlert: showProtectedSystemFeedAlert,
                lastProtectedFeedAction: lastProtectedFeedAction
            )
            .configuredDataObservers(
                viewModel: viewModel,
                errorAlertMessage: errorAlertMessage,
                showErrorAlert: showErrorAlert
            )
    }
}

private extension View {
    func configuredToolbar(
        isDrawerOpen: Binding<Bool>,
        showErrorAlert: Binding<Bool>,
        errorAlertMessage: Binding<String>,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void
    ) -> some View {
        self.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isDrawerOpen.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.primary)
                    }
                }
        }
        #if os(iOS)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #else
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        #endif
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .alert("Error", isPresented: showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorAlertMessage.wrappedValue)
        }
    }
    
    func configuredSheets(
        showAddFeedSheet: Binding<Bool>,
        isShowingAccountSwitcher: Binding<Bool>, 
        showProtectedSystemFeedAlert: Binding<Bool>,
        lastProtectedFeedAction: String
    ) -> some View {
        self
            .sheet(isPresented: showAddFeedSheet) {
                AddFeedSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thinMaterial)
            }
            .sheet(isPresented: isShowingAccountSwitcher) {
                AccountSwitcherView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thinMaterial)
            }
            .alert("System Feed Protected", isPresented: showProtectedSystemFeedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(lastProtectedFeedAction) cannot be performed on system feeds like Timeline/Following as they are required for the app to function correctly.")
            }
    }
    
    func configuredDataObservers(
        viewModel: FeedsStartPageViewModel,
        errorAlertMessage: Binding<String>,
        showErrorAlert: Binding<Bool>
    ) -> some View {
        self
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
    }
}
