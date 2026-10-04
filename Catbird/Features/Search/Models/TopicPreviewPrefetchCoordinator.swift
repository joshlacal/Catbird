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
    guard batches[owner]?.identity != identity else { return false }
    cancel(owner: owner)
    let links = Self.boundedLinks(links)
    guard !links.isEmpty else { return false }
    let id = UUID()
    let task = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        for link in links {
          guard !Task.isCancelled else { break }
          group.addTask { @MainActor in
            guard !Task.isCancelled else { return }
            await load(link)
          }
        }
      }
      if self?.batches[owner]?.id == id {
        self?.batches.removeValue(forKey: owner)
      }
    }
    batches[owner] = Batch(id: id, identity: identity, task: task)
    return true
  }

  func cancel(owner: TopicPreviewPrefetchOwner) {
    batches.removeValue(forKey: owner)?.task.cancel()
  }

  func cancelAll() {
    for batch in batches.values { batch.task.cancel() }
    batches.removeAll()
  }

  deinit {
    for batch in batches.values { batch.task.cancel() }
  }
}
