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
    let visibilityContext: PostVisibilityContext
    private let logger = Logger(subsystem: "blue.catbird", category: "ThreadView")
    
    init(
        postURI: ATProtocolURI,
        path: Binding<NavigationPath>,
        visibilityContext: PostVisibilityContext = .public
    ) {
        self.postURI = postURI
        self._path = path
        self.visibilityContext = visibilityContext
    }
    
    var body: some View {
        Group {
            #if os(iOS)
            UIKitThreadViewWrapper(postURI: postURI, path: $path, appState: appState, visibilityContext: visibilityContext)
            #elseif os(macOS)
            SwiftUIThreadView(postURI: postURI, path: $path, visibilityContext: visibilityContext)
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort Replies", selection: sortSelection) {
                        Text("Top").tag("top")
                        Text("Latest").tag("newest")
                        Text("Oldest").tag("oldest")
                    }
                    .pickerStyle(.inline)

                    Picker("Layout", selection: threadedRepliesSelection) {
                        Text("Linear").tag(false)
                        Text("Threaded").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel("Thread options")
                }
            }
        }
    }

    /// Every stored value other than newest/oldest ("hot", "hotness", "most-likes", …) sorts as Top.
    private var sortSelection: Binding<String> {
        Binding(
            get: {
                let sort = appState.appSettings.threadSortOrder
                return ["newest", "oldest"].contains(sort) ? sort : "top"
            },
            set: { updateSort($0) }
        )
    }

    private var threadedRepliesSelection: Binding<Bool> {
        Binding(
            get: { appState.appSettings.threadedReplies },
            set: { appState.appSettings.threadedReplies = $0 }
        )
    }

    private func updateSort(_ sort: String) {
        appState.appSettings.threadSortOrder = sort
        Task {
            do {
                try await appState.preferencesManager.setThreadViewPreferences(
                    sort: sort,
                    prioritizeFollowedUsers: appState.appSettings.prioritizeFollowedUsers
                )
            } catch {
                logger.error("Failed to save reply order: \(error.localizedDescription)")
                appState.toastManager.show(
                    ToastItem(message: "Couldn’t save reply order. Try again.", icon: "exclamationmark.triangle")
                )
            }
        }
    }
}

#if os(iOS)
/// iOS wrapper around the high-performance UIKit thread view
private struct UIKitThreadViewWrapper: View {
    let postURI: ATProtocolURI
    @Binding var path: NavigationPath
    let appState: AppState
    let visibilityContext: PostVisibilityContext
    
