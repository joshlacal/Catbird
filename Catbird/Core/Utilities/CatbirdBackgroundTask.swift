#if os(iOS)
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
    let taskId: UIBackgroundTaskIdentifier = {
      let begin = {
        UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
          expirationHandler?()
          self?.end()
        }
      }
      if Thread.isMainThread {
        return begin()
      } else {
        return DispatchQueue.main.sync(execute: begin)
      }
    }()
    state.withLock { $0 = taskId }
  }

  deinit { end() }

  func end() {
    let taskId: UIBackgroundTaskIdentifier? = state.withLock { id in
      guard id != .invalid else { return nil }
      let captured = id
      id = .invalid
      return captured
    }

    guard let taskId else { return }
    if Thread.isMainThread {
      UIApplication.shared.endBackgroundTask(taskId)
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.endBackgroundTask(taskId)
      }
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

#else

/// No-op on macOS — background tasks are not needed.
final class CatbirdBackgroundTask: @unchecked Sendable {
  init(name: String, expirationHandler: (@Sendable () -> Void)? = nil) {}
  func end() {}

  static func perform<T: Sendable>(
    named name: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    try await operation()
  }
}

#endif
