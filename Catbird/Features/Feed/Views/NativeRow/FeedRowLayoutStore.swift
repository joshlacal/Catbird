#if os(iOS)
import UIKit

// MARK: - Feed Row Layout Store

/// Caches `FeedRowLayout`s and computes them off the main actor ahead of display.
///
/// A layout is only ever served for the exact inputs it was computed from. The key holds every
/// input `FeedRowLayoutEngine` reads: the width, the typography generation, the header strings
/// (display name, handle, time text), the badge symbol, and the content signature, which together
/// with the typography determines the attributed text. A stale entry can therefore never give a
/// cell a frame set that disagrees with what it draws (the gap/overlap bug class).
@MainActor
final class FeedRowLayoutStore {
  struct Key: Hashable, Sendable {
    let postID: String
    /// The exact requested width. It is not rounded: a layout computed for a neighbouring width
    /// would not match the cell's bounds.
    let width: CGFloat
    let typographyKey: Int
    let displayName: String
    let handle: String
    /// Changes with the clock ("9m", "10m", "1d") and sizes the name and handle.
    let timeText: String
    /// Follows the hide-verification-badges preference and decides whether a badge frame exists.
    let verificationSymbol: String?
    let signature: FeedPostContentSignature

    nonisolated init(_ input: FeedRowLayoutInput) {
      postID = input.postID
      width = input.width
      typographyKey = input.typography.generationKey
      displayName = input.displayName
      handle = input.handle
      timeText = input.timeText
      verificationSymbol = input.verificationSymbol
      signature = input.contentSignature
    }
  }

  static let defaultCapacity = 1000

  private var layouts: [Key: FeedRowLayout] = [:]
  private let capacity: Int

  var cachedCount: Int { layouts.count }

  init(capacity: Int = FeedRowLayoutStore.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// The cached layout for `input`, or one computed now on the calling thread.
  func layout(for input: FeedRowLayoutInput) -> FeedRowLayout {
    let key = Key(input)
    if let cached = layouts[key] { return cached }
    let layout = FeedRowLayoutEngine.layout(input)
    store(layout, for: key)
    return layout
  }

  /// Computes layouts for the inputs that are not cached yet on a background thread.
  /// Cancelling the calling task stops the work between rows; layouts finished by then are kept.
  func prepare(_ inputs: [FeedRowLayoutInput]) async {
    var seen = Set<Key>()
    var pending: [(key: Key, input: FeedRowLayoutInput)] = []
    for input in inputs {
      let key = Key(input)
      if layouts[key] == nil, seen.insert(key).inserted { pending.append((key, input)) }
    }
    guard !pending.isEmpty else { return }

    let work = pending
    let task = Task.detached(priority: .userInitiated) { () -> [(Key, FeedRowLayout)] in
      var computed: [(Key, FeedRowLayout)] = []
      computed.reserveCapacity(work.count)
      for (key, input) in work {
        if Task.isCancelled { break }
        computed.append((key, FeedRowLayoutEngine.layout(input)))
      }
      return computed
    }
    let computed = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    for (key, layout) in computed { store(layout, for: key) }
  }

  func invalidateAll() { layouts.removeAll(keepingCapacity: true) }

  // MARK: - Storage

  private func store(_ layout: FeedRowLayout, for key: Key) {
    if layouts[key] == nil, layouts.count >= capacity { layouts.removeAll(keepingCapacity: true) }
    layouts[key] = layout
  }
}
#endif
