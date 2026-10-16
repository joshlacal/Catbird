#if os(iOS)
import Foundation
import Petrel
import UIKit
import Testing
@testable import Catbird

@MainActor
@Suite("Feed first-use warmup", .serialized)
struct FeedFirstUseWarmupTests {
  @Test("Preparation waits for visible content to settle and for every scroll to end")
  func waitsForIdleContent() {
    let warmup = FeedFirstUseWarmup()
    var calls = 0
    func attempt(now: Double = 5, since: Double? = 1, scroll: Double = 0,
                 visible: Bool = true, scrolling: Bool = false) {
      warmup.prepare(now: now, contentVisibleSince: since, lastScrollAt: scroll,
        isVisible: visible, isScrolling: scrolling, nativeAvailable: true, trendingAvailable: true,
        native: { calls += 1 }, trending: { calls += 1 })
    }
    attempt(since: nil)
    attempt(visible: false)
    attempt(scrolling: true)
    attempt(now: 1.749)
    attempt(scroll: 4.501)
    #expect(calls == 0)
    #expect(warmup.nativePreparationCount == 0)
    #expect(warmup.trendingPreparationCount == 0)
    attempt(now: 5, scroll: 4.5)
    #expect(calls == 2)
    #expect(warmup.nativePreparationCount == 1)
    #expect(warmup.trendingPreparationCount == 1)
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private final class DeceleratingCarousel: UIScrollView {
    var simulatesDeceleration = true
    override var isDecelerating: Bool { simulatesDeceleration }
  }

  @Test("The controller defers for a nested carousel while the outer feed is idle")
  func nestedDecelerationDefersController() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://warmup-controller.invalid")!)
    let state = AppState(userDID: "did:plc:warmupcontroller", client: client, regulatoryChecker: NoAgePrompt())
    defer { state.cleanup() }
    let host = try NativeFeedRowControllerHost(appState: state,
      posts: [try FeedRowTestPosts.cachedPost(text: "Nested scrolling")])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let carousel = DeceleratingCarousel(frame: container.bounds)
    carousel.contentSize = CGSize(width: 900, height: 200)
    host.controller.collectionView.addSubview(container)
    container.addSubview(carousel)
    #expect(!host.controller.collectionView.isDecelerating)
    let warmup = FeedFirstUseWarmup()
    let now = ProcessInfo.processInfo.systemUptime + 10
    host.controller.prepareFirstUseIfIdleForTesting(warmup, now: now, visibleSince: now - 10)
    #expect(warmup.nativePreparationCount == 0)
    carousel.simulatesDeceleration = false
    host.controller.prepareFirstUseIfIdleForTesting(warmup, now: now + 1, visibleSince: now - 10)
    #expect(warmup.nativePreparationCount == 1)
  }

  @Test("A real trending carousel delegate callback delays the controller after horizontal motion")
  func recentCarouselMovementDefersController() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://warmup-controller.invalid")!)
    let state = AppState(userDID: "did:plc:warmuprecent", client: client, regulatoryChecker: NoAgePrompt())
    defer { state.cleanup() }
    let host = try NativeFeedRowControllerHost(appState: state,
      posts: [try FeedRowTestPosts.cachedPost(text: "Recent scrolling")])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    try await Task.sleep(for: .milliseconds(600))
    let cell = TrendingInterstitialCell(frame: .zero)
    host.controller.collectionView.addSubview(cell)
    let carousel = try #require(cell.contentView.subviews.compactMap { $0 as? UIScrollView }.first)
    cell.scrollViewDidScroll(carousel)
    let now = ProcessInfo.processInfo.systemUptime
    #expect(cell.lastCarouselScrollAt > now - 0.1)
    let warmup = FeedFirstUseWarmup()
    host.controller.prepareFirstUseIfIdleForTesting(warmup, now: now + 0.1, visibleSince: now - 10)
    #expect(warmup.nativePreparationCount == 0)
    host.controller.prepareFirstUseIfIdleForTesting(warmup, now: now + 0.6, visibleSince: now - 10)
    #expect(warmup.nativePreparationCount == 1)
  }

  @Test("Each kind is prepared once per process even when content arrives separately")
  func claimsEachKindOnce() {
    let warmup = FeedFirstUseWarmup()
    var native = 0
    var trending = 0
    func attempt(nativeAvailable: Bool, trendingAvailable: Bool) {
      warmup.prepare(now: 5, contentVisibleSince: 1, lastScrollAt: 0,
        isVisible: true, isScrolling: false, nativeAvailable: nativeAvailable,
        trendingAvailable: trendingAvailable, native: { native += 1 }, trending: { trending += 1 })
    }
    attempt(nativeAvailable: false, trendingAvailable: false)
    #expect(native == 0 && trending == 0)
    attempt(nativeAvailable: true, trendingAvailable: false)
    #expect(native == 1 && trending == 0)
    attempt(nativeAvailable: true, trendingAvailable: true)
    attempt(nativeAvailable: true, trendingAvailable: true)
    #expect(native == 1 && trending == 1)
    #expect(warmup.nativePreparationCount == 1 && warmup.trendingPreparationCount == 1)
  }
}
#endif
