#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed row layout store")
struct FeedRowLayoutStoreTests {
  @Test("Prepared layouts are served without recomputing")
  func prepareThenServe() async throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "prepared")
    await store.prepare([input])
    #expect(store.cachedCount == 1)
    #expect(store.layout(for: input) == FeedRowLayoutEngine.layout(input))
    #expect(store.cachedCount == 1)
  }

  @Test("A typography change misses the cache")
  func typographyChangeMisses() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    _ = store.layout(for: input)
    let bigger = try NativeFeedRowTestFactory.layoutInput(text: "x", contentSize: .accessibilityLarge)
    _ = store.layout(for: bigger)
    #expect(store.cachedCount == 2)
  }

  @Test("Invalidation empties the cache")
  func invalidate() throws {
    let store = FeedRowLayoutStore()
    _ = store.layout(for: try NativeFeedRowTestFactory.layoutInput(text: "x"))
    store.invalidateAll()
    #expect(store.cachedCount == 0)
  }

  @Test("A width change misses the cache and each layout matches its request")
  func widthChangeMisses() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let wide = Self.resized(input, to: 390)
    let narrow = Self.resized(input, to: 320)
    let wideLayout = store.layout(for: wide)
    let narrowLayout = store.layout(for: narrow)
    #expect(store.cachedCount == 2)
    #expect(wideLayout.width == 390)
    #expect(narrowLayout.width == 320)
    #expect(store.layout(for: wide) == wideLayout)
    #expect(store.layout(for: narrow) == narrowLayout)
    #expect(store.cachedCount == 2)
  }

  @Test("A sub-point width difference is not served from the neighbouring width")
  func fractionalWidthMisses() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let whole = store.layout(for: Self.resized(input, to: 390))
    let fractional = store.layout(for: Self.resized(input, to: 390.4))
    #expect(store.cachedCount == 2)
    #expect(whole.width == 390)
    #expect(fractional.width == 390.4)
  }

  @Test("A content change for the same post misses the cache")
  func contentChangeMisses() throws {
    let store = FeedRowLayoutStore()
    let original = try NativeFeedRowTestFactory.layoutInput(text: "original text")
    let edited = try NativeFeedRowTestFactory.layoutInput(text: "edited text that is different")
    #expect(original.postID == edited.postID)
    #expect(original.contentSignature != edited.contentSignature)
    _ = store.layout(for: original)
    _ = store.layout(for: edited)
    #expect(store.cachedCount == 2)
  }

  @Test("Prepare skips inputs that are already cached and duplicates within the batch")
  func prepareSkipsKnownInputs() async throws {
    let store = FeedRowLayoutStore()
    let first = try NativeFeedRowTestFactory.layoutInput(text: "first")
    let second = try NativeFeedRowTestFactory.layoutInput(text: "second")
    _ = store.layout(for: first)
    await store.prepare([first, second, second])
    #expect(store.cachedCount == 2)
    #expect(store.layout(for: second) == FeedRowLayoutEngine.layout(second))
  }

  @Test("Prepared layouts for several widths are each served for their own width")
  func prepareServesEachWidth() async throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let inputs = [320, 375, 390, 430].map { Self.resized(input, to: CGFloat($0)) }
    await store.prepare(inputs)
    #expect(store.cachedCount == 4)
    for request in inputs {
      #expect(store.layout(for: request).width == request.width)
    }
    #expect(store.cachedCount == 4)
  }

  // MARK: - Helpers

  private static func resized(_ input: FeedRowLayoutInput, to width: CGFloat) -> FeedRowLayoutInput {
    FeedRowLayoutInput(
      postID: input.postID, width: width, typography: input.typography, displayName: input.displayName,
      handle: input.handle, timeText: input.timeText, verificationSymbol: input.verificationSymbol,
      text: input.text, contentSignature: input.contentSignature)
  }
}
#endif
