#if os(iOS)
import Foundation
import Petrel
import UIKit

// MARK: - Native Feed Row Preparation

/// The work `NativeFeedRowPreparer` moves off the main actor for rows that are about to scroll
/// in: each post's decision (classification, header strings, attributed text and counts), its
/// layout at the width cells have, and its relative time strings.
///
/// Every function here is a pure function of its inputs, the same functions the main-actor path
/// calls, so a prepared row is exactly the row the main actor would build. Results are keyed as
/// the main actor keys its own: decisions by the post's content signature under one set of row
/// settings, layouts by `FeedRowLayoutStore.Key`, and time strings by the time text they were
/// computed with.
enum NativeFeedRowPreparation {
  /// The most posts one batch prepares; a batch is a window of rows ahead of the visible ones.
  static let batchSize = 24

  /// One post to prepare, captured on the main actor.
  enum Entry: Sendable {
    /// A post with no decision yet for its content: classified from its captured input.
    case classify(postID: String, signature: FeedPostContentSignature, source: NativeFeedRowSupport.Entry)
    /// A post the main actor already decided for this content: only its layout and time strings
    /// are prepared.
    case decided(postID: String, signature: FeedPostContentSignature, decision: NativeFeedRowCoordinator.Decision)

    var postID: String {
      switch self {
      case .classify(let postID, _, _), .decided(let postID, _, _): postID
      }
    }

    var signature: FeedPostContentSignature {
      switch self {
      case .classify(_, let signature, _), .decided(_, let signature, _): signature
      }
    }
  }

  /// Posts to prepare under one set of row settings, at one layout width.
  struct Batch: Sendable {
    /// Tells the preparer's batches apart.
    let id: Int
    /// The preparer's generation when the batch was taken; a batch from an earlier generation
    /// (other settings, typography or width) is discarded.
    let generation: Int
    let width: CGFloat
    let settings: NativeFeedRowCoordinator.Settings
    let entries: [Entry]
  }

  /// What the main actor stores for one prepared post.
  struct Prepared: Sendable {
    let postID: String
    let signature: FeedPostContentSignature
    let decision: NativeFeedRowCoordinator.Decision
    /// The native row's layout, with the key it is stored under; `nil` for a hosted post.
    let layout: FeedRowLayoutStore.Prepared?
    /// The native row's time strings, from the same instant as the layout's time text.
    let time: RowTime?
  }

  // MARK: - Running

  /// Prepares `batch` on a background thread. Cancelling the calling task stops the work between
  /// posts; what was prepared by then is returned, and the caller decides whether it still applies.
  static func run(_ batch: Batch) async -> [Prepared] {
    let work = Task.detached(priority: .userInitiated) { prepare(batch) }
    return await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
  }

  /// Prepares `batch` on the calling thread.
  static func prepare(_ batch: Batch) -> [Prepared] {
    var prepared: [Prepared] = []
    prepared.reserveCapacity(batch.entries.count)
    for entry in batch.entries {
      if Task.isCancelled { break }
      let decision: NativeFeedRowCoordinator.Decision
      switch entry {
      case .classify(let postID, let signature, let source):
        decision = NativeFeedRowCoordinator.decide(
          postID: postID, entry: source, signature: signature, settings: batch.settings)
      case .decided(_, _, let existing):
        decision = existing
      }
      guard case .native(let row) = decision else {
        prepared.append(Prepared(
          postID: entry.postID, signature: entry.signature, decision: decision, layout: nil, time: nil))
        continue
      }
      let time = RowTime(createdAt: row.createdAt)
      let input = NativeFeedRowCoordinator.layoutInput(
        for: row, width: batch.width, timeText: time.text, settings: batch.settings)
      prepared.append(Prepared(
        postID: entry.postID, signature: entry.signature, decision: decision,
        layout: FeedRowLayoutStore.Prepared(input), time: time))
    }
    return prepared
  }

  // MARK: - Time

