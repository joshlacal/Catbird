#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Opt-in, synthetic-fixture-only observation. Never requests layout or changes
/// scrolling. All observation is confined to the offline debug fixture.
@MainActor
struct ModerationFixtureViewportProbe: UIViewRepresentable {
  let targetPostID: String

  func makeUIView(context: Context) -> ProbeView { ProbeView(targetPostID: targetPostID) }
  func updateUIView(_ uiView: ProbeView, context: Context) {}

  final class ProbeView: UIView {
    private let targetPostID: String
    private var displayLink: CADisplayLink?
    private var events: [[String: Any]] = []
    private var nextSequence = 0
    private var previousGeometry = Data()
    private var cellTokens: [ObjectIdentifier: Int] = [:]
    private weak var observedCell: FeedPostCollectionViewCell?
    private let started = CACurrentMediaTime()

    init(targetPostID: String) {
      self.targetPostID = targetPostID
      super.init(frame: .zero)
      isAccessibilityElement = true
      accessibilityIdentifier = "moderation.fixture.geometry"
      accessibilityLabel = "Synthetic feed geometry trace"
      backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      guard window != nil else { return }
      let link = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    @MainActor
    private final class DisplayTarget: NSObject {
      weak var view: ProbeView?
      init(_ view: ProbeView) { self.view = view }
      @objc func tick() { view?.record("display") }
    }

    private func collection(in view: UIView) -> UICollectionView? {
      if let collection = view as? UICollectionView { return collection }
      for child in view.subviews {
        if let result = collection(in: child) { return result }
      }
      return nil
    }

    private func rectangle(_ rect: CGRect) -> [String: CGFloat] {
      ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    private func activeGeometryAnimationKeys(in layer: CALayer) -> [String] {
      if layer is CAReplicatorLayer
        || layer.delegate is UIActivityIndicatorView
        || layer.delegate is UIRefreshControl {
        return []
      }
      var found: [String] = []
      if let keys = layer.animationKeys() {
        for key in keys where key != "opacity" && key != "contents" && key != "instanceAlphaOffset" {
          found.append("\(type(of: layer)):\(key)")
        }
      }
      for sublayer in layer.sublayers ?? [] {
        found.append(contentsOf: activeGeometryAnimationKeys(in: sublayer))
      }
      return found
    }

    private func record(_ event: String) {
      guard let window, let collection = collection(in: window) else { return }
      for visible in collection.visibleCells.compactMap({ $0 as? FeedPostCollectionViewCell })
      where visible.postID != targetPostID && visible.accessibilityIdentifier == "moderation.fixture.outerCell" {
        visible.accessibilityIdentifier = nil
      }
      let cell = collection.visibleCells.compactMap { $0 as? FeedPostCollectionViewCell }
        .first { $0.postID == targetPostID }
      let inset = collection.adjustedContentInset
      let minimum = -inset.top
      let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + inset.bottom)
      var geometry: [String: Any] = [
        "offsetY": collection.contentOffset.y,
        "contentHeight": collection.contentSize.height,
        "bounds": rectangle(collection.bounds),
        "collectionWindow": rectangle(collection.convert(collection.bounds, to: window)),
        "insetTop": collection.contentInset.top, "insetBottom": collection.contentInset.bottom,
        "adjustedTop": inset.top, "adjustedBottom": inset.bottom,
        "minimumOffsetY": minimum, "maximumOffsetY": maximum,
        "bottomGap": maximum - collection.contentOffset.y,
        "dragging": collection.isDragging, "decelerating": collection.isDecelerating,
        "displayMaxFPS": window.windowScene?.screen.maximumFramesPerSecond ?? 60,
      ]
      if let cell {
        let identity = ObjectIdentifier(cell)
        if cellTokens[identity] == nil { cellTokens[identity] = cellTokens.count + 1 }
        geometry["cellToken"] = cellTokens[identity]
        geometry["cellContentFrame"] = rectangle(cell.frame)
        geometry["cellWindowFrame"] = rectangle(cell.convert(cell.bounds, to: window))
        geometry["contentViewWindowFrame"] = rectangle(cell.contentView.convert(cell.contentView.bounds, to: window))
        if let presentation = cell.layer.presentation(), let superlayer = cell.layer.superlayer {
          let inWindow = superlayer.convert(presentation.frame, to: window.layer)
          geometry["cellPresentationWindowFrame"] = rectangle(inWindow)
        }
        let animKeys = activeGeometryAnimationKeys(in: cell.layer)
        geometry["geometryAnimationCount"] = animKeys.count
        if !animKeys.isEmpty {
          geometry["geometryAnimationKeys"] = animKeys
        }
        geometry["freshlyConfigured"] = cell.isFreshlyConfigured
        if let indexPath = collection.indexPath(for: cell),
          let attributes = collection.layoutAttributesForItem(at: indexPath) {
          geometry["layoutFrame"] = rectangle(attributes.frame)
        }
        if observedCell !== cell {
          observedCell = cell
          cell.accessibilityIdentifier = "moderation.fixture.outerCell"
        }
      }
      guard let fingerprint = try? JSONSerialization.data(withJSONObject: geometry, options: .sortedKeys)
      else { return }
      guard event != "display" || fingerprint != previousGeometry else { return }
      previousGeometry = fingerprint
      geometry["event"] = event
      geometry["sequence"] = nextSequence
      nextSequence += 1
      geometry["elapsed"] = CACurrentMediaTime() - started
      events.append(geometry)
      if events.count > 512 { events.removeFirst() }
      // XCTest retains the trace as an attachment; this probe performs no file I/O.
      guard let data = try? JSONSerialization.data(withJSONObject: ["events": events], options: .sortedKeys)
      else { return }
      accessibilityValue = String(data: data, encoding: .utf8)
    }
  }
}
#endif
