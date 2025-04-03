import NukeUI
import OSLog
import Petrel
import SwiftUI

struct NotificationsView: View {
  @Environment(AppState.self) private var appState: AppState
  @State private var viewModel: NotificationsViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var currentUser: AppBskyActorDefs.ProfileViewBasic?
  @State private var scrollPosition: ScrollPosition = ScrollPosition(idType: String.self)
  @SceneStorage("notifications-scroll-position") private var savedScrollPositionId: String?

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
        .navigationBarTitleDisplayMode(.large)
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
    .onChange(of: selectedTab) { oldValue, newValue in
      // When switching to the notifications tab, refresh and mark as seen
      if newValue == 2 && oldValue != 2 {
        Task {
          await viewModel.refreshNotifications()
          try? await viewModel.markNotificationsAsSeen()
        }
      }

      // When coming back to this tab, restore position
      // if oldValue != 2 && newValue == 2,
      //   let savedId = savedScrollPositionId,
      //   viewModel.groupedNotifications.contains(where: { $0.id == savedId })
      // {
      //   // Delay slightly to ensure view is loaded
      //   DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      //     scrollPosition.scrollTo(savedId)
      //   }
      // }
    }
    .task {
      if viewModel.groupedNotifications.isEmpty {
        await viewModel.loadNotifications()
      }
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
          NotificationCard(
            group: group,
            onTap: { destination in
              navigationPath.wrappedValue.append(destination)
            }, path: navigationPath
          )
          .id(group.id)
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          .listRowSeparator(.visible)
          .alignmentGuide(.listRowSeparatorLeading) { _ in
            0
          }
          // Add infinite scroll trigger for the last few items
          .onAppear {
            // Check if this is one of the last few items
            let index =
              viewModel.groupedNotifications.firstIndex(where: { $0.id == group.id }) ?? 0
            let thresholdIndex = max(0, viewModel.groupedNotifications.count - 5)

            if index >= thresholdIndex && viewModel.hasMoreNotifications
              && !viewModel.isLoadingMore
            {
              Task {
                await viewModel.loadMoreNotifications()
              }
            }
          }

          //            Divider()

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
      .scrollPosition($scrollPosition)
      .overlay(alignment: .top) {
        if viewModel.isRefreshing {
          ProgressView()
            .progressViewStyle(.linear)
            .transition(.move(edge: .top))
        }
      }
    }
    .refreshable {
      await viewModel.refreshNotifications()

      // Mark notifications as read
      try? await viewModel.markNotificationsAsSeen()
    }

  }

  @ViewBuilder
  private func destinationView(for destination: NavigationDestination) -> some View {
    // Add this line to properly define navigationPath
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    NavigationHandler.viewForDestination(
      destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
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
    VStack(alignment: .leading, spacing: 0) {  // Ensure leading alignment for consistency
      Button {
        if group.type == .follow {
          if group.notifications.count > 1 {
            // Multiple followers - keep the expandable behavior
            isFollowExpanded.toggle()
          } else {
            // Single follower - navigate directly to their profile
            if let follower = group.notifications.first {
              onTap(NavigationDestination.profile(follower.author.did.didString()))
            }
          }
        } else {
          handleTap()
        }
      } label: {
        // For replies, quotes, and mentions, simply show PostView with minimal header
        if group.type == .reply || group.type == .quote || group.type == .mention,
          let post = group.subjectPost
        {
          replyOrQuoteNotificationView(post: post)
          //                .padding(.leading, 16)

          //            .padding(.bottom, 6)  // Add some padding below post view if needed
        } else {
          // For all other notification types (like, repost, follow)
          standardNotificationView
        }
      }
      .buttonStyle(.plain)  // Ensure button style doesn't interfere

      // Expanded followers list (conditionally shown)
      // Use an `if` statement directly within the VStack
      if group.type == .follow && isFollowExpanded {
        expandedFollowersList
        // REMOVED the explicit transition here:
        // .transition(.move(edge: .top))
        // Let withAnimation handle the appearance/disappearance implicitly
      }
    }
    .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
    .animation(.none, value: isFollowExpanded)  // Try disabling animations here
    // Ensure the card itself doesn't have extra padding causing shifts
    .background(
      // Highlight unread notifications with a subtle background color that extends edge to edge
      group.hasUnreadNotifications ? Color.accentColor.opacity(0.2) : Color.clear
    )
  }

  // Expanded view for followers (Restoring original content)
  private var expandedFollowersList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Rectangle()
        .frame(height: 1)
        .foregroundColor(Color(.systemGray5))
        .padding(.horizontal)
        .padding(.top, 8)

      ForEach(group.notifications, id: \.cid) { notification in
        Button {
          onTap(NavigationDestination.profile(notification.author.did.didString()))
        } label: {
          HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 2) {
              Text(notification.author.displayName ?? notification.author.handle.description)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

              Text("@\(notification.author.handle)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundColor(.secondary.opacity(0.6))
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())

        if notification.cid != group.notifications.last?.cid {
          Divider()
            .padding(.leading, 36 + 12)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  private func replyOrQuoteNotificationView(post: AppBskyFeedDefs.PostView) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PostView(
        post: post,
        grandparentAuthor: nil,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState,
        isToYou: group.type == .reply
      )
    }
    .padding(.top, 6)
    .contentShape(Rectangle())
  }

  // Standard notification view for likes, reposts, and follows
  private var standardNotificationView: some View {
    // No major changes needed here, ensure padding is correct
    HStack(alignment: .top, spacing: 12) {
      // Notification type icon
      NotificationIcon(type: group.type)
        .frame(width: 50, alignment: .trailing)  // Ensure consistent size

      VStack(alignment: .leading, spacing: 4) {  // Reduced spacing slightly maybe
        // Header with avatars and time
        HStack(alignment: .center) {
          // Avatar stack logic remains the same
          if group.type == .follow && group.notifications.count > 1 {
            HStack(spacing: 3) {
              AvatarStack(notifications: group.notifications)

              // Chevron indicator - ensure it aligns well
              Image(
                systemName: isFollowExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill"
              )
              .foregroundStyle(Color.secondary)  // Use secondary color
              .font(.system(size: 18))
              .padding(.leading, 5)  // Add some space from avatars
            }
          } else {
            AvatarStack(notifications: group.notifications)
          }

          Spacer()
          Text(formatTimeAgo(from: group.latestNotification.indexedAt.date))
            .font(.subheadline)  // Maybe slightly smaller font for time
            .foregroundColor(.secondary)
        }

        // Notification text
        Text(notificationText)
          .font(.body)  // Consistent font size
          .foregroundColor(.primary)
          .lineLimit(nil)  // Allow text wrapping
          .fixedSize(horizontal: false, vertical: true)  // Ensure it takes needed vertical space
          .padding(.top, 4)  // Add slight space above text

        // Post preview for applicable notification types
        if shouldShowPostPreview {
          postPreview
            .padding(.top, 4)  // Add space above preview
        }
      }
    }
    .padding(.vertical, 12)  // Increase vertical padding for better spacing but contained within the background
    .contentShape(Rectangle())
  }

  // Notification text based on type and number of users
  private var notificationText: AttributedString {
    let count = group.notifications.count
    let firstAuthor = group.notifications.first?.author

    // More robust author name extraction
    let authorDisplayName: String
    if let displayName = firstAuthor?.displayName, !displayName.isEmpty {
      authorDisplayName = displayName
    } else if let handle = firstAuthor?.handle {
      // Ensure we properly convert the handle to a string
      authorDisplayName = "@" + handle.description
    } else {
      authorDisplayName = "Someone"
    }

    var attributedText = AttributedString()
    var authorPart = AttributedString(authorDisplayName)

    // Apply bold formatting to the author name
    authorPart.font = .boldSystemFont(ofSize: UIFont.labelFontSize)

    // Append the author name and the appropriate text based on notification type
    attributedText.append(authorPart)

    switch (group.type, count) {
    case (.like, 1):
      attributedText.append(AttributedString(" liked your post"))
    case (.like, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") liked your post"))
    case (.repost, 1):
      attributedText.append(AttributedString(" reposted your post"))
    case (.repost, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") reposted your post"))
    case (.follow, 1):
      attributedText.append(AttributedString(" followed you"))
    case (.follow, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") followed you"))
    case (.mention, 1):
      attributedText.append(AttributedString(" mentioned you in a post"))
    case (.mention, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") mentioned you"))
    case (.reply, 1):
      attributedText.append(AttributedString(" replied to your post"))
    case (.reply, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") replied"))
    case (.quote, 1):
      attributedText.append(AttributedString(" quoted your post"))
    case (.quote, _):
      attributedText.append(
        AttributedString(" and \(count - 1) other\(count > 2 ? "s" : "") quoted"))
    }

    return attributedText
  }

  private var shouldShowPostPreview: Bool {
    switch group.type {
    case .like, .repost: return group.subjectPost != nil
    default: return false
    }
  }

  @ViewBuilder
  private var postPreview: some View {
    if let post = group.subjectPost {
      if case .knownType(let postObj) = post.record, let feedPost = postObj as? AppBskyFeedPost,
        !feedPost.text.isEmpty
      {
        Text(feedPost.text)
          .font(.body)  // Smaller font for preview
          .foregroundColor(.secondary)
          .lineLimit(nil)
          .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width
      } else if let embed = post.embed {
          switch embed {
          case .appBskyEmbedImagesView(let images):
              Text(images.images.map { $0.thumb.uriString() }.joined(separator: ", "))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width

          case .appBskyEmbedVideoView(let video):
              Text(video.playlist.uriString())
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width

          case .appBskyEmbedExternalView(let external):
              Text(external.external.uri.uriString())
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width

          case .appBskyEmbedRecordView(let record):
              switch record.record {
              case .appBskyEmbedRecordViewRecord(let viewRecord):
                  if case let .knownType(recordPost) = viewRecord.value,
                     let post = recordPost as? AppBskyFeedPost {
                      Text(post.text)
                          .font(.body)
                          .foregroundColor(.secondary)
                          .lineLimit(1)
                          .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width

                  }
                  
              default:
                  EmptyView()
              }
                  
          case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
              switch recordWithMedia.record.record {
              case .appBskyEmbedRecordViewRecord(let viewRecord):
                  if case let .knownType(recordPost) = viewRecord.value,
                     let post = recordPost as? AppBskyFeedPost {
                      Text(post.text)
                          .font(.body)
                          .foregroundColor(.secondary)
                          .lineLimit(1)
                          .frame(maxWidth: .infinity, alignment: .leading)  // Ensure it takes width

                  }
              
              default: EmptyView()
              }
          case .unexpected(_):
              EmptyView()
            

          }
          // TODO: images?
//        PostEmbed(embed: embed, labels: post.labels, path: $path)
//          .frame(maxHeight: 50)
      } else {
        EmptyView()
      }
    }
  }

  private func handleTap() {
    switch group.type {
    case .like, .repost:
      if let post = group.subjectPost {
        onTap(NavigationDestination.post(post.uri))
      } else if let reasonSubject = group.notifications.first?.reasonSubject {
        onTap(NavigationDestination.post(reasonSubject))
      }
    case .follow:
      // For single followers, we already handle this in the Button action
      // This case is only reached for multiple followers
      break
    case .reply, .quote, .mention:
      // Tapping the PostView itself handles navigation now
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
      .font(.system(size: 28, weight: .medium))
      .frame(width: 44, height: 44, alignment: .trailing)
    //      .background(type.color.opacity(0.1))
    //      .clipShape(Circle())
  }
}

struct AvatarStack: View {
  let notifications: [AppBskyNotificationListNotifications.Notification]
  @Environment(AppState.self) private var appState: AppState

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    HStack(spacing: 3) {
      ForEach(0..<min(3, notifications.count), id: \.self) { index in
        LazyImage(url: URL(string: notifications[index].author.avatar?.uriString() ?? "")) {
          state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .aspectRatio(contentMode: .fill)

          }
        }
        .onTapGesture {
          navigationPath.wrappedValue.append(
            NavigationDestination.profile(notifications[index].author.did.didString())
          )
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
      }

      if notifications.count > 3 {
        Text("+\(notifications.count - 3)")
              .font(.customSystemFont(size: 16, weight: .medium, width: -0.1, relativeTo: .caption))
          .textScale(.secondary)
          .frame(width: 44, height: 44)
          .background(Color(.systemGray6).opacity(0.5))
          .clipShape(Circle())
          .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
      }
    }
    .offset(x: -3)
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
