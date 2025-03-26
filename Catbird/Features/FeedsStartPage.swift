import NukeUI
import OSLog
import Petrel
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FeedsStartPage: View {
  // Calculate offset for feed item animation
  private func calculatedOffsetFor(item: String) -> CGSize {
    // If no drop target or we're dragging this item, no offset
    guard let target = dropTargetItem, draggedFeedItem != item, isDragging else { 
      return CGSize.zero 
    }
    
    // Is this the drop target?
    if target == item {
      // This is the direct drop target - move it down
      return CGSize(width: 0, height: 20) 
    }
    
    // For empty category drops
    if target.starts(with: "empty-") {
      return CGSize.zero // No movement needed
    }
    
    // Handle pinned feeds
    if let targetIdx = filteredPinnedFeeds.firstIndex(of: target), 
       let itemIdx = filteredPinnedFeeds.firstIndex(of: item) {
      
      let indexDiff = targetIdx - itemIdx
      
      if abs(indexDiff) <= 1 && indexDiff != 0 {
        // Calculate column positions
        let targetColumn = targetIdx % columns
        let itemColumn = itemIdx % columns
        
        if targetColumn == itemColumn {
          // Same column - move vertically
          return CGSize(width: 0, height: indexDiff < 0 ? 20 : -20)
        } else if abs(targetColumn - itemColumn) == 1 {
          // Adjacent column - move horizontally
          return CGSize(width: targetColumn < itemColumn ? -15 : 15, height: 0)
        }
      }
    }
    
    // Handle saved feeds with same logic
    if let targetIdx = filteredSavedFeeds.firstIndex(of: target),
       let itemIdx = filteredSavedFeeds.firstIndex(of: item) {
      
      let indexDiff = targetIdx - itemIdx
      
      if abs(indexDiff) <= 1 && indexDiff != 0 {
        // Calculate column positions
        let targetColumn = targetIdx % columns
        let itemColumn = itemIdx % columns
        
        if targetColumn == itemColumn {
          // Same column - move vertically
          return CGSize(width: 0, height: indexDiff < 0 ? 20 : -20)
        } else if abs(targetColumn - itemColumn) == 1 {
          // Adjacent column - move horizontally
          return CGSize(width: targetColumn < itemColumn ? -15 : 15, height: 0)
        }
      }
    }
    
    return CGSize.zero
  }
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var editMode: EditMode = .inactive
  @Binding var isDrawerOpen: Bool
  @State private var viewModel: FeedsStartPageViewModel
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String
  @State private var searchText = ""
  @State private var isLoaded = false
  @State private var isInitialized = false  
  @State private var showAddFeedSheet = false
  @State private var newFeedURI = ""
  @State private var pinNewFeed = false
  @State private var showProtectedSystemFeedAlert = false
  @State private var lastProtectedFeedAction: String = ""
  @State private var draggedFeedItem: String?
  @State private var isDragging: Bool = false
  @State private var draggedItemCategory: String?
  @State private var dropTargetItem: String? = nil
  @State private var filteredPinnedFeeds: [String] = []
  @State private var filteredSavedFeeds: [String] = []
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedsStartPage")

  // Use a direct approach to get the actual safe area
  private var safeAreaTop: CGFloat {
    let window = UIApplication.shared.connectedScenes
      .filter { $0.activationState == .foregroundActive }
      .first(where: { $0 is UIWindowScene })
      .flatMap { $0 as? UIWindowScene }?.windows
      .first(where: { $0.isKeyWindow })

    return window?.safeAreaInsets.top ?? 44  // Default to 44 if can't determine
  }

  // Dynamic sizing
  private let screenWidth = UIScreen.main.bounds.width
  private var drawerWidth: CGFloat { screenWidth * 0.75 }
  private var gridSpacing: CGFloat { screenWidth < 375 ? 12 : 16 }  // Increased spacing
  private var horizontalPadding: CGFloat { screenWidth < 375 ? 12 : 16 }

  // Compute number of columns based on screen width and drawer width
  private var columns: Int {
    switch screenWidth {
    case ..<320: return 2  // iPhone SE 1st gen
    case ..<375: return 3  // iPhone SE 2nd/3rd gen
    case ..<430: return 3  // Standard iPhones
    default: return 3  // Larger devices
    }
  }

  // Compute item size based on available space
  private var itemWidth: CGFloat {
    let availableWidth =
      drawerWidth - (horizontalPadding * 2) - (gridSpacing * CGFloat(columns - 1))
    return availableWidth / CGFloat(columns)
  }

  // More compact icon size for better space utilization
  private var iconSize: CGFloat {
    switch screenWidth {
    case ..<320: return 45
    case ..<375: return 50
    default: return 52
    }
  }

  init(
    appState: AppState, selectedFeed: Binding<FetchType>, currentFeedName: Binding<String>,
    isDrawerOpen: Binding<Bool>
  ) {
    self._selectedFeed = selectedFeed
    self._viewModel = State(initialValue: FeedsStartPageViewModel(appState: appState))
    self._currentFeedName = currentFeedName
    self._isDrawerOpen = isDrawerOpen
  }

  var body: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        // Base background color that extends to all edges
        Color(UIColor.systemBackground)
          .ignoresSafeArea()

        // Main content with safe area handling
        VStack(spacing: 0) {
          // Header with proper safe area padding
          VStack(spacing: 0) {
            // Add explicit spacing for safe area
            Rectangle()
              .fill(Color.clear)
              .frame(height: safeAreaTop)

            HStack {
              Text("Feeds")
                .font(.title)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: .leading)

              EditButton()
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, horizontalPadding)

            Divider()
          }
          .background(Color(UIColor.systemBackground))
          .frame(maxWidth: .infinity)

          // Content
          ScrollView {
            VStack(spacing: gridSpacing) {
              Spacer(minLength: 16)

              // Search bar for filtering feeds
              HStack {
                Image(systemName: "magnifyingglass")
                  .foregroundColor(.secondary)

                TextField("Search feeds...", text: $searchText)
                  .foregroundColor(.primary)
                  .scrollDismissesKeyboard(.interactively)
                  .onChange(of: searchText) { _, _ in
                    Task {
                      await updateFilteredFeeds()
                    }
                  }

                if !searchText.isEmpty {
                  Button(action: {
                    searchText = ""
                    Task {
                      await updateFilteredFeeds()
                    }
                  }) {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundColor(.secondary)
                  }
                }
              }
              .padding(10)
              .background(Color(UIColor.secondarySystemBackground))
              .cornerRadius(10)
              .padding(.bottom, 8)

              // Add Feed button in edit mode
              if editMode.isEditing {
                Button(action: {
                  showAddFeedSheet = true
                }) {
                  HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add New Feed")
                  }
                  .padding()
                  .frame(maxWidth: .infinity)
                  .background(Color.accentColor.opacity(0.1))
                  .cornerRadius(10)
                }
                .padding(.vertical, 8)
              }

              timelineButton
                .padding(.top, 4)

              if !filteredPinnedFeeds.isEmpty {
                sectionHeader("Pinned Feeds")
                gridSection(for: filteredPinnedFeeds, category: "pinned")
              }

              if !filteredSavedFeeds.isEmpty {
                sectionHeader("Saved Feeds")
                gridSection(for: filteredSavedFeeds, category: "saved")
              }

              // Extra space at bottom for better scrolling experience
              Spacer(minLength: 200)
            }
            .padding(.horizontal, horizontalPadding)
            .onChange(of: isDragging) { wasActive, isActive in
                // If dragging just stopped, ensure draggedFeedItem and category are nil
                if wasActive && !isActive {
                    draggedFeedItem = nil
                    draggedItemCategory = nil
                }
                
                // Safety timer - reset drag state after a timeout
                if isActive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if isDragging {
                            withAnimation {
                                isDragging = false
                                draggedFeedItem = nil
                                draggedItemCategory = nil
                            }
                        }
                    }
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { _ in
                        // Only trigger if we're still in dragging state
                        if isDragging {
                            withAnimation {
                                isDragging = false
                                draggedFeedItem = nil
                                draggedItemCategory = nil
                            }
                        }
                    }
            )
          }
          .refreshable {
            await viewModel.fetchFeedGenerators()
            await updateFilteredFeeds()
          }
        }

        // Loading and error overlays with safe area consideration
        if viewModel.isLoading {
          VStack {
            Spacer()
            ProgressView("Loading feeds...")
            Spacer()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(UIColor.systemBackground).opacity(0.9))
        } else if let error = viewModel.errorMessage {
          VStack {
            Spacer()
            Text(error)
              .foregroundColor(.red)
              .padding()
            Spacer()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(UIColor.systemBackground).opacity(0.9))
        }

        // Show initialization loading overlay
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
      .environment(\.editMode, $editMode)
      .onAppear {
        // Sequential initialization
        Task {
          // First, initialize with ModelContext to set up all dependencies
          await viewModel.initializeWithModelContext(modelContext)

          // Then populate the filtered feeds
          await updateFilteredFeeds()

          // Mark initialization as complete
          isInitialized = true

          // Add animation delay for a smoother appearance
          withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
            isLoaded = true
          }
        }
      }
        .onChange(of: viewModel.cachedPinnedFeeds) { _, _ in
          Task {
            await updateFilteredFeeds()
          }
        }
        .onChange(of: viewModel.cachedSavedFeeds) { _, _ in
          Task {
            await updateFilteredFeeds()
          }
        }
      // Replace the task modifier with one that just refreshes data periodically
      .task {
        // Wait a bit before doing a background refresh
        try? await Task.sleep(for: .seconds(2))
        if isInitialized {
          await viewModel.fetchFeedGenerators()
          await updateFilteredFeeds()
        }
      }
      .onChange(of: viewModel.feedGenerators) { _, _ in
        Task {
          await updateFilteredFeeds()
        }
      }
      .sheet(isPresented: $showAddFeedSheet) {
        addFeedSheet
      }
      .alert("System Feed Protected", isPresented: $showProtectedSystemFeedAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(
          "\(lastProtectedFeedAction) cannot be performed on system feeds like Timeline/Following as they are required for the app to function correctly."
        )
      }
    }
  }

  private func updateFilteredFeeds() async {
    // Update the caches first
    await viewModel.updateCaches()

    // Then use the sync properties
    let pinnedFeeds = viewModel.cachedPinnedFeeds
    let savedFeeds = viewModel.cachedSavedFeeds

    filteredPinnedFeeds = viewModel.filteredFeeds(pinnedFeeds, searchText: searchText)
    let filteredSaved = viewModel.filteredFeeds(savedFeeds, searchText: searchText)
    // Filter out any feeds that are already in the pinned feeds list
    filteredSavedFeeds = filteredSaved.filter { feed in
      !pinnedFeeds.contains(feed)
    }
  }

  @ViewBuilder
  private func sectionHeader(_ title: String) -> some View {
    HStack {
      Text(title)
        .font(.headline)
        .foregroundColor(.primary)
      
      Spacer()
      
      // Show appropriate icon based on section
      if title == "Pinned Feeds" {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if title == "Saved Feeds" {
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
  private func gridSection(for feeds: [String], category: String) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
      spacing: gridSpacing
    ) {
      ForEach(feeds, id: \.self) { feed in
        if let uri = try? ATProtocolURI(uriString: feed) {
          feedLink(for: uri, feedURI: feed, category: category)
            // Visual effects during dragging
            .opacity(draggedFeedItem == feed && isDragging ? 0.4 : 1.0)
            .scaleEffect(draggedFeedItem == feed && isDragging ? 0.95 : 1.0)
            // Move items out of the way when something is being dragged to them
            .offset(calculatedOffsetFor(item: feed))
            .animation(.spring(duration: 0.3), value: dropTargetItem)
            .animation(.easeInOut(duration: 0.2), value: draggedFeedItem)
            .animation(.easeInOut(duration: 0.2), value: isDragging)
            // Add drop zone for the entire category
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(draggedFeedItem != nil && draggedFeedItem != feed && isDragging ? 
                           Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 2)
                    .padding(-4)
            )
        }
      }
    }
    // Add drop zone for adding to this category when empty
    .overlay(
      Group {
        if feeds.isEmpty && isDragging {
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
            .foregroundColor(Color.accentColor.opacity(0.5))
            .frame(height: 120)
            .overlay(
              Text(category == "pinned" ? "Drop here to pin" : "Drop here to unpin")
                .font(.subheadline)
                .foregroundColor(.secondary)
            )
            .onDrop(
              of: [UTType.plainText.identifier],
              delegate: EmptyCategoryDropDelegate(
                category: category,
                viewModel: viewModel,
                draggedItem: $draggedFeedItem,
                isDragging: $isDragging,
                draggedItemCategory: $draggedItemCategory,
                dropTargetItem: $dropTargetItem
              )
            )
        }
      }
    )
  }

  @ViewBuilder
  private var timelineButton: some View {
    Button {
      let impact = UIImpactFeedbackGenerator(style: .rigid)
      impact.impactOccurred()

      selectedFeed = .timeline
      currentFeedName = "Timeline"
      isDrawerOpen = false
    } label: {
      VStack(spacing: 6) {
        // Timeline icon with iOS app icon styling
        ZStack {
          LinearGradient(
            gradient: Gradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.6)]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          
          Image(systemName: "clock")
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        
        // Timeline label
        Text("Timeline")
          .font(.caption2)
          .foregroundStyle(.primary)
          .padding(.top, 4)
          .lineLimit(1)
      }
      .frame(width: itemWidth - 12)
      .padding(6)
    }
    .buttonStyle(PlainButtonStyle())
    .scaleEffect(isLoaded ? 1 : 0.8)
    .opacity(isLoaded ? 1 : 0)
  }

  @ViewBuilder
  private func feedLink(for uri: ATProtocolURI, feedURI: String, category: String) -> some View {
    Button {
      let impact = UIImpactFeedbackGenerator(style: .rigid)
      impact.impactOccurred()

      selectedFeed = .feed(uri)
      currentFeedName =
        viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
      isDrawerOpen = false
    } label: {
      VStack(spacing: 6) {
        // Avatar or placeholder in iOS-style icon shape
        Group {
          if let generator = viewModel.feedGenerators[uri] {
            LazyImage(url: URL(string: generator.avatar?.uriString() ?? "")) { state in
              if let image = state.image {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
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
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)

        // Feed name - iOS style app label
        Text(viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri))
          .font(.caption2)
          .foregroundStyle(.primary) // Use system foreground color
          .padding(.top, 4)
          .lineLimit(2)
          .frame(minHeight: 28, alignment: .top)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: itemWidth - 12) 
      .padding(6)
      // Remove background to match iOS app icon feel
    }
    .buttonStyle(PlainButtonStyle())  // Prevent default button styling
    .overlay(
      Group {
        if editMode.isEditing {
          VStack {
            HStack {
              Spacer()
              Button {
                Task {
                  if SystemFeedTypes.isTimelineFeed(feedURI) && viewModel.isPinnedSync(feedURI) {
                    lastProtectedFeedAction = "Removal"
                    showProtectedSystemFeedAlert = true
                  } else {
                    await viewModel.removeFeed(feedURI)
                  }
                }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .font(.system(size: 20))
                  .foregroundColor(.red)
                  .background(Circle().fill(Color.white))
              }
              .offset(x: -5, y: 5)  // Move the button inward
            }
            Spacer()
          }
        }
        
        // Show a pin badge for pinned feeds
        if category == "pinned" && !editMode.isEditing {
          VStack {
            HStack {
              Spacer()
              Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(4)
                .background(Circle().fill(Color.accentColor.opacity(0.8)))
                .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
            }
            Spacer()
          }
          .padding(4)
        }
      }
    )
    .onDrag {
      // Set the dragged item for animations
      draggedFeedItem = feedURI
      draggedItemCategory = category
      isDragging = true

      return NSItemProvider(object: feedURI as NSString)
    }
    .onDrop(
      of: [UTType.plainText.identifier],
      delegate: FeedDropDelegate(
        item: feedURI,
        items: category == "pinned"
          ? viewModel.cachedPinnedFeeds : viewModel.cachedSavedFeeds,
        category: category,
        viewModel: viewModel,
        draggedItem: $draggedFeedItem,
        isDragging: $isDragging,
        draggedItemCategory: $draggedItemCategory,
        dropTargetItem: $dropTargetItem
      )
    )
    .scaleEffect(isLoaded ? 1 : 0.8)
    .opacity(isLoaded ? 1 : 0)
    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
  }

  private func feedPlaceholder(for title: String) -> some View {
    ZStack {
      // iOS-like gradient background
      LinearGradient(
        gradient: Gradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.5)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      
      // First letter of feed name
      Text(title.prefix(1).uppercased())
        .font(.system(.headline, design: .rounded, weight: .bold))
        .foregroundColor(.white)
    }
  }

  // Add feed sheet
  @ViewBuilder
  private var addFeedSheet: some View {
    NavigationStack {
      Form {
        Section(header: Text("Feed URI")) {
          TextField("at://did:plc.../app.bsky.feed.generator/feed-id", text: $newFeedURI)
            .autocapitalization(.none)
            .autocorrectionDisabled()
        }

        Section {
          Toggle("Pin this feed", isOn: $pinNewFeed)
        }

        if !viewModel.errorMessage.isNilOrEmpty {
          Section {
            Text(viewModel.errorMessage ?? "")
              .foregroundColor(.red)
          }
        }

        Section {
          Button("Add Feed") {
            Task {
              if !newFeedURI.isEmpty {
                await viewModel.addFeed(newFeedURI, pinned: pinNewFeed)
                if viewModel.errorMessage == nil {
                  newFeedURI = ""
                  pinNewFeed = false
                  showAddFeedSheet = false
                }
              }
            }
          }
          .disabled(newFeedURI.isEmpty)
        }
      }
      .navigationTitle("Add Feed")
      .navigationBarItems(
        trailing: Button("Cancel") {
          showAddFeedSheet = false
          newFeedURI = ""
          pinNewFeed = false
        })
    }
  }

  private func ensureTimelineProtection() async {
    do {
      // This method is now only called after the ModelContext is ready
      try await appState.preferencesManager.fixTimelineFeedIssue()
    } catch {
      logger.error("Error fixing timeline feed issue: \(error.localizedDescription)")
    }
  }
}

// MARK: - Helper Extensions

extension Optional where Wrapped == String {
  var isNilOrEmpty: Bool {
    self == nil || self?.isEmpty == true
  }
}
