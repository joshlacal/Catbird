#if os(iOS)

/// Shared first-use work is claimed only after content has settled and scrolling has stopped.
@MainActor
final class FeedFirstUseWarmup {
  static let shared = FeedFirstUseWarmup()
  private(set) var nativePreparationCount = 0
  private(set) var trendingPreparationCount = 0

  func prepare(
    now: Double, contentVisibleSince: Double?, lastScrollAt: Double,
    isVisible: Bool, isScrolling: Bool, nativeAvailable: Bool, trendingAvailable: Bool,
    native: () -> Void, trending: () -> Void
  ) {
    guard let contentVisibleSince, isVisible, !isScrolling else { return }
    let visibleDuration: Double = now - contentVisibleSince
    let idleDuration: Double = now - lastScrollAt
    guard visibleDuration >= 0.75, idleDuration >= 0.5 else { return }
    // Claim before invoking callbacks, including callbacks that cause another feed update.
    if nativeAvailable, nativePreparationCount == 0 {
      nativePreparationCount = 1
      native()
    }
    if trendingAvailable, trendingPreparationCount == 0 {
      trendingPreparationCount = 1
      trending()
    }
  }
}
#endif
