#if targetEnvironment(macCatalyst)
import UIKit

final class CatalystSceneDelegate: NSObject, UIWindowSceneDelegate {
  /// Shared coordinator — accessed by the bridge modifier to wire up closures
  static var activeCoordinator: CatalystToolbarCoordinator?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let titlebar = windowScene.titlebar else { return }

    let coordinator = CatalystToolbarCoordinator()
    CatalystSceneDelegate.activeCoordinator = coordinator

    titlebar.titleVisibility = .hidden
    titlebar.toolbarStyle = .unified
    titlebar.toolbar = coordinator.nsToolbar
  }
}
#endif
