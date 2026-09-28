import NukeUI
import Petrel
import SwiftUI

struct ThreadViewMainPostView: View, Equatable {
    static func == (lhs: ThreadViewMainPostView, rhs: ThreadViewMainPostView) -> Bool {
        lhs.post.uri == rhs.post.uri && lhs.post.indexedAt == rhs.post.indexedAt && lhs.viewModel.isBookmarked == rhs.viewModel.isBookmarked && lhs.opThreadPostIndex == rhs.opThreadPostIndex && lhs.opThreadPostCount == rhs.opThreadPostCount
    }
    
    let post: AppBskyFeedDefs.PostView
    let showLine: Bool
    let appState: AppState
    let visibilityContext: PostVisibilityContext
    @Binding var path: NavigationPath
    let opThreadPostIndex: Int?
    let opThreadPostCount: Int?
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel: PostViewModel
    @State private var contextMenuViewModel: PostContextMenuViewModel
    @State private var currentUserDid: String?
    @State private var showingReportView = false
    @State private var showingAddToListSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showBlockConfirmation = false
    @State private var showingInteractionSettings = false
    @State private var showingLabelsOnPost = false
    // Using multiples of 3 for spacing
    private static let baseUnit: CGFloat = 3
    private static let avatarSize: CGFloat = 48
    private static let avatarContainerWidth: CGFloat = 54
    
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium  // Shows month, day, year
        formatter.timeStyle = .short  // Shows hour and minute
        
        // If you specifically want the day of week included:
        formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"  // e.g. "Thursday, Feb 27, 2025 at 2:30 PM"
        
