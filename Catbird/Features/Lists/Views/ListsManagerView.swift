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
  
  /// People lists first, then moderation lists, then anything else.
  var sortedCategories: [String] {
    let order = ["People Lists", "Moderation Lists", "Other Lists"]
    return groupedLists.keys.sorted {
      (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
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
  @Environment(AppState.self) private var appState
  @State private var viewModel: ListsManagerViewModel?

  /// True when shown inside Settings › Moderation. The Settings sheet has its own navigation
  /// stack, so rows push there instead of onto the tab behind the sheet, and only moderation
  /// lists are shown to match the Settings row.
  private let isHostedInSettings: Bool
  
  init(isHostedInSettings: Bool = false) {
    self.isHostedInSettings = isHostedInSettings
  }
  
  var body: some View {
    Group {
      if let viewModel {
        ListsManagerContent(viewModel: viewModel, isHostedInSettings: isHostedInSettings)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
    .navigationTitle(isHostedInSettings ? "Moderation Lists" : "My Lists")
    .modifier(ListsManagerTitleDisplayModifier(isInline: isHostedInSettings))
    .environment(\.listsUseLocalNavigation, isHostedInSettings)
    .task {
      guard viewModel == nil else { return }
      let model = ListsManagerViewModel(
        appState: appState,
        purposeFilter: isHostedInSettings ? .appbskygraphdefsmodlist : nil
      )
      viewModel = model
      await model.loadData()
    }
  }
}

// MARK: - Content

/// The loaded screen. Takes a non-optional view model so its bindings and modifiers stay simple.
private struct ListsManagerContent: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Bindable var viewModel: ListsManagerViewModel
  let isHostedInSettings: Bool
  @State private var localDestination: ListLocalDestination?

  var body: some View {
    content
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            viewModel.showingCreateList = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New List")
        }
      }
      .listLocalNavigationDestination($localDestination)
      .refreshable {
        await viewModel.refreshData()
      }
      .searchable(text: $viewModel.searchText, prompt: "Search your lists")
      .modifier(ListsManagerPresentations(viewModel: viewModel, isHostedInSettings: isHostedInSettings))
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.userLists.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !viewModel.hasLists {
      emptyStateView
    } else if viewModel.filteredLists.isEmpty {
      ContentUnavailableView.search(text: viewModel.searchText)
    } else {
      listsView
    }
  }

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label(
        isHostedInSettings ? "No Moderation Lists Yet" : "No Lists Yet",
        systemImage: "list.bullet.rectangle"
      )
    } description: {
      Text(isHostedInSettings
        ? "Create a moderation list to mute or block a group of accounts at once."
        : "Create your first list to organize and curate accounts.")
    } actions: {
      Button("Create List") {
        viewModel.showingCreateList = true
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var listsView: some View {
    let groupedLists = viewModel.groupedLists
    return List {
      ForEach(viewModel.sortedCategories, id: \.self) { category in
        Section(category) {
          ForEach(groupedLists[category] ?? [], id: \.uri) { list in
            ListManagerRow(
              list: list,
              onNavigate: { navigate(to: $0) },
              onDelete: { viewModel.confirmDelete(list) }
            )
          }
        }
      }
    }
    .modifier(ListsManagerListStyleModifier())
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
}

// MARK: - Presentations

/// Error and delete alerts plus the create-list sheet.
private struct ListsManagerPresentations: ViewModifier {
  @Bindable var viewModel: ListsManagerViewModel
  let isHostedInSettings: Bool

  func body(content: Content) -> some View {
    content
      .alert("Something Went Wrong", isPresented: $viewModel.showingError) {
        Button("OK") {
          viewModel.showingError = false
        }
      } message: {
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
        }
      }
      .alert("Delete List", isPresented: $viewModel.showingDeleteConfirmation, presenting: viewModel.listToDelete) { list in
        Button("Cancel", role: .cancel) {
          viewModel.listToDelete = nil
        }
        Button("Delete", role: .destructive) {
          viewModel.listToDelete = nil
          Task { await viewModel.deleteList(list) }
        }
      } message: { list in
        Text("Delete “\(list.name)”? This can’t be undone.")
      }
      .sheet(isPresented: $viewModel.showingCreateList, onDismiss: {
        viewModel.syncFromCache()
      }) {
        CreateListView(initialPurpose: isHostedInSettings ? .appbskygraphdefsmodlist : .appbskygraphdefscuratelist)
      }
  }
}

private struct ListsManagerListStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
    #else
    content
      .listStyle(.inset)
    #endif
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
      ListSummaryRow(list: list)
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete List", systemImage: "trash")
      }

      Button {
        onNavigate(.edit(list.uri))
      } label: {
        Label("Edit List", systemImage: "pencil")
      }
      .tint(.accentColor)
    }
    .swipeActions(edge: .leading) {
      Button {
        onNavigate(.members(list.uri))
      } label: {
        Label("Manage Members", systemImage: "person.2.badge.gearshape")
      }
      .tint(.indigo)
    }
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
