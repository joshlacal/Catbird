import CatbirdMLSCore
import NukeUI
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

/// Search and add members to an MLS group conversation.
/// Pushed within MLSGroupDetailView's NavigationStack — does not wrap itself in another one.
struct MLSAddMemberView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let conversationId: String
  let conversationManager: MLSConversationManager
  let existingMemberDIDs: Set<String>

  @State private var viewModel: MLSAddMemberViewModel?
  @State private var searchText = ""
  @State private var showingError = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSAddMemberView")

  var body: some View {
    List {
      if let viewModel {
        listContent(viewModel: viewModel)
      }
    }
    .navigationTitle("Add Members")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search by name or handle")
    .onChange(of: searchText) { _, newValue in
      viewModel?.searchQuery = newValue
    }
    .overlay {
      if viewModel?.isAddingMember == true {
        addingOverlay
      }
    }
    .alert("Failed to Add Member", isPresented: $showingError) {
      Button("OK", role: .cancel) {}
    } message: {
      if let error = viewModel?.error {
        Text(error.localizedDescription)
      }
    }
    .task {
      viewModel = MLSAddMemberViewModel(
        conversationId: conversationId,
        conversationManager: conversationManager,
        existingMemberDIDs: existingMemberDIDs
      )
    }
    .onChange(of: viewModel?.didAddMember) { _, didAdd in
      if didAdd == true {
        dismiss()
      }
    }
  }

  // MARK: - List Content

  @ViewBuilder
  private func listContent(viewModel: MLSAddMemberViewModel) -> some View {
    if searchText.isEmpty {
      emptySearchSection
    } else if viewModel.isSearching {
      searchingSection
    } else if viewModel.searchResults.isEmpty {
      noResultsSection
    } else {
      resultsSection(viewModel: viewModel)
    }
  }

  private var emptySearchSection: some View {
    Section {
      Text("Search for people to add to this group.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
    }
  }

  private var searchingSection: some View {
    Section {
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
    }
  }

  private var noResultsSection: some View {
    Section {
      Text("No results found")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
    }
  }

  @ViewBuilder
  private func resultsSection(viewModel: MLSAddMemberViewModel) -> some View {
    Section {
      ForEach(viewModel.searchResults) { participant in
        let isOptedIn = viewModel.participantOptInStatus[participant.id] ?? false
        Button {
          guard isOptedIn else { return }
          Task { await addMember(participant) }
        } label: {
          searchResultRow(participant: participant, isOptedIn: isOptedIn)
        }
        .buttonStyle(.plain)
        .disabled(!isOptedIn)
        .opacity(isOptedIn ? 1.0 : 0.6)
      }
    } header: {
      Text("Results")
    } footer: {
      if viewModel.searchResults.contains(where: { viewModel.participantOptInStatus[$0.id] != true }) {
        Text("Users without the lock icon haven't enabled encrypted messaging yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Search Result Row

  @ViewBuilder
  private func searchResultRow(participant: MLSParticipantViewModel, isOptedIn: Bool) -> some View {
    HStack(spacing: 12) {
      ZStack(alignment: .bottomTrailing) {
        avatarImage(url: participant.avatarURL, name: participant.displayName ?? participant.handle)
          .frame(width: 40, height: 40)
          .clipShape(Circle())

        if isOptedIn {
          Image(systemName: "lock.shield.fill")
            .font(.system(size: 12))
            .foregroundStyle(.green)
            .background(
              Circle()
                .fill(Color(.systemBackground))
                .frame(width: 16, height: 16)
            )
            .offset(x: 2, y: 2)
        }
      }

      VStack(alignment: .leading, spacing: 2) {
        if let displayName = participant.displayName, !displayName.isEmpty {
          Text(displayName)
            .font(.body)
        }
        HStack(spacing: 4) {
          Text("@\(participant.handle)")
            .font(.caption)
            .foregroundStyle(.secondary)
          if !isOptedIn {
            Text("• Not available")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }

      Spacer()

      if isOptedIn {
        Image(systemName: "plus.circle.fill")
          .font(.title3)
          .foregroundStyle(.blue)
      }
    }
  }

  // MARK: - Avatar

  @ViewBuilder
  private func avatarImage(url: URL?, name: String) -> some View {
    if let url {
      LazyImage(url: url) { state in
        if let image = state.image {
          image.resizable().scaledToFill()
        } else {
          placeholderAvatar(name: name)
        }
      }
    } else {
      placeholderAvatar(name: name)
    }
  }

  @ViewBuilder
  private func placeholderAvatar(name: String) -> some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.2))
      Text(String(name.prefix(2)).uppercased())
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Adding Overlay

  private var addingOverlay: some View {
    ZStack {
      Color.black.opacity(0.3)
        .ignoresSafeArea()
      VStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.5)
        Text("Adding member...")
          .font(.callout)
          .foregroundStyle(.white)
      }
      .padding(24)
      .background(.ultraThinMaterial)
      .cornerRadius(16)
    }
  }

  // MARK: - Actions

  private func addMember(_ participant: MLSParticipantViewModel) async {
    await viewModel?.addMember(participant.id)
    if viewModel?.error != nil {
      showingError = true
    }
  }
}

#endif
