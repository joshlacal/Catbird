//
//  PostView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import AppIntents
import Nuke
import NukeUI
import Observation
import Petrel
import PetrelCatbird
import SwiftUI

// MARK: - PostState

/// Observable state shared by `PostView` and its content layout. Everything the
/// view mutates lives in this one heap object, so the view struct stays a few
/// hundred bytes (see `EquatableBox` for why that matters).
@Observable final class PostState {
  var currentUserDid: String?
  /// The shadow-merged post being displayed. Boxed so render code can read one
  /// field without copying the whole model; use `currentPost` to replace it.
  var currentPostBox: EquatableBox<AppBskyFeedDefs.PostView>
  var isAvatarLoaded = false
  var showingReportView = false
  var showingAddToListSheet = false
  var initialLoadComplete = false  // For transaction animation control
  var postError: PostViewError?  // Error state tracking
  var isShowingThreadSummary = false
  var isThreadSummaryLoading = false
  var threadSummaryText: String?
  var threadSummaryError: String?
  var canRetryThreadSummary = false
  @ObservationIgnored var threadSummaryTask: Task<Void, Never>?
  var showDeleteConfirmation = false
  var showBlockConfirmation = false
  var showMuteUserConfirmation = false
  var showMuteThreadConfirmation = false
  var isShowingCopilot = false
  var copilotContextToPresent: CopilotContext?
  var pendingDedicatedProposal: CopilotProposal?
  var showingInteractionSettings = false
  var showingLabelsOnPost = false
  var revealedMutedPreview: [String]?

  /// Shares the view's box, so creating the state copies no post data.
  init(postBox: EquatableBox<AppBskyFeedDefs.PostView>) {
    self.currentPostBox = postBox
  }

  var currentPost: AppBskyFeedDefs.PostView {
    get { currentPostBox.value }
    set { currentPostBox = EquatableBox(newValue) }
  }

  var allPostLabels: [ComAtprotoLabelDefs.Label] {
    var combined: [ComAtprotoLabelDefs.Label] = []
    if let postLabels = currentPostBox.value.labels {
      combined.append(contentsOf: postLabels)
    }
    if let authorLabels = currentPostBox.value.author.labels {
      combined.append(contentsOf: authorLabels)
    }
    return combined
  }

  /// Whether the post was authored by the signed-in user.
  var isOwnPost: Bool {
    currentPostBox.value.author.did.didString() == currentUserDid
  }

  var copilotContext: CopilotContext {
    let text: String
    if case .knownType(let record) = currentPostBox.value.record,
       let feedPost = record as? AppBskyFeedPost {
      text = feedPost.text
    } else {
      text = ""
    }
    return .post(
      uri: currentPostBox.value.uri.uriString(),
      cid: currentPostBox.value.cid.string,
      authorDID: currentPostBox.value.author.did.didString(),
      text: text,
      evidence: CopilotPostEvidenceBuilder.build(currentPostBox.value)
    )
  }
}


/// Avatar sizing for `PostView`. `.tree` is the constant compact avatar of
/// nested thread replies; every other surface uses `.regular`.
enum PostAvatarScale: Equatable, Sendable {
  case regular
  case tree

  var avatarSize: CGFloat {
    switch self {
    case .regular: ThreadReplyGeometry.linearAvatarSize
    case .tree: ThreadReplyGeometry.treeAvatarSize
    }
  }

  var containerWidth: CGFloat {
    avatarSize + 6
  }
}

/// A view that displays a single post with its content, avatar, and actions.
///
/// `PostView` owns the post's state, lifecycle work and presentation (sheets,
/// alerts, Copilot); `PostContentLayout` renders it. The split, and holding the
/// post through `EquatableBox` and `PostState`, keep this struct and its body
/// type small: a Debug build reserves a stack slot for every modifier step of
/// `body`, and with inline Petrel models one feed row overflowed the device's
/// 1 MB main-thread stack.
struct PostView: View, Identifiable {
  @Environment(SceneNavigationContext.self) private var sceneContext
  // MARK: - Environment & Properties
  @Environment(AppState.self) private var appState
  /// The post as supplied by the parent. `postState.currentPostBox` holds the
  /// shadow-merged copy that is displayed.
  private let postBox: EquatableBox<AppBskyFeedDefs.PostView>
  private let replyTarget: PostReplyTarget?
  let isParentPost: Bool
  let isSelectable: Bool
  let isToYou: Bool
  let avatarScale: PostAvatarScale
  let visibilityContext: PostVisibilityContext
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?
  @Binding var path: NavigationPath
  @Environment(\.feedPostID) private var feedPostID
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview
  // MARK: - State
  @State private var postState: PostState  // Consolidated state, including presentation flags
  @State private var contextMenuViewModel: PostContextMenuViewModel
  @State private var viewModel: PostViewModel
  var id: String {
    // Base ID from post URI and CID
    let postID = postBox.value.uri.uriString() + postBox.value.cid.string

    // If we have a feed post ID from the environment, use it to ensure uniqueness
    // This handles cases where the same post appears multiple times in a feed (e.g., multiple reposts)
    if let feedPostID = feedPostID {
      return "\(feedPostID)-\(postID)"
    } else {
      return postID
    }
  }

  // Using design tokens for consistent spacing
  fileprivate static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = DesignTokens.Size.avatarLG  // 48pt (16 * 3)
  private static let avatarContainerWidth: CGFloat = DesignTokens.Spacing.custom(18)  // 54pt (18 * 3)

