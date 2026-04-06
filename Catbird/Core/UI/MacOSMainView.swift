#if os(macOS)
import OSLog
import Petrel
import SwiftUI

/// Top-level macOS view replacing TabView. Uses NavigationSplitView with a unified
/// sidebar (functional items + feeds) and a detail pane routed by SidebarItem selection.
struct MacOSMainView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.openWindow) private var openWindow

  @State private var selectedItem: SidebarItem? = .feed(.timeline)
  @State private var navigationPaths: [SidebarItem: NavigationPath] = [:]

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSMainView")

  var body: some View {
    NavigationSplitView {
      MacOSUnifiedSidebar(selection: $selectedItem)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } detail: {
      MacOSDetailRouter(
        selection: selectedItem,
        navigationPaths: $navigationPaths
      )
    }
    .navigationTitle(windowTitle)
    .toolbar(id: "main") {
      ToolbarItem(id: "compose", placement: .primaryAction) {
        Button {
          openWindow(id: "compose")
        } label: {
          Image(systemName: "pencil")
        }
        .tint(.accentColor)
        .keyboardShortcut("n", modifiers: .command)
        .help("New Post (Cmd+N)")
      }

      ToolbarItem(id: "avatar", placement: .primaryAction) {
        SettingsAvatarToolbarButton {
          openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
        .help("Settings (Cmd+,)")
      }
    }
    // Keyboard shortcuts
    .onKeyPress(.escape) {
      handleEscape()
    }
    .onKeyPress("f", modifiers: .command) { selectedItem = .search; return .handled }
    .onKeyPress("1", modifiers: .command) { selectedItem = .search; return .handled }
    .onKeyPress("2", modifiers: .command) { selectedItem = .notifications; return .handled }
    .onKeyPress("3", modifiers: .command) { selectedItem = .chat; return .handled }
    .onKeyPress("4", modifiers: .command) { selectedItem = .profile; return .handled }
    // Deep link handling
    .onChange(of: appState.navigationManager.targetConversationId) { _, newValue in
      if let _ = newValue {
        selectedItem = .chat
        appState.navigationManager.targetConversationId = nil
      }
    }
    .onChange(of: appState.navigationManager.targetMLSConversationId) { _, newValue in
      if let _ = newValue {
        selectedItem = .chat
        appState.navigationManager.targetMLSConversationId = nil
      }
    }
  }

  // MARK: - Window Title

  private var windowTitle: String {
    switch selectedItem {
    case .search: return "Search"
    case .notifications: return "Notifications"
    case .chat: return "Chat"
    case .profile: return "Profile"
    case .feed(let type):
      return type.description.isEmpty ? "Timeline" : type.description
    case nil: return "Catbird"
    }
  }

  // MARK: - Keyboard

  private func handleEscape() -> KeyPress.Result {
    if let item = selectedItem, let path = navigationPaths[item], !path.isEmpty {
      var mutablePath = path
      mutablePath.removeLast()
      navigationPaths[item] = mutablePath
      return .handled
    }
    return .ignored
  }
}
#endif
