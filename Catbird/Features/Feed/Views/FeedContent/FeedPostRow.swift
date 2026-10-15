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

private struct InvalidateFeedRowHeightKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var invalidateFeedRowHeight: (() -> Void)? {
        get { self[InvalidateFeedRowHeightKey.self] }
        set { self[InvalidateFeedRowHeightKey.self] = newValue }
    }
}

/// A feed post row that works with FeedPostViewModel for persistent state management
struct FeedPostRow: View, Identifiable {
    var id: String {
        viewModel.post.id
    }
    
    // MARK: - Properties
    
    var viewModel: FeedPostViewModel
    @Binding var navigationPath: NavigationPath
    var feedTypeIdentifier: String
    var tracksVisibilityForFeedback: Bool = true
    var visibilityContext: PostVisibilityContext = .public
    var onHeightInvalidated: (() -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.feedInteractionTarget) private var feedInteractionTarget
    @State private var isSmartFilterRevealed = false
    @State private var isIntentRevealed = false
    @State private var isPendingIndicatorVisible = true

    init(
        viewModel: FeedPostViewModel,
        navigationPath: Binding<NavigationPath>,
        feedTypeIdentifier: String,
        tracksVisibilityForFeedback: Bool = true,
        visibilityContext: PostVisibilityContext = .public,
        onHeightInvalidated: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self._navigationPath = navigationPath
        self.feedTypeIdentifier = feedTypeIdentifier
        self.tracksVisibilityForFeedback = tracksVisibilityForFeedback
        self.visibilityContext = visibilityContext
        self.onHeightInvalidated = onHeightInvalidated
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
                    Button("Show") {
                        isIntentRevealed = true
                        onHeightInvalidated?()
                    }
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
                    Button("Show") {
                        isSmartFilterRevealed = true
                        onHeightInvalidated?()
                    }
                        .buttonStyle(.bordered)
                }
                .padding()
                .accessibilityElement(children: .combine)
            } else {
                EnhancedFeedPost(
                    cachedPost: viewModel.post,
                    path: $navigationPath
                )
                .environment(\.invalidateFeedRowHeight, onHeightInvalidated)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let fvp = try? viewModel.post.feedViewPost {
                        ThreadManager.storePrefillPost(fvp.post, userDID: appState.userDID)
                    }
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
                .task(id: "\(viewModel.post.id)|\(viewModel.post.isSmartFilterPending)") {
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
            if let feedInteractionTarget {
                VStack {
                        Button {
                            guard let item = try? viewModel.post.feedViewPost else { return }
                            let postURI = item.post.uri
                            appState.feedFeedbackManager.sendShowMore(postURI: postURI, target: feedInteractionTarget,
                                feedContext: item.feedContext, reqId: item.reqId)
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
                        guard let item = try? viewModel.post.feedViewPost else { return }
                        let postURI = item.post.uri
                        appState.feedFeedbackManager.sendShowLess(postURI: postURI, target: feedInteractionTarget,
                            feedContext: item.feedContext, reqId: item.reqId)
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
        .modifier(FeedRowVisibilityModifier(tracks: tracksVisibilityForFeedback) { isVisible in
            if isVisible {
                if let item = try? viewModel.post.feedViewPost {
                    appState.feedFeedbackManager.trackPostSeen(
                        postURI: item.post.uri,
                        target: feedInteractionTarget,
                        feedContext: item.feedContext,
                        reqId: item.reqId
                    )
                }
            }
        })
        .id("\(feedTypeIdentifier)-\(viewModel.post.id)-feedback:\(feedInteractionTarget != nil)")
        .onChange(of: viewModel.post.id) { _, _ in
            isSmartFilterRevealed = false
            isIntentRevealed = false
            isPendingIndicatorVisible = true
        }
    }
}

private struct FeedRowVisibilityModifier: ViewModifier {
    let tracks: Bool
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if tracks {
            content.onScrollVisibilityChange(threshold: 0.5, action)
        } else {
            content
        }
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
