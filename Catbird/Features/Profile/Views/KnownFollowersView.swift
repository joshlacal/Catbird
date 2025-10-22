//
//  KnownFollowersView.swift
//  Catbird
//
//  Shows known followers (mutual connections)
//

import Petrel
import SwiftUI

struct KnownFollowersView: View {
    let userDID: String
    @Environment(AppState.self) private var appState
    @State private var knownFollowers: [AppBskyActorDefs.ProfileView] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var error: Error?
    @Binding var path: NavigationPath
    
    var body: some View {
        List {
            if let error = error {
                ErrorStateView(
                    error: error,
                    context: "Failed to load known followers",
                    retryAction: { Task { await loadKnownFollowers() } }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else if !knownFollowers.isEmpty {
                ForEach(knownFollowers, id: \.did) { follower in
                    ProfileRowView(profile: follower, path: $path)
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                    .onAppear {
                        // Load more when reaching the end
                        if follower == knownFollowers.last && hasMore && !isLoading {
                            Task { await loadKnownFollowers() }
                        }
                    }
                }
                
                // Loading indicator for pagination
                if hasMore && isLoading {
                    ProgressView()
                        .padding()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            } else if isLoading {
                ProgressView("Loading known followers...")
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding()
                    .listRowSeparator(.hidden)
            } else {
                Text("No known followers yet.")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Followers you know")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
        .task {
            if knownFollowers.isEmpty && !isLoading {
                await loadKnownFollowers()
            }
        }
    }
    
    private func loadKnownFollowers() async {
        guard let client = appState.atProtoClient, !isLoading else { return }
        
        isLoading = true
        error = nil
        
        do {
            let params = AppBskyGraphGetKnownFollowers.Parameters(
                actor: try ATIdentifier(string: userDID),
                limit: 50,
                cursor: cursor
            )
            
            let (responseCode, output) = try await client.app.bsky.graph.getKnownFollowers(input: params)
            
            if responseCode == 200, let output = output {
                let followers = output.followers
                
                await MainActor.run {
                    if cursor == nil {
                        knownFollowers = followers
                    } else {
                        knownFollowers.append(contentsOf: followers)
                    }
                    cursor = output.cursor
                    hasMore = output.cursor != nil
                    isLoading = false
                }
            } else {
                await MainActor.run {
                    error = NSError(domain: "KnownFollowersView", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Failed to load known followers"])
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.error = error
                isLoading = false
            }
        }
    }
}
