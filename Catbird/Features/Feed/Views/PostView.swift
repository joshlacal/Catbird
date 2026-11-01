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
  /// Not observed: nothing renders from it, and observing its write (once per
  /// row, when the avatar loads) re-rendered the whole row while scrolling.
  @ObservationIgnored var isAvatarLoaded = false
  var showingReportView = false
  var showingAddToListSheet = false
  /// Read live by the row's `.transaction` closure to skip animations until
  /// loaded. Not observed for the same reason as `isAvatarLoaded`.
  @ObservationIgnored var initialLoadComplete = false
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
  /// The hidden row's cause identity the viewer chose to show (see
  /// `PostModerationPresentation.filterIdentity`).
  var revealedModerationFilter: String?

  /// Shares the view's box, so creating the state copies no post data. The account is
  /// known up front so the first render already reflects it, instead of a second render
  /// once `setupPost` runs.
  init(postBox: EquatableBox<AppBskyFeedDefs.PostView>, currentUserDid: String? = nil) {
    self.currentPostBox = postBox
    self.currentUserDid = currentUserDid
  }

  /// Synchronously resets transient per-post state when a cell is reused for a different post.
  func reset(for newBox: EquatableBox<AppBskyFeedDefs.PostView>, currentUserDid: String?) {
    threadSummaryTask?.cancel()
    threadSummaryTask = nil
    self.currentUserDid = currentUserDid
    self.currentPostBox = newBox
    self.isAvatarLoaded = false
    self.initialLoadComplete = false
    self.postError = nil
    self.isShowingThreadSummary = false
    self.isThreadSummaryLoading = false
    self.threadSummaryText = nil
    self.threadSummaryError = nil
    self.canRetryThreadSummary = false
    self.copilotContextToPresent = nil
    self.pendingDedicatedProposal = nil
    self.revealedMutedPreview = nil
    self.revealedModerationFilter = nil
  }

  /// Whether any of the post's sheets or alerts is requested; `PostView` installs its
  /// presentations only while this is true.
  var hasPresentation: Bool {
    showingReportView || showingAddToListSheet || isShowingThreadSummary
      || showingInteractionSettings || showingLabelsOnPost || isShowingCopilot
      || showDeleteConfirmation || showBlockConfirmation || showMuteUserConfirmation
      || showMuteThreadConfirmation
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
/// `PostView` owns the post's state and lifecycle work, and presents its sheets,
/// alerts and Copilot through `PostPresentationsModifier`; `PostContentLayout`
/// renders it. The split, and holding the
/// post through `EquatableBox` and `PostState`, keep this struct and its body
/// type small: a Debug build reserves a stack slot for every modifier step of
/// `body`, and with inline Petrel models one feed row overflowed the device's
/// 1 MB main-thread stack.
struct PostView: View, Identifiable {
  // MARK: - Environment & Properties
  @Environment(AppState.self) private var appState
  /// The post as supplied by the parent. `postState.currentPostBox` holds the
  /// shadow-merged copy that is displayed.
  private let postBox: EquatableBox<AppBskyFeedDefs.PostView>
  private let replyTarget: PostReplyTarget?
  let isParentPost: Bool
  let isSelectable: Bool
  let isToYou: Bool
  let hasVisibleThreadContext: Bool
  let avatarScale: PostAvatarScale
  let visibilityContext: PostVisibilityContext
  let rootPostURI: ATProtocolURI?
  let rootAuthorDID: String?
  let isReplyHiddenByThreadgate: Bool
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
    postBox: EquatableBox<AppBskyFeedDefs.PostView>,
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
    self.postBox = postBox
    self.replyTarget = grandparentAuthor.map { PostReplyTarget($0) }
    self.isParentPost = isParentPost
    self.isSelectable = isSelectable
    self._path = path
    self.isToYou = isToYou
    self.hasVisibleThreadContext = hasVisibleThreadContext
    self.avatarScale = avatarScale
    self.visibilityContext = visibilityContext
    self.rootPostURI = rootPostURI
    self.rootAuthorDID = rootAuthorDID
    self.isReplyHiddenByThreadgate = isReplyHiddenByThreadgate
    self.opThreadPostIndex = opThreadPostIndex
    self.opThreadPostCount = opThreadPostCount
    _postState = State(initialValue: PostState(postBox: postBox, currentUserDid: appState.userDID))
    _viewModel = State(initialValue: PostViewModel(post: postBox.value, appState: appState, visibilityContext: visibilityContext))
    _contextMenuViewModel = State(
      initialValue: PostContextMenuViewModel(
        appState: appState,
        post: postBox.value,
        allowsThreadSummary: (hasVisibleThreadContext || isParentPost) && (postBox.value.replyCount ?? 0) > 0,
        visibilityContext: visibilityContext,
        rootPostURI: rootPostURI,
        rootAuthorDID: rootAuthorDID,
        isReplyHiddenByThreadgate: isReplyHiddenByThreadgate
      ))
  }

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
    self.init(
      postBox: EquatableBox(post),
      grandparentAuthor: grandparentAuthor,
      isParentPost: isParentPost,
      isSelectable: isSelectable,
      path: path,
      appState: appState,
      isToYou: isToYou,
      hasVisibleThreadContext: hasVisibleThreadContext,
      avatarScale: avatarScale,
      visibilityContext: visibilityContext,
      rootPostURI: rootPostURI,
      rootAuthorDID: rootAuthorDID,
      isReplyHiddenByThreadgate: isReplyHiddenByThreadgate,
      opThreadPostIndex: opThreadPostIndex,
      opThreadPostCount: opThreadPostCount
    )
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
    .onChange(of: postBox) { oldBox, newBox in
      let newPost = newBox.value
      let isDifferentPost = oldBox.value.uri != newPost.uri
      if isReadOnlyPreview {
        if isDifferentPost {
          postState.reset(for: newBox, currentUserDid: appState.userDID)
        } else {
          postState.currentPostBox = newBox
        }
        postState.postError = Self.detectPostError(in: newPost, isReadOnlyPreview: true)
        return
      }
      if isDifferentPost {
        postState.reset(for: newBox, currentUserDid: appState.userDID)
        postState.postError = Self.detectPostError(in: newPost, isReadOnlyPreview: false)
        viewModel.configure(
          post: newPost,
          appState: appState,
          visibilityContext: visibilityContext
        )
        contextMenuViewModel.configure(
          appState: appState,
          post: newPost,
          allowsThreadSummary: (hasVisibleThreadContext || isParentPost) && (newPost.replyCount ?? 0) > 0,
          visibilityContext: visibilityContext,
          rootPostURI: rootPostURI,
          rootAuthorDID: rootAuthorDID,
          isReplyHiddenByThreadgate: isReplyHiddenByThreadgate
        )
      } else {
        contextMenuViewModel.configure(
          appState: appState,
          post: newPost,
          allowsThreadSummary: (hasVisibleThreadContext || isParentPost) && (newPost.replyCount ?? 0) > 0,
          visibilityContext: visibilityContext,
          rootPostURI: rootPostURI,
          rootAuthorDID: rootAuthorDID,
          isReplyHiddenByThreadgate: isReplyHiddenByThreadgate
        )
        if viewModel.postCid != newPost.cid {
          viewModel.configure(
            post: newPost,
            appState: appState,
            visibilityContext: visibilityContext
          )
        }
      }
    }
    .onDisappear {
      postState.threadSummaryTask?.cancel()
      postState.threadSummaryTask = nil
    }
    .modifier(PostPresentationsModifier(
      postState: postState,
      contextMenuViewModel: contextMenuViewModel,
      viewModel: viewModel,
      visibilityContext: visibilityContext
    ))
  }

  /// Set up the post and its observers
  private func setupPost() async {
    guard !Task.isCancelled else { return }
    let post = postBox.value

    let state = postState
    let vm = viewModel
    let menuVm = contextMenuViewModel

    // Discovery previews use the fetched payload without donating entities or
    // starting interaction/shadow work. Label decisions still run in the views.
    if isReadOnlyPreview {
      state.currentPost = post
      state.postError = Self.detectPostError(in: post, isReadOnlyPreview: true)
      state.initialLoadComplete = true
      return
    }

    if state.currentPostBox != postBox {
      state.currentPostBox = postBox
    }
    if vm.postId != post.uri.uriString() || vm.postCid != post.cid {
      vm.configure(post: post, appState: appState, visibilityContext: visibilityContext)
    }

    // Check for error conditions first
    if let error = Self.detectPostError(in: post, isReadOnlyPreview: isReadOnlyPreview) {
      state.postError = error
      state.initialLoadComplete = true
      return
    }

    // Set up report callback
    menuVm.onReportPost = {
      state.showingReportView = true  // Use consolidated state
    }
    
    // Set up add to list callback
    menuVm.onAddAuthorToList = {
      state.showingAddToListSheet = true  // Use consolidated state
    }
    
    // Set up bookmark callback
    menuVm.onToggleBookmark = {
      Task {
        do {
          try await vm.toggleBookmark()
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
    menuVm.onSummarizeThread = {
      PostThreadSummarizer.summarize(state: state, appState: appState)
    }
#endif
    
    // Fetch user data
    fetchCurrentUserDid()

    // Deterministic async initialization of PostViewModel (single actor hop)
    if let merged = await vm.start(post: post) {
      guard !Task.isCancelled else { return }
      if merged != state.currentPost {
        state.currentPost = merged
      }
    }
    guard !Task.isCancelled else { return }

    // Mark initial load as complete for transaction animation control
    state.initialLoadComplete = true

    // Preserve the thermally scaled delay before non-essential entity seeding
    await appState.waitForNextRefreshCycle()
    guard !Task.isCancelled else { return }

    // Seed the on-screen resolution stores so Siri's "this post" resolves from
    // memory on every surface that renders a row (search, profiles, hashtags,
    // notifications, quotes), not only feeds and threads. Deferred until after
    // the refresh cycle so cells flying past during a fast scroll do not spawn
    // unstructured background tasks.
    if #available(iOS 18.0, *), visibilityContext == .public {
      let seed = SpotlightDonationModeration.rowSeed(post, policy: appState.moderationPolicy)
      if seed.storesPost || seed.storesAuthor {
        Task(priority: .utility) {
          if seed.storesPost { await PostEntityStore.shared.store(post) }
          if seed.storesAuthor { await ProfileEntityStore.shared.store(ProfileEntity(from: post.author)) }
        }
      }
    }

    // Structured shadow observation loop for real-time updates
    for await shadow in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
      guard !Task.isCancelled else { break }
      if let shadow, shadow.hasModifications {
        let merged = await appState.postShadowManager.mergeShadow(post: post)
        guard !Task.isCancelled else { break }
        if merged != state.currentPost {
          state.currentPost = merged
        }
      } else if state.currentPostBox != postBox {
        state.currentPostBox = postBox
      }
    }
  }
  
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
    // Observable setters notify even for an unchanged value, which re-renders the row.
    if postState.currentUserDid != appState.userDID {
      postState.currentUserDid = appState.userDID
    }
  }

  /// Get the final avatar URL with fallback handling
  private func getFinalAvatarURL() -> URL? {
    // Use postState.currentPost
    return postState.currentPostBox.value.author.finalAvatarURL()
  }

  /// Prefetch the avatar image for better performance
  private func prefetchAvatar() async {
    guard let finalAvatarURL = getFinalAvatarURL(), !postState.isAvatarLoaded else { return }
    let request = ImageRequestFactory.avatar(finalAvatarURL, pointSize: Self.avatarSize, scale: 2.0)
    if request != nil {
      await ImageLoadingManager.shared.startPrefetching(urls: [finalAvatarURL])
    }
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

  @Environment(\.moderationPolicy) private var moderationPolicy
  @Environment(\.moderationListFilterExemptDID) private var listFilterExemptDID
  @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

  /// The shadow-merged post being displayed.
  private var displayed: EquatableBox<AppBskyFeedDefs.PostView> {
    postState.currentPostBox
  }

  private var displayError: PostViewError? {
    postState.postError
      ?? (isReadOnlyPreview ? PostView.detectPostError(in: postBox.value, isReadOnlyPreview: true) : nil)
  }

  /// The post's decision on the list surface. Error rows carry no moderation.
  private var moderation: PostModerationPresentation {
    guard displayError == nil else { return .empty }
    return PostModerationPresentation.make(
      post: displayed.value, policy: moderationPolicy, surface: .contentList,
      listFilterExemptDID: listFilterExemptDID)
  }

  var body: some View {
    let moderation = self.moderation
    if moderation.hidesRow && postState.revealedModerationFilter != moderation.filterIdentity {
      // The surface did not filter this post (profile tabs, likes, bookmarks,
      // thread replies, notifications): show it as hidden instead of the post.
      // A filter inherited from a quote does not hide the row; the quote card
      // gates itself.
      ModerationHiddenPostRow(presentation: moderation) {
        withoutRevealAnimation {
          postState.revealedModerationFilter = moderation.filterIdentity
        }
        invalidateFeedRowHeight?()
      }
      .padding(.top, PostView.baseUnit)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if moderation.hidesRow {
          // A shown hidden row keeps its cause in view and can be hidden again.
          ModerationRevealedPostBar(presentation: moderation) {
            withoutRevealAnimation {
              postState.revealedModerationFilter = nil
            }
            invalidateFeedRowHeight?()
          }
          .padding(.horizontal, PostView.baseUnit)
          .padding(.top, PostView.baseUnit)
        }
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
          postAvatar(concealed: moderation.concealsAvatar)
          postContentColumn(moderation)
        }
      }
    }
  }

  private func postAvatar(concealed: Bool) -> some View {
    AuthorAvatarColumn(
      author: PostAvatarAuthor(getAuthorForDisplay()),
      isParentPost: isParentPost,
      isAvatarLoaded: $postState.isAvatarLoaded,
      path: $path,
      avatarScale: avatarScale,
      concealsAvatar: concealed
    )
  }

  private func postContentColumn(_ moderation: PostModerationPresentation) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      if let error = displayError {
        // Show error content
        errorContentView(for: error)
      } else if isReadOnlyPreview && postBox.value.author.viewer?.muted == true && !showsMutedPreview {
        HStack {
          Label("Post from an account you muted", systemImage: "speaker.slash")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Show") {
            withoutRevealAnimation {
              postState.revealedMutedPreview = mutedPreviewIdentity
            }
            invalidateFeedRowHeight?()
          }
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.borderless)
        }
      } else {
        // Show normal post content with moderation
        moderatedPostContent(moderation)
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

  private func postHeader(for feedPost: AppBskyFeedPost) -> some View {
    HStack(alignment: .top, spacing: 0) {
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
    .padding(.horizontal, PostView.baseUnit)
  }

  // MARK: - Content Views

  /// Header and reply line stay visible. Text and embed sit together behind
  /// the body gate (`ContentHider` upstream); media sits behind the media gate
  /// inside it. The action bar stays visible below.
  @ViewBuilder
  private func moderatedPostContent(_ moderation: PostModerationPresentation) -> some View {
    if case .knownType(let postObj) = displayed.value.record,
      let feedPost = postObj as? AppBskyFeedPost {
      VStack(alignment: .leading, spacing: 0) {
        postHeader(for: feedPost)

        if case .circle(let circle) = visibilityContext {
          HStack(spacing: 4) {
            Image(systemName: "person.2.circle.fill")
              .font(.caption2)
              .foregroundStyle(Color.accentColor)
            Text("Circle · \(circle.name)")
              .appCaption()
              .fontWeight(.medium)
              .foregroundStyle(Color.accentColor)
          }
          .padding(.horizontal, PostView.baseUnit)
          .padding(.top, 2)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Circle: \(circle.name)")
        }

        if let replyTarget {
          replyIndicatorView(replyTarget: replyTarget)
            .textScale(.secondary)
            .padding(.top, PostView.baseUnit)
        } else if isToYou {
          replyIndicatorView(replyTarget: nil)
            .textScale(.secondary)
            .padding(.top, PostView.baseUnit)
        }
      }

      ModerationContentGate(ui: moderation.body) {
        PostModeratedBody(
          record: EquatableBox(feedPost),
          displayed: displayed,
          moderation: moderation,
          isSelectable: isSelectable,
          visibilityContext: visibilityContext,
          postID: postID,
          path: $path
        )
      }
      // Reveals are remembered for the post, not the row, so they survive cell
      // reuse and carry to other rows and screens that show it.
      .environment(\.moderationRevealSubject, displayed.value.uri.uriString())
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

  // MARK: - Helper Views

  // Default avatar placeholder (moved to AuthorAvatarColumn)

  // Line connecting parent and child posts (moved to AuthorAvatarColumn)

  // Post menu (three dots)
  @ViewBuilder
  private var postEllipsisMenuView: some View {
    #if os(iOS)
    // The glyph stays in SwiftUI so the header lays out exactly as before; the UIKit
    // button over it builds the menu only when it opens.
    postOptionsGlyph
      .accessibilityHidden(true)
      .overlay {
        PostOptionsMenuButton(accessibilityLabel: "Post Options", accessibilityIdentifier: nil) {
          PostOptionsMenuBuilder.elements(post: displayed.value, context: optionsMenuContext)
        }
      }
    #else
    swiftUIPostOptionsMenu
    #endif
  }

  private var postOptionsGlyph: some View {
    Image(systemName: "ellipsis")
      .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
      .padding(PostView.baseUnit * 3)
      .contentShape(Rectangle())
  }

  #if os(iOS)
  private var optionsMenuContext: PostOptionsMenuContext {
    PostOptionsMenuContext(
      postState: postState, contextMenuViewModel: contextMenuViewModel, viewModel: viewModel,
      appState: appState, feedInteractionTarget: feedInteractionTarget, visibilityContext: visibilityContext)
  }
  #endif

  private var swiftUIPostOptionsMenu: some View {
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
      postOptionsGlyph
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
}

/// The part of a row the body gate conceals: label chips, text and embed.
/// Its own view so the gate's generic content stays small in the row's body.
private struct PostModeratedBody: View {
  let record: EquatableBox<AppBskyFeedPost>
  let displayed: EquatableBox<AppBskyFeedDefs.PostView>
  let moderation: PostModerationPresentation
  let isSelectable: Bool
  let visibilityContext: PostVisibilityContext
  let postID: String
  @Binding var path: NavigationPath
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  var body: some View {
    ContentLabelView(causes: moderation.chips)

    PostRecordText(record: record, isSelectable: isSelectable, path: $path)
      .allowsHitTesting(!isReadOnlyPreview)
      .disabled(isReadOnlyPreview)
      .padding(.top, PostView.baseUnit)
      .padding(.bottom, PostView.baseUnit)

    if let embed = displayed.value.embed {
      PostEmbed(
        embed: embed,
        mediaModeration: moderation.media,
        path: $path,
        visibilityContext: visibilityContext,
        authorDID: displayed.value.author.did
      )
      .environment(\.postID, postID)
      .padding(.trailing, PostView.baseUnit * 2)
      .padding(.bottom, PostView.baseUnit)
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
    guard text.utf8.count >= 200 else { return nil }
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

struct ThreadSummarySheet: View {
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
  /// The author's `avatar` decision blurs: show the neutral placeholder and
  /// never request the image.
  var concealsAvatar: Bool = false
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview
  @Environment(\.displayScale) private var displayScale

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  private var avatarSize: CGFloat { avatarScale.avatarSize }
  private var avatarContainerWidth: CGFloat { avatarScale.containerWidth }

  // Reusable image request for avatars matching FeedPrefetchingManager's cache key
  private func avatarRequest(for url: URL) -> ImageRequest? {
    ImageRequestFactory.avatar(url, pointSize: avatarSize, scale: displayScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if concealsAvatar {
        ModeratedAvatarPlaceholder(size: avatarSize)
          .overlay(liveStatusRing)
          .onTapGesture {
            openProfile()
          }
      } else if let finalURL = author.avatarURL {
        LazyImage(request: avatarRequest(for: finalURL)) { state in
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


extension PostView {
  /// Minimal production Circle row factory from a generated `BlueCatbirdCircleDefs.FeedItem`.
  public static func circleRow(
    item: BlueCatbirdCircleDefs.FeedItem,
    path: Binding<NavigationPath>,
    appState: AppState,
    isParentPost: Bool = false,
    isSelectable: Bool = true,
    avatarScale: PostAvatarScale = .regular
  ) -> PostView {
    PostView(
      post: item.post.post,
      grandparentAuthor: nil,
      isParentPost: isParentPost,
      isSelectable: isSelectable,
      path: path,
      appState: appState,
      avatarScale: avatarScale,
      visibilityContext: .circle(item.circle)
    )
  }

  /// Minimal production Circle detail factory.
  public static func circleDetail(
    post: AppBskyFeedDefs.PostView,
    circle: CircleSummary,
    path: Binding<NavigationPath>,
    appState: AppState,
    grandparentAuthor: AppBskyActorDefs.ProfileViewBasic? = nil,
    isParentPost: Bool = false,
    isSelectable: Bool = true,
    hasVisibleThreadContext: Bool = false,
    avatarScale: PostAvatarScale = .regular
  ) -> PostView {
    PostView(
      post: post,
      grandparentAuthor: grandparentAuthor,
      isParentPost: isParentPost,
      isSelectable: isSelectable,
      path: path,
      appState: appState,
      hasVisibleThreadContext: hasVisibleThreadContext,
      avatarScale: avatarScale,
      visibilityContext: .circle(circle)
    )
  }
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
