#if os(iOS)
import Testing
import UIKit
import CoreFoundation
@testable import Catbird

@Suite(.serialized)
@MainActor
struct ImageSharePresentationOriginTests {
  @Test func competingWindowsKeepTheirOwnPresenter() throws {
    let first = makeWindow()
    let second = makeWindow()
    defer { first.isHidden = true; second.isHidden = true }
    let firstSource = UIView()
    let secondSource = UIView()
    first.rootViewController?.view.addSubview(firstSource)
    second.rootViewController?.view.addSubview(secondSource)

    let firstOrigin = try #require(ImageSharePresentationOrigin(sourceView: firstSource))
    let secondOrigin = try #require(ImageSharePresentationOrigin(sourceView: secondSource))
    let firstContext = try #require(firstOrigin.resolve())
    let secondContext = try #require(secondOrigin.resolve())

    #expect(firstContext.presenter === first.rootViewController)
    #expect(secondContext.presenter === second.rootViewController)
    #expect(firstContext.sourceView === firstSource)
    #expect(secondContext.sourceView === secondSource)
  }

  @Test func nearestOwningControllerPresentsWithinItsWindow() throws {
    let window = makeWindow()
    defer { window.isHidden = true }
    let root = try #require(window.rootViewController)
    let child = UIViewController()
    root.addChild(child)
    root.view.addSubview(child.view)
    child.didMove(toParent: root)
    let source = UIView()
    child.view.addSubview(source)

    let origin = try #require(ImageSharePresentationOrigin(sourceView: source))
    #expect(origin.resolve()?.presenter === child)
  }

  @Test func movedSourceCannotPresentInEitherWindow() throws {
    let first = makeWindow()
    let second = makeWindow()
    defer { first.isHidden = true; second.isHidden = true }
    let source = UIView()
    first.rootViewController?.view.addSubview(source)
    let origin = try #require(ImageSharePresentationOrigin(sourceView: source))

    source.removeFromSuperview()
    #expect(origin.resolve() == nil)
    second.rootViewController?.view.addSubview(source)
    #expect(origin.resolve() == nil)
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
    for _ in 0..<20 {
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

  private func retireSource(in window: UIWindow, root: UIViewController,
                            captureOrigin: Bool) throws
    -> (probe: RetirementProbe, origin: ImageSharePresentationOrigin?) {
    try autoreleasepool {
      try #require(root.viewIfLoaded?.window === window)
      let source = UIView()
      let probe = RetirementProbe(source)
      root.view.addSubview(source)
      defer { source.removeFromSuperview() }
      try #require(source.superview === root.view)
      try #require(source.window === window)
      let origin: ImageSharePresentationOrigin?
      if captureOrigin {
        let captured = try #require(ImageSharePresentationOrigin(sourceView: source))
        try #require(captured.resolve()?.sourceView === source)
        try #require(captured.resolve()?.presenter === root)
        origin = captured
      } else {
        origin = nil
      }
      source.removeFromSuperview()
      try #require(source.superview == nil)
      try #require(source.window == nil)
      return (probe, origin)
    }
  }

  @Test func originDoesNotKeepRemovedViewAlive() async throws {
    let window = makeWindow()
    defer { window.isHidden = true }
    let root = try #require(window.rootViewController)
    root.view.layoutIfNeeded()
    try #require(root.viewIfLoaded?.window === window)
    let control = try retireSource(in: window, root: root, captureOrigin: false)
    let captured = try retireSource(in: window, root: root, captureOrigin: true)
    let origin = try #require(captured.origin)

    #expect(origin.resolve() == nil)
    await settleRetirement(control.probe, captured.probe)
    try #require(root.viewIfLoaded?.window === window)
    #expect(control.probe.isReleased, "UIKit control view still retained: \(control.probe.identity)")
    #expect(captured.probe.isReleased, "Origin view still retained: \(captured.probe.identity)")
    #expect(origin.resolve() == nil)
  }

  @Test func detachedAndHiddenOriginsCannotPresent() throws {
    #expect(ImageSharePresentationOrigin(sourceView: UIView()) == nil)
    let window = makeWindow()
    let source = UIView()
    window.rootViewController?.view.addSubview(source)
    let origin = try #require(ImageSharePresentationOrigin(sourceView: source))

    window.isHidden = true
    #expect(origin.resolve() == nil)
  }

  @Test func resizingKeepsOriginAndUsesCurrentAnchorBounds() throws {
    let window = makeWindow()
    defer { window.isHidden = true }
    let source = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    window.rootViewController?.view.addSubview(source)
    let origin = try #require(ImageSharePresentationOrigin(sourceView: source))

    window.frame.size.width = 700
    source.frame.size.width = 640
    let context = try #require(origin.resolve())
    #expect(context.sourceView === source)
    #expect(context.presenter === window.rootViewController)
    #expect(context.sourceView.bounds.width == 640)
  }

  private func makeWindow() -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = UIViewController()
    window.isHidden = false
    return window
  }
}
#endif
