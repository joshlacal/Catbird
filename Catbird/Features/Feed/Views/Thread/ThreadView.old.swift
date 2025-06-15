// import Petrel
// import SwiftUI
// import os
// import SwiftUIIntrospect
//
// struct ThreadView: View {
//  @Environment(AppState.self) private var appState: AppState
//  let postURI: ATProtocolURI
//  @Binding var path: NavigationPath
//
//  @State private var threadManager: ThreadManager?
//  @State private var isLoading = true
//  @State private var hasInitialized = false
//  @State private var isLoadingMoreParents = false
//  @State private var contentOpacity: Double = 0
//  @State private var scrollPosition = ScrollPosition(idType: String.self)
//  @State private var hasScrolledToMainPost = false
//
//  @State private var parentPosts: [ParentPost] = []
//  @State private var mainPost: AppBskyFeedDefs.PostView?
//  @State private var replyWrappers: [ReplyWrapper] = []
//
//  private static let mainPostID = "main-post-id"
//
//  // Logger for debugging thread loading issues
//  private let logger = Logger(subsystem: "blue.catbird", category: "ThreadView")
//
//  var body: some View {
//    ZStack {
//      if isLoading {
//        ProgressView("Loading thread...")
//      } else if mainPost != nil {
//        flippedThreadView
//          .opacity(contentOpacity)
//          .onAppear {
//            Task { @MainActor in
//              // Only jump to main post on first appear
//              if !hasScrolledToMainPost {
//                try? await Task.sleep(for: .milliseconds(300))
//                jumpToMainPost()
//                hasScrolledToMainPost = true
//              }
//            }
//
//            withAnimation(.easeInOut(duration: 0.02)) {
//              contentOpacity = 1
//            }
//          }
//      } else {
//        Text("Could not load thread")
//      }
//    }
//    .overlay(
//      VStack {
//        Color.clear
//          .frame(height: 1)
//        Spacer()
//      },
//      alignment: .top
//    )
//
//    .globalBackgroundColor(Color.primaryBackground)
//    .task {
//      guard !hasInitialized else { return }
//      hasInitialized = true
//
//      await loadInitialThread()
//    }
//  }
//
//  private func jumpToMainPost() {
//    scrollPosition = ScrollPosition(id: ThreadView.mainPostID, anchor: .center)
//  }
//
//  private var flippedThreadView: some View {
//    ScrollView {
//      LazyVStack(spacing: 0) {
//        parentsSection
//
//        if let post = mainPost {
//          mainPostSection(post)
//            .id(ThreadView.mainPostID)
//            .padding(.bottom, 9)
//        }
//
//        repliesSection
//
//        Spacer(minLength: 800)
//      }
//      .rotationEffect(.degrees(180))
//    }
//    .scrollIndicators(.hidden)
//    .scrollPosition($scrollPosition, anchor: .bottom)
//    .rotationEffect(.degrees(180))
//    .introspect(.scrollView, on: .iOS(.v16, .v17, .v18)) { scrollView in
//        // Disable standard scrollsToTop because it just goes down
//        scrollView.scrollsToTop = false
//    }
//  }
//
//  private var parentsSection: some View {
//    LazyVStack(spacing: 0) {
//      if isLoadingMoreParents {
//        ProgressView("Loading more parents...")
//          .padding()
//      }
//
//      if parentPosts.isEmpty {
//        // No parents to show
//        EmptyView()
//      } else {
//        if !parentPosts.isEmpty {
//          // Invisible element at the top that triggers more loading
//          Color.clear
//            .frame(height: 20)
//            .onAppear {
//              logger.debug("Top of parents section appeared, triggering loadMoreParents")
//              loadMoreParents()
//            }
//            .id("load-trigger-\(parentPosts.count)")  // Important: ensures it's "new" each time
//        }
//
//        // Display parents in reverse chronological order (oldest to newest)
//        ForEach(Array(parentPosts.reversed()), id: \.id) { parentPost in
//          parentPostView(for: parentPost)
//            .padding(.horizontal, 3)
//            .id(parentPost.id)
//            .onAppear {
//              if parentPost.id == parentPosts.first?.id {
//                // When we see the oldest parent, try to load even older ones
//                logger.debug(
//                  "Oldest parent post appeared (URI: \(parentPost.id)), triggering loadMoreParents")
//                loadMoreParents()
//              }
//            }
//        }
//      }
//    }
//  }
//
//  @ViewBuilder
//  private func mainPostSection(_ post: AppBskyFeedDefs.PostView) -> some View {
//    VStack(spacing: 0) {
//      ThreadViewMainPostView(
//        post: post,
//        showLine: false,
//        path: $path,
//        appState: appState
//      )
//      .padding(.horizontal, 6)
//      .padding(.vertical, 6)
//
//      Divider()
//    }
//  }
//
//  private var repliesSection: some View {
//    VStack(spacing: 0) {
//        ForEach(replyWrappers, id: \.id) { wrapper in
//        if case .appBskyFeedDefsThreadViewPost(let replyPost) = wrapper.reply {
//          recursiveReplyView(
//            reply: replyPost,
//            opAuthorID: mainPost?.author.did.didString() ?? "",
//            depth: 0,
//            maxDepth: 3  // Show up to 3 levels deep
//          )
//          .padding(.horizontal, 10)
//
//          Divider()
//            .padding(.vertical, 3)
//            .rotationEffect(.degrees(180))
////            .scaleEffect(x: 1, y: -1, anchor: .center)
//        } else {
//          // Handle other reply types (not found, blocked, etc.)
//            replyView(for: wrapper, opAuthorID: mainPost?.author.did.didString() ?? "")
//        }
//      }
//    }
//  }
//
//  @ViewBuilder
//  private func parentPostView(for parentPost: ParentPost) -> some View {
//    switch parentPost.post {
//    case .appBskyFeedDefsThreadViewPost(let post):
//      PostView(
//        post: post.post,
//        grandparentAuthor: nil,
//        isParentPost: true,
//        isSelectable: false,
//        path: $path,
//        appState: appState
//      )
//      .contentShape(Rectangle())
//      .onTapGesture {
//        path.append(NavigationDestination.post(post.post.uri))
//      }
//      .padding(.horizontal, 3)
//      .padding(.vertical, 3)
//
//    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
//      Text("Parent post not found \(notFoundPost.uri)")
//        .appFont(AppTextRole.subheadline)
//        .foregroundColor(.red)
//        .padding(.horizontal, 3)
//
//    case .appBskyFeedDefsBlockedPost(let blockedPost):
//      BlockedPostView(blockedPost: blockedPost, path: $path)
//        .appFont(AppTextRole.subheadline)
//        .foregroundColor(.gray)
//        .padding(.horizontal, 3)
//
//    case .unexpected(let unexpected):
//      Text("Unexpected parent post type: \(unexpected.textRepresentation)")
//        .appFont(AppTextRole.subheadline)
//        .foregroundColor(.orange)
//        .padding(.horizontal, 3)
//    case .pending:
//      EmptyView()
//    }
//  }
//
//  /// Consolidated function to load more parent posts - handles both displaying more loaded parents
//  /// and fetching additional parents from the API when needed
//  private func loadMoreParents() {
//    guard !isLoadingMoreParents, let threadManager = threadManager else {
//      logger.debug(
//        "loadMoreParents: Skipped - isLoadingMoreParents: \(isLoadingMoreParents), threadManager: \(threadManager != nil)"
//      )
//      return
//    }
//
//    // If there are no parents at all, nothing to do
//    guard !parentPosts.isEmpty else {
//      logger.debug("loadMoreParents: Skipped - no parent posts exist")
//      return
//    }
//
//    let oldestParent = parentPosts.last!
//
//    // Start loading more parents
//    isLoadingMoreParents = true
//
//    Task { @MainActor in
//      var postURI: ATProtocolURI?
//
//      // Handle the post based on its type
//      var oldestParentPost = oldestParent.post
//
//      // If it's pending, try to load it
//      if case .pending = oldestParentPost {
//        logger.debug("loadMoreParents: Found pending post, loading deferred data")
//        // This loads the full data for the pending post
//        await oldestParentPost.loadPendingData()
//      }
//
//      // Now check what we have after potential loading
//      if case .appBskyFeedDefsThreadViewPost(let threadViewPost) = oldestParentPost {
//        postURI = threadViewPost.post.uri
//        logger.debug("loadMoreParents: Using post URI: \(postURI!.uriString())")
//      } else {
//        // Still not a valid post, search backward
//        logger.debug("loadMoreParents: Searching for earlier valid post")
//        for i in (0..<parentPosts.count - 1).reversed() {
//          if case .appBskyFeedDefsThreadViewPost(let post) = parentPosts[i].post {
//            postURI = post.post.uri
//            logger.debug("loadMoreParents: Found valid post at index \(i): \(postURI!.uriString())")
//            break
//          }
//        }
//      }
//
//      // If we found a valid URI, load more parents
//        if let postURI = postURI {
//            // Keep original call
//            let success = await threadManager.loadMoreParents(uri: postURI)
//            
//            // CRITICAL CHANGE: Always refresh from manager regardless of success
//            if let threadUnion = threadManager.threadViewPost,
//               case .appBskyFeedDefsThreadViewPost(let threadViewPost) = threadUnion {
//                
//                // Get the complete chain from manager
//                let fullChainFromManager = collectParentPosts(from: threadViewPost.parent)
//                
//                // Update UI state with the latest data
//                if parentPosts != fullChainFromManager {
//                    logger.debug("loadMoreParents: Updating parentPosts. Old: \(parentPosts.count), New: \(fullChainFromManager.count)")
//                    parentPosts = fullChainFromManager // Replace with authoritative chain
//                } else {
//                    logger.debug("loadMoreParents: No change in parent chain after load attempt.")
//                }
//            }
//            
//            // Log manager result but don't rely on it for UI updates
//            logger.debug("loadMoreParents: Manager reported \(success ? "success" : "no change or failure")")
//        } else {
//        logger.debug("loadMoreParents: No valid parent post found for reference")
//      }
//
//      isLoadingMoreParents = false
//    }
//  }
//
//  private func loadInitialThread() async {
//    logger.debug("loadInitialThread: Starting initial thread load for URI: \(postURI.uriString())")
//    isLoading = true
//    contentOpacity = 0
//
//    threadManager = ThreadManager(appState: appState)
//
//    await threadManager?.loadThread(uri: postURI)
//
//    processThreadData()
//    logger.debug("loadInitialThread: Completed. Parent posts count: \(parentPosts.count)")
//    isLoading = false
//  }
//
//  private func processThreadData() {
//    guard let threadManager = threadManager,
//      let threadUnion = threadManager.threadViewPost
//    else {
//      return
//    }
//
//    switch threadUnion {
//    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
//      let oldParentCount = parentPosts.count
//      parentPosts = collectParentPosts(from: threadViewPost.parent)
//
//      mainPost = threadViewPost.post
//
//      if let replies = threadViewPost.replies {
//          replyWrappers = selectRelevantReplies(replies, opAuthorID: threadViewPost.post.author.did.didString())
//      } else {
//        replyWrappers = []
//      }
//
//    default:
//      parentPosts = []
//      mainPost = nil
//      replyWrappers = []
//    }
//  }
//
//    private func collectParentPosts(from initialPost: AppBskyFeedDefs.ThreadViewPostParentUnion?)
//      -> [ParentPost] {
//      var parents: [ParentPost] = []
//      var currentPost = initialPost
//      var grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
//      var depth = 0
//            
//      while let post = currentPost {
//        depth += 1
//        switch post {
//        case .appBskyFeedDefsThreadViewPost(let threadViewPost):
//          let postURI = threadViewPost.post.uri.uriString()
//          parents.append(ParentPost(id: postURI, post: post, grandparentAuthor: grandparentAuthor))
//          grandparentAuthor = threadViewPost.post.author
//          currentPost = threadViewPost.parent
//          
//        case .appBskyFeedDefsNotFoundPost(let notFoundPost):
//          let uri = notFoundPost.uri.uriString()
//          parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
//          currentPost = nil
//          
//        case .appBskyFeedDefsBlockedPost(let blockedPost):
//          let uri = blockedPost.uri.uriString()
//          parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
//          currentPost = nil
//          
//        case .pending(let pendingData):
//          // Generate a more consistent ID for pending posts based on the type
//          let pendingID = "pending-\(pendingData.type)-\(depth)"
//
//          parents.append(ParentPost(id: pendingID, post: post, grandparentAuthor: grandparentAuthor))
//          
//          // Important: Don't terminate the chain, try to access parent if possible
//          if let threadViewPost = try? post.getThreadViewPost() {
//            currentPost = threadViewPost.parent
//            logger.debug("collectParentPosts: Accessed parent through pending post")
//          } else {
//            currentPost = nil
//            logger.debug("collectParentPosts: Could not access parent through pending post")
//          }
//
//        case .unexpected:
//          let unexpectedID = "unexpected-\(depth)-\(UUID().uuidString.prefix(8))"
//          logger.debug("collectParentPosts: Found unexpected post type at depth \(depth): \(unexpectedID)")
//          parents.append(ParentPost(id: unexpectedID, post: post, grandparentAuthor: grandparentAuthor))
//          currentPost = nil
//        }
//      }
//      
//      if !parents.isEmpty {
////        logger.debug("collectParentPosts: Parent URIs in order: \(parents.map { $0.id }.joined(separator: ", "))")
//      }
//      
//      return parents
//    }
//
//  @ViewBuilder
//  private func replyView(for wrapper: ReplyWrapper, opAuthorID: String) -> some View {
//    switch wrapper.reply {
//    case .appBskyFeedDefsThreadViewPost(let replyPost):
//      VStack(alignment: .leading, spacing: 0) {
//        // The reply post itself - mark as parent if we're showing a reply beneath it
//        PostView(
//          post: replyPost.post,
//          grandparentAuthor: nil,
//          isParentPost: replyPost.replies?.isEmpty == false,  // This creates the connecting line
//          isSelectable: false,
//          path: $path,
//          appState: appState
//        )
//        .contentShape(Rectangle())
//        .onTapGesture {
//          path.append(NavigationDestination.post(replyPost.post.uri))
//        }
//
//        // Show just one reply to create a continuous thread feeling
//        if let replies = replyPost.replies, !replies.isEmpty {
//          // Get the most relevant reply to show (might be from OP or has most engagement)
//          let nestedReplyToShow = selectMostRelevantReply(replies, opAuthorID: opAuthorID)
//
//          switch nestedReplyToShow {
//          case .appBskyFeedDefsThreadViewPost(let nestedPost):
//            PostView(
//              post: nestedPost.post,
//              grandparentAuthor: nil,
//              isParentPost: false,  // End of visible thread
//              isSelectable: false,
//              path: $path,
//              appState: appState
//            )
//            .contentShape(Rectangle())
//            .onTapGesture {
//              path.append(NavigationDestination.post(nestedPost.post.uri))
//            }
//          default:
//            EmptyView()
//          }
//        }
//      }
//      .padding(.vertical, 3)
//      .padding(.horizontal, 6)
//      .frame(maxWidth: 550, alignment: .leading)
//
//    // Other cases remain the same
//    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
//      Text("Reply not found: \(notFoundPost.uri.uriString())")
//        .foregroundColor(.red)
//    case .appBskyFeedDefsBlockedPost(let blocked):
//      BlockedPostView(blockedPost: blocked, path: $path)
//    case .unexpected(let unexpected):
//      Text("Unexpected reply type: \(unexpected.textRepresentation)")
//        .foregroundColor(.orange)
//    case .pending:
//      EmptyView()
//    }
//  }
//
//  // Helper function to select the most relevant nested reply to show
//  private func selectMostRelevantReply(
//    _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion], opAuthorID: String
//  ) -> AppBskyFeedDefs.ThreadViewPostRepliesUnion {
//    // Priority: 1) From OP, 2) Has replies itself, 3) Most recent
//
//    // Check for replies from OP
//    if let opReply = replies.first(where: { reply in
//      if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//          return post.post.author.did.didString() == opAuthorID
//      }
//      return false
//    }) {
//      return opReply
//    }
//
//    // Check for replies that have their own replies
//    if let threadReply = replies.first(where: { reply in
//      if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//        return !(post.replies?.isEmpty ?? true)
//      }
//      return false
//    }) {
//      return threadReply
//    }
//
//    // Default to first reply
//    return replies.first!
//  }
//  func selectRelevantReplies(
//    _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion], opAuthorID: String
//  ) -> [ReplyWrapper] {
//    // First, convert replies to ReplyWrapper and extract relevant information
//    let wrappedReplies = replies.map { reply -> ReplyWrapper in
//      let id = getReplyID(reply)
//      let isFromOP =
//        if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//            post.post.author.did.didString() == opAuthorID
//        } else {
//          false
//        }
//      let hasReplies =
//        if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//          !(post.replies?.isEmpty ?? true)
//        } else {
//          false
//        }
//      return ReplyWrapper(id: id, reply: reply, isFromOP: isFromOP, hasReplies: hasReplies)
//    }
//
//    // Sort replies to prioritize:
//    // 1. Replies from the original poster
//    // 2. Replies that have their own replies (indicating discussion)
//    // 3. Most recent replies
//    return wrappedReplies.sorted { first, second in
//      if first.isFromOP != second.isFromOP {
//        return first.isFromOP
//      }
//      if first.hasReplies != second.hasReplies {
//        return first.hasReplies
//      }
//      return first.id > second.id  // Assuming IDs are chronological
//    }
//  }
//
//  private func getReplyID(_ reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion) -> String {
//    switch reply {
//    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
//      return threadViewPost.post.uri.uriString()
//    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
//      return notFoundPost.uri.uriString()
//    case .appBskyFeedDefsBlockedPost(let blockedPost):
//      return blockedPost.uri.uriString()
//    case .unexpected:
//      return UUID().uuidString
//    case .pending:
//      return UUID().uuidString
//    }
//  }
//
//  @ViewBuilder
//  private func recursiveReplyView(
//    reply: AppBskyFeedDefs.ThreadViewPost,
//    opAuthorID: String,
//    depth: Int,
//    maxDepth: Int
//  ) -> some View {
//    VStack(alignment: .leading, spacing: 0) {
//      // Display the current reply
//      // Only show connecting line if it has replies AND we haven't reached max depth
//      let showConnectingLine = reply.replies?.isEmpty == false && depth < maxDepth
//
//      PostView(
//        post: reply.post,
//        grandparentAuthor: nil,
//        isParentPost: showConnectingLine,
//        isSelectable: false,
//        path: $path,
//        appState: appState
//      )
//      .contentShape(Rectangle())
//      .onTapGesture {
//        path.append(NavigationDestination.post(reply.post.uri))
//      }
//      .padding(.vertical, 3)
//
//      // If we're at max depth but there are more replies, show "Continue thread" button
//      if depth == maxDepth && reply.replies?.isEmpty == false {
//        Button(action: {
//          path.append(NavigationDestination.post(reply.post.uri))
//        }) {
//          HStack {
//            Text("Continue thread")
//              .appFont(AppTextRole.subheadline)
//              .foregroundColor(.accentColor)
//            Image(systemName: "chevron.right")
//              .appFont(AppTextRole.subheadline)
//              .foregroundColor(.accentColor)
//          }
//          .padding(.vertical, 8)
//          .padding(.horizontal, 12)
//          .frame(maxWidth: .infinity, alignment: .leading)
//          .contentShape(Rectangle())
//        }
//      }
//      // If we haven't reached max depth and there are replies, show the next post
//      else if depth < maxDepth, let replies = reply.replies, !replies.isEmpty {
//        let topReply = selectMostRelevantReply(replies, opAuthorID: opAuthorID)
//
//        if case .appBskyFeedDefsThreadViewPost(let nestedPost) = topReply {
//          AnyView(
//            recursiveReplyView(
//              reply: nestedPost,
//              opAuthorID: opAuthorID,
//              depth: depth + 1,
//              maxDepth: maxDepth
//            ))
//        }
//      }
//    }
//  }
//
//  // Helper function to select top replies
//  private func selectTopReplies(
//    _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion],
//    opAuthorID: String,
//    count: Int
//  ) -> [ReplyWrapper] {
//    // Use your existing selectRelevantReplies function
//    return Array(selectRelevantReplies(replies, opAuthorID: opAuthorID).prefix(count))
//  }
//
//  struct ReplyWrapper: Identifiable, Equatable {
//    let id: String
//    let reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion
//    let isFromOP: Bool
//    let hasReplies: Bool
//    static func == (lhs: ReplyWrapper, rhs: ReplyWrapper) -> Bool {
//      return lhs.id == rhs.id
//      // Optionally include the scalar properties if needed
//      // && lhs.isFromOP == rhs.isFromOP && lhs.hasReplies == rhs.hasReplies
//    }
//
//  }
//
//  struct ParentPost: Identifiable, Equatable {
//    let id: String
//    let post: AppBskyFeedDefs.ThreadViewPostParentUnion
//    let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
//
//    static func == (lhs: ParentPost, rhs: ParentPost) -> Bool {
//      return lhs.id == rhs.id
//    }
//  }
// }
//
// extension AppBskyFeedDefs.ThreadViewPostParentUnion {
//  func getThreadViewPost() throws -> AppBskyFeedDefs.ThreadViewPost? {
//    switch self {
//    case .appBskyFeedDefsThreadViewPost(let post):
//      return post
//    case .pending(let data):
//      // Try to decode the pending data to get a ThreadViewPost
//      if data.type == "app.bsky.feed.defs#threadViewPost" {
//        do {
//          let threadViewPost = try JSONDecoder().decode(AppBskyFeedDefs.ThreadViewPost.self, from: data.rawData)
//          return threadViewPost
//        } catch {
//          return nil
//        }
//      }
//      return nil
//    default:
//      return nil
//    }
//  }
// }
