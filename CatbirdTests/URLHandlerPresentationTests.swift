#if os(iOS)
import UIKit
import CoreFoundation
import Testing
import Petrel
@testable import Catbird

@Suite(.serialized)
@MainActor
struct URLHandlerPresentationTests {
  private func makeWindow(root suppliedRoot: UIViewController? = nil,
                          scene: UIWindowScene? = nil) -> UIWindow {
    let root = suppliedRoot ?? UIViewController()
    let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window: UIWindow
    if let scene {
      window = UIWindow(windowScene: scene)
      window.frame = frame
    } else {
      window = UIWindow(frame: frame)
    }
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

  private func retireWindow(root: UIViewController, scene: UIWindowScene,
                            anchor: SceneBrowserPresentationAnchor? = nil) throws -> RetirementProbe {
    try autoreleasepool {
      let window = self.makeWindow(root: root, scene: scene)
      let probe = RetirementProbe(window)
      defer {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
      }
      try #require(window.windowScene === scene)
      try #require(root.viewIfLoaded?.window === window)
      anchor?.register(controller: root)
      if let anchor {
        try #require(anchor.attachedWindow === window)
      }
      window.isHidden = true
      window.rootViewController = nil
      // Hiding removes visibility; nil removes membership in the native scene.
      window.windowScene = nil
      try #require(window.windowScene == nil)
      try #require(root.viewIfLoaded?.window == nil)
      return probe
    }
  }

  @MainActor
  private final class IdleBoundaryWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: CFRunLoopObserver?
    private var timeout: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
      self.continuation = continuation
    }

    func start() {
      let observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
      ) { [self] _, _ in
        // This observer is installed only on the main run loop.
        MainActor.assumeIsolated { self.finish(reachedIdle: true) }
      }!
      self.observer = observer
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      let timeout = DispatchWorkItem { [self] in
        // This work item is submitted only to the main queue.
        MainActor.assumeIsolated { self.finish(reachedIdle: false) }
      }
      self.timeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func finish(reachedIdle: Bool) {
      guard let continuation else { return }
      self.continuation = nil
      if let observer {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
      }
      timeout?.cancel()
      timeout = nil
      continuation.resume(returning: reachedIdle)
    }
  }

  private func settleRetirement(_ probes: RetirementProbe...) async {
    // Main-queue dispatch alone need not reach UIKit's run-loop cleanup.
    // Each idle-boundary wait has a wall timeout and removes its observer.
    // Clearing a window's root controller runs a root dismissal whose completion
    // (which holds the window) waits for the render server to acknowledge a CA
    // commit, so the settle bound is wall time, not a count of run-loop turns.
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      let reachedIdle = await withCheckedContinuation { continuation in
        IdleBoundaryWaiter(continuation).start()
      }
      guard reachedIdle else {
        Issue.record("Main run loop did not reach its idle cleanup boundary within one second")
        return
      }
      if probes.allSatisfy({ $0.isReleased }) { return }
    }
  }

  @Test func retiredFeedControllerPreservesOriginWindow() async throws {
    let root = UIViewController()
    let window = makeWindow(root: root)
    let controlRoot = UIViewController()
    let controlWindow = makeWindow(root: controlRoot)
    defer { window.isHidden = true; controlWindow.isHidden = true }
    try #require(root.viewIfLoaded?.window === window)
    try #require(controlRoot.viewIfLoaded?.window === controlWindow)
    let anchor = SceneBrowserPresentationAnchor()
    let control = retireFeed(in: controlRoot)
    let retiredFeed = retireFeed(in: root, anchor: anchor)
    try #require(anchor.attachedWindow === window)

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

  @Test func anchorDoesNotRetainWindowOrFollowRetiredOrigin() async throws {
    let root = UIViewController()
    let controlRoot = UIViewController()
    let anchor = SceneBrowserPresentationAnchor()
    let scene = try #require(UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let control = try retireWindow(root: controlRoot, scene: scene)
    let retiredWindow = try retireWindow(root: root, scene: scene, anchor: anchor)
    let replacement = makeWindow(root: root, scene: scene)
    let controlReplacement = makeWindow(root: controlRoot, scene: scene)
    defer {
      replacement.isHidden = true
      replacement.rootViewController = nil
      replacement.windowScene = nil
      controlReplacement.isHidden = true
      controlReplacement.rootViewController = nil
      controlReplacement.windowScene = nil
    }
    try #require(root.viewIfLoaded?.window === replacement)
    try #require(controlRoot.viewIfLoaded?.window === controlReplacement)

    // Reject following the reused controller even while UIKit may retain the
    // old window; eventual deallocation is a separate lifetime contract.
    #expect(anchor.attachedWindow == nil)
    await settleRetirement(control, retiredWindow)
    try #require(root.viewIfLoaded?.window === replacement)
    try #require(controlRoot.viewIfLoaded?.window === controlReplacement)
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
