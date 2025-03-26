//
//  ActionButtonsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import SwiftUI
import Petrel
import Observation

/// A view displaying interaction buttons for a post (like, reply, repost, share)
struct ActionButtonsView: View {
    // MARK: - Environment & Properties
    @Environment(AppState.self) private var appState
    
    // Post to display actions for
    let post: AppBskyFeedDefs.PostView
    
    @State private var isFirstAppear = true
    
    // View model for handling actions
    @State private var viewModel: ActionButtonViewModel
    @State private var showRepostOptions: Bool = false
    @State private var showingPostComposer: Bool = false
    
    // States for displaying interaction counts
    @State private var isLiked: Bool = false
    @State private var isReposted: Bool = false
    @State private var likeCount: Int = 0
    @State private var repostCount: Int = 0
    @State private var replyCount: Int = 0
    
    @State private var animateLike: Bool = false
    @State private var animateRepost: Bool = false
    @State private var initialLoadComplete: Bool = false
    
    // Customization option - just one flag as requested
    let isBig: Bool
    @Binding var path: NavigationPath
    
    // Using multiples of 3 for spacing
    private static let baseUnit: CGFloat = 3
    
    // MARK: - Initialization
    init(post: AppBskyFeedDefs.PostView, postViewModel: PostViewModel, path: Binding<NavigationPath>, isBig: Bool = false) {
        self.post = post
        self._viewModel = State(wrappedValue: ActionButtonViewModel(
            postId: post.uri.uriString(),
            postViewModel: postViewModel,
            appState: postViewModel.appState
        ))
        self._path = path
        self.isBig = isBig
        
        // Initialize like/repost state directly from post
        self._isLiked = State(initialValue: post.viewer?.like != nil)
        self._isReposted = State(initialValue: post.viewer?.repost != nil)
        
        // Initialize counts
        self._likeCount = State(initialValue: post.likeCount ?? 0)
        self._repostCount = State(initialValue: post.repostCount ?? 0)
        self._replyCount = State(initialValue: post.replyCount ?? 0)
    }
    
    // MARK: - Body
    var body: some View {
        HStack {
            // Reply Button
            InteractionButton(
                iconName: "bubble.left",
                count: isBig ? nil : replyCount,
                isActive: false,
                isFirstAppear: isFirstAppear,
                color: .secondary,
                isBig: isBig
            ) {
                showingPostComposer = true
            }
            Spacer()
            
            // Repost Button (includes quote option)
            InteractionButton(
                iconName: "arrow.2.squarepath",
                count: isBig ? nil : repostCount,
                isActive: isReposted,
                animateActivation: animateRepost,
                animateScale: initialLoadComplete,
                isFirstAppear: isFirstAppear,
                color: isReposted ? .green : .secondary,
                isBig: isBig
            ) {
                showRepostOptions = true
            }
            
            Spacer()
            
            // Like Button - NO optimistic updates in the view
            InteractionButton(
                iconName: isLiked ? "heart.fill" : "heart",
                count: isBig ? nil : likeCount,
                isActive: isLiked,
                animateActivation: animateLike,
                animateScale: initialLoadComplete,
                isFirstAppear: isFirstAppear,
                color: isLiked ? .red : .secondary,
                isBig: isBig
            ) {
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                // Set animation flag to true
                animateLike = true
                
                Task {
                    try? await viewModel.toggleLike()
                    // UI state will be updated via the shadow manager
                }
            }
            Spacer()
            
            // Share Button (system share sheet only)
            InteractionButton(
                iconName: "square.and.arrow.up",
                count: nil, // Share doesn't have a count
                isActive: false,
                isFirstAppear: isFirstAppear,
                color: .secondary,
                isBig: isBig
            ) {
                Task {
                    await viewModel.share(post: post)
                }
            }
        }
        .font(isBig ? .title3 : .callout)
        .frame(height: isBig ? 54 : 45)
        .padding(.trailing, ActionButtonsView.baseUnit * 4)
        .onAppear {
            // Set isFirstAppear to false after a tiny delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFirstAppear = false
            }
        }
        .task {
            // Initial state setup
            await refreshState()
            
            // Mark initial load as complete after a brief delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                initialLoadComplete = true
            }
            
            // Continuous updates
            for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
                await refreshState()
            }
        }
        .sheet(isPresented: $showRepostOptions) {
            RepostOptionsView(post: post, viewModel: viewModel)
                .presentationDetents([.fraction(1/4)])
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(12)
        }
        .sheet(isPresented: $showingPostComposer) {
            PostComposerView(parentPost: post, appState: appState)
        }
    }
    
    // MARK: - State Management
    private func refreshState() async {
        let mergedPost = await appState.postShadowManager.mergeShadow(post: post)
        await MainActor.run {
            // Add debug log to track count changes
            let oldLikeCount = likeCount
            
            isLiked = mergedPost.viewer?.like != nil
            isReposted = mergedPost.viewer?.repost != nil
            likeCount = mergedPost.likeCount ?? 0
            repostCount = mergedPost.repostCount ?? 0
            replyCount = mergedPost.replyCount ?? 0
            
            if oldLikeCount != likeCount {
                print("Like count changed: \(oldLikeCount) -> \(likeCount)")
            }
        }
    }
}

struct InteractionButton: View {
    let iconName: String
    let count: Int?
    let isActive: Bool
    var animateActivation: Bool = false
    var animateScale: Bool = true
    var isFirstAppear: Bool = false
    let color: Color
    let isBig: Bool
    let action: () -> Void
    
    // Calculate extra width needed for counts
    private var buttonMinWidth: CGFloat {
        if let count = count, count > 0 {
            // Add more space for buttons with counts
            return isBig ? 58 : 46
        } else {
            // Original width for buttons without counts
            return isBig ? 48 : 36
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { // Slightly increased spacing
                Image(systemName: iconName)
                    .fontWeight(isBig ? .regular : .semibold)
                    .contentTransition(isFirstAppear ? .identity : .symbolEffect(.replace))
                    .imageScale(isBig ? .large : .medium)
                    .symbolEffect(.bounce, options: .speed(1.5), value: animateActivation)
                
                if let count = count, count > 0 {
                    Text(count.formatted)
                        // tabular numbers
                        .font(Font.system(.caption).monospacedDigit())
                        .fontWeight(.bold)
                        .contentTransition(.numericText(countsDown: false))
                        .lineLimit(1)
                        .fixedSize() // Prevent truncation
                        .layoutPriority(1) // Give priority to the text
                }
            }
            .foregroundStyle(color)
            .frame(minWidth: buttonMinWidth, minHeight: isBig ? 40 : 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 1.05 : 1.0)
        .animation(animateScale ? .snappy(duration: 0.2) : nil, value: isActive)
    }
}
