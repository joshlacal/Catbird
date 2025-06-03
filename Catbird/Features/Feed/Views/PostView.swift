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

  // MARK: - Computed Properties
var id: String {
    let postID = post.uri.uriString() + post.cid.string
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
      // Use the extracted AuthorAvatarColumn view
      AuthorAvatarColumn(
        author: postState.currentPost.author,
        isParentPost: isParentPost,
        isAvatarLoaded: $postState.isAvatarLoaded,
        path: $path
      )

      // Content column
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        // Only show content labels if there's no embed - embeds handle their own labels
        if let labels = postState.currentPost.labels, !labels.isEmpty, postState.currentPost.embed == nil {
          ContentLabelView(labels: labels)
            .padding(.bottom, PostView.baseUnit)
        }

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
      .padding(.top, PostView.baseUnit)
    }
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: .clear)
    .transaction { t in  // Disable initial animations
      if !initialLoadComplete {
        t.animation = nil
      }
    }
    // This is critical for preventing layout jumps
    .fixedSize(horizontal: false, vertical: true)
    // Present the report form when showingReportView is true
    .sheet(isPresented: $postState.showingReportView) {  // Use consolidated state
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
    .task {
      await setupPost()
    }
    .onDisappear {  // Cancel the shadow update task when the view disappears
      shadowUpdateTask?.cancel()
      shadowUpdateTask = nil
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
      Button(action: {
        Task { await contextMenuViewModel.muteUser() }
      }) {
        Label("Mute User", systemImage: "speaker.slash")
      }

      Button(action: {
        Task { await contextMenuViewModel.blockUser() }
      }) {
        Label("Block User", systemImage: "exclamationmark.octagon")
      }

      Button(action: {
        Task { await contextMenuViewModel.muteThread() }
      }) {
        Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
      }

      // Use postState.currentUserDid and postState.currentPost
      if let currentUserDid = postState.currentUserDid,
        postState.currentPost.author.did.didString() == currentUserDid {
        Button(action: {
          Task { await contextMenuViewModel.deletePost() }
        }) {
          Label("Delete Post", systemImage: "trash")
        }
      }

      Button(action: {
        postState.showingReportView = true  // Use consolidated state
      }) {
        Label("Report Post", systemImage: "flag")
      }
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(.gray)
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
        .foregroundStyle(.secondary)
        .appBody()

      HStack(spacing: 0) {
        Text("in reply to ")
          .appBody()
          .offset(y: -1)
          .foregroundStyle(.secondary)

          if isToYou {
            Text("you")
                  .appBody()
                  .offset(y: -1)
                  .foregroundStyle(.secondary)
          } else if let grandparentAuthor = grandparentAuthor {
              Text("@\(grandparentAuthor.handle)")
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

  /// Set up the post and its observers
  private func setupPost() async {
    // Set up report callback
    contextMenuViewModel.onReportPost = {
      postState.showingReportView = true  // Use consolidated state
    }

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

  /// Fetch the current user's DID
  private func fetchCurrentUserDid() {
    postState.currentUserDid = appState.currentUserDID  // Use consolidated state
  }

  /// Get the final avatar URL with fallback handling
  private func getFinalAvatarURL() -> URL? {
    // Use postState.currentPost
    return postState.currentPost.author.finalAvatarURL()
  }

  /// Prefetch the avatar image for better performance
  private func prefetchAvatar() async {
    // Use postState.isAvatarLoaded and check before prefetching
    guard let finalAvatarURL = getFinalAvatarURL(), !postState.isAvatarLoaded else { return }
    let manager = ImageLoadingManager.shared
    await manager.startPrefetching(urls: [finalAvatarURL])

    // Cancel prefetching if avatar doesn't load after a delay
    Task {
      try await Task.sleep(for: .seconds(5))
      // Check isAvatarLoaded again before stopping
      if !postState.isAvatarLoaded {
        await manager.stopPrefetching(urls: [finalAvatarURL])
      }
    }
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

  // Reusable image processor
  private let avatarProcessor = ImageProcessors.AsyncImageDownscaling(
    targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize)
  )

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let finalURL = author.finalAvatarURL() {
        LazyImage(url: finalURL) { state in
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
        .processors([avatarProcessor])  // Apply processor
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
        .fill(Color(UIColor.systemGray4))
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
