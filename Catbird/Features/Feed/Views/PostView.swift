//
//  PostView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI
import Observation

/// A view that displays a single post with its content, avatar, and actions
struct PostView: View {
  // MARK: - Environment & Properties
  @Environment(AppState.self) private var appState
  let post: AppBskyFeedDefs.PostView
  let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
  let isParentPost: Bool
  let isSelectable: Bool
  @Binding var path: NavigationPath
  @Environment(\.feedPostID) private var feedPostID

  // MARK: - State
  @State private var currentUserDid: String? = nil
  @State private var contextMenuViewModel: PostContextMenuViewModel
  @State private var viewModel: PostViewModel
  @State private var currentPost: AppBskyFeedDefs.PostView
  @State private var isAvatarLoaded = false
  @State private var showingReportView = false

  // MARK: - Computed Properties
  private var uniqueID: String {
    let postID = post.uri.uriString() + post.cid
    if let feedPostID = feedPostID {
      return "\(feedPostID)-\(postID)"
    } else {
      return postID
    }
  }

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48
  private static let avatarContainerWidth: CGFloat = 54

  // MARK: - Initialization
  init(
    post: AppBskyFeedDefs.PostView,
    grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?,
    isParentPost: Bool,
    isSelectable: Bool,
    path: Binding<NavigationPath>,
    appState: AppState
  ) {
    self.post = post
    self.grandparentAuthor = grandparentAuthor
    self.isParentPost = isParentPost
    self.isSelectable = isSelectable
    self._path = path

    // Initialize states
    _currentPost = State(initialValue: post)
    _viewModel = State(initialValue: PostViewModel(post: post, appState: appState))
    _contextMenuViewModel = State(
      initialValue: PostContextMenuViewModel(appState: appState, post: post))
  }

  // MARK: - Body
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Avatar column with thread indicator
      authorAvatarColumn
      
      // Content column
      VStack(alignment: .leading, spacing: 0) {
        postContentView
        
        // Embed content (images, links, videos, etc.)
        if let embed = currentPost.embed {
          embedContent(embed, labels: currentPost.labels)
            .environment(\.postID, uniqueID)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, PostView.baseUnit)
        }
        
        // Action buttons
        ActionButtonsView(
          post: currentPost,
          postViewModel: viewModel,
          path: $path
        )
        .padding(.bottom, PostView.baseUnit)
      }
      .padding(.top, PostView.baseUnit)
    }
    // This is critical for preventing layout jumps
    .fixedSize(horizontal: false, vertical: true) 
    // Present the report form when showingReportView is true
    .sheet(isPresented: $showingReportView) {
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
  }

  // MARK: - Component Views
  
  // Avatar column with thread indicator line
  private var authorAvatarColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Avatar image
      if let finalURL = getFinalAvatarURL() {
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
            ProgressView()
              .background(Color.gray.opacity(0.2))
              .frame(width: Self.avatarSize, height: Self.avatarSize)
              .clipShape(Circle())
              .contentShape(Circle())
          } else {
            noAvatarView
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .priority(.high)
        .processors([
          ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize))
        ])
        .onTapGesture {
          path.append(NavigationDestination.profile(currentPost.author.did))
        }
      } else {
        noAvatarView
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .frame(width: Self.avatarContainerWidth)
    .padding(.horizontal, PostView.baseUnit)
    .padding(.top, PostView.baseUnit)
    .background(parentPostIndicator)
  }
  
  // Post content area
  private var postContentView: some View {
    VStack(alignment: .leading, spacing: 0) {
      if case .knownType(let postObj) = currentPost.record,
         let feedPost = postObj as? AppBskyFeedPost {
        
        HStack(alignment: .top, spacing: 0) {
          PostHeaderView(
            displayName: currentPost.author.displayName ?? currentPost.author.handle,
            handle: currentPost.author.handle,
            timeAgo: formatTimeAgo(from: feedPost.createdAt.date)
          )
          
          Spacer()
          
          postEllipsisMenuView
        }
        .padding(.horizontal, PostView.baseUnit)
        
          if let grandparentAuthor = grandparentAuthor {
              replyIndicatorView(grandparentAuthor: grandparentAuthor)
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
  
  // Default avatar placeholder
  private var noAvatarView: some View {
    Image(systemName: "person.circle.fill")
      .resizable()
      .aspectRatio(1, contentMode: .fit)
      .frame(width: Self.avatarSize, height: Self.avatarSize)
      .foregroundColor(.gray)
      .onTapGesture {
        path.append(NavigationDestination.profile(currentPost.author.did))
      }
  }
  
  // Line connecting parent and child posts
  @ViewBuilder
  private var parentPostIndicator: some View {
    if isParentPost {
      Rectangle()
        .fill(Color.secondary.opacity(0.3))
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .padding(.bottom, Self.avatarSize + PostView.baseUnit * 2)
        .offset(y: Self.avatarSize + PostView.baseUnit * 3)
    }
  }
  
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

      if let currentUserDid = currentUserDid, currentPost.author.did == currentUserDid {
        Button(action: {
          Task { await contextMenuViewModel.deletePost() }
        }) {
          Label("Delete Post", systemImage: "trash")
        }
      }

      Button(action: { 
        showingReportView = true
      }) {
        Label("Report Post", systemImage: "flag")
      }
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(.gray)
        .padding(PostView.baseUnit * 2)
        .contentShape(Rectangle())
    }
  }
  
  // Reply indicator text
    @ViewBuilder
    private func replyIndicatorView(grandparentAuthor: AppBskyActorDefs.ProfileViewBasic) -> some View {
        HStack(alignment: .center, spacing: PostView.baseUnit) {
            Image(systemName: "arrow.up.forward.circle")
                .foregroundStyle(.secondary)
                .font(.body)
            
            HStack(spacing: 0) {
                Text("in reply to ")
                    .font(.body)
                    .offset(y: -1)
                    .foregroundStyle(.secondary)
                
                Text("@\(grandparentAuthor.handle)")
                    .font(.body)
                    .offset(y: -1)
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture {
                        path.append(NavigationDestination.profile(grandparentAuthor.did))
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
      .environment(\.postID, uniqueID)
      .padding(.top, PostView.baseUnit *
               2)
      .padding(.trailing, PostView.baseUnit * 2 )
  }

  // MARK: - Setup & Helpers
  
  /// Set up the post and its observers
  private func setupPost() async {
    // Set up report callback
    contextMenuViewModel.onReportPost = {
        showingReportView = true
    }
    
    // Fetch user data
    fetchCurrentUserDid()
    
    // Small delay to ensure proper initialization
    try? await Task.sleep(for: .milliseconds(100))
    
    // Prefetch the avatar image
    await prefetchAvatar()
    
    // Set up shadow observation for real-time updates
    for await _ in await appState.postShadowManager.shadowUpdates(forUri: post.uri.uriString()) {
      currentPost = await appState.postShadowManager.mergeShadow(post: post)
    }
  }

  /// Fetch the current user's DID
  private func fetchCurrentUserDid() {
    currentUserDid = appState.currentUserDID
  }

  /// Get the final avatar URL with fallback handling
  private func getFinalAvatarURL() -> URL? {
    return currentPost.author.finalAvatarURL()
  }

  /// Prefetch the avatar image for better performance
  private func prefetchAvatar() async {
    guard let finalAvatarURL = getFinalAvatarURL() else { return }
      let manager = ImageLoadingManager.shared
      await manager.startPrefetching(urls: [finalAvatarURL])
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
