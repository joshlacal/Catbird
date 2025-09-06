//
//  FollowersView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/3/25.
//

import Petrel
import SwiftUI

struct FollowersView: View {
    let userDID: String
    @Environment(AppState.self) private var appState
    @State var viewModel: FollowViewModel
    @Binding var path: NavigationPath
    
    init(userDID: String, client: ATProtoClient?, path: Binding<NavigationPath>) {
        self.userDID = userDID
        self.viewModel = FollowViewModel(client: client, userDID: userDID)
        self._path = path
    }

    var body: some View {
        List {
            if let error = viewModel.error {
                ErrorStateView(
                    error: error,
                    context: "Failed to load followers",
                    retryAction: { Task { await retryLoadFollowers() } }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else if !viewModel.followers.isEmpty {
                ForEach(viewModel.followers, id: \.did) { follower in
                        ProfileRowView(profile: follower, path: $path)
                            .padding(12)
                            .buttonStyle(.plain)
                    .onAppear {
                        // Load more when reaching the end
                        if follower == viewModel.followers.last && viewModel.hasMoreFollowers && !viewModel.isLoadingMore {
                            Task { await viewModel.loadFollowers() }
                        }
                    }
                }
                
                // Loading indicator for pagination
                if viewModel.hasMoreFollowers && viewModel.isLoadingMore {
                    ProgressView()
                        .padding()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            } else if viewModel.isLoadingMore {
                ProgressView("Loading followers...")
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding()
                    .listRowSeparator(.hidden)
            } else {
                Text("No followers yet.")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Followers")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
        .task {            
            // Then load followers
            if viewModel.followers.isEmpty && !viewModel.isLoadingMore {
                await viewModel.loadFollowers()
            }
        }
    }
    
    private func retryLoadFollowers() async {
        viewModel.clearError()
        await viewModel.loadFollowers()
    }
}
