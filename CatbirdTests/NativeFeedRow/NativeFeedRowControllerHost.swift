#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

// MARK: - Feed Controller Host

/// The production feed controller showing `posts` in a window, as `FeedHeaderEnvironmentTests` hosts it.
@MainActor
final class NativeFeedRowControllerHost {
  let controller: FeedCollectionViewControllerIntegrated
  let window: UIWindow
  private let state: FeedStateManager
  private let sceneContext: SceneNavigationContext
  private let previousKeyWindow: UIWindow?

  init(appState: AppState, posts: [CachedFeedViewPost], width: CGFloat = 402) throws {
    sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    let viewport = sceneContext.feedViewportStore.state(
      accountDID: appState.userDID, feedIdentifier: FetchType.timeline.identifier)
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    model.posts = posts
    state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline, initialScenePhase: .background)
    state.hasReachedEnd = true
    controller = FeedCollectionViewControllerIntegrated(
      stateManager: state, viewportState: viewport, sceneContext: sceneContext,
      navigationPath: .constant(NavigationPath()))
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
    window.rootViewController = controller
    controller.loadViewIfNeeded()
    controller.collectionView.isPrefetchingEnabled = false
    window.isHidden = false
  }

  func tearDown() {
    let becameKey = window.isKeyWindow
    window.isHidden = true
    window.rootViewController = nil
    state.cleanup()
    sceneContext.invalidate()
    if becameKey { previousKeyWindow?.makeKey() }
  }

  /// Waits until the feed's first post is on screen in a cell of type `Cell`, and returns it.
  @discardableResult
  func waitForPostCell<Cell: UICollectionViewCell>(
    _ type: Cell.Type, where condition: (Cell) -> Bool = { _ in true }
  ) async throws -> Cell? {
    let deadline = ContinuousClock.now + .seconds(5)
    var current: UICollectionViewCell?
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      current = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
      if let cell = current as? Cell, condition(cell) { return cell }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The post's cell is \(current.map { String(describing: Swift.type(of: $0)) } ?? "missing"), not the expected \(Cell.self)")
    return nil
  }
}
#endif