  // MARK: - Initialization
  init(
    post: AppBskyFeedDefs.PostView,
    grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?,
    isParentPost: Bool,
    isSelectable: Bool,
    path: Binding<NavigationPath>,
    appState: AppState,
    isToYou: Bool = false,
    hasVisibleThreadContext: Bool = false,
    avatarScale: PostAvatarScale = .regular,
    visibilityContext: PostVisibilityContext = .public,
    rootPostURI: ATProtocolURI? = nil,
    rootAuthorDID: String? = nil,
    isReplyHiddenByThreadgate: Bool = false,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil
  ) {
    self.postBox = EquatableBox(post)
    self.replyTarget = grandparentAuthor.map { PostReplyTarget($0) }
    self.isParentPost = isParentPost
    self.isSelectable = isSelectable
    self._path = path
    self.isToYou = isToYou
    self.avatarScale = avatarScale
    self.visibilityContext = visibilityContext
    self.opThreadPostIndex = opThreadPostIndex
    self.opThreadPostCount = opThreadPostCount
    _postState = State(initialValue: PostState(postBox: postBox))  // Initialize consolidated state
    _viewModel = State(initialValue: PostViewModel(post: post, appState: appState, visibilityContext: visibilityContext))
    // The thread context, root and threadgate inputs only seed the menu model,
    // which SwiftUI keeps from the first init, so the view does not store them.
    _contextMenuViewModel = State(
      initialValue: PostContextMenuViewModel(
        appState: appState,
        post: post,
        allowsThreadSummary: (hasVisibleThreadContext || isParentPost) && (post.replyCount ?? 0) > 0,
        visibilityContext: visibilityContext,
        rootPostURI: rootPostURI,
        rootAuthorDID: rootAuthorDID,
        isReplyHiddenByThreadgate: isReplyHiddenByThreadgate
      ))
  }
  // MARK: - Body
  var body: some View {
    PostContentLayout(
      postBox: postBox,
      replyTarget: replyTarget,
      isParentPost: isParentPost,
      isSelectable: isSelectable,
      isToYou: isToYou,
      avatarScale: avatarScale,
      visibilityContext: visibilityContext,
      opThreadPostIndex: opThreadPostIndex,
      opThreadPostCount: opThreadPostCount,
      postID: id,
      postState: postState,
      contextMenuViewModel: contextMenuViewModel,
      viewModel: viewModel,
      path: $path
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("post.\(postBox.value.uri.uriString())")
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: .clear)
    .transaction { t in  // Disable initial animations
      if !postState.initialLoadComplete {
        t.animation = nil
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .modifier(PostEntityContextModifier(uri: postBox.value.uri.uriString(), isReadOnly: isReadOnlyPreview))
    .task(id: postBox) {
      await setupPost()
    }
    .onChange(of: postBox) { _, newBox in
      let newPost = newBox.value
      if isReadOnlyPreview {
        postState.currentPost = newPost
        postState.postError = Self.detectPostError(in: newPost, isReadOnlyPreview: true)
        return
      }
      // Route through the shadow instead of assigning the raw payload: a page
      // fetched before the AppView indexed a like/repost would otherwise revert
      // the optimistic state when the feed re-supplies the cell on reappear.
      Task { @MainActor in
        postState.currentPost = await appState.postShadowManager.mergeShadow(post: newPost)
      }
      if viewModel.postId != newPost.uri.uriString() || viewModel.postCid != newPost.cid {
        viewModel = PostViewModel(post: newPost, appState: appState, visibilityContext: visibilityContext)
      }
    }
    .onDisappear {
      postState.threadSummaryTask?.cancel()
      postState.threadSummaryTask = nil
    }
    .sheet(isPresented: $postState.showingReportView) {
      if let client = appState.atProtoClient {
        let reportingService = ReportingService(client: client)
        let subject = contextMenuViewModel.createReportSubject()
        let description = contextMenuViewModel.getReportDescription()

        ReportFormView(
          reportingService: reportingService,
          subject: subject,
          contentDescription: description
        )
      }
    }
    .sheet(isPresented: $postState.showingAddToListSheet) {
      AddToListSheet(
        userDID: postState.currentPostBox.value.author.did.didString(),
        userHandle: postState.currentPostBox.value.author.handle.description,
        userDisplayName: postState.currentPostBox.value.author.displayName
      )
    }
    .sheet(isPresented: $postState.isShowingThreadSummary) {
      ThreadSummarySheet(state: postState) { summarizeCurrentThread() }
    }
    .sheet(isPresented: $postState.showingInteractionSettings) {
      PostInteractionSettingsView(
        post: postState.currentPost,
        rootPostURI: contextMenuViewModel.resolvedRootPostURI ?? postState.currentPostBox.value.uri,
        isRootAuthor: contextMenuViewModel.isRootAuthor
      )
    }
    .sheet(isPresented: $postState.showingLabelsOnPost) {
      if let client = appState.atProtoClient {
        let reportingService = ReportingService(client: client)
        let handle = postState.currentPostBox.value.author.handle.description
        LabelsOnMeView(
          labels: postState.allPostLabels,
          targetDescription: "Post by @\(handle)",
          viewerDID: appState.userDID,
          reportingService: reportingService
        )
      }
    }
    .sheet(isPresented: $postState.isShowingCopilot) {
      let activeContext = postState.copilotContextToPresent ?? postState.copilotContext
      CatbirdCopilotSheet(
        context: activeContext,
        onConfirmedAction: { proposal in
          try await handleConfirmedCopilotAction(proposal, context: activeContext)
        },
        onDedicatedAction: { proposal in
          postState.pendingDedicatedProposal = proposal
        }
      )
    }
    .onChange(of: postState.isShowingCopilot) { wasShowing, isShowing in
      if wasShowing && !isShowing, let proposal = postState.pendingDedicatedProposal {
        postState.pendingDedicatedProposal = nil
        handleDedicatedProposal(proposal)
      }
    }
    .alert("Delete Post", isPresented: $postState.showDeleteConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Delete", role: .destructive) {
        Task { await contextMenuViewModel.deletePost(visibilityContext: visibilityContext) }
      }
    } message: {
      Text("Are you sure you want to delete this post? This action cannot be undone.")
    }
    .alert("Block User", isPresented: $postState.showBlockConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Block", role: .destructive) {
        Task { await contextMenuViewModel.blockUser() }
      }
    } message: {
      Text("Block @\(postState.currentPostBox.value.author.handle)? You won't see each other's posts, and they won't be able to follow you.")
    }
    .alert("Mute User", isPresented: $postState.showMuteUserConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Mute", role: .destructive) {
        Task { await contextMenuViewModel.muteUser() }
      }
    } message: {
      Text("Mute @\(postState.currentPostBox.value.author.handle)? You won't see their posts and replies in your feeds.")
    }
    .alert("Mute Thread", isPresented: $postState.showMuteThreadConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Mute", role: .destructive) {
        Task { await contextMenuViewModel.muteThread() }
      }
    } message: {
      Text("Mute this thread? You won't be notified about new replies.")
    }
  }

  @MainActor
  private func handleConfirmedCopilotAction(_ proposal: CopilotProposal, context: CopilotContext) async throws {
    let currentURI = postState.currentPostBox.value.uri.uriString()
    let currentCID = postState.currentPostBox.value.cid.string
    switch proposal {
    case .likePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !viewModel.isLiked {
        try await viewModel.toggleLike()
      }

    case .unlikePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if viewModel.isLiked {
        try await viewModel.toggleLike()
      }

    case .repostPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !viewModel.isReposted {
        try await viewModel.toggleRepost()
      }

    case .unrepostPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if viewModel.isReposted {
        try await viewModel.toggleRepost()
      }

    case .bookmarkPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !viewModel.isBookmarked {
        try await viewModel.toggleBookmark()
      }

    case .unbookmarkPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if viewModel.isBookmarked {
        try await viewModel.toggleBookmark()
      }

    case .hidePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !contextMenuViewModel.isPostHidden {
        await contextMenuViewModel.hidePost()
      }

    case .unhidePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if contextMenuViewModel.isPostHidden {
        await contextMenuViewModel.unhidePost()
      }

    default:
      try await CopilotProposalCoordinator.executeConfirmed(
        proposal,
        context: context,
        expectedAccountDID: appState.userDID,
        appState: appState
      )
    }
  }

  @MainActor
  private func handleDedicatedProposal(_ proposal: CopilotProposal) {
    let currentURI = postState.currentPostBox.value.uri.uriString()
    let currentCID = postState.currentPostBox.value.cid.string
    let authorDID = postState.currentPostBox.value.author.did.didString()

    switch proposal {
    case .reportPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else { return }
      postState.showingReportView = true

    case .deletePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else { return }
      guard authorDID == appState.userDID else { return }
      postState.showDeleteConfirmation = true

    case .addActorToList(let actorDID):
      guard actorDID == authorDID else { return }
      postState.showingAddToListSheet = true

    case .prepareReply(let uri, let cid, let text):
      guard uri == currentURI && cid == currentCID else { return }
      sceneContext.presentPostComposer(initialText: text, parentPost: postState.currentPost)

    case .prepareQuote(let uri, let cid, let text):
      guard uri == currentURI && cid == currentCID else { return }
      sceneContext.presentPostComposer(initialText: text, quotedPost: postState.currentPost)

    case .preparePostDraft(let text):
      sceneContext.presentPostComposer(initialText: text)

    default:
      break
    }
  }

  /// Set up the post and its observers
  private func setupPost() async {
    guard !Task.isCancelled else { return }
    let post = postBox.value

    // Discovery previews use the fetched payload without donating entities or
    // starting interaction/shadow work. Label decisions still run in the views.
    if isReadOnlyPreview {
      postState.currentPost = post
      postState.postError = Self.detectPostError(in: post, isReadOnlyPreview: true)
      postState.initialLoadComplete = true
      return
    }

    if postState.currentPostBox != postBox {
      postState.currentPostBox = postBox
    }
    if viewModel.postId != post.uri.uriString() || viewModel.postCid != post.cid {
      viewModel = PostViewModel(post: post, appState: appState, visibilityContext: visibilityContext)
    }

    // Check for error conditions first
    if let error = Self.detectPostError(in: post, isReadOnlyPreview: isReadOnlyPreview) {
      postState.postError = error
      postState.initialLoadComplete = true
      return
    }
    // Seed before any lifecycle wait or image prefetch. The responder may be
    // visible to AppIntentsTesting as soon as this view renders.
    if #available(iOS 18.0, *) {
      await PostEntityStore.shared.store(post)
      await ProfileEntityStore.shared.store(ProfileEntity(from: post.author))
    }
    
    // Set up report callback
    contextMenuViewModel.onReportPost = {
      postState.showingReportView = true  // Use consolidated state
    }
    
    // Set up add to list callback
    contextMenuViewModel.onAddAuthorToList = {
      postState.showingAddToListSheet = true  // Use consolidated state
    }
    
    // Set up bookmark callback
    contextMenuViewModel.onToggleBookmark = {
      Task {
        do {
          try await viewModel.toggleBookmark()
        } catch {
          logger.error("Failed to toggle bookmark: \(error)")
          if let message = UserFacingError.message(for: error, action: "update your bookmarks") {
            appState.toastManager.show(
              ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
          }
        }
      }
    }

#if canImport(FoundationModels)
    contextMenuViewModel.onSummarizeThread = {
      summarizeCurrentThread()
    }
#endif
    
    // Fetch user data
    fetchCurrentUserDid()

    // Deterministic async initialization of PostViewModel
    await viewModel.start(post: post)
    guard !Task.isCancelled else { return }

    // Preserve the thermally scaled delay
    await appState.waitForNextRefreshCycle()
    guard !Task.isCancelled else { return }

    // Prefetch the avatar image
    await prefetchAvatar()
    guard !Task.isCancelled else { return }

    // Mark initial load as complete for transaction animation control
    postState.initialLoadComplete = true

    // Structured shadow observation loop for real-time updates
    for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
      guard !Task.isCancelled else { break }
      let merged = await appState.postShadowManager.mergeShadow(post: post)
      guard !Task.isCancelled else { break }
      if merged != postState.currentPost {
        postState.currentPost = merged
      }
    }
  }
  
