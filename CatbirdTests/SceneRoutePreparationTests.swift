import Foundation
import XCTest
import Petrel
@testable import Catbird

final class SceneRoutePreparationTests: XCTestCase {
  @MainActor
  private func makeAccount(_ suffix: String) async -> AppState {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    return AppState(userDID: "did:plc:prepare-\(suffix)", client: client)
  }

  private func route(_ did: String, sceneID: UUID? = nil) -> SceneRouteRequest {
    SceneRouteRequest(accountDID: did, destination: .hashtag("prepared"), tabIndex: 1,
                      preferredSceneID: sceneID)
  }

  @MainActor
  func testImmediatePreparationRunsOnceInMatchingSceneBeforeSelectionAndNavigation() async {
    let account = await makeAccount("match")
    let foreignAccount = await makeAccount("foreign")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let foreign = SceneNavigationContext(appState: foreignAccount, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    for context in [scene, foreign] {
      coordinator.register(context)
      coordinator.setActive(sceneID: context.sceneID, isActive: true)
    }
    var events: [String] = []
    scene.navigationManager.registerTabSelectionCallback { _ in events.append("selected") }
    let result = coordinator.submit(route(account.userDID)) { receivingScene in
      XCTAssertTrue(receivingScene === scene)
      XCTAssertEqual(receivingScene.navigationManager.currentTabIndex, 0)
      XCTAssertEqual(receivingScene.navigationManager.tabPaths[1]?.count, 0)
      events.append("prepared")
      return true
    }
    XCTAssertEqual(result, .delivered(sceneID: scene.sceneID))
    XCTAssertEqual(events, ["prepared", "selected"])
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(foreign.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testQueuedPreparationWaitsForExactTargetAndRejectsReentrantDuplicate() async {
    let account = await makeAccount("queued")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let other = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(other)
    coordinator.setActive(sceneID: other.sceneID, isActive: true)
    let request = route(account.userDID, sceneID: scene.sceneID)
    var callbackCount = 0
    XCTAssertEqual(coordinator.submit(request) { context in
      callbackCount += 1
      XCTAssertTrue(context === scene)
      XCTAssertEqual(coordinator.pendingRequestCount, 0)
      XCTAssertEqual(coordinator.submit(request) { _ in
        XCTFail("Duplicate preparation must not run")
        return true
      }, .duplicate)
      return true
    }, .queued)
    XCTAssertEqual(callbackCount, 0)
    coordinator.register(scene)
    XCTAssertEqual(callbackCount, 0)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    coordinator.markFocused(sceneID: scene.sceneID)
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(other.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testRejectedPreparationDoesNotSelectTabOrNavigate() async {
    let account = await makeAccount("reject")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    scene.navigationManager.registerTabSelectionCallback { _ in XCTFail("Must not select") }
    let result = coordinator.submit(route(account.userDID)) { _ in false }
    XCTAssertEqual(result, .dropped(reason: .preparationRejected))
    XCTAssertEqual(scene.navigationManager.currentTabIndex, 0)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testDisconnectBeforeDeliveryNeverRunsPreparation() async {
    let account = await makeAccount("disconnect")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: scene.sceneID)) { _ in
      XCTFail("Disconnected scene must not prepare")
      return true
    }, .queued)
    coordinator.disconnect(sceneID: scene.sceneID)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testPreparationInvalidationPreventsTabSelectionAndNavigation() async {
    let account = await makeAccount("invalidate")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    let result = coordinator.submit(route(account.userDID)) { context in
      context.invalidate()
      return true
    }
    XCTAssertEqual(result, .dropped(reason: .sceneUnavailable))
    XCTAssertEqual(scene.navigationManager.currentTabIndex, 0)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testPreparationReplacementCannotRedirectIntoReplacementContext() async {
    let account = await makeAccount("replace")
    let sceneID = UUID()
    let old = SceneNavigationContext(appState: account, sceneID: sceneID)
    let replacement = SceneNavigationContext(appState: account, sceneID: sceneID)
    let coordinator = SceneRouteCoordinator()
    coordinator.register(old)
    coordinator.setActive(sceneID: sceneID, isActive: true)
    let result = coordinator.submit(route(account.userDID, sceneID: sceneID)) { _ in
      coordinator.register(replacement)
      coordinator.setActive(sceneID: sceneID, isActive: true)
      return true
    }
    XCTAssertEqual(result, .dropped(reason: .sceneUnavailable))
    XCTAssertEqual(old.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(replacement.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testExpiredAndDiscardedRequestsDoNotRunPreparation() async {
    let account = await makeAccount("expired")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    var clock: TimeInterval = 0
    let coordinator = SceneRouteCoordinator(now: { clock })
    coordinator.register(scene)
    XCTAssertEqual(coordinator.submit(route(account.userDID)) { _ in
      XCTFail("Expired request must not prepare")
      return true
    }, .queued)
    clock = SceneRouteCoordinator.pendingTTL
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    coordinator.setActive(sceneID: scene.sceneID, isActive: false)
    XCTAssertEqual(coordinator.submit(route(account.userDID)) { _ in
      XCTFail("Discarded request must not prepare")
      return true
    }, .queued)
    coordinator.discardPending(forAccountDID: account.userDID)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
  }
}