        return formatter
    }()
    
    init(
        post: AppBskyFeedDefs.PostView,
        showLine: Bool,
        path: Binding<NavigationPath>,
        appState: AppState,
        visibilityContext: PostVisibilityContext = .public,
        opThreadPostIndex: Int? = nil,
        opThreadPostCount: Int? = nil
    ) {
        self.post = post
        self.showLine = showLine
        self._path = path
        self.appState = appState
        self.visibilityContext = visibilityContext
        self.opThreadPostIndex = opThreadPostIndex
        self.opThreadPostCount = opThreadPostCount
        _viewModel = State(initialValue: PostViewModel(post: post, appState: appState, visibilityContext: visibilityContext))
        let actualRootURI: ATProtocolURI = {
            if case let .knownType(record) = post.record,
               let feedPost = record as? AppBskyFeedPost,
               let root = feedPost.reply?.root.uri {
                return root
            }
            return post.uri
        }()
        _contextMenuViewModel = State(
            initialValue: PostContextMenuViewModel(
                appState: appState,
                post: post,
                visibilityContext: visibilityContext,
                rootPostURI: actualRootURI,
                rootAuthorDID: actualRootURI.authority
            )
        )
    }
    
    private var authorAvatarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyImage(url: post.author.finalAvatarURL()) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: Self.avatarSize, height: Self.avatarSize)
                        .clipShape(Circle())
                        .contentShape(Circle())
                    //            .overlay(
                    //              Circle()
                    //                .inset(by: -1.5)
                    //                .stroke(colorScheme == .dark ? Color.black : Color.white, lineWidth: 3)
                    //            )
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Self.avatarSize, height: Self.avatarSize)
                        .foregroundColor(.gray)
                        .contentShape(Circle())
                }
            }
            .onTapGesture {
                path.append(NavigationDestination.profile(post.author.did.didString()))
            }
            
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: Self.avatarContainerWidth)
        .padding(.horizontal, ThreadViewMainPostView.baseUnit)
        // Keep this subtree free of ProfileEntity context. The enclosing
        // thread post is annotated as PostEntity, and iOS 27 can flatten a
        // nested profile DID into that post annotation during collection.
    }
    
    var body: some View {
        ContentLabelManager(labels: post.labels, selfLabelValues: extractSelfLabelValues(from: post), contentType: "post") {
            VStack(alignment: .leading, spacing: 0) {
                
                VStack(alignment: .leading, spacing: 0) {
                    if case let .knownType(postObj) = post.record,
                       let feedPost = postObj as? AppBskyFeedPost {
                            HStack(alignment: .center, spacing: 0) {
                                authorAvatarColumn
                                
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 4) {
                                        Text(post.author.displayName ?? post.author.handle.description)
                                            .lineLimit(1, reservesSpace: true)
                                            .truncationMode(.tail)
                                            .appHeadline()
                                            .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
                                            .allowsTightening(true)
                                            .transaction { $0.animation = nil }
                                            .contentTransition(.identity)

                                        if let badgeKind = VerificationBadge.kind(for: post.author.verification, did: post.author.did) {
                                            VerificationBadgeView(kind: badgeKind)
                                                .font(.caption)
                                        }
                                        
                                        if let pronouns = post.author.pronouns, !pronouns.isEmpty {
                                            Text("\(pronouns)")
                                                .appSubheadline()
                                                .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                                                .lineLimit(1)
                                                .opacity(0.9)
                                                .textScale(.secondary)
                                                .padding(1)
                                                .padding(.horizontal, 4)
                                                .padding(.bottom, 2)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .fill(Color.secondary.opacity(0.1))
                                                )

                                        }

                                    }
                                    .padding(.bottom, 1)

                                    HStack(spacing: 4) {
                                        Text(verbatim: "@\(post.author.handle)")
                                            .appSubheadline()
                                            .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .allowsTightening(true)

                                    }
                                    .padding(.bottom, 1)
                                    .transaction { $0.animation = nil }
                                    .contentTransition(.identity)
                                }                                .padding(.leading, 3)
                                .padding(.bottom, 4)
                                .onTapGesture {
                                    
                                    path.append(NavigationDestination.profile(post.author.did.didString()))
                                    
                                }
                                Spacer()
                                
                                if let opThreadPostIndex, let opThreadPostCount {
                                    ThreadPostNumberView(index: opThreadPostIndex, count: opThreadPostCount)
                                        .padding(.trailing, 8)
                                }
                                
                                postEllipsisMenuView
                            }
                            .frame(height: 60, alignment: .center)
                            .padding(.bottom, 3)

                            if case .circle(let circle) = visibilityContext {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.2.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text("Circle · \(circle.name)")
                                        .appSubheadline()
                                        .fontWeight(.medium)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.horizontal, 6)
                                .padding(.bottom, 4)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Circle: \(circle.name)")
                            }

                            if !feedPost.text.isEmpty {
                                // Reuse Post component to unify selectable text + translation
                                Post(
                                    post: feedPost,
                                    isSelectable: true,
                                    path: $path,
                                    textSize: 23,
                                    textStyle: .title3,
                                    textDesign: .default,
                                    textWeight: .regular,
                                    fontWidth: 100,
                                    lineSpacing: 1.2,
                                    letterSpacing: 0.2,
                                    useUIKitSelectableText: true
                                )
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                                .padding(.leading, 6)
                                .padding(.trailing, 6)
                                .transaction { txn in txn.animation = nil }
                                .contentTransition(.identity)
                            }
                            
                            //              if feedPost.text != "" {
                            //
                            //                  TappableTextView(
                            //                    attributedString: feedPost.facetsAsAttributedString, textSize: nil, textStyle: .title3
                            //                  )
                            //                  .lineLimit(nil)
                            //                  .fixedSize(horizontal: false, vertical: true)
                            //                  .padding(.vertical, 6)
                            //                  .padding(.leading, 6)
                            //                  .padding(.trailing, 6)
                            //              }
                            if let embed = post.embed {
                                    PostEmbed(
                                        embed: embed,
                                        labels: post.labels,
                                        path: $path,
                                        visibilityContext: visibilityContext,
                                        authorDID: post.author.did
                                    )
                                        .padding(.vertical, 6)
                                        .padding(.leading, 6)
                                        .padding(.trailing, 6)
                            }
                            Text(Self.dateTimeFormatter.string(from: feedPost.createdAt.date))
                                .appSubheadline()
                                .textScale(.secondary)
                                .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                                .padding(Self.baseUnit * 3)
                                .transaction { $0.animation = nil }
                                .contentTransition(.identity)
                    } else {
                        // Record failed typed decoding — show the tombstone
                        // instead of silently rendering an empty main post.
                        PostNotFoundView(uri: post.uri, reason: .parseError, path: $path)
                    }

                    PostStatsView(post: post, path: $path)
                        .padding(.top, Self.baseUnit * 3)
                        .padding(.horizontal, 6)
                    
                    ActionButtonsView(
                        post: post,
                        postViewModel: viewModel,
                        path: $path,
                        isBig: true
                    )
                    .padding(.leading, 15)
                    .padding(.trailing, 9)
                }
            }
            // Present the report form when showingReportView is true
            .sheet(isPresented: $showingReportView) {
                if case .circle(let circle) = visibilityContext {
                    CircleReportView(
                        post: post,
                        circle: circle
                    )
                } else if let client = appState.atProtoClient {
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
            // Present the add to list sheet when showingAddToListSheet is true
            .sheet(isPresented: $showingAddToListSheet) {
                AddToListSheet(
                    userDID: post.author.did.didString(),
                    userHandle: post.author.handle.description,
                    userDisplayName: post.author.displayName
                )
            }
            .sheet(isPresented: $showingInteractionSettings) {
                let actualRootURI: ATProtocolURI = {
                    if case let .knownType(record) = post.record,
                       let feedPost = record as? AppBskyFeedPost,
                       let root = feedPost.reply?.root.uri {
                        return root
                    }
                    return post.uri
                }()
                let isRootAuthor = (actualRootURI.authority ?? post.author.did.didString()) == appState.userDID

                PostInteractionSettingsView(
                    post: post,
                    rootPostURI: actualRootURI,
                    isRootAuthor: isRootAuthor
                )
            }
            .sheet(isPresented: $showingLabelsOnPost) {
                if let client = appState.atProtoClient {
                    let reportingService = ReportingService(client: client)
                    let handle = post.author.handle.description
                    LabelsOnMeView(
                        labels: allPostLabels,
                        targetDescription: "Post by @\(handle)",
                        viewerDID: appState.userDID,
                        reportingService: reportingService
                    )
                }
            }
            .alert("Delete Post", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    Task { await contextMenuViewModel.deletePost(visibilityContext: visibilityContext) }
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
                Text("Block @\(post.author.handle)? You won't see each other's posts, and they won't be able to follow you.")
            }
            .task(id: post) {
                await setupContextMenu()
            }
        }
        
    }
    
    /// Extract self-applied labels from record for visibility decisions
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
    // MARK: - Setup & Helpers

    /// Set up the context menu and its callbacks
    private func setupContextMenu() async {
        guard !Task.isCancelled else { return }
        if viewModel.postId != post.uri.uriString() || viewModel.postCid != post.cid {
            viewModel = PostViewModel(post: post, appState: appState, visibilityContext: visibilityContext)
        }
        await viewModel.start(post: post)
        guard !Task.isCancelled else { return }
        // Set up report callback
        contextMenuViewModel.onReportPost = {
            showingReportView = true
        }
        
        // Set up add to list callback
        contextMenuViewModel.onAddAuthorToList = {
            showingAddToListSheet = true
        }
        
        // Set up bookmark callback
        contextMenuViewModel.onToggleBookmark = {
            Task {
                do {
                    try await viewModel.toggleBookmark()
                } catch {
                    // Handle bookmark error if needed
                }
            }
        }
        
        // Fetch current user DID
        currentUserDid = appState.userDID
    }
    
    // MARK: - Helper Views
    
    // Post menu (three dots)
    private var postEllipsisMenuView: some View {
        Menu {
            // Only show "Add to List" for other users' posts
            if post.author.did.didString() != currentUserDid {
                Button(action: {
                    contextMenuViewModel.addAuthorToList()
                }) {
                    Label("Add Author to List", systemImage: "list.bullet.rectangle")
                }
                
                Divider()
            }
            
            // Bookmark button - available for all posts
            Button(action: {
                contextMenuViewModel.toggleBookmark()
            }) {
                Label(
                    viewModel.isBookmarked ? "Remove Bookmark" : "Bookmark",
                    systemImage: viewModel.isBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            
            Divider()
            
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
            
            if case .public = visibilityContext {
                Button(action: {
                    Task { await contextMenuViewModel.muteThread() }
                }) {
                    Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
                }
            }
            
            // Use currentUserDid and post
            if post.author.did.didString() != currentUserDid {
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
                            contextMenuViewModel.isReplyHiddenByThreadgate ? "Show reply for everyone" : "Hide reply for everyone",
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
                            contextMenuViewModel.isQuoteDetached ? "Re-attach quote" : "Detach quote",
                            systemImage: contextMenuViewModel.isQuoteDetached ? "link" : "arrow.branch"
                        )
                    }
                }
            }

            if let currentUserDid = currentUserDid,
               post.author.did.didString() == currentUserDid {
                Button(action: {
                    Task { await contextMenuViewModel.togglePin() }
                }) {
                    if contextMenuViewModel.isPinned {
                        Label("Unpin from profile", systemImage: "pin.slash")
                    } else {
                        Label("Pin to your profile", systemImage: "pin")
                    }
                }

                Button(action: {
                    showingInteractionSettings = true
                }) {
                    Label("Edit interaction settings", systemImage: "slider.horizontal.3")
                }

                Button(action: {
                    showingLabelsOnPost = true
                }) {
                    Label("Labels applied to this post", systemImage: "tag")
                }
                Button(role: .destructive, action: {
                    showDeleteConfirmation = true
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
                .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
                .padding(Self.baseUnit * 3)
                .contentShape(Rectangle())
                .accessibilityLabel("Post Options")
                .accessibilityAddTraits(.isButton)
            
        }
    }

    private var allPostLabels: [ComAtprotoLabelDefs.Label] {
        var combined: [ComAtprotoLabelDefs.Label] = []
        if let postLabels = post.labels {
            combined.append(contentsOf: postLabels)
        }
        if let authorLabels = post.author.labels {
            combined.append(contentsOf: authorLabels)
        }
        return combined
    }

}
/// Truncates the string to a specified maximum length, appending a trailing indicator if needed.
extension String {
    func truncated(to length: Int, trailing: String = "...") -> String {
        // If the string exceeds the max length, return a substring with trailing text
        if self.count > length {
            return self.prefix(length) + trailing
        } else {
            return self
        }
    }
}

#Preview("ThreadViewMainPostView") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPostView(from: appState)
  } content: { appState, postView in
    ScrollView {
      ThreadViewMainPostView(
        post: postView,
        showLine: false,
        path: .constant(NavigationPath()),
        appState: appState
      )
    }
  }
}
