import NukeUI
import Petrel
import SwiftUI

struct ThreadViewMainPostView: View, Equatable {
    static func == (lhs: ThreadViewMainPostView, rhs: ThreadViewMainPostView) -> Bool {
        lhs.post.uri == rhs.post.uri && lhs.post.indexedAt == rhs.post.indexedAt && lhs.viewModel.isBookmarked == rhs.viewModel.isBookmarked
    }
    
    let post: AppBskyFeedDefs.PostView
    let showLine: Bool
    let appState: AppState
    @Binding var path: NavigationPath
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel: PostViewModel
    @State private var contextMenuViewModel: PostContextMenuViewModel
    @State private var currentUserDid: String?
    @State private var showingReportView = false
    @State private var showingAddToListSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showBlockConfirmation = false
    
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
        post: AppBskyFeedDefs.PostView, showLine: Bool, path: Binding<NavigationPath>,
        appState: AppState
    ) {
        self.post = post
        self.showLine = showLine
        self._path = path
        _viewModel = State(initialValue: PostViewModel(post: post, appState: appState))
        _contextMenuViewModel = State(initialValue: PostContextMenuViewModel(appState: appState, post: post))
        self.appState = appState
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
    }
    
    var body: some View {
        ContentLabelManager(labels: post.labels, selfLabelValues: extractSelfLabelValues(from: post), contentType: "post") {
            VStack(alignment: .leading, spacing: 0) {
                
                VStack(alignment: .leading, spacing: 0) {
                    if case let .knownType(postObj) = post.record {
                        if let feedPost = postObj as? AppBskyFeedPost {
                            HStack(alignment: .center, spacing: 0) {
                                authorAvatarColumn
                                
                                VStack(alignment: .leading, spacing: 0) {
                                    Text((post.author.displayName ?? post.author.handle.description).truncated(to: 30))
                                        .lineLimit(1, reservesSpace: true)
                                        .appHeadline()
                                        .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
                                        .truncationMode(.tail)
                                        .allowsTightening(true)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.bottom, 1)
                                        .transaction { $0.animation = nil }
                                        .contentTransition(.identity)
                                    
                                    Text("@\(post.author.handle)".truncated(to: 30))
                                        .appSubheadline()
                                        .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .allowsTightening(true)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.bottom, 1)
                                        .transaction { $0.animation = nil }
                                        .contentTransition(.identity)
                                    
                                }
                                .padding(.leading, 3)
                                .padding(.bottom, 4)
                                .onTapGesture {
                                    
                                    path.append(NavigationDestination.profile(post.author.did.didString()))
                                    
                                }
                                
                                Spacer()
                                
                                postEllipsisMenuView
                            }
                            
                            .frame(height: 60, alignment: .center)
                            .padding(.bottom, 3)
                            
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
                                    PostEmbed(embed: embed, labels: post.labels, path: $path)
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
                        }
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
            // Present the add to list sheet when showingAddToListSheet is true
            .sheet(isPresented: $showingAddToListSheet) {
                AddToListSheet(
                    userDID: post.author.did.didString(),
                    userHandle: post.author.handle.description,
                    userDisplayName: post.author.displayName
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
                Text("Block @\(post.author.handle)? You won't see each other's posts, and they won't be able to follow you.")
            }
            .task {
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
            
            Button(action: {
                Task { await contextMenuViewModel.muteThread() }
            }) {
                Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
            }
            
            // Use currentUserDid and post
            if let currentUserDid = currentUserDid,
               post.author.did.didString() == currentUserDid {
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
