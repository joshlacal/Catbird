import Foundation

/// Geometry shared by self-sizing invalidations and transcript snapshot restoration.
enum ChatScrollGeometry {
  static func resizeAdjustment(
    oldHeight: CGFloat,
    newHeight: CGFloat,
    resizedItem: Int,
    anchorItem: Int?,
    contentHeight: CGFloat,
    offsetY: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat,
    isInteracting: Bool,
    bottomThreshold: CGFloat = 24
  ) -> CGFloat {
    let delta = newHeight - oldHeight
    guard delta.isFinite else { return 0 }
    let oldBottom = max(-topInset, contentHeight - viewportHeight + bottomInset)
    if !isInteracting, abs(offsetY - oldBottom) <= bottomThreshold {
      let newBottom = max(-topInset, contentHeight + delta - viewportHeight + bottomInset)
      return newBottom - oldBottom
    }
    // Keep the first visible message's origin fixed. Resizing that message itself
    // must reveal content below it, not move the text the reader is looking at.
    return anchorItem.map { resizedItem < $0 ? delta : 0 } ?? 0
  }
}
