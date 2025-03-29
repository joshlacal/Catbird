import SwiftUI
import Petrel
import NukeUI
import OSLog

struct NotificationsView: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var viewModel: NotificationsViewModel
    @Binding var selectedTab: Int
    @Binding var lastTappedTab: Int?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "NotificationsView")
    
    init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
        _viewModel = State(wrappedValue: NotificationsViewModel(client: appState.atProtoClient))
        self._selectedTab = selectedTab
        self._lastTappedTab = lastTappedTab
    }
    
    var body: some View {
        let navigationPath = appState.navigationManager.pathBinding(for: 2)
        
        NavigationStack(path: navigationPath) {
            notificationContent
                .navigationTitle("Notifications")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: NavigationDestination.self) { destination in
                    destinationView(for: destination)
                }
        }
        .onChange(of: lastTappedTab) { _, newValue in
            if newValue == 2, selectedTab == 2 {
                // Scroll to top or refresh when notification tab is double-tapped
                Task {
                    await viewModel.refreshNotifications()
                }
                lastTappedTab = nil
            }
        }
        .task {
            await viewModel.loadNotifications()
        }
    }
    
    @ViewBuilder
    private var notificationContent: some View {
        if viewModel.isLoading && viewModel.groupedNotifications.isEmpty {
            loadingView
        } else if viewModel.groupedNotifications.isEmpty {
            emptyView
        } else {
            notificationsList
        }
    }
    
    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading notifications...")
                .foregroundColor(.secondary)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Notifications")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("You don't have any notifications yet")
                .foregroundColor(.secondary)
            
            Button(action: {
                Task {
                    await viewModel.refreshNotifications()
                }
            }) {
                Text("Refresh")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var notificationsList: some View {
        let navigationPath = appState.navigationManager.pathBinding(for: 2)
        
        ScrollViewReader { scrollProxy in
            List {
                ForEach(viewModel.groupedNotifications, id: \.id) { group in
                    NotificationCard(group: group, onTap: { destination in
                        navigationPath.wrappedValue.append(destination)
                    }, path: navigationPath)
                    .padding(.leading, 16)
                    .id(group.id)
                    .listRowSeparator(.visible)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in
                        0
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 16))
                    // Add infinite scroll trigger for the last few items
                    .onAppear {
                        // Check if this is one of the last few items
                        let index = viewModel.groupedNotifications.firstIndex(where: { $0.id == group.id }) ?? 0
                        let thresholdIndex = max(0, viewModel.groupedNotifications.count - 5)
                        
                        if index >= thresholdIndex && viewModel.hasMoreNotifications && !viewModel.isLoadingMore {
                            Task {
                                await viewModel.loadMoreNotifications()
                            }
                        }
                    }
                }
                
                // Loading indicator at bottom of list
                if viewModel.hasMoreNotifications {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                    .id("loadingIndicator")
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.refreshNotifications()
                
                // Mark notifications as read
                try? await viewModel.markNotificationsAsSeen()
            }
            .overlay(alignment: .top) {
                if viewModel.isRefreshing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .transition(.move(edge: .top))
                }
            }
        }
    }
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        // Add this line to properly define navigationPath
        let navigationPath = appState.navigationManager.pathBinding(for: 2)
        
        NavigationHandler.viewForDestination(destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
    }
}

// MARK: - Notification Card

struct NotificationCard: View {
    let group: GroupedNotification
    let onTap: (NavigationDestination) -> Void
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState: AppState
    
