//
//  FeedFeedbackOutbox.swift
//  Catbird
//
//  Delivery state for queued feed interaction feedback. Every event carries the
//  account it was recorded by and the feed it was shown in, so batches never
//  mix accounts or feeds.
//

import Foundation

/// Where a piece of feedback goes: the feed it was shown in, on behalf of the
/// account that was signed in when it was recorded.
struct FeedFeedbackDestination: Hashable, Sendable {
  let accountDID: String
  let target: FeedInteractionTarget
}

/// One interaction, with the generator's opaque fields kept as given.
struct FeedFeedbackInteraction: Hashable, Sendable {
  let itemURI: String
  let event: String
  let feedContext: String?
  let requestID: String?
}

struct FeedFeedbackKey: Hashable, Sendable {
  let destination: FeedFeedbackDestination
  let interaction: FeedFeedbackInteraction
}

enum FeedFeedbackDeliveryState: Equatable, Sendable {
  case queued
  case sending
  case confirmed
  /// The generator may have received the request; no acknowledgment was confirmed.
  case unconfirmed
}

/// In-memory, bounded outbox. Confirmed events are remembered so duplicates are not
/// resent; unconfirmed events are only resent when the person explicitly asks again.
@MainActor
final class FeedFeedbackOutbox {
  typealias Sender = @MainActor (FeedFeedbackDestination, [FeedFeedbackInteraction]) async throws -> Void

  /// app.bsky.feed.sendInteractions accepts at most this many interactions per request.
  static let batchLimit = 200

  private var states: [FeedFeedbackKey: FeedFeedbackDeliveryState] = [:]
  private var pendingOrder: [FeedFeedbackKey] = []
  private var confirmedOrder: [FeedFeedbackKey] = []
  private var inFlight: Set<FeedFeedbackDestination> = []
  private let pendingLimit: Int
  private let historyLimit: Int

  init(pendingLimit: Int = 2_000, historyLimit: Int = 2_000) {
    self.pendingLimit = max(1, pendingLimit)
    self.historyLimit = max(0, historyLimit)
  }

  func state(for key: FeedFeedbackKey) -> FeedFeedbackDeliveryState? { states[key] }

  var queuedDestinations: [FeedFeedbackDestination] {
    var seen: Set<FeedFeedbackDestination> = []
    return pendingOrder.compactMap { key in
      guard states[key] == .queued, seen.insert(key.destination).inserted else { return nil }
      return key.destination
    }
  }

  /// Known events are deduplicated. Returns false when a new event cannot fit.
  @discardableResult
  func enqueue(_ key: FeedFeedbackKey) -> Bool {
    if states[key] != nil { return true }
    guard pendingOrder.count < pendingLimit else { return false }
    states[key] = .queued
    pendingOrder.append(key)
    return true
  }

  /// Requeues an unconfirmed event. Automatic events such as "seen" never call this.
  func prepareRetry(_ key: FeedFeedbackKey) {
    guard states[key] == .unconfirmed else { return }
    states[key] = .queued
  }

  /// Drops every event that has not started sending, for every account. A batch already
  /// sending finishes under the account that started it.
  func discardPending() {
    let retained = pendingOrder.filter { states[$0] == .sending }
    for key in pendingOrder where states[key] != .sending {
      states.removeValue(forKey: key)
    }
    pendingOrder = retained
  }

  func flush(_ destination: FeedFeedbackDestination, send: Sender) async {
    guard !inFlight.contains(destination) else { return }
    let batch = Array(pendingOrder.filter {
      $0.destination == destination && states[$0] == .queued
    }.prefix(Self.batchLimit))
    guard !batch.isEmpty else { return }
    inFlight.insert(destination)
    defer { inFlight.remove(destination) }
    for key in batch { states[key] = .sending }
    do {
      try await send(destination, batch.map(\.interaction))
      let acknowledged = Set(batch)
      pendingOrder.removeAll { acknowledged.contains($0) }
      for key in batch {
        states[key] = .confirmed
        confirmedOrder.append(key)
      }
      while confirmedOrder.count > historyLimit {
        let evicted = confirmedOrder.removeFirst()
        if states[evicted] == .confirmed { states.removeValue(forKey: evicted) }
      }
    } catch {
      for key in batch where states[key] == .sending { states[key] = .unconfirmed }
    }
  }
}
