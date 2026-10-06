import Petrel
import SwiftUI
import XCTest
@testable import Catbird

final class SceneWindowLifecycleTests: XCTestCase {
  @MainActor
  private func makeAccount(_ suffix: String) async -> AppState {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    return AppState(userDID: "did:plc:window-\(suffix)", client: client)
  }

  @MainActor
  private func makeWindow(sceneID: UUID = UUID(), coordinator: SceneRouteCoordinator) -> SceneWindowState {
    SceneWindowState(
      sceneID: sceneID, coordinator: coordinator,
      feedActivity: SceneFeedActivityRegistration(register: { _, _ in }, update: { _, _ in }, unregister: { _ in })
    )
  }

  @MainActor
  func testSameAccountAndViewAttachmentPreserveWindowContext() async throws {
    let coordinator = SceneRouteCoordinator()
    let window = makeWindow(coordinator: coordinator)
    let account = await makeAccount("stable")
    window.updateAccount(account)
    let context = try XCTUnwrap(window.context)
    window.updatePhase(.active)
    window.setPresentationAttached(true)
    window.updateAccount(account)
    window.setPresentationAttached(false)
    window.setPresentationAttached(true)
    XCTAssertTrue(window.context === context)
    XCTAssertFalse(context.isInvalidated)
    XCTAssertEqual(window.sceneID, context.sceneID)
    window.disconnect()
  }

  @MainActor
  func testAccountReplacementKeepsWindowIdentityAndRetiresOldContext() async throws {
    let window = makeWindow(coordinator: SceneRouteCoordinator())
    let oldAccount = await makeAccount("old")
    let newAccount = await makeAccount("new")
    window.updateAccount(oldAccount)
    let old = try XCTUnwrap(window.context)
    window.updateAccount(newAccount)
    let new = try XCTUnwrap(window.context)
    XCTAssertTrue(old.isInvalidated)
    XCTAssertEqual(new.sceneID, old.sceneID)
    XCTAssertNotEqual(new.activityRegistrationID, old.activityRegistrationID)
    XCTAssertNotEqual(new.accountDID, old.accountDID)
    window.disconnect()
  }

  @MainActor
  func testNewServiceContainerForSameAccountReplacesContext() async throws {
    let window = makeWindow(coordinator: SceneRouteCoordinator())
    let firstAccount = await makeAccount("same")
    let replacementAccount = await makeAccount("same")
    window.updateAccount(firstAccount)
    let old = try XCTUnwrap(window.context)
    window.updateAccount(replacementAccount)
    let replacement = try XCTUnwrap(window.context)
    XCTAssertTrue(old.isInvalidated)
    XCTAssertEqual(replacement.accountDID, old.accountDID)
    XCTAssertEqual(replacement.sceneID, old.sceneID)
    XCTAssertNotEqual(replacement.activityRegistrationID, old.activityRegistrationID)
    window.disconnect()
  }

  @MainActor
  func testTransientDetachQueuesButActualCloseDropsTargetedRoutes() async throws {
    let coordinator = SceneRouteCoordinator()
    let window = makeWindow(coordinator: coordinator)
    let account = await makeAccount("detach")
    window.updateAccount(account)
    window.updatePhase(.active)
    window.setPresentationAttached(true)
    window.setPresentationAttached(false)
    let context = try XCTUnwrap(window.context)
    let route = SceneRouteRequest(
      accountDID: account.userDID, destination: .hashtag("window-test"), tabIndex: 1,
      preferredSceneID: window.sceneID
    )
    XCTAssertEqual(coordinator.submit(route), .queued)
    XCTAssertFalse(context.isInvalidated)
    window.setPresentationAttached(true)
    XCTAssertEqual(context.navigationManager.tabPaths[1]?.count, 1)
    window.disconnect()
    XCTAssertTrue(context.isInvalidated)
    XCTAssertEqual(coordinator.submit(SceneRouteRequest(
      accountDID: account.userDID, destination: .hashtag("closed"), tabIndex: 1,
      preferredSceneID: window.sceneID
    )), .dropped(reason: .sceneDisconnected))
    window.updateAccount(account)
    XCTAssertNil(window.context)
  }

  @MainActor
  func testPersistedIdentityCanBeRecreatedWithoutSharingOtherWindowsState() async throws {
    let account = await makeAccount("restore")
    let persistedID = UUID()
    let restored = makeWindow(sceneID: persistedID, coordinator: SceneRouteCoordinator())
    let other = makeWindow(coordinator: SceneRouteCoordinator())
    restored.updateAccount(account)
    other.updateAccount(account)
    XCTAssertEqual(restored.context?.sceneID, persistedID)
    XCTAssertNotEqual(other.sceneID, persistedID)
    XCTAssertFalse(restored.context?.navigationManager === other.context?.navigationManager)
    restored.disconnect()
    XCTAssertFalse(try XCTUnwrap(other.context).isInvalidated)
    other.disconnect()
  }
}
