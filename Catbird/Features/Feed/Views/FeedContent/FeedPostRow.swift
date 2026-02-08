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
struct FeedPostRow: View, Equatable, Identifiable {
    var id: String {
        viewModel.post.id
    }
    
    static func == (lhs: FeedPostRow, rhs: FeedPostRow) -> Bool {
        lhs.viewModel.post.id == rhs.viewModel.post.id
    }
    
    // MARK: - Properties
    
    var viewModel: FeedPostViewModel
    @Binding var navigationPath: NavigationPath
    var feedTypeIdentifier: String
    @Environment(AppState.self) private var appState
    
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
                .fill(Color.separator)
                .frame(height: 0.5)
        }
        #if os(macOS)
        // macOS uses SwiftUI List - add swipe actions here
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if appState.feedFeedbackManager.isEnabled {
                VStack {
                        Button {
                            guard let postURI = try? viewModel.post.feedViewPost.post.uri, appState.feedFeedbackManager.isEnabled else { return }
                            appState.feedFeedbackManager.sendShowMore(postURI: postURI)
                            logger.debug("Sent 'show more' feedback for post: \(postURI)")
                            
                            // Show confirmation toast
                            appState.toastManager.show(
                                ToastItem(
                                    message: "Feedback sent",
                                    icon: "checkmark.circle.fill"
                                )
                            )
                        } label: {
                            Label("Show More Like This", systemImage: "hand.thumbsup.fill")
                                .imageScale(.large)
                                .labelStyle(.iconOnly)

                        }
                        .tint(.green)
                    
                    
                    Button {
                        guard let postURI = try? viewModel.post.feedViewPost.post.uri, appState.feedFeedbackManager.isEnabled else { return }
                        appState.feedFeedbackManager.sendShowLess(postURI: postURI)
                        logger.debug("Sent 'show less' feedback for post: \(postURI)")
                        
                        // Show confirmation toast
                        appState.toastManager.show(
                            ToastItem(
                                message: "Feedback sent",
                                icon: "checkmark.circle.fill"
                            )
                        )
                    } label: {
                        Label("Show Less Like This", systemImage: "hand.thumbsdown.fill")
                            .imageScale(.large)
                            .labelStyle(.iconOnly)
                    }
                    .tint(.red)
                }
            }
            
        }
        #endif
        .platformIgnoresSafeArea(.container, edges: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.identity)
        // Track post visibility for feed feedback (iOS 18.0+/macOS 15.0+)
        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
            if isVisible {
                if let postURI = try? ATProtocolURI(uriString: viewModel.post.feedViewPost.post.uri.uriString()) {
                    appState.feedFeedbackManager.trackPostSeen(postURI: postURI)
                }
            }
        }
        .id("\(feedTypeIdentifier)-\(viewModel.post.id)-feedback:\(appState.feedFeedbackManager.isEnabled)")
    }
    
}

// MARK: - Equatable


// MARK: - Preview Support

//#Preview {
//    @Previewable @Environment(AppState.self) var appState
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
//    let mockViewModel = FeedPostViewModel(post: mockPost, appState: appState)
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
