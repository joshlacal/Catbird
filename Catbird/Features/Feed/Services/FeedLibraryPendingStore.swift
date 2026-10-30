import Foundation

/// Per-URI retry intents survive account/AppState recreation. Server refreshes overlay
/// only these URIs, preserving every unrelated server feed and its relative order.
@MainActor
final class FeedLibraryPendingStore {
  enum Intent: String, Codable { case saved, pinned, unpinned, removed }
  struct Entry: Codable, Equatable {
    let uri: String
    let intent: Intent
    let revision: UUID
  }
  struct PinnedOrder: Codable, Equatable {
    let uris: [String]
    let revision: UUID
  }

  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func entries(accountDID: String) -> [Entry] {
    guard let data = defaults.data(forKey: key(accountDID)) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  @discardableResult
  func record(uri: String, intent: Intent, accountDID: String) -> Entry {
    var entries = entries(accountDID: accountDID)
    entries.removeAll { $0.uri == uri }
    let entry = Entry(uri: uri, intent: intent, revision: UUID())
    entries.append(entry)
    write(entries, accountDID: accountDID)
    return entry
  }

  /// Conditional completion never erases a newer operation for the same URI.
  func complete(_ entry: Entry, accountDID: String, restoring previous: Entry? = nil) {
    var entries = entries(accountDID: accountDID)
    guard entries.contains(entry) else { return }
    entries.removeAll { $0 == entry }
    if let previous { entries.append(previous) }
    write(entries, accountDID: accountDID)
  }

  func reconcile(accountDID: String, pinned: inout [String], saved: inout [String]) {
    for entry in entries(accountDID: accountDID) {
      switch entry.intent {
      case .saved:
        if !pinned.contains(entry.uri) && !saved.contains(entry.uri) { saved.append(entry.uri) }
      case .unpinned:
        pinned.removeAll { $0 == entry.uri }
        if !saved.contains(entry.uri) { saved.append(entry.uri) }
      case .pinned:
        saved.removeAll { $0 == entry.uri }
        if !pinned.contains(entry.uri) { pinned.append(entry.uri) }
      case .removed:
        pinned.removeAll { $0 == entry.uri }
        saved.removeAll { $0 == entry.uri }
      }
    }
    if let order = pinnedOrder(accountDID: accountDID) {
      pinned = Self.applyingPinnedOrder(order.uris, to: pinned)
    }
  }

  func pinnedOrder(accountDID: String) -> PinnedOrder? {
    guard let data = defaults.data(forKey: orderKey(accountDID)) else { return nil }
    return try? JSONDecoder().decode(PinnedOrder.self, from: data)
  }

  @discardableResult
  func recordPinnedOrder(_ uris: [String], accountDID: String) -> PinnedOrder {
    let order = PinnedOrder(uris: uris, revision: UUID())
    if let data = try? JSONEncoder().encode(order) { defaults.set(data, forKey: orderKey(accountDID)) }
    return order
  }

  func completePinnedOrder(_ order: PinnedOrder, accountDID: String, restoring previous: PinnedOrder? = nil) {
    guard pinnedOrder(accountDID: accountDID) == order else { return }
    if let previous, let data = try? JSONEncoder().encode(previous) {
      defaults.set(data, forKey: orderKey(accountDID))
    } else { defaults.removeObject(forKey: orderKey(accountDID)) }
  }

  /// An explicit order cannot add or remove membership, including unknown feeds.
  nonisolated static func applyingPinnedOrder(_ requested: [String], to existing: [String]) -> [String] {
    var remaining = existing
    var chosen: [String] = []
    for uri in requested {
      if let index = remaining.firstIndex(of: uri) { chosen.append(remaining.remove(at: index)) }
    }
    return chosen + remaining
  }

  /// Legacy library editors express their latest intent through their current arrays.
  /// Only supersede already-pending URIs; unrelated preference saves create no intents.
  @discardableResult
  func supersedePending(accountDID: String, pinned: [String], saved: [String]) -> [(previous: Entry, replacement: Entry)] {
    var changes: [(previous: Entry, replacement: Entry)] = []
    for entry in entries(accountDID: accountDID) {
      let next: Intent = pinned.contains(entry.uri) ? .pinned
        : saved.contains(entry.uri) ? .unpinned : .removed
      let equivalent = next == entry.intent || (entry.intent == .saved && next == .unpinned)
      if !equivalent {
        let replacement = record(uri: entry.uri, intent: next, accountDID: accountDID)
        changes.append((entry, replacement))
      }
    }
    return changes
  }

  private func key(_ accountDID: String) -> String { "feedLibrary.pendingIntents.\(accountDID)" }
  private func orderKey(_ accountDID: String) -> String { "feedLibrary.pendingPinnedOrder.\(accountDID)" }
  private func write(_ entries: [Entry], accountDID: String) {
    // Entry contains only nonoptional strings/enums/UUIDs; encoding cannot fail.
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: key(accountDID))
  }
}
