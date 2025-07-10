import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class ListMemberManagementViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let listURI: String
  private let logger = Logger(subsystem: "blue.catbird", category: "ListMemberManagement")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  var members: [AppBskyActorDefs.ProfileView] = []
  var searchResults: [AppBskyActorDefs.ProfileView] = []
  
  // State
  var isLoading = false
  var isSearching = false
  var searchText = ""
  var errorMessage: String?
  var showingError = false
  
  // Operations tracking
  private var operationsInProgress: Set<String> = []
  
  // Search debounce
  private var searchTask: Task<Void, Never>?
  
  // MARK: - Computed Properties
  
  var canAddMembers: Bool {
    guard let listDetails = listDetails else { return false }
    // Only allow adding members to own lists or lists with appropriate permissions
    guard let currentUserDID = appState.currentUserDID else { return false }
    return listDetails.creator.did.didString() == currentUserDID
  }
  
  var filteredSearchResults: [AppBskyActorDefs.ProfileView] {
    // Filter out users who are already members
    let memberDIDs = Set(members.map { $0.did.didString() })
    return searchResults.filter { !memberDIDs.contains($0.did.didString()) }
  }
  
  // MARK: - Initialization
  
  init(listURI: String, appState: AppState) {
    self.listURI = listURI
    self.appState = appState
    logger.info("ListMemberManagementViewModel initialized with URI: \(listURI)")
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadData() async {
    guard !isLoading else { return }
    
    logger.info("Starting to load data for list: \(self.listURI)")
    
    isLoading = true
    errorMessage = nil
    
    do {
      // Wait for client to be available (with timeout)
      var attempts = 0
      let maxAttempts = 50 // 5 seconds max wait
      while appState.atProtoClient == nil && attempts < maxAttempts {
        logger.debug("Waiting for ATProto client to initialize (attempt \(attempts + 1)/\(maxAttempts))")
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        attempts += 1
      }
      
      // Final validation that we have a client
      guard appState.atProtoClient != nil else {
        logger.error("ATProto client not available after waiting")
        throw ListError.clientNotInitialized
      }
      
      logger.debug("ATProto client available, proceeding with data load")
      
      // Load list details and members concurrently
      async let listDetailsTask = appState.listManager.getListDetails(listURI)
      async let membersTask = appState.listManager.getListMembers(listURI)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      logger.info("Successfully loaded list data: \(self.members.count) members for list '\(self.listDetails?.name ?? "Unknown")'")
      
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
      // Force refresh from server
      listDetails = try await appState.listManager.getListDetails(listURI, forceRefresh: true)
      members = try await appState.listManager.getListMembers(listURI, forceRefresh: true)
      
      logger.info("Refreshed list data: \(self.members.count) members")
      
    } catch {
      logger.error("Failed to refresh list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
  
  // MARK: - Search
  
  func searchUsers() {
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
      try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
      
      guard !Task.isCancelled else { return }
      
      await performSearch(query: query)
    }
  }
  
  @MainActor
  private func performSearch(query: String) async {
    guard let client = appState.atProtoClient else { return }
    
    isSearching = true
    
    do {
      let (responseCode, searchData) = try await client.app.bsky.actor.searchActors(
        input: .init(
          term: query,
          limit: 20,
          cursor: nil
        )
      )
      
      guard responseCode == 200, let searchData = searchData else {
        logger.warning("Search returned invalid response")
        return
      }
      
      searchResults = searchData.actors as [AppBskyActorDefs.ProfileView]
      logger.debug("Search found \(searchData.actors.count) users for query: \(query)")
      
    } catch {
      logger.error("Search failed: \(error.localizedDescription)")
    }
    
    isSearching = false
  }
  
  // MARK: - Member Management
  
  @MainActor
  func addMember(_ userDID: String) async {
    guard !operationsInProgress.contains(userDID) else { return }
    
    operationsInProgress.insert(userDID)
    defer { operationsInProgress.remove(userDID) }
    
    do {
      try await appState.listManager.addMember(userDID: userDID, to: listURI)
      
      // Refresh members list
      members = try await appState.listManager.getListMembers(listURI, forceRefresh: true)
      
      // Remove from search results
      searchResults.removeAll { $0.did.didString() == userDID }
      
      logger.info("Successfully added member: \(userDID)")
      
    } catch {
      logger.error("Failed to add member: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
  
  @MainActor
  func removeMember(_ userDID: String) async {
    guard !operationsInProgress.contains(userDID) else { return }
    
    operationsInProgress.insert(userDID)
    defer { operationsInProgress.remove(userDID) }
    
    do {
      try await appState.listManager.removeMember(userDID: userDID, from: listURI)
      
      // Refresh members list
      members = try await appState.listManager.getListMembers(listURI, forceRefresh: true)
      
      logger.info("Successfully removed member: \(userDID)")
      
    } catch {
      logger.error("Failed to remove member: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
  
  func isOperationInProgress(for userDID: String) -> Bool {
    operationsInProgress.contains(userDID)
  }
}

struct ListMemberManagementView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: ListMemberManagementViewModel?
  @State private var showingMemberOptions = false
  @State private var selectedMember: AppBskyActorDefs.ProfileView?
  @State private var initializationFailed = false
  @State private var errorMessage: String?
  
  let listURI: String
  
  init(listURI: String) {
    self.listURI = listURI
    print("🔵 ListMemberManagementView init with URI: \(listURI)")
  }
  
  var body: some View {
    Group {
      if initializationFailed {
        errorView
      } else if let viewModel = viewModel {
        contentView(viewModel: viewModel)
      } else {
        loadingView
      }
    }
    .onAppear {
      Task { @MainActor in
        await initializeView()
      }
    }
  }
  
  @ViewBuilder
  private func contentView(viewModel: ListMemberManagementViewModel) -> some View {
    VStack(spacing: 0) {
      // Search Section
      if viewModel.canAddMembers {
        searchSection
      }
      
      // Content
      if viewModel.isLoading && viewModel.members.isEmpty {
        loadingView
      } else {
        membersListView
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        if !viewModel.members.isEmpty {
          Menu {
            Button("Refresh") {
              Task {
                await viewModel.refreshData()
              }
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
    .alert("Error", isPresented: Binding(
      get: { viewModel.showingError },
      set: { _ in viewModel.showingError = false }
    )) {
      Button("OK") {
        viewModel.showingError = false
      }
      
      // Add retry button for client initialization errors
      if viewModel.errorMessage?.contains("ATProto client not initialized") == true {
        Button("Retry") {
          viewModel.showingError = false
          Task {
            await viewModel.loadData()
          }
        }
      }
    } message: {
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
      }
    }
    .refreshable {
      await viewModel.refreshData()
    }
  }
  
  private var errorView: some View {
    VStack(spacing: 20) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundStyle(.red)
      
      Text("Failed to Initialize")
        .font(.title2)
        .fontWeight(.semibold)
      
      if let errorMessage = errorMessage {
        Text(errorMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Button("Retry") {
        Task { @MainActor in
          await initializeView()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  @MainActor
  private func initializeView() async {
    print("🔵 ListMemberManagementView initializeView started")
    print("🔵 Input listURI: '\(listURI)'")
    print("🔵 appState.isAuthenticated: \(appState.isAuthenticated)")
    print("🔵 appState.atProtoClient != nil: \(appState.atProtoClient != nil)")
    
    // Reset state
    initializationFailed = false
    errorMessage = nil
    
    do {
      // Validate URI format
      print("🔵 Validating URI format...")
      guard !listURI.isEmpty && listURI.contains("at://") else {
        print("🔴 URI validation failed: empty=\(!listURI.isEmpty), contains-at=\(listURI.contains("at://"))")
        throw InitializationError.invalidURI(listURI)
      }
      print("🔵 URI validation passed")
      
      // Check authentication
      print("🔵 Checking authentication...")
      guard appState.isAuthenticated else {
        print("🔴 Authentication check failed")
        throw InitializationError.notAuthenticated
      }
      print("🔵 Authentication check passed")
      
      // Wait for client to be available (with reasonable timeout)
      print("🔵 Waiting for ATProto client...")
      var attempts = 0
      let maxAttempts = 30 // 3 seconds max wait
      while appState.atProtoClient == nil && attempts < maxAttempts {
        print("🔵 Waiting for ATProto client (attempt \(attempts + 1)/\(maxAttempts))")
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        attempts += 1
      }
      
      guard appState.atProtoClient != nil else {
        print("🔴 ATProto client not available after waiting")
        throw InitializationError.clientNotAvailable
      }
      print("🔵 ATProto client is available")
      
      // Create viewModel with consistent AppState
      print("🔵 Creating viewModel with consistent AppState")
      viewModel = ListMemberManagementViewModel(listURI: listURI, appState: appState)
      
      // Load data
      print("🔵 Loading initial data")
      await viewModel?.loadData()
      
      print("🔵 ListMemberManagementView initialization successful")
      
    } catch {
      print("🔴 ListMemberManagementView initialization failed: \(error)")
      initializationFailed = true
      errorMessage = error.localizedDescription
    }
  }
  
  // MARK: - Search Section
  
  @ViewBuilder
  private var searchSection: some View {
    if let viewModel = viewModel {
      VStack(spacing: 12) {
        // Search bar
        HStack {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          
          TextField("Search users to add...", text: Binding(
            get: { viewModel.searchText },
            set: { newValue in
              viewModel.searchText = newValue
              viewModel.searchUsers()
            }
          ))
          .textFieldStyle(.plain)
          .onSubmit {
            viewModel.searchUsers()
          }
          
          if viewModel.isSearching {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        
        // Search Results
        if !viewModel.filteredSearchResults.isEmpty {
          LazyVStack(spacing: 8) {
            ForEach(viewModel.filteredSearchResults, id: \.did) { user in
              SearchResultRow(
                user: user,
                isAddingInProgress: viewModel.isOperationInProgress(for: user.did.didString())
              ) {
                Task {
                  await viewModel.addMember(user.did.didString())
                }
              }
            }
          }
          .padding(.top, 8)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.ultraThinMaterial)
    }
  }
  
  // MARK: - Members List
  
  @ViewBuilder
  private var membersListView: some View {
    if let viewModel = viewModel {
      List {
        if viewModel.members.isEmpty {
          emptyStateView
        } else {
          Section {
            ForEach(viewModel.members, id: \.did) { member in
              MemberRow(
                member: member,
                canRemove: viewModel.canAddMembers,
                isRemovingInProgress: viewModel.isOperationInProgress(for: member.did.didString())
              ) {
                Task {
                  await viewModel.removeMember(member.did.didString())
                }
              } onTap: {
                // Navigate to profile
                appState.navigationManager.navigate(to: .profile(member.did.didString()), in: nil)
              }
            }
          } header: {
            Text("\(viewModel.members.count) Members")
          }
        }
      }
      .listStyle(.insetGrouped)
    }
  }
  
  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(systemName: "person.2")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      
      Text("No Members Yet")
        .font(.headline)
      
      Text("Start building your list by searching for and adding users")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      
      if let viewModel = viewModel, viewModel.isLoading {
        Text("Loading members...")
          .font(.headline)
          .foregroundStyle(.secondary)
      } else {
        Text("Initializing...")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Supporting Views

struct SearchResultRow: View {
  let user: AppBskyActorDefs.ProfileView
  let isAddingInProgress: Bool
  let onAdd: () -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      // Avatar
        LazyImage(url: user.finalAvatarURL()) { state in
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
      
      // Profile Info
      VStack(alignment: .leading, spacing: 2) {
        Text(user.displayName ?? user.handle.description)
          .font(.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)
        
        Text("@\(user.handle)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      
      Spacer()
      
      // Add Button
      Button(action: onAdd) {
        HStack(spacing: 4) {
          if isAddingInProgress {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Image(systemName: "plus")
          }
          Text("Add")
        }
        .font(.caption)
        .fontWeight(.medium)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isAddingInProgress)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

struct MemberRow: View {
  let member: AppBskyActorDefs.ProfileView
  let canRemove: Bool
  let isRemovingInProgress: Bool
  let onRemove: () -> Void
  let onTap: () -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      // Avatar
      LazyImage(url: member.finalAvatarURL()) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          Circle()
            .fill(.secondary.opacity(0.3))
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(Circle())
      
      // Profile Info
      VStack(alignment: .leading, spacing: 2) {
        Text(member.displayName ?? member.handle.description)
          .font(.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)
        
        Text("@\(member.handle)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        
        if let description = member.description, !description.isEmpty {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.top, 1)
        }
      }
      
      Spacer()
      
      // Remove Button
      if canRemove {
        Button(action: onRemove) {
          if isRemovingInProgress {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Image(systemName: "minus.circle.fill")
              .foregroundStyle(.red)
          }
        }
        .buttonStyle(.plain)
        .disabled(isRemovingInProgress)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      onTap()
    }
  }
}

enum InitializationError: LocalizedError {
  case invalidURI(String)
  case notAuthenticated
  case clientNotAvailable
  
  var errorDescription: String? {
    switch self {
    case .invalidURI(let uri):
      return "Invalid list URI: \(uri)"
    case .notAuthenticated:
      return "Please log in to manage list members"
    case .clientNotAvailable:
      return "Network client not available. Please try again."
    }
  }
}
