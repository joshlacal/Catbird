//
//  PostView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Nuke
import NukeUI
import Observation
import Petrel
import SwiftUI

// Define the consolidated state model
@Observable class PostState {
  var currentUserDid: String?
  var currentPost: AppBskyFeedDefs.PostView
  var isAvatarLoaded = false
  var showingReportView = false
  var showingAddToListSheet = false

  init(post: AppBskyFeedDefs.PostView) {
    self.currentPost = post
  }
}

/// A view that displays a single post with its content, avatar, and actions
struct PostView: View, Equatable, Identifiable {
    static func == (lhs: PostView, rhs: PostView) -> Bool {
        lhs.post.uri == rhs.post.uri && lhs.post.cid == rhs.post.cid
    }
        
  // MARK: - Environment & Properties
  @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
  let post: AppBskyFeedDefs.PostView
  let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
  let isParentPost: Bool
  let isSelectable: Bool
let isToYou: Bool
  @Binding var path: NavigationPath
  @Environment(\.feedPostID) private var feedPostID

  // MARK: - State
  @State private var postState: PostState  // Consolidated state
  @State private var contextMenuViewModel: PostContextMenuViewModel
  @State private var viewModel: PostViewModel
  @State private var shadowUpdateTask: Task<Void, Error>?  // For AsyncStream management
  @State private var initialLoadComplete = false  // For transaction animation control
  @State private var postError: PostViewError?  // Error state tracking
  @State private var isShowingThreadSummary = false
  @State private var isThreadSummaryLoading = false
  @State private var threadSummaryText: String?
  @State private var threadSummaryError: String?
  @State private var canRetryThreadSummary = false
  @State private var threadSummaryTask: Task<Void, Never>?
  @State private var showDeleteConfirmation = false
  @State private var showBlockConfirmation = false

  // MARK: - Computed Properties
var id: String {
    // Base ID from post URI and CID
    let postID = post.uri.uriString() + post.cid.string

    // If we have a feed post ID from the environment, use it to ensure uniqueness
    // This handles cases where the same post appears multiple times in a feed (e.g., multiple reposts)
    if let feedPostID = feedPostID {
      return "\(feedPostID)-\(postID)"
    } else {
      return postID
    }
  }

