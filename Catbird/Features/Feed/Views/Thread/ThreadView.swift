import Petrel
import SwiftUI
import OSLog

// Import cross-platform modifiers for iOS-specific modifiers
#if os(macOS)
// Ensure we import the cross-platform extensions
#endif

/// Cross-platform ThreadView that provides:
/// - iOS: Wrapper around UIKitThreadView for optimal performance
/// - macOS: Pure SwiftUI implementation for native experience
struct ThreadView: View {
    @Environment(AppState.self) private var appState: AppState
    let postURI: ATProtocolURI
    @Binding var path: NavigationPath
    
    var body: some View {
        #if os(iOS)
        UIKitThreadViewWrapper(postURI: postURI, path: $path, appState: appState)
        #elseif os(macOS)
        SwiftUIThreadView(postURI: postURI, path: $path)
        #endif
    }
}

#if os(iOS)
/// iOS wrapper around the high-performance UIKit thread view
private struct UIKitThreadViewWrapper: View {
    let postURI: ATProtocolURI
    @Binding var path: NavigationPath
    let appState: AppState
    
    var body: some View {
        ThreadViewControllerRepresentable(postURI: postURI, path: $path)
          .ignoresSafeArea()
            .environment(appState)
    }
}
#endif

#if os(macOS)
/// Pure SwiftUI ThreadView implementation optimized for macOS
private struct SwiftUIThreadView: View {
    @Environment(AppState.self) private var appState: AppState
    let postURI: ATProtocolURI
    @Binding var path: NavigationPath
    
    @State private var threadManager: ThreadManager?
    @State private var isLoading = true
    @State private var hasInitialized = false
    @State private var isLoadingMoreParents = false
    @State private var contentOpacity: Double = 0
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var hasScrolledToMainPost = false
    
    @State private var parentPosts: [ParentPost] = []
    @State private var mainPost: AppBskyFeedDefs.PostView? = nil
    @State private var mainBlocked: AppBskyFeedDefs.BlockedPost? = nil
    @State private var mainNotFound: AppBskyFeedDefs.NotFoundPost? = nil
    @State private var replyWrappers: [ReplyWrapper] = []
    
    private static let mainPostID = "main-post-id"
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ThreadView")
    