#if canImport(FoundationModels)
  @MainActor
  private func summarizeCurrentThread() {
    postState.threadSummaryTask?.cancel()
    postState.threadSummaryTask = nil

    postState.isShowingThreadSummary = true
    postState.isThreadSummaryLoading = true
    postState.threadSummaryText = nil
    postState.threadSummaryError = nil
    postState.canRetryThreadSummary = false

    guard appState.atProtoClient != nil else {
      postState.threadSummaryError = "Sign in to summarize threads."
      postState.isThreadSummaryLoading = false
      postState.canRetryThreadSummary = false
      return
    }

    if #available(iOS 26.0, macOS 26.0, *) {
      let agent = appState.blueskyAgent
      let targetURI = postState.currentPost.uri

      postState.threadSummaryTask = Task {
        do {
          var accumulatedText = ""
          let stream = await agent.streamThreadSummary(at: targetURI)
          
          for try await chunk in stream {
            guard !Task.isCancelled else { return }
            
            accumulatedText += chunk
            
            await MainActor.run {
              self.postState.threadSummaryText = accumulatedText
            }
          }
          
          guard !Task.isCancelled else { return }

          await MainActor.run {
            let cleaned = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let squashed = cleaned
              .lowercased()
              .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

            if cleaned.isEmpty || squashed.range(of: #"^(null)+$"#, options: .regularExpression) != nil {
              self.postState.threadSummaryError = "The model couldn’t generate a summary for this thread."
              self.postState.isThreadSummaryLoading = false
              self.postState.canRetryThreadSummary = true
            } else {
              self.postState.threadSummaryText = cleaned
              self.postState.isThreadSummaryLoading = false
              self.postState.canRetryThreadSummary = false
            }
          }
        } catch {
          guard !Task.isCancelled else { return }
          let (message, retryable) = summarizeThreadErrorMessage(for: error)
          await MainActor.run {
            self.postState.threadSummaryError = message
            self.postState.isThreadSummaryLoading = false
            self.postState.canRetryThreadSummary = retryable
          }
        }
      }
    } else {
      postState.threadSummaryError = "Thread summarization requires iOS 26 or later."
      postState.isThreadSummaryLoading = false
      postState.canRetryThreadSummary = false
    }
  }

  private func summarizeThreadErrorMessage(for error: Error) -> (String, Bool) {
    if let agentError = error as? BlueskyAgentError {
      switch agentError {
      case .missingClient:
        return ("Sign in to summarize threads.", false)
      case .notAThread:
        return ("There isn’t enough conversation to summarize yet.", false)
      case .modelUnavailable:
        return ("Apple Intelligence is still preparing. Try again in a moment.", true)
      case .foundationModelsUnavailable:
        return ("Thread summarization isn’t available on this device.", false)
      case .invalidThreadURI:
        return ("This thread can’t be summarized.", false)
      case .emptyResult(let context):
        if context.contains("post may be deleted") {
          return ("That post isn’t available anymore, so this thread can’t be summarized.", false)
        }
        if context.hasPrefix("thread fetch") || context.contains("thread (no data") || context.contains("thread (empty") {
          return ("Couldn’t load this thread to summarize. Try again.", true)
        }
        if context.contains("no valid posts") {
          return ("There isn’t enough conversation to summarize yet.", false)
        }
        return ("Couldn’t generate a summary for this thread. Try again.", true)
      case .contextLimitExceeded:
        return ("This thread is too long to summarize.", false)
      case .underlying(let underlying):
        let message = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        return (message, true)
      }
    }

    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return (message, true)
  }
