//
//  QuotesView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import OSLog
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
    @State private var isLoadingPage: Bool = false
    @State private var initialError: Error?
    @State private var pageError: Error?
    @State private var cursor: String?
    /// Set once a load succeeds, so returning to the screen doesn't refetch page 1.
    @State private var hasLoaded = false
    @Binding var path: NavigationPath

    private let logger = Logger(subsystem: "blue.catbird", category: "QuotesView")
    
    var body: some View {
        VStack {
            if loading && quotes.isEmpty {
                ProgressView()
                    .padding()
            } else if let initialError, quotes.isEmpty {
                ListLoadFailureView(title: "Couldn’t Load Quotes", error: initialError) {
                    Task { await loadQuotes() }
                }
            } else if quotes.isEmpty, hasLoaded {
                Text("No quotes yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else if quotes.isEmpty {
                // A cancelled load leaves nothing loaded yet; `.task` reruns it.
                ProgressView()
                    .padding()
            } else {
                PostListCollectionView(
                    posts: quotes,
                    hasMore: cursor != nil,
                    isLoadingMore: isLoadingPage,
                    footerState: pageError != nil ? .failed : (cursor != nil ? .loading : .hidden),
                    onLoadMore: { await loadMoreQuotes() },
                    onRefresh: { await loadQuotes() },
                    appState: appState,
                    accessibilityIdentifier: "quotes.posts"
                ) { post in
                    Button {
                        path.append(NavigationDestination.post(post.uri))
                    } label: {
                        VStack(spacing: 0) {
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

                            Rectangle()
                                .fill(Color.separator)
                                .frame(height: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(
                    Color.primaryBackground(
                        themeManager: appState.themeManager,
                        currentScheme: colorScheme
                    )
                )
            }
        }
        .navigationTitle("Quotes")
        .task {
            // `.task` restarts each time the screen reappears, such as on the way
            // back from a quoting post; keep the loaded pages and scroll position.
            // Pull to refresh reloads.
            guard !hasLoaded else { return }
            await loadQuotes()
        }
    }
    
    private func loadQuotes() async {
        loading = true
        initialError = nil
        pageError = nil
        
        do {
            guard let client = appState.atProtoClient else {
                throw NSError(domain: "QuotesView", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetQuotes.Parameters(uri: uri, limit: 25)
            
            let (responseCode, result) = try await client.app.bsky.feed.getQuotes(input: input)
            guard (200 ... 299).contains(responseCode), let result else {
                throw NSError(domain: "QuotesView", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected response \(responseCode)"])
            }
            
            var seen = Set<String>()
            quotes = result.posts.filter { seen.insert($0.uri.uriString()).inserted }
            cursor = result.cursor
            hasLoaded = true
        } catch {
            logger.error("Failed to load quotes: \(error.localizedDescription)")
            // A load cancelled by leaving the screen isn't an error; it reruns on return.
            if !Task.isCancelled {
                if quotes.isEmpty {
                    initialError = error
                } else {
                    pageError = error
                }
            }
        }
        
        loading = false
    }
    
    private func loadMoreQuotes() async {
        guard let client = appState.atProtoClient,
              let currentCursor = cursor,
              !loading, !isLoadingPage else { return }
        
        isLoadingPage = true
        pageError = nil
        
        do {
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetQuotes.Parameters(
                uri: uri,
                limit: 25,
                cursor: currentCursor
            )
            
            let (responseCode, result) = try await client.app.bsky.feed.getQuotes(input: input)
            guard (200 ... 299).contains(responseCode), let result else {
                throw NSError(domain: "QuotesView", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected response \(responseCode)"])
            }
            
            var seen = Set(quotes.map { $0.uri.uriString() })
            quotes.append(contentsOf: result.posts.filter { seen.insert($0.uri.uriString()).inserted })
            if result.cursor == currentCursor || result.posts.isEmpty {
                cursor = nil
            } else {
                cursor = result.cursor
            }
        } catch {
            logger.error("Failed to load more quotes: \(error.localizedDescription)")
            // Pull to refresh cancels a page load still in flight; the refresh
            // replaces the pages, so that isn't a failed page.
            if !Task.isCancelled {
                pageError = error
            }
        }
        
        isLoadingPage = false
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
