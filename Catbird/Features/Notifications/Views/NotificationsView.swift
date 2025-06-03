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
  @State private var selectedFilter: NotificationsViewModel.NotificationFilter = .all

  private let logger = Logger(subsystem: "blue.catbird", category: "NotificationsView")

  init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
    _viewModel = State(wrappedValue: NotificationsViewModel(client: appState.atProtoClient))
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
  }

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    NavigationStack(path: navigationPath) {
      notificationContentWithHeader
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
          
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            Task {
              await viewModel.refreshNotifications()
            }
          }) {
            Image(systemName: "arrow.clockwise")
                  .imageScale(.medium)
          }
        }
      }
      .navigationDestination(for: NavigationDestination.self) { destination in
        destinationView(for: destination)
      }
    }
    .onChange(of: lastTappedTab) { _, newValue in
      if newValue == 2, selectedTab == 2 {
        Task {
          await viewModel.refreshNotifications()
        }
        lastTappedTab = nil
      }
    }
    .onChange(of: selectedTab) { oldValue, newValue in
      if newValue == 2 && oldValue != 2 {
        Task {
          await viewModel.refreshNotifications()
          try? await viewModel.markNotificationsAsSeen()
        }
      }
    }
    .onChange(of: selectedFilter) { _, newFilter in
      Task {
        await viewModel.setFilter(newFilter)
      }
    }.task {
      if viewModel.groupedNotifications.isEmpty {
        await viewModel.loadNotifications()
      }

      // Force widget update when notifications view appears
      appState.notificationManager.updateWidgetUnreadCount(appState.notificationManager.unreadCount)
    }
    // Check scene phase changes
    .onChange(of: UIApplication.shared.applicationState) { _, newState in
      if newState == .active {
          // App became active, update widget
        appState.notificationManager.updateWidgetUnreadCount(
          appState.notificationManager.unreadCount)
      }
    }
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $selectedFilter) {
      Text("All").tag(NotificationsViewModel.NotificationFilter.all)
      Text("Mentions").tag(NotificationsViewModel.NotificationFilter.mentions)
    }
    .pickerStyle(.segmented)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var notificationContentWithHeader: some View {
    if let error = viewModel.error {
      VStack(spacing: DesignTokens.Spacing.none) {
        filterPicker
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        
        ErrorStateView(
          error: error,
          context: "Failed to load notifications",
          retryAction: { Task { await retryLoadNotifications() } }
        )
      }
    } else if viewModel.isLoading && viewModel.groupedNotifications.isEmpty {
      VStack(spacing: DesignTokens.Spacing.none) {
        filterPicker
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        
        loadingView
      }
    } else if viewModel.groupedNotifications.isEmpty {
      VStack(spacing: DesignTokens.Spacing.none) {
        filterPicker
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        
        emptyView
      }
    } else {
      notificationsListWithHeader
    }
  }

  @ViewBuilder
  private var notificationContent: some View {
    if let error = viewModel.error {
      ErrorStateView(
        error: error,
        context: "Failed to load notifications",
        retryAction: { Task { await retryLoadNotifications() } }
      )
    } else if viewModel.isLoading && viewModel.groupedNotifications.isEmpty {
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
    VStack(spacing: DesignTokens.Spacing.xl) {
      Image(systemName: "bell.slash")
        .appFont(size: 48)
        .foregroundColor(.secondary)

      Text("No Notifications")
        .enhancedAppHeadline()
        .fontWeight(.semibold)

      Text("You don't have any notifications yet")
        .enhancedAppSubheadline()
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
  private var notificationsListWithHeader: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    ScrollViewReader { _ in
      List {
        // Filter picker as the first list item
        filterPicker
          .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
          .listRowSeparator(.hidden)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)

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
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
          .onAppear {
            let index =
              viewModel.groupedNotifications.firstIndex(where: { $0.id == group.id }) ?? 0
            let thresholdIndex = max(0, viewModel.groupedNotifications.count - 5)

            if index >= thresholdIndex && viewModel.hasMoreNotifications
              && !viewModel.isLoadingMore {
              Task {
                await viewModel.loadMoreNotifications()
              }
            }
          }
        }

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
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
      .scrollPosition($scrollPosition)
    }
    .refreshable {
      try? await viewModel.markNotificationsAsSeen()
      await viewModel.refreshNotifications()
    }
  }

  @ViewBuilder
  private var notificationsList: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    ScrollViewReader { _ in
      List {
//          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
//          .listRowSeparator(.hidden)
//          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)

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
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
          .onAppear {
            let index =
              viewModel.groupedNotifications.firstIndex(where: { $0.id == group.id }) ?? 0
            let thresholdIndex = max(0, viewModel.groupedNotifications.count - 5)

            if index >= thresholdIndex && viewModel.hasMoreNotifications
              && !viewModel.isLoadingMore {
              Task {
                await viewModel.loadMoreNotifications()
              }
            }
          }
        }

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
      .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
      .scrollPosition($scrollPosition)
      //      .overlay(alignment: .top) {
      //        if viewModel.isRefreshing {
      //          ProgressView()
      //            .progressViewStyle(.linear)
      //            .transition(.move(edge: .top))
      //        }
      //      }
    }
    .refreshable {
      try? await viewModel.markNotificationsAsSeen()
      await viewModel.refreshNotifications()
    }
  }

  @ViewBuilder
  private func destinationView(for destination: NavigationDestination) -> some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    NavigationHandler.viewForDestination(
      destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
  }
  
  private func retryLoadNotifications() async {
    viewModel.clearError()
    if viewModel.groupedNotifications.isEmpty {
      await viewModel.loadNotifications()
    } else {
      await viewModel.refreshNotifications()
    }
  }
}

