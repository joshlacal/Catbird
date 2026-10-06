//
//  RepostsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import SwiftUI
import Petrel
import OSLog

struct RepostsView: View {
    let postUri: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var reposts: [AppBskyActorDefs.ProfileView] = []
    @State private var loading: Bool = true
    @State private var isLoadingPage: Bool = false
    @State private var initialError: Error?
    @State private var pageError: Error?
    @State private var cursor: String?

    private let logger = Logger(subsystem: "blue.catbird", category: "RepostsView")

    private var contentMaxWidth: CGFloat {
        hSizeClass == .compact ? .infinity : 600
    }

    var body: some View {
        VStack {
            if loading && reposts.isEmpty {
                ProgressView()
                    .padding()
            } else if let initialError, reposts.isEmpty {
                ListLoadFailureView(title: "Couldn’t Load Reposts", error: initialError) {
                    Task { await loadReposts() }
                }
            } else if reposts.isEmpty {
                Text("No reposts yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(reposts, id: \.did) { profile in
                        ProfileRowView(profile: profile, path: $path)
                            .mainContentFrame()
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets())
                    }

                    if pageError != nil {
                        ListPageFailureRow {
                            Task { await loadMoreReposts() }
                        }
                        .listRowSeparator(.hidden)
                    } else if cursor != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear {
                                Task { await loadMoreReposts() }
                            }
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await loadReposts()
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Reposts")
        .task {
            await loadReposts()
        }
    }
    
    private func loadReposts() async {
        loading = true
        initialError = nil
        pageError = nil
        
        do {
            guard let client = appState.atProtoClient else {
                throw NSError(domain: "RepostsView", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetRepostedBy.Parameters(uri: uri, limit: 50)
            
            let (responseCode, result) = try await client.app.bsky.feed.getRepostedBy(input: input)
            guard (200 ... 299).contains(responseCode), let result else {
                throw NSError(domain: "RepostsView", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected response \(responseCode)"])
            }
            
            var seen = Set<String>()
            reposts = result.repostedBy.filter { seen.insert($0.did.didString()).inserted }
            cursor = result.cursor
        } catch {
            logger.error("Failed to load reposts: \(error.localizedDescription)")
            if reposts.isEmpty {
                initialError = error
            } else {
                pageError = error
            }
        }
        
        loading = false
    }
    
    private func loadMoreReposts() async {
        guard let client = appState.atProtoClient,
              let currentCursor = cursor,
              !loading, !isLoadingPage else { return }
        
        isLoadingPage = true
        pageError = nil
        
        do {
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetRepostedBy.Parameters(
                uri: uri,
                limit: 50,
                cursor: currentCursor
            )
            
            let (responseCode, result) = try await client.app.bsky.feed.getRepostedBy(input: input)
            guard (200 ... 299).contains(responseCode), let result else {
                throw NSError(domain: "RepostsView", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected response \(responseCode)"])
            }
            
            var seen = Set(reposts.map { $0.did.didString() })
            reposts.append(contentsOf: result.repostedBy.filter { seen.insert($0.did.didString()).inserted })
            if result.cursor == currentCursor || result.repostedBy.isEmpty {
                cursor = nil
            } else {
                cursor = result.cursor
            }
        } catch {
            logger.error("Failed to load more reposts: \(error.localizedDescription)")
            pageError = error
        }
        
        isLoadingPage = false
    }
}

#Preview("RepostsView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    RepostsView(
      postUri: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l2s5xxv6fn2c",
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
