import Foundation
import XCTest
import Petrel
@testable import Catbird

final class SceneNavigationContextTests: XCTestCase {
  @MainActor
  private func makeAppState(_ did: String = "did:plc:scenecontext123456789") async -> AppState {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    return AppState(userDID: did, client: client)
  }

  @MainActor
  func testTwoScenesKeepNavigationAndTransientRequestsIndependent() async {
    let appState = await makeAppState()
    let first = SceneNavigationContext(appState: appState, sceneID: UUID())
    let second = SceneNavigationContext(appState: appState, sceneID: UUID())
    first.navigationManager.updateCurrentTab(1)
    second.navigationManager.updateCurrentTab(3)

    _ = first.urlHandler.handle(URL(string: "tag://first-scene")!)
    _ = second.urlHandler.handle(URL(string: "mention://second-scene")!)
    first.pendingSearchRequest = AppState.SearchRequest(query: "first query")
    first.tabTappedAgain = 1
    first.presentPostComposer(initialText: "Only in the first scene")

    XCTAssertFalse(first.navigationManager === second.navigationManager)
    XCTAssertFalse(first.urlHandler === second.urlHandler)
    XCTAssertFalse(first.urlHandler.externalIntentPresenter === second.urlHandler.externalIntentPresenter)
    XCTAssertEqual(first.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(first.navigationManager.tabPaths[3]?.count, 0)
    XCTAssertEqual(second.navigationManager.tabPaths[3]?.count, 1)
    XCTAssertEqual(second.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertNil(second.pendingSearchRequest)
    XCTAssertNil(second.tabTappedAgain)
    XCTAssertNil(second.postComposerRequest)
    XCTAssertEqual(first.postComposerRequest?.initialText, "Only in the first scene")
  }

  @MainActor
  func testOriginSceneAndTabStayStableAcrossQueuedURLResolution() async {
    let appState = await makeAppState()
    let first = SceneNavigationContext(appState: appState, sceneID: UUID())
    let second = SceneNavigationContext(appState: appState, sceneID: UUID())
    first.navigationManager.updateCurrentTab(1)
    second.navigationManager.updateCurrentTab(2)
    let delivered = expectation(description: "Origin scene receives its queued URL")
    let originalAction = first.urlHandler.navigateAction
    first.urlHandler.navigateAction = { destination, tabIndex in
      originalAction?(destination, tabIndex)
      XCTAssertEqual(tabIndex, 1)
      delivered.fulfill()
    }

    _ = first.urlHandler.handle(URL(string: "bluesky://video-feed")!)
    first.navigationManager.updateCurrentTab(4)
    _ = second.urlHandler.handle(URL(string: "tag://second-scene")!)

    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(first.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(first.navigationManager.tabPaths[4]?.count, 0)
    XCTAssertEqual(second.navigationManager.tabPaths[2]?.count, 1)
    XCTAssertEqual(second.navigationManager.tabPaths[1]?.count, 0)
  }

  @MainActor
  func testInvalidatingScenePreventsQueuedURLAndComposerDelivery() async {
    let appState = await makeAppState()
    let context = SceneNavigationContext(appState: appState, sceneID: UUID())
    let handler = context.urlHandler
    context.navigationManager.updateCurrentTab(1)
    context.pendingSearchRequest = AppState.SearchRequest(query: "discard")
    context.tabTappedAgain = 1
    context.presentPostComposer(initialText: "discard")
    _ = handler.handle(URL(string: "bluesky://video-feed")!)

    let retainedAction = handler.navigateAction
    context.invalidate()
    let staleDelivery = expectation(description: "Invalidated URL cannot deliver")
    staleDelivery.isInverted = true
    handler.navigateAction = { _, _ in staleDelivery.fulfill() }
    retainedAction?(.hashtag("retained-callback"), 1)
    let afterInvalidation = await handler.handleURL(URL(string: "tag://after-invalidation")!)
    await fulfillment(of: [staleDelivery], timeout: 0.1)
    context.presentPostComposer(initialText: "must not reopen")

    XCTAssertTrue(context.isInvalidated)
    XCTAssertFalse(afterInvalidation)
    XCTAssertEqual(context.navigationManager.tabPaths[1]?.count, 0)
    XCTAssertNil(context.pendingSearchRequest)
    XCTAssertNil(context.tabTappedAgain)
    XCTAssertNil(context.postComposerRequest)
  }

  @MainActor
  func testConfiguredHandlerDoesNotRetainSceneNavigationManager() async {
    let appState = await makeAppState()
    let handler = URLHandler()
    let otherScene = SceneNavigationContext(appState: appState, sceneID: UUID())
    var manager: AppNavigationManager? = AppNavigationManager()
    weak var weakManager: AppNavigationManager?
    weakManager = manager
    handler.configure(with: appState, navigationManager: manager!)

    manager = nil

    XCTAssertNil(weakManager)
    _ = handler.handle(URL(string: "tag://orphan")!)
    XCTAssertEqual(otherScene.navigationManager.tabPaths[0]?.count, 0)
  }

  @MainActor
  func testReconfiguringHandlerCannotMoveAnOlderQueuedURLToNewScene() async {
    let appState = await makeAppState()
    let handler = URLHandler()
    let firstManager = AppNavigationManager()
    let secondManager = AppNavigationManager()
    firstManager.updateCurrentTab(1)
    secondManager.updateCurrentTab(2)
    handler.configure(with: appState, navigationManager: firstManager)
    _ = handler.handle(URL(string: "bluesky://video-feed")!)

    handler.configure(with: appState, navigationManager: secondManager)
    let currentAction = handler.navigateAction
    let staleDelivery = expectation(description: "Earlier configuration cannot deliver")
    staleDelivery.isInverted = true
    handler.navigateAction = { destination, tabIndex in
      if destination == .videoFeed { staleDelivery.fulfill() }
      currentAction?(destination, tabIndex)
    }
    let currentHandled = await handler.handleURL(URL(string: "tag://current-context")!)
    await fulfillment(of: [staleDelivery], timeout: 0.1)

    XCTAssertTrue(currentHandled)
    XCTAssertEqual(firstManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(secondManager.tabPaths[1]?.count, 0)
    XCTAssertEqual(secondManager.tabPaths[2]?.count, 1)
  }

  @MainActor
  func testReconfigurationRetiresPreviousIntentPresentationAndDedupe() async {
    let oldAccount = await makeAppState("did:plc:old-intent-account")
    let newAccount = await makeAppState("did:plc:new-intent-account")
    let handler = URLHandler()
    let oldManager = AppNavigationManager()
    let newManager = AppNavigationManager()
    handler.configure(with: oldAccount, navigationManager: oldManager)
    let presenter = handler.externalIntentPresenter
    presenter.activeIntent = .verifyEmail(code: "old-active")
    presenter.pendingIntent = .groupChatJoin(code: "old-pending")
    presenter.lastDeliveredURL = "bluesky://chat/old-pending"

    handler.configure(with: newAccount, navigationManager: newManager)

    XCTAssertNil(presenter.activeIntent)
    XCTAssertNil(presenter.pendingIntent)
    XCTAssertNil(presenter.lastDeliveredURL)
    presenter.activeIntent = .compose(text: "invalidated")
    presenter.pendingIntent = .verifyEmail(code: "invalidated")
    presenter.lastDeliveredURL = "bluesky://intent/compose"
    handler.invalidate()
    XCTAssertNil(presenter.activeIntent)
    XCTAssertNil(presenter.pendingIntent)
    XCTAssertNil(presenter.lastDeliveredURL)
  }
}
