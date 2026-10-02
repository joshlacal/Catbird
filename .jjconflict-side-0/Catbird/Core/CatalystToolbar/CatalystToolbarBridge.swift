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
      .onChange(of: appState.currentUserProfile?.avatar?.description) { _, _ in
        if let coordinator = CatalystSceneDelegate.activeCoordinator {
          loadAvatar(coordinator: coordinator)
        }
      }
  }

  private func setupCoordinator() {
    guard let coordinator = CatalystSceneDelegate.activeCoordinator else { return }

    coordinator.onTabSelected = { tab in
      selectedTab = tab
      appState.navigationManager.updateCurrentTab(tab)
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

    // Initial state sync
    coordinator.selectTab(selectedTab)
    coordinator.setFeedSelectorEnabled(isRootView)
    updateBadges()

    // Load avatar image
    loadAvatar(coordinator: coordinator)
  }

  private func loadAvatar(coordinator: CatalystToolbarCoordinator) {
    guard let avatarURL = appState.currentUserProfile?.finalAvatarURL() else { return }
    Task {
      do {
        let (data, _) = try await URLSession.shared.data(from: avatarURL)
        if let image = UIImage(data: data) {
          await MainActor.run {
            coordinator.updateAvatarImage(image)
          }
        }
      } catch {
        // Fall back to person.circle — already set
      }
    }
  }

  private func updateBadges() {
    CatalystSceneDelegate.activeCoordinator?.updateBadges(
      notifications: appState.notificationManager.unreadCount,
      messages: appState.totalMessagesUnreadCount
    )
  }
}
#endif
