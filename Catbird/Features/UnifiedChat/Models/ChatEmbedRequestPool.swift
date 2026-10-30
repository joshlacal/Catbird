import Foundation

/// Prefetch and a visible cell may need the same metadata. Cancel the underlying
/// request only when its last consumer leaves; retries get a new request identity.
@MainActor
final class ChatEmbedRequestPool<Key: Hashable & Sendable, Value: Sendable> {
  private struct Request {
    let id: UUID
    let task: Task<Value, Error>
    var consumers: Set<UUID>
  }

  private var requests: [Key: Request] = [:]

  func value(
    for key: Key,
    operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let consumer = UUID()
    let requestID: UUID
    let task: Task<Value, Error>
    if var request = requests[key] {
      request.consumers.insert(consumer)
      requests[key] = request
      requestID = request.id
      task = request.task
    } else {
      requestID = UUID()
      task = Task { try await operation() }
      requests[key] = Request(id: requestID, task: task, consumers: [consumer])
    }
    defer { release(key, requestID: requestID, consumer: consumer) }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.release(key, requestID: requestID, consumer: consumer)
      }
    }
  }

  private func release(_ key: Key, requestID: UUID, consumer: UUID) {
    guard var request = requests[key], request.id == requestID else { return }
    request.consumers.remove(consumer)
    if request.consumers.isEmpty {
      request.task.cancel()
      requests.removeValue(forKey: key)
    } else {
      requests[key] = request
    }
  }
}