    var body: some View {
        ThreadViewControllerRepresentable(postURI: postURI, path: $path, visibilityContext: visibilityContext)
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
    let visibilityContext: PostVisibilityContext
    @State private var threadManager: ThreadManager?
    @State private var isLoading = true
    @State private var hasInitialized = false
    @State private var isLoadingMoreParents = false
    @State private var hasMoreParents = false
    @State private var contentOpacity: Double = 0
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var hasScrolledToMainPost = false

    @State private var parentPosts: [ParentPost] = []
    @State private var mainPost: AppBskyFeedDefs.PostView?
    @State private var mainPostIndex: Int?
    @State private var mainPostCount: Int?
    @State private var mainItemIsBlocked = false
    @State private var blockedAnchorItem: AppBskyUnspeccedDefs.ThreadItemBlocked?
    @State private var mainItemIsNotFound = false
    @State private var rows: [ThreadRow] = []
    @State private var threadItemsByID: [String: AppBskyUnspeccedGetPostThreadV2.ThreadItem] = [:]
    @State private var hasOtherReplies = false
    @State private var hasLoadedHiddenReplies = false
    @State private var isLoadingHiddenReplies = false

    private static let mainPostID = "main-post-id"

    private let logger = Logger(subsystem: "blue.catbird", category: "ThreadView")

    var body: some View {
        ZStack {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading thread…")
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
        // Linear and tree layouts fetch different reply shapes, so a layout or
        // sort change refetches.
        .onChange(of: appState.appSettings.threadedReplies) { _, _ in
            Task { await loadInitialThread() }
        }
        .onChange(of: appState.appSettings.threadSortOrder) { _, _ in
            Task { await loadInitialThread() }
        }
    }

    private func jumpToMainPost() {
        scrollPosition = ScrollPosition(id: SwiftUIThreadView.mainPostID, anchor: .center)
    }

    private var modernThreadView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                        .id(row.kind == .anchor ? SwiftUIThreadView.mainPostID : row.id)
                }

                if mainPost == nil && blockedAnchorItem == nil && mainItemIsNotFound {
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
                    .padding(.horizontal, ThreadReplyGeometry.rowInset)
                    .id(SwiftUIThreadView.mainPostID)
                }

                Spacer(minLength: 200)
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollPosition($scrollPosition, anchor: .top)
        .safeAreaInset(edge: .bottom) {
            if let post = mainPost {
                ThreadComposePrompt(post: post, appState: appState)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ThreadRow) -> some View {
        switch row.kind {
        case .anchor:
            anchorView(row)
        case .readMoreUp:
            ThreadRowView(
                row: row,
                threadItem: nil,
                parentAuthor: nil,
                path: $path,
                appState: appState,
                visibilityContext: visibilityContext,
                isActionLoading: isLoadingMoreParents,
                onAction: { loadMoreParents() }
            )
            .onAppear { loadMoreParents() }
        case .showOtherReplies:
            ThreadRowView(
                row: row,
                threadItem: nil,
                parentAuthor: nil,
                path: $path,
                appState: appState,
                visibilityContext: visibilityContext,
                isActionLoading: isLoadingHiddenReplies,
                onAction: { loadHiddenReplies() }
            )
        case .ancestor, .reply, .tombstone, .readMore:
            ThreadRowView(
                row: row,
                threadItem: threadItemsByID[row.id],
                parentAuthor: row.parentID.flatMap { threadItemsByID[$0]?.post?.author },
                path: $path,
                appState: appState,
                visibilityContext: visibilityContext
            )
        }
    }

    @ViewBuilder
    private func anchorView(_ row: ThreadRow) -> some View {
        if let post = mainPost {
            ThreadAnchorPostView(
                post: post,
                showsLineFromParent: row.lineIn,
                path: $path,
                appState: appState,
                visibilityContext: visibilityContext,
                opThreadPostIndex: mainPostIndex,
                opThreadPostCount: mainPostCount
            )
        } else if let blocked = blockedAnchorItem {
            BlockedContentCard(
                relationship: BlockRelationship(threadItemBlocked: blocked),
                authorDid: blocked.author.did.didString(),
                postUri: postURI,
                variant: .anchor,
                path: $path
            )
            .applyAppStateEnvironment(appState)
            .padding(.horizontal, ThreadReplyGeometry.rowInset)
            .padding(.vertical, ThreadReplyGeometry.connectedTopSpacing)
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

        let manager = ThreadManager(appState: appState)
        manager.setModelContext(modelContext)
        await manager.loadThread(uri: postURI, visibilityContext: visibilityContext)
        threadManager = manager

        hasOtherReplies = manager.threadData?.hasOtherReplies ?? false
        hasLoadedHiddenReplies = false
        if appState.appSettings.showHiddenPosts && hasOtherReplies {
            await manager.loadHiddenReplies(uri: postURI)
            hasLoadedHiddenReplies = true
        }

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
            mainPostIndex = nil
            mainPostCount = nil
            mainItemIsBlocked = false
            blockedAnchorItem = nil
            mainItemIsNotFound = false
            rows = []
            threadItemsByID = [:]
            hasMoreParents = false
            return
        }

        // Process the anchor/main post
        switch anchorItem.value {
        case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
            mainPost = itemPost.post
            mainPostIndex = itemPost.opThreadPostIndex
            mainPostCount = itemPost.opThreadPostCount
            mainItemIsBlocked = false
            blockedAnchorItem = nil
            mainItemIsNotFound = false
        case .appBskyUnspeccedDefsThreadItemBlocked(let blocked):
            mainPost = nil
            mainPostIndex = nil
            mainPostCount = nil
            mainItemIsBlocked = true
            blockedAnchorItem = blocked
            mainItemIsNotFound = false
        case .appBskyUnspeccedDefsThreadItemNotFound:
            mainPost = nil
            mainPostIndex = nil
            mainPostCount = nil
            mainItemIsBlocked = false
            blockedAnchorItem = nil
            mainItemIsNotFound = true
        default:
            mainPost = nil
            mainPostIndex = nil
            mainPostCount = nil
            mainItemIsBlocked = false
            blockedAnchorItem = nil
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

        rebuildRows()
    }

    private func loadHiddenReplies() {
        guard !isLoadingHiddenReplies, !hasLoadedHiddenReplies, let threadManager else { return }
        isLoadingHiddenReplies = true
        Task { @MainActor in
            await threadManager.loadHiddenReplies(uri: postURI)
            hasLoadedHiddenReplies = true
            isLoadingHiddenReplies = false
            rebuildRows()
        }
    }

    private func rebuildRows() {
        let serverItems = threadManager?.threadData?.thread ?? []
        let hiddenItems = (threadManager?.hiddenReplies ?? []).map {
            AppBskyUnspeccedGetPostThreadV2.ThreadItem(otherItem: $0)
        }
        var itemsByID: [String: AppBskyUnspeccedGetPostThreadV2.ThreadItem] = [:]
        for item in serverItems + hiddenItems where itemsByID[item.uri.uriString()] == nil {
            itemsByID[item.uri.uriString()] = item
        }
        threadItemsByID = itemsByID
        rows = ThreadRowBuilder.build(
            items: serverItems.map(ThreadRowBuilder.Item.init),
            otherItems: hiddenItems.map(ThreadRowBuilder.Item.init),
            mode: ThreadLayoutMode(threadedReplies: appState.appSettings.threadedReplies),
            maxIndentLevels: ThreadReplyGeometry.regularMaxIndentLevels,
            showsOtherRepliesPrompt: hasOtherReplies && !hasLoadedHiddenReplies
        )
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
