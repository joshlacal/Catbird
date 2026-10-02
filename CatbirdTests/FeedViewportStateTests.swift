import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import Catbird

@Suite("Scene-owned feed viewport state")
@MainActor
struct FeedViewportStateTests {
  @Test("Two scenes retain independent anchors for the same account and feed")
  func sceneAnchorsAreIndependent() throws {
    let firstScene = FeedViewportStore()
    let secondScene = FeedViewportStore()
    let first = firstScene.state(accountDID: "did:plc:fixture", feedIdentifier: "timeline")
    let second = secondScene.state(accountDID: "did:plc:fixture", feedIdentifier: "timeline")
    #expect(first !== second)
    first.setScrollAnchor(anchor("post-20", offset: 15))
    second.setScrollAnchor(anchor("post-40", offset: 35))

    let recreatedFirst = firstScene.state(accountDID: "did:plc:fixture", feedIdentifier: "timeline")
    #expect(recreatedFirst === first)
    #expect(try #require(recreatedFirst.getScrollAnchor()).postID == "post-20")
    #expect(try #require(second.getScrollAnchor()).postID == "post-40")
    first.clearScrollAnchor()
    #expect(first.getScrollAnchor() == nil)
    #expect(try #require(second.getScrollAnchor()).offsetFromTop == 35)
  }

  @Test("Account and feed components cannot collide or replace sibling viewport state")
  func accountAndFeedKeysAreIndependent() throws {
    let store = FeedViewportStore()
    let timeline = store.state(accountDID: "did:plc:first", feedIdentifier: "timeline")
    let otherFeed = store.state(accountDID: "did:plc:first", feedIdentifier: "discover")
    let otherAccount = store.state(accountDID: "did:plc:second", feedIdentifier: "timeline")
    #expect(timeline !== otherFeed)
    #expect(timeline !== otherAccount)
    timeline.setScrollAnchor(anchor("timeline", offset: 10))
    otherFeed.setScrollAnchor(anchor("discover", offset: 20))
    otherAccount.setScrollAnchor(anchor("other-account", offset: 30))
    #expect(try #require(store.state(accountDID: "did:plc:first", feedIdentifier: "timeline")
      .getScrollAnchor()).postID == "timeline")
    #expect(try #require(otherFeed.getScrollAnchor()).postID == "discover")
    #expect(try #require(otherAccount.getScrollAnchor()).postID == "other-account")
    #expect(store.state(accountDID: "did:plc:first-extra", feedIdentifier: "timeline") !==
      store.state(accountDID: "did:plc:first", feedIdentifier: "extra-timeline"))
  }

  @Test("An expired anchor is cleared without changing another scene")
  func expirationRemainsLocal() throws {
    let stale = FeedViewportStore().state(accountDID: "fixture", feedIdentifier: "timeline")
    let fresh = FeedViewportStore().state(accountDID: "fixture", feedIdentifier: "timeline")
    stale.setScrollAnchor(.init(postID: "expired", offsetFromTop: 12,
      timestamp: Date(timeIntervalSinceNow: -FeedConstants.maxScrollAnchorAge - 10)))
    fresh.setScrollAnchor(anchor("fresh", offset: 22))
    #expect(stale.getScrollAnchor() == nil)
    #expect(stale.getScrollAnchor() == nil)
    #expect(try #require(fresh.getScrollAnchor()).postID == "fresh")
  }

  @Test("Old controller teardown cannot remove its replacement's scroll handler")
  func staleHandlerOwnerCannotUnregisterReplacement() {
    let state = FeedViewportStore().state(accountDID: "fixture", feedIdentifier: "timeline")
    let oldOwner = UUID()
    let newOwner = UUID()
    let calls = HandlerCalls()
    state.registerScrollToTopHandler(ownerID: oldOwner) { calls.old += 1 }
    state.registerScrollToTopHandler(ownerID: newOwner) { calls.new += 1 }
    state.unregisterScrollToTopHandler(ownerID: oldOwner)
    state.scrollToTop()
    #expect(calls.old == 0)
    #expect(calls.new == 1)
    state.unregisterScrollToTopHandler(ownerID: newOwner)
    state.scrollToTop()
    #expect(calls.new == 1)
  }

  @Test("A scroll command targets only its scene's viewport")
  func commandsAreSceneLocal() {
    let first = FeedViewportStore().state(accountDID: "fixture", feedIdentifier: "timeline")
    let second = FeedViewportStore().state(accountDID: "fixture", feedIdentifier: "timeline")
    let calls = HandlerCalls()
    first.registerScrollToTopHandler(ownerID: UUID()) { calls.old += 1 }
    second.registerScrollToTopHandler(ownerID: UUID()) { calls.new += 1 }
    first.scrollToTop()
    #expect(calls.old == 1)
    #expect(calls.new == 0)
    second.scrollToTop()
    #expect(calls.old == 1)
    #expect(calls.new == 1)
  }

  #if os(iOS)
  @Test("Window capture retains its post position independently across controller recreation")
  func capturedGeometryRemainsSceneLocal() async throws {
    let firstWindow = try FeedViewportAnchorTests.Fixture(topInset: 100)
    let secondWindow = try FeedViewportAnchorTests.Fixture(topInset: 64)
    defer {
      firstWindow.window.isHidden = true
      secondWindow.window.isHidden = true
    }
    let rows: [FeedViewportAnchorTests.Row] = (0..<30).map { .post("p\($0)") }
    await firstWindow.apply(rows)
    await secondWindow.apply(rows)
    firstWindow.collection.contentOffset.y = 615
    secondWindow.collection.contentOffset.y = 1235
    firstWindow.collection.layoutIfNeeded()
    secondWindow.collection.layoutIfNeeded()

    let firstScene = FeedViewportStore()
    let secondScene = FeedViewportStore()
    let first = firstScene.state(accountDID: "fixture", feedIdentifier: "timeline")
    let second = secondScene.state(accountDID: "fixture", feedIdentifier: "timeline")
    first.captureScrollAnchor(from: firstWindow.collection) {
      firstWindow.source.itemIdentifier(for: $0)?.postID
    }
    second.captureScrollAnchor(from: secondWindow.collection) {
      secondWindow.source.itemIdentifier(for: $0)?.postID
    }
    let firstAnchor = try #require(first.getScrollAnchor())
    let secondAnchor = try #require(second.getScrollAnchor())
    #expect(firstAnchor.postID != secondAnchor.postID)
    #expect(abs(firstAnchor.viewportAnchor.viewportY -
      (try firstWindow.viewportY(firstAnchor.postID))) < 1)

    let recreated = try FeedViewportAnchorTests.Fixture(topInset: 64)
    defer { recreated.window.isHidden = true }
    await recreated.apply(rows)
    let saved = try #require(firstScene.state(accountDID: "fixture", feedIdentifier: "timeline")
      .getScrollAnchor())
    let index = try #require(recreated.index(saved.postID))
    saved.viewportAnchor.restore(in: recreated.collection, indexPath: index)
    #expect(abs((try recreated.viewportY(saved.postID)) - saved.viewportAnchor.viewportY) < 1)
    #expect(try #require(second.getScrollAnchor()).postID == secondAnchor.postID)
    #expect(secondWindow.collection.contentOffset.y == 1235)
  }
  #endif

  private func anchor(_ postID: String, offset: CGFloat) -> FeedViewportState.ScrollAnchor {
    .init(postID: postID, offsetFromTop: offset, timestamp: Date(),
      capturedTopInset: 100, isAtTop: false)
  }

  @MainActor
  private final class HandlerCalls {
    var old = 0
    var new = 0
  }
}
