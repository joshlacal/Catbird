import Foundation

/// Waits between completed native calls, so cooldowns hold no native operation locks.
@MainActor
enum MLSConversationCreationRetry {
  static func run<Value>(
    isCurrent: () -> Bool,
    retryAfter: (Error) -> TimeInterval?,
    onProgress: (String) -> Void,
    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: () async throws -> Value
  ) async throws -> Value {
    func checkCurrent() throws {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
    }
    for attempt in 1...3 {
      try checkCurrent()
      onProgress(attempt == 1 ? "Setting up secure conversation..." : "Trying secure conversation again...")
      do {
        let result = try await operation()
        try checkCurrent()
        return result
      } catch {
        try checkCurrent()
        guard attempt < 3, let delay = retryAfter(error),
              delay.isFinite, delay > 0, delay <= 901 else { throw error }
        var remaining = delay
        while remaining > 0 {
          try checkCurrent()
          onProgress("Secure chat is busy. Trying again in \(Int(ceil(remaining))) seconds...")
          let interval = min(1, remaining)
          try await sleep(interval)
          remaining -= interval
        }
      }
    }
    preconditionFailure("Every final attempt returns or throws")
  }
}
