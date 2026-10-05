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

                    if pageError != nil {
                        ListPageFailureRow {
                            Task { await loadMoreQuotes() }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            Color.primaryBackground(
                                themeManager: appState.themeManager,
                                currentScheme: colorScheme
                            )
                        )
                    } else if cursor != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
                .refreshable {
                    await loadQuotes()
                }
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
        } catch {
            logger.error("Failed to load quotes: \(error.localizedDescription)")
            if quotes.isEmpty {
                initialError = error
            } else {
                pageError = error
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
            pageError = error
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
