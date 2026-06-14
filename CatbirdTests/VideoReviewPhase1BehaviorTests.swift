@testable import Catbird
import Testing

@Suite("Video review phase 1 behavior")
struct VideoReviewPhase1BehaviorTests {
  @Test("Top-level thread rests at natural adjusted top")
  func topLevelThreadUsesNaturalTopOffset() {
    let target = ThreadMainPostScrollTarget(
      mainPostY: 0,
      adjustedTopInset: 88,
      hasParentPosts: false
    )

    #expect(target.offset == -88)
    #expect(target.expectedVisibleTop == 88)
  }

  @Test("Parent thread keeps small parent preview and respects inset")
  func parentThreadKeepsPreviewAboveMainPost() {
    let target = ThreadMainPostScrollTarget(
      mainPostY: 280,
      adjustedTopInset: 88,
      hasParentPosts: true
    )

    #expect(target.offset == 182)
    #expect(target.expectedVisibleTop == 98)
  }

  @Test("Short parent thread never clamps under the navigation bar")
  func shortParentThreadKeepsMainPostBelowBar() {
    let target = ThreadMainPostScrollTarget(
      mainPostY: 70,
      adjustedTopInset: 88,
      hasParentPosts: true
    )

    #expect(target.offset == -28)
    #expect(target.expectedVisibleTop == 98)
  }

  @Test("Feed discovery header hides until posts exist")
  func feedDiscoveryHeaderRequiresPosts() {
    #expect(FeedDiscoveryHeaderVisibility.shouldShowHeader(headerIsPresent: true, postCount: 0) == false)
    #expect(FeedDiscoveryHeaderVisibility.shouldShowHeader(headerIsPresent: false, postCount: 3) == false)
    #expect(FeedDiscoveryHeaderVisibility.shouldShowHeader(headerIsPresent: true, postCount: 3) == true)
  }
}
