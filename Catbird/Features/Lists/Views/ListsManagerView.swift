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
  /// When set, only lists with this purpose are shown.
  let purposeFilter: AppBskyGraphDefs.ListPurpose?
  
  // MARK: - Computed Properties
  
  /// Lists this screen manages. Starter pack backing lists are edited with their starter pack.
  private var manageableLists: [AppBskyGraphDefs.ListView] {
    userLists.filter { list in
      guard list.purpose != .appbskygraphdefsreferencelist else { return false }
      guard let purposeFilter else { return true }
      return list.purpose == purposeFilter
    }
  }

  var hasLists: Bool {
    !manageableLists.isEmpty
  }

  var filteredLists: [AppBskyGraphDefs.ListView] {
    if searchText.isEmpty {
      return manageableLists
    } else {
      let searchTerm = searchText.lowercased()
      return manageableLists.filter { list in
        list.name.lowercased().contains(searchTerm) ||
        (list.description?.lowercased().contains(searchTerm) ?? false)
      }
    }
  }
  
  var groupedLists: [String: [AppBskyGraphDefs.ListView]] {
    Dictionary(grouping: filteredLists) { list in
      switch list.purpose {
      case .appbskygraphdefscuratelist:
        return "People Lists"
      case .appbskygraphdefsmodlist:
        return "Moderation Lists"
      default:
        return "Other Lists"
      }
    }
  }
  
  // MARK: - Initialization
  
  init(appState: AppState, purposeFilter: AppBskyGraphDefs.ListPurpose? = nil) {
    self.appState = appState
    self.purposeFilter = purposeFilter
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
  
  /// Picks up lists created from this screen, which `ListManager` adds to its cache.
  @MainActor
  func syncFromCache() {
    userLists = appState.listManager.userLists
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
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: ListsManagerViewModel?
  @State private var localDestination: ListLocalDestination?

  /// True when shown inside Settings › Moderation. The Settings sheet has its own navigation
  /// stack, so rows push there instead of onto the tab behind the sheet, and only moderation
  /// lists are shown to match the Settings row.
  private let isHostedInSettings: Bool
  
  init(isHostedInSettings: Bool = false) {
    self.isHostedInSettings = isHostedInSettings
  }
  
  var body: some View {
    Group {
      if let viewModel = viewModel {
        contentView(viewModel: viewModel)
      } else {
        ProgressView()
      }
    }
    .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
    .navigationTitle(isHostedInSettings ? "Moderation Lists" : "My Lists")
    .modifier(ListsManagerTitleDisplayModifier(isInline: isHostedInSettings))
    .toolbar {
      if let viewModel = viewModel {
        ToolbarItem(placement: .primaryAction) {
          Button {
            viewModel.showingCreateList = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New List")
        }
      }
    }
    .listLocalNavigationDestination($localDestination)
    .environment(\.listsUseLocalNavigation, isHostedInSettings)
    .task {
      if viewModel == nil {
        viewModel = ListsManagerViewModel(
          appState: appState,
          purposeFilter: isHostedInSettings ? .appbskygraphdefsmodlist : nil
        )
        await viewModel?.loadData()
      }
    }
    .refreshable {
      await viewModel?.refreshData() ?? ()
    }
    .searchable(text: Binding(
      get: { viewModel?.searchText ?? "" },
      set: { viewModel?.searchText = $0 }
    ), prompt: "Search your lists")
    .alert("Something Went Wrong", isPresented: Binding(
      get: { viewModel?.showingError ?? false },
      set: { if !$0 { viewModel?.showingError = false } }
    )) {
      Button("OK") {
        viewModel?.showingError = false
      }
    } message: {
      if let errorMessage = viewModel?.errorMessage {
        Text(errorMessage)
      }
    }
    .alert("Delete List", isPresented: Binding(
      get: { viewModel?.showingDeleteConfirmation ?? false },
      set: { if !$0 { viewModel?.showingDeleteConfirmation = false } }
    )) {
      Button("Cancel", role: .cancel) {
        viewModel?.listToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let list = viewModel?.listToDelete {
          Task {
            await viewModel?.deleteList(list)
          }
        }
        viewModel?.listToDelete = nil
      }
    } message: {
      if let list = viewModel?.listToDelete {
        Text("Delete “\(list.name)”? This can’t be undone.")
      }
    }
    .sheet(isPresented: Binding(
      get: { viewModel?.showingCreateList ?? false },
      set: { if !$0 { viewModel?.showingCreateList = false } }
    ), onDismiss: {
      viewModel?.syncFromCache()
    }) {
      CreateListView(initialPurpose: isHostedInSettings ? .appbskygraphdefsmodlist : .appbskygraphdefscuratelist)
    }
  }

  private func navigate(to destination: ListLocalDestination) {
    if isHostedInSettings {
      localDestination = destination
      return
    }
    switch destination {
    case .detail(let uri):
      sceneContext.navigationManager.navigate(to: .listFeed(uri))
    case .edit(let uri):
      sceneContext.navigationManager.navigate(to: .editList(uri))
    case .members(let uri):
      sceneContext.navigationManager.navigate(to: .listMembers(uri))
    }
  }
  
  @ViewBuilder
  private func contentView(viewModel: ListsManagerViewModel) -> some View {
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
      Text("Loading your lists…")
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
        Text(isHostedInSettings ? "No Moderation Lists Yet" : "No Lists Yet")
          .font(.title2)
          .fontWeight(.semibold)
        
        Text(isHostedInSettings
          ? "Create a moderation list to mute or block a group of accounts at once."
          : "Create your first list to organize and curate accounts.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Button("Create Your First List") {
        viewModel?.showingCreateList = true
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  @ViewBuilder
  private var listsView: some View {
    if let viewModel = viewModel {
      let sortedCategories = Array(viewModel.groupedLists.keys.sorted())
      List {
        ForEach(sortedCategories, id: \.self) { category in
          let categoryLists = viewModel.groupedLists[category] ?? []
          Section(category) {
            ForEach(categoryLists, id: \.uri) { list in
              ListManagerRow(
                list: list,
                onNavigate: { navigate(to: $0) },
                onDelete: {
                  viewModel.confirmDelete(list)
                }
              )
            }
          }
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      #elseif os(macOS)
      .listStyle(.inset)
      #endif
    }
  }
}

// MARK: - Supporting Views

struct ListManagerRow: View {
  @Environment(AppState.self) private var appState
  let list: AppBskyGraphDefs.ListView
  let onNavigate: (ListLocalDestination) -> Void
  let onDelete: () -> Void
  
  var body: some View {
    Button {
      onNavigate(.detail(list.uri))
    } label: {
      HStack(spacing: 12) {
        // List Avatar
        LazyImage(url: list.finalAvatarURL()) { state in
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
            Text("^[\(list.listItemCount ?? 0) member](inflect: true)")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            
            Spacer()
            
            // Manage Members button
            Button(action: {
              onNavigate(.members(list.uri))
            }) {
              Image(systemName: "person.2.badge.gearshape")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(4)
                .background(Circle().fill(.blue.opacity(0.1)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage Members")
            
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
        onNavigate(.edit(list.uri))
      } label: {
        Label("Edit List", systemImage: "pencil")
      }
      
      Button {
        onNavigate(.members(list.uri))
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
      return "People"
    case .appbskygraphdefsmodlist:
      return "Moderation"
    case .appbskygraphdefsreferencelist:
      return "Reference"
    default:
      return "Unknown"
    }
  }
}

private struct ListsManagerTitleDisplayModifier: ViewModifier {
  let isInline: Bool

  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbarTitleDisplayMode(isInline ? .inline : .large)
    #else
    content
    #endif
  }
}

#Preview("ListsManagerView") {
  NavigationStack {
    ListsManagerView()
  }
  .previewWithAuthenticatedState()
}
