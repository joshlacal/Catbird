//
//  ActionButtonsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Observation
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Observable class to hold interaction state for a post
@Observable class PostInteractionState {
  var isLiked: Bool
  var isReposted: Bool
  var likeCount: Int
  var repostCount: Int
  var replyCount: Int
  var animateLike: Bool = false

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
  @State private var showingPostComposer: Bool = false
  @State private var showingRepostOptions: Bool = false
  // Per-post matched transition namespace for reply → composer zoom
  @Namespace private var replyTransition

  // Consolidated interaction state
  @State private var interactionState: PostInteractionState

  // State for managing animations and loading
  @State private var initialLoadComplete: Bool = false
  @State private var updateTask: Task<Void, Error>?  // Task for shadow updates

  // Customization option
  let isBig: Bool
  @Binding var path: NavigationPath

  // Shared haptic feedback generator
#if os(iOS)
  @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  // Unique zoom source id per post to ensure correct return target
  private var replySourceID: String { "reply-\(post.uri.uriString())" }

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
        handleReplyTap()
      }
      .accessibilityIdentifier("replyButton")
        .accessibilityLabel("Reply. Replies count: \(post.replyCount ?? 0)")
      .disabled(post.viewer?.replyDisabled ?? false)
      // Subtle glass and mark as the matched transition source for this post
      .padding(.vertical, isBig ? 3 : 2)
      .padding(.horizontal, isBig ? 6 : 5)
      #if os(iOS)
      .modifier(ReplyZoomSource(id: replySourceID, namespace: replyTransition))
      #endif
      Spacer()

      repostMenu
      .accessibilityIdentifier("repostButton")

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
#if os(iOS)
        feedbackGenerator.impactOccurred()
