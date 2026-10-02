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
    var title: String? = nil
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var likes: [AppBskyFeedGetLikes.Like] = []

    private var resolvedTitle: String {
        if let title {
            return title
        }
        if postUri.contains("app.bsky.labeler.service") {
            return "Liked By"
        }
        return "Likes"
    }

    private var contentMaxWidth: CGFloat {
        hSizeClass == .compact ? .infinity : 600
    }
    @State private var loading: Bool = true
    @State private var isLoadingPage: Bool = false
    @State private var initialError: Error?
    @State private var pageError: Error?
    @State private var cursor: String?
    var body: some View {
        VStack {
            if loading && likes.isEmpty {
                ProgressView()
                    .padding()
            } else if let initialError = initialError, likes.isEmpty {
                VStack(spacing: 12) {
                    Text("Error loading likes: \(initialError.localizedDescription)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        Task { await loadLikes() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if likes.isEmpty {
                Text("No likes yet")
                    .padding()
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(likes, id: \.actor.did) { like in
                        ProfileRowView(profile: like.actor, path: $path)
                            .mainContentFrame()
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets())
                    }

                    if let pageError = pageError {
                        VStack(spacing: 8) {
                            Text("Failed to load more: \(pageError.localizedDescription)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await loadMoreLikes() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                    } else if cursor != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear {
                                Task { await loadMoreLikes() }
                            }
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await loadLikes()
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle(resolvedTitle)
        .task {
            await loadLikes()
        }
    }
    
    private func loadLikes() async {
        loading = true
        initialError = nil
        pageError = nil
        
        do {
            guard let client = appState.atProtoClient else {
                throw NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetLikes.Parameters(uri: uri, limit: 50)
            
            let (responseCode, result) = try await client.app.bsky.feed.getLikes(input: input)
            guard (200 ... 299).contains(responseCode) else {
                throw NSError(
                    domain: "LikesView",
                    code: responseCode,
                    userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"]
                )
            }
            guard let result else {
                throw NSError(
                    domain: "LikesView",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Empty response from server"]
                )
            }
            
            var seen = Set<DID>()
            var uniqueLikes: [AppBskyFeedGetLikes.Like] = []
            for like in result.likes {
                if seen.insert(like.actor.did).inserted {
                    uniqueLikes.append(like)
                }
            }
            likes = uniqueLikes
            cursor = result.cursor
        } catch {
            self.initialError = error
        }
        
        loading = false
    }
    
    private func loadMoreLikes() async {
        guard let currentCursor = cursor, !isLoadingPage else { return }
        isLoadingPage = true
        pageError = nil
        
        do {
            guard let client = appState.atProtoClient else {
                throw NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
            }
            
            let uri = try ATProtocolURI(uriString: postUri)
            let input = AppBskyFeedGetLikes.Parameters(uri: uri, limit: 50, cursor: currentCursor)
            
            let (responseCode, result) = try await client.app.bsky.feed.getLikes(input: input)
            guard (200 ... 299).contains(responseCode) else {
                throw NSError(
                    domain: "LikesView",
                    code: responseCode,
                    userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(responseCode)"]
                )
            }
            guard let result else {
                throw NSError(
                    domain: "LikesView",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Empty response from server"]
                )
            }
            
            var seen = Set(likes.map(\.actor.did))
            var newLikes: [AppBskyFeedGetLikes.Like] = []
            for like in result.likes {
                if seen.insert(like.actor.did).inserted {
                    newLikes.append(like)
                }
            }
            likes.append(contentsOf: newLikes)
            if result.cursor == currentCursor || result.likes.isEmpty {
                self.cursor = nil
            } else {
                self.cursor = result.cursor
            }
        } catch {
            self.pageError = error
        }
        
        isLoadingPage = false
    }
}

#Preview("LikesView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    LikesView(
      postUri: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l2s5xxv6fn2c",
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
