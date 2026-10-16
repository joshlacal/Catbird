#if os(iOS)
import Foundation
import UIKit

// MARK: - Native Feed Row Preparer Delegate

/// The snapshot a `NativeFeedRowPreparer` prepares rows of, and where prepared rows go.
@MainActor
protocol NativeFeedRowPreparerDelegate: AnyObject {
  /// The row settings rows are prepared with; `nil` until a snapshot resolved them.
  var preparationSettings: NativeFeedRowCoordinator.Settings? { get }
  /// The post's content signature in the current snapshot; `nil` when the post is not in it.
  func preparationSignature(forPostID postID: String) -> FeedPostContentSignature?
  /// Whether the post needs nothing prepared for `signature`: it is already decided as hosted.
  func preparationIsSettled(postID: String, signature: FeedPostContentSignature) -> Bool
  /// What preparing the post starts from: the decision already made for `signature`, or the
  /// post's classification input; `nil` when the post is not in the snapshot.
  func preparationEntry(forPostID postID: String, signature: FeedPostContentSignature) -> NativeFeedRowPreparation.Entry?
  /// Stores a prepared post. Its signature is the snapshot's.
  func store(_ prepared: NativeFeedRowPreparation.Prepared)
}

// MARK: - Native Feed Row Preparer

/// Prepares native rows off the main actor ahead of display: a bounded queue of posts asked for,
/// one batch at a time on a background thread, and what each post was prepared for.
///
/// Results are applied only while they still hold:
/// - a batch prepared for an earlier generation is dropped whole. Every change that invalidates
///   prepared rows starts a new generation (`discardAll`): settings, typography, another feed, and
///   a new layout width (`prepare(_:width:)`), so the generation alone tells a stale batch;
/// - a post that left the snapshot meanwhile is skipped;
/// - a post whose content changed meanwhile is asked for again with its new content.
///
/// Discarding cancels the batch in flight, which stops its work between posts. The main actor
/// never waits for a batch: a cell configured first builds its row itself.
@MainActor
final class NativeFeedRowPreparer {
  /// Prepares one batch; the default runs `NativeFeedRowPreparation.prepare` on a background thread.
  typealias Runner = @Sendable (NativeFeedRowPreparation.Batch) async -> [NativeFeedRowPreparation.Prepared]

  /// Posts that may wait to be prepared at once; posts asked for long ago are behind the reader.
  static let maximumQueued = NativeFeedRowPreparation.batchSize * 2

  weak var delegate: (any NativeFeedRowPreparerDelegate)?
  /// Changes whenever prepared results stop applying. A batch of an earlier generation is dropped.
  private(set) var generation = 0

  private let run: Runner
  /// The layout width preparations are for.
  private var width: CGFloat?
  /// Posts waiting to be prepared, in the order they were asked for.
  private var queue: [String] = []
  /// Posts a batch asked for again (changed meanwhile, or not reached before a cancellation). They
  /// are prepared before `queue` and never trimmed: a batch holds at most `batchSize` posts.
  private var retries: [String] = []
  /// The posts in `queue` and `retries`.
  private var queued: Set<String> = []
  /// The batch being prepared off the main actor.
  private var inFlight: (id: Int, postIDs: Set<String>)?
  private var batchCount = 0
  private var task: Task<Void, Never>?
  private var taskID = 0
  /// What each post was last prepared for. A post with a stamp for its current signature, the
  /// current generation and the width asked for is not prepared again.
  private var stamps: [String: Stamp] = [:]
  /// How many batches reached `finish`, whatever it kept of them.
  private(set) var finishedBatchCountForTesting = 0

  init(run: @escaping Runner = { await NativeFeedRowPreparation.run($0) }) {
    self.run = run
  }

  isolated deinit {
    task?.cancel()
  }

  // MARK: - Asking

  /// Asks for the posts to be prepared at `width`. A different width than the last one asked for
  /// discards everything prepared for that one first.
  func prepare(_ postIDs: [String], width: CGFloat) {
    if let current = self.width, current != width { discardAll() }
    self.width = width
    enqueue(postIDs, width: width)
  }

  /// The main actor built the post's row at `width` itself: it needs no preparation for that width.
  func markConfigured(postID: String, signature: FeedPostContentSignature, width: CGFloat) {
    stamps[postID] = Stamp(signature: signature, width: width, generation: generation)
  }

  /// Nothing prepared so far applies any more (settings, typography or width changed, or another
  /// feed): cancels the batch in flight, empties the queue and starts a new generation.
  func discardAll() {
    task?.cancel()
    task = nil
    inFlight = nil
    queue.removeAll()
    retries.removeAll()
    queued.removeAll()
    stamps.removeAll(keepingCapacity: true)
    generation &+= 1
  }