#else
  @MainActor
  private func summarizeCurrentThread() {}
#endif

  /// Detect if the post has any error conditions
  fileprivate static func detectPostError(
    in post: AppBskyFeedDefs.PostView,
    isReadOnlyPreview: Bool
  ) -> PostViewError? {
    // Check if the post record can be decoded
    guard case .knownType(let record) = post.record,
          record is AppBskyFeedPost else {
      return .parseError
    }
    
    // Check if the author is blocked/blocking
    if let viewer = post.author.viewer {
      // Check if this should be shown as blocked
      let iBlockedThem = viewer.blocking != nil || viewer.blockingByList != nil
      let theyBlockedMe = viewer.blockedBy == true
      
      // Only show the blocked-content card in specific cases (e.g., thread continuity)
      // Most blocked content should be filtered out by FeedTuner
      if theyBlockedMe || (iBlockedThem && (isReadOnlyPreview || Self.shouldShowBlockedContent())) {
        // Create a BlockedPost from the available data
        let blockedAuthor = AppBskyFeedDefs.BlockedAuthor(
          did: post.author.did,
          viewer: viewer
        )
        let blockedPost = AppBskyFeedDefs.BlockedPost(
          uri: post.uri,
          blocked: true,
          author: blockedAuthor
        )
        return .blocked(blockedPost)
      }
    }
    
    // Check for other error conditions
    // Could add more sophisticated checks here
    
    return nil
  }
  
  /// Determine if blocked content should be shown (e.g., for thread continuity)
  private static func shouldShowBlockedContent() -> Bool {
    // Show blocked content if:
    // 1. We're in a thread view and this maintains continuity
    // 2. User specifically requested to see it
    // 3. It's essential for context
    
    // For now, be conservative and don't show blocked content
    // The FeedTuner should handle most filtering
    return false
  }

  /// Fetch the current user's DID
  private func fetchCurrentUserDid() {
    postState.currentUserDid = appState.userDID  // Use consolidated state
  }

  /// Get the final avatar URL with fallback handling
  private func getFinalAvatarURL() -> URL? {
    // Use postState.currentPost
    return postState.currentPostBox.value.author.finalAvatarURL()
  }

  /// Prefetch the avatar image for better performance
  /// Note: Relies on Nuke's built-in timeout handling rather than creating separate timeout tasks
  private func prefetchAvatar() async {
    guard let finalAvatarURL = getFinalAvatarURL(), !postState.isAvatarLoaded else { return }
    await ImageLoadingManager.shared.startPrefetching(urls: [finalAvatarURL])
  }

  /// Check if a post has adult content labels
  private func hasAdultContentLabel(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    guard !appState.isAdultContentEnabled else { return false }
    return labels?.contains { label in
      let lowercasedValue = label.val.lowercased()
      return lowercasedValue == "porn" || lowercasedValue == "nsfw" || lowercasedValue == "nudity"
    } ?? false
  }
}

// MARK: - PostContentLayout

