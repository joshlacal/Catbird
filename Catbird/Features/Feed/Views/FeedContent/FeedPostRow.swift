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
    var tracksVisibilityForFeedback: Bool = true
    var visibilityContext: PostVisibilityContext = .public
    @Environment(AppState.self) private var appState
    @State private var isSmartFilterRevealed = false
    @State private var isIntentRevealed = false
    @State private var isPendingIndicatorVisible = true

    init(
        viewModel: FeedPostViewModel,
        navigationPath: Binding<NavigationPath>,
        feedTypeIdentifier: String,
        tracksVisibilityForFeedback: Bool = true,
        visibilityContext: PostVisibilityContext = .public
    ) {
        self.viewModel = viewModel
        self._navigationPath = navigationPath
        self.feedTypeIdentifier = feedTypeIdentifier
        self.tracksVisibilityForFeedback = tracksVisibilityForFeedback
        self.visibilityContext = visibilityContext
    }
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            if let ruleText = viewModel.post.intentHiddenRuleText, !isIntentRevealed {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hidden by your rule: \(ruleText)")
                            .appFont(AppTextRole.subheadline.weight(.semibold))
                        Text("Filtered on-device by intent controls.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { isIntentRevealed = true }
                        .buttonStyle(.bordered)
                }
                .padding()
                .accessibilityElement(children: .combine)
            } else if viewModel.post.smartFilterCollapseRuleID != nil && !isSmartFilterRevealed {
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Collapsed by Smart Filter")
                            .appFont(AppTextRole.subheadline.weight(.semibold))
                        Text("This is a private rule on your device.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { isSmartFilterRevealed = true }
                        .buttonStyle(.bordered)
                }
                .padding()
                .accessibilityElement(children: .combine)
            } else {
                EnhancedFeedPost(
                    cachedPost: viewModel.post,
                    path: $navigationPath
                )
                .equatable()
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.navigateToPost(navigationPath: $navigationPath)
                }
                .overlay(alignment: .topTrailing) {
                    if viewModel.post.isSmartFilterPending && isPendingIndicatorVisible {
                        Image(systemName: "sparkles")
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .accessibilityLabel("Smart Filter classification pending")
                    }
                }
                .task(id: viewModel.post.isSmartFilterPending) {
                    guard viewModel.post.isSmartFilterPending else { return }
                    try? await Task.sleep(for: .seconds(3))
                    isPendingIndicatorVisible = false
                }
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
            if tracksVisibilityForFeedback, isVisible {
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
