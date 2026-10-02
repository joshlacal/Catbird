#if os(iOS)
import UIKit

/// A post's position below the collection's effective visible top, independent
/// of headers, interstitials, and navigation-bar inset changes.
@MainActor
struct FeedViewportAnchor {
  let postID: String
  let viewportY: CGFloat
  let isAtTop: Bool

  static func capture(
    in collectionView: UICollectionView,
    postIDAt: (IndexPath) -> String?
  ) -> Self? {
    let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
      guard let postID = postIDAt(indexPath),
        let attributes = collectionView.layoutAttributesForItem(at: indexPath),
        attributes.frame.maxY > visibleTop else { continue }
      return Self(
        postID: postID,
        viewportY: attributes.frame.minY - visibleTop,
        isAtTop: visibleTop <= 1
      )
    }
    return nil
  }

  func restore(in collectionView: UICollectionView, indexPath: IndexPath) {
    if isAtTop {
      collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
      return
    }
    // Materializing a distant self-sizing row can change its estimated origin.
    // Resolve and correct in one nonanimated transaction, without item alignment.
    UIView.performWithoutAnimation {
      for _ in 0..<3 {
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let top = -collectionView.adjustedContentInset.top
        let bottom = max(top, collectionView.contentSize.height
          - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let target = min(bottom, max(top,
          attributes.frame.minY - viewportY - collectionView.adjustedContentInset.top))
        if abs(target - collectionView.contentOffset.y) > 0.5 {
          collectionView.contentOffset.y = target
        }
      }
    }
  }
}

/// A new controller and a reused controller share this one-shot restoration
/// boundary. An actual user drag cancels a pending restore instead of being
/// overwritten when an asynchronous snapshot finishes.
@MainActor
final class FeedViewportRestoration {
  private var anchor: FeedViewportAnchor?
  private(set) var isPending = true
  private(set) var generation = 0

  init(anchor: FeedViewportAnchor?) { self.anchor = anchor }

  func reset(to anchor: FeedViewportAnchor?) {
    self.anchor = anchor
    generation += 1
    isPending = true
  }

  func cancel() { isPending = false }

  @discardableResult
  func restoreIfReady(
    in collectionView: UICollectionView,
    postCount: Int,
    isLoading: Bool,
    snapshotGeneration: Int = 0,
    indexPathFor: (String) -> IndexPath?
  ) -> Bool {
    guard isPending, snapshotGeneration == generation else { return false }
    if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
      cancel()
      return false
    }
    guard collectionView.window != nil, collectionView.bounds.height > 0, postCount > 0 else {
      return false
    }
    let indexPath = anchor.flatMap { indexPathFor($0.postID) }
    if anchor != nil, indexPath == nil, isLoading { return false }
    // Consume before laying out: layout callbacks may reenter the controller.
    isPending = false
    if let anchor, let indexPath {
      anchor.restore(in: collectionView, indexPath: indexPath)
    } else {
      collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
    }
    return true
  }
}

#if DEBUG
/// Geometry only: no post text, identifiers, or account state enters the trace.
struct FeedLayoutGeometry: Equatable {
  static let isTracingEnabled = ProcessInfo.processInfo.arguments
    .contains("-catbird-feed-layout-diagnostics")

  let bounds: CGRect
  let contentSize: CGSize
  let contentOffset: CGPoint
  let contentInset: UIEdgeInsets
  let adjustedInset: UIEdgeInsets
  let safeArea: UIEdgeInsets
  let firstPostFrame: CGRect?
  let firstPostSafeArea: UIEdgeInsets?
  let hostingSafeArea: UIEdgeInsets?
  let isRefreshing: Bool

  @MainActor
  static func capture(in collectionView: UICollectionView,
    postIDAt: (IndexPath) -> String?) -> Self {
    let index = collectionView.indexPathsForVisibleItems.sorted().first { postIDAt($0) != nil }
    let cell = index.flatMap { collectionView.cellForItem(at: $0) }
    return Self(
      bounds: collectionView.bounds,
      contentSize: collectionView.contentSize,
      contentOffset: collectionView.contentOffset,
      contentInset: collectionView.contentInset,
      adjustedInset: collectionView.adjustedContentInset,
      safeArea: collectionView.safeAreaInsets,
      firstPostFrame: index.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame },
      firstPostSafeArea: cell?.safeAreaInsets,
      hostingSafeArea: cell?.contentView.subviews.first?.safeAreaInsets,
      isRefreshing: collectionView.refreshControl?.isRefreshing ?? false
    )
  }
}
#endif
#endif
