import CatbirdMLSCore
import NukeUI
import OSLog
import Petrel
import PetrelCatbird
import SwiftUI

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
  @State private var showBlockWarning = false
  @State private var blockWarningMessage = ""
  @State private var invitedDID: String?
  @State private var noteDraft: MLSDirectComposeDraft?
  @State private var noteError: String?
  @State private var preparingNote = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSAddMemberView")

  var body: some View {
    List {
      if let invitedDID {
        Section("Group invitation sent") {
          Text("The group invitation is separate from a direct message. You can write an optional encrypted note.")
          Button("Write a separate note") { Task { await prepareInvitationNote(recipient: invitedDID) } }
            .disabled(preparingNote)
          Button("Done") { dismiss() }
          if preparingNote { ProgressView() }
          if let noteError { Text(noteError).foregroundStyle(.red) }
        }
      } else if let viewModel {
        listContent(viewModel: viewModel)
      }
    }
    .navigationTitle("Add Members")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
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
    .alert("Cannot Add Member", isPresented: $showBlockWarning) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(blockWarningMessage)
    }
    .task {
      viewModel = MLSAddMemberViewModel(
        conversationId: conversationId,
        conversationManager: conversationManager,
        existingMemberDIDs: existingMemberDIDs
      )
    }
    .sheet(item: $noteDraft) { draft in
      MLSDirectComposeView(draft: draft) { conversationID in
        appState.navigationManager.targetMLSConversationId = conversationID
        dismiss()
      }
    }
    .onChange(of: appState.userDID) { _, _ in dismiss() }
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
                #if os(iOS)
                .fill(Color(.systemBackground))
                #else
                .fill(Color(nsColor: .windowBackgroundColor))
                #endif
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
    // Warn the user up front if the server would reject this add due to
    // a block edge. Server enforces the same rule with HTTP 403.
    do {
      var didStrings = Array(existingMemberDIDs)
      didStrings.append(participant.id)
      let dids = didStrings.compactMap { try? DID(didString: $0) }
      if dids.count >= 2 {
        let (_, output) = try await conversationManager.apiClient.checkBlocks(dids: dids)
        if let output, !output.isEmpty {
          blockWarningMessage = "You can't add @\(participant.handle): a block relationship exists between this user and someone already in the conversation."
          showBlockWarning = true
          return
        }
      }
    } catch {
      // If the check fails (network, server down, etc.), fall through to the actual add.
      // The server's own block check will still catch a genuine conflict (HTTP 403).
      logger.warning("checkBlocks failed: \(String(describing: error))")
    }

    let account = appState.userDID
    guard conversationManager.currentUserDID == account else { return }
    await viewModel?.addMember(participant.id)
    guard appState.userDID == account, conversationManager.currentUserDID == account else { return }
    if viewModel?.error != nil {
      showingError = true
    } else if viewModel?.didAddMember == true {
      invitedDID = participant.id
    }
  }

  @MainActor private func prepareInvitationNote(recipient: String) async {
    guard !preparingNote else { return }
    let account = appState.userDID
    guard conversationManager.currentUserDID == account else { return }
    preparingNote = true
    defer { preparingNote = false }
    do {
      guard let verified = try await conversationManager.getGroupInvitationReference(conversationId: conversationId, recipientDid: recipient),
            appState.userDID == account, conversationManager.currentUserDID == account else {
        noteError = "The group invitation could not be verified yet. The invitation remains separate; try opening the note again."
        return
      }
      let reference = try MLSGroupInvitationReference(verified: verified)
      let saved = try await MLSDirectComposeDraftStore.invitationDraft(accountDID: account, reference: reference, database: conversationManager.database)
      guard appState.userDID == account else { return }
      noteDraft = saved
    } catch {
      guard appState.userDID == account else { return }
      noteError = "The group invitation was sent, but the optional note could not be prepared. Try again."
    }
  }

}
