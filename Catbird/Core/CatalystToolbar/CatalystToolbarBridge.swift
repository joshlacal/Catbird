#if targetEnvironment(macCatalyst)
import SwiftUI

/// Syncs SwiftUI state to the CatalystToolbarCoordinator and routes
/// toolbar actions back into SwiftUI.
struct CatalystToolbarBridge: ViewModifier {
  @Binding var selectedTab: Int
  @Binding var isDrawerOpen: Bool
  @Binding var isRootView: Bool
  @Binding var showingPostComposer: Bool
  @Binding var showingNewMessageSheet: Bool
  @Binding var showingSettings: Bool

  let appState: AppState

  // Contextual action closures (set by the view attaching the modifier)
  var onRefresh: (() async -> Void)?
  var onSearchFilter: (() -> Void)?
  var onMarkAllRead: (() async -> Void)?
  var onMessageRequests: (() -> Void)?

  func body(content: Content) -> some View {
    content
      .onAppear { setupCoordinator() }
      .onChange(of: selectedTab) { _, newTab in
        CatalystSceneDelegate.activeCoordinator?.selectTab(newTab)
      }
      .onChange(of: isRootView) { _, newValue in
        CatalystSceneDelegate.activeCoordinator?.setFeedSelectorEnabled(newValue)
      }
      .onChange(of: appState.notificationManager.unreadCount) { _, _ in
        updateBadges()
      }
      .onChange(of: appState.totalMessagesUnreadCount) { _, _ in
        updateBadges()
      }
  }

  private func setupCoordinator() {
    guard let coordinator = CatalystSceneDelegate.activeCoordinator else { return }

    coordinator.onTabSelected = { tab in
      selectedTab = tab
    }
    coordinator.onComposeTapped = {
      showingPostComposer = true
    }
    coordinator.onNewMessageTapped = {
      showingNewMessageSheet = true
    }
    coordinator.onSettingsTapped = {
      showingSettings = true
    }
    coordinator.onFeedSelectorTapped = {
      isDrawerOpen = true
    }
    coordinator.onRefreshTapped = {
      Task { await onRefresh?() }
    }
    coordinator.onSearchFilterTapped = {
      onSearchFilter?()
    }
    coordinator.onMarkAllReadTapped = {
      Task { await onMarkAllRead?() }
    }
    coordinator.onMessageRequestsTapped = {
      onMessageRequests?()
    }

    // Set up avatar hosting view — coordinator retains the UIHostingController
    let avatarView = SettingsAvatarToolbarButton {
      showingSettings = true
    }
    .environment(appState)
    coordinator.setAvatarView(avatarView)

    // Initial state sync
    coordinator.selectTab(selectedTab)
    coordinator.setFeedSelectorEnabled(isRootView)
    updateBadges()
  }

  private func updateBadges() {
    CatalystSceneDelegate.activeCoordinator?.updateBadges(
      notifications: appState.notificationManager.unreadCount,
      messages: appState.totalMessagesUnreadCount
    )
  }
}
#endif
