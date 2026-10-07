import Foundation
import Testing
@testable import Catbird

@Suite("Resolved trending thumbnail retention")
struct TopicPreviewImageRetentionTests {
  @Test("A recreated reader finds the same value without extending its lifetime")
  func briefReturnAndExpiry() {
    let start = Date(timeIntervalSince1970: 1000)
    var cache = TopicPreviewImageRetention<String, String>()
    cache.insert("resolved still", for: "request", cost: 20, now: start)
    #expect(cache.value(for: "request", now: start.addingTimeInterval(1)) == "resolved still")
    cache.insert("resolved still", for: "request", cost: 20, now: start.addingTimeInterval(59))
    #expect(cache.count == 1 && cache.totalCost == 20)
    #expect(cache.value(for: "request", now: start.addingTimeInterval(60)) == nil)
    #expect(cache.count == 0 && cache.totalCost == 0, "Expired lookup releases retained values")
    cache.insert("new still", for: "request", cost: 15, now: start.addingTimeInterval(60))
    #expect(cache.value(for: "request", now: start.addingTimeInterval(61)) == "new still")
    #expect(cache.totalCost == 15)
  }

  @Test("Costs and count bound retention even while many topics scroll past", arguments: [true, false])
  func boundedRetention(costBound: Bool) {
    let start = Date(timeIntervalSince1970: 1000)
    var cache = TopicPreviewImageRetention<Int, Int>(countLimit: costBound ? 10 : 2,
      costLimit: costBound ? 25 : 100)
    for key in 0..<20 {
      cache.insert(key, for: key, cost: 10, now: start)
      #expect(cache.count <= 2)
      #expect(cache.totalCost <= (costBound ? 25 : 100))
    }
    #expect(cache.value(for: 17, now: start) == nil)
    #expect(cache.value(for: 18, now: start) == 18)
    #expect(cache.value(for: 19, now: start) == 19)
    cache.insert(100, for: 100, cost: 101, now: start)
    #expect(cache.value(for: 100, now: start) == nil)
    #expect(cache.count == 2)
  }

  @Test("Expired entries are pruned before a new topic is retained")
  func pruneExpired() {
    let start = Date(timeIntervalSince1970: 1000)
    var cache = TopicPreviewImageRetention<Int, String>(lifetime: 2)
    cache.insert("expired", for: 1, cost: 50, now: start)
    cache.insert("current", for: 2, cost: 10, now: start.addingTimeInterval(2))
    #expect(cache.count == 1 && cache.totalCost == 10)
    #expect(cache.value(for: 1, now: start.addingTimeInterval(2)) == nil)
  }

  @Test("Different account owners cannot share retained values, and invalidation releases them")
  func accountOwnershipAndClear() {
    var one = TopicPreviewImageRetention<String, String>()
    var two = TopicPreviewImageRetention<String, String>()
    one.insert("one's still", for: "same request", cost: 20)
    #expect(one.value(for: "same request") != nil)
    #expect(two.value(for: "same request") == nil)
    one.removeAll()
    #expect(one.value(for: "same request") == nil)
    #expect(one.count == 0 && one.totalCost == 0)
  }

  @Test("Invalid retention limits and invalid costs never admit an entry")
  func invalidAdmission() {
    for limits in [(0, 100, 60.0), (10, 0, 60.0), (10, 100, 0.0)] {
      var cache = TopicPreviewImageRetention<Int, Int>(countLimit: limits.0, costLimit: limits.1, lifetime: limits.2)
      cache.insert(1, for: 1, cost: 1)
      #expect(cache.count == 0)
    }
    var cache = TopicPreviewImageRetention<Int, Int>()
    cache.insert(1, for: 1, cost: -1)
    cache.insert(2, for: 2, cost: 0)
    #expect(cache.count == 0 && cache.totalCost == 0)
  }
}

#if canImport(UIKit)
import Nuke
import UIKit

@Suite("Account-owned trending stills", .serialized)
@MainActor
struct TrendingTopicResolvedImageTests {
  private func still() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }
  }

  private func request(size: CGSize? = nil, scale: CGFloat = 3) -> ImageRequest {
    TrendingTopicImageRequests.request(URL(string: "https://retained-trend-fixture.invalid/never-fetched.png")!,
      size: size ?? TrendingTopicImageRequests.cardSize, displayScale: scale)
  }

  @Test("Resolved media survives surface cancellation and another account cannot read it")
  func briefSurfaceRecreation() throws {
    let store = TrendingTopicMediaStore()
    let anotherAccount = TrendingTopicMediaStore()
    store.setActive(true)
    anotherAccount.setActive(true)
    let request = request()
    store.retainImage(still(), for: request, revision: store.revision)
    store.cancelPrefetch(owner: .search)
    let returned = try #require(store.image(for: request))
    #expect(returned.cgImage?.width == 12)
    #expect(anotherAccount.image(for: request) == nil)
    // No transport or global-cache clearing: this URL was never loaded into Nuke.
    #expect(ImageLoadingManager.shared.pipeline.cache[request] == nil)
  }

  @Test("Retained stills keep complete card, avatar, scale and request-option identities")
  func processedRequestSeparation() {
    let store = TrendingTopicMediaStore()
    store.setActive(true)
    let card = request()
    store.retainImage(still(), for: card, revision: store.revision)
    #expect(store.image(for: card) != nil)
    #expect(store.image(for: request(size: TrendingTopicImageRequests.avatarSize)) == nil)
    #expect(store.image(for: request(scale: 2)) == nil)
    var reload = card
    reload.options = .reloadIgnoringCachedData
    #expect(store.image(for: reload) == nil)
  }

  @Test("Graph, labeler and activity invalidation clear stills and reject late completions")
  func hardInvalidationAndLateCompletion() {
    let store = TrendingTopicMediaStore()
    store.setActive(true)
    let request = request()
    let image = still()
    var revision = store.revision
    store.retainImage(image, for: request, revision: revision)
    store.invalidateForGraphChange()
    store.retainImage(image, for: request, revision: revision)
    #expect(store.image(for: request) == nil)
    revision = store.revision
    store.retainImage(image, for: request, revision: revision)
    store.invalidate(labelers: "new-labelers")
    store.retainImage(image, for: request, revision: revision)
    #expect(store.image(for: request) == nil)
    revision = store.revision
    store.retainImage(image, for: request, revision: revision)
    store.setActive(false)
    store.retainImage(image, for: request, revision: revision)
    #expect(store.image(for: request) == nil)
    store.setActive(true)
    store.retainImage(image, for: request, revision: revision)
    #expect(store.image(for: request) == nil)
  }
}
#endif
