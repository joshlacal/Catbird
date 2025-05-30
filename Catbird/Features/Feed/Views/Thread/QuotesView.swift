//
//  QuotesView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import Petrel
import SwiftUI

struct QuotesView: View {
    let postUri: String
    @Environment(AppState.self) private var appState
    @State private var quotes: [AppBskyFeedDefs.PostView] = []
    @State private var loading: Bool = true
    @State private var error: Error?
    @State private var cursor: String?
    @Binding var path: NavigationPath
    
    var body: some View {
        VStack {
            if loading && quotes.isEmpty {
                ProgressView()
                    .padding()
            } else if let error = error {
                Text("Error loading quotes: \(error.localizedDescription)")
                    .padding()
            } else if quotes.isEmpty {
                Text("No quotes yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(quotes, id: \.uri) { post in
                        PostQuoteRowView(post: post, path: $path)
                    }
                    
                    if let cursor = cursor {
                        ProgressView()
                            .onAppear {
                                Task { await loadMoreQuotes() }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Quotes")
        .task {
            await loadQuotes()
        }
    }
    
    private func loadQuotes() async {
        loading = true
        
        do {
            guard let client = appState.atProtoClient else {
                error = NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
                loading = false
                return
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetQuotes.Parameters(uri: uri, limit: 25)
            
            let (_, result) = try await client.app.bsky.feed.getQuotes(input: input)
            
            if let result = result {
                quotes = result.posts
                cursor = result.cursor
            }
        } catch {
            self.error = error
        }
        
        loading = false
    }
    
    private func loadMoreQuotes() async {
        // Similar implementation to loadMoreLikes
        // ...
    }
}
