import UIKit
import Synchronization

/// RAII wrapper for UIKit background task assertions.
/// Modeled after Signal's OWSBackgroundTask pattern.
///
/// Usage:
///   let task = CatbirdBackgroundTask(name: "MLSSync")
///   defer { task.end() }
///   // ... do work
///   // Task auto-released on dealloc if not explicitly ended
final class CatbirdBackgroundTask: @unchecked Sendable {
  private let state: Mutex<UIBackgroundTaskIdentifier>

  init(name: String, expirationHandler: (@Sendable () -> Void)? = nil) {
    state = Mutex(.invalid)
    // beginBackgroundTask's expiration closure escapes — capture self weakly.
    let taskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      expirationHandler?()
      self?.end()
    }
    state.withLock { $0 = taskId }
  }

  deinit { end() }

  func end() {
    state.withLock { id in
      guard id != .invalid else { return }
      UIApplication.shared.endBackgroundTask(id)
      id = .invalid
    }
  }
}

extension CatbirdBackgroundTask {
  /// Wraps async work in a background task assertion.
  /// Cancels the Task on expiration (~5s grace on iOS 18).
  static func perform<T: Sendable>(
    named name: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    let operationTask = Task<T, Error> { try await operation() }
    let bgTask = CatbirdBackgroundTask(name: name) {
      operationTask.cancel()
    }
    defer { bgTask.end() }
    return try await operationTask.value
  }
}