  // Using design tokens for consistent spacing
  private static let baseUnit: CGFloat = 3
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
    isToYou: Bool = false
  ) {
    self.post = post
    self.grandparentAuthor = grandparentAuthor
    self.isParentPost = isParentPost
    self.isSelectable = isSelectable
    self._path = path
      self.isToYou = isToYou

    // Initialize states
    _postState = State(initialValue: PostState(post: post))  // Initialize consolidated state
    _viewModel = State(initialValue: PostViewModel(post: post, appState: appState))
    _contextMenuViewModel = State(
      initialValue: PostContextMenuViewModel(appState: appState, post: post))
  }

  // MARK: - Body
  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
      // Always show avatar column with thread line
      AuthorAvatarColumn(
        author: getAuthorForDisplay(),
        isParentPost: isParentPost,
        isAvatarLoaded: $postState.isAvatarLoaded,
        path: $path
      )

      // Content column - show error view or normal post content
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        if let error = postError {
          // Show error content
          errorContentView(for: error)
        } else {
          // Show normal post content with moderation
          moderatedPostContent
        }
      }
      .padding(.top, PostView.baseUnit)
    }
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: .clear)
    .transaction { t in  // Disable initial animations
      if !initialLoadComplete {
        t.animation = nil
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .task {
      await setupPost()
    }
    .onDisappear {
      shadowUpdateTask?.cancel()
      shadowUpdateTask = nil
      threadSummaryTask?.cancel()
      threadSummaryTask = nil
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
        userDID: postState.currentPost.author.did.didString(),
        userHandle: postState.currentPost.author.handle.description,
        userDisplayName: postState.currentPost.author.displayName
      )
    }
    .sheet(isPresented: $isShowingThreadSummary) {
      ThreadSummarySheet(
        isLoading: isThreadSummaryLoading,
        summaryText: threadSummaryText,
        errorText: threadSummaryError,
        canRetry: canRetryThreadSummary && !isThreadSummaryLoading,
        onRetry: canRetryThreadSummary ? { summarizeCurrentThread() } : nil,
        post: postState.currentPost
      )
    }
    .alert("Delete Post", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Delete", role: .destructive) {
        Task { await contextMenuViewModel.deletePost() }
      }
    } message: {
      Text("Are you sure you want to delete this post? This action cannot be undone.")
    }
    .alert("Block User", isPresented: $showBlockConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Block", role: .destructive) {
        Task { await contextMenuViewModel.blockUser() }
      }
    } message: {
      Text("Block @\(postState.currentPost.author.handle)? You won't see each other's posts, and they won't be able to follow you.")
    }
  }

  // MARK: - Content Views

  @ViewBuilder
  private var moderatedPostContent: some View {
    let labels = postState.currentPost.labels
    let selfLabelValues = extractSelfLabelValues(from: postState.currentPost)
    let hasEmbed = postState.currentPost.embed != nil
    
    // Only wrap in ContentLabelManager if:
    // 1. There's no embed (post handles its own labels), OR
    // 2. There are text-specific labels that don't apply to the embed
    if !hasEmbed && (labels?.isEmpty == false || !selfLabelValues.isEmpty) {
      ContentLabelManager(labels: labels, selfLabelValues: selfLabelValues, contentType: "post") {
        normalPostContent
      }
    } else {
      // Embeds handle their own labels exclusively
      normalPostContent
    }
  }

  @ViewBuilder
  private var normalPostContent: some View {
    // ContentLabelManager handles label display, so don't show them here
    postContentView
      .padding(.bottom, PostView.baseUnit)

    // Embed content (images, links, videos, etc.)
    if let embed = postState.currentPost.embed {
      embedContent(embed, labels: postState.currentPost.labels)
        .environment(\.postID, id)
        .padding(.bottom, PostView.baseUnit)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Action buttons
    ActionButtonsView(
      post: postState.currentPost,
      postViewModel: viewModel,
      path: $path
    )
    .padding(.bottom, PostView.baseUnit)
  }

  @ViewBuilder
  private func errorContentView(for error: PostViewError) -> some View {
    switch error {
    case .blocked(let blockedPost):
      BlockedPostView(blockedPost: blockedPost, path: $path)
        .id("blocked-\(post.uri.uriString())")

    case .notFound(let reason):
      PostNotFoundView(uri: post.uri, reason: reason, path: $path)
        .id("notfound-\(post.uri.uriString())")

    case .parseError:
      PostNotFoundView(uri: post.uri, reason: .parseError, path: $path)
        .id("parseerror-\(post.uri.uriString())")

    case .permissionDenied:
      PostNotFoundView(uri: post.uri, reason: .permissionDenied, path: $path)
        .id("permission-\(post.uri.uriString())")
    }
  }

  // MARK: - Component Views (AuthorAvatarColumn extracted)

  // Post content area
  private var postContentView: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Use postState.currentPost
      if case .knownType(let postObj) = postState.currentPost.record,
        let feedPost = postObj as? AppBskyFeedPost {

        HStack(alignment: .top, spacing: 0) {
          PostHeaderView(
            displayName: postState.currentPost.author.displayName
              ?? postState.currentPost.author.handle.description,
            handle: postState.currentPost.author.handle.description,
            timeAgo: feedPost.createdAt.date
          )

          Spacer()

          postEllipsisMenuView
        }
        .padding(.horizontal, PostView.baseUnit)

        if let grandparentAuthor = grandparentAuthor {
          replyIndicatorView(grandparentAuthor: grandparentAuthor)
            .textScale(.secondary)
            .padding(.top, PostView.baseUnit)
        } else if isToYou {
            replyIndicatorView(grandparentAuthor: nil)
                .textScale(.secondary)
                .padding(.top, PostView.baseUnit)
            }

        Post(post: feedPost, isSelectable: isSelectable, path: $path)
          .padding(.top, PostView.baseUnit)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Helper Views

  // Default avatar placeholder (moved to AuthorAvatarColumn)

  // Line connecting parent and child posts (moved to AuthorAvatarColumn)

  // Post menu (three dots)
  private var postEllipsisMenuView: some View {
    Menu {
      // Only show "Add to List" for other users' posts
      if postState.currentPost.author.did.didString() != postState.currentUserDid {
        Button(action: {
          contextMenuViewModel.addAuthorToList()
        }) {
          Label("Add Author to List", systemImage: "list.bullet.rectangle")
        }
        
        Divider()
      }
      
#if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 15.0, *) {
        Button(action: {
          contextMenuViewModel.summarizeThread()
        }) {
          Label("Summarize Thread", systemImage: "text.append")
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
      
      // Show More / Show Less options for custom feeds
      if contextMenuViewModel.isFeedbackEnabled {
        Divider()
        
        Button(action: {
          contextMenuViewModel.sendShowMore()
        }) {
          Label("Show More Like This", systemImage: "hand.thumbsup")
        }
        
        Button(action: {
          contextMenuViewModel.sendShowLess()
        }) {
          Label("Show Less Like This", systemImage: "hand.thumbsdown")
        }
      }
      
      Divider()
      
      // Only show mute/block for other users' posts
      if postState.currentPost.author.did.didString() != postState.currentUserDid {
        Button(action: {
          Task { await contextMenuViewModel.muteUser() }
        }) {
          Label("Mute User", systemImage: "speaker.slash")
        }

        Button(role: .destructive, action: {
          showBlockConfirmation = true
        }) {
          Label("Block User", systemImage: "exclamationmark.octagon")
        }
      }

      Button(action: {
        Task { await contextMenuViewModel.muteThread() }
      }) {
        Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
      }
      
      // Only show hide/report for other users' posts
      if postState.currentPost.author.did.didString() != postState.currentUserDid {
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
      }

      // Use postState.currentUserDid and postState.currentPost
      if let currentUserDid = postState.currentUserDid,
        postState.currentPost.author.did.didString() == currentUserDid {
        Button(role: .destructive, action: {
          showDeleteConfirmation = true
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
  private func replyIndicatorView(grandparentAuthor: AppBskyActorDefs.ProfileViewBasic? = nil) -> some View {
    HStack(alignment: .center, spacing: PostView.baseUnit) {
      Image(systemName: "arrow.up.forward.circle")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
        .appBody()

      HStack(spacing: 0) {
        Text("in reply to ")
          .appBody()
          .offset(y: -1)
          .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))

        if isToYou {
          Text("you")
            .appBody()
            .offset(y: -1)
            .foregroundStyle(Color.accentColor)
        } else if let grandparentAuthor = grandparentAuthor {
          Text(verbatim: "@\(grandparentAuthor.handle)")
            .appBody()
            .offset(y: -1)
            .foregroundStyle(Color.accentColor)
            .onTapGesture {
              path.append(NavigationDestination.profile(grandparentAuthor.did.didString()))
            }
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
    PostEmbed(embed: embed, labels: labels, path: $path)
      .environment(\.postID, id)
      .padding(.trailing, PostView.baseUnit * 2)
  }

  // MARK: - Setup & Helpers

  /// Get the author to display in the avatar column
  private func getAuthorForDisplay() -> AppBskyActorDefs.ProfileViewBasic {
    // If there's an error, try to extract author info from the error
    if let error = postError {
      switch error {
      case .blocked(let blockedPost):
        // Create placeholder from blocked author
        let placeholderHandle = try! Handle(handleString: "blocked.user")
        return AppBskyActorDefs.ProfileViewBasic(
          did: blockedPost.author.did,
          handle: placeholderHandle,
          displayName: nil,
          pronouns: nil, avatar: nil,
          associated: nil,
          viewer: blockedPost.author.viewer,
          labels: nil,
          createdAt: nil,
          verification: nil,
          status: nil
        )
      case .notFound, .parseError, .permissionDenied:
        // Generic placeholder for deleted/not found posts
        let placeholderDID = try! DID(didString: "did:plc:unknown")
        let placeholderHandle = try! Handle(handleString: "deleted.user")
        return AppBskyActorDefs.ProfileViewBasic(
          did: placeholderDID,
          handle: placeholderHandle,
          displayName: nil,
          pronouns: nil, avatar: nil,
          associated: nil,
          viewer: nil,
          labels: nil,
          createdAt: nil,
          verification: nil,
          status: nil
        )
      }
    }

    // Normal case - return actual post author
    return postState.currentPost.author
  }

  /// Set up the post and its observers
  private func setupPost() async {
    // Check for error conditions first
    if let error = detectPostError() {
      postError = error
      initialLoadComplete = true
      return
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
          // Handle bookmark error if needed
          logger.error("Failed to toggle bookmark: \(error)")
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

    // Replace fixed sleep with waiting for app state cycle (if available)
    // try? await Task.sleep(for: .milliseconds(100)) // Removed
    await appState.waitForNextRefreshCycle()  // Added - Ensure AppState has this method

    // Prefetch the avatar image
    await prefetchAvatar()

    // Set up shadow observation for real-time updates
    shadowUpdateTask = Task {  // Manage task lifecycle
      for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
        try Task.checkCancellation()  // Check for cancellation
        postState.currentPost = await appState.postShadowManager.mergeShadow(post: post)  // Use consolidated state
      }
    }

    // Mark initial load as complete for transaction animation control
    initialLoadComplete = true
  }
  
#if canImport(FoundationModels)
  @MainActor
  private func summarizeCurrentThread() {
    threadSummaryTask?.cancel()
    threadSummaryTask = nil

    isShowingThreadSummary = true
    isThreadSummaryLoading = true
    threadSummaryText = nil
    threadSummaryError = nil
    canRetryThreadSummary = false

    guard appState.atProtoClient != nil else {
      threadSummaryError = "Sign in to summarize threads."
      isThreadSummaryLoading = false
      canRetryThreadSummary = false
      return
    }

    if #available(iOS 26.0, macOS 15.0, *) {
      let agent = appState.blueskyAgent
      let targetURI = postState.currentPost.uri

      threadSummaryTask = Task {
        do {
          var accumulatedText = ""
          let stream = await agent.streamThreadSummary(at: targetURI)
          
          for try await chunk in stream {
            guard !Task.isCancelled else { return }
            
            accumulatedText += chunk
            
            await MainActor.run {
              self.threadSummaryText = accumulatedText
            }
          }
          
          guard !Task.isCancelled else { return }

          await MainActor.run {
            let cleaned = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
              self.threadSummaryError = "The model couldn't generate a summary for this thread."
              self.isThreadSummaryLoading = false
              self.canRetryThreadSummary = true
            } else {
              self.threadSummaryText = cleaned
              self.isThreadSummaryLoading = false
              self.canRetryThreadSummary = false
            }
          }
        } catch {
          guard !Task.isCancelled else { return }
          let (message, retryable) = summarizeThreadErrorMessage(for: error)
          await MainActor.run {
            self.threadSummaryError = message
            self.isThreadSummaryLoading = false
            self.canRetryThreadSummary = retryable
          }
        }
      }
    } else {
      threadSummaryError = "Thread summarization requires iOS 26 or later."
      isThreadSummaryLoading = false
      canRetryThreadSummary = false
    }
  }

  private func summarizeThreadErrorMessage(for error: Error) -> (String, Bool) {
    if let agentError = error as? BlueskyAgentError {
      switch agentError {
      case .missingClient:
        return ("Sign in to summarize threads.", false)
      case .modelUnavailable:
        return ("Apple Intelligence is still preparing. Try again in a moment.", true)
      case .foundationModelsUnavailable:
        return ("Thread summarization isn't available on this device.", false)
      case .invalidThreadURI(let value):
        return ("The thread identifier \(value) is invalid.", false)
      case .emptyResult:
        return ("There isn't enough conversation to summarize yet.", false)
      case .underlying(let underlying):
        let message = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        return (message, true)
      }
    }

    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return (message, true)
  }
#endif

  /// Detect if the post has any error conditions
  private func detectPostError() -> PostViewError? {
    // Check if the post record can be decoded
    guard case .knownType(let record) = post.record,
          record is AppBskyFeedPost else {
      return .parseError
    }
    
    // Check if the author is blocked/blocking
    if let viewer = post.author.viewer {
      // Check if this should be shown as blocked
      let iBlockedThem = viewer.blocking != nil
      let theyBlockedMe = viewer.blockedBy == true
      
      // Only show BlockedPostView in specific cases (e.g., thread continuity)
      // Most blocked content should be filtered out by FeedTuner
      if theyBlockedMe || (iBlockedThem && shouldShowBlockedContent()) {
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
  private func shouldShowBlockedContent() -> Bool {
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
    return postState.currentPost.author.finalAvatarURL()
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

private struct ThreadSummarySheet: View {
  let isLoading: Bool
  let summaryText: String?
  let errorText: String?
  let canRetry: Bool
  let onRetry: (() -> Void)?
  let post: AppBskyFeedDefs.PostView

  @Environment(\.dismiss) private var dismiss

  private var authorDisplayName: String {
    post.author.displayName ?? post.author.handle.description
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        header

        content

        Spacer()

        if let onRetry, canRetry {
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
      .navigationBarTitleDisplayMode(.inline)
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

      Text("@\(post.author.handle.description)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var content: some View {
    if isLoading {
      VStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
        ProgressView()
        Text("Summarizing thread…")
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, DesignTokens.Spacing.lg)
    } else if let summaryText {
      ScrollView {
        Text(summaryText)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, DesignTokens.Spacing.sm)
      }
    } else if let errorText {
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
  let author: AppBskyActorDefs.ProfileViewBasic
  let isParentPost: Bool
  @Binding var isAvatarLoaded: Bool
  @Binding var path: NavigationPath

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48
  private static let avatarContainerWidth: CGFloat = 54

  // Reusable image request for avatars
  private var avatarRequest: (URL) -> ImageRequest {
    { url in
      ImageLoadingManager.imageRequest(
        for: url,
        targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize)
      )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let finalURL = author.finalAvatarURL() {
        LazyImage(request: avatarRequest(finalURL)) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(1, contentMode: .fill)
              .frame(width: Self.avatarSize, height: Self.avatarSize)
              .clipShape(Circle())
              .contentShape(Circle())
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
          path.append(NavigationDestination.profile(author.did.didString()))
        }
      } else {
        noAvatarView
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .frame(width: Self.avatarContainerWidth)
    .padding(.horizontal, Self.baseUnit)
    .padding(.top, Self.baseUnit)
    .background(parentPostIndicator)
  }

  // Default avatar placeholder
  private var noAvatarView: some View {
    Image(systemName: "person.crop.circle")
      .resizable()
      .aspectRatio(1, contentMode: .fit)
      .frame(width: Self.avatarSize, height: Self.avatarSize)
      .foregroundColor(.gray)
      .onTapGesture {
        path.append(NavigationDestination.profile(author.did.didString()))
      }
  }

  // Placeholder view for loading state
  private var avatarPlaceholder: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .frame(width: Self.avatarSize, height: Self.avatarSize)
      .overlay(ProgressView().scaleEffect(0.8))  // Optional: add a smaller ProgressView
  }

  // Line connecting parent and child posts
  @ViewBuilder
  private var parentPostIndicator: some View {
    if isParentPost {
      Rectangle()
        .fill(Color.systemGray4)
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .padding(.bottom, Self.avatarSize + Self.baseUnit * 2)
        .offset(y: Self.avatarSize + Self.baseUnit * 3)
    }
  }
}

// MARK: - PostID Environment
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
enum PostViewError {
    case blocked(AppBskyFeedDefs.BlockedPost)
    case notFound(PostNotFoundReason)
    case parseError
    case permissionDenied
}
