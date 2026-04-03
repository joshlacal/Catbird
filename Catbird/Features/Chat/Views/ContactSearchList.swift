import CatbirdMLSCore
import NukeUI
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

// MARK: - Contact Search List

/// Shared contact search component for both Bluesky DM and Catbird Group modes.
/// Handles AT Protocol typeahead search, "People You Follow" default list,
/// and both single-select (tap → callback) and multi-select (tap → toggle) modes.
struct ContactSearchList: View {
  enum SelectionMode {
    case single   // tap fires onSingleSelect callback
    case multi    // tap toggles in selectedDIDs, shows checkmarks
  }

  let selectionMode: SelectionMode
  let showMLSStatus: Bool

  /// Multi-select: bound set of selected DIDs
  @Binding var selectedDIDs: Set<String>
  /// Multi-select: bound ordered list for chip display
  @Binding var selectionOrder: [String]
  /// Multi-select: bound profile details for selected contacts
  @Binding var selectedProfiles: [String: MLSParticipantViewModel]
  /// Single-select: called when a contact is tapped
  var onSingleSelect: ((any ProfileDisplayable) -> Void)?

  @Environment(AppState.self) private var appState
  @State private var searchText = ""
  @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
  @State private var mlsSearchResults: [MLSParticipantViewModel] = []
  @State private var followingProfiles: [AppBskyActorDefs.ProfileView] = []
  @State private var isSearching = false
  @State private var isLoadingFollows = false
  @State private var searchError: String?
  @State private var searchTask: Task<Void, Never>?
  @State private var isStartingConversation = false
  @State private var participantOptInStatus: [String: Bool] = [:]

  private let logger = Logger(subsystem: "blue.catbird", category: "ContactSearchList")
  private let searchDebounceInterval: Duration = .milliseconds(300)

  var body: some View {
    VStack(spacing: 0) {
      // Selected chips (multi-select only)
      if selectionMode == .multi && !selectedDIDs.isEmpty {
        selectedChipsView
      }

      List {
        if isSearching {
          searchingRow
        } else if let error = searchError {
          errorRow(error)
        } else if !searchText.isEmpty && searchResults.isEmpty && mlsSearchResults.isEmpty {
          noResultsRow
        } else if !searchText.isEmpty {
          searchResultsSection
        } else {
          followingSection
        }
      }
      .listStyle(.plain)
    }
    .searchable(
      text: $searchText,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search by name or handle"
    )
    .autocorrectionDisabled()
    .textInputAutocapitalization(.never)
    .onChange(of: searchText) { _, newValue in
      handleSearchTextChange(newValue)
    }
    .task {
      await loadFollowing()
    }
  }

  // MARK: - Selected Chips

  @ViewBuilder
  private var selectedChipsView: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack {
        Label("Selected (\(selectedDIDs.count))", systemImage: "person.fill.checkmark")
          .designCaption()
          .foregroundColor(.secondary)
        Spacer()
        Button("Clear") {
          withAnimation(.spring(response: 0.3)) {
            selectedDIDs.removeAll()
            selectionOrder.removeAll()
            selectedProfiles.removeAll()
          }
        }
        .designCaption()
      }
      .padding(.horizontal)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          ForEach(selectionOrder, id: \.self) { did in
            if let profile = selectedProfiles[did] {
              ParticipantChip(participant: profile) {
                withAnimation(.spring(response: 0.3)) {
                  selectedDIDs.remove(did)
                  selectionOrder.removeAll { $0 == did }
                  selectedProfiles.removeValue(forKey: did)
                }
              }
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
    }
    .background(Color.secondary.opacity(0.05))
  }

  // MARK: - List Sections

