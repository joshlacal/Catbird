import Foundation
#if os(iOS)
import UIKit
#endif

/// Transient presentation state for one account/feed in one scene. The scene's
/// store retains it across controller recreation without sharing another window's
/// reading position or scroll commands.
@MainActor
final class FeedViewportState {
  struct ScrollAnchor {
    let postID: String
    let offsetFromTop: CGFloat
    let timestamp: Date
    let capturedTopInset: CGFloat
    let isAtTop: Bool

    init(postID: String, offsetFromTop: CGFloat, timestamp: Date,
      capturedTopInset: CGFloat = 0, isAtTop: Bool = false) {
      self.postID = postID
      self.offsetFromTop = offsetFromTop
      self.timestamp = timestamp
      self.capturedTopInset = capturedTopInset
      self.isAtTop = isAtTop
    }

    #if os(iOS)
    @MainActor var viewportAnchor: FeedViewportAnchor {
      FeedViewportAnchor(postID: postID,
        viewportY: -offsetFromTop - capturedTopInset, isAtTop: isAtTop)
    }
    #endif

    var isStale: Bool {
      Date().timeIntervalSince(timestamp) > FeedConstants.maxScrollAnchorAge
    }
  }

  private var scrollAnchor: ScrollAnchor?
  private var scrollToTopHandler: (ownerID: UUID, action: @MainActor () -> Void)?

  #if os(iOS)
  func captureScrollAnchor(from collectionView: UICollectionView,
    postIDAt: (IndexPath) -> String?) {
    guard let anchor = FeedViewportAnchor.capture(in: collectionView, postIDAt: postIDAt) else {
      if collectionView.contentOffset.y + collectionView.adjustedContentInset.top <= 1 {
        scrollAnchor = nil
      }
      return
    }
    let topInset = collectionView.adjustedContentInset.top
    scrollAnchor = ScrollAnchor(
      postID: anchor.postID,
      offsetFromTop: -anchor.viewportY - topInset,
      timestamp: Date(),
      capturedTopInset: topInset,
      isAtTop: anchor.isAtTop)
  }
  #endif

  func setScrollAnchor(_ anchor: ScrollAnchor) {
    scrollAnchor = anchor
  }

  func getScrollAnchor() -> ScrollAnchor? {
    guard let anchor = scrollAnchor, !anchor.isStale else {
      scrollAnchor = nil
      return nil
    }
    return anchor
  }

  func clearScrollAnchor() {
    scrollAnchor = nil
  }

  func registerScrollToTopHandler(ownerID: UUID, handler: @escaping @MainActor () -> Void) {
    scrollToTopHandler = (ownerID, handler)
  }

  /// Controller replacement may attach its handler before the old controller is
  /// dismantled. Only the current registration's owner can remove that handler.
  func unregisterScrollToTopHandler(ownerID: UUID) {
    guard scrollToTopHandler?.ownerID == ownerID else { return }
    scrollToTopHandler = nil
  }

  func scrollToTop() {
    scrollToTopHandler?.action()
  }
}

/// Owned by a scene context; intentionally has no process-wide shared instance.
/// Separate key components avoid collisions between account and feed identifiers.
@MainActor
final class FeedViewportStore {
  private struct Key: Hashable {
    let accountDID: String
    let feedIdentifier: String
  }

  private var states: [Key: FeedViewportState] = [:]

  func state(accountDID: String, feedIdentifier: String) -> FeedViewportState {
    let key = Key(accountDID: accountDID, feedIdentifier: feedIdentifier)
    if let existing = states[key] { return existing }
    let state = FeedViewportState()
    states[key] = state
    return state
  }
}
