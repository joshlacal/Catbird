#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed row layout store")
struct FeedRowLayoutStoreTests {
  @Test("A layout prepared off the main actor is served without recomputing")
  func prepareThenServe() async throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "prepared")
    let prepared = await Task.detached { FeedRowLayoutStore.Prepared(input) }.value
    store.insert(prepared)
    #expect(store.cachedCount == 1)
    #expect(store.layout(for: input) == FeedRowLayoutEngine.layout(input))
    #expect(store.cachedCount == 1)
    #expect(store.computedOnCallCount == 0)
  }

  @Test("A miss is computed on the calling thread and counted; a hit is not")
  func missesAreCounted() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "counted")
    _ = store.layout(for: input)
    #expect(store.computedOnCallCount == 1)
    _ = store.layout(for: input)
    #expect(store.computedOnCallCount == 1)
    _ = store.layout(for: Self.resized(input, to: 320))
    #expect(store.computedOnCallCount == 2)
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

  @Test("A prepared layout for a cached key replaces it without adding an entry")
  func preparedLayoutForCachedKey() throws {
    let store = FeedRowLayoutStore()
    let first = try NativeFeedRowTestFactory.layoutInput(text: "first")
    let second = try NativeFeedRowTestFactory.layoutInput(text: "second")
    _ = store.layout(for: first)
    store.insert(FeedRowLayoutStore.Prepared(first))
    store.insert(FeedRowLayoutStore.Prepared(second))
    store.insert(FeedRowLayoutStore.Prepared(second))
    #expect(store.cachedCount == 2)
    #expect(store.layout(for: second) == FeedRowLayoutEngine.layout(second))
    #expect(store.computedOnCallCount == 1)
  }

  @Test("Prepared layouts for several widths are each served for their own width")
  func prepareServesEachWidth() async throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let inputs = [320, 375, 390, 430].map { Self.resized(input, to: CGFloat($0)) }
    let prepared = await Task.detached { inputs.map(FeedRowLayoutStore.Prepared.init) }.value
    for layout in prepared { store.insert(layout) }
    #expect(store.cachedCount == 4)
    for request in inputs {
      #expect(store.layout(for: request).width == request.width)
    }
    #expect(store.cachedCount == 4)
    #expect(store.computedOnCallCount == 0)
  }

  @Test("A differing time text misses the cache")
  func timeTextChangeMisses() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let nineMinutes = Self.copy(of: input, timeText: "9m")
    let tenMinutes = Self.copy(of: input, timeText: "10m")
    _ = store.layout(for: nineMinutes)
    let served = store.layout(for: tenMinutes)
    #expect(store.cachedCount == 2)
    #expect(served == FeedRowLayoutEngine.layout(tenMinutes))
    #expect(served.timeFrame.width > FeedRowLayoutEngine.layout(nineMinutes).timeFrame.width)
  }

  @Test("A differing verification badge misses the cache")
  func verificationChangeMisses() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let plain = Self.copy(of: input, verificationSymbol: .some(nil))
    let verified = Self.copy(of: input, verificationSymbol: "checkmark.seal.fill")
    #expect(store.layout(for: plain).badgeFrame == nil)
    let served = store.layout(for: verified)
    #expect(store.cachedCount == 2)
    #expect(served.badgeFrame != nil)
    #expect(served == FeedRowLayoutEngine.layout(verified))
  }

  @Test("A differing display name or handle misses the cache")
  func nameAndHandleChangeMiss() throws {
    let store = FeedRowLayoutStore()
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let renamed = Self.copy(of: input, displayName: "A much longer display name than before")
    let rehandled = Self.copy(of: input, handle: "@a-much-longer-handle.example.com")
    _ = store.layout(for: input)
    #expect(store.layout(for: renamed) == FeedRowLayoutEngine.layout(renamed))
    #expect(store.layout(for: rehandled) == FeedRowLayoutEngine.layout(rehandled))
    #expect(store.cachedCount == 3)
  }

  @Test("Exceeding the capacity wipes the cache and still serves the new layout")
  func evictionAtCapacity() throws {
    let capacity = 4
    let store = FeedRowLayoutStore(capacity: capacity)
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    for index in 0..<capacity {
      _ = store.layout(for: Self.resized(input, to: CGFloat(300 + index)))
    }
    #expect(store.cachedCount == capacity)
    let extra = Self.resized(input, to: 500)
    let served = store.layout(for: extra)
    #expect(store.cachedCount == 1)
    #expect(served == FeedRowLayoutEngine.layout(extra))
  }

  @Test("Overwriting a cached key at capacity does not wipe the cache")
  func overwriteAtCapacityKeepsEntries() async throws {
    let store = FeedRowLayoutStore(capacity: 2)
    let input = try NativeFeedRowTestFactory.layoutInput(text: "x")
    let first = Self.resized(input, to: 320)
    let second = Self.resized(input, to: 390)
    // A preparation of `first` that finishes after the main actor filled the store to capacity.
    let prepared = await Task.detached { FeedRowLayoutStore.Prepared(first) }.value
    _ = store.layout(for: second)
    _ = store.layout(for: first)
    #expect(store.cachedCount == 2)
    store.insert(prepared)
    #expect(store.cachedCount == 2)
    #expect(store.layout(for: first) == FeedRowLayoutEngine.layout(first))
    #expect(store.layout(for: second) == FeedRowLayoutEngine.layout(second))
    #expect(store.cachedCount == 2)
  }

  // MARK: - Helpers

  private static func resized(_ input: FeedRowLayoutInput, to width: CGFloat) -> FeedRowLayoutInput {
    copy(of: input, width: width)
  }

  /// `input` with the given fields replaced. `verificationSymbol: .some(nil)` removes the badge.
  private static func copy(
    of input: FeedRowLayoutInput, width: CGFloat? = nil, displayName: String? = nil,
    handle: String? = nil, timeText: String? = nil, verificationSymbol: String?? = nil
  ) -> FeedRowLayoutInput {
    FeedRowLayoutInput(
      postID: input.postID, width: width ?? input.width, typography: input.typography,
      displayName: displayName ?? input.displayName, handle: handle ?? input.handle,
      timeText: timeText ?? input.timeText,
      verificationSymbol: verificationSymbol ?? input.verificationSymbol,
      text: input.text, contentSignature: input.contentSignature)
  }
}
#endif
