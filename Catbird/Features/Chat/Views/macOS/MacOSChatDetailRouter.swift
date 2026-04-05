#if os(macOS)
import CatbirdMLSCore
import Petrel
import SwiftUI

// MARK: - macOS Chat Detail Router

/// Routes the selected conversation to the appropriate detail view (Bluesky DM or MLS).
/// Wraps content in a NavigationStack for navigation destinations.
@available(macOS 13.0, *)
struct MacOSChatDetailRouter: View {
  @Environment(AppState.self) private var appState
  let coordinator: UnifiedChatCoordinator
  let selectedConvoId: String?
  @Binding var selectedTab: Int

  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }

  var body: some View {
    NavigationStack(path: chatNavigationPath) {
      detailContent
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(
            destination,
            path: chatNavigationPath,
            appState: appState,
            selectedTab: $selectedTab
          )
        }
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    if let convoId = selectedConvoId,
       let item = coordinator.conversations.first(where: { $0.id == convoId }) {
      switch item {
      case .bluesky:
        MacOSBlueskyConversationView(convoId: convoId)
          .id(convoId)
      case .mls:
        MacOSMLSConversationView(conversationId: convoId)
          .id(convoId)
      }
    } else if let convoId = selectedConvoId {
      // Deep-link before coordinator has loaded — assume Bluesky DM
      MacOSBlueskyConversationView(convoId: convoId)
        .id(convoId)
    } else {
      EmptyConversationView()
    }
  }
}
#endif
