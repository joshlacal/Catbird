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
    mainSplitView
      .onKeyPress(.escape) { handleEscape() }
      .background { keyboardShortcutButtons }
      .modifier(MacOSDeepLinkHandlers(selectedItem: $selectedItem, appState: appState))
  }

  private var mainSplitView: some View {
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
    .toolbar {
      composeToolbarItem
      settingsToolbarItem
    }
  }

  // MARK: - Keyboard Shortcut Buttons (hidden, provide Cmd+key navigation)

  @ViewBuilder
  private var keyboardShortcutButtons: some View {
    Group {
      Button("Search") { selectedItem = .search }
        .keyboardShortcut("f", modifiers: .command)
      Button("Feeds") { selectedItem = .feed(.timeline) }
        .keyboardShortcut("1", modifiers: .command)
      Button("Notifications") { selectedItem = .notifications }
        .keyboardShortcut("2", modifiers: .command)
      Button("Chat") { selectedItem = .chat }
        .keyboardShortcut("3", modifiers: .command)
      Button("Profile") { selectedItem = .profile }
        .keyboardShortcut("4", modifiers: .command)
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .allowsHitTesting(false)
  }

  // MARK: - Toolbar Items

  private var composeToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        openWindow(id: "compose")
      } label: {
        Image(systemName: "pencil")
      }
      .tint(.accentColor)
      .keyboardShortcut("n", modifiers: .command)
      .help("New Post (Cmd+N)")
    }
  }

  private var settingsToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      SettingsAvatarToolbarButton {
        openWindow(id: "settings")
      }
      .keyboardShortcut(",", modifiers: .command)
      .help("Settings (Cmd+,)")
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

// MARK: - Deep Link Handlers Modifier

private struct MacOSDeepLinkHandlers: ViewModifier {
  @Binding var selectedItem: SidebarItem?
  let appState: AppState

  func body(content: Content) -> some View {
    content
      .onChange(of: appState.navigationManager.targetConversationId) { _, newValue in
        if newValue != nil {
          selectedItem = .chat
          appState.navigationManager.targetConversationId = nil
        }
      }
      .onChange(of: appState.navigationManager.targetMLSConversationId) { _, newValue in
        if newValue != nil {
          selectedItem = .chat
          appState.navigationManager.targetMLSConversationId = nil
        }
      }
  }
}
#endif
