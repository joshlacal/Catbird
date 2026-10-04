import Observation

/// Requested playback survives temporary moderation and lifecycle suspension.
/// Only selection and explicit user actions change this state.
@MainActor @Observable
final class VideoFeedPlaybackIntent {
  private(set) var selectedItemID: String?
  private(set) var isPlaybackRequested = false

  func select(_ itemID: String?) {
    guard itemID != selectedItemID else { return }
    selectedItemID = itemID
    isPlaybackRequested = itemID != nil
  }

  func setPlaybackRequested(_ requested: Bool, for itemID: String) {
    guard selectedItemID == itemID else { return }
    isPlaybackRequested = requested
  }

  func requestsPlayback(for itemID: String) -> Bool {
    selectedItemID == itemID && isPlaybackRequested
  }
}
