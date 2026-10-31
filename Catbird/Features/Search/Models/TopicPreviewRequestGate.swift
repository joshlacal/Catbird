import Foundation

/// FIFO admission with two requests total and one per feed, shared by Search and timeline.
@MainActor
final class TopicPreviewRequestGate {
  private struct Waiter {
    let id: UUID
    let key: String
    let continuation: CheckedContinuation<Void, Error>
  }
  private var active: Set<String> = []
  private var waiters: [Waiter] = []

  func acquire(_ key: String) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if active.count < 2 && !active.contains(key) {
          active.insert(key)
          continuation.resume()
        } else {
          waiters.append(.init(id: id, key: key, continuation: continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  func release(_ key: String) {
    active.remove(key)
    while active.count < 2, let index = waiters.firstIndex(where: { !active.contains($0.key) }) {
      let waiter = waiters.remove(at: index)
      active.insert(waiter.key)
      waiter.continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
