#if os(iOS)
import Petrel
import SwiftUI
import UIKit

// MARK: - SwiftUI Integration
@available(iOS 18.0, *)
struct ThreadViewControllerRepresentable: UIViewControllerRepresentable {
  @Environment(AppState.self) private var appState: AppState
  let postURI: ATProtocolURI
  @Binding var path: NavigationPath
  let visibilityContext: PostVisibilityContext

  init(
    postURI: ATProtocolURI,
    path: Binding<NavigationPath>,
    visibilityContext: PostVisibilityContext = .public
  ) {
    self.postURI = postURI
    self._path = path
    self.visibilityContext = visibilityContext
  }

  func makeUIViewController(context: Context) -> ThreadViewController {
    let controller = ThreadViewController(
      appState: appState,
      postURI: postURI,
      path: $path,
      visibilityContext: visibilityContext
    )
    context.coordinator.lastSortOrder = appState.appSettings.threadSortOrder
    context.coordinator.lastThreadedReplies = appState.appSettings.threadedReplies
    return controller
  }
  func updateUIViewController(_ uiViewController: ThreadViewController, context: Context) {
    let currentSort = appState.appSettings.threadSortOrder
    let currentThreaded = appState.appSettings.threadedReplies

    if !context.coordinator.lastSortOrder.isEmpty && context.coordinator.lastSortOrder != currentSort {
      uiViewController.reloadThreadFromSettingsChange()
    }
    context.coordinator.lastSortOrder = currentSort

    if context.coordinator.lastThreadedReplies != currentThreaded {
      context.coordinator.lastThreadedReplies = currentThreaded
      uiViewController.rebuildReplyCellsFromLayoutChange()
    }
  }

  static func dismantleUIViewController(_ uiViewController: ThreadViewController, coordinator: Coordinator) {
    uiViewController.tearDown()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator {
    var lastSortOrder: String = ""
    var lastThreadedReplies: Bool = false
  }
}
#endif
