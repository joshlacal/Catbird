#if os(macOS)
import OSLog
import Petrel
import SwiftUI

/// Top-level macOS view replacing TabView. Uses NavigationSplitView with a unified
/// sidebar (functional items + feeds) and a detail pane routed by SidebarItem selection.
struct MacOSMainView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.openWindow) private var openWindow

  @State private var selectedItem: SidebarItem? = .feed(.timeline)
  @State private var navigationPaths: [SidebarItem: NavigationPath] = [:]
  @State private var newConversationRecipient: NewConversationRecipient?

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSMainView")

  var body: some View {
    mainSplitView
      .frame(minWidth: 900, minHeight: 600)
      .onKeyPress(.escape) { handleEscape() }
      .background { keyboardShortcutButtons }
      .modifier(MacOSDeepLinkHandlers(selectedItem: $selectedItem, appState: appState))
      .onChange(of: sceneContext.navigationManager.pendingNewConversationRecipient) { _, recipient in
        guard let recipient else { return }
        sceneContext.navigationManager.pendingNewConversationRecipient = nil
        newConversationRecipient = recipient
      }
      .sheet(item: $newConversationRecipient) { recipient in
        PlatformAgeProtectedContent(operation: .directMessaging) {
          NewConversationView(preselectedRecipient: recipient)
        }
        .frame(minWidth: 450, minHeight: 500)
      }
  }

  private var mainSplitView: some View {
    NavigationSplitView {
      MacOSUnifiedSidebar(selection: $selectedItem)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      MacOSDetailRouter(
        selection: selectedItem,
        navigationPaths: $navigationPaths
      )
    }
    .navigationSplitViewStyle(.balanced)
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
    case .search:
      return String(localized: "Search", comment: "macOS window title for Search section.")
    case .notifications:
      return String(localized: "Notifications", comment: "macOS window title for Notifications section.")
    case .chat:
      return String(localized: "Chat", comment: "macOS window title for Chat section.")
    case .profile:
      return String(localized: "Profile", comment: "macOS window title for Profile section.")
    case .feed(let type):
      return type.description.isEmpty
        ? String(localized: "Timeline", comment: "macOS window title for Timeline feed.")
        : type.description
    case nil:
      return String(localized: "Catbird", comment: "macOS window title when no sidebar item is selected.")
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
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Binding var selectedItem: SidebarItem?
  let appState: AppState

  func body(content: Content) -> some View {
    content
      .onChange(of: sceneContext.navigationManager.targetConversationId) { _, newValue in
        if newValue != nil {
          selectedItem = .chat
        }
      }
      .onChange(of: sceneContext.navigationManager.targetMLSConversationId) { _, newValue in
        if newValue != nil {
          selectedItem = .chat
        }
      }
  }
}
#endif
