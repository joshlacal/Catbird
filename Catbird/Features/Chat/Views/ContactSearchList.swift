import CatbirdMLSCore
import NukeUI
import OSLog
import Petrel
import SwiftUI

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
  @State private var searchGeneration = UUID()
  @State private var isStartingConversation = false
  @State private var participantAvailability: [String: MLSAPIClient.MLSChatAvailability] = [:]
  @State private var checkingAvailability: Set<String> = []
  @State private var availabilityRequests: [String: UUID] = [:]
  @State private var blueskyChatAvailability: [String: Bool] = [:]

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
    #if os(iOS)
    .searchable(
      text: $searchText,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search by name or handle"
    )
    #else
    .searchable(
      text: $searchText,
      placement: .sidebar,
      prompt: "Search by name or handle"
    )
    #endif
    .autocorrectionDisabled()
    #if os(iOS)
    .textInputAutocapitalization(.never)
    #endif
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
          participantRow(
            participant,
            blueskyAvailable: blueskyChatAvailability[participant.id] ?? true
          )
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
            participantRow(
              participant,
              blueskyAvailable: blueskyAddable(
                chatSetting: profile.associated?.chat?.allowIncoming,
                followedBy: profile.viewer?.followedBy != nil
              )
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private func participantRow(
    _ participant: MLSParticipantViewModel,
    blueskyAvailable: Bool
  ) -> some View {
    let availability = participantAvailability[participant.id]
    let isChecking = checkingAvailability.contains(participant.id) || availability == nil
    if showMLSStatus && (isChecking || availability == .unknown) {
      Button {
        Task { await checkMLSOptIn(for: participant.id) }
      } label: {
        HStack(spacing: DesignTokens.Spacing.base) {
          AsyncProfileImage(url: participant.avatarURL, size: DesignTokens.Size.avatarMD)
          VStack(alignment: .leading, spacing: 4) {
            if let displayName = participant.displayName {
              Text(displayName)
                .designCallout()
                .foregroundColor(.primary)
                .lineLimit(1)
            }
            Text("@\(participant.handle)")
              .designCaption()
              .foregroundColor(.secondary)
              .lineLimit(1)
            Text(isChecking ? "Checking chat availability…" : "Couldn't check availability")
              .designCaption()
              .foregroundColor(.secondary)
          }
          Spacer()
          if isChecking {
            ProgressView()
          } else {
            Label("Retry", systemImage: "arrow.clockwise")
              .designCaption()
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isChecking)
      .accessibilityHint(isChecking ? "" : "Checks whether this person can receive Catbird chats")
    } else {
      let isAvailable = showMLSStatus ? availability == .available : blueskyAvailable
      ParticipantRow(
        participant: participant,
        isSelected: selectedDIDs.contains(participant.id),
        isMLSAvailable: isAvailable,
        showsEncryptionBadge: showMLSStatus,
        unavailableLabel: showMLSStatus ? "Not available" : "Chat restricted"
      ) {
        if isAvailable { toggleParticipant(participant) }
      }
      .disabled(!isAvailable)
      .opacity(isAvailable ? 1.0 : 0.6)
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

  /// Local heuristic mirroring ChatProfileRowView's 1:1 messageability check:
  /// users whose chat settings exclude the current user can't be added to a
  /// Bluesky group either (the server would reject them at creation).
  private func blueskyAddable(chatSetting: String?, followedBy: Bool) -> Bool {
    switch chatSetting ?? "all" {
    case "none":
      return false
    case "following":
      return followedBy
    default:
      return true
    }
  }

  // MARK: - Search Logic

  private func handleSearchTextChange(_ newValue: String) {
    let generation = UUID()
    searchGeneration = generation
    searchTask?.cancel()
    searchError = nil
    if !newValue.isEmpty && newValue.count >= 2 {
      searchTask = Task {
        do {
          try await Task.sleep(for: searchDebounceInterval)
          await performSearch(query: newValue, generation: generation)
        } catch {
          // Cancelled
        }
      }
    } else {
      isSearching = false
      searchResults = []
      mlsSearchResults = []
    }
  }

  @MainActor
  private func isCurrentSearch(query: String, generation: UUID) -> Bool {
    !Task.isCancelled && searchGeneration == generation && searchText == query
  }

  @MainActor
  private func performSearch(query: String, generation: UUID) async {
    guard isCurrentSearch(query: query, generation: generation) else { return }
    guard let client = appState.atProtoClient else {
      searchError = "Not connected"
      return
    }

    isSearching = true
    defer {
      if searchGeneration == generation { isSearching = false }
    }

    do {
      let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let params = AppBskyActorSearchActorsTypeahead.Parameters(q: term, limit: 20)
      let (code, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
      guard isCurrentSearch(query: query, generation: generation) else { return }

      guard code >= 200 && code < 300, let actors = response?.actors else {
        searchError = "Search failed"
        return
      }

      searchResults = actors

      if !showMLSStatus {
        let targetDids = actors.compactMap { try? DID(didString: $0.did.description) }
        let relationships = (try? await appState.batchCheckRelationships(targets: targetDids)) ?? [:]
        guard isCurrentSearch(query: query, generation: generation) else { return }

        for actor in actors {
          let didString = actor.did.description
          let followedBy: Bool
          if let viewer = actor.viewer {
            followedBy = viewer.followedBy != nil
          } else if let didObj = try? DID(didString: didString), let rel = relationships[didObj] {
            followedBy = rel.followedBy
          } else {
            followedBy = false
          }
          blueskyChatAvailability[didString] = blueskyAddable(
            chatSetting: actor.associated?.chat?.allowIncoming,
            followedBy: followedBy
          )
        }
      }

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
      guard isCurrentSearch(query: query, generation: generation) else { return }
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
    let didObjects = dids.compactMap { try? DID(didString: $0) }
    guard !didObjects.isEmpty else { return }
    let requestID = UUID()
    for did in didObjects {
      let key = did.didString()
      availabilityRequests[key] = requestID
      checkingAvailability.insert(key)
    }

    var resolved: [String: MLSAPIClient.MLSChatAvailability] = [:]
    if let apiClient = await appState.getMLSAPIClient(), !Task.isCancelled {
      let statuses = await apiClient.getChatAvailability(dids: didObjects)
      if !Task.isCancelled {
        for status in statuses { resolved[status.did.didString()] = status.availability }
      }
    }

    for did in didObjects {
      let key = did.didString()
      // A superseded search/retry must not overwrite a newer result for this person.
      guard availabilityRequests[key] == requestID else { continue }
      participantAvailability[key] = resolved[key] ?? .unknown
      checkingAvailability.remove(key)
      availabilityRequests.removeValue(forKey: key)
    }
  }

  @MainActor
  private func checkMLSOptIn(for did: String) async {
    await checkMLSOptInBatch(dids: [did])
  }
}