/// Renders a post's avatar column and content column for `PostView`.
///
/// It is a separate view so `PostView.body`, which carries two dozen lifecycle
/// and presentation modifiers, wraps this struct's few hundred bytes instead of
/// the whole rendered layout. SwiftUI also skips re-rendering it when only
/// presentation state changes.
private struct PostContentLayout: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.feedInteractionTarget) private var feedInteractionTarget
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  /// The post as supplied to `PostView`, used for error detection and identity.
  let postBox: EquatableBox<AppBskyFeedDefs.PostView>
  let replyTarget: PostReplyTarget?
  let isParentPost: Bool
  let isSelectable: Bool
  let isToYou: Bool
  let avatarScale: PostAvatarScale
  let visibilityContext: PostVisibilityContext
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?
  let postID: String
  @Bindable var postState: PostState
  let contextMenuViewModel: PostContextMenuViewModel
  let viewModel: PostViewModel
  @Binding var path: NavigationPath

  /// The shadow-merged post being displayed.
  private var displayed: EquatableBox<AppBskyFeedDefs.PostView> {
    postState.currentPostBox
  }

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
      postAvatar
      postContentColumn
    }
  }

  private var postAvatar: some View {
    AuthorAvatarColumn(
      author: PostAvatarAuthor(getAuthorForDisplay()),
      isParentPost: isParentPost,
      isAvatarLoaded: $postState.isAvatarLoaded,
      path: $path,
      avatarScale: avatarScale
    )
  }

  private var postContentColumn: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      if let error = postState.postError
        ?? (isReadOnlyPreview ? PostView.detectPostError(in: postBox.value, isReadOnlyPreview: true) : nil) {
        // Show error content
        errorContentView(for: error)
      } else if isReadOnlyPreview && postBox.value.author.viewer?.muted == true && !showsMutedPreview {
        HStack {
          Label("Post from an account you muted", systemImage: "speaker.slash")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Show") { postState.revealedMutedPreview = mutedPreviewIdentity }
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.borderless)
        }
      } else {
        // Show normal post content with moderation
        moderatedPostContent
          .postRevealFade(isEnabled: showsMutedPreview)
      }
    }
    .padding(.top, PostView.baseUnit)
  }

  private var mutedPreviewIdentity: [String] {
    [appState.userDID, postBox.value.uri.uriString(), postBox.value.cid.description]
  }

  private var showsMutedPreview: Bool {
    postState.revealedMutedPreview == mutedPreviewIdentity
  }

  private func postHeader(for feedPost: AppBskyFeedPost) -> AnyView {
    // Keep header metadata separate from the post and embed builder. Sharing
    // this header in previews otherwise duplicates its full generic type.
    AnyView(HStack(alignment: .top, spacing: 0) {
      PostHeaderView(
        displayName: displayed.value.author.displayName
          ?? displayed.value.author.handle.description,
        handle: displayed.value.author.handle.description,
        timeAgo: feedPost.createdAt.date,
        pronouns: displayed.value.author.pronouns,
        verificationKind: VerificationBadge.kind(
          for: displayed.value.author.verification,
          did: displayed.value.author.did
        ),
        isAutomated: AutomationBadge.isSelfDeclared(
          labels: displayed.value.author.labels,
          authorDID: displayed.value.author.did
        )
      )

      Spacer()

      if let opThreadPostIndex, let opThreadPostCount {
        ThreadPostNumberView(index: opThreadPostIndex, count: opThreadPostCount)
          .padding(.trailing, 6)
      }
      if appState.appSettings.showReadingTimeEstimates,
         let minutes = PostReadingTime.minutes(for: feedPost.text) {
        Text("\(minutes) min read")
          .appCaption2()
          .foregroundStyle(.secondary)
      }

      if !isReadOnlyPreview {
        postEllipsisMenuView
      }
    }
    .padding(.horizontal, PostView.baseUnit))
  }

  // MARK: - Content Views

  @ViewBuilder
  private var moderatedPostContent: some View {
    let labels = displayed.value.labels
    let selfLabelValues = extractSelfLabelValues(from: displayed.value)
    let hasEmbed = displayed.value.embed != nil
    let labelSubject = PostLabelSubject(
      uri: displayed.value.uri.uriString(), cid: displayed.value.cid,
      authorDID: displayed.value.author.did.didString(),
      authorHandle: displayed.value.author.handle.description
    )
    if labels?.isEmpty == false || !selfLabelValues.isEmpty {
      ContentLabelView(labels: labels, selfLabelValues: selfLabelValues, subject: labelSubject)
    }
    
    // Only wrap in ContentLabelManager if:
    // 1. There's no embed (post handles its own labels), OR
    // 2. There are text-specific labels that don't apply to the embed
    if !hasEmbed && (labels?.isEmpty == false || !selfLabelValues.isEmpty) {
      ContentLabelManager(labels: labels, selfLabelValues: selfLabelValues, contentType: "post", selfLabelsAlreadyShown: true) {
        normalPostContent
      }
      .environment(\.postLabelSummaryIDs, labelSubject.labelIDs(in: labels))
    } else {
      // Embeds handle their own visibility policy. The post owns its label summary.
      normalPostContent
        .environment(\.postLabelSummaryIDs, labelSubject.labelIDs(in: labels))
    }
  }

  @ViewBuilder
  private var normalPostContent: some View {
    // The post-level summary remains outside concealed text and media.
    postContentView
      .padding(.bottom, PostView.baseUnit)

    // Embed content (images, links, videos, etc.)
    if let embed = displayed.value.embed {
      embedContent(embed, labels: displayed.value.labels)
        .environment(\.postID, postID)
        .padding(.bottom, PostView.baseUnit)
    }

    if !isReadOnlyPreview {
      ActionButtonsView(
        post: displayed,
        postViewModel: viewModel,
        path: $path
      )
      .padding(.bottom, PostView.baseUnit)
    }
  }

  @ViewBuilder
  private func errorContentView(for error: PostViewError) -> some View {
    switch error {
    case .blocked(let blockedPost):
      BlockedContentCard(
        relationship: BlockRelationship(blockedPost: blockedPost),
        authorDid: blockedPost.author.did.didString(),
        postUri: blockedPost.uri,
        variant: .feed,
        path: $path
      )

    case .notFound(let reason):
      PostNotFoundView(uri: postBox.value.uri, reason: reason, path: $path)

    case .parseError:
      PostNotFoundView(uri: postBox.value.uri, reason: .parseError, path: $path)

    case .permissionDenied:
      PostNotFoundView(uri: postBox.value.uri, reason: .permissionDenied, path: $path)
    }
  }

  // MARK: - Component Views (AuthorAvatarColumn extracted)

  // Post content area
  private var postContentView: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Render the shadow-merged post
      if case .knownType(let postObj) = displayed.value.record,
        let feedPost = postObj as? AppBskyFeedPost {

        postHeader(for: feedPost)

        if let replyTarget {
          replyIndicatorView(replyTarget: replyTarget)
            .textScale(.secondary)
            .padding(.top, PostView.baseUnit)
        } else if isToYou {
            replyIndicatorView(replyTarget: nil)
                .textScale(.secondary)
                .padding(.top, PostView.baseUnit)
            }

        PostRecordText(record: EquatableBox(feedPost), isSelectable: isSelectable, path: $path)
          .allowsHitTesting(!isReadOnlyPreview)
          .disabled(isReadOnlyPreview)
          .padding(.top, PostView.baseUnit)
      }
    }
  }

  // MARK: - Helper Views

  // Default avatar placeholder (moved to AuthorAvatarColumn)

  // Line connecting parent and child posts (moved to AuthorAvatarColumn)

  // Post menu (three dots)
  private var postEllipsisMenuView: some View {
    Menu {
      if CopilotAvailability.isAvailable {
        Button {
          postState.copilotContextToPresent = postState.copilotContext
          postState.isShowingCopilot = true
        } label: {
          Label("Ask Catbird", systemImage: "sparkles")
        }

        Divider()
      }

      // Only show "Add to List" for other users' posts
      if !postState.isOwnPost {
        Button(action: {
          contextMenuViewModel.addAuthorToList()
        }) {
          Label("Add Author to List", systemImage: "list.bullet.rectangle")
        }
        
        Divider()
      }
      
#if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *), contextMenuViewModel.allowsThreadSummary, CopilotAvailability.isAvailable {
        Button(action: {
          let rootURI: String
          if case .knownType(let record) = displayed.value.record,
             let feedPost = record as? AppBskyFeedPost,
             let replyRootUri = feedPost.reply?.root.uri.uriString() {
            rootURI = replyRootUri
          } else {
            rootURI = displayed.value.uri.uriString()
          }
          postState.copilotContextToPresent = .thread(anchorURI: rootURI)
          postState.isShowingCopilot = true
        }) {
          Label("Ask Catbird About Thread", systemImage: "sparkles")
        }

        Divider()
      }
#endif

      // Bookmark button - available for all posts
      Button(action: {
        contextMenuViewModel.toggleBookmark()
      }) {
        Label(
          viewModel.isBookmarked ? "Remove Bookmark" : "Bookmark",
          systemImage: viewModel.isBookmarked ? "bookmark.fill" : "bookmark"
        )
      }
      
      // Show More / Show Less options, only inside a feed that accepts feedback
      if let feedInteractionTarget {
        Divider()
        
        Button(action: {
          contextMenuViewModel.sendShowMore(target: feedInteractionTarget)
        }) {
          Label("Show More Like This", systemImage: "hand.thumbsup")
        }
        
        Button(action: {
          contextMenuViewModel.sendShowLess(target: feedInteractionTarget)
        }) {
          Label("Show Less Like This", systemImage: "hand.thumbsdown")
        }
      }
      
      Divider()
      
      // Only show mute/block for other users' posts
      if !postState.isOwnPost {
        Button(action: {
          if DestructiveActionConfirmation.shouldConfirm(
            isEnabled: appState.appSettings.confirmBeforeActions
          ) {
            postState.showMuteUserConfirmation = true
          } else {
            Task { await contextMenuViewModel.muteUser() }
          }
        }) {
          Label("Mute User", systemImage: "speaker.slash")
        }

        Button(role: .destructive, action: {
          postState.showBlockConfirmation = true
        }) {
          Label("Block User", systemImage: "exclamationmark.octagon")
        }
      }

      if case .public = visibilityContext {
        Button(action: {
          if DestructiveActionConfirmation.shouldConfirm(
            isEnabled: appState.appSettings.confirmBeforeActions
          ) {
            postState.showMuteThreadConfirmation = true
          } else {
            Task { await contextMenuViewModel.muteThread() }
          }
        }) {
          Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
        }
      }
      
      // Only show hide/report for other users' posts
      if !postState.isOwnPost {
        // Hide/Unhide post option
        Button(action: {
          Task {
            if contextMenuViewModel.isPostHidden {
              await contextMenuViewModel.unhidePost()
            } else {
              await contextMenuViewModel.hidePost()
            }
          }
        }) {
          Label(
            contextMenuViewModel.isPostHidden ? "Unhide Post" : "Hide Post",
            systemImage: contextMenuViewModel.isPostHidden ? "eye" : "eye.slash"
          )
        }

        Button(action: {
          postState.showingReportView = true  // Use consolidated state
        }) {
          Label("Report Post", systemImage: "flag")
        }

        // Threadgate OP Moderation (G13): Root author can hide/show replies for everyone
        if contextMenuViewModel.isRootAuthor {
          Button(action: {
            Task {
              if contextMenuViewModel.isReplyHiddenByThreadgate {
                await contextMenuViewModel.unhideReplyForEveryone()
              } else {
                await contextMenuViewModel.hideReplyForEveryone()
              }
            }
          }) {
            Label(
              contextMenuViewModel.isReplyHiddenByThreadgate ? "Show Reply for Everyone" : "Hide Reply for Everyone",
              systemImage: contextMenuViewModel.isReplyHiddenByThreadgate ? "eye" : "eye.slash"
            )
          }
        }

        // Postgate Quote Detachment (G14): Author of quoted post can detach/re-attach quote
        if contextMenuViewModel.quotedPostURI != nil {
          Button(action: {
            Task {
              if contextMenuViewModel.isQuoteDetached {
                await contextMenuViewModel.reattachQuote()
              } else {
                await contextMenuViewModel.detachQuote()
              }
            }
          }) {
            Label(
              contextMenuViewModel.isQuoteDetached ? "Re-attach Quote" : "Detach Quote",
              systemImage: contextMenuViewModel.isQuoteDetached ? "link" : "arrow.branch"
            )
          }
        }
      }

      if postState.isOwnPost {
        Button(action: {
          Task { await contextMenuViewModel.togglePin() }
        }) {
          if contextMenuViewModel.isPinned {
            Label("Unpin from Profile", systemImage: "pin.slash")
          } else {
            Label("Pin to Profile", systemImage: "pin")
          }
        }

        Button(action: {
          postState.showingInteractionSettings = true
        }) {
          Label("Edit Interaction Settings", systemImage: "slider.horizontal.3")
        }

        Button(action: {
          postState.showingLabelsOnPost = true
        }) {
          Label("View Labels", systemImage: "tag")
        }
        Button(role: .destructive, action: {
          postState.showDeleteConfirmation = true
        }) {
          Label("Delete Post", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
        .padding(PostView.baseUnit * 3)
        .contentShape(Rectangle())
        .accessibilityLabel("Post Options")
        .accessibilityAddTraits(.isButton)
        
    }
  }

  // Reply indicator text
  @ViewBuilder
  private func replyIndicatorView(replyTarget: PostReplyTarget? = nil) -> some View {
    HStack(alignment: .center, spacing: PostView.baseUnit) {
      Image(systemName: "arrow.up.forward.circle")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
        .appBody()

      HStack(spacing: 0) {
        Text("In reply to ")
          .appBody()
          .offset(y: -1)
          .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))

        if isToYou {
          Text("you")
            .appBody()
            .offset(y: -1)
            .foregroundStyle(Color("AccentTextColor"))
        } else if let replyTarget {
          Text(verbatim: "@\(replyTarget.handle)")
            .appBody()
            .offset(y: -1)
            .foregroundStyle(Color("AccentTextColor"))
            .onTapGesture {
              guard !isReadOnlyPreview else { return }
              path.append(NavigationDestination.profile(replyTarget.did))
            }
            .accessibilityAddTraits(.isButton)
        }
      }
    }
    .padding(.leading, PostView.baseUnit)
  }

  // Media content (images, links, videos, etc.)
  @ViewBuilder
  private func embedContent(
    _ embed: AppBskyFeedDefs.PostViewEmbedUnion, labels: [ComAtprotoLabelDefs.Label]?
  ) -> some View {
    PostEmbed(
      embed: embed,
      labels: labels,
      path: $path,
      visibilityContext: visibilityContext,
      authorDID: postBox.value.author.did
    )
      .environment(\.postID, postID)
      .padding(.trailing, PostView.baseUnit * 2)
  }

  // MARK: - Setup & Helpers

  /// Get the author to display in the avatar column
  private func getAuthorForDisplay() -> AppBskyActorDefs.ProfileViewBasic {
    // If there's an error, try to extract author info from the error
    if let error = postState.postError {
      switch error {
      case .blocked(let blockedPost):
        // Create placeholder from blocked author. The literal handle is always
        // valid today; never trap the feed if validation ever tightens.
        return AppBskyActorDefs.ProfileViewBasic(
          did: blockedPost.author.did,
          handle: PlaceholderAuthors.blockedHandle ?? displayed.value.author.handle,
          displayName: nil,
          pronouns: nil, avatar: nil,
          associated: nil,
          viewer: blockedPost.author.viewer,
          labels: nil,
          createdAt: nil,
          verification: nil,
          status: nil,
          debug: nil

        )
      case .notFound, .parseError, .permissionDenied:
        // Generic placeholder for deleted/not found posts
        return PlaceholderAuthors.deleted ?? displayed.value.author
      }
    }

    // Normal case - return actual post author
    return displayed.value.author
  }

  // Extract self-applied label values from the record (if present)
  private func extractSelfLabelValues(from postView: AppBskyFeedDefs.PostView) -> [String] {
    guard case .knownType(let record) = postView.record,
          let feedPost = record as? AppBskyFeedPost,
          let postLabels = feedPost.labels else { return [] }

    switch postLabels {
    case .comAtprotoLabelDefsSelfLabels(let selfLabels):
      return selfLabels.values.map { $0.val.lowercased() }
    default:
      return []
    }
  }
}

