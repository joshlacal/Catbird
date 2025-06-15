//
//  ActionButtonsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Observation
import Petrel
import SwiftUI

/// Observable class to hold interaction state for a post
@Observable class PostInteractionState {
  var isLiked: Bool
  var isReposted: Bool
  var likeCount: Int
  var repostCount: Int
  var replyCount: Int
  var animateLike: Bool = false
  var animateRepost: Bool = false  // Keep separate for distinct animations

  init(post: AppBskyFeedDefs.PostView) {
    self.isLiked = post.viewer?.like != nil
    self.isReposted = post.viewer?.repost != nil
    self.likeCount = post.likeCount ?? 0
    self.repostCount = post.repostCount ?? 0
    self.replyCount = post.replyCount ?? 0
      
  }

  func update(from post: AppBskyFeedDefs.PostView) {
    let oldLikeCount = self.likeCount  // For debug logging

    self.isLiked = post.viewer?.like != nil
    self.isReposted = post.viewer?.repost != nil
    self.likeCount = post.likeCount ?? 0
    self.repostCount = post.repostCount ?? 0
    self.replyCount = post.replyCount ?? 0

    #if DEBUG
      if oldLikeCount != self.likeCount {
        logger.debug("Like count changed: \(oldLikeCount) -> \(self.likeCount)")
      }
    #endif
  }
}

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

  // Consolidated interaction state
  @State private var interactionState: PostInteractionState

  // State for managing animations and loading
  @State private var initialLoadComplete: Bool = false
  @State private var updateTask: Task<Void, Error>?  // Task for shadow updates

  // Customization option
  let isBig: Bool
  @Binding var path: NavigationPath

  // Shared haptic feedback generator
  @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3

  // MARK: - Initialization
  init(
    post: AppBskyFeedDefs.PostView, postViewModel: PostViewModel, path: Binding<NavigationPath>,
    isBig: Bool = false
  ) {
    self.post = post
    self._viewModel = State(
      wrappedValue: ActionButtonViewModel(
        postId: post.uri.uriString(),
        postViewModel: postViewModel,
        appState: postViewModel.appState
      ))
    self._path = path
    self.isBig = isBig

    // Initialize consolidated state
    self._interactionState = State(initialValue: PostInteractionState(post: post))
      
//      if case let .knownType(threadgate) = post.threadgate?.record,
//         let threadgate = threadgate as? AppBskyFeedThreadgate {
//          if threadgate.allow
//      }

  }

  // MARK: - Body
  var body: some View {
    HStack {
      // Reply Button
      InteractionButton(
        iconName: "bubble.left",
        count: isBig ? nil : interactionState.replyCount,
        isActive: false,
        isFirstAppear: isFirstAppear,
        color: .secondary,
        isBig: isBig
      ) {
        showingPostComposer = true
      }
      .accessibilityIdentifier("replyButton")
        .accessibilityLabel("Reply. Replies count: \(post.replyCount ?? 0)")
      .disabled(post.viewer?.replyDisabled ?? false)
      Spacer()

      // Repost Button (includes quote option)
      InteractionButton(
        iconName: "arrow.2.squarepath",
        count: isBig ? nil : interactionState.repostCount,
        isActive: interactionState.isReposted,
        animateActivation: interactionState.animateRepost,  // Use state property
        animateScale: initialLoadComplete,
        isFirstAppear: isFirstAppear,
        color: interactionState.isReposted ? .green : .secondary,
        isBig: isBig
      ) {
        showRepostOptions = true
        // Trigger repost animation if needed (logic might go in RepostOptionsView or viewModel)
        // interactionState.animateRepost = true // Example trigger point
      }
      .accessibilityIdentifier("repostButton")
      .accessibilityLabel(interactionState.isReposted ? "Remove Repost. Repost count: \(interactionState.repostCount)" : "Repost or Quote Post. Repost count: \(interactionState.repostCount)")

      Spacer()

      // Like Button
      InteractionButton(
        iconName: interactionState.isLiked ? "heart.fill" : "heart",
        count: isBig ? nil : interactionState.likeCount,
        isActive: interactionState.isLiked,
        animateActivation: interactionState.animateLike,  // Use state property
        animateScale: initialLoadComplete,
        isFirstAppear: isFirstAppear,
        color: interactionState.isLiked ? .red : .secondary,
        isBig: isBig
      ) {
        // Haptic feedback using shared generator
        feedbackGenerator.impactOccurred()

        // Set animation flag to true
        interactionState.animateLike = true

        Task {
          try? await viewModel.toggleLike()
          // UI state will be updated via the shadow manager and refreshState
          // Reset animation flag after a short delay if needed
          try? await Task.sleep(for: .milliseconds(500))  // Adjust delay as needed
          await MainActor.run { interactionState.animateLike = false }
        }
      }
        .accessibilityIdentifier("likeButton")
        .accessibilityLabel(interactionState.isLiked ? "Unlike. Like count: \(interactionState.likeCount)" : "Like. Like count: \(interactionState.likeCount)")
        
      Spacer()

      // Share Button (system share sheet only)
      InteractionButton(
        iconName: "square.and.arrow.up",
        count: nil,  // Share doesn't have a count
        isActive: false,
        isFirstAppear: isFirstAppear,
        color: .secondary,
        isBig: isBig
      ) {
        Task {
          await viewModel.share(post: post)
        }
      }
      .accessibilityIdentifier("shareButton")
        .accessibilityLabel("Share")
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

      // Wait 0.5 seconds then mark initial load complete
      try? await Task.sleep(for: .milliseconds(500))
      await MainActor.run { initialLoadComplete = true }

      // Start cancellable task for continuous updates
      updateTask = Task {
        for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
          try Task.checkCancellation()  // Check if task was cancelled
          await refreshState()
        }
      }
    }
    .onDisappear {
      // Cancel the update task when the view disappears
      updateTask?.cancel()
      updateTask = nil
    }
    .sheet(isPresented: $showRepostOptions) {
      RepostOptionsView(post: post, viewModel: viewModel)
        .presentationDetents([.fraction(1 / 4)])
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
      interactionState.update(from: mergedPost)
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
  
  @Environment(AppState.self) private var appState

  // Pre-calculated widths for efficiency
  private static let smallWidths: [Bool: CGFloat] = [true: 46, false: 36]  // true: has count > 0, false: no count or count == 0
  private static let bigWidths: [Bool: CGFloat] = [true: 58, false: 48]  // true: has count > 0, false: no count or count == 0

  // Calculate min width based on pre-calculated values
  private var buttonMinWidth: CGFloat {
    let widths = isBig ? InteractionButton.bigWidths : InteractionButton.smallWidths
    let hasVisibleCount = count != nil && count! > 0
    return widths[hasVisibleCount]!
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: iconName)
              .fontWeight(isBig ? .medium : .semibold)
          // Use identity transition on first appear to prevent initial animation
          .contentTransition(isFirstAppear ? .identity : .symbolEffect(.replace))
          .imageScale(isBig ? .large : .medium)
          // Trigger bounce only when animateActivation becomes true
          .symbolEffect(.bounce, options: .speed(1.5), value: animateActivation)

        if let count = count, count > 0 {
          Text(count.formatted)
            .font(Font.system(.caption).monospacedDigit())
            .fontWeight(.bold)
            .contentTransition(.numericText(countsDown: false))
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
        }
      }
      .foregroundStyle(color)
      .frame(minWidth: buttonMinWidth, minHeight: isBig ? 40 : 32, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Apply scale effect animation only when animateScale is true
    .accessibleScaleEffect(isActive ? 1.05 : 1.0, appState: appState)
    // Conditionally apply animation based on animateScale flag
    .accessibleAnimation(animateScale ? .snappy(duration: 0.2) : nil, value: isActive, appState: appState)
  }
}
