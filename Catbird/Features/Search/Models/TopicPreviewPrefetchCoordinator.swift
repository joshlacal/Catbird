import Foundation

enum TopicPreviewPrefetchOwner: Hashable {
  case search, timeline
}

/// Metadata starts a small batch before individual rows enter the viewport.
/// Feed admission remains shared with visible rows in TopicPreviewRequestGate.
@MainActor
final class TopicPreviewPrefetchCoordinator {
  private struct Batch {
    let id: UUID
    let identity: String
    let task: Task<Void, Never>
  }
  private var batches: [TopicPreviewPrefetchOwner: Batch] = [:]
  /// A finished batch is not repeated when its surface reappears; a new identity (revision,
  /// labelers, links) or a cancellation restarts it.
  private var completed: [TopicPreviewPrefetchOwner: String] = [:]
  private(set) var isActive = true

  func setActive(_ active: Bool) {
    isActive = active
    if !active { cancelAll() }
  }

  static func boundedLinks(_ links: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for link in links where !link.isEmpty && seen.insert(link).inserted {
      result.append(link)
      if result.count == 6 { break }
    }
    return result
  }

  func start(owner: TopicPreviewPrefetchOwner, identity: String, links: [String],
    load: @escaping @MainActor (String) async -> Void) -> Bool {
    guard isActive, batches[owner]?.identity != identity, completed[owner] != identity else { return false }
    cancel(owner: owner)
    let links = Self.boundedLinks(links)
    guard !links.isEmpty else { return false }
    let id = UUID()
    let task = Task { [weak self] in
      guard self?.isActive == true, !Task.isCancelled else { return }
      await withTaskGroup(of: Void.self) { group in
        for link in links {
          guard self?.isActive == true, !Task.isCancelled else { break }
          group.addTask { @MainActor [weak self] in
            guard self?.isActive == true, !Task.isCancelled else { return }
            await load(link)
          }
        }
      }
      if self?.batches[owner]?.id == id {
        self?.batches.removeValue(forKey: owner)
        if !Task.isCancelled { self?.completed[owner] = identity }
      }
    }
    batches[owner] = Batch(id: id, identity: identity, task: task)
    return true
  }

  func cancel(owner: TopicPreviewPrefetchOwner) {
    batches.removeValue(forKey: owner)?.task.cancel()
    completed.removeValue(forKey: owner)
  }

  func cancelAll() {
    for batch in batches.values { batch.task.cancel() }
    batches.removeAll()
    completed.removeAll()
  }

  deinit {
    for batch in batches.values { batch.task.cancel() }
  }
}
