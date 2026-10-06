#if DEBUG && os(iOS)
import Petrel
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Runs in the real Catbird test host with production window/context owners.
/// Container resizing and two UIWindows below share one OS scene. A separate
/// iPad launch of --scene-runtime-ui-fixture must qualify actual scene sessions.
@MainActor
final class SceneRuntimeHostingTests: XCTestCase {
  func testProductionWindowRootRetainsContextPathEditorAndViewportAcrossResize() async throws {
    try requireUnauthenticatedHost()
    let account = await makeAccount()
    let capture = OwnerCapture()
    let host = try makeHost(
      AnyView(CatbirdWindowRoot(
        appStateManager: .shared, onOpenURL: { _, _ in }, onAccountReady: { _ in }
      ) { scene in
        SceneRuntimeFixture(scene: scene, account: account)
          .onChange(of: ObjectIdentifier(scene), initial: true) { _, _ in capture.owner = scene }
      }.environment(\.scenePhase, .active)), size: CGSize(width: 390, height: 844)
    )
    defer {
      finish(capture.owner, account: account)
      host.dispose()
    }
    let owner = try await waitForOwner(capture, host: host)
    let context = try XCTUnwrap(owner.context)
    let editor = context.composerEditingSession
    let viewport = SceneRuntimeFixture.viewport(in: context)
    let claim = try SceneRuntimeFixture.seed(context)
    let draft = try XCTUnwrap(editor.currentDraft)
    let anchor = try XCTUnwrap(viewport.getScrollAnchor())
    await settle([host])
    try assertRenderedMarker(in: host)
    try captureSnapshot(host, owner: owner, name: "before-container-resize")

    for (name, size) in [
      ("narrow", CGSize(width: 320, height: 700)),
      ("wide", CGSize(width: 744, height: 520)),
      ("tall", CGSize(width: 600, height: 900))
    ] {
      host.container.resize(to: size)
      await settle([host])
      XCTAssertTrue(capture.owner === owner, name)
      XCTAssertTrue(owner.context === context, name)
      XCTAssertFalse(context.isInvalidated, name)
      XCTAssertTrue(context.composerEditingSession === editor, name)
      XCTAssertTrue(SceneRuntimeFixture.viewport(in: context) === viewport, name)
      XCTAssertEqual(context.navigationManager.currentTabIndex, 1, name)
      XCTAssertEqual(context.navigationManager.tabPaths[1]?.count, 1, name)
      XCTAssertEqual(editor.activeClaim, claim, name)
      XCTAssertEqual(editor.currentDraft, draft, name)
      XCTAssertEqual(viewport.getScrollAnchor()?.postID, anchor.postID, name)
      XCTAssertEqual(viewport.getScrollAnchor()?.offsetFromTop, anchor.offsetFromTop, name)
      XCTAssertEqual(host.controller.view.bounds.width, size.width, accuracy: 0.5, name)
      XCTAssertEqual(host.controller.view.bounds.height, size.height, accuracy: 0.5, name)
      try assertRenderedMarker(in: host)
      try captureSnapshot(host, owner: owner, name: name)
    }
  }

