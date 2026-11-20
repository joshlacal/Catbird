#if DEBUG && os(iOS)
import Petrel
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

@MainActor
final class TabSelectionViewUpdateTests: XCTestCase {
  func testWindowAnchorMountAndUpdateDeferRouteDeliveryOffViewUpdatePass() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let account = await SceneRuntimeFixture.makeAccount(
      did: "did:plc:tab-update-\(UUID().uuidString.lowercased())"
    )
    let coordinator = SceneRouteCoordinator()
    let owner = SceneWindowState(
      coordinator: coordinator,
      feedActivity: SceneFeedActivityRegistration(register: { _, _ in }, update: { _, _ in }, unregister: { _ in })
    )
    owner.updateAccount(account)
    owner.updatePhase(.active)
    let context = try XCTUnwrap(owner.context)

    var isInSwiftUIUpdatePass = false
    var firedDuringUpdatePass = false
    var deliveredTabs: [Int] = []
    context.navigationManager.registerTabSelectionCallback { newTab in
      if isInSwiftUIUpdatePass {
        firedDuringUpdatePass = true
      }
      deliveredTabs.append(newTab)
    }

    // Queue a route while the window anchor has not attached yet.
    let mountRequest = SceneRouteRequest(
      accountDID: account.userDID,
      command: .showTab(AppNavigationManager.chatTabIndex, resetPath: false),
      preferredSceneID: owner.sceneID
    )
    XCTAssertEqual(coordinator.submit(mountRequest), .queued)

    let controller = UIHostingController(rootView: AnyView(SceneWindowAnchor(owner: owner)))
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

    defer {
      owner.disconnect()
      account.cleanup()
      window.isHidden = true
      window.rootViewController = nil
    }

    // Initial mount (didMoveToWindow + first updateUIView) must not invoke tabSelection synchronously.
    isInSwiftUIUpdatePass = true
    window.rootViewController = controller
    window.isHidden = false
    controller.view.layoutIfNeeded()
    isInSwiftUIUpdatePass = false

    XCTAssertFalse(
      firedDuringUpdatePass,
      "SceneWindowAnchor mount must not synchronously drain routes during a SwiftUI view update pass"
    )

    for _ in 0..<50 where deliveredTabs.count < 1 {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(deliveredTabs, [AppNavigationManager.chatTabIndex])
    XCTAssertEqual(context.navigationManager.currentTabIndex, AppNavigationManager.chatTabIndex)

    // Detach the hosted view from the window; deferred didMoveToWindow(nil) must
    // mark presentation detached so subsequent routes queue rather than deliver.
    window.rootViewController = nil
    try await Task.sleep(for: .milliseconds(50))

    let updateRequest = SceneRouteRequest(
      accountDID: account.userDID,
      command: .showTab(2, resetPath: false),
      preferredSceneID: owner.sceneID
    )
    XCTAssertEqual(coordinator.submit(updateRequest), .queued)

    // Reattaching to the window during a layout pass must also defer route delivery.
    isInSwiftUIUpdatePass = true
    window.rootViewController = controller
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    isInSwiftUIUpdatePass = false

    XCTAssertFalse(
      firedDuringUpdatePass,
      "SceneWindowAnchor reattachment must not synchronously drain routes during a SwiftUI view update pass"
    )

    for _ in 0..<50 where deliveredTabs.count < 2 {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(deliveredTabs, [AppNavigationManager.chatTabIndex, 2])
    XCTAssertEqual(context.navigationManager.currentTabIndex, 2)
  }

  func testBindTabSelectionDefersBindingMutationAndConvergesToLatestTab() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let account = AppState(userDID: "did:plc:tab-bind-\(UUID().uuidString.lowercased())", client: client)
    let context = SceneNavigationContext(appState: account, sceneID: UUID())
    defer {
      context.invalidate()
      account.cleanup()
    }

    var selectedTab = 0
    var writeHistory: [Int] = []
    let binding = Binding<Int>(
      get: { selectedTab },
      set: { newValue in
        selectedTab = newValue
        writeHistory.append(newValue)
      }
    )

    MainContentView.bindTabSelection(context: context, selectedTab: binding)

    // Selecting the already-selected tab must not schedule or perform a state write.
    context.navigationManager.tabSelection?(0)
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(writeHistory, [])

    // Rapid consecutive selections must not write synchronously, and must converge
    // to the latest currentTabIndex once the deferred MainActor turn runs.
    context.navigationManager.tabSelection?(AppNavigationManager.chatTabIndex)
    XCTAssertEqual(selectedTab, 0, "Binding write must be deferred off the synchronous callback stack")
    XCTAssertEqual(context.navigationManager.currentTabIndex, AppNavigationManager.chatTabIndex)

    context.navigationManager.tabSelection?(2)
    XCTAssertEqual(selectedTab, 0, "Second selection must also stay deferred off the synchronous stack")
    XCTAssertEqual(context.navigationManager.currentTabIndex, 2)

    for _ in 0..<50 where selectedTab != 2 {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(selectedTab, 2)
    XCTAssertEqual(writeHistory, [2])
  }

  func testBindTabSelectionIgnoresDeferredMutationAfterContextInvalidation() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let account = AppState(userDID: "did:plc:tab-invalid-\(UUID().uuidString.lowercased())", client: client)
    let context = SceneNavigationContext(appState: account, sceneID: UUID())
    defer { account.cleanup() }

    var selectedTab = 0
    let binding = Binding<Int>(
      get: { selectedTab },
      set: { selectedTab = $0 }
    )

    MainContentView.bindTabSelection(context: context, selectedTab: binding)

    context.navigationManager.tabSelection?(AppNavigationManager.chatTabIndex)
    context.invalidate()

    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(selectedTab, 0)
  }
}
#endif
