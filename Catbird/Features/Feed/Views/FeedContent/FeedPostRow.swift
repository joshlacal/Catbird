//
//  FeedPostRow.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  SwiftUI view for individual feed posts within UIKit collection view
//

import SwiftUI
import Petrel
import os

/// A feed post row that works with FeedPostViewModel for persistent state management
struct FeedPostRow: View, Equatable {
    static func == (lhs: FeedPostRow, rhs: FeedPostRow) -> Bool {
        lhs.viewModel.post.id == rhs.viewModel.post.id
    }
    
    // MARK: - Properties
    
    var viewModel: FeedPostViewModel
    @Binding var navigationPath: NavigationPath
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            EnhancedFeedPost(
                cachedPost: viewModel.post,
                path: $navigationPath
            )
            .equatable()
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.navigateToPost(navigationPath: $navigationPath)
            }
            
            // Full-width divider
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.identity)
    }
    
}

// MARK: - Equatable


// MARK: - Preview Support

//#Preview {
//    @State var navigationPath = NavigationPath()
//    
//    // Create a mock post for preview
//    let mockPost = CachedFeedViewPost(
//        id: "preview-post",
//        feedViewPost: AppBskyFeedDefs.FeedViewPost(
//            post: AppBskyFeedDefs.PostView(
//                uri: try! ATProtocolURI(uriString: "at://did:example/app.bsky.feed.post/preview"),
//                cid: "preview-cid",
//                author: AppBskyActorDefs.ProfileViewBasic(
//                    did: try! DID(didString: "did:example:123"),
//                    handle: Handle(handle: "preview.user"),
//                    displayName: "Preview User",
//                    avatar: nil,
//                    associated: nil,
//                    viewer: nil,
//                    labels: [],
//                    createdAt: nil
//                ),
//                record: ATProtocolValueContainer(
//                    lexicon: "app.bsky.feed.post",
//                    data: Data()
//                ),
//                embed: nil,
//                replyCount: 0,
//                repostCount: 0,
//                likeCount: 0,
//                quoteCount: 0,
//                indexedAt: ATProtocolDate(date: Date()),
//                viewer: nil,
//                labels: [],
//                threadgate: nil
//            ),
//            reply: nil,
//            reason: nil,
//            feedContext: nil, reqId: nil
//        )
//    )
//    
//    let mockViewModel = FeedPostViewModel(post: mockPost, appState: AppState.shared)
//    
//    NavigationStack(path: $navigationPath) {
//        FeedPostRow(
//            viewModel: mockViewModel,
//            navigationPath: $navigationPath
//        )
//        .padding()
//    }
//}
//
