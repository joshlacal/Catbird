import CoreGraphics
import Testing

@testable import Catbird

/// When a thread opens from a feed tap, the tapped post shows before the thread loads (P080). If
/// the reader drags it meanwhile, the loaded thread keeps it where they have it instead of
/// snapping it to the usual place under their finger.
@Suite("Thread prefilled anchor hold")
@MainActor
struct ThreadPrefilledAnchorHoldTests {
  @Test("A prefilled anchor left where it opened is positioned as usual")
  func untouchedAnchorIsPositioned() {
    #expect(!ThreadViewController.readerMovedPrefilledAnchor(
      isTracking: false, isDragging: false, isDecelerating: false, offsetFromTop: 0))
    #expect(!ThreadViewController.readerMovedPrefilledAnchor(
      isTracking: false, isDragging: false, isDecelerating: false, offsetFromTop: 0.5))
  }

  @Test(
    "Touching, dragging, flinging or having scrolled the anchor keeps it where the reader has it",
    arguments: [
      (true, false, false, CGFloat(0)), (false, true, false, CGFloat(0)), (false, false, true, CGFloat(0)),
      (false, false, false, CGFloat(120)), (false, false, false, CGFloat(-40)),
    ]
  )
  func movedAnchorIsHeld(isTracking: Bool, isDragging: Bool, isDecelerating: Bool, offsetFromTop: CGFloat) {
    #expect(ThreadViewController.readerMovedPrefilledAnchor(
      isTracking: isTracking, isDragging: isDragging, isDecelerating: isDecelerating, offsetFromTop: offsetFromTop))
  }
}
