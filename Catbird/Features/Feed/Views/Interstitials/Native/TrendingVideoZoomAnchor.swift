#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Zoom Anchor

/// The zoom transition into The Vids needs a SwiftUI `matchedTransitionSource`. When the user
/// opens a video, the native cell mounts this anchor over the tapped thumbnail (or the "Open The
/// Vids" label), drawing a snapshot of it, then routes with the anchor's namespace, so the source
/// exists for the push and for the zoom back. Building one small hosted view at tap time keeps
/// scrolling free of SwiftUI.
@available(iOS 18.0, *)
struct TrendingVideoZoomAnchor: View {
  let snapshot: UIImage?
  let postURI: String?
  let cornerRadius: CGFloat
  let onReady: @MainActor (Namespace.ID) -> Void

  @Namespace private var namespace
  @State private var announced = false

  var body: some View {
    content
      .videoFeedZoomSource(postURI: postURI, namespace: namespace, cornerRadius: cornerRadius)
      .accessibilityHidden(true)
      .onAppear {
        guard !announced else { return }
        announced = true
        let namespace = namespace
        // SwiftUI resolves the zoom source when the push starts, and a source registers once it
        // has been rendered. Routing from the first `onAppear` would find nothing and zoom from
        // the screen center (in both directions), so wait until the anchor has been on screen.
        Task { @MainActor in
          await DisplayFrameWaiter.frames(2)
          onReady(namespace)
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if let snapshot {
      Image(uiImage: snapshot).resizable()
    } else {
      Color.clear
    }
  }
}

/// Suspends until the display has refreshed `count` times.
@MainActor
final class DisplayFrameWaiter: NSObject {
  private var link: CADisplayLink?
  private var remaining: Int
  private var continuation: CheckedContinuation<Void, Never>?

  private init(count: Int) {
    remaining = max(1, count)
  }

  static func frames(_ count: Int) async {
    let waiter = DisplayFrameWaiter(count: count)
    await withCheckedContinuation { continuation in
      waiter.continuation = continuation
      let link = CADisplayLink(target: waiter, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      waiter.link = link
    }
  }

  @objc private func tick() {
    remaining -= 1
    guard remaining == 0 else { return }
    link?.invalidate()
    link = nil
    continuation?.resume()
    continuation = nil
  }
}

/// Owns the one mounted anchor of a cell. A new tap replaces it; reuse removes it.
@MainActor
final class TrendingVideoZoomAnchorHost {
  private var controller: UIViewController?
  private var restore: (() -> Void)?
  /// Advances on every mount and removal, so a replaced or removed anchor never routes.
  private var generation = 0

  /// Mounts a fresh anchor over `source` showing a snapshot of it, hides the source's own drawing
  /// with `conceal` (the source stays interactive beneath the non-interactive anchor), and calls
  /// `navigate` once SwiftUI has rendered the anchor. The anchor is a child hosting controller of
  /// `parent`, so it joins the view controller hierarchy like the feed's other hosted content.
  @available(iOS 18.0, *)
  func mount(
    over source: UIView, in parent: UIViewController, postURI: String?, cornerRadius: CGFloat,
    conceal: @escaping (Bool) -> Void,
    navigate: @escaping @MainActor (Namespace.ID) -> Void
  ) {
    remove()
    guard let container = source.superview else { return }
    let current = generation
    let route: @MainActor (Namespace.ID) -> Void = { [weak self] namespace in
      guard let self, self.generation == current, self.controller != nil else { return }
      navigate(namespace)
    }
    let snapshot = UIGraphicsImageRenderer(bounds: source.bounds).image { _ in
      _ = source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
    }
    let controller = UIHostingController(rootView: TrendingVideoZoomAnchor(
      snapshot: snapshot, postURI: postURI, cornerRadius: cornerRadius, onReady: route))
    controller.sizingOptions = []
    controller.safeAreaRegions = []
    controller.view.backgroundColor = .clear
    controller.view.isUserInteractionEnabled = false
    controller.view.frame = source.frame
    parent.addChild(controller)
    container.insertSubview(controller.view, aboveSubview: source)
    controller.didMove(toParent: parent)
    conceal(true)
    self.controller = controller
    restore = { conceal(false) }
  }

  func remove() {
    generation += 1
    if let controller {
      controller.willMove(toParent: nil)
      controller.view.removeFromSuperview()
      controller.removeFromParent()
    }
    controller = nil
    restore?()
    restore = nil
  }

  /// Removes the anchor when the view holding it is recycled for other content.
  func remove(ifIn view: UIView) {
    guard let anchorView = controller?.view, anchorView.isDescendant(of: view) else { return }
    remove()
  }
}
#endif
