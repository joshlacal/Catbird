import Petrel
import SwiftUI
import SwiftData
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
            .applyAppStateEnvironment(appState)
    }
}
#endif

#if os(macOS)
/// Pure SwiftUI ThreadView implementation optimized for macOS
/// Uses the V2 thread API (flat array of ThreadItem with depth values)
private struct SwiftUIThreadView: View {
    @Environment(AppState.self) private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    let postURI: ATProtocolURI
    @Binding var path: NavigationPath

    @State private var threadManager: ThreadManager?
    @State private var isLoading = true
    @State private var hasInitialized = false
    @State private var isLoadingMoreParents = false
    @State private var contentOpacity: Double = 0
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var hasScrolledToMainPost = false

    // V2 types: ParentPost and ReplyWrapper from ThreadManager.swift
    @State private var parentPosts: [ParentPost] = []
    @State private var mainPost: AppBskyFeedDefs.PostView? = nil
    @State private var mainItemIsBlocked = false
    @State private var mainItemIsNotFound = false
    @State private var replyWrappers: [ReplyWrapper] = []
    @State private var hasMoreParents = false

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
            } else if mainPost != nil || mainItemIsBlocked || mainItemIsNotFound {
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
            } else if mainItemIsNotFound {
                ContentUnavailableView {
                    Label("Post Not Found", systemImage: "questionmark.circle")
                } description: {
                    Text("This post may have been deleted.")
                }
            } else if mainItemIsBlocked {
                ContentUnavailableView {
                    Label("Post Blocked", systemImage: "hand.raised")
                } description: {
                    Text("This post is from a blocked account.")
                }
            } else {
                ContentUnavailableView {
                    Label("Post Not Available", systemImage: "exclamationmark.circle")
                } description: {
                    Text("This post may have been deleted or is not available.")
                }
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
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LazyVStack(spacing: 0) {
                    parentsSection

                    if let post = mainPost {
                        mainPostSection(post)
                            .id(SwiftUIThreadView.mainPostID)
                            .padding(.bottom, 12)
                    } else if mainItemIsBlocked {
                        HStack {
                            Image(systemName: "hand.raised")
                                .foregroundColor(.red)
                            Text("This post is from a blocked account.")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .id(SwiftUIThreadView.mainPostID)
                        .padding(.bottom, 12)
                    } else if mainItemIsNotFound {
                        HStack {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.orange)
                            Text("Post not found")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                        .id(SwiftUIThreadView.mainPostID)
                        .padding(.bottom, 12)
                    }

                    repliesSection

                    Spacer(minLength: 200)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 700)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 8, for: .scrollContent)
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
                if hasMoreParents {
                    Color.clear
                        .frame(height: 20)
                        .onAppear {
                            logger.debug("Top of parents section appeared, triggering loadMoreParents")
                            loadMoreParents()
                        }
                        .id("load-trigger-\(parentPosts.count)")
                }

                // Parents are already ordered from oldest (most negative depth) to newest
                ForEach(parentPosts, id: \.id) { parentPost in
                    parentPostView(for: parentPost)
                        .id(parentPost.id)
                        .onAppear {
                            if hasMoreParents && parentPost.id == parentPosts.first?.id {
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
                replyView(for: wrapper, opAuthorID: mainPost?.author.did.didString() ?? "")

                if wrapper.id != replyWrappers.last?.id {
                    Divider()
                        .padding(.horizontal, -16)
                }
            }
        }
    }

    @ViewBuilder
    private func parentPostView(for parentPost: ParentPost) -> some View {
        let threadItem = parentPost.threadItem
        switch threadItem.value {
        case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
            PostView(
                post: itemPost.post,
                grandparentAuthor: parentPost.grandparentAuthor,
                isParentPost: true,
                isSelectable: false,
                path: $path,
                appState: appState,
                hasVisibleThreadContext: true
            )
            .contentShape(Rectangle())
            .onTapGesture {
                path.append(NavigationDestination.post(itemPost.post.uri))
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(platformColor: PlatformColor.platformSecondarySystemBackground).opacity(0.1))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )

        case .appBskyUnspeccedDefsThreadItemNotFound:
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

        case .appBskyUnspeccedDefsThreadItemBlocked:
            HStack {
                Image(systemName: "hand.raised")
                    .foregroundColor(.red)
                Text("Blocked post")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)

        default:
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
        }
    }

    @ViewBuilder
    private func replyView(for wrapper: ReplyWrapper, opAuthorID: String) -> some View {
        let threadItem = wrapper.threadItem
        switch threadItem.value {
        case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
            let indentLevel = max(0, wrapper.depth - 1)
            VStack(alignment: .leading, spacing: 4) {
                PostView(
                    post: itemPost.post,
                    grandparentAuthor: nil,
                    isParentPost: wrapper.hasReplies,
                    isSelectable: false,
                    path: $path,
                    appState: appState,
                    hasVisibleThreadContext: wrapper.hasReplies
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    path.append(NavigationDestination.post(itemPost.post.uri))
                }

                // Show "Continue thread" button for posts with more replies not in the flat list
                if itemPost.moreReplies > 0 {
                    Button(action: {
                        path.append(NavigationDestination.post(itemPost.post.uri))
                    }) {
                        HStack {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption)
                            Text("Continue thread (\(itemPost.moreReplies) more)")
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
                    .padding(.leading, CGFloat(indentLevel * 16))
                }
            }
            .padding(.leading, CGFloat(indentLevel * 16))

        case .appBskyUnspeccedDefsThreadItemNotFound:
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

        case .appBskyUnspeccedDefsThreadItemBlocked:
            HStack {
                Image(systemName: "hand.raised")
                    .foregroundColor(.red)
                Text("Reply from blocked account")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)

        default:
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
        }
    }

    // MARK: - Data Loading Methods

    private func loadMoreParents() {
        guard !isLoadingMoreParents, let threadManager = threadManager else {
            logger.debug("loadMoreParents: Skipped - already loading or no manager")
            return
        }

        guard !parentPosts.isEmpty, hasMoreParents else {
            logger.debug("loadMoreParents: Skipped - no parent posts or no more parents available")
            return
        }

        // Find the oldest parent's URI
        guard let oldestParent = parentPosts.first else { return }

        isLoadingMoreParents = true

        Task { @MainActor in
            let uri = oldestParent.threadItem.uri
            let success = await threadManager.loadMoreParents(uri: uri)

            if success {
                // Re-process thread data after loading more parents
                processThreadData()
            }

            isLoadingMoreParents = false
        }
    }

    private func loadInitialThread() async {
        logger.debug("loadInitialThread: Starting for URI: \(postURI.uriString())")
        isLoading = true
        contentOpacity = 0

        threadManager = ThreadManager(appState: appState)
        threadManager?.setModelContext(modelContext)
        await threadManager?.loadThread(uri: postURI)

        processThreadData()
        logger.debug("loadInitialThread: Completed. Parents: \(parentPosts.count)")
        isLoading = false
    }

    /// Process the flat V2 thread array into parent posts, main post, and replies.
    /// V2 API returns a flat `[ThreadItem]` where:
    ///   - depth < 0: parent posts (most negative = oldest ancestor)
    ///   - depth == 0: the anchor/main post
    ///   - depth > 0: reply posts
    private func processThreadData() {
        guard let threadManager = threadManager,
              let threadData = threadManager.threadData else {
            return
        }

        let thread = threadData.thread

        // Find the anchor post (depth == 0)
        guard let anchorItem = thread.first(where: { $0.depth == 0 }) else {
            // No anchor found - clear everything
            parentPosts = []
            mainPost = nil
            mainItemIsBlocked = false
            mainItemIsNotFound = false
            replyWrappers = []
            hasMoreParents = false
            return
        }

        // Process the anchor/main post
        switch anchorItem.value {
        case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
            mainPost = itemPost.post
            mainItemIsBlocked = false
            mainItemIsNotFound = false
        case .appBskyUnspeccedDefsThreadItemBlocked:
            mainPost = nil
            mainItemIsBlocked = true
            mainItemIsNotFound = false
        case .appBskyUnspeccedDefsThreadItemNotFound:
            mainPost = nil
            mainItemIsBlocked = false
            mainItemIsNotFound = true
        default:
            mainPost = nil
            mainItemIsBlocked = false
            mainItemIsNotFound = false
        }

        // Extract parent posts (depth < 0), sorted from most negative (oldest) to -1 (closest to anchor)
        let parentItems = thread
            .filter { $0.depth < 0 }
            .sorted { $0.depth < $1.depth }

        // Build ParentPost array with grandparent author tracking
        var parents: [ParentPost] = []
        for (index, item) in parentItems.enumerated() {
            let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?
            if index > 0 {
                // The grandparent is the item before this one in the parent chain
                if case .appBskyUnspeccedDefsThreadItemPost(let prevPost) = parentItems[index - 1].value {
                    grandparentAuthor = prevPost.post.author
                } else {
                    grandparentAuthor = nil
                }
            } else {
                grandparentAuthor = nil
            }

            parents.append(ParentPost(
                id: item.uri.uriString(),
                threadItem: item,
                grandparentAuthor: grandparentAuthor
            ))
        }
        parentPosts = parents

        // Check if the topmost parent has moreParents flag
        if let topParent = parentItems.first,
           case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = topParent.value {
            hasMoreParents = itemPost.moreParents
        } else {
            hasMoreParents = false
        }

        // Extract the OP author DID for reply sorting
        let opAuthorID = mainPost?.author.did.didString() ?? ""

        // Extract reply items (depth > 0), keeping original order from API
        let replyItems = thread.filter { $0.depth > 0 }

        // Build ReplyWrapper array from the flat reply items
        // The V2 API returns replies in display order, so we preserve that
        var wrappers: [ReplyWrapper] = []

        for (index, item) in replyItems.enumerated() {
            let isFromOP: Bool
            let isOpThread: Bool
            let hasReplies: Bool

            switch item.value {
            case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
                isFromOP = itemPost.post.author.did.didString() == opAuthorID
                isOpThread = itemPost.opThread
                // Check if there's a deeper reply following this one in the list
                let hasChildInList = index + 1 < replyItems.count && replyItems[index + 1].depth > item.depth
                hasReplies = hasChildInList || itemPost.moreReplies > 0
            default:
                isFromOP = false
                isOpThread = false
                hasReplies = false
            }

            wrappers.append(ReplyWrapper(
                id: item.uri.uriString(),
                threadItem: item,
                depth: item.depth,
                isFromOP: isFromOP,
                isOpThread: isOpThread,
                hasReplies: hasReplies
            ))
        }

        replyWrappers = wrappers
    }
}

#endif

struct NavigationTitleDisplayModeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

#Preview("ThreadView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    ThreadView(
      postURI: try! ATProtocolURI(uriString: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l2s5xxv6fn2c"),
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
