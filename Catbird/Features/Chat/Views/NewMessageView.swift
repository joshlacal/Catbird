//
//  NewMessageView.swift
//  Catbird
//
//  Created by Claude on 5/10/25.
//

import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

import NukeUI
// Chat system using unified components

//// MARK: - Profile Protocol
//protocol ProfileProtocol {
//  var did: DID { get }
//}


// MARK: - Platform Toolbar Modifier
private struct PlatformToolbarModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbarTitleDisplayMode(.inline)
    #else
    content

#Preview("NewMessageView") {
  NavigationStack {
    NewMessageView()
  }
  .previewWithAuthenticatedState()
}

    #endif
  }
}

struct NewMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
  @State private var followingProfiles: [AppBskyActorDefs.ProfileView] = []
  @State private var isSearching = false
  @State private var isLoadingFollows = false
  @State private var searchError: String?
  @State private var isStartingConversation = false
  @State private var searchTask: Task<Void, Never>?
  @FocusState private var isSearchFieldFocused: Bool

  // MARK: - Mode

  enum NewConversationMode: String, CaseIterable {
    case bluesky = "Bluesky DM"
    case catbirdGroup = "Catbird Group"
  }

  @State private var mode: NewConversationMode = .bluesky

  private let logger = Logger(subsystem: "blue.catbird", category: "NewMessageView")
  private let searchDebounceInterval: Duration = .milliseconds(300)

  var body: some View {
    // MLSNewConversationView has its own NavigationStack + .searchable,
    // so it must replace the outer NavigationStack entirely to avoid nesting.
    if mode == .catbirdGroup && ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID) {
      mlsNewConversationContent
    } else {
      NavigationStack {
        contentView
          .navigationTitle("New Message")
          .modifier(PlatformToolbarModifier())
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              cancelButton
            }
          }
          .onChange(of: searchText) { _, newValue in
            handleSearchTextChange(newValue)
          }
          .disabled(isStartingConversation)
          .task {
            loadFollowing()
            isSearchFieldFocused = true
          }
      }
    }
  }

  @ViewBuilder
  private var mlsNewConversationContent: some View {
    MLSNewConversationView(
      onConversationCreated: { /* refresh handled by coordinator polling */ },
      onNavigateToConversation: { convoId in
        dismiss()
        appState.navigationManager.targetMLSConversationId = convoId
      }
    )
    .environment(appState)
    .applyAppStateEnvironment(appState)
    .overlay(alignment: .top) {
      // Mode picker overlaid so user can switch back
      Picker("Type", selection: $mode) {
        ForEach(NewConversationMode.allCases, id: \.self) { m in
          Text(m.rawValue).tag(m)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.top, 8)
      .background(.bar)
    }
    .safeAreaInset(edge: .top) {
      // Push content down to make room for the picker overlay
      Color.clear.frame(height: 44)
    }
  }

  @ViewBuilder
  private var contentView: some View {
    VStack(spacing: 0) {
      Picker("Type", selection: $mode) {
        ForEach(NewConversationMode.allCases, id: \.self) { m in
          Text(m.rawValue).tag(m)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.top)

      switch mode {
      case .bluesky:
        blueskyContent
      case .catbirdGroup:
        catbirdGroupContent
      }
    }
  }

  // MARK: - Bluesky Content

  @ViewBuilder
  private var blueskyContent: some View {
    searchBar
    Divider().padding(.top, 8)
    resultsList
  }

  @ViewBuilder
  private var searchBar: some View {
    SearchBarView(searchText: $searchText, placeholder: "Search for people") {
      // Search is triggered automatically via onChange of searchText
    }
    .padding(.horizontal)
    .padding(.top)
  }

  @ViewBuilder
  private var resultsList: some View {
    List {
      if isSearching {
        searchingView
      } else if let error = searchError {
        errorView(error)
      } else if searchResults.isEmpty && !searchText.isEmpty {
        noResultsView
      } else if !searchText.isEmpty {
        searchResultsSection
      } else {
        followingSection
      }
    }
    .listStyle(.plain)
  }

  @ViewBuilder
  private var searchingView: some View {
    ProgressView("Searching...")
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    Text("Error: \(error)")
      .foregroundColor(.red)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var noResultsView: some View {
    Text("No users found")
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var searchResultsSection: some View {
    Section(header: Text("Search Results")) {
      ForEach(searchResults, id: \.did) { profile in
        profileRow(profile, isSearchResult: true)
      }
    }
  }

  @ViewBuilder
  private var followingSection: some View {
    if isLoadingFollows {
      ProgressView("Loading follows...")
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowSeparator(.hidden)
    } else if followingProfiles.isEmpty {
      emptyFollowsView
    } else {
      followingList
    }
  }

  @ViewBuilder
  private var emptyFollowsView: some View {
    ContentUnavailableView {
      Label("No Follows", systemImage: "person.2.slash")
    } description: {
      Text("You aren't following anyone yet.")
    }
    .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var followingList: some View {
    Section(header: Text("People You Follow")) {
      ForEach(followingProfiles, id: \.did) { profile in
        profileRow(profile, isSearchResult: false)
      }
    }
  }

  @ViewBuilder
    private func profileRow(_ profile: ProfileDisplayable, isSearchResult: Bool) -> some View {
    let isSelected = isStartingConversation && isFirstProfile(profile, in: isSearchResult)
    ChatProfileRowView(
      profile: profile,
      isStartingConversation: isSelected,
      onSelect: {
        startConversation(with: profile)
      }
    )
  }

  private var cancelButton: some View {
    Button("Cancel", systemImage: "xmark") {
      dismiss()
    }
    .disabled(isStartingConversation)
  }

  private func isFirstProfile(_ profile: some ProfileDisplayable, in searchResults: Bool) -> Bool {
    if searchResults {
      return profile.did.didString() == self.searchResults.first?.did.didString()
    } else {
      return profile.did.didString() == followingProfiles.first?.did.didString()
    }
  }

  private func handleSearchTextChange(_ newValue: String) {
    searchTask?.cancel()
    if !newValue.isEmpty && newValue.count >= 2 {
      searchTask = Task {
        do {
          try await Task.sleep(for: searchDebounceInterval)
          performSearch(searchText: newValue)
        } catch {
          // Task cancelled - ignore
        }
      }
    } else {
      searchResults = []
    }
  }

  /// Loads the people the user is following
  private func loadFollowing() {
    guard let client = appState.atProtoClient else {
      return
    }

    Task {
      isLoadingFollows = true

      do {
        // Get the current user's DID
        let currentUserDid = try await client.getDid()

        // Get the user's following list
        let params = AppBskyGraphGetFollows.Parameters(
          actor: try ATIdentifier(string: currentUserDid),
          limit: 50
        )

        let (responseCode, response) = try await client.app.bsky.graph.getFollows(input: params)

        await MainActor.run {
          isLoadingFollows = false

          guard responseCode >= 200 && responseCode < 300, let response = response else {
            logger.error("Failed to load following: HTTP \(responseCode)")
            return
          }

          followingProfiles = response.follows
        }
      } catch {
        await MainActor.run {
          isLoadingFollows = false
          logger.error("Error loading following: \(error.localizedDescription)")
        }
      }
    }
  }

  private func performSearch(searchText: String) {
    guard let client = appState.atProtoClient else {
      searchError = "Not connected to BlueSky"
      return
    }

    Task {
      isSearching = true
      searchError = nil

      do {
        let searchTerm = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = AppBskyActorSearchActorsTypeahead.Parameters(q: searchTerm, limit: 20)
        let (responseCode, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)

        await MainActor.run {
          isSearching = false

          guard responseCode >= 200 && responseCode < 300 else {
            searchError = "Network error: \(responseCode)"
            return
          }

          guard let results = response?.actors else {
            searchError = "No results returned"
            return
          }

          searchResults = results
        }
      } catch {
        await MainActor.run {
          isSearching = false
          searchError = error.localizedDescription
          logger.error("Search error: \(error.localizedDescription)")
        }
      }
    }
  }

    private func startConversation(with profile: some ProfileDisplayable) {
    Task {
      await MainActor.run {
        isStartingConversation = true
      }

      logger.debug("Starting conversation with user: \(profile.handle.description)")
        if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
        logger.debug("Successfully started conversation with ID: \(convoId)")

        await MainActor.run {
          isStartingConversation = false
          dismiss()

          // Navigate to the conversation
          appState.navigationManager.navigate(
            to: .conversation(convoId),
            in: 4  // Chat tab index
          )
        }
      } else {
        logger.error("Failed to start conversation with user: \(profile.handle.description)")

        await MainActor.run {
          isStartingConversation = false
          searchError = "Failed to start conversation. Please try again."
        }
      }
    }
  }

  // MARK: - Catbird Group Content

  @ViewBuilder
  private var catbirdGroupContent: some View {
    // MLS-enabled path is handled at the body level (replaces NavigationStack
    // entirely to avoid nested NavigationStacks breaking .searchable).
    // This only shows the opt-in gate when MLS is NOT enabled.
    mlsOptInGate
  }

  @ViewBuilder
  private var mlsOptInGate: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "lock.shield")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)

      Text("Catbird Groups")
        .font(.title3)
        .fontWeight(.semibold)

      Text("End-to-end encrypted group chat using the MLS protocol.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      VStack(spacing: 8) {
        Label("Highly Experimental", systemImage: "exclamationmark.triangle.fill")
          .font(.headline)
          .foregroundStyle(.orange)

        Text("This feature is under active development. You may experience bugs or missing messages.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      Toggle(isOn: Binding(
        get: { ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID) },
        set: { newValue in
          if newValue {
            ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
            Task { await optInToMLS() }
          }
        }
      )) {
        Text("Enable Catbird Groups")
          .fontWeight(.medium)
      }
      .toggleStyle(.switch)
      .padding(.horizontal, 48)

      Spacer()
    }
  }

  @MainActor
  private func optInToMLS() async {
    do {
      try await appState.initializeMLS()
      guard let apiClient = await appState.getMLSAPIClient() else { return }
      _ = try await apiClient.optIn()
      if let manager = await appState.getMLSConversationManager() {
        try? await manager.ensureDeviceRecordPublished()
      }
      ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
    } catch {
      ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
    }
  }
}

#else

// macOS stub for NewMessageView
struct NewMessageView: View {
  var body: some View {
    VStack {
      Text("New Message")
        .font(.title2)
        .fontWeight(.semibold)
      Text("Chat functionality is not available on macOS")
        .foregroundColor(.secondary)
      Text("Chat features require iOS")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding()
  }
}


#Preview("NewMessageView") {
  NavigationStack {
    NewMessageView()
  }
  .previewWithAuthenticatedState()
}

#endif