#endif

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

      // Start cancellable task for continuous updates with debouncing
      updateTask = Task {
        var lastUpdate = Date.distantPast
        let debounceInterval: TimeInterval = 0.1  // 100ms debounce to prevent excessive re-renders

        for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
          try Task.checkCancellation()  // Check if task was cancelled
          let now = Date()
          if now.timeIntervalSince(lastUpdate) >= debounceInterval {
            lastUpdate = now
            await refreshState()
          }
        }
      }
    }
    .onDisappear {
      // Cancel the update task when the view disappears
      updateTask?.cancel()
      updateTask = nil
    }
    .sheet(isPresented: $showingPostComposer) {
      Group {
        PostComposerViewUIKit(
          parentPost: post,
          appState: appState
        )
        .applyAppStateEnvironment(appState)
        #if os(iOS)
        .presentationDetents({
          if #available(iOS 26.0, *) { return [.large] } else { return [PresentationDetent.large] }
        }())
        .presentationDragIndicator({
          if #available(iOS 26.0, *) { return .visible } else { return .hidden }
        }())
        #endif
      }
      #if os(iOS)
      // Link the composer sheet to this reply button's transition namespace
      .modifier(ReplyZoomDestination(id: replySourceID, namespace: replyTransition))
      #endif
    }
    .id(appState.userDID)
  }

  private var repostMenu: some View {
    Group {
      #if os(iOS)
      if #available(iOS 27.0, *) {
        repostDialogButton
      } else {
        repostMenuControl
      }
      #else
      repostMenuControl
      #endif
    }
  }

  private var repostDialogButton: some View {
    Button {
      showingRepostOptions = true
    } label: {
      repostLabel
    }
    .buttonStyle(.plain)
    .confirmationDialog(
      "Repost",
      isPresented: $showingRepostOptions,
      titleVisibility: .hidden
    ) {
      Button(repostActionTitle) {
        handleRepostToggle()
      }
      if !(post.viewer?.embeddingDisabled ?? false) {
        Button("Quote Post") {
          handleQuotePost()
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var repostMenuControl: some View {
    Menu {
      Button {
        handleRepostToggle()
      } label: {
        Label(repostActionTitle, systemImage: "arrow.2.squarepath")
      }

      Button {
        handleQuotePost()
      } label: {
        Label("Quote Post", systemImage: "quote.bubble")
      }
      .disabled(post.viewer?.embeddingDisabled ?? false)
    } label: {
      repostLabel
    }
    .id("repost-\(post.uri.uriString())")
  }

  private var repostLabel: some View {
    HStack(spacing: 4) {
      Image(systemName: "arrow.2.squarepath")
        .appFont(Font.TextStyle.callout)
        .fontWeight(isBig ? .medium : .semibold)
        .imageScale(isBig ? .large : .medium)

      if !isBig, interactionState.repostCount > 0 {
        Text(interactionState.repostCount.formatted)
          .appFont(Font.TextStyle.caption)
          .monospacedDigit()
          .fontWeight(.bold)
          .lineLimit(1)
          .fixedSize()
          .layoutPriority(1)
      }
    }
    .foregroundStyle(interactionState.isReposted ? .green : .secondary)
    .frame(minWidth: repostMenuMinWidth, minHeight: isBig ? 40 : 32, alignment: .leading)
    .contentShape(Rectangle())
    .compositingGroup()
    .accessibilityLabel(repostAccessibilityLabel)
    .accessibilityAddTraits(.isButton)
  }

  private var repostActionTitle: String {
    interactionState.isReposted ? "Remove Repost" : "Repost"
  }

  private var repostAccessibilityLabel: String {
    interactionState.isReposted
      ? "Remove Repost. Repost count: \(interactionState.repostCount)"
      : "Repost or Quote Post. Repost count: \(interactionState.repostCount)"
  }

  private var repostMenuMinWidth: CGFloat {
    if isBig {
      return 48
    }
    return interactionState.repostCount > 0 ? 46 : 36
  }

  // MARK: - Reply Handling
  
  private func handleReplyTap() {
    let parentPostURI = post.uri.uriString()
    
    // Check for conflicting draft
    if appState.composerDraftManager.hasConflictingDraft(parentPostURI: parentPostURI, quotedPostURI: nil) {
      // Show alert asking user what to do with existing draft
      // For now, just clear the existing draft and proceed
      appState.composerDraftManager.clearDraft()
    }
    
    // Track reply interaction for feed feedback
    appState.feedFeedbackManager.trackReply(postURI: post.uri)
    
    showingPostComposer = true
  }

  private func handleRepostToggle() {
#if os(iOS)
    feedbackGenerator.impactOccurred()
#endif

    Task {
      do {
        try await viewModel.toggleRepost()
      } catch {
        logger.debug("Error toggling repost: \(error)")
      }
    }
  }

  private func handleQuotePost() {
    appState.presentPostComposer(quotedPost: post)
  }
  
  // MARK: - State Management
  private func refreshState() async {
    let mergedPost = await appState.postShadowManager.mergeShadow(post: post)
    await MainActor.run {
      interactionState.update(from: mergedPost)
    }
  }
}

struct InteractionButtonLabel: View {
  let iconName: String
  let count: Int?
  var animateActivation: Bool = false
  var isFirstAppear: Bool = false
  let color: Color
  let isBig: Bool

  private static let smallWidths: [Bool: CGFloat] = [true: 46, false: 36]
  private static let bigWidths: [Bool: CGFloat] = [true: 58, false: 48]

  private var buttonMinWidth: CGFloat {
    let widths = isBig ? InteractionButtonLabel.bigWidths : InteractionButtonLabel.smallWidths
    let hasVisibleCount = count != nil && count! > 0
    return widths[hasVisibleCount]!
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: iconName)
        .appFont(Font.TextStyle.callout)
        .fontWeight(isBig ? .medium : .semibold)
        .contentTransition(isFirstAppear ? .identity : .symbolEffect(.replace))
        .imageScale(isBig ? .large : .medium)
        .symbolEffect(.bounce, options: .speed(1.5), value: animateActivation)

      if let count = count, count > 0 {
        Text(count.formatted)
          .appFont(Font.TextStyle.caption)
          .monospacedDigit()
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
  @Environment(\.fontManager) private var fontManager

  var body: some View {
    Button(action: action) {
      InteractionButtonLabel(
        iconName: iconName,
        count: count,
        animateActivation: animateActivation,
        isFirstAppear: isFirstAppear,
        color: color,
        isBig: isBig
      )
    }
    .buttonStyle(.plain)
    // Apply scale effect animation only when animateScale is true
    .accessibleScaleEffect(isActive ? 1.05 : 1.0, appState: appState)
    // Conditionally apply animation based on animateScale flag
    .accessibleAnimation(animateScale ? .snappy(duration: 0.2) : nil, value: isActive, appState: appState)
  }
}

#if os(iOS)
// MARK: - Matched transition helpers (iOS 26+ safe wrappers)
private struct ReplyZoomSource: ViewModifier {
  let id: String
  let namespace: Namespace.ID
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.matchedTransitionSource(id: id, in: namespace) { source in
        source
      }
    } else {
      content
    }
  }
}

private struct ReplyZoomDestination: ViewModifier {
  let id: String
  let namespace: Namespace.ID
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.navigationTransition(.zoom(sourceID: id, in: namespace))
    } else {
      content
    }
  }
}
#endif

#Preview("ActionButtonsView") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPostView(from: appState)
  } content: { appState, postView in
    ActionButtonsView(
      post: postView,
      postViewModel: PostViewModel(post: postView, appState: appState),
      path: .constant(NavigationPath())
    )
  }
}