  @ViewBuilder
  private var searchingRow: some View {
    HStack {
      Spacer()
      ProgressView("Searching...")
      Spacer()
    }
    .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private func errorRow(_ error: String) -> some View {
    Text("Error: \(error)")
      .foregroundColor(.red)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var noResultsRow: some View {
    EmptyStateRow(icon: "magnifyingglass", message: "No results found")
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var searchResultsSection: some View {
    Section(header: Text("Search Results")) {
      switch selectionMode {
      case .single:
        ForEach(searchResults, id: \.did) { profile in
          ChatProfileRowView(
            profile: profile,
            isStartingConversation: isStartingConversation
              && profile.did.didString() == searchResults.first?.did.didString(),
            onSelect: {
              isStartingConversation = true
              onSingleSelect?(profile)
            }
          )
        }
      case .multi:
        ForEach(mlsSearchResults, id: \.id) { participant in
          let isOptedIn = participantOptInStatus[participant.id] ?? false
          ParticipantRow(
            participant: participant,
            isSelected: selectedDIDs.contains(participant.id),
            isMLSAvailable: showMLSStatus ? isOptedIn : true
          ) {
            if !showMLSStatus || isOptedIn {
              toggleParticipant(participant)
            }
          }
          .disabled(showMLSStatus && !isOptedIn)
          .opacity(showMLSStatus && !isOptedIn ? 0.6 : 1.0)
        }
      }
    }
  }

  @ViewBuilder
  private var followingSection: some View {
    if isLoadingFollows {
      HStack {
        Spacer()
        ProgressView("Loading follows...")
        Spacer()
      }
      .listRowSeparator(.hidden)
    } else if followingProfiles.isEmpty {
      ContentUnavailableView {
        Label("No Follows", systemImage: "person.2.slash")
      } description: {
        Text("You aren't following anyone yet.")
      }
      .listRowSeparator(.hidden)
    } else {
      Section(header: Text("People You Follow")) {
        switch selectionMode {
        case .single:
          ForEach(followingProfiles, id: \.did) { profile in
            ChatProfileRowView(
              profile: profile,
              isStartingConversation: false,
              onSelect: {
                isStartingConversation = true
                onSingleSelect?(profile)
              }
            )
          }
        case .multi:
          ForEach(followingProfiles, id: \.did) { profile in
            let did = profile.did.didString()
            let participant = MLSParticipantViewModel(
              id: did,
              handle: profile.handle.description,
              displayName: profile.displayName,
              avatarURL: profile.avatar.flatMap { URL(string: $0.uriString()) }
            )
            let isOptedIn = participantOptInStatus[did] ?? false
            ParticipantRow(
              participant: participant,
              isSelected: selectedDIDs.contains(did),
              isMLSAvailable: showMLSStatus ? isOptedIn : true
            ) {
              if !showMLSStatus || isOptedIn {
                toggleParticipant(participant)
              }
            }
            .disabled(showMLSStatus && !isOptedIn)
            .opacity(showMLSStatus && !isOptedIn ? 0.6 : 1.0)
            .task {
              if showMLSStatus && participantOptInStatus[did] == nil {
                await checkMLSOptIn(for: did)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Multi-Select Helpers

  private func toggleParticipant(_ participant: MLSParticipantViewModel) {
    withAnimation(.spring(response: 0.3)) {
      if selectedDIDs.contains(participant.id) {
        selectedDIDs.remove(participant.id)
        selectionOrder.removeAll { $0 == participant.id }
        selectedProfiles.removeValue(forKey: participant.id)
      } else {
        selectedDIDs.insert(participant.id)
        selectionOrder.append(participant.id)
        selectedProfiles[participant.id] = participant
      }
    }
  }

  // MARK: - Search Logic

  private func handleSearchTextChange(_ newValue: String) {
    searchTask?.cancel()
    searchError = nil
    if !newValue.isEmpty && newValue.count >= 2 {
      searchTask = Task {
        do {
          try await Task.sleep(for: searchDebounceInterval)
          await performSearch(query: newValue)
        } catch {
          // Cancelled
        }
      }
    } else {
      searchResults = []
      mlsSearchResults = []
    }
  }

  @MainActor
  private func performSearch(query: String) async {
    guard let client = appState.atProtoClient else {
      searchError = "Not connected"
      return
    }

    isSearching = true
    defer { isSearching = false }

    do {
      let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let params = AppBskyActorSearchActorsTypeahead.Parameters(q: term, limit: 20)
      let (code, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)

      guard code >= 200 && code < 300, let actors = response?.actors else {
        searchError = "Search failed"
        return
      }

      searchResults = actors

      mlsSearchResults = actors.map { actor in
        MLSParticipantViewModel(
          id: actor.did.description,
          handle: actor.handle.description,
          displayName: actor.displayName,
          avatarURL: actor.avatar.flatMap { URL(string: $0.uriString()) }
        )
      }

      for participant in mlsSearchResults where selectedDIDs.contains(participant.id) {
        selectedProfiles[participant.id] = participant
      }

      if showMLSStatus {
        await checkMLSOptInBatch(dids: actors.map { $0.did.description })
      }
    } catch {
      searchError = error.localizedDescription
    }
  }

  @MainActor
  private func loadFollowing() async {
    guard let client = appState.atProtoClient else { return }

    isLoadingFollows = true
    defer { isLoadingFollows = false }

    do {
      let currentUserDid = try await client.getDid()
      let params = AppBskyGraphGetFollows.Parameters(
        actor: try ATIdentifier(string: currentUserDid),
        limit: 50
      )
      let (code, response) = try await client.app.bsky.graph.getFollows(input: params)
      guard code >= 200 && code < 300, let response else { return }
      followingProfiles = response.follows

      if showMLSStatus {
        let dids = followingProfiles.map { $0.did.didString() }
        await checkMLSOptInBatch(dids: dids)
      }
    } catch {
      logger.error("Error loading following: \(error.localizedDescription)")
    }
  }

  // MARK: - MLS Opt-In Check

  @MainActor
  private func checkMLSOptInBatch(dids: [String]) async {
    guard let apiClient = await appState.getMLSAPIClient() else { return }
    let didObjects = dids.compactMap { try? DID(didString: $0) }
    guard !didObjects.isEmpty else { return }
    do {
      let statuses = try await apiClient.getOptInStatus(dids: didObjects)
      for status in statuses {
        participantOptInStatus[status.did.didString()] = status.optedIn
      }
    } catch {
      logger.warning("Failed to check MLS opt-in: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func checkMLSOptIn(for did: String) async {
    await checkMLSOptInBatch(dids: [did])
  }
}

#endif