  /// A snapshot was applied: forgets posts that left it, and cancels a batch that holds one. That
  /// batch's results for the posts still in the snapshot are kept, and its posts it did not reach
  /// are asked for again.
  func snapshotDidChange() {
    guard let delegate else { return }
    let isGone = { (postID: String) in delegate.preparationSignature(forPostID: postID) == nil }
    stamps = stamps.filter { !isGone($0.key) }
    if queue.contains(where: isGone) || retries.contains(where: isGone) {
      queue.removeAll(where: isGone)
      retries.removeAll(where: isGone)
      queued = Set(queue + retries)
    }
    guard let inFlight, inFlight.postIDs.contains(where: isGone) else { return }
    task?.cancel()
    task = nil
    self.inFlight = nil
    startPreparing()
  }

  // MARK: - Testing

  /// Waits until every post asked for is prepared, or its preparation was discarded.
  func waitForPreparationForTesting() async {
    while let task {
      await task.value
    }
  }

  /// Whether a batch is being prepared off the main actor.
  var hasPreparationInFlightForTesting: Bool { inFlight != nil }

  // MARK: - Queue

  /// Queues the posts that need preparing. Retries go ahead of everything asked for and are not
  /// trimmed; the oldest other requests are trimmed beyond `maximumQueued`.
  private func enqueue(_ postIDs: [String], width: CGFloat, asRetries: Bool = false) {
    var added = false
    for postID in postIDs where needsPreparation(postID, width: width) && queued.insert(postID).inserted {
      if asRetries {
        retries.append(postID)
      } else {
        queue.append(postID)
      }
      added = true
    }
    guard added else { return }
    let excess = queue.count - Self.maximumQueued
    if excess > 0 {
      queue.prefix(excess).forEach { queued.remove($0) }
      queue.removeFirst(excess)
    }
    startPreparing()
  }

  private func needsPreparation(_ postID: String, width: CGFloat) -> Bool {
    guard let delegate, let signature = delegate.preparationSignature(forPostID: postID),
      inFlight?.postIDs.contains(postID) != true
    else { return false }
    if stamps[postID] == Stamp(signature: signature, width: width, generation: generation) { return false }
    return !delegate.preparationIsSettled(postID: postID, signature: signature)
  }

  // MARK: - Batches

  private func startPreparing() {
    guard task == nil, !queue.isEmpty || !retries.isEmpty else { return }
    taskID &+= 1
    let id = taskID
    let run = self.run
    task = Task { [weak self] in
      while !Task.isCancelled, let batch = self?.nextBatch() {
        let prepared = await run(batch)
        // Also after a cancellation: `finish` drops what no longer applies and keeps the rest.
        self?.finish(batch, prepared: prepared)
      }
      self?.taskDidFinish(id)
    }
  }

  private func taskDidFinish(_ id: Int) {
    guard taskID == id else { return }
    task = nil
  }

  /// The next posts to prepare, captured from the snapshot.
  private func nextBatch() -> NativeFeedRowPreparation.Batch? {
    guard let delegate, let settings = delegate.preparationSettings, let width else {
      queue.removeAll()
      retries.removeAll()
      queued.removeAll()
      return nil
    }
    var entries: [NativeFeedRowPreparation.Entry] = []
    while entries.count < NativeFeedRowPreparation.batchSize {
      let postID: String
      if !retries.isEmpty {
        postID = retries.removeFirst()
      } else if !queue.isEmpty {
        postID = queue.removeFirst()
      } else {
        break
      }
      queued.remove(postID)
      guard needsPreparation(postID, width: width),
        let signature = delegate.preparationSignature(forPostID: postID),
        let entry = delegate.preparationEntry(forPostID: postID, signature: signature)
      else { continue }
      entries.append(entry)
    }
    guard !entries.isEmpty else { return nil }
    batchCount &+= 1
    inFlight = (batchCount, Set(entries.map(\.postID)))
    return NativeFeedRowPreparation.Batch(
      id: batchCount, generation: generation, width: width, settings: settings, entries: entries)
  }

  /// Applies a batch's results that still hold.
  private func finish(_ batch: NativeFeedRowPreparation.Batch, prepared: [NativeFeedRowPreparation.Prepared]) {
    finishedBatchCountForTesting += 1
    if inFlight?.id == batch.id { inFlight = nil }
    // Prepared for other settings, typography, width or feed.
    guard batch.generation == generation, let delegate else { return }
    var askAgain: [String] = []
    for result in prepared {
      // Left the snapshot.
      guard let current = delegate.preparationSignature(forPostID: result.postID) else { continue }
      // Changed meanwhile: prepared again for its new content.
      guard current == result.signature else {
        askAgain.append(result.postID)
        continue
      }
      delegate.store(result)
      stamps[result.postID] = Stamp(signature: result.signature, width: batch.width, generation: batch.generation)
    }
    // A cancelled batch stops before its last posts; those still in the snapshot are asked for again.
    let reached = Set(prepared.map(\.postID))
    askAgain += batch.entries.map(\.postID).filter { !reached.contains($0) }
    if !askAgain.isEmpty { enqueue(askAgain, width: batch.width, asRetries: true) }
  }

  // MARK: - Stamps

  /// What a post was prepared for: its content, the preparation generation and the layout width.
  private struct Stamp: Equatable {
    let signature: FeedPostContentSignature
    let width: CGFloat
    let generation: Int
  }
}
#endif