// MARK: - Small view inputs

/// The author a reply line points at. Only the handle and DID are rendered, so
/// `PostView` stores these instead of a full profile (about 2 KB inline).
struct PostReplyTarget: Equatable {
  let handle: String
  let did: String

  init(_ author: AppBskyActorDefs.ProfileViewBasic) {
    handle = author.handle.description
    did = author.did.didString()
  }
}

/// The author fields `AuthorAvatarColumn` renders, so it does not store a full
/// profile (about 2 KB inline).
struct PostAvatarAuthor: Equatable {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: URL?
  /// Kept whole because the live check compares `expiresAt` with the current
  /// time when the column renders.
  let status: EquatableBox<AppBskyActorDefs.StatusView>?

  init(_ author: AppBskyActorDefs.ProfileViewBasic) {
    did = author.did.didString()
    handle = author.handle.description
    displayName = author.displayName
    avatarURL = author.finalAvatarURL()
    status = author.status.map { EquatableBox($0) }
  }
}

/// Builds `Post` in its own update, so the record and the text view's state stay
/// out of `PostContentLayout`'s body type.
private struct PostRecordText: View {
  let record: EquatableBox<AppBskyFeedPost>
  let isSelectable: Bool
  @Binding var path: NavigationPath

  var body: some View {
    Post(post: record.value, isSelectable: isSelectable, path: $path)
  }
}