// MARK: - Notification Card

struct NotificationCard: View {
  let group: GroupedNotification
  let onTap: (NavigationDestination) -> Void
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState: AppState

  @State private var isFollowExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        if group.type == .follow {
          if group.notifications.count > 1 {
            isFollowExpanded.toggle()
          } else {
            if let follower = group.notifications.first {
              onTap(NavigationDestination.profile(follower.author.did.didString()))
            }
          }
        } else {
          handleTap()
        }
      } label: {
        if group.type == .reply || group.type == .quote || group.type == .mention,
          let post = group.subjectPost {
          replyOrQuoteNotificationView(post: post)
        } else {
          standardNotificationView
        }
      }
      .buttonStyle(.plain)

      if group.type == .follow && isFollowExpanded {
        expandedFollowersList
      }
    }
    .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
    .animation(.none, value: isFollowExpanded)
    .frame(maxWidth: 600, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(
      group.hasUnreadNotifications ? Color.accentColor.opacity(0.2) : Color.clear
    )
  }

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
          HStack(spacing: DesignTokens.Spacing.base) {
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
                .appSubheadline()
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary.opacity(0.6))
          }
          .spacingBase(.horizontal)
          .spacingMD(.vertical)
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

  private var standardNotificationView: some View {
    HStack(alignment: .top, spacing: 12) {
      NotificationIcon(type: group.type)
        .frame(width: 50, alignment: .trailing)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center) {
          if group.type == .follow && group.notifications.count > 1 {
            HStack(spacing: 3) {
              AvatarStack(notifications: group.notifications)

              Image(
                systemName: isFollowExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill"
              )
              .foregroundStyle(Color.secondary)
              .appFont(size: 18)
              .padding(.leading, 5)
            }
          } else {
            AvatarStack(notifications: group.notifications)
          }

          Spacer()
          Text(formatTimeAgo(from: group.latestNotification.indexedAt.date))
            .appSubheadline()
            .foregroundColor(.secondary)
            .accessibilityLabel(formatTimeAgo(from: group.latestNotification.indexedAt.date, forAccessibility: true))

        }

        Text(notificationText)
          .appBody()
          .foregroundColor(.primary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)

        if shouldShowPostPreview {
          postPreview
            .padding(.top, 4)
        }
      }
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  private var notificationText: AttributedString {
    let count = group.notifications.count
    let firstAuthor = group.notifications.first?.author

    let authorDisplayName: String
    if let displayName = firstAuthor?.displayName, !displayName.isEmpty {
      authorDisplayName = displayName
    } else if let handle = firstAuthor?.handle {
      authorDisplayName = "@" + handle.description
    } else {
      authorDisplayName = "Someone"
    }

    var attributedText = AttributedString()
    attributedText.font = Font.body
    var authorPart = AttributedString(authorDisplayName)
    authorPart.font = Font.body.bold()

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
        !feedPost.text.isEmpty {
        Text(feedPost.text)
          .appBody()
          .foregroundColor(.secondary)
          .lineLimit(nil)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let embed = post.embed {
        switch embed {
        case .appBskyEmbedImagesView(let images):
          Text(images.images.map { $0.thumb.uriString() }.joined(separator: ", "))
            .appBody()
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .appBskyEmbedVideoView(let video):
          Text(video.playlist.uriString())
            .appBody()
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .appBskyEmbedExternalView(let external):
          Text(external.external.uri.uriString())
            .appBody()
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .appBskyEmbedRecordView(let record):
          switch record.record {
          case .appBskyEmbedRecordViewRecord(let viewRecord):
            if case let .knownType(recordPost) = viewRecord.value,
              let post = recordPost as? AppBskyFeedPost {
              Text(post.text)
                .appBody()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .appBody()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

          default: EmptyView()
          }
        case .unexpected:
          EmptyView()
        }
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
      break
    case .reply, .quote, .mention:
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
      .appFont(size: 28)
      .frame(width: 44, height: 44, alignment: .trailing)
  }
}

struct AvatarStack: View {
  let notifications: [AppBskyNotificationListNotifications.Notification]
  @Environment(AppState.self) private var appState: AppState

  var body: some View {
    let navigationPath = appState.navigationManager.pathBinding(for: 2)

    HStack(spacing: 3) {
      ForEach(0..<min(3, notifications.count), id: \.self) { index in
        LazyImage(url: notifications[index].author.finalAvatarURL()) { state in
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
//        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
      }

      if notifications.count > 3 {
        Text("+\(notifications.count - 3)")
          .appFont(.customSystemFont(size: 16, weight: .medium, width: 60, relativeTo: .caption))
          .textScale(.secondary)
          .frame(width: 44, height: 44)
          .background(Color(.systemGray6).opacity(0.7))
          .clipShape(Circle())
//          .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
      }
    }
    .offset(x: -3)
  }
}

// MARK: - Preview

#Preview {
  NotificationsView(
    appState: AppState.shared,
    selectedTab: .constant(2),
    lastTappedTab: .constant(nil)
  )
}