  /// A post's relative time as the header shows it ("9m") and as VoiceOver reads it ("9 minutes
  /// ago"), computed at the same instant.
  struct RowTime: Equatable, Sendable {
    let createdAt: Date
    let text: String
    let accessibilityLabel: String

    init(createdAt: Date) {
      self.createdAt = createdAt
      text = shortTimeAgoString(from: createdAt)
      accessibilityLabel = formatTimeAgo(from: createdAt, forAccessibility: true)
    }

    init(createdAt: Date, text: String, accessibilityLabel: String) {
      self.createdAt = createdAt
      self.text = text
      self.accessibilityLabel = accessibilityLabel
    }

    /// Whether these are still the strings for a post created at `createdAt` whose header now
    /// shows `timeText`. Both strings change at the same minute, hour, day, month and year
    /// boundaries, except below a minute: the header shows "now" while the spoken label counts
    /// seconds, so "now" is never reused.
    func isCurrent(createdAt: Date, timeText: String) -> Bool {
      self.createdAt == createdAt && text == timeText && timeText != "now"
    }
  }
}

// MARK: - Preparation Window

/// Follows the post the feed shows as it scrolls and says which posts to prepare next: a window
/// ahead in the direction of travel and a few posts behind, so the first rows of a reversal are
/// prepared too and the reversal itself asks for a window the other way.
///
/// Indexes are positions in the snapshot's posts; the window starts over (`reset`) whenever a
/// snapshot is applied, since the positions may have moved.
struct NativeFeedRowPreparationWindow: Equatable {
  enum Direction: Equatable {
    case forward, backward
  }

  /// Posts prepared ahead of the shown post in the direction of travel.
  static let ahead = NativeFeedRowPreparation.batchSize
  /// Posts prepared behind the shown post when the window starts over.
  static let behind = 8
  /// A new window is asked for once at most this many posts ahead of the shown one are covered.
  static let threshold = 12

  /// The posts already asked for.
  private(set) var covered: Range<Int>?
  private(set) var direction: Direction = .forward
  private var lastIndex: Int?

  /// Starts over at `index` of `count` posts and returns the posts to prepare around it.
  mutating func reset(at index: Int, count: Int) -> Range<Int> {
    guard count > 0 else {
      covered = nil
      lastIndex = nil
      return 0..<0
    }
    let index = min(max(0, index), count - 1)
    lastIndex = index
    let range = window(around: index, count: count)
    covered = range
    return range
  }

  /// The posts to prepare now that the post at `index` of `count` is shown, or `nil` while the
  /// posts ahead of it are already covered.
  mutating func advance(to index: Int, count: Int) -> Range<Int>? {
    guard count > 0, index >= 0, index < count else { return nil }
    if let lastIndex, index != lastIndex { direction = index > lastIndex ? .forward : .backward }
    lastIndex = index
    guard let covered, covered.contains(index), covered.upperBound <= count else {
      // A jump past what was asked for, or a feed that got shorter: start over here.
      let range = window(around: index, count: count)
      self.covered = range
      return range
    }
    switch direction {
    case .forward:
      guard covered.upperBound < count, covered.upperBound - (index + 1) < Self.threshold else { return nil }
      let range = covered.upperBound..<min(count, index + 1 + Self.ahead)
      self.covered = covered.lowerBound..<range.upperBound
      return range
    case .backward:
      guard covered.lowerBound > 0, index - covered.lowerBound < Self.threshold else { return nil }
      let range = max(0, index - Self.ahead)..<covered.lowerBound
      self.covered = range.lowerBound..<covered.upperBound
      return range
    }
  }

  private func window(around index: Int, count: Int) -> Range<Int> {
    switch direction {
    case .forward: max(0, index - Self.behind)..<min(count, index + 1 + Self.ahead)
    case .backward: max(0, index - Self.ahead)..<min(count, index + 1 + Self.behind)
    }
  }
}
#endif
