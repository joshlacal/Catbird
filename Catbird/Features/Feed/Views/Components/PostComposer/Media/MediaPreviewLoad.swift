import Foundation

/// Tracks the current preparation attempt independently of attachment and draft identity.
@MainActor
final class MediaPreviewLoadRegistry {
  private var attempts: [UUID: MediaPreviewLoadAttempt] = [:]

  func begin(for mediaID: UUID, timeout: Duration = .seconds(120)) -> MediaPreviewLoadAttempt {
    cancel(for: mediaID)
    let attempt = MediaPreviewLoadAttempt(timeout: timeout)
    attempts[mediaID] = attempt
    return attempt
  }

  func owns(_ attempt: MediaPreviewLoadAttempt, for mediaID: UUID) -> Bool {
    attempts[mediaID]?.id == attempt.id
  }

  @discardableResult
  func finish(_ attempt: MediaPreviewLoadAttempt, for mediaID: UUID) -> Bool {
    guard owns(attempt, for: mediaID) else { return false }
    attempts[mediaID] = nil
    attempt.cancel()
    return true
  }

  func cancel(for mediaID: UUID) {
    attempts.removeValue(forKey: mediaID)?.cancel()
  }
}

enum MediaPreviewLoadError: Error {
  case timedOut
}

@MainActor
final class MediaPreviewLoadAttempt {
  let id = UUID()
  private let deadline: ContinuousClock.Instant
  private var isCancelled = false
  private var cancelWork: (() -> Void)?

  init(timeout: Duration) {
    deadline = ContinuousClock.now.advanced(by: timeout)
  }

  func cancel() {
    isCancelled = true
    cancelWork?()
    cancelWork = nil
  }

  /// Cancellation resumes the caller without waiting for Photos/AVFoundation to cooperate.
  /// Operations return values only; callers validate ownership before applying any result.
  func value<Value: Sendable>(
    _ operation: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    guard !isCancelled else { throw CancellationError() }
    guard ContinuousClock.now < deadline else { throw MediaPreviewLoadError.timedOut }
    let race = MediaPreviewLoadRace<Value>()
    cancelWork = { race.resolve(.failure(CancellationError())) }
    defer { cancelWork = nil }
    let value = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        race.start(deadline: deadline, continuation: continuation, operation: operation)
      }
    } onCancel: {
      Task { @MainActor in race.resolve(.failure(CancellationError())) }
    }
    try Task.checkCancellation()
    guard !isCancelled else { throw CancellationError() }
    guard ContinuousClock.now < deadline else { throw MediaPreviewLoadError.timedOut }
    return value
  }
}

@MainActor
private final class MediaPreviewLoadRace<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, any Error>?
  private var worker: Task<Void, Never>?
  private var timer: Task<Void, Never>?

  func start(
    deadline: ContinuousClock.Instant,
    continuation: CheckedContinuation<Value, any Error>,
    operation: @escaping @MainActor () async throws -> Value
  ) {
    self.continuation = continuation
    worker = Task { @MainActor [weak self] in
      do {
        let value = try await operation()
        self?.resolve(.success(value))
      } catch {
        self?.resolve(.failure(error))
      }
    }
    timer = Task { @MainActor [weak self] in
      do {
        try await ContinuousClock().sleep(until: deadline)
        self?.resolve(.failure(MediaPreviewLoadError.timedOut))
      } catch {
        // Resolving the race cancels its deadline task.
      }
    }
  }

  func resolve(_ result: Result<Value, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    worker?.cancel()
    timer?.cancel()
    worker = nil
    timer = nil
    continuation.resume(with: result)
  }
}
