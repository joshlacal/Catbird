//
//  NewMessageView.swift
//  Catbird
//
//  Created by Claude on 5/10/25.
//

import OSLog
import Petrel
import SwiftUI
import NukeUI
import ExyteChat

struct NewMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var searchResults: [AppBskyActorDefs.ProfileView] = []
  @State private var followingProfiles: [AppBskyActorDefs.ProfileView] = []
  @State private var isSearching = false
  @State private var isLoadingFollows = false
  @State private var searchError: String?
  @State private var isStartingConversation = false
  @FocusState private var isSearchFieldFocused: Bool

  private let logger = Logger(subsystem: "blue.catbird", category: "NewMessageView")

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Search field
        SearchBarView(searchText: $searchText, placeholder: "Search for people") {
          // TODO: Implement search functionality
        }
          .padding(.horizontal)
          .padding(.top)

        Divider()
          .padding(.top, 8)

        // Results list
        List {
          if isSearching {
            ProgressView("Searching...")
              .frame(maxWidth: .infinity, alignment: .center)
              .listRowSeparator(.hidden)
          } else if let error = searchError {
            Text("Error: \(error)")
              .foregroundColor(.red)
              .frame(maxWidth: .infinity, alignment: .center)
              .listRowSeparator(.hidden)
          } else if searchResults.isEmpty && !searchText.isEmpty {
            Text("No users found")
              .foregroundColor(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .listRowSeparator(.hidden)
          } else if !searchText.isEmpty {
            // Show search results
            Section(header: Text("Search Results")) {
              ForEach(searchResults, id: \.did) { profile in
                ChatProfileRowView(
                  profile: profile,
                  isStartingConversation: isStartingConversation && profile.did.didString() == searchResults.first?.did.didString(),
                  onSelect: {
                    startConversation(with: profile)
                  }
                )
              }
            }
          } else {
            // Show people you follow
            if isLoadingFollows {
              ProgressView("Loading follows...")
                .frame(maxWidth: .infinity, alignment: .center)
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
                ForEach(followingProfiles, id: \.did) { profile in
                  ChatProfileRowView(
                    profile: profile,
                    isStartingConversation: isStartingConversation && profile.did.didString() == followingProfiles.first?.did.didString(),
                    onSelect: {
                      startConversation(with: profile)
                    }
                  )
                }
              }
            }
          }
        }
        .listStyle(.plain)
      }
      .navigationTitle("New Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isStartingConversation)
        }
      }
      .onChange(of: searchText) { _, newValue in
        if !newValue.isEmpty && newValue.count >= 2 {
          performSearch(searchText: newValue)
        } else {
          searchResults = []
        }
      }
      .disabled(isStartingConversation)
      .task {
        // Load following list when view appears
        loadFollowing()

        // Auto-focus search field when view appears
        isSearchFieldFocused = true
      }
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
        let params = AppBskyActorSearchActors.Parameters(q: searchTerm, limit: 20)
        let (responseCode, response) = try await client.app.bsky.actor.searchActors(input: params)

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

  private func startConversation(with profile: AppBskyActorDefs.ProfileView) {
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
}
