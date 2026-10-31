import Foundation
import XCTest
import Petrel
@testable import Catbird

final class SceneRouteCoordinatorTests: XCTestCase {
  @MainActor
  private func makeAccount(_ suffix: String) async -> AppState {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    return AppState(userDID: "did:plc:scene-\(suffix)", client: client)
  }

  private func route(_ account: String, sceneID: UUID? = nil, tab: Int = 1) -> SceneRouteRequest {
    SceneRouteRequest(accountDID: account, destination: .hashtag("scene-route"), tabIndex: tab,
                      preferredSceneID: sceneID)
  }

  @MainActor
  func testRegistrationWaitsForActivationAndDeliversOnce() async {
    let account = await makeAccount("first")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    let request = route(account.userDID)
    XCTAssertEqual(coordinator.submit(request), .queued)
    XCTAssertEqual(coordinator.submit(request), .duplicate)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
    coordinator.register(scene)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
  }

  @MainActor
  func testExplicitInactiveTargetNeverFallsBackToAnotherActiveWindow() async {
    let account = await makeAccount("same")
    let first = SceneNavigationContext(appState: account, sceneID: UUID())
    let second = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(first)
    coordinator.register(second)
    coordinator.setActive(sceneID: second.sceneID, isActive: true)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: first.sceneID)), .queued)
    XCTAssertEqual(second.navigationManager.tabPaths[1]?.count, 0)
    coordinator.setActive(sceneID: first.sceneID, isActive: true)
    XCTAssertEqual(first.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(second.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testAccountMismatchQueuesUntilSameWindowRegistersCorrectAccount() async {
    let firstAccount = await makeAccount("old")
    let secondAccount = await makeAccount("new")
    let sceneID = UUID()
    let old = SceneNavigationContext(appState: firstAccount, sceneID: sceneID)
    let replacement = SceneNavigationContext(appState: secondAccount, sceneID: sceneID)
    let other = SceneNavigationContext(appState: secondAccount, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(old)
    coordinator.register(other)
    coordinator.setActive(sceneID: sceneID, isActive: true)
    coordinator.setActive(sceneID: other.sceneID, isActive: true)
    XCTAssertEqual(coordinator.submit(route(secondAccount.userDID, sceneID: sceneID)), .queued)
    coordinator.register(replacement)
    XCTAssertTrue(old.isInvalidated)
    XCTAssertEqual(replacement.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(other.navigationManager.tabPaths[1]?.count, 0)
    coordinator.setActive(sceneID: sceneID, isActive: true)
    XCTAssertEqual(replacement.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(old.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testUntargetedRouteSelectsMostRecentlyFocusedMatchingAccount() async {
    let account = await makeAccount("matching")
    let foreignAccount = await makeAccount("foreign")
    let first = SceneNavigationContext(appState: account, sceneID: UUID())
    let second = SceneNavigationContext(appState: account, sceneID: UUID())
    let foreign = SceneNavigationContext(appState: foreignAccount, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    for scene in [first, second, foreign] {
      coordinator.register(scene)
      coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    }
    coordinator.register(first)
    coordinator.setActive(sceneID: first.sceneID, isActive: true)
    XCTAssertEqual(coordinator.submit(route(account.userDID)), .delivered(sceneID: second.sceneID))
    coordinator.markFocused(sceneID: first.sceneID)
    XCTAssertEqual(coordinator.submit(route(account.userDID)), .delivered(sceneID: first.sceneID))
    XCTAssertEqual(first.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(second.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(foreign.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testInactiveHistoricalTargetCanBeCapturedButCannotReceiveUntilActive() async {
    let account = await makeAccount("capture")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    XCTAssertNil(coordinator.preferredSceneIDForExternalEvent())
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    coordinator.setActive(sceneID: scene.sceneID, isActive: false)
    let target = coordinator.preferredSceneIDForExternalEvent()
    XCTAssertEqual(target, scene.sceneID)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: target)), .queued)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
  }

  @MainActor
  func testDisconnectionDropsTargetedQueueAndRejectsLaterStaleTarget() async {
    let account = await makeAccount("disconnect")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    var reasons: [SceneRouteCoordinator.DropReason] = []
    let coordinator = SceneRouteCoordinator(onDrop: { _, reason in reasons.append(reason) })
    coordinator.register(scene)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: scene.sceneID)), .queued)
    coordinator.disconnect(sceneID: scene.sceneID)
    XCTAssertTrue(scene.isInvalidated)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: scene.sceneID)),
                   .dropped(reason: .sceneDisconnected))
    XCTAssertEqual(reasons, [.sceneDisconnected, .sceneDisconnected])
  }

  @MainActor
  func testRegistryDoesNotKeepSceneAliveAndDoesNotRetargetItsPendingRoute() async {
    let account = await makeAccount("weak")
    let sceneID = UUID()
    let coordinator = SceneRouteCoordinator()
    weak var weakScene: SceneNavigationContext?
    do {
      let scene = SceneNavigationContext(appState: account, sceneID: sceneID)
      weakScene = scene
      coordinator.register(scene)
    }
    XCTAssertNil(weakScene)
    let other = SceneNavigationContext(appState: account, sceneID: UUID())
    coordinator.register(other)
    coordinator.setActive(sceneID: other.sceneID, isActive: true)
    XCTAssertEqual(coordinator.submit(route(account.userDID, sceneID: sceneID)), .queued)
    XCTAssertEqual(coordinator.registeredSceneCount, 1)
    XCTAssertEqual(other.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testExpiredQueueCannotDeliverWhenWindowBecomesActive() async {
    let account = await makeAccount("expiry")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    var clock: TimeInterval = 10
    var drops: [UUID] = []
    let coordinator = SceneRouteCoordinator(now: { clock }, onDrop: { request, reason in
      XCTAssertEqual(reason, .expired)
      drops.append(request.id)
    })
    coordinator.register(scene)
    let request = route(account.userDID)
    XCTAssertEqual(coordinator.submit(request), .queued)
    clock += SceneRouteCoordinator.pendingTTL
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(drops, [request.id])
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
  }

  @MainActor
  func testCapacityEvictsOldestAndPreservesFIFOForSurvivingRoutes() async {
    let account = await makeAccount("capacity")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    var dropped: [UUID] = []
    var deliveredTabs: [Int] = []
    let coordinator = SceneRouteCoordinator(onDrop: { request, reason in
      XCTAssertEqual(reason, .capacityExceeded)
      dropped.append(request.id)
    })
    coordinator.register(scene)
    scene.navigationManager.registerTabSelectionCallback { deliveredTabs.append($0) }
    let requests = (0...SceneRouteCoordinator.maxPendingRequests).map {
      SceneRouteRequest(accountDID: account.userDID, command: .showTab($0 % 5, resetPath: false))
    }
    for request in requests { XCTAssertEqual(coordinator.submit(request), .queued) }
    XCTAssertEqual(coordinator.pendingRequestCount, SceneRouteCoordinator.maxPendingRequests)
    XCTAssertEqual(dropped, [requests[0].id])
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(deliveredTabs, requests.dropFirst().map { $0.command.tabIndex })
  }

  @MainActor
  func testAccountDiscardPreservesOtherAccountQueue() async {
    let firstAccount = await makeAccount("discard")
    let secondAccount = await makeAccount("keep")
    let scene = SceneNavigationContext(appState: secondAccount, sceneID: UUID())
    var dropped: [UUID] = []
    let coordinator = SceneRouteCoordinator(onDrop: { request, reason in
      XCTAssertEqual(reason, .accountDiscarded)
      dropped.append(request.id)
    })
    let firstRequest = route(firstAccount.userDID)
    XCTAssertEqual(coordinator.submit(firstRequest), .queued)
    XCTAssertEqual(coordinator.submit(route(secondAccount.userDID)), .queued)
    coordinator.discardPending(forAccountDID: firstAccount.userDID)
    XCTAssertEqual(dropped, [firstRequest.id])
    coordinator.register(scene)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
  }

  @MainActor
  func testShowTabResetsOnlyRequestedScenePath() async {
    let account = await makeAccount("show-tab")
    let first = SceneNavigationContext(appState: account, sceneID: UUID())
    let second = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    for scene in [first, second] {
      scene.navigationManager.navigate(to: .hashtag("existing"), in: 0)
      coordinator.register(scene)
      coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    }
    let request = SceneRouteRequest(accountDID: account.userDID, command: .showTab(0, resetPath: true),
                                    preferredSceneID: first.sceneID)
    XCTAssertEqual(coordinator.submit(request), .delivered(sceneID: first.sceneID))
    XCTAssertEqual(first.navigationManager.tabPaths[0]?.count, 0)
    XCTAssertEqual(second.navigationManager.tabPaths[0]?.count, 1)
  }

  @MainActor
  func testSelectionCallbackCanDisconnectWithoutReceivingDestination() async {
    let account = await makeAccount("callback-close")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    scene.navigationManager.registerTabSelectionCallback { _ in
      coordinator.disconnect(sceneID: scene.sceneID)
    }
    XCTAssertEqual(coordinator.submit(route(account.userDID)), .dropped(reason: .sceneUnavailable))
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testDrainingRemovesRequestBeforeReentrantActivationCallback() async {
    let account = await makeAccount("reentrant")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    var deliveries = 0
    scene.navigationManager.registerTabSelectionCallback { _ in
      deliveries += 1
      coordinator.setActive(sceneID: scene.sceneID, isActive: true)
      XCTAssertEqual(coordinator.pendingRequestCount, 0)
    }
    XCTAssertEqual(coordinator.submit(route(account.userDID)), .queued)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(deliveries, 1)
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)
  }

  @MainActor
  func testSameRequestResubmittedInsideSelectionCallbackIsDuplicate() async {
    let account = await makeAccount("reentrant-same-request")
    let scene = SceneNavigationContext(appState: account, sceneID: UUID())
    let coordinator = SceneRouteCoordinator()
    coordinator.register(scene)
    var request = route(account.userDID)
    var reentrantResults: [SceneRouteCoordinator.DeliveryResult] = []
    var hasResubmitted = false
    scene.navigationManager.registerTabSelectionCallback { _ in
      guard !hasResubmitted else { return }
      hasResubmitted = true
      reentrantResults.append(coordinator.submit(request))
    }
    XCTAssertEqual(coordinator.submit(request), .queued)
    coordinator.setActive(sceneID: scene.sceneID, isActive: true)
    XCTAssertEqual(reentrantResults, [.duplicate])
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 1)

    request = route(account.userDID)
    hasResubmitted = false
    XCTAssertEqual(coordinator.submit(request), .delivered(sceneID: scene.sceneID))
    XCTAssertEqual(reentrantResults, [.duplicate, .duplicate])
    XCTAssertEqual(scene.navigationManager.tabPaths[1]?.count, 2)
  }
}
