import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class ListDiscoveryViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let logger = Logger(subsystem: "blue.catbird", category: "ListDiscoveryView")
  
  // Data
  var discoveredLists: [AppBskyGraphDefs.ListView] = []
  var searchResults: [AppBskyGraphDefs.ListView] = []
  
  // State
  var isLoading = false
  var isSearching = false
  var searchText = ""
  var errorMessage: String?
  var showingError = false
  var selectedFilter: ListFilter = .all
  
  // Pagination
  var cursor: String?
  var hasMoreResults = true
  
  // Search debounce
  private var searchTask: Task<Void, Never>?
  
  // MARK: - Enums
  
  enum ListFilter: String, CaseIterable {
    case all = "All"
    case curated = "Curated"
    case moderation = "Moderation"
    case reference = "Reference"
    
    var purpose: AppBskyGraphDefs.ListPurpose? {
      switch self {
      case .all:
        return nil
      case .curated:
        return .appbskygraphdefscuratelist
      case .moderation:
        return .appbskygraphdefsmodlist
      case .reference:
        return .appbskygraphdefsreferencelist
      }
    }
  }
  
  // MARK: - Computed Properties
  
  var displayedLists: [AppBskyGraphDefs.ListView] {
    let lists = searchText.isEmpty ? discoveredLists : searchResults
    
    if selectedFilter == .all {
      return lists
    } else {
      return lists.filter { $0.purpose == selectedFilter.purpose }
    }
  }
  
  var hasLists: Bool {
    !displayedLists.isEmpty
  }
  
  // MARK: - Initialization
  
  init(appState: AppState) {
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadInitialData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    cursor = nil
    
    do {
      // Load suggested lists for discovery
      await loadSuggestedLists()
      
      logger.info("Loaded \(self.discoveredLists.count) discovered lists")
      
    } catch {
      logger.error("Failed to load discovered lists: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  @MainActor
  func loadMoreData() async {
    guard !isLoading && hasMoreResults else { return }
    
    do {
      await loadSuggestedLists(cursor: cursor)
      logger.debug("Loaded more discovered lists")
      
    } catch {
      logger.error("Failed to load more lists: \(error.localizedDescription)")
    }
  }
  
  @MainActor
  private func loadSuggestedLists(cursor: String? = nil) async {
    // Load suggested lists from the server
    
    // Simulate API delay
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    
    // Mock data
    let mockLists: [AppBskyGraphDefs.ListView] = []
    
    if cursor == nil {
      discoveredLists = mockLists
    } else {
      discoveredLists.append(contentsOf: mockLists)
    }
    
    // Simulate pagination
    self.cursor = mockLists.isEmpty ? nil : "next_page"
    hasMoreResults = !mockLists.isEmpty
  }
  
  // MARK: - Search
  
  func searchLists() {
    // Cancel previous search
    searchTask?.cancel()
    
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Clear results if query is empty
    guard !query.isEmpty else {
      searchResults = []
      return
    }
    
    // Debounce search
    searchTask = Task { @MainActor in
      // Wait for debounce period
      try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
      
      guard !Task.isCancelled else { return }
      
      await performSearch(query: query)
    }
  }
  
  @MainActor
  private func performSearch(query: String) async {
    guard let client = appState.atProtoClient else { return }
    
    isSearching = true
    
    do {
      // Filter discovered lists by search query
      self.searchResults = self.discoveredLists.filter { list in
        list.name.localizedCaseInsensitiveContains(query) ||
        (list.description?.localizedCaseInsensitiveContains(query) ?? false)
      }
      
      logger.debug("Search found \(self.searchResults.count) lists for query: \(query)")
      
    } catch {
      logger.error("Search failed: \(error.localizedDescription)")
    }
    
    isSearching = false
  }
  
  // MARK: - List Actions
  
  @MainActor
  func followList(_ list: AppBskyGraphDefs.ListView) async {
    // Follow/subscribe to the list
    logger.info("Would follow list: \(list.name)")
  }
}

struct ListDiscoveryView: View {
  @Environment(AppState.self) private var appState
  @State private var viewModel: ListDiscoveryViewModel
  @State private var navigationPath = NavigationPath()
  
  init() {
    self._viewModel = State(wrappedValue: ListDiscoveryViewModel(appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      contentView
        .navigationTitle("Discover Lists")
        .toolbarTitleDisplayMode(.large)
        .onAppear {
          viewModel = ListDiscoveryViewModel(appState: appState)
          Task {
            await viewModel.loadInitialData()
          }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search lists")
        .onChange(of: viewModel.searchText) { _, _ in
          viewModel.searchLists()
        }
        .alert("Error", isPresented: $viewModel.showingError) {
          Button("OK") {
            viewModel.showingError = false
          }
        } message: {
          if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
          }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $navigationPath, appState: appState, selectedTab: .constant(0))
        }
    }
  }
  
  @ViewBuilder
  private var contentView: some View {
    VStack(spacing: 0) {
      // Filter Picker
      filterPicker
      
      // Content
      if viewModel.isLoading && viewModel.discoveredLists.isEmpty {
        loadingView
      } else if !viewModel.hasLists {
        emptyStateView
      } else {
        listsView
      }
    }
  }
  
  private var filterPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(ListDiscoveryViewModel.ListFilter.allCases, id: \.self) { filter in
          FilterChip(
            title: filter.rawValue,
            isSelected: viewModel.selectedFilter == filter
          ) {
            viewModel.selectedFilter = filter
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(.regularMaterial)
  }
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Discovering lists...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var emptyStateView: some View {
    VStack(spacing: 24) {
      Image(systemName: "magnifyingglass.circle")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)
      
      VStack(spacing: 8) {
        Text("No Lists Found")
          .font(.title2)
          .fontWeight(.semibold)
        
        Text(viewModel.searchText.isEmpty ? 
             "There are no public lists to discover at the moment" :
             "No lists match your search terms")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      if !viewModel.searchText.isEmpty {
        Button("Clear Search") {
          viewModel.searchText = ""
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var listsView: some View {
    List {
      ForEach(viewModel.displayedLists, id: \.uri) { list in
        DiscoveryListRow(
          list: list,
          onTap: {
            navigationPath.append(NavigationDestination.listFeed(list.uri))
          },
          onFollow: {
            Task {
              await viewModel.followList(list)
            }
          }
        )
        .onAppear {
          // Load more when reaching the end
          if list == viewModel.displayedLists.last {
            Task {
              await viewModel.loadMoreData()
            }
          }
        }
      }
      
      // Loading indicator for pagination
      if viewModel.isLoading && !viewModel.discoveredLists.isEmpty {
        HStack {
          Spacer()
          ProgressView()
            .padding()
          Spacer()
        }
        .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
  }
}

// MARK: - Supporting Views

struct FilterChip: View {
  let title: String
  let isSelected: Bool
  let onTap: () -> Void
  
  var body: some View {
    Button(action: onTap) {
      Text(title)
        .font(.subheadline)
        .fontWeight(.medium)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? .blue : Color(.quaternarySystemFill))
        .foregroundStyle(isSelected ? .white : .primary)
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

struct DiscoveryListRow: View {
  let list: AppBskyGraphDefs.ListView
  let onTap: () -> Void
  let onFollow: () -> Void
  
  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          // List Avatar
          LazyImage(url: list.avatar?.url) { state in
            if let image = state.image {
              image
                .resizable()
                .scaledToFill()
            } else {
              listPlaceholderIcon
            }
          }
          .frame(width: 56, height: 56)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          
          // List Info
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(list.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
              
              Spacer()
              
              purposeIcon
            }
            
            if let description = list.description, !description.isEmpty {
              Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            
            HStack {
              Text("By @\(list.creator.handle)")
                .font(.caption)
                .foregroundStyle(.secondary)
              
              Spacer()
              
              Text("\(list.listItemCount ?? 0) members")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
        }
        
        // Action Buttons
        HStack(spacing: 12) {
          Button("View List") {
            onTap()
          }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity)
          
          Button("Follow") {
            onFollow()
          }
          .buttonStyle(.borderedProminent)
          .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
  }
  
  private var listPlaceholderIcon: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(.secondary.opacity(0.3))
      .overlay {
        Image(systemName: "list.bullet")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
  }
  
  private var purposeIcon: some View {
    Image(systemName: iconForPurpose)
      .font(.caption)
      .foregroundStyle(colorForPurpose)
      .padding(4)
      .background(colorForPurpose.opacity(0.2))
      .clipShape(Circle())
  }
  
  private var iconForPurpose: String {
    switch list.purpose {
    case .appbskygraphdefscuratelist:
      return "star.fill"
    case .appbskygraphdefsmodlist:
      return "shield.lefthalf.filled"
    case .appbskygraphdefsreferencelist:
      return "bookmark.fill"
    default:
      return "questionmark.circle"
    }
  }
  
  private var colorForPurpose: Color {
    switch list.purpose {
    case .appbskygraphdefscuratelist:
      return .yellow
    case .appbskygraphdefsmodlist:
      return .red
    case .appbskygraphdefsreferencelist:
      return .blue
    default:
      return .gray
    }
  }
}
