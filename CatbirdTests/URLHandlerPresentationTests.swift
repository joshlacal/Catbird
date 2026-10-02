#if os(iOS)
import UIKit
import Testing
import Petrel
@testable import Catbird

@Suite(.serialized)
@MainActor
struct URLHandlerPresentationTests {
  private func makeWindow(root suppliedRoot: UIViewController? = nil) -> UIWindow {
    let root = suppliedRoot ?? UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = root
    window.isHidden = false
    root.view.layoutIfNeeded()
    return window
  }

  private func resolvedController(in window: UIWindow) -> UIViewController? {
    if case .ready(let controller) = SceneBrowserPresentationAnchor.resolvePresenter(in: window) {
      return controller
    }
    return nil
  }

  @Test func retiredFeedControllerPreservesOriginWindow() {
    let root = UIViewController()
    let window = makeWindow(root: root)
    defer { window.isHidden = true }
    let anchor = SceneBrowserPresentationAnchor()
    var feed: UIViewController? = UIViewController()
    weak var retiredFeed = feed
    root.addChild(feed!)
    root.view.addSubview(feed!.view)
    feed!.didMove(toParent: root)
    anchor.register(controller: feed!)

    feed!.willMove(toParent: nil)
    feed!.view.removeFromSuperview()
    feed!.removeFromParent()
    feed = nil

    #expect(retiredFeed == nil)
    #expect(anchor.attachedWindow === window)
    #expect(resolvedController(in: window) === root)
  }

  @Test func twoAnchorsResolveOnlyTheirOwnWindows() {
    let first = makeWindow()
    let second = makeWindow()
    defer { first.isHidden = true; second.isHidden = true }
    let firstAnchor = SceneBrowserPresentationAnchor()
    let secondAnchor = SceneBrowserPresentationAnchor()
    firstAnchor.register(window: first)
    secondAnchor.register(window: second)
    #expect(firstAnchor.attachedWindow === first)
    #expect(secondAnchor.attachedWindow === second)
    #expect(resolvedController(in: first) === first.rootViewController)
    #expect(resolvedController(in: second) === second.rootViewController)
    firstAnchor.clear()
    #expect(firstAnchor.attachedWindow == nil)
    #expect(secondAnchor.attachedWindow === second)
  }

  @Test func followsSelectedTabAndVisibleNavigationController() {
    let first = UIViewController()
    let selected = UIViewController()
    let navigation = UINavigationController(rootViewController: selected)
    let tabs = UITabBarController()
    tabs.viewControllers = [first, navigation]
    tabs.selectedIndex = 1
    let window = makeWindow(root: tabs)
    defer { window.isHidden = true }
    #expect(resolvedController(in: window) === selected)
  }

  @Test func presentedSheetIsTheLocalPresenter() async {
    let window = makeWindow()
    defer { window.isHidden = true }
    let anchor = SceneBrowserPresentationAnchor()
    anchor.register(window: window)
    let sheet = UIViewController()
    sheet.modalPresentationStyle = .fullScreen
    await withCheckedContinuation { continuation in
      window.rootViewController!.present(sheet, animated: false) { continuation.resume() }
    }
    #expect(anchor.attachedWindow === window)
    #expect(resolvedController(in: window) === sheet)
    await withCheckedContinuation { continuation in
      sheet.dismiss(animated: false) { continuation.resume() }
    }
  }

  @Test func registrationBeforeAttachmentCapturesTheFirstWindow() {
    let root = UIViewController()
    let anchor = SceneBrowserPresentationAnchor()
    anchor.register(controller: root)
    #expect(anchor.attachedWindow == nil)
    let first = makeWindow(root: root)
    defer { first.isHidden = true }
    #expect(anchor.attachedWindow === first)
    first.rootViewController = UIViewController()
    let second = makeWindow(root: root)
    defer { second.isHidden = true }
    #expect(anchor.attachedWindow === first)
    #expect(anchor.attachedWindow !== second)
  }

  @Test func anchorDoesNotRetainWindowOrFollowRetiredOrigin() {
    let root = UIViewController()
    let anchor = SceneBrowserPresentationAnchor()
    var window: UIWindow? = makeWindow(root: root)
    weak var retiredWindow = window
    anchor.register(controller: root)
    window!.isHidden = true
    window!.rootViewController = nil
    window = nil
    let replacement = makeWindow(root: root)
    defer { replacement.isHidden = true }
    #expect(retiredWindow == nil)
    #expect(anchor.attachedWindow == nil)
  }

  @Test func unattachedAndHiddenWindowsHaveNoVisiblePresenter() {
    let anchor = SceneBrowserPresentationAnchor()
    let unattached = UIWindow(frame: .zero)
    anchor.register(window: unattached)
    #expect(anchor.attachedWindow == nil)
    #expect(resolvedController(in: unattached) == nil)
    let hidden = makeWindow()
    hidden.isHidden = true
    #expect(resolvedController(in: hidden) == nil)
  }

  @Test func reconfigurationClearsTheCapturedWindow() async {
    let handler = URLHandler()
    let window = makeWindow()
    window.isHidden = true
    handler.registerPresentationWindow(window)
    let url = URL(string: "https://example.org/scene-presentation-probe")!
    #expect(await handler.handleURL(url))
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let state = AppState(userDID: "did:plc:browserorigin123456789", client: client)
    let navigation = AppNavigationManager()
    handler.configure(with: state, navigationManager: navigation)
    #expect(await handler.handleURL(url) == false)
  }

  @Test func invalidationRejectsLateControllerAndWindowRegistration() async {
    let handler = URLHandler()
    let window = makeWindow()
    defer { window.isHidden = true }
    handler.registerPresentationWindow(window)
    handler.invalidate()
    handler.registerTopViewController(window.rootViewController!)
    handler.registerPresentationWindow(window)
    #expect(await handler.handleURL(URL(string: "https://example.org/stale-scene")!) == false)
  }

}
#endif
