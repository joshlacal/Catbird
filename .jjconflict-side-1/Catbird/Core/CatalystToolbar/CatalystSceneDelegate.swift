#if targetEnvironment(macCatalyst)
import UIKit
import OSLog

private let catalystLogger = Logger(subsystem: "blue.catbird", category: "CatalystSceneDelegate")

final class CatalystSceneDelegate: NSObject, UIWindowSceneDelegate {
  var window: UIWindow?

  /// The coordinator associated with this specific scene instance
  private(set) var coordinator: CatalystToolbarCoordinator?

  /// Shared coordinator — tracks the coordinator for the currently focused/active scene
  static var activeCoordinator: CatalystToolbarCoordinator?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let titlebar = windowScene.titlebar else { return }

    catalystLogger.debug("Scene will connect to session \(session.persistentIdentifier)")

    let coordinator = CatalystToolbarCoordinator()
    self.coordinator = coordinator
    CatalystSceneDelegate.activeCoordinator = coordinator

    titlebar.titleVisibility = .hidden
    titlebar.toolbarStyle = .unified
    titlebar.toolbar = coordinator.nsToolbar
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    catalystLogger.debug("Scene did become active")
    if let coordinator {
      CatalystSceneDelegate.activeCoordinator = coordinator
    }
  }

  func sceneWillResignActive(_ scene: UIScene) {
    catalystLogger.debug("Scene will resign active")
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    catalystLogger.debug("Scene will enter foreground")
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    catalystLogger.debug("Scene did enter background")
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    catalystLogger.debug("Scene did disconnect")
    if CatalystSceneDelegate.activeCoordinator === coordinator {
      // Find another active/connected scene coordinator if available
      CatalystSceneDelegate.activeCoordinator = UIApplication.shared.connectedScenes
        .compactMap { ($0.delegate as? CatalystSceneDelegate)?.coordinator }
        .first { $0 !== coordinator }
    }
    coordinator = nil
  }
}
#endif
