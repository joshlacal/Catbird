import Testing
@testable import Catbird

@MainActor
@Suite("Video feed requested playback")
struct VideoFeedPlaybackIntentTests {
  @Test("Refreshing the selected URI retains its pending play request")
  func selectedRefreshRetainsRequest() {
    let intent = VideoFeedPlaybackIntent()
    intent.select("selected")
    #expect(intent.requestsPlayback(for: "selected"))
    intent.select("selected")
    #expect(intent.requestsPlayback(for: "selected"))
  }

  @Test("Refreshing or resuming the same URI preserves an explicit pause")
  func explicitPauseSurvivesRefresh() {
    let intent = VideoFeedPlaybackIntent()
    intent.select("selected")
    intent.setPlaybackRequested(false, for: "selected")
    intent.select("selected")
    #expect(!intent.requestsPlayback(for: "selected"))
    intent.setPlaybackRequested(true, for: "selected")
    #expect(intent.requestsPlayback(for: "selected"))
  }

  @Test("A stale page cannot alter the newly selected video's intent")
  func stalePageCannotChangeSelection() {
    let intent = VideoFeedPlaybackIntent()
    intent.select("old")
    intent.setPlaybackRequested(false, for: "old")
    intent.select("current")
    intent.setPlaybackRequested(false, for: "old")
    #expect(intent.requestsPlayback(for: "current"))
    #expect(!intent.requestsPlayback(for: "old"))
    intent.setPlaybackRequested(false, for: "current")
    intent.setPlaybackRequested(true, for: "old")
    #expect(!intent.requestsPlayback(for: "current"))
  }

  @Test("Removing the selection clears the request and rejects late actions")
  func removedSelectionCannotResume() {
    let intent = VideoFeedPlaybackIntent()
    intent.select("selected")
    intent.select(nil)
    intent.setPlaybackRequested(true, for: "selected")
    #expect(intent.selectedItemID == nil)
    #expect(!intent.isPlaybackRequested)
  }
}
