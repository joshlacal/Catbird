import Foundation

/// A caller's cancellation or deadline never cancels account-owned initialization.
@MainActor
enum MLSInitializationWaiter {
  enum Outcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    case cancelled
  }

  @MainActor
  private final class PendingWait<Value: Sendable> {
    var continuation: CheckedContinuation<Outcome<Value>, Never>?
    var observer: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ outcome: Outcome<Value>) {
      guard let continuation else { return }
      self.continuation = nil
      observer?.cancel()
      timer?.cancel()
      observer = nil
      timer = nil
      continuation.resume(returning: outcome)
    }
  }

  static func wait<Value: Sendable>(
    for task: Task<Value, Never>, timeout: TimeInterval
  ) async -> Outcome<Value> {
    let pending = PendingWait<Value>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pending.continuation = continuation
        guard !Task.isCancelled else {
          pending.finish(.cancelled)
          return
        }
        pending.observer = Task { [weak pending] in
          let value = await task.value
          pending?.finish(.completed(value))
        }
        pending.timer = Task { [weak pending] in
          do {
            try await Task.sleep(for: .seconds(max(0, timeout)))
          } catch {
            return
          }
          pending?.finish(.timedOut)
        }
      }
    } onCancel: {
      Task { @MainActor in pending.finish(.cancelled) }
    }
  }
}
