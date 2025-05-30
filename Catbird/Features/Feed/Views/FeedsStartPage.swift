import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - FeedsStartPage
struct FeedsStartPage: View {
  // Environment and State properties
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var editMode: EditMode = .inactive
  @Binding var isDrawerOpen: Bool
  @State private var viewModel: FeedsStartPageViewModel
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String

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

  // Sizing properties
  private let screenWidth = UIScreen.main.bounds.width
  private var drawerWidth: CGFloat { screenWidth * 0.75 }
  private var gridSpacing: CGFloat { screenWidth < 375 ? 12 : 16 }
  private var horizontalPadding: CGFloat { screenWidth < 375 ? 12 : 16 }
  private var columns: Int {
    switch screenWidth {
    case ..<320: return 2
    case ..<375: return 3
    default: return 3
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
    default: return 65
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
      let uri = try? ATProtocolURI(uriString: feed) {
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
        && !viewModel.filteredFeeds([feed], searchText: searchText).contains(feed) {
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
      Text(title)
        .font(
          Font.customSystemFont(
            size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
            relativeTo: .title3)
        )
        .foregroundColor(.primary)

      Spacer()

      if title == "Pinned" {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if title == "Saved" {
        Image(systemName: "bookmark.fill")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, gridSpacing)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private func searchBar() -> some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .font(.system(size: 16, weight: .medium))

      TextField("Search feeds...", text: $searchText)
        .font(.system(size: 16, weight: .regular))
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
            .font(.system(size: 16, weight: .medium))
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
              .font(.headline)
              .foregroundStyle(.primary)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Spacer()

            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 14)
            .fill(.ultraThinMaterial)
            .overlay(
              LinearGradient(
                colors: [Color.accentColor.opacity(0.05), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            )
        )
        .shadow(
          color: .black.opacity(0.05),
          radius: 8,
          x: 0,
          y: 2
        )
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
        let generator = viewModel.feedGenerators[uri] {
        // Custom feed avatar
        LazyImage(url: URL(string: generator.avatar?.uriString() ?? "")) { state in
          if let image = state.image {
            image.resizable().aspectRatio(contentMode: .fill)
          } else {
            feedPlaceholder(for: defaultFeedName)
          }
        }
      } else {
        // Default system "Timeline" icon
        ZStack {
          LinearGradient(
            gradient: Gradient(colors: [
              Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.6)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Image(systemName: "clock")
            .font(.system(size: 24, weight: .semibold))
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
    .padding(.bottom, gridSpacing)
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
          .font(.caption2)
          .foregroundStyle(.primary)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: itemWidth - 6)
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(dropTargetItem == feedURI ? Color.accentColor.opacity(0.1) : Color.clear)
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(PlainButtonStyle())
    .interactiveGlass()
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
                  .font(.system(size: 20))
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
        resetDragState: resetDragState
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
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        // Feed name
        Text("Timeline")
          .font(.caption2)
          .foregroundStyle(.primary)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: itemWidth - 6)
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(dropTargetItem == feedURI ? Color.accentColor.opacity(0.15) : Color.clear)
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
        resetDragState: resetDragState
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
        .font(.system(.headline, design: .rounded, weight: .bold))
        .foregroundColor(.white)
    }
  }

  @ViewBuilder
  private func profileSection() -> some View {
      VStack(spacing: 12) {
      // User avatar - larger and centered
//      Button {
//      } label: {
          Group {
              if let avatarURL = profile?.avatar?.url {
                  AsyncProfileImage(url: avatarURL, size: 56)
              } else {
                  // Fallback avatar
                  ZStack {
                      Circle()
                          .fill(Color.accentColor.opacity(0.2))
                          .frame(width: 56, height: 56)
                      
                      Text(profile?.handle.description.prefix(1).uppercased() ?? "?")
                          .font(.system(size: 22, weight: .semibold))
                          .foregroundColor(.accentColor)
                  }
              }
          }
//      }
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
      .accessibility(label: Text("My Profile"))
      .accessibility(hint: Text("Double tap to view your profile. Long press to switch accounts."))
      .accessibilityAddTraits(.isButton)
      
      // Display name using customSystemFont
      if let displayName = profile?.displayName, !displayName.isEmpty {
        Text(displayName)
          .font(
            Font.customSystemFont(
              size: 17, weight: .medium, width: 120, opticalSize: true, design: .default,
              relativeTo: .title3)
          )
          .foregroundStyle(.primary)
          .lineLimit(1)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, safeAreaTop + 8)
    .padding(.bottom, 16)
  }

  // MARK: - UI Layout Sections

    
//@ViewBuilder
//  private func fixedHeaderSection() -> some View {
//    VStack(spacing: 0) {
//      // Safe area spacing
////      Rectangle()
////        .fill(Color.clear)
////        .frame(height: safeAreaTop)
//      
//      HStack {
//          // Profile section at the top with extra spacing
//
//        Spacer()
//        
//      }
////      .padding(.vertical, 12)
//      .padding(.horizontal, horizontalPadding)
//    }
//    .background(Color(UIColor.systemBackground))
//    .frame(maxWidth: .infinity)
//    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
//  }
  @ViewBuilder
  private func scrollableContent() -> some View {
    ScrollView {
      VStack(spacing: 0) {
          profileSection()
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, gridSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(
              color: Color.black.opacity(0.05),
              radius: 4, x: 0, y: 2
            )
          
        // Feeds heading
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
                    .font(.system(size: 16, weight: .medium))
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
                      .font(.system(size: 16, weight: .medium))
                  }
                  .tint(.accentColor.opacity(0.8))
                  .accessibilityLabel("Done Editing")
                  .accessibilityAddTraits(.isButton)
                } else {
                  Button {
                    editMode = .active
                  } label: {
                    Image(systemName: "slider.horizontal.3")
                      .font(.system(size: 16, weight: .medium))
                  }
                  .tint(.accentColor.opacity(0.8))
                  .accessibility(label: Text("Edit Feeds"))
                  .accessibility(hint: Text("Double tap to enter edit mode"))
                  .accessibilityAddTraits(.isButton)
                }

                Button("Close Feeds Menu") {
                  isDrawerOpen = false
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close Feeds Menu")
                .accessibility(hint: Text("Double tap to close the feeds menu"))
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(false)
              }

          }
          .padding(.horizontal, horizontalPadding)
          .padding(.bottom, 24)
          
          // Search bar
          if isSearchBarVisible {
            searchBar()
              .padding(.horizontal, horizontalPadding)
              .padding(.bottom, gridSpacing)
              .transition(.asymmetric(
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
      }
    }
    .refreshable {
      await viewModel.fetchFeedGenerators()
      await updateFilteredFeeds()
      if appState.isAuthenticated {
        await loadUserProfile()
      }
    }
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

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        // Base background
        Color(UIColor.systemBackground)
          .ignoresSafeArea()

        // Main scrollable content
        scrollableContent()

//         Fixed header overlay
//        VStack(spacing: 0) {
//          fixedHeaderSection()
//          Spacer()
//        }

        // Overlays
        loadingOverlay()
        initializationOverlay()
      }
      .environment(\.editMode, $editMode)
      .onAppear {
        // Sequential initialization
        Task {
          await viewModel.initializeWithModelContext(modelContext)
          await updateFilteredFeeds()
          isInitialized = true

          // Animation delay for smoother appearance
          withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
            isLoaded = true
          }
          
          // Load user profile
          if appState.isAuthenticated {
            await loadUserProfile()
          }
        }
      }
      .onChange(of: viewModel.cachedPinnedFeeds) { _, _ in
        Task { await updateFilteredFeeds() }
      }
      .onChange(of: viewModel.cachedSavedFeeds) { _, _ in
        Task { await updateFilteredFeeds() }
      }
      .task {
        // Periodic background refresh
        try? await Task.sleep(for: .seconds(2))
        if isInitialized {
          await viewModel.fetchFeedGenerators()
          await updateFilteredFeeds()
        }
      }
      .onChange(of: viewModel.feedGenerators) { _, _ in
        Task { await updateFilteredFeeds() }
      }
      .onChange(of: viewModel.errorMessage) { _, newError in
        if let errorMsg = newError {
          errorAlertMessage = errorMsg
          showErrorAlert = true
        }
      }
      .sheet(isPresented: $showAddFeedSheet) {
        AddFeedSheet()
      }
      .sheet(isPresented: $isShowingAccountSwitcher) {
        AccountSwitcherView()
      }
      .alert("System Feed Protected", isPresented: $showProtectedSystemFeedAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(
          "\(lastProtectedFeedAction) cannot be performed on system feeds like Timeline/Following as they are required for the app to function correctly."
        )
      }
      .alert("Error", isPresented: $showErrorAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorAlertMessage)
      }
    }
  }
}

// Helper Extensions
extension Optional where Wrapped == String {
  var isNilOrEmpty: Bool {
    self == nil || self?.isEmpty == true
  }
}