    var body: some View {
        ZStack {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading thread...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if mainPost != nil || mainBlocked != nil || mainNotFound != nil {
                modernThreadView
                    .opacity(contentOpacity)
                    .onAppear {
                        Task { @MainActor in
                            if !hasScrolledToMainPost {
                                try? await Task.sleep(for: .milliseconds(300))
                                jumpToMainPost()
                                hasScrolledToMainPost = true
                            }
                        }
                        
                        withAnimation(.easeInOut(duration: 0.3)) {
                            contentOpacity = 1
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    if let nf = mainNotFound {
                        PostNotFoundView(uri: nf.uri, reason: .notFound, path: $path)
                    } else if let blocked = mainBlocked {
                        BlockedPostView(blockedPost: blocked, path: $path)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                        Text("Could not load thread")
                            .font(.headline)
                        Text("This post may have been deleted or is not available.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Thread")
        .modifier(NavigationTitleDisplayModeModifier())
        .task {
            guard !hasInitialized else { return }
            hasInitialized = true
            await loadInitialThread()
        }
    }
    
    private func jumpToMainPost() {
        scrollPosition = ScrollPosition(id: SwiftUIThreadView.mainPostID, anchor: .center)
    }
    
    private var modernThreadView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                parentsSection
                
                if let post = mainPost {
                    mainPostSection(post)
                        .id(SwiftUIThreadView.mainPostID)
                        .padding(.bottom, 12)
                } else if let blocked = mainBlocked {
                    BlockedPostView(blockedPost: blocked, path: $path)
                        .padding(.vertical, 8)
                        .id(SwiftUIThreadView.mainPostID)
                        .padding(.bottom, 12)
                } else if let nf = mainNotFound {
                    PostNotFoundView(uri: nf.uri, reason: .notFound, path: $path)
                        .padding(.vertical, 8)
                        .id(SwiftUIThreadView.mainPostID)
                        .padding(.bottom, 12)
                }
                
                repliesSection
                
                // Extra space at bottom for comfortable scrolling
                Spacer(minLength: 200)
            }
            .padding(.horizontal, 16)
        }
        .scrollPosition($scrollPosition, anchor: .top)
    }
    
    private var parentsSection: some View {
        LazyVStack(spacing: 8) {
            if isLoadingMoreParents {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading more parents...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            
            if !parentPosts.isEmpty {
                // Invisible trigger for loading more parents
                Color.clear
                    .frame(height: 20)
                    .onAppear {
                        logger.debug("Top of parents section appeared, triggering loadMoreParents")
                        loadMoreParents()
                    }
                    .id("load-trigger-\(parentPosts.count)")
                
                // Display parents in reverse chronological order
                ForEach(Array(parentPosts.reversed()), id: \.id) { parentPost in
                    parentPostView(for: parentPost)
                        .id(parentPost.id)
                        .onAppear {
                            if parentPost.id == parentPosts.first?.id {
                                logger.debug("Oldest parent post appeared, triggering loadMoreParents")
                                loadMoreParents()
                            }
                        }
                }
            }
        }
    }
    
    @ViewBuilder
    private func mainPostSection(_ post: AppBskyFeedDefs.PostView) -> some View {
        VStack(spacing: 0) {
            ThreadViewMainPostView(
                post: post,
                showLine: false,
                path: $path,
                appState: appState
            )
            .padding(.vertical, 8)
            
            Divider()
                .padding(.horizontal, -16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(platformColor: PlatformColor.platformSecondarySystemBackground).opacity(0.3))
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        )
    }
    
    private var repliesSection: some View {
        LazyVStack(spacing: 8) {
            ForEach(replyWrappers, id: \.id) { wrapper in
                if case .appBskyFeedDefsThreadViewPost(let replyPost) = wrapper.reply {
                    recursiveReplyView(
                        reply: replyPost,
                        opAuthorID: mainPost?.author.did.didString() ?? "",
                        depth: 0,
                        maxDepth: 3
                    )
                } else {
                    replyView(for: wrapper, opAuthorID: mainPost?.author.did.didString() ?? "")
                }
                
                if wrapper.id != replyWrappers.last?.id {
                    Divider()
                        .padding(.horizontal, -16)
                }
            }
        }
    }
    
    @ViewBuilder
    private func parentPostView(for parentPost: ParentPost) -> some View {
        switch parentPost.post {
        case .appBskyFeedDefsThreadViewPost(let post):
            PostView(
                post: post.post,
                grandparentAuthor: nil,
                isParentPost: true,
                isSelectable: false,
                path: $path,
                appState: appState
            )
            .contentShape(Rectangle())
            .onTapGesture {
                path.append(NavigationDestination.post(post.post.uri))
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(platformColor: PlatformColor.platformSecondarySystemBackground).opacity(0.1))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            
        case .appBskyFeedDefsNotFoundPost(let notFoundPost):
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.orange)
                Text("Parent post not found")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground).opacity(0.5))
            .cornerRadius(8)
            
        case .appBskyFeedDefsBlockedPost(let blockedPost):
            BlockedPostView(blockedPost: blockedPost, path: $path)
            
        case .unexpected(let unexpected):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Unexpected post type")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground).opacity(0.5))
            .cornerRadius(8)
            
        case .pending(_):
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading post...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func replyView(for wrapper: ReplyWrapper, opAuthorID: String) -> some View {
        switch wrapper.reply {
        case .appBskyFeedDefsThreadViewPost(let replyPost):
            VStack(alignment: .leading, spacing: 4) {
                PostView(
                    post: replyPost.post,
                    grandparentAuthor: nil,
                    isParentPost: replyPost.replies?.isEmpty == false,
                    isSelectable: false,
                    path: $path,
                    appState: appState
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    path.append(NavigationDestination.post(replyPost.post.uri))
                }
                
                // Show nested reply preview
                if let replies = replyPost.replies, !replies.isEmpty {
                    let nestedReplyToShow = selectMostRelevantReply(replies, opAuthorID: opAuthorID)
                    
                    if case .appBskyFeedDefsThreadViewPost(let nestedPost) = nestedReplyToShow {
                        PostView(
                            post: nestedPost.post,
                            grandparentAuthor: nil,
                            isParentPost: false,
                            isSelectable: false,
                            path: $path,
                            appState: appState
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            path.append(NavigationDestination.post(nestedPost.post.uri))
                        }
                        .padding(.leading, 20)
                        .opacity(0.8)
                    }
                }
            }
            
        case .appBskyFeedDefsNotFoundPost(let notFoundPost):
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.red)
                Text("Reply not found")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
            
        case .appBskyFeedDefsBlockedPost(let blocked):
            BlockedPostView(blockedPost: blocked, path: $path)
            
        case .unexpected(let unexpected):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Unexpected reply type")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
            
        case .pending(_):
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading reply...")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func recursiveReplyView(
        reply: AppBskyFeedDefs.ThreadViewPost,
        opAuthorID: String,
        depth: Int,
        maxDepth: Int
    ) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
            let showConnectingLine = reply.replies?.isEmpty == false && depth < maxDepth
            
            PostView(
                post: reply.post,
                grandparentAuthor: nil,
                isParentPost: showConnectingLine,
                isSelectable: false,
                path: $path,
                appState: appState
            )
            .contentShape(Rectangle())
            .onTapGesture {
                path.append(NavigationDestination.post(reply.post.uri))
            }
            .padding(.leading, CGFloat(depth * 16))
            
            // Continue thread button at max depth
            if depth == maxDepth && reply.replies?.isEmpty == false {
                Button(action: {
                    path.append(NavigationDestination.post(reply.post.uri))
                }) {
                    HStack {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                        Text("Continue thread (\(reply.replies?.count ?? 0) more)")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.leading, CGFloat((depth + 1) * 16))
            }
            // Show nested replies within depth limit
            else if depth < maxDepth, let replies = reply.replies, !replies.isEmpty {
                let topReply = selectMostRelevantReply(replies, opAuthorID: opAuthorID)
                
                if case .appBskyFeedDefsThreadViewPost(let nestedPost) = topReply {
                    AnyView(recursiveReplyView(
                        reply: nestedPost,
                        opAuthorID: opAuthorID,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    ))
                }
            }
        }
    }
}
    
