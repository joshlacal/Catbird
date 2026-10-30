/// Prefetch is optional work. Transcript observation can continue while this
/// gate is closed, including under a covering screen or in an inactive scene.
@MainActor
final class ChatEmbedPrefetchAdmission {
  private var isVisible = false
  private var isSceneActive = false

  var isAllowed: Bool { isVisible && isSceneActive }

  func update(
    isVisible: Bool? = nil,
    isSceneActive: Bool? = nil,
    cancel: () -> Void,
    warm: () -> Void
  ) {
    let wasAllowed = isAllowed
    if let isVisible { self.isVisible = isVisible }
    if let isSceneActive { self.isSceneActive = isSceneActive }
    // Publish the closed gate before cancellation can cause any other work.
    if !isAllowed {
      cancel()
    } else if !wasAllowed {
      warm()
    }
  }

  func performIfAllowed(_ operation: () -> Void) {
    guard isAllowed else { return }
    operation()
  }
}
