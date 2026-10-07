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
#elseif os(macOS)
import AppKit
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
    let newIsLiked = post.viewer?.like != nil
    let newIsReposted = post.viewer?.repost != nil
    let newLikeCount = post.likeCount ?? 0
    let newRepostCount = post.repostCount ?? 0
    let newReplyCount = post.replyCount ?? 0

    if self.isLiked != newIsLiked { self.isLiked = newIsLiked }
    if self.isReposted != newIsReposted { self.isReposted = newIsReposted }
    if self.likeCount != newLikeCount { self.likeCount = newLikeCount }
    if self.repostCount != newRepostCount { self.repostCount = newRepostCount }
    if self.replyCount != newReplyCount { self.replyCount = newReplyCount }
  }
}

/// A view displaying interaction buttons for a post (like, reply, repost, share)
struct ActionButtonsView: View {
  // MARK: - Environment & Properties
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.feedInteractionTarget) private var feedInteractionTarget

  // Post to display actions for. Boxed because an inline `PostView` is about
  // 3 KB, and `.task(id:)`, `.onChange(of:)` and `PostShareMenu` would each
  // store another copy in this view's body type.
  private let postBox: EquatableBox<AppBskyFeedDefs.PostView>
  let postViewModel: PostViewModel
  @State private var isFirstAppear = true

  // View model for handling actions
  @State private var viewModel: ActionButtonViewModel

  // Consolidated interaction state
  @State private var interactionState: PostInteractionState

  // State for managing animations and loading
  @State private var initialLoadComplete: Bool = false

  // Customization option
  let isBig: Bool
  @Binding var path: NavigationPath

  // Shared haptic feedback generator

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3

  // MARK: - Initialization
  init(
    post: AppBskyFeedDefs.PostView, postViewModel: PostViewModel, path: Binding<NavigationPath>,
    isBig: Bool = false
  ) {
    self.init(post: EquatableBox(post), postViewModel: postViewModel, path: path, isBig: isBig)
  }

  /// Takes a post the caller has already boxed, skipping the copy into a new box.
  init(
    post: EquatableBox<AppBskyFeedDefs.PostView>, postViewModel: PostViewModel,
    path: Binding<NavigationPath>, isBig: Bool = false
  ) {
    self.postBox = post
    self.postViewModel = postViewModel
    self._path = path
    self.isBig = isBig
    self._viewModel = State(
      wrappedValue: ActionButtonViewModel(
        postId: post.value.uri.uriString(),
        postViewModel: postViewModel,
        appState: postViewModel.appState
      ))

    // Initialize consolidated state
    self._interactionState = State(initialValue: PostInteractionState(post: post.value))

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
        .accessibilityLabel(countedLabel("Reply", count: interactionState.replyCount, singular: "reply", plural: "replies"))
      .disabled(postBox.value.viewer?.replyDisabled ?? false)
      // Subtle glass and mark as the matched transition source for this post
      .padding(.vertical, isBig ? 3 : 2)
      .frame(maxWidth: .infinity, alignment: .leading)

      repostMenu
        .accessibilityIdentifier("repostButton")
        .frame(maxWidth: .infinity, alignment: .leading)

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
        PlatformHaptics.medium()

        // Set animation flag to true
        interactionState.animateLike = true

        let wasLiked = interactionState.isLiked
        Task {
          do {
            try await viewModel.toggleLike(feedInteractionTarget: feedInteractionTarget)
          } catch {
            logger.error("Error toggling like: \(error)")
            showFailureToast(
              for: error, action: wasLiked ? "remove your like" : "like this post")
          }
          // UI state will be updated via the shadow manager and refreshState
          // Reset animation flag after a short delay if needed
          try? await Task.sleep(for: .milliseconds(500))  // Adjust delay as needed
          await MainActor.run { interactionState.animateLike = false }
        }
      }
      .accessibilityIdentifier("likeButton")
      .accessibilityLabel(countedLabel(
        interactionState.isLiked ? "Unlike" : "Like",
        count: interactionState.likeCount, singular: "like", plural: "likes"))
      .frame(maxWidth: .infinity, alignment: .leading)

      PostShareMenu(post: postBox, appState: appState, isBig: isBig)

    }
    .font(isBig ? .title3 : .callout)
    .frame(height: isBig ? 54 : 45)
    .padding(.leading, ActionButtonsView.baseUnit)
    .padding(.trailing, ActionButtonsView.baseUnit * 4)
    .onAppear {
      // Set isFirstAppear to false after a tiny delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isFirstAppear = false
      }
    }
    .task(id: postBox) {
      if viewModel.postId != postBox.value.uri.uriString() {
        viewModel = ActionButtonViewModel(
          postId: postBox.value.uri.uriString(),
          postViewModel: postViewModel,
          appState: postViewModel.appState
        )
      }

      // Initial state setup
      await refreshState()
      guard !Task.isCancelled else { return }

      // Mark initial load complete after brief delay
      async let markInitialLoad: Void = {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        initialLoadComplete = true
      }()

      // Structured task loop for continuous updates with debouncing
      var lastUpdate = Date.distantPast
      let debounceInterval: TimeInterval = 0.1  // 100ms debounce to prevent excessive re-renders

      for await _ in await appState.postShadowManager.shadowUpdates(forUri: postBox.value.uri.uriString()) {
        guard !Task.isCancelled else { break }
        let now = Date()
        if now.timeIntervalSince(lastUpdate) >= debounceInterval {
          lastUpdate = now
          await refreshState()
        }
      }
      _ = await markInitialLoad
    }
    .onChange(of: postBox) { _, newPost in
      if viewModel.postId != newPost.value.uri.uriString() {
        viewModel = ActionButtonViewModel(
          postId: newPost.value.uri.uriString(),
          postViewModel: postViewModel,
          appState: postViewModel.appState
        )
      }
      Task { await refreshState() }
    }
    .id(appState.userDID)
  }

  private var repostMenu: some View {
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
      .disabled(postBox.value.viewer?.embeddingDisabled ?? false)
    } label: {
      repostLabel
    }
    .id("repost-\(postBox.value.uri.uriString())")
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
    countedLabel(
      interactionState.isReposted ? "Remove Repost" : "Repost or Quote Post",
      count: interactionState.repostCount, singular: "repost", plural: "reposts")
  }

  /// VoiceOver label such as "Like, 3 likes".
  private func countedLabel(_ action: String, count: Int, singular: String, plural: String) -> String {
    "\(action), \(count) \(count == 1 ? singular : plural)"
  }

  private func showFailureToast(for error: Error, action: String) {
    guard let message = UserFacingError.message(for: error, action: action) else { return }
    appState.toastManager.show(
      ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
  }

  private var repostMenuMinWidth: CGFloat {
    if isBig {
      return 48
    }
    return interactionState.repostCount > 0 ? 46 : 36
  }

  // MARK: - Reply Handling
  
  private func handleReplyTap() {
    guard !sceneContext.isInvalidated, sceneContext.accountDID == appState.userDID else { return }
    appState.feedFeedbackManager.trackReply(postURI: postBox.value.uri, target: feedInteractionTarget)
    sceneContext.presentPostComposer(initialText: nil, parentPost: postBox.value, quotedPost: nil)
  }

  private func handleRepostToggle() {
    PlatformHaptics.medium()

    let wasReposted = interactionState.isReposted
    Task {
      do {
        try await viewModel.toggleRepost(feedInteractionTarget: feedInteractionTarget)
      } catch {
        logger.error("Error toggling repost: \(error)")
        showFailureToast(
          for: error, action: wasReposted ? "remove your repost" : "repost this post")
      }
    }
  }

  private func handleQuotePost() {
    guard !sceneContext.isInvalidated, sceneContext.accountDID == appState.userDID else { return }
    appState.feedFeedbackManager.trackQuote(postURI: postBox.value.uri, target: feedInteractionTarget)
    sceneContext.presentPostComposer(initialText: nil, parentPost: nil, quotedPost: postBox.value)
  }
  
  // MARK: - State Management
  private func refreshState() async {
    let mergedPost = await appState.postShadowManager.mergeShadow(post: postBox.value)
    interactionState.update(from: mergedPost)
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

/// Shared feed, thread and video entry point. Sheets belong to the originating
/// view rather than whichever application window happens to be first.
struct PostShareMenu: View {
  @Environment(SceneNavigationContext.self) private var sceneContext

  // Boxed: this menu sits in every post's action row, where an inline
  // `PostView` would add about 3 KB to each enclosing body type.
  private let postBox: EquatableBox<AppBskyFeedDefs.PostView>
  let appState: AppState
  var isBig = false
  var onChooseChat: (() -> Void)?
  var onCopyLink: ((URL) -> Void)?
  var onChooseMore: (() -> Void)?

  @State private var destination: Destination?

  init(
    post: AppBskyFeedDefs.PostView,
    appState: AppState,
    isBig: Bool = false,
    onChooseChat: (() -> Void)? = nil,
    onCopyLink: ((URL) -> Void)? = nil,
    onChooseMore: (() -> Void)? = nil
  ) {
    self.init(
      post: EquatableBox(post),
      appState: appState,
      isBig: isBig,
      onChooseChat: onChooseChat,
      onCopyLink: onCopyLink,
      onChooseMore: onChooseMore
    )
  }

  /// Takes a post the caller has already boxed, skipping the copy into a new box.
  init(
    post: EquatableBox<AppBskyFeedDefs.PostView>,
    appState: AppState,
    isBig: Bool = false,
    onChooseChat: (() -> Void)? = nil,
    onCopyLink: ((URL) -> Void)? = nil,
    onChooseMore: (() -> Void)? = nil
  ) {
    self.postBox = post
    self.appState = appState
    self.isBig = isBig
    self.onChooseChat = onChooseChat
    self.onCopyLink = onCopyLink
    self.onChooseMore = onChooseMore
  }

  private struct Destination: Identifiable {
    enum Kind { case chat, native }
    let id = UUID()
    let kind: Kind
    let sceneContext: SceneNavigationContext
  }

  private var isValidOrigin: Bool {
    !sceneContext.isInvalidated && sceneContext.accountDID == appState.userDID
  }

  var body: some View {
    Menu {
      #if os(iOS)
      Button {
        guard isValidOrigin else { return }
        if let onChooseChat { onChooseChat() } else {
          destination = Destination(kind: .chat, sceneContext: sceneContext)
        }
      } label: {
        Label("Send via Chat", systemImage: "bubble.left.and.bubble.right")
      }
      .disabled(!appState.isAuthenticated && onChooseChat == nil)
      .accessibilityIdentifier("shareToBlueskyChat")

      #endif

      Button {
        guard isValidOrigin, let url = ActionButtonViewModel.shareURL(for: postBox.value) else { return }
        if let onCopyLink {
          onCopyLink(url)
        } else {
          copyLink(url)
        }
      } label: {
        Label("Copy Link", systemImage: "link")
      }
      .accessibilityIdentifier("copyPostLink")
      .disabled(ActionButtonViewModel.shareURL(for: postBox.value) == nil)

      #if os(iOS)
      Button {
        guard isValidOrigin else { return }
        if let onChooseMore { onChooseMore() } else {
          destination = Destination(kind: .native, sceneContext: sceneContext)
        }
      } label: {
        Label("More…", systemImage: "square.and.arrow.up")
      }
      .accessibilityIdentifier("morePostSharing")
      #else
      if let url = ActionButtonViewModel.shareURL(for: postBox.value) {
        ShareLink(item: url) {
          Label("More…", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("morePostSharing")
      }
      #endif
    } label: {
      Image(systemName: "square.and.arrow.up")
        .appFont(Font.TextStyle.callout)
        .fontWeight(isBig ? .medium : .semibold)
        .imageScale(isBig ? .large : .medium)
        // Concrete `Color.secondary`, not the hierarchical `.secondary` style:
        // inside a Menu label the hierarchical style resolves against the
        // menu's accent tint and renders blue. Matches reply/repost/like.
        .foregroundStyle(Color.secondary)
        .frame(minWidth: isBig ? 48 : 36, minHeight: isBig ? 40 : 32, alignment: .trailing)
        .contentShape(Rectangle())
    }
    .tint(Color.secondary)
    .disabled(!isValidOrigin)
    .accessibilityIdentifier("shareButton")
    .accessibilityLabel("Share post")
    .sheet(item: $destination) { destination in
      shareDestination(destination)
    }
    .onChange(of: destination?.sceneContext.isInvalidated) { _, isInvalidated in
      if isInvalidated == true { destination = nil }
    }
    .onChange(of: sceneContext.accountDID) { _, _ in
      destination = nil
    }
    .onChange(of: sceneContext.sceneID) { _, _ in
      destination = nil
    }
  }

  @ViewBuilder
  private func shareDestination(_ destination: Destination) -> some View {
    #if os(iOS)
    if !destination.sceneContext.isInvalidated,
       destination.sceneContext.accountDID == appState.userDID {
      switch destination.kind {
      case .chat:
        ModernChatSelectionView(post: postBox.value, appState: appState, sceneContext: destination.sceneContext) {
          self.destination = nil
        }
        .applyAppStateEnvironment(appState)
        .environment(destination.sceneContext)
      case .native:
        NativePostShareSheet(post: postBox.value, appState: appState, sceneContext: destination.sceneContext)
      }
    }
    #else
    if let url = ActionButtonViewModel.shareURL(for: postBox.value) {
      ShareLink(item: url)
    }
    #endif
  }

  private func copyLink(_ url: URL) {
    #if os(iOS)
    UIPasteboard.general.url = url
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([url as NSURL])
    #endif
    PlatformHaptics.light()
    appState.toastManager.show(ToastItem(message: "Link copied", icon: "link"))
  }
}
