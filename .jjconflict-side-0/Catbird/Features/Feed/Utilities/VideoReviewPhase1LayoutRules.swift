import CoreGraphics

struct ThreadMainPostScrollTarget {
  let offset: CGFloat
  let expectedVisibleTop: CGFloat

  init(mainPostY: CGFloat, adjustedTopInset: CGFloat, hasParentPosts: Bool) {
    if hasParentPosts {
      let parentPreviewHeight: CGFloat = 10
      offset = max(
        -adjustedTopInset,
        mainPostY - adjustedTopInset - parentPreviewHeight
      )
      expectedVisibleTop = adjustedTopInset + parentPreviewHeight
    } else {
      offset = -adjustedTopInset
      expectedVisibleTop = adjustedTopInset
    }
  }
}

enum FeedDiscoveryHeaderVisibility {
  static func shouldShowHeader(headerIsPresent: Bool, postCount: Int) -> Bool {
    headerIsPresent && postCount > 0
  }
}
