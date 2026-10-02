#if os(iOS)
import Testing
import UIKit
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

  @Test func originDoesNotKeepRemovedViewAlive() throws {
    let window = makeWindow()
    defer { window.isHidden = true }
    var source: UIView? = UIView()
    weak var weakSource = source
    window.rootViewController?.view.addSubview(try #require(source))
    let origin = try #require(source.flatMap { ImageSharePresentationOrigin(sourceView: $0) })

    source?.removeFromSuperview()
    source = nil
    #expect(weakSource == nil)
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
