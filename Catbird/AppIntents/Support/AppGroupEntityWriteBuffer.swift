//
//  AppGroupEntityWriteBuffer.swift
//  Catbird
//
//  Coalesces the App Group writes behind the App Intents entity caches.
//  Every rendered post and profile used to decode, merge, re-encode and
//  rewrite a whole App Group blob (a cfprefsd round trip each time). Entries
//  now collect in memory and reach the shared defaults in one write, shortly
//  after the last change and before the app resigns active or enters the
//  background, so the out-of-process Siri path still finds them.
//

import Foundation
import OSLog

#if canImport(UIKit)
  import UIKit
#endif

enum AppGroupEntityWrites {
  /// How long a buffer waits after its most recent write before flushing.
  static let flushDelay: TimeInterval = 1.5

  /// Notifications that flush synchronously, before the process can be suspended.
  static var lifecycleNotifications: [Notification.Name] {
    #if canImport(UIKit)
      [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification]
    #else
      []
    #endif
  }
}

/// A most-recent-first list of entities stored as one JSON blob in App Group
/// defaults. Writes land in an in-memory buffer; `entries()` merges that buffer
/// over the stored list, so readers in this process see every write immediately.
final class AppGroupEntityWriteBuffer<Entry: Codable & Equatable & Sendable>: @unchecked Sendable {
  private let defaults: UserDefaults
  private let storageKey: String
  private let capacity: Int
  private let flushDelay: TimeInterval
  private let entryID: @Sendable (Entry) -> String
  private let encode: @Sendable ([Entry]) throws -> Data
  private let decode: @Sendable (Data) throws -> [Entry]
  private let flushQueue = DispatchQueue(label: "blue.catbird.app-intents.entity-writes", qos: .utility)
  private let logger = Logger(subsystem: "blue.catbird", category: "AppGroupEntityWriteBuffer")

  /// Guards `pending`, `inFlight` and `scheduledFlush`.
  private let lock = NSLock()
  /// Writes not yet handed to a flush, newest first and unique by ID.
  private var pending: [Entry] = []
  /// Entries a running flush is writing; reads keep seeing them until the write lands.
  private var inFlight: [Entry] = []
  private var scheduledFlush: DispatchWorkItem?
  /// Serializes flushes so a lifecycle flush never interleaves with a timer flush.
  private let flushLock = NSLock()
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    defaults: UserDefaults,
    storageKey: String,
    capacity: Int,
    flushDelay: TimeInterval = AppGroupEntityWrites.flushDelay,
    lifecycleNotifications: [Notification.Name] = AppGroupEntityWrites.lifecycleNotifications,
    id: @escaping @Sendable (Entry) -> String,
    encode: @escaping @Sendable ([Entry]) throws -> Data = { try JSONEncoder().encode($0) },
    decode: @escaping @Sendable (Data) throws -> [Entry] = { try JSONDecoder().decode([Entry].self, from: $0) }
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.capacity = capacity
    self.flushDelay = flushDelay
    self.entryID = id
    self.encode = encode
    self.decode = decode
    lifecycleObservers = lifecycleNotifications.map { name in
      // A nil queue delivers on the posting thread, so the flush finishes
      // before the app returns from its resign or background notification.
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.flush()
      }
    }
  }

  deinit {
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
  }

  /// Buffers `fresh` ahead of everything already known, keeping the first copy of
  /// each ID, and schedules a flush `flushDelay` after this, the latest write.
  func enqueue(_ fresh: [Entry]) {
    let batch = merge(fresh, over: [])
    guard !batch.isEmpty else { return }

    let work = DispatchWorkItem { [weak self] in self?.flush() }
    lock.lock()
    pending = merge(batch, over: pending)
    scheduledFlush?.cancel()
    scheduledFlush = work
    lock.unlock()
    flushQueue.asyncAfter(deadline: .now() + flushDelay, execute: work)
  }

  /// The list as this process sees it: buffered writes merged over the stored blob.
  func entries() -> [Entry] {
    lock.lock()
    let buffered = merge(pending, over: inFlight)
    lock.unlock()
    return merge(buffered, over: storedEntries())
  }

  /// Writes buffered entries to the App Group now. Skips the write when the
  /// merged list matches what is already stored.
  func flush() {
    flushLock.lock()
    defer { flushLock.unlock() }

    lock.lock()
    scheduledFlush?.cancel()
    scheduledFlush = nil
    let batch = pending
    inFlight = batch
    pending = []
    lock.unlock()
    guard !batch.isEmpty else { return }

    // Covers the read, merge, encode and App Group write, so Instruments shows
    // what each coalesced export costs (blue.catbird.performance / Intervals).
    let signpost = PerformanceSignposts.beginInterval("EntityExport")
    defer { PerformanceSignposts.endInterval("EntityExport", signpost) }

    let stored = storedEntries()
    let merged = merge(batch, over: stored)
    if merged != stored {
      do {
        defaults.set(try encode(merged), forKey: storageKey)
      } catch {
        logger.error("Failed to encode \(self.storageKey, privacy: .public): \(error.localizedDescription)")
      }
    }

    lock.lock()
    inFlight = []
    lock.unlock()
  }

  private func storedEntries() -> [Entry] {
    guard let data = defaults.data(forKey: storageKey) else { return [] }
    do {
      return try decode(data)
    } catch {
      logger.error("Failed to decode \(self.storageKey, privacy: .public): \(error.localizedDescription)")
      return []
    }
  }

  /// `newer` (first copy of each ID wins) followed by the `older` entries it
  /// doesn't replace, trimmed to `capacity`.
  private func merge(_ newer: [Entry], over older: [Entry]) -> [Entry] {
    var seen = Set<String>()
    var merged: [Entry] = []
    merged.reserveCapacity(min(capacity, newer.count + older.count))
    for entry in newer + older where merged.count < capacity {
      if seen.insert(entryID(entry)).inserted {
        merged.append(entry)
      }
    }
    return merged
  }
}
