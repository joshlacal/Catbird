#if os(iOS)
import Nuke
import UIKit

// MARK: - Trending Image Slot

/// Loads one image into one `UIImageView` through the shared pipeline. A slot shows only its
/// current request: a reused view never receives a late image from an earlier request, and
/// assigning the same request again keeps the image (or the load) already in progress.
@MainActor
final class TrendingImageSlot {
  enum Phase {
    case empty, loading, loaded, failed
  }

  private weak var imageView: UIImageView?
  private var task: ImageTask?
  private var identity: TrendingTopicImageRequests.Identity?
  private(set) var startedRequestCountForTesting = 0

  init(imageView: UIImageView) {
    self.imageView = imageView
  }

  /// - Parameters:
  ///   - memoryImage: an image already resolved for this request (for example a retained still).
  ///   - fadeIn: cross-fade a network or disk result in, as `LazyImage` transitions do.
  ///   - onPhase: called synchronously for cache hits and on the main thread for loads.
  ///   - onLoaded: called with a freshly loaded, non-preview result.
  func setRequest(
    _ request: ImageRequest?,
    memoryImage: UIImage? = nil,
    allowsImageLoading: Bool = true,
    fadeIn: Bool = false,
    onPhase: @escaping @MainActor (Phase) -> Void = { _ in },
    onLoaded: (@MainActor (UIImage) -> Void)? = nil
  ) {
    let newIdentity = request.map(TrendingTopicImageRequests.identity)
    if let newIdentity, newIdentity == identity { return }
    cancel()
    identity = newIdentity
    guard let request, let imageView else {
      self.imageView?.image = nil
      onPhase(.empty)
      return
    }
    if let image = memoryImage ?? ImageLoadingManager.shared.pipeline.cache[request].flatMap({ $0.isPreview ? nil : $0.image }) {
      imageView.image = image
      onPhase(.loaded)
      return
    }
    imageView.image = nil
    guard allowsImageLoading else {
      // A memory-cache miss is not a completed request. A later normal configure must retry it.
      identity = nil
      onPhase(.empty)
      return
    }
    onPhase(.loading)
    startedRequestCountForTesting += 1
    task = ImageLoadingManager.shared.pipeline.loadImage(with: request) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, self.identity == newIdentity, let imageView = self.imageView else { return }
        self.task = nil
        switch result {
        case .success(let response):
          if fadeIn {
            UIView.transition(with: imageView, duration: 0.18, options: [.transitionCrossDissolve, .curveEaseOut]) {
              imageView.image = response.image
            }
          } else {
            imageView.image = response.image
          }
          onPhase(.loaded)
          if !response.container.isPreview { onLoaded?(response.image) }
        case .failure:
          onPhase(.failed)
        }
      }
    }
  }

  /// Stops any load and forgets the request; the image view keeps what it shows until reassigned.
  func cancel() {
    task?.cancel()
    task = nil
    identity = nil
  }
}
#endif
