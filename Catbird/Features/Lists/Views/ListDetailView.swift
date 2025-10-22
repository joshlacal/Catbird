import SwiftUI
import Petrel
import OSLog
import NukeUI

enum ListDetailTab: String, CaseIterable {
  case members = "Members"
  case feed = "Feed"
}

@Observable
final class ListDetailViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  let listURI: ATProtocolURI
  private let logger = Logger(subsystem: "blue.catbird", category: "ListDetailView")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  var members: [AppBskyActorDefs.ProfileView] = []
  
  // State
  var isLoading = false
  var errorMessage: String?
  var showingError = false
  var selectedTab: ListDetailTab = .members
  
  // MARK: - Computed Properties
  
  var isOwnList: Bool {
    guard let listDetails = listDetails else { return false }
    return listDetails.creator.did.didString() == appState.currentUserDID
  }
  
  // MARK: - Initialization
  
  init?(listURIString: String, appState: AppState) {
    guard let uri = try? ATProtocolURI(uriString: listURIString) else {
      return nil
    }
    self.listURI = uri
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadInitialData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      // Load list details and members concurrently
      async let listDetailsTask = appState.listManager.getListDetails(listURI.description)
      async let membersTask = appState.listManager.getListMembers(listURI.description)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      logger.info("Loaded list data: \(self.members.count) members")
      
    } catch {
      logger.error("Failed to load list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  @MainActor
  func refreshData() async {
    do {
      // Refresh list details and members
      async let listDetailsTask = appState.listManager.getListDetails(listURI.description, forceRefresh: true)
      async let membersTask = appState.listManager.getListMembers(listURI.description, forceRefresh: true)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      logger.info("Refreshed list data")
      
    } catch {
      logger.error("Failed to refresh list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
}

struct ListDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var vm: ListDetailViewModel?
  @State private var feedSelectedTab: Int = 0
  @Binding var path: NavigationPath
  
  let listURIString: String
  
  init(listURIString: String, path: Binding<NavigationPath>) {
    self.listURIString = listURIString
    self._path = path
  }
  
  var body: some View {
    Group {
      if let viewModel = vm {
        contentView(viewModel: viewModel)
      } else {
        errorView
      }
    }
    .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
    .task {
      if vm == nil {
        if let listDetailViewModel = ListDetailViewModel(listURIString: listURIString, appState: appState) {
          vm = listDetailViewModel
          await listDetailViewModel.loadInitialData()
        }
      }
    }
  }
  
  @ViewBuilder
  private func contentView(viewModel: ListDetailViewModel) -> some View {
    @Bindable var viewModel = viewModel
    
    VStack(spacing: 0) {
      // List header with details
      if let listDetails = viewModel.listDetails {
        listHeaderView(listDetails, viewModel: viewModel)
      } else if viewModel.isLoading {
        ProgressView()
          .padding()
      }
      
      // Tab Picker
      Picker("View", selection: $viewModel.selectedTab) {
        ForEach(ListDetailTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color(UIColor.systemGroupedBackground))
      
      // Tab Content
      TabView(selection: $viewModel.selectedTab) {
        membersView(viewModel: viewModel)
          .tag(ListDetailTab.members)
        
        feedView(viewModel: viewModel)
          .tag(ListDetailTab.feed)
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
    }
    .navigationTitle(viewModel.listDetails?.name ?? "List")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          if viewModel.isOwnList {
            Button {
              path.append(NavigationDestination.editList(viewModel.listURI))
            } label: {
              Label("Edit List", systemImage: "pencil")
            }
            
            Button {
              path.append(NavigationDestination.listMembers(viewModel.listURI))
            } label: {
              Label("Manage Members", systemImage: "person.2.badge.gearshape")
            }
          }
          
          Button {
            Task { await viewModel.refreshData() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .refreshable {
      await viewModel.refreshData()
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
  }
  
  private var errorView: some View {
    ContentUnavailableView(
      "Invalid List",
      systemImage: "exclamationmark.triangle",
      description: Text("This list URI is invalid or cannot be loaded.")
    )
  }
  
  private func listHeaderView(_ listDetails: AppBskyGraphDefs.ListView, viewModel: ListDetailViewModel) -> some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        // List Avatar
        LazyImage(url: listDetails.avatar?.url) { state in
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
          HStack(spacing: 8) {
            Text(listDetails.name)
              .font(.headline)
              .fontWeight(.semibold)
              .lineLimit(1)
            
            purposeBadge(listDetails.purpose)
          }
          
          if let description = listDetails.description, !description.isEmpty {
            Text(description)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          
          HStack(spacing: 16) {
            Text("\(viewModel.members.count) members")
              .font(.caption)
              .foregroundStyle(.tertiary)
            
            Text("by @\(listDetails.creator.handle)")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      
      Divider()
    }
    .background(Color(UIColor.systemGroupedBackground))
  }
  
  @ViewBuilder
  private func membersView(viewModel: ListDetailViewModel) -> some View {
    List {
      if viewModel.members.isEmpty {
        ContentUnavailableView(
          "No Members",
          systemImage: "person.2.slash",
          description: Text("This list doesn't have any members yet.")
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
        ForEach(viewModel.members, id: \.did) { member in
          Button {
            path.append(NavigationDestination.profile(member.did.didString()))
          } label: {
            HStack(spacing: 12) {
              LazyImage(url: member.avatar?.url) { state in
                if let image = state.image {
                  image
                    .resizable()
                    .scaledToFill()
                } else {
                  Circle()
                    .fill(.secondary.opacity(0.3))
                }
              }
              .frame(width: 40, height: 40)
              .clipShape(Circle())
              
              VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? member.handle.description)
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .foregroundStyle(.primary)
                
                Text("@\(member.handle)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              
              Spacer()
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.plain)
    #if os(iOS)
    .scrollContentBackground(.hidden)
    #endif
  }
  
  @ViewBuilder
  private func feedView(viewModel: ListDetailViewModel) -> some View {
    FeedView(
      fetch: .list(viewModel.listURI),
      path: $path,
      selectedTab: $feedSelectedTab
    )
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
  
  private func purposeBadge(_ purpose: AppBskyGraphDefs.ListPurpose) -> some View {
    HStack(spacing: 4) {
      Image(systemName: iconForPurpose(purpose))
        .font(.caption2)
      Text(textForPurpose(purpose))
        .font(.caption2)
    }
    .foregroundStyle(colorForPurpose(purpose))
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(colorForPurpose(purpose).opacity(0.15))
    .clipShape(Capsule())
  }
  
  private func iconForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
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
  
  private func colorForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> Color {
    switch purpose {
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
  
  private func textForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
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
