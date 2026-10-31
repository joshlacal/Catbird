import Foundation

@main
struct VerifyChatScrollGeometry {
  static func main() async {
    var contentHeight: CGFloat = 2400
    var offset: CGFloat = 600
    var anchorY: CGFloat = 580
    let relativeY = anchorY - offset
    // Realistic asynchronous ordering: below, above, visible, above/error shrink.
    for (item, old, new) in [(18, 80.0, 420.0), (2, 80.0, 360.0),
                             (7, 80.0, 290.0), (1, 300.0, 64.0)] {
      try? await Task.sleep(for: .milliseconds(25))
      let delta = new - old
      let adjustment = ChatScrollGeometry.resizeAdjustment(
        oldHeight: old, newHeight: new, resizedItem: item, anchorItem: 7,
        contentHeight: contentHeight, offsetY: offset, viewportHeight: 700,
        topInset: 40, bottomInset: 100, isInteracting: false
      )
      offset += adjustment
      if item < 7 { anchorY += delta }
      contentHeight += delta
      precondition(abs(anchorY - offset - relativeY) < 0.001)
    }
    for interacting in [false, true] {
      let adjustment = ChatScrollGeometry.resizeAdjustment(
        oldHeight: 80, newHeight: 400, resizedItem: 20, anchorItem: 17,
        contentHeight: 2400, offsetY: 1800, viewportHeight: 700,
        topInset: 40, bottomInset: 100, isInteracting: interacting
      )
      precondition(adjustment == (interacting ? 0 : 320))
    }
    // Close but not at bottom: a reader 90pt above latest must stay put.
    precondition(ChatScrollGeometry.resizeAdjustment(
      oldHeight: 80, newHeight: 400, resizedItem: 20, anchorItem: 17,
      contentHeight: 2400, offsetY: 1710, viewportHeight: 700,
      topInset: 40, bottomInset: 100, isInteracting: false
    ) == 0)
    // Short transcript: only compensate once it exceeds the usable viewport.
    precondition(ChatScrollGeometry.resizeAdjustment(
      oldHeight: 80, newHeight: 400, resizedItem: 0, anchorItem: 0,
      contentHeight: 400, offsetY: -40, viewportHeight: 700,
      topInset: 40, bottomInset: 100, isInteracting: false
    ) == 160)
    // Warm unchanged measurement causes no displacement at any scroll position.
    precondition(ChatScrollGeometry.resizeAdjustment(
      oldHeight: 400, newHeight: 400, resizedItem: 0, anchorItem: 7,
      contentHeight: 2400, offsetY: 600, viewportHeight: 700,
      topInset: 40, bottomInset: 100, isInteracting: false
    ) == 0)
    // No geometry delta means no correction, even inside a rubber-band region.
    for bottom: CGFloat in [0, 1800] {
      for offset: CGFloat in [-18, bottom + 18] {
        precondition(ChatScrollGeometry.readingOffset(target: offset, current: offset,
          bottom: bottom, top: 0, isInteracting: false) == nil)
      }
    }
    // A late size delta preserves the elastic position instead of clamping it.
    precondition(ChatScrollGeometry.readingOffset(target: -30, current: -18,
      bottom: 1800, top: 0, isInteracting: true) == -30)
    precondition(ChatScrollGeometry.readingOffset(target: 1838, current: 1818,
      bottom: 1800, top: 0, isInteracting: false) == 1838)
    precondition(ChatScrollGeometry.readingOffset(target: -30, current: 10,
      bottom: 1800, top: 0, isInteracting: false) == 0)
    precondition(ChatScrollGeometry.readingOffset(target: .nan, current: 10,
      bottom: 1800, top: 0, isInteracting: false) == nil)
    print("PASS: rubber-band preservation, real geometry correction, invalid geometry; delayed out-of-order growth/shrink, viewport anchoring, idle bottom follow, active touch, near-bottom reader, short transcript, warm sizing")
  }
}
