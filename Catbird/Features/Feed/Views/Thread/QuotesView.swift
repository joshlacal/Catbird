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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var quotes: [AppBskyFeedDefs.PostView] = []

    private var contentMaxWidth: CGFloat {
        hSizeClass == .compact ? .infinity : 600
    }
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
                        Button {
                            path.append(NavigationDestination.post(post.uri))
                        } label: {
                            PostView(
                                post: post,
                                grandparentAuthor: nil,
                                isParentPost: false,
                                isSelectable: false,
                                path: $path,
                                appState: appState
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Color.separator)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
                        .listRowBackground(
                            Color.primaryBackground(
                                themeManager: appState.themeManager,
                                currentScheme: colorScheme
                            )
                        )
                        .listRowInsets(EdgeInsets())
                    }

                    if let cursor = cursor {
                        ProgressView()
                            .onAppear {
                                Task { await loadMoreQuotes() }
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                Color.primaryBackground(
                                    themeManager: appState.themeManager,
                                    currentScheme: colorScheme
                                )
                            )
                    }
                }
                .listStyle(.plain)
                .background(
                    Color.primaryBackground(
                        themeManager: appState.themeManager,
                        currentScheme: colorScheme
                    )
                )
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
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
        guard let client = appState.atProtoClient,
              let currentCursor = cursor,
              !loading else { return }
        
        loading = true
        
        do {
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetQuotes.Parameters(
                uri: uri,
                limit: 25,
                cursor: currentCursor
            )
            
            let (_, result) = try await client.app.bsky.feed.getQuotes(input: input)
            
            if let result = result {
                quotes.append(contentsOf: result.posts)
                cursor = result.cursor
            }
        } catch {
            self.error = error
        }
        
        loading = false
    }
}

#Preview("QuotesView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    QuotesView(
      postUri: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l2s5xxv6fn2c",
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
