import Nuke
import NukeUI
import OSLog
import Petrel
import SwiftUI

struct NotificationsView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState: AppState
  @Environment(\.horizontalSizeClass) private var hSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @State private var viewModel: NotificationsViewModel
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var scrollPosition: ScrollPosition = ScrollPosition(idType: String.self)
  @SceneStorage("notifications-scroll-position") private var savedScrollPositionId: String?
  @State private var selectedFilter: NotificationsViewModel.NotificationFilter = .all
  @State private var lastLoadMoreTriggerTime: TimeInterval = .zero
  @State private var showingSettings = false
  @State private var circleRefresh = NotificationSupplementRefresh()
  private let loadMoreTriggerDedupInterval: TimeInterval = 0.35
  @State private var openIntervalState: OSSignpostIntervalState?
  @State private var wasBackgrounded = false

  private let logger = Logger(subsystem: "blue.catbird", category: "NotificationsView")

  init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _viewModel = State(wrappedValue: NotificationsViewModel(
      client: appState.atProtoClient,
      notificationManager: appState.notificationManager,
      moderationPolicy: appState.moderationPolicy
    ))
  }

  var body: some View {
    let navigationPathBinding = sceneContext.navigationManager.pathBinding(for: 2)

    return navigationStack(using: navigationPathBinding)
    .onChange(of: lastTappedTab) { _, newValue in
      if newValue == 2, selectedTab == 2 {
        Task {
          startCircleRefresh()
          await viewModel.refreshNotifications()
        }
        lastTappedTab = nil
      }
    }
    .onChange(of: selectedTab) { oldValue, newValue in
      if newValue == 2 && oldValue != 2 {
        if openIntervalState == nil {
          openIntervalState = PerformanceSignposts.beginInterval("NotificationsOpen")
        }
        Task {
          startCircleRefresh()
          if !viewModel.hasLoadedOnce {
            await viewModel.loadNotifications()
          } else if viewModel.isStale || appState.notificationManager.unreadCount > 0 {
            await viewModel.refreshNotifications()
          }
          if let state = openIntervalState {
            PerformanceSignposts.endInterval("NotificationsOpen", state)
            openIntervalState = nil
          }
          try? await viewModel.markNotificationsAsSeen()
        }
      }
    }
    .onChange(of: appState.notificationManager.preferences) { _, _ in
      viewModel.preferencesDidChange()
    }
    .onChange(of: viewModel.isLoading) { _, isLoading in
      if !isLoading, let state = openIntervalState {
        PerformanceSignposts.endInterval("NotificationsOpen", state)
        openIntervalState = nil
      }
    }
    .onChange(of: selectedFilter) { _, newFilter in
      Task {
        await viewModel.setFilter(newFilter)
      }
    }
    .onChange(of: appState.moderationPolicy) { _, policy in
      // The list the view model paginates is the policy-filtered one.
      viewModel.moderationPolicy = policy
    }
    .task {
      if openIntervalState == nil {
        openIntervalState = PerformanceSignposts.beginInterval("NotificationsOpen")
      }
      viewModel.moderationPolicy = appState.moderationPolicy
      #if DEBUG
      if appState.e2eCircleTransport == nil, !viewModel.hasLoadedOnce {
        await viewModel.loadNotifications()
      }
      #else
      if !viewModel.hasLoadedOnce {
        await viewModel.loadNotifications()
      }
      #endif
      if let state = openIntervalState {
        PerformanceSignposts.endInterval("NotificationsOpen", state)
        openIntervalState = nil
      }
      // The first visit creates this view with the tab already selected, so the
      // selectedTab change above never fires for it.
      if selectedTab == 2 {
        try? await viewModel.markNotificationsAsSeen()
      }
    }
    .task(id: appState.circlesEnabled) {
      if appState.circlesEnabled {
        startCircleRefresh()
      } else {
        circleRefresh.cancel()
      }
    }
    .onDisappear { circleRefresh.cancel() }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .background {
        wasBackgrounded = true
        return
      }
      guard newPhase == .active, wasBackgrounded else { return }
      wasBackgrounded = false
      // Returning to the app on this tab: show what's new and clear the badge.
      if selectedTab == 2 {
        Task {
          if viewModel.isStale || appState.notificationManager.unreadCount > 0 {
            await viewModel.refreshNotifications()
          }
          try? await viewModel.markNotificationsAsSeen()
        }
      }
    }
    .onChange(of: viewModel.error != nil) { _, hasError in
      // A failed refresh keeps the loaded list on screen and reports the problem as a toast.
      guard hasError, !viewModel.groupedNotifications.isEmpty else { return }
      appState.toastManager.show(ToastItem(
        message: String(
          localized: "Couldn’t refresh notifications",
          comment: "Toast message shown when refreshing notifications fails"
        ),
        icon: "exclamationmark.triangle.fill"))
      viewModel.clearError()
    }
  }

  @MainActor
  private func startCircleRefresh() {
    guard appState.circlesEnabled else { return }
    let model = appState.circleNotificationsModel
    circleRefresh.start {
      do {
        try await model.refresh()
      } catch {
        // Circle errors stay in the Circle model and never block public activity.
      }
    }
  }

  private var notificationsLeadingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
  }

  private var notificationsTrailingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .automatic
    #endif
  }

  @ViewBuilder
  private func navigationStack(using navigationPath: Binding<NavigationPath>) -> some View {
    NavigationStack(path: navigationPath) {
      notificationContent
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
        .navigationTitle("Notifications")
      #if os(iOS)
        .toolbarTitleDisplayMode(.large)
      #endif
        #if !targetEnvironment(macCatalyst)
        .toolbar {
          ToolbarItem(placement: notificationsLeadingPlacement) {
            Menu {
              Button("Notification Settings", systemImage: "gearshape") {
                navigationPath.wrappedValue.append(NavigationDestination.settings(.notifications))
              }
              Button("Activity Alerts", systemImage: "bell.badge") {
                navigationPath.wrappedValue.append(NavigationDestination.activitySubscriptions)
              }
            } label: {
              Image(systemName: "gearshape")
                .imageScale(.medium)
            }
            .accessibilityLabel("Notification Options")
            .nuxNudge(id: .activitySubscriptions)
          }

          ToolbarItem(placement: .principal) {
            filterPicker
          }

          ToolbarItem(placement: .primaryAction) {
            SettingsAvatarToolbarButton {
              showingSettings = true
            }
          }
        }
        #endif
        .sheet(isPresented: $showingSettings) {
          SettingsView()
            .applyAppStateEnvironment(appState)
            .environment(appState)
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
        }
    }
  }

  @ViewBuilder
  private var filterPicker: some View {
    #if compiler(>=6.4)
    if #available(anyAppleOS 27.0, *) {
      Picker("Filter", selection: $selectedFilter) {
        Text("All", comment: "Notifications filter tab showing all activity").tag(NotificationsViewModel.NotificationFilter.all)
        Text("Mentions", comment: "Notifications filter tab showing only mentions, replies, and quotes").tag(NotificationsViewModel.NotificationFilter.mentions)
      }
      .buttonBorderShape(.capsule)
      .pickerStyle(.tabs)
      .frame(width: hSizeClass == .compact ? 220 : 280, height: 32)
    } else {
      Picker("Filter", selection: $selectedFilter) {
        Text("All").tag(NotificationsViewModel.NotificationFilter.all)
        Text("Mentions").tag(NotificationsViewModel.NotificationFilter.mentions)
      }
      .pickerStyle(.segmented)
      .frame(width: hSizeClass == .compact ? 220 : 280, height: 32)
    }
    #else
    Picker("Filter", selection: $selectedFilter) {
      Text("All").tag(NotificationsViewModel.NotificationFilter.all)
      Text("Mentions").tag(NotificationsViewModel.NotificationFilter.mentions)
    }
    .pickerStyle(.segmented)
    .frame(width: hSizeClass == .compact ? 220 : 280, height: 32)
    #endif
  }

  @ViewBuilder
  private var notificationContent: some View {
    if !appState.circlesEnabled {
      if let error = viewModel.error, viewModel.groupedNotifications.isEmpty {
        ErrorStateView(
          error: error,
          context: String(
            localized: "Couldn’t load notifications",
            comment: "Error state title when notifications fail to load"
          ),
          retryAction: { Task { await retryLoadNotifications() } }
        )
      } else if (viewModel.isLoading || viewModel.isRefreshing) && viewModel.groupedNotifications.isEmpty {
        loadingView
      } else if viewModel.groupedNotifications.isEmpty {
        emptyView
      } else {
        notificationsList
      }
    } else {
      notificationsList
    }
  }

  private var loadingView: some View {
    VStack {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading notifications")
        .foregroundColor(.secondary)
        .padding(.top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyView: some View {
    let isMentions = selectedFilter == .mentions
    return VStack(spacing: DesignTokens.Spacing.xl) {
      Image(systemName: isMentions ? "at" : "bell.slash")
        .appFont(size: 48)
        .foregroundColor(.secondary)

      Group {
        if isMentions {
          Text("No Mentions Yet")
        } else {
          Text("No Notifications")
        }
      }
      .enhancedAppHeadline()
      .fontWeight(.semibold)

      Group {
        if isMentions {
          Text("Replies, mentions, and quotes will appear here.")
        } else {
          Text("You don’t have any notifications yet.")
        }
      }
      .enhancedAppSubheadline()
      .foregroundColor(.secondary)
      .multilineTextAlignment(.center)

      if viewModel.hasMoreNotifications {
        loadMoreFilteredNotificationsButton
      }

      Button("Refresh") {
        Task {
          await viewModel.refreshNotifications()
        }
      }
      .buttonStyle(.catbird(.primary, size: .md))
      .padding(.top, 8)
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var loadMoreFilteredNotificationsButton: some View {
    Button {
      Task { await viewModel.loadMoreNotifications() }
    } label: {
      if viewModel.isLoadingMore {
        ProgressView()
      } else {
        Text("Load More")
      }
    }
    .buttonStyle(.catbird(.tonal, size: .md))
    .disabled(viewModel.isLoadingMore)
    .accessibilityIdentifier("notifications.loadMoreFiltered")
  }

  @ViewBuilder
  private var notificationsList: some View {
    let navigationPath = sceneContext.navigationManager.pathBinding(for: 2)
    // The view model's list already excludes the groups the policy filters
    // (`NotificationModeration`), so row indexes match its pagination threshold.
    let indexedGroups = Array(viewModel.groupedNotifications.enumerated())

    ScrollViewReader { _ in
      List {
        if appState.circlesEnabled {
          CircleNotificationsSection(appState: appState, navigationPath: navigationPath)
            #if os(macOS)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
            #endif
            .listSectionSeparator(.hidden, edges: .top)
        }

        if let error = viewModel.error, viewModel.groupedNotifications.isEmpty, appState.circlesEnabled {
          ErrorStateView(
            error: error,
            context: String(
              localized: "Couldn’t load public notifications",
              comment: "Error state title when public Bluesky notifications fail to load"
            ),
            retryAction: { Task { await retryLoadNotifications() } }
          )
          .listRowSeparator(.hidden)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        } else if (viewModel.isLoading || viewModel.isRefreshing)
          && viewModel.groupedNotifications.isEmpty && appState.circlesEnabled {
          HStack {
            Spacer()
            ProgressView("Loading notifications")
            Spacer()
          }
          .padding(.vertical, DesignTokens.Spacing.xl)
          .listRowSeparator(.hidden)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        } else if viewModel.groupedNotifications.isEmpty && appState.circlesEnabled {
          VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "bell.slash")
              .appFont(size: 32)
              .foregroundColor(.secondary)
            Text("No Public Notifications")
              .enhancedAppSubheadline()
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, DesignTokens.Spacing.xl)
          .listRowSeparator(.hidden)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        }
        Section {
          ForEach(indexedGroups, id: \.element.id) { item in
            let index = item.offset
            let group = item.element
            NotificationCard(
              group: group,
              onTap: { destination in
                navigationPath.wrappedValue.append(destination)
              }, path: navigationPath
            )
            .equatable()
            #if os(macOS)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
            #endif
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.visible)
            .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
            .alignmentGuide(.listRowSeparatorLeading) { _ in
              0
            }
            .alignmentGuide(.listRowSeparatorTrailing) { dimension in dimension.width }
            .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
            .onAppear {
              triggerLoadMoreNotificationsIfNeeded(currentIndex: index)
            }
          }

          if viewModel.paginationError != nil {
            VStack(spacing: 8) {
              Text("Couldn’t load more notifications.")
                .appSubheadline()
                .foregroundStyle(.secondary)
              Button("Retry") {
                Task { await viewModel.loadMoreNotifications() }
              }
              .buttonStyle(.catbird(.tonal, size: .md))
            }
            .frame(maxWidth: .infinity)
            .padding()
            #if os(macOS)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
            #endif
            .listRowSeparator(.hidden)
            .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
          } else if viewModel.hasMoreNotifications {
            HStack {
              Spacer()
              ProgressView()
                .padding()
              Spacer()
            }
            #if os(macOS)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
            #endif
            .id("loadingIndicator")
            .listRowSeparator(.hidden)
            .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
            .onAppear {
              // The spinner is the last row; reaching it requests the next page too.
              triggerLoadMoreNotificationsIfNeeded(currentIndex: indexedGroups.count - 1)
            }
          }
        }
        .listSectionSeparator(.hidden, edges: .top)
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
      startCircleRefresh()
      await viewModel.refreshNotifications()
      try? await viewModel.markNotificationsAsSeen()
    }
  }

  @MainActor
  private func triggerLoadMoreNotificationsIfNeeded(currentIndex: Int) {
    guard viewModel.shouldLoadMore(afterShowingIndex: currentIndex) else { return }
    
    let now = Date().timeIntervalSinceReferenceDate
    guard now - lastLoadMoreTriggerTime >= loadMoreTriggerDedupInterval else { return }
    
    lastLoadMoreTriggerTime = now
    Task {
      await viewModel.loadMoreNotifications()
    }
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

struct NotificationCard: View, Equatable {
  let group: GroupedNotification
  let onTap: (NavigationDestination) -> Void
  @Binding var path: NavigationPath

  static func == (lhs: NotificationCard, rhs: NotificationCard) -> Bool {
    guard lhs.group.id == rhs.group.id,
          lhs.group.type == rhs.group.type,
          lhs.group.pageNumber == rhs.group.pageNumber,
          lhs.group.hasUnreadNotifications == rhs.group.hasUnreadNotifications,
          lhs.group.subjectPost?.cid == rhs.group.subjectPost?.cid,
          lhs.group.subjectPost?.viewer?.like == rhs.group.subjectPost?.viewer?.like,
          lhs.group.subjectPost?.viewer?.repost == rhs.group.subjectPost?.viewer?.repost,
          lhs.group.parentPost?.cid == rhs.group.parentPost?.cid,
          lhs.group.parentPost?.viewer?.like == rhs.group.parentPost?.viewer?.like,
          lhs.group.parentPost?.viewer?.repost == rhs.group.parentPost?.viewer?.repost,
          lhs.group.notifications.count == rhs.group.notifications.count
    else {
      return false
    }

    for (ln, rn) in zip(lhs.group.notifications, rhs.group.notifications) {
      if ln.cid != rn.cid || ln.isRead != rn.isRead {
        return false
      }
    }

    return true
  }
  @Environment(AppState.self) private var appState: AppState
  @Environment(\.horizontalSizeClass) private var hSizeClass

  private var contentMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : 600
  }

  @State private var isFollowExpanded = false
  @Environment(\.moderationPolicy) private var moderationPolicy
  /// The hidden preview's cause identity the viewer chose to show.
  @State private var revealedModerationFilter: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        if group.type == .follow || group.type == .followBack {
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

      if (group.type == .follow || group.type == .followBack) && isFollowExpanded {
        expandedFollowersList
      }
    }
    // Leading 5pt puts icons and reply avatars ~11pt from the edge, the same
    // column as avatars in the home feed, instead of hugging the screen edge.
    .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 16))
    .animation(.none, value: isFollowExpanded)
    .frame(maxWidth: contentMaxWidth, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(
      group.hasUnreadNotifications ? Color.accentColor.opacity(0.2) : Color.clear
    )
  }

  private var expandedFollowersList: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(group.notifications, id: \.cid) { notification in
        Button {
          onTap(NavigationDestination.profile(notification.author.did.didString()))
        } label: {
          HStack(spacing: DesignTokens.Spacing.base) {
            NotificationAuthorAvatar(author: notification.author, size: 36)

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 4) {
                Text(
                  notification.author.displayName.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                  } ?? notification.author.handle.description
                )
                  .fontWeight(.semibold)
                  .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
                  .lineLimit(1)
                  .truncationMode(.tail)

                if let badgeKind = VerificationBadge.kind(
                  for: notification.author.verification,
                  did: notification.author.did,
                  hideBadges: appState.preferencesManager.hideVerificationBadges
                ) {
                  VerificationBadgeView(kind: badgeKind)
                    .appFont(AppTextRole.caption)
                }
              }

              Text(verbatim: "@\(notification.author.handle)")
                .appSubheadline()
                .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
            }

            Spacer()

            Image(systemName: "chevron.forward")
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
            .padding(.leading, DesignTokens.Spacing.base + 36 + DesignTokens.Spacing.base)
        }
      }
    }
    .padding(.leading, 50)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .padding(.bottom, 8)
  }

  private func replyOrQuoteNotificationView(post: AppBskyFeedDefs.PostView) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      let (isToYou, parentAuthor) = determineReplyContext()
      PostView(
        post: post,
        grandparentAuthor: parentAuthor,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState,
        isToYou: isToYou
      )
    }
    .padding(.top, 6)
    .contentShape(Rectangle())
  }

  /// Determines if the reply is to the current user and who the parent author is
  private func determineReplyContext() -> (isToYou: Bool, parentAuthor: AppBskyActorDefs.ProfileViewBasic?) {
    // Only check for reply notifications
    guard group.type == .reply else {
      return (false, nil)
    }

    // Get the parent post from the group (fetched in ViewModel)
    guard let parentPost = group.parentPost else {
      return (false, nil)
    }

    // Check if the parent post author is the current user
    let currentUserDid = appState.userDID
    let isReplyToCurrentUser = parentPost.author.did.didString() == currentUserDid

    if isReplyToCurrentUser {
      // Reply is to the current user, show "Replied to you"
      return (true, nil)
    } else {
      // Reply is to someone else, show "Replied to @handle"
      return (false, parentPost.author)
    }
  }

  private var standardNotificationView: some View {
    HStack(alignment: .top, spacing: 12) {
      NotificationIcon(type: group.type)
        .frame(width: 50, alignment: .trailing)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center) {
          if (group.type == .follow || group.type == .followBack) && group.notifications.count > 1 {
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
            .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
            .accessibilityLabel(formatTimeAgo(from: group.latestNotification.indexedAt.date, forAccessibility: true))

        }

        notificationText
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
          .accessibilityLabel(notificationAccessibilityLabel)

        if shouldShowPostPreview {
          postPreview
            .padding(.top, 4)
        }
      }
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  /// Resolves an actor's display name (falling back to `@handle`, then localized `"Someone"`).
  private func actorDisplayName(for author: AppBskyActorDefs.ProfileView?) -> String {
    if let displayName = author?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
      return displayName
    } else if let handle = author?.handle {
      return "@\(handle.description)"
    }
    return String(
      localized: "Someone",
      comment: "Fallback actor name when a notification author's profile name is unavailable"
    )
  }

  /// Styled `Text` for a notification actor: bold name plus optional inline verification badge.
  private func styledActorText(for author: AppBskyActorDefs.ProfileView?, bodyFont: Font) -> Text {
    var actorText = Text(actorDisplayName(for: author)).font(bodyFont.bold())
    if let author,
       let badge = VerificationBadge.inlineText(
         for: author.verification,
         did: author.did,
         hideBadges: appState.preferencesManager.hideVerificationBadges
       ) {
      actorText = actorText + Text(verbatim: " ") + badge
    }
    return actorText
  }

  /// Spoken actor name for VoiceOver, including verification status when present.
  private func spokenActorName(for author: AppBskyActorDefs.ProfileView?) -> String {
    let name = actorDisplayName(for: author)
    if let author,
       let kind = VerificationBadge.kind(
         for: author.verification,
         did: author.did,
         hideBadges: appState.preferencesManager.hideVerificationBadges
       ) {
      return String(
        localized: "\(name), \(kind.accessibilityLabel)",
        comment: "VoiceOver actor name with verification status. %1$@ is the actor's name, %2$@ is the verification badge description."
      )
    }
    return name
  }

  /// Composed `Text` for the notification sentence using single localized templates so
  /// translators can reorder actor names and counts across languages (Japanese, Korean,
  /// Arabic, German, Spanish) while keeping bold actor styling and inline verification badges.
  private var notificationText: Text {
    let bodyFont = appState.fontManager.fontForTextRole(.body)
    let count = group.notifications.count
    let firstActor = styledActorText(for: group.notifications.first?.author, bodyFont: bodyFont)

    let sentence: Text
    switch group.type {
    case .activitySubscription:
      if count <= 1 {
        sentence = Text(
          "\(firstActor) shared a new post",
          comment: "Notification summary when a subscribed account shares one new post. %@ is the author's name."
        )
      } else {
        sentence = Text(
          "\(firstActor) shared \(count) new posts",
          comment: "Notification summary when a subscribed account shares new posts. %1$@ is the author's name, %2$lld is the post count."
        )
      }
    case .verified:
      sentence = Text(
        "\(firstActor) verified your account",
        comment: "Notification summary when a verifier verifies the user's account. %@ is the verifier's name."
      )
    case .unverified:
      sentence = Text(
        "\(firstActor) removed their verification from your account",
        comment: "Notification summary when a verifier removes verification from the user's account. %@ is the verifier's name."
      )
    case .contactMatch:
      sentence = Text(
        "\(firstActor) is on Bluesky",
        comment: "Notification summary when a contact joins Bluesky. %@ is the contact's name."
      )
    case .like:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) liked your post",
          comment: "Notification summary when two people liked the user's post. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others liked your post",
          comment: "Notification summary when multiple people liked the user's post. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) liked your post",
          comment: "Notification summary when one person liked the user's post. %@ is the person's name."
        )
      }
    case .repost:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) reposted your post",
          comment: "Notification summary when two people reposted the user's post. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others reposted your post",
          comment: "Notification summary when multiple people reposted the user's post. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) reposted your post",
          comment: "Notification summary when one person reposted the user's post. %@ is the person's name."
        )
      }
    case .likeViaRepost:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) liked your repost",
          comment: "Notification summary when two people liked the user's repost. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others liked your repost",
          comment: "Notification summary when multiple people liked the user's repost. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) liked your repost",
          comment: "Notification summary when one person liked the user's repost. %@ is the person's name."
        )
      }
    case .repostViaRepost:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) reposted your repost",
          comment: "Notification summary when two people reposted the user's repost. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others reposted your repost",
          comment: "Notification summary when multiple people reposted the user's repost. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) reposted your repost",
          comment: "Notification summary when one person reposted the user's repost. %@ is the person's name."
        )
      }
    case .follow:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) followed you",
          comment: "Notification summary when two people followed the user. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others followed you",
          comment: "Notification summary when multiple people followed the user. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) followed you",
          comment: "Notification summary when one person followed the user. %@ is the person's name."
        )
      }
    case .followBack:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) followed you back",
          comment: "Notification summary when two people followed the user back. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others followed you back",
          comment: "Notification summary when multiple people followed the user back. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) followed you back",
          comment: "Notification summary when one person followed the user back. %@ is the person's name."
        )
      }
    case .mention:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) mentioned you",
          comment: "Notification summary when two people mentioned the user. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others mentioned you",
          comment: "Notification summary when multiple people mentioned the user. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) mentioned you in a post",
          comment: "Notification summary when one person mentioned the user in a post. %@ is the person's name."
        )
      }
    case .reply:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) replied",
          comment: "Notification summary when two people replied to the user. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others replied",
          comment: "Notification summary when multiple people replied to the user. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) replied to your post",
          comment: "Notification summary when one person replied to the user's post. %@ is the person's name."
        )
      }
    case .quote:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) quoted",
          comment: "Notification summary when two people quoted the user. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others quoted",
          comment: "Notification summary when multiple people quoted the user. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) quoted your post",
          comment: "Notification summary when one person quoted the user's post. %@ is the person's name."
        )
      }
    case .starterpackJoined:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) signed up with your starter pack",
          comment: "Notification summary when two people signed up using the user's starter pack. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others signed up with your starter pack",
          comment: "Notification summary when multiple people signed up using the user's starter pack. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) signed up with your starter pack",
          comment: "Notification summary when one person signed up using the user's starter pack. %@ is the person's name."
        )
      }
    case .feedgenLike:
      if count == 2 {
        let secondActor = styledActorText(for: group.notifications[1].author, bodyFont: bodyFont)
        sentence = Text(
          "\(firstActor) and \(secondActor) liked your custom feed",
          comment: "Notification summary when two people liked the user's custom feed. %1$@ is the first person's name, %2$@ is the second person's name."
        )
      } else if count > 2 {
        let others = count - 1
        sentence = Text(
          "\(firstActor) and \(others) others liked your custom feed",
          comment: "Notification summary when multiple people liked the user's custom feed. %1$@ is the first person's name, %2$lld is the number of additional people."
        )
      } else {
        sentence = Text(
          "\(firstActor) liked your custom feed",
          comment: "Notification summary when one person liked the user's custom feed. %@ is the person's name."
        )
      }
    }

    return sentence.font(bodyFont)
  }

  /// VoiceOver-friendly version of the notification sentence using the same localized templates.
  /// `Text(Image:)` does not narrate the badge, so we include the badge's spoken label in each actor name.
  private var notificationAccessibilityLabel: String {
    let count = group.notifications.count
    let firstActor = spokenActorName(for: group.notifications.first?.author)

    switch group.type {
    case .activitySubscription:
      return count <= 1
        ? String(localized: "\(firstActor) shared a new post")
        : String(localized: "\(firstActor) shared \(count) new posts")
    case .verified:
      return String(localized: "\(firstActor) verified your account")
    case .unverified:
      return String(localized: "\(firstActor) removed their verification from your account")
    case .contactMatch:
      return String(localized: "\(firstActor) is on Bluesky")
    case .like:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) liked your post")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others liked your post")
      }
      return String(localized: "\(firstActor) liked your post")
    case .repost:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) reposted your post")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others reposted your post")
      }
      return String(localized: "\(firstActor) reposted your post")
    case .likeViaRepost:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) liked your repost")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others liked your repost")
      }
      return String(localized: "\(firstActor) liked your repost")
    case .repostViaRepost:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) reposted your repost")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others reposted your repost")
      }
      return String(localized: "\(firstActor) reposted your repost")
    case .follow:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) followed you")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others followed you")
      }
      return String(localized: "\(firstActor) followed you")
    case .followBack:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) followed you back")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others followed you back")
      }
      return String(localized: "\(firstActor) followed you back")
    case .mention:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) mentioned you")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others mentioned you")
      }
      return String(localized: "\(firstActor) mentioned you in a post")
    case .reply:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) replied")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others replied")
      }
      return String(localized: "\(firstActor) replied to your post")
    case .quote:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) quoted")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others quoted")
      }
      return String(localized: "\(firstActor) quoted your post")
    case .starterpackJoined:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) signed up with your starter pack")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others signed up with your starter pack")
      }
      return String(localized: "\(firstActor) signed up with your starter pack")
    case .feedgenLike:
      if count == 2 {
        let secondActor = spokenActorName(for: group.notifications[1].author)
        return String(localized: "\(firstActor) and \(secondActor) liked your custom feed")
      } else if count > 2 {
        return String(localized: "\(firstActor) and \(count - 1) others liked your custom feed")
      }
      return String(localized: "\(firstActor) liked your custom feed")
    }
  }

  private var shouldShowPostPreview: Bool {
    switch group.type {
    case .like, .repost, .likeViaRepost, .repostViaRepost, .activitySubscription:
      return group.subjectPost != nil
    default: return false
    }
  }

  /// The subject post, under the feed-row rules: a hidden row when the policy
  /// filters it, else the body gate over text and media, with the media
  /// thumbnails behind a compact media gate.
  @ViewBuilder
  private var postPreview: some View {
    if let post = group.subjectPost {
      let moderation = PostModerationPresentation.make(post: post, policy: moderationPolicy)
      if moderation.hidesRow && revealedModerationFilter != moderation.filterIdentity {
        ModerationHiddenPostRow(presentation: moderation) {
          revealedModerationFilter = moderation.filterIdentity
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          if moderation.hidesRow {
            // A shown hidden preview keeps its cause in view and can be hidden again.
            ModerationRevealedPostBar(presentation: moderation) {
              revealedModerationFilter = nil
            }
          }
          ModerationContentGate(ui: moderation.body) {
            postPreviewBody(post, moderation: moderation)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func postPreviewBody(_ post: AppBskyFeedDefs.PostView, moderation: PostModerationPresentation) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        ContentLabelView(causes: moderation.chips)

        if case .knownType(let postObj) = post.record, let feedPost = postObj as? AppBskyFeedPost,
          !feedPost.text.isEmpty {
          Text(feedPost.text)
            .appBody()
            .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Show media thumbnails if available
        let thumbnails = extractMediaThumbnails(from: post)
        if !thumbnails.isEmpty {
          ModerationMediaGate(ui: moderation.media, style: .compact) {
            NotificationMediaThumbnail(thumbnails: thumbnails)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        // Show quoted post text for record embeds (without media)
        if thumbnails.isEmpty, let embed = post.embed {
          switch embed {
          case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView:
            quotedPreview(in: post)

          case .appBskyEmbedExternalView(let external):
            // Show external link info if no thumbnail available
            if thumbnails.isEmpty {
              HStack(spacing: 8) {
                Image(systemName: "link")
                  .foregroundStyle(.secondary)
                  .appFont(AppTextRole.caption)
                
                Text(external.external.title ?? external.external.uri.uriString())
                  .appBody()
                  .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            
          default:
            EmptyView()
          }
        }
      }
  }

  /// The quoted post's text under the quote's own decision: a `!hide`, `!warn`
  /// or labeler `blurs: content` label on the quoted post or its author gates
  /// it here as `RecordEmbedView` does in feeds. The parent's decision carries
  /// these causes downgraded, so its body gate never covers them.
  @ViewBuilder
  private func quotedPreview(in post: AppBskyFeedDefs.PostView) -> some View {
    if let quoted = PostModerationPresentation.quotedRecord(in: post),
      case .knownType(let record) = quoted.value, let quotedPost = record as? AppBskyFeedPost {
      let quote = PostModerationPresentation.make(quoted: quoted, policy: moderationPolicy)
      ModerationContentGate(ui: quote.body) {
        Text("Quoted: \(quotedPost.text)")
          .appBody()
          .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func handleTap() {
    switch group.type {
    case .like, .repost, .likeViaRepost, .repostViaRepost:
      if let post = group.subjectPost {
        onTap(NavigationDestination.post(post.uri))
      } else if let reasonSubject = group.notifications.first?.reasonSubject {
        onTap(NavigationDestination.post(reasonSubject))
      }
    case .follow, .followBack:
      if let follower = group.notifications.first {
        onTap(NavigationDestination.profile(follower.author.did.didString()))
      }
    case .reply, .quote, .mention:
      if let post = group.subjectPost {
        onTap(NavigationDestination.post(post.uri))
      } else if let uri = group.notifications.first?.uri {
        onTap(NavigationDestination.post(uri))
      }
    case .activitySubscription:
      var uniqueURIs: [ATProtocolURI] = []
      for notification in group.notifications {
        if !uniqueURIs.contains(notification.uri) {
          uniqueURIs.append(notification.uri)
          if uniqueURIs.count == 25 { break }
        }
      }
      if uniqueURIs.isEmpty {
        if let post = group.subjectPost {
          uniqueURIs = [post.uri]
        } else if let uri = group.notifications.first?.uri {
          uniqueURIs = [uri]
        }
      }
      if uniqueURIs.count == 1 {
        onTap(NavigationDestination.post(uniqueURIs[0]))
      } else if !uniqueURIs.isEmpty {
        onTap(NavigationDestination.notificationActivity(uniqueURIs))
      }
    case .starterpackJoined:
      if let starterPackURI = group.notifications.first?.reasonSubject {
        onTap(NavigationDestination.starterPack(starterPackURI))
      }
    case .verified, .unverified, .contactMatch:
      if let actor = group.notifications.first {
        onTap(NavigationDestination.profile(actor.author.did.didString()))
      }
    case .feedgenLike:
      if let feedURI = group.notifications.first?.reasonSubject {
        onTap(NavigationDestination.feed(feedURI))
      }
    }
  }
  
  /// Extracts media thumbnail information from post embeds
  private func extractMediaThumbnails(from post: AppBskyFeedDefs.PostView) -> [MediaThumbnailInfo] {
    guard let embed = post.embed else { return [] }
    
    var thumbnails: [MediaThumbnailInfo] = []
    
    switch embed {
    case .appBskyEmbedImagesView(let images):
      // Handle multiple images
      for image in images.images {
        if let thumbURL = URL(string: image.thumb.uriString()) {
          // Check if it's a GIF by looking at the original image URL
          let isGif = image.fullsize.uriString().lowercased().contains("gif") ||
                     image.thumb.uriString().lowercased().contains("gif")
          
          thumbnails.append(MediaThumbnailInfo(
            url: thumbURL,
            mediaType: isGif ? .gif : .image,
            totalCount: images.images.count
          ))
        }
      }
      
    case .appBskyEmbedGalleryView(let gallery):
      // Handle gallery images
      let galleryImages = gallery.items.compactMap { item -> AppBskyEmbedGallery.ViewImage? in
        if case .appBskyEmbedGalleryViewImage(let image) = item { return image } else { return nil }
      }
      for image in galleryImages {
        if let thumbURL = URL(string: image.thumbnail.uriString()) {
          thumbnails.append(MediaThumbnailInfo(
            url: thumbURL,
            mediaType: .image,
            totalCount: galleryImages.count
          ))
        }
      }

    case .appBskyEmbedVideoView(let video):
      // Handle video thumbnail
      if let thumbnailURI = video.thumbnail,
         let thumbURL = URL(string: thumbnailURI.uriString()) {
        thumbnails.append(MediaThumbnailInfo(
          url: thumbURL,
          mediaType: .video,
          totalCount: 1
        ))
      }
      
    case .appBskyEmbedExternalView(let external):
      // Handle external link thumbnail
      if let thumbURI = external.external.thumb,
         let thumbURL = URL(string: thumbURI.uriString()) {
        thumbnails.append(MediaThumbnailInfo(
          url: thumbURL,
          mediaType: .external,
          totalCount: 1
        ))
      }
      
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      // Handle record with media - extract media part
      switch recordWithMedia.media {
      case .appBskyEmbedImagesView(let images):
        for image in images.images {
          if let thumbURL = URL(string: image.thumb.uriString()) {
            let isGif = image.fullsize.uriString().lowercased().contains("gif") ||
                       image.thumb.uriString().lowercased().contains("gif")
            
            thumbnails.append(MediaThumbnailInfo(
              url: thumbURL,
              mediaType: isGif ? .gif : .image,
              totalCount: images.images.count
            ))
          }
        }
        
      case .appBskyEmbedGalleryView(let gallery):
        let galleryImages = gallery.items.compactMap { item -> AppBskyEmbedGallery.ViewImage? in
          if case .appBskyEmbedGalleryViewImage(let image) = item { return image } else { return nil }
        }
        for image in galleryImages {
          if let thumbURL = URL(string: image.thumbnail.uriString()) {
            thumbnails.append(MediaThumbnailInfo(
              url: thumbURL,
              mediaType: .image,
              totalCount: galleryImages.count
            ))
          }
        }

      case .appBskyEmbedVideoView(let video):
        if let thumbnailURI = video.thumbnail,
           let thumbURL = URL(string: thumbnailURI.uriString()) {
          thumbnails.append(MediaThumbnailInfo(
            url: thumbURL,
            mediaType: .video,
            totalCount: 1
          ))
        }
        
      case .appBskyEmbedExternalView(let external):
        if let thumbURI = external.external.thumb,
           let thumbURL = URL(string: thumbURI.uriString()) {
          thumbnails.append(MediaThumbnailInfo(
            url: thumbURL,
            mediaType: .external,
            totalCount: 1
          ))
        }
        
      case .unexpected:
        break
      }
      
    case .appBskyEmbedRecordView:
      // Record embeds don't typically have media thumbnails
      break
      
    case .unexpected:
      break
}
    
    return thumbnails
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
      .contentShape(Rectangle())
  }
}

// MARK: - Media Thumbnail Support

struct MediaThumbnailInfo {
  let url: URL
  let mediaType: MediaType
  let totalCount: Int
  
  enum MediaType {
    case image
    case video
    case gif
    case external
    
    var placeholderIcon: String {
      switch self {
      case .image, .gif: return "photo.fill"
      case .video: return "play.rectangle.fill"
      case .external: return "link"
      }
    }
  }
}

struct NotificationMediaThumbnail: View {
  let thumbnails: [MediaThumbnailInfo]
  @Environment(AppState.self) private var appState: AppState
  
  private let thumbnailSize: CGFloat = 44
  private let cornerRadius: CGFloat = 8
  private let maxThumbnails = 3
  
  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<min(maxThumbnails, thumbnails.count), id: \.self) { index in
        let thumbnail = thumbnails[index]
        
        LazyImage(request: ImageLoadingManager.imageRequest(
          for: thumbnail.url,
          targetSize: CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
        )) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else if state.error != nil {
            // Error state - show placeholder icon
            Image(systemName: thumbnail.mediaType.placeholderIcon)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color.systemGray6)
          } else {
            // Loading state
            ProgressView()
              .scaleEffect(0.8)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color.systemGray6)
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
          // Add play icon for videos
          thumbnail.mediaType == .video ? 
          Image(systemName: "play.fill")
            .foregroundStyle(.white)
            .appFont(size: 12, weight: .bold)
            .shadow(radius: 2)
          : nil
        )
        .accessibilityLabel(accessibilityLabel(for: thumbnail))
      }
      
      // Show count indicator if there are more thumbnails
      if thumbnails.count > maxThumbnails {
        Text(verbatim: "+\((thumbnails.count - maxThumbnails).formatted())")
          .appFont(.customSystemFont(size: 12, weight: .medium, width: 60, relativeTo: .caption))
          .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
          .frame(width: thumbnailSize, height: thumbnailSize)
          .background(Color.systemGray5)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
      }
    }
  }
  
  private func accessibilityLabel(for thumbnail: MediaThumbnailInfo) -> LocalizedStringKey {
    switch thumbnail.mediaType {
    case .image: return "Image thumbnail"
    case .video: return "Video thumbnail"
    case .gif: return "GIF thumbnail"
    case .external: return "Link thumbnail"
    }
  }
}

/// A notification author's avatar. When the policy blurs it (`ui(.avatar)`:
/// `!warn`, `!hide` or an adult or graphic account label set to warn or hide)
/// the neutral placeholder is drawn and no image is requested.
struct NotificationAuthorAvatar: View {
  let author: AppBskyActorDefs.ProfileView
  let size: CGFloat
  @Environment(\.moderationPolicy) private var moderationPolicy
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    if NotificationModeration.concealsAvatar(of: author, policy: moderationPolicy) {
      ModeratedAvatarPlaceholder(size: size)
    } else {
      let request = ImageRequestFactory.avatar(author.finalAvatarURL(), pointSize: size, scale: displayScale)
      LazyImage(request: request) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.gray)
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
    }
  }
}

struct AvatarStack: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  let notifications: [AppBskyNotificationListNotifications.Notification]
  @Environment(AppState.self) private var appState: AppState

  var body: some View {
    let navigationPath = sceneContext.navigationManager.pathBinding(for: 2)

    HStack(spacing: 3) {
      ForEach(0..<min(3, notifications.count), id: \.self) { index in
        NotificationAuthorAvatar(author: notifications[index].author, size: 44)
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
        Text(verbatim: "+\((notifications.count - 3).formatted())")
          .appFont(.customSystemFont(size: 16, weight: .medium, width: 60, relativeTo: .caption))
          .textScale(.secondary)
          .frame(width: 44, height: 44)
          .background(Color.systemGray6.opacity(0.7))
          .clipShape(Circle())
//          .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
      }
    }
    .offset(x: -3)
  }
}

#Preview("NotificationsView") {
  AsyncPreviewContent { appState in
    NotificationsView(
      appState: appState,
      selectedTab: .constant(2),
      lastTappedTab: .constant(nil)
    )
  }
}
