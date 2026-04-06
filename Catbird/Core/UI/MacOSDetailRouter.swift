#if os(macOS)
import OSLog
import Petrel
import SwiftUI

/// Routes the detail pane content based on the selected sidebar item.
/// Each sidebar item gets its own NavigationStack with a preserved NavigationPath.
struct MacOSDetailRouter: View {
  @Environment(AppState.self) private var appState

  let selection: SidebarItem?

  /// Per-item navigation paths, preserved across sidebar switches
  @Binding var navigationPaths: [SidebarItem: NavigationPath]

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSDetailRouter")

  var body: some View {
    Group {
      switch selection {
      case .feed(let fetchType):
        feedDetail(fetchType: fetchType)

      case .search:
        searchDetail

      case .notifications:
        notificationsDetail

      case .profile:
        profileDetail

      case .chat:
        chatDetail

      case nil:
        ContentUnavailableView {
          Label("Catbird", systemImage: "bird")
        } description: {
          Text("Select an item from the sidebar")
        }
      }
    }
  }

  // MARK: - Feed Detail

  @ViewBuilder
  private func feedDetail(fetchType: FetchType) -> some View {
    let sidebarItem = SidebarItem.feed(fetchType)
    let pathBinding = pathBinding(for: sidebarItem)

    NavigationStack(path: pathBinding) {
      FeedView(
        fetch: fetchType,
        path: pathBinding,
        selectedTab: .constant(0)
      )
      .navigationTitle(feedName(for: fetchType))
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(
          destination,
          path: pathBinding,
          appState: appState,
          selectedTab: .constant(0)
        )
      }
    }
  }

  private func feedName(for fetchType: FetchType) -> String {
    switch fetchType {
    case .timeline:
      return "Timeline"
    default:
      return fetchType.description
    }
  }

  // MARK: - Search Detail

  private var searchDetail: some View {
    RefinedSearchView(
      appState: appState,
      selectedTab: .constant(1),
      lastTappedTab: .constant(nil)
    )
  }

  // MARK: - Notifications Detail

  private var notificationsDetail: some View {
    NotificationsView(
      appState: appState,
      selectedTab: .constant(2),
      lastTappedTab: .constant(nil)
    )
  }

  // MARK: - Profile Detail

  private var profileDetail: some View {
    let pathBinding = pathBinding(for: .profile)
    return NavigationStack(path: pathBinding) {
      UnifiedProfileView(
        appState: appState,
        selectedTab: .constant(3),
        lastTappedTab: .constant(nil),
        path: pathBinding
      )
      .id(appState.userDID)
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(
          destination,
          path: pathBinding,
          appState: appState,
          selectedTab: .constant(3)
        )
      }
    }
  }

  // MARK: - Chat Detail

  private var chatDetail: some View {
    MacOSChatContentView()
  }

  // MARK: - Path Management

  private func pathBinding(for item: SidebarItem) -> Binding<NavigationPath> {
    Binding(
      get: { navigationPaths[item] ?? NavigationPath() },
      set: { navigationPaths[item] = $0 }
    )
  }
}
#endif