    // Track expanded state for follow notifications
    @State private var isFollowExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            Button {
                if group.type == .follow {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isFollowExpanded.toggle()
                    }
                } else {
                    handleTap()
                }
            } label: {
                // For replies and quotes, simply show PostView with minimal header
                if group.type == .reply || group.type == .quote, let post = group.subjectPost {
                    replyOrQuoteNotificationView(post: post)
                } else {
                    // For all other notification types (like, repost, follow, mention)
                    standardNotificationView
                }
            }
            .buttonStyle(.plain)
            
            // Expanded followers list (conditionally shown)
            if group.type == .follow && isFollowExpanded {
                expandedFollowersList
            }
        }
    }
    
    // Expanded view for followers
    private var expandedFollowersList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.horizontal)
            
            ForEach(group.notifications, id: \.cid) { notification in
                Button {
                    onTap(NavigationDestination.profile(notification.author.did.didString()))
                } label: {
                    HStack(spacing: 12) {
                        // Follower avatar
                        LazyImage(url: URL(string: notification.author.avatar?.uriString() ?? "")) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.gray
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        
                        // Follower info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.author.displayName ?? notification.author.handle.description)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Text("@\(notification.author.handle)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Optional: Add a follow button here
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if notification.cid != group.notifications.last?.cid {
                    Divider()
                        .padding(.leading, 60)
                }
            }
        }
        .background(Color(.systemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    
    // Special layout for replies and quotes - directly showing PostView with a minimal header
    private func replyOrQuoteNotificationView(post: AppBskyFeedDefs.PostView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Notification type and time
            HStack {
                NotificationIcon(type: group.type)
                
                // Author info from the notification
                let author = group.notifications.first?.author
                Text(author?.displayName ?? author?.handle.description ?? "Someone")
                    .fontWeight(.semibold)
                
                Text(group.type == .reply ? "replied to your post" : "quoted your post")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Time
                Text(formatTimeAgo(from: group.latestNotification.indexedAt.date))
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            // Show the PostView directly
            PostView(
                post: post,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: false,
                path: $path,
                appState: appState
            )
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    // Standard notification view for likes, reposts, follows, and mentions
    private var standardNotificationView: some View {
        HStack(alignment: .top, spacing: 12) {
            // Notification type icon
            NotificationIcon(type: group.type)
            
            VStack(alignment: .leading, spacing: 8) {
                // Header with avatars and time
                HStack(alignment: .center) {
                    AvatarStack(notifications: group.notifications)
                    Spacer()
                    Text(formatTimeAgo(from: group.latestNotification.indexedAt.date))
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                
                // Notification text
                Text(notificationText)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                
                // Post preview for applicable notification types (except replies and quotes)
                if shouldShowPostPreview {
                    postPreview
                }
                
                // Indicator for follow notifications that they can be expanded
                if group.type == .follow && group.notifications.count > 1 {
                    HStack {
                        Spacer()
                        Text(isFollowExpanded ? "Tap to collapse" : "Tap to see all followers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    // Notification text based on type and number of users
    private var notificationText: String {
        let count = group.notifications.count
        let firstAuthor = group.notifications.first?.author
        let authorName = firstAuthor?.displayName ?? firstAuthor?.handle.description ?? "Someone"
        
        switch (group.type, count) {
        case (.like, 1):
            return "\(authorName) liked your post"
        case (.like, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") liked your post"
        case (.repost, 1):
            return "\(authorName) reposted your post"
        case (.repost, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") reposted your post"
        case (.follow, 1):
            return "\(authorName) followed you"
        case (.follow, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") followed you"
        case (.mention, 1):
            return "\(authorName) mentioned you"
        case (.mention, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") mentioned you"
        case (.reply, 1):
            return "\(authorName) replied to your post"
        case (.reply, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") replied to your post"
        case (.quote, 1):
            return "\(authorName) quoted your post"
        case (.quote, _):
            return "\(authorName) and \(count - 1) other\(count > 2 ? "s" : "") quoted your post"
        }
    }
    
    // Determine if we should show post preview
    private var shouldShowPostPreview: Bool {
        switch group.type {
        case .like, .mention:
            return group.subjectPost != nil
        case .reply, .quote, .repost, .follow:
            return false
        }
    }
    
    // Post content preview (for likes and mentions only)
    @ViewBuilder
    private var postPreview: some View {
        if let post = group.subjectPost {
            VStack(alignment: .leading, spacing: 4) {
                if case .knownType(let postObj) = post.record,
                   let feedPost = postObj as? AppBskyFeedPost {
                    Text(feedPost.text)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .cornerRadius(8)
        }
    }
    
    // Handle taps on notifications
    private func handleTap() {
        switch group.type {
        case .like, .repost, .mention:
            if let post = group.subjectPost {
                onTap(NavigationDestination.post(post.uri))
            } else if let reasonSubject = group.notifications.first?.reasonSubject {
                onTap(NavigationDestination.post(reasonSubject))
            }
        case .follow:
            // Follow tap is now handled in the button action to toggle expansion
            break
        case .reply, .quote:
            if let post = group.subjectPost {
                onTap(NavigationDestination.post(post.uri))
            } else if let uri = group.notifications.first?.uri {
                onTap(NavigationDestination.post(uri))
            }
        }
    }
}

// MARK: - Supporting Views

struct NotificationIcon: View {
    let type: NotificationType
    
    var body: some View {
        Image(systemName: type.icon)
            .foregroundColor(type.color)
            .font(.system(size: 16))
            .frame(width: 32, height: 32)
            .background(type.color.opacity(0.1))
            .clipShape(Circle())
    }
}

struct AvatarStack: View {
    let notifications: [AppBskyNotificationListNotifications.Notification]
    
    var body: some View {
        HStack(spacing: -8) {
            ForEach(0..<min(3, notifications.count), id: \.self) { index in
                LazyImage(url: URL(string: notifications[index].author.avatar?.uriString() ?? "")) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            
            if notifications.count > 3 {
                Text("+\(notifications.count - 3)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NotificationsView(
        appState: AppState(),
        selectedTab: .constant(2),
        lastTappedTab: .constant(nil)
    )
}
