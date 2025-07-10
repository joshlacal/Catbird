import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class ListsManagerViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let logger = Logger(subsystem: "blue.catbird", category: "ListsManagerView")
  
  // Data
  var userLists: [AppBskyGraphDefs.ListView] = []
  
  // State
  var isLoading = false
  var isRefreshing = false
  var errorMessage: String?
  var showingError = false
  var showingCreateList = false
  var showingDeleteConfirmation = false
  var listToDelete: AppBskyGraphDefs.ListView?
  
  // Search and filtering
  var searchText = ""
  
  // MARK: - Computed Properties
  
  var hasLists: Bool {
    !userLists.isEmpty
  }
  
  var filteredLists: [AppBskyGraphDefs.ListView] {
    if searchText.isEmpty {
      return userLists
    } else {
      let searchTerm = searchText.lowercased()
      return userLists.filter { list in
        list.name.lowercased().contains(searchTerm) ||
        (list.description?.lowercased().contains(searchTerm) ?? false)
      }
    }
  }
  
  var groupedLists: [String: [AppBskyGraphDefs.ListView]] {
    Dictionary(grouping: filteredLists) { list in
      switch list.purpose {
      case .appbskygraphdefscuratelist:
        return "Curated Lists"
      case .appbskygraphdefsmodlist:
        return "Moderation Lists"
      case .appbskygraphdefsreferencelist:
        return "Reference Lists"
      default:
        return "Other Lists"
      }
    }
  }
  
  // MARK: - Initialization
  
  init(appState: AppState) {
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      userLists = try await appState.listManager.loadUserLists()
      logger.info("Loaded \(self.userLists.count) user lists")
      
    } catch {
      logger.error("Failed to load user lists: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  @MainActor
  func refreshData() async {
    guard !isRefreshing else { return }
    
    isRefreshing = true
    
    do {
      userLists = try await appState.listManager.loadUserLists(forceRefresh: true)
      logger.info("Refreshed \(self.userLists.count) user lists")
      
    } catch {
      logger.error("Failed to refresh user lists: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isRefreshing = false
  }
  
  // MARK: - List Management
  
  @MainActor
  func deleteList(_ list: AppBskyGraphDefs.ListView) async {
    do {
      try await appState.listManager.deleteList(list.uri.description)
      
      // Remove from local array
      userLists.removeAll { $0.uri.description == list.uri.description }
      
      logger.info("Successfully deleted list: \(list.name)")
      
    } catch {
      logger.error("Failed to delete list: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
  
  func confirmDelete(_ list: AppBskyGraphDefs.ListView) {
    listToDelete = list
    showingDeleteConfirmation = true
  }
}

struct ListsManagerView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: ListsManagerViewModel
  @State private var navigationPath = NavigationPath()
  
  init() {
    self._viewModel = State(wrappedValue: ListsManagerViewModel(appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      contentView
        .navigationTitle("My Lists")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button {
              viewModel.showingCreateList = true
            } label: {
              Image(systemName: "plus")
            }
          }
        }
        .onAppear {
          viewModel = ListsManagerViewModel(appState: appState)
          Task {
            await viewModel.loadData()
          }
        }
        .refreshable {
          await viewModel.refreshData()
        }
        .searchable(text: $viewModel.searchText, prompt: "Search your lists")
        .alert("Error", isPresented: $viewModel.showingError) {
          Button("OK") {
            viewModel.showingError = false
          }
        } message: {
          if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
          }
        }
        .alert("Delete List", isPresented: $viewModel.showingDeleteConfirmation) {
          Button("Cancel", role: .cancel) {
            viewModel.listToDelete = nil
          }
          Button("Delete", role: .destructive) {
            if let list = viewModel.listToDelete {
              Task {
                await viewModel.deleteList(list)
              }
            }
            viewModel.listToDelete = nil
          }
        } message: {
          if let list = viewModel.listToDelete {
            Text("Are you sure you want to delete \"\(list.name)\"? This action cannot be undone.")
          }
        }
        .sheet(isPresented: $viewModel.showingCreateList) {
          CreateListView()
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $navigationPath, appState: appState, selectedTab: .constant(0))
        }
    }
  }
  
  @ViewBuilder
  private var contentView: some View {
    if viewModel.isLoading && viewModel.userLists.isEmpty {
      loadingView
    } else if !viewModel.hasLists {
      emptyStateView
    } else {
      listsView
    }
  }
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading your lists...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var emptyStateView: some View {
    VStack(spacing: 24) {
      Image(systemName: "list.bullet.rectangle")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)
      
      VStack(spacing: 8) {
        Text("No Lists Yet")
          .font(.title2)
          .fontWeight(.semibold)
        
        Text("Create your first list to organize and curate accounts")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Button("Create Your First List") {
        viewModel.showingCreateList = true
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var listsView: some View {
    List {
      ForEach(Array(viewModel.groupedLists.keys.sorted()), id: \.self) { category in
        Section(category) {
          ForEach(viewModel.groupedLists[category] ?? [], id: \.uri) { list in
            ListManagerRow(
              list: list,
              onTap: {
                navigationPath.append(NavigationDestination.listFeed(list.uri))
              },
              onEdit: {
                navigationPath.append(NavigationDestination.editList(list.uri))
              },
              onManageMembers: {
                navigationPath.append(NavigationDestination.listMembers(list.uri))
              },
              onDelete: {
                viewModel.confirmDelete(list)
              }
            )
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }
}

// MARK: - Supporting Views

struct ListManagerRow: View {
  let list: AppBskyGraphDefs.ListView
  let onTap: () -> Void
  let onEdit: () -> Void
  let onManageMembers: () -> Void
  let onDelete: () -> Void
  
  var body: some View {
    Button(action: onTap) {
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
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // List Info
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(list.name)
              .font(.subheadline)
              .fontWeight(.medium)
              .foregroundStyle(.primary)
              .lineLimit(1)
            
            Spacer()
            
            purposeIcon
          }
          
          if let description = list.description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          
          HStack {
            Text("\(list.listItemCount ?? 0) members")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            
            Spacer()
            
            // Manage Members button
            Button(action: onManageMembers) {
              Image(systemName: "person.2.badge.gearshape")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(4)
                .background(Circle().fill(.blue.opacity(0.1)))
            }
            .buttonStyle(.plain)
            
            Text(purposeText)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary)
              .clipShape(Capsule())
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        onEdit()
      } label: {
        Label("Edit List", systemImage: "pencil")
      }
      
      Button {
        onManageMembers()
      } label: {
        Label("Manage Members", systemImage: "person.2.badge.gearshape")
      }
      
      Divider()
      
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete List", systemImage: "trash")
      }
    }
  }
  
  private var listPlaceholderIcon: some View {
    RoundedRectangle(cornerRadius: 8)
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
  
  private var purposeText: String {
    switch list.purpose {
    case .appbskygraphdefscuratelist:
      return "Curated"
    case .appbskygraphdefsmodlist:
      return "Moderation"
    case .appbskygraphdefsreferencelist:
      return "Reference"
    default:
      return "Unknown"
    }
  }
}