    // MARK: - Data Loading Methods
    
    private func loadMoreParents() {
        guard !isLoadingMoreParents, let threadManager = threadManager else {
            logger.debug("loadMoreParents: Skipped - already loading or no manager")
            return
        }
        
        guard !parentPosts.isEmpty else {
            logger.debug("loadMoreParents: Skipped - no parent posts exist")
            return
        }
        
        let oldestParent = parentPosts.last!
        isLoadingMoreParents = true
        
        Task { @MainActor in
            var postURI: ATProtocolURI? = nil
            var oldestParentPost = oldestParent.post
            
            // Handle pending posts
            if case .pending = oldestParentPost {
                logger.debug("loadMoreParents: Found pending post, loading deferred data")
                await oldestParentPost.loadPendingData()
            }
            
            // Extract URI from valid post
            if case .appBskyFeedDefsThreadViewPost(let threadViewPost) = oldestParentPost {
                postURI = threadViewPost.post.uri
            } else {
                // Search for earlier valid post
                for i in (0..<parentPosts.count - 1).reversed() {
                    if case .appBskyFeedDefsThreadViewPost(let post) = parentPosts[i].post {
                        postURI = post.post.uri
                        break
                    }
                }
            }
            
            if let postURI = postURI {
                let success = await threadManager.loadMoreParents(uri: postURI)
                
                // Refresh data from manager
                if let threadUnion = threadManager.threadViewPost,
                   case .appBskyFeedDefsThreadViewPost(let threadViewPost) = threadUnion {
                    
                    let fullChainFromManager = collectParentPosts(from: threadViewPost.parent)
                    
                    if parentPosts != fullChainFromManager {
                        logger.debug("loadMoreParents: Updating parentPosts. Old: \(parentPosts.count), New: \(fullChainFromManager.count)")
                        parentPosts = fullChainFromManager
                    }
                }
            }
            
            isLoadingMoreParents = false
        }
    }
    
