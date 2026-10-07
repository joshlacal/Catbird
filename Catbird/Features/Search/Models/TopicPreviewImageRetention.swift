import Foundation

/// Short-lived resolved thumbnails, independent of a scrolling view's identity.
/// Reads never extend lifetime or start work; the account owner clears on invalidation.
struct TopicPreviewImageRetention<Key: Hashable, Value> {
  private struct Entry {
    let value: Value
    let cost: Int
    let expiresAt: Date
    let order: Int
  }
  private var entries: [Key: Entry] = [:]
  private var order = 0
  private(set) var totalCost = 0
  var count: Int { entries.count }
  let countLimit: Int
  let costLimit: Int
  let lifetime: TimeInterval

  init(countLimit: Int = 36, costLimit: Int = 4 * 1024 * 1024, lifetime: TimeInterval = 60) {
    self.countLimit = countLimit
    self.costLimit = costLimit
    self.lifetime = lifetime
  }

  mutating func value(for key: Key, now: Date = Date()) -> Value? {
    prune(now: now)
    return entries[key]?.value
  }

  mutating func insert(_ value: Value, for key: Key, cost: Int, now: Date = Date()) {
    prune(now: now)
    // Seeing an already retained image again must not keep it alive indefinitely.
    guard entries[key] == nil else { return }
    guard countLimit > 0, lifetime > 0, cost > 0, cost <= costLimit else { return }
    while entries.count >= countLimit || totalCost > costLimit - cost {
      guard let oldest = entries.min(by: { $0.value.order < $1.value.order })?.key else { break }
      remove(oldest)
    }
    order += 1
    entries[key] = Entry(value: value, cost: cost, expiresAt: now.addingTimeInterval(lifetime), order: order)
    totalCost += cost
  }

  mutating func removeAll() {
    entries.removeAll()
    totalCost = 0
  }

  private mutating func remove(_ key: Key) {
    if let entry = entries.removeValue(forKey: key) { totalCost -= entry.cost }
  }

  private mutating func prune(now: Date) {
    for (key, entry) in entries where entry.expiresAt <= now { remove(key) }
  }
}
