//
//  RepostsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//


import SwiftUI
import Petrel
import NukeUI

struct RepostsView: View {
    let postUri: String
    @Environment(AppState.self) private var appState
    @State private var reposts: [AppBskyActorDefs.ProfileView] = []
    @State private var loading: Bool = true
    @State private var error: Error?
    @State private var cursor: String?
    
    var body: some View {
        VStack {
            if loading && reposts.isEmpty {
                ProgressView()
                    .padding()
            } else if let error = error {
                Text("Error loading reposts: \(error.localizedDescription)")
                    .padding()
            } else if reposts.isEmpty {
                Text("No reposts yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(reposts, id: \.did) { profile in
                        ProfileRowView(profile: profile)
                    }
                    
                    if let cursor = cursor {
                        ProgressView()
                            .onAppear {
                                Task { await loadMoreReposts() }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Reposts")
        .task {
            await loadReposts()
        }
    }
    
    private func loadReposts() async {
        loading = true
        
        do {
            guard let client = appState.atProtoClient else {
                error = NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
                loading = false
                return
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetRepostedBy.Parameters(uri: uri, limit: 50)
            
            let (_, result) = try await client.app.bsky.feed.getRepostedBy(input: input)
            
            if let result = result {
                reposts = result.repostedBy
                cursor = result.cursor
            }
        } catch {
            self.error = error
        }
        
        loading = false
    }
    
    private func loadMoreReposts() async {
        // TODO: Similar implementation to loadMoreLikes
        // ...
    }
}