    private func loadInitialThread() async {
        logger.debug("loadInitialThread: Starting for URI: \(postURI.uriString())")
        isLoading = true
        contentOpacity = 0
        
        threadManager = ThreadManager(appState: appState)
        await threadManager?.loadThread(uri: postURI)
        
        processThreadData()
        logger.debug("loadInitialThread: Completed. Parents: \(parentPosts.count)")
        isLoading = false
    }
    
    private func processThreadData() {
        guard let threadManager = threadManager,
              let threadUnion = threadManager.threadViewPost else {
            return
        }
        
        switch threadUnion {
        case .appBskyFeedDefsThreadViewPost(let threadViewPost):
            parentPosts = collectParentPosts(from: threadViewPost.parent)
            mainPost = threadViewPost.post
            mainBlocked = nil
            mainNotFound = nil
            
            if let replies = threadViewPost.replies {
                replyWrappers = selectRelevantReplies(replies, opAuthorID: threadViewPost.post.author.did.didString())
            } else {
                replyWrappers = []
            }
            
        case .appBskyFeedDefsBlockedPost(let blocked):
            parentPosts = []
            mainPost = nil
            mainBlocked = blocked
            mainNotFound = nil
            replyWrappers = []
        case .appBskyFeedDefsNotFoundPost(let nf):
            parentPosts = []
            mainPost = nil
            mainBlocked = nil
            mainNotFound = nf
            replyWrappers = []
        default:
            parentPosts = []
            mainPost = nil
            mainBlocked = nil
            mainNotFound = nil
            replyWrappers = []
        }
    }
    
    private func collectParentPosts(from initialPost: AppBskyFeedDefs.ThreadViewPostParentUnion?) -> [ParentPost] {
        var parents: [ParentPost] = []
        var currentPost = initialPost
        var grandparentAuthor: AppBskyActorDefs.ProfileViewBasic? = nil
        var depth = 0
        
        while let post = currentPost {
            depth += 1
            switch post {
            case .appBskyFeedDefsThreadViewPost(let threadViewPost):
                let postURI = threadViewPost.post.uri.uriString()
                parents.append(ParentPost(id: postURI, post: post, grandparentAuthor: grandparentAuthor))
                grandparentAuthor = threadViewPost.post.author
                currentPost = threadViewPost.parent
                
            case .appBskyFeedDefsNotFoundPost(let notFoundPost):
                let uri = notFoundPost.uri.uriString()
                parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
                currentPost = nil
                
            case .appBskyFeedDefsBlockedPost(let blockedPost):
                let uri = blockedPost.uri.uriString()
                parents.append(ParentPost(id: uri, post: post, grandparentAuthor: grandparentAuthor))
                currentPost = nil
                
            case .pending(let pendingData):
                let pendingID = "pending-\(pendingData.type)-\(depth)"
                parents.append(ParentPost(id: pendingID, post: post, grandparentAuthor: grandparentAuthor))
                
                if let threadViewPost = try? post.getThreadViewPost() {
                    currentPost = threadViewPost.parent
                } else {
                    currentPost = nil
                }
                
            case .unexpected(_):
                let unexpectedID = "unexpected-\(depth)-\(UUID().uuidString.prefix(8))"
                parents.append(ParentPost(id: unexpectedID, post: post, grandparentAuthor: grandparentAuthor))
                currentPost = nil
            }
        }
        
        return parents
    }
    
