//
//  FollowingView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/3/25.
//

import SwiftUI
import Petrel

struct FollowingView: View {
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
            if !viewModel.follows.isEmpty {
                ForEach(viewModel.follows, id: \.did) { follow in
                        ProfileRowView(profile: follow)
                        .padding(12)
                            .applyListRowModifiers(id: follow.did.didString())
                            .onTapGesture {
                                path.append(NavigationDestination.profile(follow.did.didString()))

                            }
                            .buttonStyle(.plain)
                    .onAppear {
                        // Load more when reaching the end
                        if follow == viewModel.follows.last && viewModel.hasMoreFollows && !viewModel.isLoadingMore {
                            Task { await viewModel.loadFollowing() }
                        }
                    }
                }
                
                // Loading indicator for pagination
                if viewModel.hasMoreFollows && viewModel.isLoadingMore {
                    ProgressView()
                        .padding()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            } else if viewModel.isLoadingMore {
                ProgressView("Loading following...")
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding()
                    .listRowSeparator(.hidden)
            } else {
                Text("Not following anyone yet.")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if viewModel.follows.isEmpty && !viewModel.isLoadingMore {
                await viewModel.loadFollowing()
            }
        }
    }
}