  func testTwoHostedWindowsShareAccountButKeepTabPathEditorAndViewportIndependent() async throws {
    try requireUnauthenticatedHost()
    let account = await makeAccount()
    let coordinator = SceneRouteCoordinator()
    let first = makeOwner(coordinator: coordinator)
    let second = makeOwner(coordinator: coordinator)
    let firstHost = try makeHost(
      AnyView(SceneRuntimeFixture(scene: first, account: account)),
      size: CGSize(width: 390, height: 760)
    )
    let secondHost = try makeHost(
      AnyView(SceneRuntimeFixture(scene: second, account: account)),
      size: CGSize(width: 600, height: 640)
    )
    defer {
      finish(first, account: account, cleanupAccount: false)
      finish(second, account: account)
      firstHost.dispose()
      secondHost.dispose()
    }
    try await waitForContexts([first, second], hosts: [firstHost, secondHost])
    first.attach(to: firstHost.window, presenter: firstHost.controller)
    second.attach(to: secondHost.window, presenter: secondHost.controller)
    first.updatePhase(.active)
    second.updatePhase(.active)
    let firstContext = try XCTUnwrap(first.context)
    let secondContext = try XCTUnwrap(second.context)
    let firstClaim = try SceneRuntimeFixture.seed(firstContext)
    let secondClaim = try SceneRuntimeFixture.seed(secondContext)
    let secondDraft = try XCTUnwrap(secondContext.composerEditingSession.currentDraft)
    let secondAnchor = try XCTUnwrap(SceneRuntimeFixture.viewport(in: secondContext).getScrollAnchor())

    firstContext.navigationManager.updateCurrentTab(3)
    _ = firstContext.urlHandler.handle(URL(string: "tag://first-window-only")!, tabIndex: 3)
    XCTAssertTrue(firstContext.composerEditingSession.update(
      SceneRuntimeFixture.makeDraft("First window edited"), claim: firstClaim
    ))
    SceneRuntimeFixture.viewport(in: firstContext).setScrollAnchor(.init(
      postID: "first-window-post-80", offsetFromTop: 81, timestamp: Date()
    ))
    firstHost.container.resize(to: CGSize(width: 744, height: 520))
    await settle([firstHost, secondHost])

    XCTAssertTrue(firstHost.window.windowScene === secondHost.window.windowScene,
      "This test intentionally covers two windows in one OS scene, not two scene sessions")
    XCTAssertEqual(firstContext.accountDID, secondContext.accountDID)
    XCTAssertNotEqual(first.sceneID, second.sceneID)
    XCTAssertNotEqual(firstContext.activityRegistrationID, secondContext.activityRegistrationID)
    XCTAssertFalse(firstContext.navigationManager === secondContext.navigationManager)
    XCTAssertFalse(firstContext.composerEditingSession === secondContext.composerEditingSession)
    XCTAssertFalse(SceneRuntimeFixture.viewport(in: firstContext) === SceneRuntimeFixture.viewport(in: secondContext))
    XCTAssertEqual(firstContext.navigationManager.currentTabIndex, 3)
    XCTAssertEqual(firstContext.navigationManager.tabPaths[3]?.count, 1)
    XCTAssertEqual(secondContext.navigationManager.currentTabIndex, 1)
    XCTAssertEqual(secondContext.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(secondContext.navigationManager.tabPaths[3]?.count, 0)
    XCTAssertEqual(secondContext.composerEditingSession.activeClaim, secondClaim)
    XCTAssertEqual(secondContext.composerEditingSession.currentDraft, secondDraft)
    XCTAssertEqual(SceneRuntimeFixture.viewport(in: secondContext).getScrollAnchor()?.postID, secondAnchor.postID)
    XCTAssertEqual(SceneRuntimeFixture.viewport(in: secondContext).getScrollAnchor()?.offsetFromTop, secondAnchor.offsetFromTop)
    try assertRenderedMarker(in: firstHost)
    try assertRenderedMarker(in: secondHost)
    try captureSnapshot(firstHost, owner: first, name: "first-window-after-independent-edit")
    try captureSnapshot(secondHost, owner: second, name: "second-window-preserved")
  }

  func testOwnerDisconnectRejectsQueuedURLRouteShareAndEditorWithoutChangingOtherWindow() async throws {
    try requireUnauthenticatedHost()
    let account = await makeAccount()
    let coordinator = SceneRouteCoordinator()
    let first = makeOwner(coordinator: coordinator)
    let second = makeOwner(coordinator: coordinator)
    let firstHost = try makeHost(AnyView(SceneRuntimeFixture(scene: first, account: account)))
    let secondHost = try makeHost(AnyView(SceneRuntimeFixture(scene: second, account: account)))
    defer {
      finish(first, account: account, cleanupAccount: false)
      finish(second, account: account)
      firstHost.dispose()
      secondHost.dispose()
    }
    try await waitForContexts([first, second], hosts: [firstHost, secondHost])
    first.attach(to: firstHost.window, presenter: firstHost.controller)
    second.attach(to: secondHost.window, presenter: secondHost.controller)
    first.updatePhase(.active)
    second.updatePhase(.active)
    let firstContext = try XCTUnwrap(first.context)
    let secondContext = try XCTUnwrap(second.context)
    let firstClaim = try SceneRuntimeFixture.seed(firstContext)
    let secondClaim = try SceneRuntimeFixture.seed(secondContext)
    let secondDraft = secondContext.composerEditingSession.currentDraft
    let firstShare = try makeShare(for: firstContext)
    let secondShare = try makeShare(for: secondContext)
    PendingChatShareStore.shared.stage(firstShare)
    PendingChatShareStore.shared.stage(secondShare)
    first.setPresentationAttached(false)
    let queued = SceneRouteRequest(
      accountDID: account.userDID, destination: .hashtag("queued-for-closing-window"),
      tabIndex: 1, preferredSceneID: first.sceneID
    )
    XCTAssertEqual(coordinator.submit(queued), .queued)
    XCTAssertEqual(coordinator.pendingRequestCount, 1)
    let handler = firstContext.urlHandler
    let retainedNavigation = handler.navigateAction
    // No suspension before disconnect: the queued URL's main-actor task has
    // not delivered. This calls the lifetime owner, not an OS scene close.
    _ = handler.handle(URL(string: "bluesky://video-feed")!, tabIndex: 1)
    first.disconnect()
    retainedNavigation?(.hashtag("retained-after-disconnect"), 1)
    let handledAfterClose = await handler.handleURL(URL(string: "tag://after-disconnect")!, tabIndex: 1)
    await settle([firstHost, secondHost])

    XCTAssertTrue(first.isDisconnected)
    XCTAssertNil(first.context)
    XCTAssertTrue(firstContext.isInvalidated)
    XCTAssertFalse(handledAfterClose)
    XCTAssertEqual(firstContext.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(coordinator.pendingRequestCount, 0)
    XCTAssertEqual(coordinator.registeredSceneCount, 1)
    XCTAssertEqual(coordinator.submit(queued), .dropped(reason: .sceneDisconnected))
    XCTAssertFalse(firstContext.composerEditingSession.update(
      SceneRuntimeFixture.makeDraft("Late editor write"), claim: firstClaim
    ))
    XCTAssertNil(PendingChatShareStore.shared.peek(
      sceneID: first.sceneID, accountDID: account.userDID, convoId: firstShare.convoId
    ))
    XCTAssertNil(PendingChatShareStore.shared.consume(
      sceneID: first.sceneID, accountDID: account.userDID,
      convoId: firstShare.convoId, expectedID: firstShare.id
    ))
    XCTAssertFalse(secondContext.isInvalidated)
    XCTAssertEqual(secondContext.navigationManager.tabPaths[1]?.count, 1)
    XCTAssertEqual(secondContext.composerEditingSession.activeClaim, secondClaim)
    XCTAssertEqual(secondContext.composerEditingSession.currentDraft, secondDraft)
    XCTAssertEqual(PendingChatShareStore.shared.peek(
      sceneID: second.sceneID, accountDID: account.userDID, convoId: secondShare.convoId
    )?.id, secondShare.id)
    try captureSnapshot(secondHost, owner: second, name: "surviving-window-after-owner-disconnect")
  }

  private func requireUnauthenticatedHost() throws {
    guard AppStateManager.shared.lifecycle.appState == nil else {
      throw FixtureError.authenticatedHost
    }
  }

  private func makeAccount() async -> AppState {
    await SceneRuntimeFixture.makeAccount(did: "did:plc:scene-runtime-\(UUID().uuidString.lowercased())")
  }

  private func makeOwner(coordinator: SceneRouteCoordinator) -> SceneWindowState {
    SceneWindowState(coordinator: coordinator, feedActivity: SceneFeedActivityRegistration(
      register: { _, _ in }, update: { _, _ in }, unregister: { _ in }
    ))
  }

  private func makeShare(for context: SceneNavigationContext) throws -> PendingChatShare {
    PendingChatShare(
      originSceneID: context.sceneID, accountDID: context.accountDID,
      convoId: "offline-\(context.sceneID.uuidString)",
      postRef: ComAtprotoRepoStrongRef(
        uri: try ATProtocolURI(uriString: "at://did:plc:sceneruntimefixturetesta/app.bsky.feed.post/scene1"),
        cid: CID.fromDAGCBOR(Data("scene-runtime-fixture".utf8))
      ),
      previewEmbed: ChatSharedPostPreview(authorDisplayName: "Offline", authorHandle: "offline.test", text: "Unsent share")
    )
  }

  private func makeHost(_ view: AnyView, size: CGSize = CGSize(width: 390, height: 760)) throws -> Host {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    return Host(scene: scene, view: view, size: size)
  }

  private func waitForOwner(_ capture: OwnerCapture, host: Host) async throws -> SceneWindowState {
    for _ in 0..<100 {
      if let owner = capture.owner, owner.context != nil { return owner }
      host.container.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    return try XCTUnwrap(capture.owner?.context == nil ? nil : capture.owner)
  }

  private func waitForContexts(_ owners: [SceneWindowState], hosts: [Host]) async throws {
    for _ in 0..<100 {
      if owners.allSatisfy({ $0.context != nil }) { return }
      for host in hosts { host.container.view.layoutIfNeeded() }
      try await Task.sleep(for: .milliseconds(20))
    }
    for owner in owners { _ = try XCTUnwrap(owner.context) }
  }

  private func settle(_ hosts: [Host]) async {
    for _ in 0..<8 {
      for host in hosts {
        host.container.view.setNeedsLayout()
        host.container.view.layoutIfNeeded()
        host.controller.view.layoutIfNeeded()
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func assertRenderedMarker(in host: Host) throws {
    let navigation = controllers(in: host.controller).compactMap { $0 as? UINavigationController }
      .first { $0.navigationBar.topItem?.title == "Scene marker" }
    XCTAssertNotNil(navigation, "The production host must render the pushed local destination")
    XCTAssertEqual(try XCTUnwrap(navigation).viewControllers.count, 2)
  }

  private func controllers(in controller: UIViewController) -> [UIViewController] {
    [controller] + controller.children.flatMap { controllers(in: $0) }
  }

  private func captureSnapshot(_ host: Host, owner: SceneWindowState, name: String) throws {
    let image = UIGraphicsImageRenderer(bounds: host.controller.view.bounds).image { _ in
      XCTAssertTrue(host.controller.view.drawHierarchy(in: host.controller.view.bounds, afterScreenUpdates: true))
    }
    let screenshot = XCTAttachment(image: image)
    screenshot.name = "scene-runtime-\(name)"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let context = try XCTUnwrap(owner.context)
    let receipt = """
    scene=\(owner.sceneID); context=\(context.activityRegistrationID)
    actualOSSession=\(host.window.windowScene?.session.persistentIdentifier ?? "none")
    receivingBounds=\(host.controller.view.bounds); windowBounds=\(host.window.bounds)
    tab=\(context.navigationManager.currentTabIndex); pathCount=\(context.navigationManager.tabPaths[context.navigationManager.currentTabIndex]?.count ?? 0)
    claim=\(context.composerEditingSession.activeClaim?.token.uuidString ?? "none")
    draft=\(context.composerEditingSession.currentDraft?.postText ?? "none")
    anchor=\(SceneRuntimeFixture.viewport(in: context).getScrollAnchor()?.postID ?? "none")
    Boundary: hosted production ownership/presentation with local route leaves; receiving-container resize, not OS window resizing. Other test windows share this OS session. No authenticated feed, real composer visual, account transition, or OS scene destruction claim.
    """
    let metadata = XCTAttachment(string: receipt)
    metadata.name = "scene-runtime-\(name)-identity"
    metadata.lifetime = .keepAlways
    add(metadata)
  }

  private func finish(_ owner: SceneWindowState?, account: AppState, cleanupAccount: Bool = true) {
    if let owner {
      let context = owner.context
      if let session = context?.composerEditingSession, let claim = session.activeClaim {
        _ = session.discard(claim: claim)
      }
      owner.disconnect()
      // Remove only this fixture account/window's recovery envelope, including
      // the envelope preserved by a context already disconnected in the test.
      UserDefaults.standard.removeObject(forKey: SceneComposerEditingSession.persistenceKey(
        sceneID: owner.sceneID, accountDID: account.userDID
      ))
    }
    if cleanupAccount { account.cleanup() }
  }

  private enum FixtureError: Error { case authenticatedHost }
  @MainActor
  private final class OwnerCapture { var owner: SceneWindowState? }

  @MainActor
  private final class Host {
    let controller: UIHostingController<AnyView>
    let container: ResizingContainer
    let window: UIWindow

    init(scene: UIWindowScene, view: AnyView, size: CGSize) {
      controller = UIHostingController(rootView: view)
      container = ResizingContainer(child: controller, size: size)
      window = UIWindow(windowScene: scene)
      window.rootViewController = container
      window.isHidden = false
      container.view.layoutIfNeeded()
    }

    func dispose() {
      window.isHidden = true
      window.rootViewController = nil
    }
  }

  private final class ResizingContainer: UIViewController {
    let child: UIViewController
    private var size: CGSize

    init(child: UIViewController, size: CGSize) {
      self.child = child
      self.size = size
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
      super.viewDidLoad()
      addChild(child)
      view.addSubview(child.view)
      child.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      child.view.frame = CGRect(origin: .zero, size: size)
    }

    func resize(to size: CGSize) {
      self.size = size
      view.setNeedsLayout()
      view.layoutIfNeeded()
    }
  }
}
#endif
