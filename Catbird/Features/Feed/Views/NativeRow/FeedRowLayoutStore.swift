#if os(iOS)
import UIKit

// MARK: - Feed Row Layout Store

/// Caches `FeedRowLayout`s and computes them off the main actor ahead of display.
///
/// A layout is only ever served for the exact width, typography generation and content signature
/// it was computed for, so a stale entry can never give a cell a frame set that disagrees with
/// what it draws (the gap/overlap bug class).
@MainActor
final class FeedRowLayoutStore {
  struct Key: Hashable, Sendable {
    let postID: String
    /// The exact requested width. It is not rounded: a layout computed for a neighbouring width
    /// would not match the cell's bounds.
    let width: CGFloat
    let typographyKey: Int
    let signature: FeedPostContentSignature

    nonisolated init(_ input: FeedRowLayoutInput) {
      postID = input.postID
      width = input.width
      typographyKey = input.typography.generationKey
      signature = input.contentSignature
    }
  }

  private var layouts: [Key: FeedRowLayout] = [:]
  private let capacity = 1000

  var cachedCount: Int { layouts.count }

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
    if layouts.count >= capacity { layouts.removeAll(keepingCapacity: true) }
    layouts[key] = layout
  }
}
#endif
