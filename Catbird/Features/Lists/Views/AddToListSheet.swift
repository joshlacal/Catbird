import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class AddToListSheetViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let userDID: String
  private let logger = Logger(subsystem: "blue.catbird", category: "AddToListSheet")
  
  // Data
  var userLists: [AppBskyGraphDefs.ListView] = []
  var membershipStatus: [String: Bool] = [:] // listURI -> isMember
  
  // State
  var isLoading = false
  var errorMessage: String?
  var showingError = false
  var showingCreateList = false
  
  // Operations
  private var operationsInProgress: Set<String> = []
  
  // MARK: - Computed Properties
  
  var hasLists: Bool {
    !userLists.isEmpty
  }
  
  // MARK: - Initialization
  
  init(userDID: String, appState: AppState) {
    self.userDID = userDID
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      // Load user's lists
      userLists = try await appState.listManager.loadUserLists()
      
      // Check membership status for each list
      for list in userLists {
        let isMember = try await appState.listManager.isUserMember(
          userDID: userDID,
          of: list.uri.description
        )
        membershipStatus[list.uri.description] = isMember
      }
      
        logger.info("Loaded \(self.userLists.count) lists for add-to-list sheet")
      
    } catch {
      logger.error("Failed to load lists: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  // MARK: - List Operations
  
  @MainActor
  func toggleMembership(for listURI: String) async {
    guard !operationsInProgress.contains(listURI) else { return }
    
    operationsInProgress.insert(listURI)
    defer { operationsInProgress.remove(listURI) }
    
    let currentlyMember = membershipStatus[listURI] ?? false
    
    do {
      if currentlyMember {
        // Remove from list
        try await appState.listManager.removeMember(userDID: userDID, from: listURI)
        membershipStatus[listURI] = false
        logger.info("Removed user from list: \(listURI)")
      } else {
        // Add to list
        try await appState.listManager.addMember(userDID: userDID, to: listURI)
        membershipStatus[listURI] = true
        logger.info("Added user to list: \(listURI)")
      }
      
    } catch {
      logger.error("Failed to toggle membership: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
  
  func isOperationInProgress(for listURI: String) -> Bool {
    operationsInProgress.contains(listURI)
  }
  
  func isMember(of listURI: String) -> Bool {
    membershipStatus[listURI] ?? false
  }
}

struct AddToListSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: AddToListSheetViewModel
  
  let userDID: String
  let userHandle: String
  let userDisplayName: String?
  
  init(userDID: String, userHandle: String, userDisplayName: String? = nil) {
    self.userDID = userDID
    self.userHandle = userHandle
    self.userDisplayName = userDisplayName
    self._viewModel = State(wrappedValue: AddToListSheetViewModel(userDID: userDID, appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack {
      contentView
        .navigationTitle("Add to List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
              dismiss()
            }
          }
          
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("New List") {
              viewModel.showingCreateList = true
            }
          }
        }
        .onAppear {
          viewModel = AddToListSheetViewModel(userDID: userDID, appState: appState)
          Task {
            await viewModel.loadData()
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
        .sheet(isPresented: $viewModel.showingCreateList) {
          CreateListView()
        }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
  
  @ViewBuilder
  private var contentView: some View {
    if viewModel.isLoading {
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
    VStack(spacing: 20) {
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
    VStack(spacing: 0) {
      // User Info Header
      userInfoHeader
      
      // Lists
      List {
        Section {
          ForEach(viewModel.userLists, id: \.uri) { list in
            ListSelectionRow(
              list: list,
              isMember: viewModel.isMember(of: list.uri.description),
              isOperationInProgress: viewModel.isOperationInProgress(for: list.uri.description)
            ) {
              Task {
                await viewModel.toggleMembership(for: list.uri.description)
              }
            }
          }
        } header: {
          Text("Your Lists")
        }
      }
      .listStyle(.insetGrouped)
    }
  }
  
  private var userInfoHeader: some View {
    HStack(spacing: 12) {
      // List avatar
      Circle()
        .fill(.secondary.opacity(0.3))
        .frame(width: 40, height: 40)
        .overlay {
          Text(String((userDisplayName ?? userHandle).prefix(1)).uppercased())
            .font(.headline)
            .fontWeight(.semibold)
        }
      
      VStack(alignment: .leading, spacing: 2) {
        Text(userDisplayName ?? userHandle)
          .font(.subheadline)
          .fontWeight(.medium)
        
        Text("@\(userHandle)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.regularMaterial)
  }
}

struct ListSelectionRow: View {
  let list: AppBskyGraphDefs.ListView
  let isMember: Bool
  let isOperationInProgress: Bool
  let onToggle: () -> Void
  
  var body: some View {
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
      .frame(width: 36, height: 36)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      
      // List Info
      VStack(alignment: .leading, spacing: 2) {
        Text(list.name)
          .font(.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)
        
        if let description = list.description, !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        
        Text("\(list.listItemCount ?? 0) members")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      
      Spacer()
      
      // Toggle Button
      Button(action: onToggle) {
        HStack(spacing: 4) {
          if isOperationInProgress {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Image(systemName: isMember ? "checkmark.circle.fill" : "plus.circle")
              .foregroundStyle(isMember ? .green : .blue)
          }
        }
      }
      .buttonStyle(.plain)
      .disabled(isOperationInProgress)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if !isOperationInProgress {
        onToggle()
      }
    }
  }
  
  private var listPlaceholderIcon: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(.secondary.opacity(0.3))
      .overlay {
        Image(systemName: "list.bullet")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
  }
}
