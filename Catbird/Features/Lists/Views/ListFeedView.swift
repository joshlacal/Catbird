import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class ListFeedViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  let listURI: ATProtocolURI
  private let logger = Logger(subsystem: "blue.catbird", category: "ListFeedView")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  var members: [AppBskyActorDefs.ProfileView] = []
  
  // State
  var isLoading = false
  var errorMessage: String?
  var showingError = false
  var showingMembersList = false
  
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
      
      logger.info("Loaded list metadata: \(self.members.count) members")
      
    } catch {
      logger.error("Failed to load list metadata: \(error.localizedDescription)")
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
      
      logger.info("Refreshed list metadata")
      
    } catch {
      logger.error("Failed to refresh list metadata: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
}

struct ListFeedView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var vm: ListFeedViewModel?
  @State private var selectedTab: Int = 0
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
        if let listFeedViewModel = ListFeedViewModel(listURIString: listURIString, appState: appState) {
          vm = listFeedViewModel
          await listFeedViewModel.loadInitialData()
        }
      }
    }
  }
  
  @ViewBuilder
  private func contentView(viewModel: ListFeedViewModel) -> some View {
      @Bindable var viewModel = viewModel
    VStack(spacing: 0) {
      // List header with details
      if let listDetails = viewModel.listDetails {
        listHeaderView(listDetails, viewModel: viewModel)
      } else if viewModel.isLoading {
        ProgressView()
          .padding()
      }
      
      // Feed content using FeedView
      FeedView(
        fetch: .list(viewModel.listURI),
        path: $path,
        selectedTab: $selectedTab
      )
    }
    .navigationTitle(viewModel.listDetails?.name ?? "List Feed")
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
            viewModel.showingMembersList = true
          } label: {
            Label("View Members (\(viewModel.members.count))", systemImage: "person.2")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(isPresented: $viewModel.showingMembersList) {
      NavigationStack {
        membersList(viewModel: viewModel)
      }
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
  
  private func listHeaderView(_ listDetails: AppBskyGraphDefs.ListView, viewModel: ListFeedViewModel) -> some View {
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
    .background(.regularMaterial)
  }
  
  private func membersList(viewModel: ListFeedViewModel) -> some View {
    List {
      ForEach(viewModel.members, id: \.did) { member in
        Button {
          path.append(NavigationDestination.profile(member.did.didString()))
          viewModel.showingMembersList = false
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
    .navigationTitle("List Members")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done") {
          viewModel.showingMembersList = false
        }
      }
    }
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
        .fontWeight(.medium)
    }
    .foregroundStyle(colorForPurpose(purpose))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(colorForPurpose(purpose).opacity(0.2))
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
}