enum PostReadingTime {
  private static let wordsPerMinute = 200

  static func minutes(for text: String) -> Int? {
    let count = text.split(whereSeparator: { $0.isWhitespace }).count
    return minutes(forWordCount: count)
  }

  static func minutes(forWordCount count: Int) -> Int? {
    guard count >= 100 else { return nil }
    return Int(ceil(Double(count) / Double(wordsPerMinute)))
  }
}

enum DestructiveActionConfirmation {
  static func shouldConfirm(isEnabled: Bool) -> Bool { isEnabled }
}

private struct ThreadSummarySheet: View {
  /// Read directly so the summary streams into the open sheet.
  let state: PostState
  let onRetry: () -> Void

  @Environment(\.dismiss) private var dismiss

  private var authorDisplayName: String {
    state.currentPostBox.value.author.displayName ?? state.currentPostBox.value.author.handle.description
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        header

        content

        Spacer()

        if state.canRetryThreadSummary && !state.isThreadSummaryLoading {
          Button("Try Again", action: onRetry)
            .buttonStyle(.borderedProminent)
        }

        Text("Summaries run on-device with Apple Intelligence.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(DesignTokens.Spacing.lg)
      .navigationTitle("Thread Summary")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(authorDisplayName)
        .font(.headline)

      Text("@\(state.currentPostBox.value.author.handle.description)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let summaryText = state.threadSummaryText {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          Text(summaryText)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)

          if state.isThreadSummaryLoading {
            ProgressView()
              .padding(.top, DesignTokens.Spacing.xs)
          }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
      }
    } else if state.isThreadSummaryLoading {
      VStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
        ProgressView()
        Text("Summarizing thread…")
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, DesignTokens.Spacing.lg)
    } else if let errorText = state.threadSummaryError {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(errorText)
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, DesignTokens.Spacing.lg)
    } else {
      Text("No summary is available right now.")
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.vertical, DesignTokens.Spacing.lg)
    }
  }
}

