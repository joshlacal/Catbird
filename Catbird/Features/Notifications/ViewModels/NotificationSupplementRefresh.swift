import Foundation

/// Owns optional feed work without making the primary feed await it.
@MainActor
final class NotificationSupplementRefresh {
  private var task: Task<Void, Never>?
  private var cancelledTask: Task<Void, Never>?
  private var generation = UUID()

  func start(_ operation: @escaping @MainActor () async -> Void) {
    guard task == nil else { return }
    let requestGeneration = UUID()
    generation = requestGeneration
    let previousTask = cancelledTask
    cancelledTask = nil
    task = Task { [weak self] in
      // Let a cancelled model request release its in-flight guard before restarting.
      await previousTask?.value
      if !Task.isCancelled { await operation() }
      guard let self, self.generation == requestGeneration else { return }
      self.task = nil
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    cancelledTask = task ?? cancelledTask
    task = nil
  }

  deinit {
    task?.cancel()
    cancelledTask?.cancel()
  }
}
