//
//  LikesView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import SwiftUI
import Petrel


struct LikesView: View {
    let postUri: String
    @Environment(AppState.self) private var appState
    @State private var likes: [AppBskyFeedGetLikes.Like] = []
    @State private var loading: Bool = true
    @State private var error: Error?
    @State private var cursor: String?
    
    var body: some View {
        VStack {
            if loading && likes.isEmpty {
                ProgressView()
                    .padding()
            } else if let error = error {
                Text("Error loading likes: \(error.localizedDescription)")
                    .padding()
            } else if likes.isEmpty {
                Text("No likes yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(likes, id: \.actor.did) { like in
                        ProfileRowView(profile: like.actor)
                    }
                    
                    if let cursor = cursor {
                        ProgressView()
                            .onAppear {
                                Task { await loadMoreLikes() }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Likes")
        .task {
            await loadLikes()
        }
    }
    
    private func loadLikes() async {
        loading = true
        
        do {
            guard let client = appState.atProtoClient else {
                error = NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
                loading = false
                return
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetLikes.Parameters(uri: uri, limit: 50)
            
            let (_, result) = try await client.app.bsky.feed.getLikes(input: input)
            
            if let result = result {
                likes = result.likes
                cursor = result.cursor
            }
        } catch {
            self.error = error
        }
        
        loading = false
    }
    
    private func loadMoreLikes() async {
        guard let cursor = cursor, !loading else { return }
        loading = true
        
        do {
            guard let client = appState.atProtoClient else { return }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetLikes.Parameters(uri: uri, limit: 50, cursor: cursor)
            
            let (_, result) = try await client.app.bsky.feed.getLikes(input: input)
            
            if let result = result {
                likes.append(contentsOf: result.likes)
                self.cursor = result.cursor
            }
        } catch {
            self.error = error
        }
        
        loading = false
    }
}
