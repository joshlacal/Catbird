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

  @MainActor
  private final class RetirementProbe {
    weak var object: AnyObject?
    let identity: ObjectIdentifier

    init(_ object: AnyObject) {
      self.object = object
      self.identity = ObjectIdentifier(object)
    }

    var isReleased: Bool { autoreleasepool { self.object == nil } }
  }

  private func retireFeed(in root: UIViewController,
                          anchor: SceneBrowserPresentationAnchor? = nil) -> RetirementProbe {
    autoreleasepool {
      let feed = UIViewController()
      let probe = RetirementProbe(feed)
      root.addChild(feed)
      root.view.addSubview(feed.view)
      feed.didMove(toParent: root)
      anchor?.register(controller: feed)
      feed.willMove(toParent: nil)
      feed.view.removeFromSuperview()
      feed.removeFromParent()
      return probe
    }
  }

  private func retireWindow(root: UIViewController,
                            anchor: SceneBrowserPresentationAnchor? = nil) -> RetirementProbe {
    autoreleasepool {
      let window = self.makeWindow(root: root)
      let probe = RetirementProbe(window)
      anchor?.register(controller: root)
      window.isHidden = true
      window.rootViewController = nil
      return probe
    }
  }

  private func settleRetirement(_ probes: RetirementProbe...) async {
    // UIKit may enqueue containment/window cleanup and autoreleased objects.
    // Cross main-queue turns, checking only inside a drained local pool; do not
    // carry a strong reference obtained from a weak probe across suspension.
    for _ in 0..<20 {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
      }
      if probes.allSatisfy({ $0.isReleased }) { return }
    }
  }

  @Test func retiredFeedControllerPreservesOriginWindow() async {
    let root = UIViewController()
    let window = makeWindow(root: root)
    let controlRoot = UIViewController()
    let controlWindow = makeWindow(root: controlRoot)
    defer { window.isHidden = true; controlWindow.isHidden = true }
    let anchor = SceneBrowserPresentationAnchor()
    let control = retireFeed(in: controlRoot)
    let retiredFeed = retireFeed(in: root, anchor: anchor)

    await settleRetirement(control, retiredFeed)
    #expect(control.isReleased, "UIKit control feed still retained: \(control.identity)")
    #expect(retiredFeed.isReleased, "Anchored feed still retained: \(retiredFeed.identity)")
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

  @Test func anchorDoesNotRetainWindowOrFollowRetiredOrigin() async {
    let root = UIViewController()
    let controlRoot = UIViewController()
    let anchor = SceneBrowserPresentationAnchor()
    let control = retireWindow(root: controlRoot)
    let retiredWindow = retireWindow(root: root, anchor: anchor)
    let replacement = makeWindow(root: root)
    let controlReplacement = makeWindow(root: controlRoot)
    defer { replacement.isHidden = true; controlReplacement.isHidden = true }

    // Reject following the reused controller even while UIKit may retain the
    // old window; eventual deallocation is a separate lifetime contract.
    #expect(anchor.attachedWindow == nil)
    await settleRetirement(control, retiredWindow)
    #expect(control.isReleased, "UIKit control window still retained: \(control.identity)")
    #expect(retiredWindow.isReleased, "Anchored window still retained: \(retiredWindow.identity)")
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