    // MARK: - Helper Methods
    
    private func selectMostRelevantReply(
        _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion],
        opAuthorID: String
    ) -> AppBskyFeedDefs.ThreadViewPostRepliesUnion {
        // Priority: 1) From OP, 2) Has replies, 3) Most recent
        
        if let opReply = replies.first(where: { reply in
            if case .appBskyFeedDefsThreadViewPost(let post) = reply {
                return post.post.author.did.didString() == opAuthorID
            }
            return false
        }) {
            return opReply
        }
        
        if let threadReply = replies.first(where: { reply in
            if case .appBskyFeedDefsThreadViewPost(let post) = reply {
                return !(post.replies?.isEmpty ?? true)
            }
            return false
        }) {
            return threadReply
        }
        
        return replies.first!
    }
    
    private func selectRelevantReplies(
        _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion],
        opAuthorID: String
    ) -> [ReplyWrapper] {
        let wrappedReplies = replies.map { reply -> ReplyWrapper in
            let id = getReplyID(reply)
            let isFromOP: Bool
            let hasReplies: Bool
            
            if case .appBskyFeedDefsThreadViewPost(let post) = reply {
                isFromOP = post.post.author.did.didString() == opAuthorID
                hasReplies = !(post.replies?.isEmpty ?? true)
            } else {
                isFromOP = false
                hasReplies = false
            }
            
            return ReplyWrapper(id: id, reply: reply, isFromOP: isFromOP, hasReplies: hasReplies)
        }
        
        return wrappedReplies.sorted { first, second in
            if first.isFromOP != second.isFromOP {
                return first.isFromOP
            }
            if first.hasReplies != second.hasReplies {
                return first.hasReplies
            }
            return first.id > second.id
        }
    }
    
    private func getReplyID(_ reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion) -> String {
        switch reply {
        case .appBskyFeedDefsThreadViewPost(let threadViewPost):
            return threadViewPost.post.uri.uriString()
        case .appBskyFeedDefsNotFoundPost(let notFoundPost):
            return notFoundPost.uri.uriString()
        case .appBskyFeedDefsBlockedPost(let blockedPost):
            return blockedPost.uri.uriString()
        case .unexpected, .pending:
            return UUID().uuidString
        }
    }
    
    // MARK: - Data Structures
    
    struct ReplyWrapper: Identifiable, Equatable {
        let id: String
        let reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion
        let isFromOP: Bool
        let hasReplies: Bool
        
        static func == (lhs: ReplyWrapper, rhs: ReplyWrapper) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    struct ParentPost: Identifiable, Equatable {
        let id: String
        let post: AppBskyFeedDefs.ThreadViewPostParentUnion
        let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
        
        static func == (lhs: ParentPost, rhs: ParentPost) -> Bool {
            return lhs.id == rhs.id
        }
    }
}

// MARK: - Extensions

extension AppBskyFeedDefs.ThreadViewPostParentUnion {
    func getThreadViewPost() throws -> AppBskyFeedDefs.ThreadViewPost? {
        switch self {
        case .appBskyFeedDefsThreadViewPost(let post):
            return post
        case .pending(let data):
            if data.type == "app.bsky.feed.defs#threadViewPost" {
                do {
                    let threadViewPost = try JSONDecoder().decode(AppBskyFeedDefs.ThreadViewPost.self, from: data.rawData)
                    return threadViewPost
                } catch {
                    return nil
                }
            }
            return nil
        default:
            return nil
        }
    }
}

struct NavigationTitleDisplayModeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}
#endif
