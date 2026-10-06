import Petrel
import SwiftUI

// MARK: - Local Navigation

/// List screens normally push through the tab's `NavigationPath`. Inside Settings, whose stack
/// only accepts settings targets, they instead push with view-based destinations so every screen
/// stays inside the Settings sheet.
private struct ListsUseLocalNavigationKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var listsUseLocalNavigation: Bool {
    get { self[ListsUseLocalNavigationKey.self] }
    set { self[ListsUseLocalNavigationKey.self] = newValue }
  }
}

/// The list screens reachable with local navigation.
enum ListLocalDestination: Hashable {
  case detail(ATProtocolURI)
  case edit(ATProtocolURI)
  case members(ATProtocolURI)
}

extension View {
  /// Pushes `destination` onto the enclosing stack without touching its path.
  func listLocalNavigationDestination(_ destination: Binding<ListLocalDestination?>) -> some View {
    navigationDestination(item: destination) { target in
      ListLocalDestinationView(destination: target)
        .environment(\.listsUseLocalNavigation, true)
    }
  }
}

private struct ListLocalDestinationView: View {
  let destination: ListLocalDestination
  @State private var unusedPath = NavigationPath()

  var body: some View {
    switch destination {
    case .detail(let uri):
      ListDetailView(listURIString: uri.uriString(), path: $unusedPath)
        .id(uri.uriString())
    case .edit(let uri):
      EditListView(listURI: uri.uriString())
        .navigationTitle("Edit List")
        .modifier(InlineNavigationTitleModifier())
    case .members(let uri):
      ListMemberManagementView(listURI: uri.uriString())
        .id(uri.uriString())
    }
  }
}

private struct InlineNavigationTitleModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbarTitleDisplayMode(.inline)
    #else
    content
    #endif
  }
}