// MARK: - Extracted AuthorAvatarColumn View
struct AuthorAvatarColumn: View {
  let author: PostAvatarAuthor
  let isParentPost: Bool
  @Binding var isAvatarLoaded: Bool
  @Binding var path: NavigationPath
  var avatarScale: PostAvatarScale = .regular
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  private var avatarSize: CGFloat { avatarScale.avatarSize }
  private var avatarContainerWidth: CGFloat { avatarScale.containerWidth }

  // Reusable image request for avatars
  private var avatarRequest: (URL) -> ImageRequest {
    { url in
      ImageLoadingManager.imageRequest(
        for: url,
        targetSize: CGSize(width: avatarSize, height: avatarSize)
      )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let finalURL = author.avatarURL {
        LazyImage(request: avatarRequest(finalURL)) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(1, contentMode: .fill)
              .frame(width: avatarSize, height: avatarSize)
              .clipShape(Circle())
              .contentShape(Circle())
              .overlay(liveStatusRing)
              .onAppear { isAvatarLoaded = true }
          } else if state.isLoading {
            // Use placeholder defined below when loading
            avatarPlaceholder
          } else {
            // Use placeholder or error view if not loading and no image
            noAvatarView  // Or a specific error view
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        // Placeholder is handled inside the content closure now
        .onTapGesture {
          openProfile()
        }
      } else {
        noAvatarView
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .frame(width: avatarContainerWidth)
    .padding(.horizontal, Self.baseUnit)
    .padding(.top, Self.baseUnit)
    .background(parentPostIndicator)
    .modifier(AuthorAvatarAccessibility(
      label: isReadOnlyPreview ? authorName : "\(authorName), view profile",
      isEnabled: !isPlaceholderAuthor && !isReadOnlyPreview,
      action: openProfile))
    // Do not add a ProfileEntity context inside a PostEntity-annotated post.
    // iOS 27 can flatten nested entity contexts during view annotation
    // collection and hydrate the author's DID as the surrounding PostEntity.
    // Dedicated profile/search surfaces donate ProfileEntity context instead.
  }

  /// Deleted and unavailable posts carry a stand-in author with no real profile.
  private var isPlaceholderAuthor: Bool {
    author.did == "did:plc:unknown"
  }

  private var authorName: String {
    if let displayName = author.displayName, !displayName.isEmpty {
      return displayName
    }
    return "@\(author.handle)"
  }

  private func openProfile() {
    guard !isPlaceholderAuthor, !isReadOnlyPreview else { return }
    path.append(NavigationDestination.profile(author.did))
  }

  // Default avatar placeholder
  private var noAvatarView: some View {
    Image(systemName: "person.crop.circle")
      .resizable()
      .aspectRatio(1, contentMode: .fit)
      .frame(width: avatarSize, height: avatarSize)
      .foregroundColor(.gray)
      .overlay(liveStatusRing)
      .onTapGesture {
        openProfile()
      }
  }

  // Placeholder view for loading state
  private var avatarPlaceholder: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .frame(width: avatarSize, height: avatarSize)
      .overlay(ProgressView().scaleEffect(0.8))  // Optional: add a smaller ProgressView
      .overlay(liveStatusRing)
  }

  // Red ring shown while the author has an active live status
  @ViewBuilder
  private var liveStatusRing: some View {
    if author.status?.value.isLiveNow == true {
      Circle()
        .strokeBorder(Color.red, lineWidth: 2)
    }
  }

  // Line connecting parent and child posts
  @ViewBuilder
  private var parentPostIndicator: some View {
    if isParentPost {
      Rectangle()
        .fill(Color.systemGray4)
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .padding(.bottom, avatarSize + Self.baseUnit * 2)
        .offset(y: avatarSize + Self.baseUnit * 3)
    }
  }
}

// MARK: - PostID Environment
private struct ReadOnlyPostPreviewKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Rendering policy for discovery previews, including nested quote/media views.
  var isReadOnlyPostPreview: Bool {
    get { self[ReadOnlyPostPreviewKey.self] }
    set { self[ReadOnlyPostPreviewKey.self] = newValue }
  }
}

private struct PostEntityContextModifier: ViewModifier {
  let uri: String
  let isReadOnly: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isReadOnly {
      content
    } else {
      content.entityContext(EntityIdentifier(for: PostEntity.self, identifier: uri))
    }
  }
}

struct PostIDKey: EnvironmentKey {
  static let defaultValue: String = ""
}

extension EnvironmentValues {
  var postID: String {
    get { self[PostIDKey.self] }
    set { self[PostIDKey.self] = newValue }
  }
}

// MARK: - PostViewError
/// Indirect so a blocked post's 1.6 KB payload is not stored inline in `PostState`
/// or copied into view temporaries.
indirect enum PostViewError {
    case blocked(AppBskyFeedDefs.BlockedPost)
    case notFound(PostNotFoundReason)
    case parseError
    case permissionDenied
}


#Preview("PostView") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPostView(from: appState)
  } content: { appState, postView in
    ScrollView {
      PostView(
        post: postView,
        grandparentAuthor: nil,
        isParentPost: false,
        isSelectable: true,
        path: .constant(NavigationPath()),
        appState: appState
      )
    }
  }
}

/// Placeholder authors for blocked and deleted posts, built without `try!` so a
/// stricter identifier validator can never crash feed rendering.
/// Exposes the avatar column as one "view profile" button to VoiceOver, or hides
/// it when there is no profile to open.
private struct AuthorAvatarAccessibility: ViewModifier {
  let label: String
  let isEnabled: Bool
  let action: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    } else {
      content.accessibilityHidden(true)
    }
  }
}

enum PlaceholderAuthors {
  static let blockedHandle = try? Handle(handleString: "blocked.user")

  static let deleted: AppBskyActorDefs.ProfileViewBasic? = {
    guard let did = try? DID(didString: "did:plc:unknown"),
      let handle = try? Handle(handleString: "deleted.user") else { return nil }
    return AppBskyActorDefs.ProfileViewBasic(
      did: did, handle: handle, displayName: nil, pronouns: nil, avatar: nil,
      associated: nil, viewer: nil, labels: nil, createdAt: nil,
      verification: nil, status: nil, debug: nil
    )
  }()
}
