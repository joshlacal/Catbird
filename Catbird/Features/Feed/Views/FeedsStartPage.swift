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
import Nuke

// MARK: - Feed Layout Mode

enum FeedsLayoutMode: String, CaseIterable {
  case grid
  case list

  var toggleSymbol: String {
    switch self {
    case .grid: return "list.bullet"
    case .list: return "square.grid.2x2"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .grid: return "Switch to list view"
    case .list: return "Switch to grid view"
    }
  }
}

enum FeedsStartPageLayoutMetrics {
  static func iconSize(itemWidth: CGFloat) -> CGFloat {
    max(64, min(itemWidth * 0.8, 110))
  }
}

// MARK: - FeedsStartPage
struct FeedsStartPage: View {
  // Environment and State properties
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.colorScheme) private var colorScheme
  #if os(iOS)
  @Environment(\.inSideDrawer) private var inSideDrawer
  #else
  private var inSideDrawer: Bool { false }
  #endif
  @AppStorage("feedsStartPage.layoutMode") private var layoutModeRaw: String = FeedsLayoutMode.grid.rawValue
  private var layoutMode: FeedsLayoutMode {
    FeedsLayoutMode(rawValue: layoutModeRaw) ?? .grid
  }
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
  @FocusState private var isFeedSearchFocused: Bool
  @State private var isLoaded = false
  @State private var isInitialized = false
  @State private var currentUserDID: String?  // Track current account for change detection
  @State private var showAddFeedSheet = false
  @State private var discoveryInitialQuery = ""
  @State private var newFeedURI = ""
  @State private var pinNewFeed = false
  @State private var showProtectedSystemFeedAlert = false
  @State private var lastProtectedFeedAction: String = ""
  @State private var showErrorAlert = false
  @State private var errorAlertMessage = ""
  // Preview state
  

  // Drag and drop state
  @State private var draggedFeedItem: String?
  @State private var isDragging: Bool = false
  @State private var draggedItemCategory: String?
  @State private var dropTargetItem: String?
  @State private var isDefaultFeedDropTarget = false
  @Namespace private var glassNamespace

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

  private var drawerPrimaryTextColor: Color {
    .primary
  }

  private var drawerSecondaryTextColor: Color {
    .secondary
  }

  private var drawerTertiaryTextColor: Color {
    .secondary
  }

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
    // Container-driven banner height. Wide drawers (large iPad / Mac, where
    // drawerWidth reaches 480–600) get a taller banner so the header keeps its
    // proportions. Never exceed a quarter of the screen height.
    let baseHeight: CGFloat
    switch drawerWidth {
    case ..<360: baseHeight = 150
    case ..<480: baseHeight = 190
    default: baseHeight = 220
    }
    return min(baseHeight, screenHeight * 0.25)
  }

  // Interior insets for the profile row inside the banner. In the drawer the
  // banner is clipped by a ~28pt concentric corner, so the avatar and handle
  // need more clearance than the grid's horizontal padding or they crowd into
  // the corner curvature and read as cut off.
  private var bannerContentInset: CGFloat {
    inSideDrawer ? DesignTokens.Spacing.section : horizontalPadding  // 24
  }

  private var bannerContentBottomInset: CGFloat {
    inSideDrawer ? DesignTokens.Spacing.xxl : max(12, bannerHeight * 0.08)  // 21
  }
  
  // Responsive avatar size
  private var avatarSize: CGFloat {
    isNarrowDrawer ? 54 : 64
  }

  // Sizing properties
  private let screenHeight = PlatformScreenInfo.height
  private let isIPad = PlatformDeviceInfo.isIPad
  private var drawerWidth: CGFloat {
    PlatformScreenInfo.responsiveDrawerWidth
  }
  // Single threshold for the narrow (phone-width) vs. wide (iPad/Mac) drawer.
  private var isNarrowDrawer: Bool { drawerWidth < 360 }
  // Single source of truth for drawer card corner rounding (HIG: consistent shapes).
  private let cardCornerRadius: CGFloat = 12
  private var gridSpacing: CGFloat {
    isNarrowDrawer ? DesignTokens.Spacing.sm : DesignTokens.Spacing.base  // 6 / 12
  }
  private var horizontalPadding: CGFloat {
    isNarrowDrawer ? DesignTokens.Spacing.base : DesignTokens.Spacing.xl  // 12 / 18
  }
  private var columns: Int {
    switch drawerWidth {
    case ..<300: return 3  // Very small screens
    case ..<380: return 4  // Standard layout
    case ..<500: return 4  // Still prefer 3 columns for readability
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
    FeedsStartPageLayoutMetrics.iconSize(itemWidth: itemWidth)
  }

  // MARK: - Initialization
  init(
    appState: AppState,
    selectedFeed: Binding<FetchType>,
    currentFeedName: Binding<String>,
    isDrawerOpen: Binding<Bool>
  ) {
    self._selectedFeed = selectedFeed
    self._currentFeedName = currentFeedName
    self._isDrawerOpen = isDrawerOpen
    self._viewModel = State(wrappedValue: FeedsStartPageViewModel(appState: appState))
  }

  // MARK: - Helper Methods
  private func isSelected(feedURI: String) -> Bool {
    if SystemFeedTypes.isTimelineFeed(feedURI) {
      return selectedFeed == .timeline
    } else if let uri = try? ATProtocolURI(uriString: feedURI) {
      // Consider both custom feeds and list feeds
      return selectedFeed == .feed(uri) || selectedFeed == .list(uri)
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
      let did: String = appState.userDID

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

  // Build a Nuke ImageRequest that decodes at the exact pixel size for avatars
  private func avatarImageRequest(from urlString: String?, sizeInPoints: CGFloat) -> ImageRequest? {
    guard let urlString, let url = URL(string: urlString) else { return nil }
    let scale = PlatformScreenInfo.scale
    let pixelSize = CGSize(width: sizeInPoints * scale, height: sizeInPoints * scale)
    let processors: [any ImageProcessing] = [
      ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
    ]
    return ImageRequest(url: url, processors: processors, priority: .high)
  }

  // MARK: - UI Components
  /// Expands a control's hit area to Apple's 44×44pt minimum (HIG: Controls).
  private func hitTarget44<V: View>(_ content: V) -> some View {
    content
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
  }

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
          .foregroundColor(drawerPrimaryTextColor)
      } else if title == "Saved" {
        Image(systemName: "bookmark.fill")
          .font(
            Font.customSystemFont(
              size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
              relativeTo: .title3)
          )
          .foregroundColor(drawerPrimaryTextColor)
      }

      Text(title)
        .font(
          Font.customSystemFont(
            size: 21, weight: .bold, width: 120, opticalSize: true, design: .default,
            relativeTo: .title3)
        )
        .foregroundColor(drawerPrimaryTextColor)

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, DesignTokens.Spacing.lg)     // 15
    .padding(.bottom, DesignTokens.Spacing.md)  // 9
  }

  @ViewBuilder
  private func addFeedButton() -> some View {
    Button {
      discoveryInitialQuery = ""
      showAddFeedSheet = true
    } label: {
      hitTarget44(
        Image(systemName: "plus")
          .appFont(size: 16)
          .foregroundStyle(Color.accentColor)
      )
      .modifier(LaunchpadGlassCircle(isEnabled: inSideDrawer))
    }
    .accessibilityLabel("Add Feed")
    .accessibilityHint("Discover and add a feed")
  }

  @ViewBuilder
  private var defaultFeedReorderTarget: some View {
    if let defaultFeed {
      ForEach([defaultFeed], id: \.self) { _ in
        // iOS 27 SwiftUI traps on drag lift ("Unexpected identifier type") when a
        // reorderable item's root is conditional content; ZStack pins a single root.
        ZStack { bigDefaultFeedButton }
      }
      .feedReorderable(collectionID: "default")
    } else {
      bigDefaultFeedButton
    }
  }

  @ViewBuilder
  private var bigDefaultFeedButton: some View {
    Button {
      guard !isEditingFeeds else { return }

      #if os(iOS)
      PlatformHaptics.rigid()
      #endif

      if let feedURI = defaultFeed, SystemFeedTypes.isTimelineFeed(feedURI) {
        selectedFeed = .timeline
        currentFeedName = "Timeline"
      } else if let feedURI = defaultFeed, let uri = try? ATProtocolURI(uriString: feedURI) {
        let uriString = uri.uriString()
        if uriString.contains("/app.bsky.graph.list/") {
          selectedFeed = .list(uri)
        } else {
          selectedFeed = .feed(uri)
        }
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
              .foregroundStyle(drawerPrimaryTextColor)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Spacer()

            Image(systemName: "chevron.right")
              .appFont(AppTextRole.caption)
              .foregroundColor(drawerSecondaryTextColor)
          }
        }
        .padding(12)
        .background {
          if !inSideDrawer {
            RoundedRectangle(cornerRadius: 24)
              .fill(.ultraThinMaterial)
              .overlay(
                selectionBackground(
                  isSelected: isDefaultFeedSelected(),
                  isDropTarget: isDefaultFeedDropTarget
                )
              )
          }
        }
        .modifier(LaunchpadGlassChip(cornerRadius: 24, isEnabled: inSideDrawer))
        .overlay {
          if inSideDrawer && isDefaultFeedDropTarget {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.accentColor, lineWidth: 2)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      }
    }
    .buttonStyle(PlainButtonStyle())
    .padding(.vertical, 8)
    .feedLegacyDragAndDrop { content in
      content
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
    }
    .accessibility(label: Text("Open \(defaultFeedName) feed"))
    .accessibility(hint: Text("Double tap to open this feed and close the menu"))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func defaultFeedIcon(iconSize: CGFloat) -> some View {
    Group {
      if let feedURI = defaultFeed,
        !SystemFeedTypes.isTimelineFeed(feedURI),
        let uri = try? ATProtocolURI(uriString: feedURI)
      {
        if uri.uriString().contains("/app.bsky.graph.list/"),
           let list = viewModel.listDetails[uri] {
          // List avatar
          LazyImage(
            request: avatarImageRequest(from: list.avatar?.uriString(), sizeInPoints: iconSize)
          ) { state in
            if let image = state.image {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
              feedPlaceholder(for: list.name)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
          }
        } else if let generator = viewModel.feedGenerators[uri] {
          // Custom feed avatar
          LazyImage(
            request: avatarImageRequest(from: generator.avatar?.uriString(), sizeInPoints: iconSize)
          ) { state in
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
          feedPlaceholder(for: defaultFeedName)
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
    if layoutMode == .list {
      listSection(for: feeds, category: category)
    } else {
      gridLayoutSection(for: feeds, category: category)
    }
  }

  /// Feeds to render in a category's grid/list section, excluding whichever
  /// one is already shown in the big default-feed button. Only the "pinned"
  /// category can contain the default feed (it's always `pinnedFeeds.first`,
  /// see `updateFilteredFeeds`) — "saved" never does, so it must show every
  /// matching feed including its first. Filters by identity (the exact
  /// `defaultFeed` URI) rather than dropping whatever's positionally first:
  /// under an active search filter, the positionally-first *matching* pinned
  /// feed isn't necessarily the (search-agnostic) default feed, so a
  /// positional drop could either hide an unrelated matching feed or, if the
  /// default feed itself is what's left first, fail to exclude it — both
  /// wrong. Filtering by identity keeps this correct regardless of search.
  private func displayFeeds(_ feeds: [String], category: String) -> [String] {
    guard category == "pinned" else { return feeds }
    return feeds.filter { $0 != defaultFeed }
  }

  @ViewBuilder
  private func gridLayoutSection(for feeds: [String], category: String) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
      spacing: gridSpacing
    ) {
      ForEach(displayFeeds(feeds, category: category), id: \.self) { feed in
        // Single non-conditional root per reorderable item; see defaultFeedReorderTarget.
        ZStack {
          if SystemFeedTypes.isTimelineFeed(feed) {
            timelineFeedLink(feedURI: feed, category: category)
          } else if let uri = try? ATProtocolURI(uriString: feed) {
            feedLink(for: uri, feedURI: feed, category: category)
          }
        }
      }
      .feedReorderable(collectionID: category)
    }
    .animation(.spring(duration: 0.4), value: feeds)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(category.capitalized) feeds grid")
  }

  @ViewBuilder
  private func listSection(for feeds: [String], category: String) -> some View {
    VStack(spacing: 4) {
      ForEach(displayFeeds(feeds, category: category), id: \.self) { feed in
        // Single non-conditional root per reorderable item; see defaultFeedReorderTarget.
        ZStack {
          if SystemFeedTypes.isTimelineFeed(feed) {
            listRow(
              feedURI: feed,
              category: category,
              title: "Timeline",
              iconView: AnyView(timelineListIcon())
            )
          } else if let uri = try? ATProtocolURI(uriString: feed) {
            let title: String = {
              if uri.uriString().contains("/app.bsky.graph.list/") {
                return viewModel.listDetails[uri]?.name ?? viewModel.extractTitle(from: uri)
              }
              return viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
            }()
            let subtitle: String? = {
              if uri.uriString().contains("/app.bsky.graph.list/") {
                return viewModel.listDetails[uri]?.description
              }
              return viewModel.feedGenerators[uri]?.description
            }()
            listRow(
              feedURI: feed,
              category: category,
              title: title,
              subtitle: subtitle,
              iconView: AnyView(feedListIcon(for: uri))
            )
          }
        }
      }
      .feedReorderable(collectionID: category)
    }
    .animation(.spring(duration: 0.4), value: feeds)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(category.capitalized) feeds list")
  }

  private static let listRowIconSize: CGFloat = 40

  @ViewBuilder
  private func timelineListIcon() -> some View {
    ZStack {
      LinearGradient(
        gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.6)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: "clock")
        .appFont(size: 18)
        .foregroundColor(.white)
    }
    .frame(width: Self.listRowIconSize, height: Self.listRowIconSize)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func feedListIcon(for uri: ATProtocolURI) -> some View {
    Group {
      if uri.uriString().contains("/app.bsky.graph.list/"), let list = viewModel.listDetails[uri] {
        LazyImage(
          request: avatarImageRequest(from: list.avatar?.uriString(), sizeInPoints: Self.listRowIconSize)
        ) { state in
          if let image = state.image {
            image.resizable().aspectRatio(contentMode: .fill)
          } else {
            feedPlaceholder(for: list.name)
          }
        }
      } else if let generator = viewModel.feedGenerators[uri] {
        LazyImage(
          request: avatarImageRequest(from: generator.avatar?.uriString(), sizeInPoints: Self.listRowIconSize)
        ) { state in
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
    .frame(width: Self.listRowIconSize, height: Self.listRowIconSize)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func listRow(
    feedURI: String,
    category: String,
    title: String,
    subtitle: String? = nil,
    iconView: AnyView
  ) -> some View {
    Button {
      guard !isEditingFeeds else { return }
      #if os(iOS)
      PlatformHaptics.rigid()
      #endif

      if SystemFeedTypes.isTimelineFeed(feedURI) {
        selectedFeed = .timeline
        currentFeedName = "Timeline"
      } else if let uri = try? ATProtocolURI(uriString: feedURI) {
        let uriString = uri.uriString()
        if uriString.contains("/app.bsky.graph.list/") {
          selectedFeed = .list(uri)
        } else {
          selectedFeed = .feed(uri)
        }
        currentFeedName = title
      }
      isDrawerOpen = false
    } label: {
      HStack(spacing: 12) {
        iconView

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .appFont(AppTextRole.body)
            .foregroundStyle(drawerPrimaryTextColor)
            .lineLimit(1)
            .truncationMode(.tail)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .appFont(AppTextRole.caption)
              .foregroundStyle(drawerSecondaryTextColor)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isEditingFeeds {
          Button {
            Task { await viewModel.removeFeed(feedURI) }
          } label: {
            hitTarget44(
              Image(systemName: "minus.circle.fill")
                .appFont(size: 20)
                .foregroundColor(.red)
            )
          }
          .buttonStyle(PlainButtonStyle())
          .accessibilityLabel("Remove feed")
        } else {
          Image(systemName: "chevron.right")
            .appFont(AppTextRole.caption)
            .foregroundStyle(drawerTertiaryTextColor)
        }
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .background(
        selectionBackground(
          isSelected: isSelected(feedURI: feedURI),
          isDropTarget: dropTargetItem == feedURI
        )
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
    .feedLegacyDragAndDrop { content in
      content
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
    }
    .opacity(draggedFeedItem == feedURI && isDragging ? 0.4 : 1.0)
    .accessibility(label: Text(title))
    .accessibility(hint: Text(isEditingFeeds ? "Editing — tap minus to remove" : "Double tap to open this feed"))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func feedLink(for uri: ATProtocolURI, feedURI: String, category: String) -> some View {
    Button {
      guard !isEditingFeeds else { return }

      #if os(iOS)
      PlatformHaptics.rigid()
      #endif

      // Choose correct fetch type based on URI collection
      let uriString = uri.uriString()
      if uriString.contains("/app.bsky.graph.list/") {
        selectedFeed = .list(uri)
      } else {
        selectedFeed = .feed(uri)
      }
      currentFeedName =
        viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
      isDrawerOpen = false
    } label: {
      VStack(spacing: 6) {
        // Feed icon
        Group {
          if uri.uriString().contains("/app.bsky.graph.list/"), let list = viewModel.listDetails[uri] {
            LazyImage(
              request: avatarImageRequest(from: list.avatar?.uriString(), sizeInPoints: iconSize)
            ) { state in
              if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
              } else {
                feedPlaceholder(for: list.name)
              }
            }
          } else if let generator = viewModel.feedGenerators[uri] {
            LazyImage(
              request: avatarImageRequest(from: generator.avatar?.uriString(), sizeInPoints: iconSize)
            ) { state in
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

        // Feed/List name
        Text(
          uri.uriString().contains("/app.bsky.graph.list/")
            ? (viewModel.listDetails[uri]?.name ?? viewModel.extractTitle(from: uri))
            : (viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri))
        )
          .appFont(AppTextRole.caption2)
          .foregroundStyle(drawerPrimaryTextColor)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        
      }
      .padding(6)
      .frame(width: itemWidth)
      .background(
        Group {
          if !inSideDrawer {
            selectionBackground(
              isSelected: isSelected(feedURI: feedURI),
              isDropTarget: dropTargetItem == feedURI
            )
          }
        }
      )
      .modifier(
        LaunchpadSelectionGlass(
          isSelected: isSelected(feedURI: feedURI),
          isDropTarget: dropTargetItem == feedURI,
          cornerRadius: cardCornerRadius,
          namespace: glassNamespace,
          isEnabled: inSideDrawer
        )
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))

    }
    .buttonStyle(PlainButtonStyle())


    .modifier(FeedRemovalBadgeOverlay(
      isEditing: isEditingFeeds,
      iconSize: iconSize,
      iconTopInset: 6,
      action: { Task { await viewModel.removeFeed(feedURI) } }
    ))
    .feedLegacyDragAndDrop { content in
      content
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
    }
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
      PlatformHaptics.rigid()
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
          .foregroundStyle(drawerPrimaryTextColor)
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(6)
      .frame(width: itemWidth)
      .background(
        Group {
          if !inSideDrawer {
            selectionBackground(
              isSelected: isSelected(feedURI: feedURI),
              isDropTarget: dropTargetItem == feedURI
            )
          }
        }
      )
      .modifier(
        LaunchpadSelectionGlass(
          isSelected: isSelected(feedURI: feedURI),
          isDropTarget: dropTargetItem == feedURI,
          cornerRadius: cardCornerRadius,
          namespace: glassNamespace,
          isEnabled: inSideDrawer
        )
      )
      .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(PlainButtonStyle())
    .feedLegacyDragAndDrop { content in
      content
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
    }
    .opacity(draggedFeedItem == feedURI && isDragging ? 0.4 : 1.0)
    .scaleEffect(draggedFeedItem == feedURI && isDragging ? 0.95 : 1.0)
    .accessibility(label: Text("Timeline"))
    .accessibility(hint: Text("Double tap to open the Timeline feed"))
    .accessibilityAddTraits(.isButton)
  }

  /// The background for a selectable feed cell. `isSelected` cells should read
  /// as clearly chosen in both light and dark mode; unselected cells stay quiet.
  /// `isDropTarget` briefly highlights a drag-drop target.
  @ViewBuilder
  private func selectionBackground(isSelected: Bool, isDropTarget: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    // Drop target takes precedence over selection (transient, stronger). All
    // states share one accent fill; only the selected state adds a 1pt stroke.
    // Opacity-based accent adapts automatically to light and dark mode.
    let fillOpacity: Double = isDropTarget ? 0.16 : (isSelected ? 0.10 : 0.0)
    return shape
      .fill(Color.accentColor.opacity(fillOpacity))
      .overlay(
        shape.stroke(
          isSelected && !isDropTarget ? Color.accentColor.opacity(0.45) : Color.clear,
          lineWidth: 1
        )
      )
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
    mainContent
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        Button {
          if isSearchBarVisible {
            searchText = ""
            isSearchBarVisible = false
            isFeedSearchFocused = false
          } else {
            isSearchBarVisible = true
          }
        } label: {
          Label("Search your feeds", systemImage: "magnifyingglass")
        }
        .opacity(inSideDrawer && !isDrawerOpen ? 0 : 1)
        .allowsHitTesting(!inSideDrawer || isDrawerOpen)
        .accessibilityHidden(inSideDrawer && !isDrawerOpen)
        .accessibilityIdentifier("feeds.search.toggle")
      }
    }
    .task(id: searchText) {
      await updateFilteredFeeds()
    }
    .applyFeedsPageModifiers(
      viewModel: viewModel,
      appState: appState,
      isEditingFeeds: $isEditingFeeds,
      isDrawerOpen: $isDrawerOpen,
      showAddFeedSheet: $showAddFeedSheet,
      discoveryInitialQuery: discoveryInitialQuery,
      onOpenDiscoveredFeed: { feed in
        selectedFeed = .feed(feed.uri)
        currentFeedName = feed.displayName
        showAddFeedSheet = false
        isDrawerOpen = false
      },
      isShowingAccountSwitcher: $isShowingAccountSwitcher,
      showProtectedSystemFeedAlert: $showProtectedSystemFeedAlert,
      lastProtectedFeedAction: lastProtectedFeedAction,
      showErrorAlert: $showErrorAlert,
      errorAlertMessage: $errorAlertMessage,
      onAppear: handleOnAppear,
      onDisappear: handleOnDisappear,
      onAccountSwitch: handleAccountSwitch,
      currentUserDID: currentUserDID
    )
    
  }
  
  @ViewBuilder
  private var mainContent: some View {
    GeometryReader { geometry in
      let availableWidth = geometry.size.width
      let contentWidth = min(availableWidth, drawerWidth)

      standardContent(contentWidth: contentWidth, topInset: min(geometry.safeAreaInsets.top, navigationBarHeight))
    }
    .frame(maxWidth: drawerWidth)
    .overlay {
      // Full-screen loading/initialization overlays
      loadingOverlay()
      initializationOverlay()
    }
  }

  @ViewBuilder
  private func standardContent(contentWidth: CGFloat, topInset: CGFloat) -> some View {
      ScrollView {
        VStack(spacing: 0) {
          // The concentric clip must be inside `flexibleHeaderContent()` so
          // the mask stretches and stays pinned with the image.
          bannerHeaderView(topInset: topInset)
            .modifier(DrawerBannerInset())
            .flexibleHeaderContent(height: 200 + topInset)
            .background(inSideDrawer ? Color.clear : Color.accentColor.opacity(0.05))

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
      .modifier(DrawerAwareScrollBackground())
      .refreshable {
        await handleRefresh()
      }
  }

  private func handleRefresh() async {
    await viewModel.fetchFeedGenerators()
    await viewModel.fetchListDetails()
    await updateFilteredFeeds()
    if appState.isAuthenticated {
      await loadUserProfile()
    }
  }
  
  private func handleOnAppear() {
    Task {
      // Track current user for account switch detection
      currentUserDID = appState.userDID

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

  private func handleAccountSwitch() {
    // Reset state when account changes
    isInitialized = false
    isLoaded = false
    profile = nil
    currentUserDID = appState.userDID

    // Re-run initialization for the new account
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
    }
  }
  
  private func handleOnDisappear() {
    if let subscriber = stateInvalidationSubscriber {
      appState.stateInvalidationBus.unsubscribe(subscriber)
      stateInvalidationSubscriber = nil
    }
  }

  // (Drawer-level close/search/bookmarks moved to ContentView native toolbar)

  @ViewBuilder
  private func bannerHeaderView(topInset: CGFloat) -> some View {
    ZStack(alignment: .bottomLeading) {
      FeedBannerArtwork(topInset: topInset) {
        bannerImageView
      }
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
          if let avatarURL = profile?.finalAvatarURL() {
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
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {  // 3
          if let displayName = profile?.displayName, !displayName.isEmpty {
            Text(displayName)
              .appFont(AppTextRole.headline)
              .foregroundStyle(.white)
              .shadow(radius: 2)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          if let handle = profile?.handle {
            Text("@\(handle.description)")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.white.opacity(0.9))
              .shadow(radius: 2)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        
        Spacer(minLength: 0)
      }
      .padding(.horizontal, bannerContentInset)
      .padding(.bottom, bannerContentBottomInset)
      .frame(maxWidth: drawerWidth)
    }
    .frame(maxWidth: drawerWidth)
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture {
      let userDID = appState.userDID
      appState.navigationManager.navigate(to: .profile(userDID))
      isDrawerOpen = false
    }
    .onLongPressGesture {
      #if os(iOS)
      PlatformHaptics.rigid()
      #endif
      isShowingAccountSwitcher = true
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("My Profile")
    .accessibilityHint("Double tap to view your profile. Long press to switch accounts.")
  }

  @ViewBuilder
  private var feedsTitleRow: some View {
    HStack {
        Text("Feeds")
            .font(
                Font.customSystemFont(
                    size: 24, weight: .bold, width: 120, opticalSize: true, design: .default,
                    relativeTo: .title)
            )
            .foregroundStyle(drawerPrimaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        Spacer()

        HStack(spacing: 12) {
            addFeedButton()

            // Layout-mode toggle (grid <-> list). Persisted via @AppStorage.
            Button {
                #if os(iOS)
                PlatformHaptics.rigid()
                #endif
                withAnimation(.easeInOut(duration: 0.25)) {
                    layoutModeRaw = (layoutMode == .grid ? FeedsLayoutMode.list : FeedsLayoutMode.grid).rawValue
                }
            } label: {
                hitTarget44(
                  Image(systemName: layoutMode.toggleSymbol)
                    .appFont(size: 16)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Color.accentColor)
                )
                .modifier(LaunchpadGlassCircle(isEnabled: inSideDrawer))
            }
            .tint(.accentColor.opacity(0.8))
            .accessibilityLabel(layoutMode.accessibilityLabel)
            .accessibilityAddTraits(.isButton)

            if isEditingFeeds {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditingFeeds = false
                    }
                } label: {
                    hitTarget44(
                      Image(systemName: "checkmark")
                        .appFont(size: 16)
                    )
                    .modifier(LaunchpadGlassCircle(isEnabled: inSideDrawer))
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
                    hitTarget44(
                      Image(systemName: "pencil")
                        .appFont(size: 16)
                    )
                    .modifier(LaunchpadGlassCircle(isEnabled: inSideDrawer))
                }
                .tint(.accentColor.opacity(0.8))
                .accessibility(label: Text("Edit Feeds"))
                .accessibility(hint: Text("Double tap to enter edit mode"))
                .accessibilityAddTraits(.isButton)
            }
        }

    }
    .animation(.easeInOut(duration: 0.2), value: isEditingFeeds)
  }

  @ViewBuilder
  private func feedsContent() -> some View {
      VStack(spacing: 0) {
          // Scoped to just this row's three glass circles (search, grid/list
          // toggle, edit/done) — a small container INSIDE scroll content,
          // scrolling with it, is safe. A container SPANNING scrolling/clipped
          // content from outside is not: the hoisted glass pass ignores clips
          // and leaks off-screen glass layers as ghost cards (see the launchpad
          // pager's history of this bug). Do not wrap anything larger than the
          // title row.
          Group {
            if #available(iOS 26.0, macOS 26.0, *) {
              GlassEffectContainer(spacing: 8) {
                feedsTitleRow
              }
            } else {
              feedsTitleRow
            }
          }
              .padding(.top, DesignTokens.Spacing.section)     // 24
              .padding(.bottom, DesignTokens.Spacing.section)  // 24

          VStack(spacing: gridSpacing) {
              if isSearchBarVisible {
                HStack(spacing: 8) {
                  Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                  TextField("Search your feeds", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFeedSearchFocused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("feeds.search.field")
                  Button {
                    searchText = ""
                    isSearchBarVisible = false
                    isFeedSearchFocused = false
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .accessibilityLabel("Close feed search")
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cardCornerRadius))
                .task { isFeedSearchFocused = true }
              }

              if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 filteredPinnedFeeds.isEmpty, filteredSavedFeeds.isEmpty {
                  Button {
                      discoveryInitialQuery = searchText
                      showAddFeedSheet = true
                  } label: {
                      Label("Discover more feeds", systemImage: "magnifyingglass")
                          .frame(minHeight: 44)
                  }
                  .accessibilityHint("Search community feeds using your current search")
              }

              // Big default feed button as first feed in hierarchy
              defaultFeedReorderTarget

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
              Spacer(minLength: DesignTokens.Spacing.section * 4)  // 96
          }
          .modifier(FeedNativeReorderContainer { sources, category, before in
            Task {
              await viewModel.applyFeedReorder(sources: sources, category: category, before: before)
              if category == "default", let feed = sources.first,
                 viewModel.cachedPinnedFeeds.first == feed {
                if SystemFeedTypes.isTimelineFeed(feed) {
                  selectedFeed = .timeline
                  currentFeedName = "Timeline"
                } else if let uri = try? ATProtocolURI(uriString: feed) {
                  selectedFeed = feed.contains("/app.bsky.graph.list/") ? .list(uri) : .feed(uri)
                  currentFeedName = viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
                }
              }
            }
          })
          .animation(.easeInOut(duration: 0.3), value: isEditingFeeds)
          .animation(.easeInOut(duration: 0.25), value: layoutMode)
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, DesignTokens.Spacing.xl)  // 18
      .frame(maxWidth: .infinity)
      .background(
        inSideDrawer
          ? Color.clear
          : Color(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      )
  }

  // MARK: - Overlays
  @ViewBuilder
  private func loadingOverlay() -> some View {
    if viewModel.isLoading {
      (inSideDrawer
        ? Color.clear
        : Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
        .ignoresSafeArea()
        .overlay {
          ProgressView("Loading feeds...")
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
  }

  @ViewBuilder
  private func initializationOverlay() -> some View {
    if !isInitialized {
      (inSideDrawer
        ? Color.clear
        : Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
        .ignoresSafeArea()
        .overlay {
          ProgressView("Loading your feeds...")
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
  }
  
  // MARK: - Banner Image Components
  
  @ViewBuilder
  private var bannerImageView: some View {
    Group {
      if let bannerURL = profile?.banner?.url {
        LazyImage(url: bannerURL) { state in
          if let image = state.image {
            Color.clear
              .overlay {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
              }
              .overlay {
                Color(white: 0, opacity: 0.15)
                  .blendMode(SwiftUI.BlendMode.overlay)
              }
              .clipped()
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
        discoveryInitialQuery: String,
        onOpenDiscoveredFeed: @escaping (AppBskyFeedDefs.GeneratorView) -> Void,
        isShowingAccountSwitcher: Binding<Bool>,
        showProtectedSystemFeedAlert: Binding<Bool>,
        lastProtectedFeedAction: String,
        showErrorAlert: Binding<Bool>,
        errorAlertMessage: Binding<String>,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void,
        onAccountSwitch: @escaping () -> Void,
        currentUserDID: String?
    ) -> some View {
        self
            .modifier(DrawerAwareThemedBackground(themeManager: appState.themeManager, appSettings: appState.appSettings))
            .configuredToolbar(
                appState: appState,
                isDrawerOpen: isDrawerOpen,
                showErrorAlert: showErrorAlert,
                errorAlertMessage: errorAlertMessage,
                onAppear: onAppear,
                onDisappear: onDisappear,
                onAccountSwitch: onAccountSwitch,
                currentUserDID: currentUserDID
            )
            .configuredSheets(
                showAddFeedSheet: showAddFeedSheet,
                discoveryInitialQuery: discoveryInitialQuery,
                onOpenDiscoveredFeed: onOpenDiscoveredFeed,
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

// Skips the opaque themed background when the start page is rendered inside
// the side drawer overlay, so the drawer's Liquid Glass / material is visible.
private struct DrawerAwareThemedBackground: ViewModifier {
    let themeManager: ThemeManager
    let appSettings: AppSettings
    #if os(iOS)
    @Environment(\.inSideDrawer) private var inSideDrawer
    #else
    private let inSideDrawer = false
    #endif

    func body(content: Content) -> some View {
        if inSideDrawer {
            content
        } else {
            content.themedPrimaryBackground(themeManager, appSettings: appSettings)
        }
    }
}

private struct DrawerAwareScrollBackground: ViewModifier {
    #if os(iOS)
    @Environment(\.inSideDrawer) private var inSideDrawer
    #else
    private let inSideDrawer = false
    #endif

    func body(content: Content) -> some View {
        if inSideDrawer {
            content
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .modifier(DrawerBannerScrollEdgeModifier())
        } else {
            content
        }
    }
}

/// The banner supplies its own blur behind the top controls. The system scroll
/// edge effect would cover that artwork with the drawer's backdrop color.
private struct DrawerBannerScrollEdgeModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .top)
    } else {
      content
    }
  }
}

/// Clips the drawer banner to a uniform radius measured from its top corners.
/// The modifier's zero horizontal inset keeps the banner full-bleed.
private struct DrawerBannerInset: ViewModifier {
    #if os(iOS)
    @Environment(\.inSideDrawer) private var inSideDrawer
    #else
    private let inSideDrawer = false
    #endif

    func body(content: Content) -> some View {
        if inSideDrawer {
            #if os(iOS)
            content
                .modifier(ConcentricBannerClip())
            #else
            content
            #endif
        } else {
            content
        }
    }
}

private extension View {
    func configuredToolbar(
        appState: AppState,
        isDrawerOpen: Binding<Bool>,
        showErrorAlert: Binding<Bool>,
        errorAlertMessage: Binding<String>,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void,
        onAccountSwitch: @escaping () -> Void,
        currentUserDID: String?
    ) -> some View {
        // Remove global SwiftUI .toolbar usage to keep actions confined to the drawer.
        // Lifecycle and alerts remain here; UI buttons are rendered inside the drawer view itself.
        self
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onChange(of: appState.userDID) { oldDID, newDID in
                // Detect account switch - only trigger if we had a previous DID and it changed
                if let currentDID = currentUserDID, currentDID != newDID {
                    onAccountSwitch()
                }
            }
            .alert("Error", isPresented: showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorAlertMessage.wrappedValue)
            }
    }
    
    func configuredSheets(
        showAddFeedSheet: Binding<Bool>,
        discoveryInitialQuery: String,
        onOpenDiscoveredFeed: @escaping (AppBskyFeedDefs.GeneratorView) -> Void,
        isShowingAccountSwitcher: Binding<Bool>, 
        showProtectedSystemFeedAlert: Binding<Bool>,
        lastProtectedFeedAction: String
    ) -> some View {
        self
            .sheet(isPresented: showAddFeedSheet) {
                AddFeedSheet(initialQuery: discoveryInitialQuery, onOpen: onOpenDiscoveredFeed)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thinMaterial)
            }
            .sheet(isPresented: isShowingAccountSwitcher) {
                AccountSwitcherView()
                    .environment(AppStateManager.shared)
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
                // Retry fetching generators if we don't have them after initial load
                try? await Task.sleep(for: .seconds(1))
                if viewModel.feedGenerators.isEmpty {
                    await viewModel.fetchFeedGenerators()
                }
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

#Preview("FeedsStartPage") {
  AsyncPreviewContent { appState in
    FeedsStartPage(
      appState: appState,
      selectedFeed: .constant(.timeline),
      currentFeedName: .constant("Following"),
      isDrawerOpen: .constant(false)
    )
  }
}

// Keep the legacy drag delegates on SDKs and systems predating native reordering.
private extension View {
  @ViewBuilder
  func feedLegacyDragAndDrop<Legacy: View>(@ViewBuilder legacy: (Self) -> Legacy) -> some View {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, *) {
      self
    } else {
      legacy(self)
    }
    #else
    legacy(self)
    #endif
  }
}

private extension DynamicViewContent {
  @ViewBuilder
  func feedReorderable(collectionID: String) -> some View {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, *) {
      self.reorderable(collectionID: collectionID)
    } else {
      self
    }
    #else
    self
    #endif
  }
}

private struct FeedNativeReorderContainer: ViewModifier {
  let move: ([String], String, String?) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, *) {
      content.reorderContainer(for: String.self, itemID: \.self, in: String.self) { difference in
        let before: String?
        switch difference.destination.position {
        case .before(let uri): before = uri
        case .end: before = nil
        }
        move(difference.sources, difference.destination.collectionID, before)
      }
    } else {
      content
    }
    #else
    content
    #endif
  }
}
