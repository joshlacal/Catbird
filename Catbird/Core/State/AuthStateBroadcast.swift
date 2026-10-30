import Foundation

/// Delivers every auth state change to every subscriber. One shared AsyncStream
/// hands each element to only one of its concurrent iterators, and cancelling
/// any iterator finishes it for all of them, so each subscriber gets its own.
final class AuthStateBroadcast: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]

  /// A stream of the states yielded after this call, preceded by `current`
  /// when given. It unsubscribes itself when its iteration ends or is cancelled.
  ///
  /// `current` must be read on the same actor that calls `yield` (the main
  /// actor for AuthenticationManager); otherwise a change made between that
  /// read and this call is lost.
  func subscribe(startingWith current: AuthState? = nil) -> AsyncStream<AuthState> {
    let (stream, continuation) = AsyncStream<AuthState>.makeStream()
    if let current {
      continuation.yield(current)
    }
    let id = UUID()
    lock.lock()
    continuations[id] = continuation
    lock.unlock()
    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(id)
    }
    return stream
  }

  func yield(_ state: AuthState) {
    lock.lock()
    let subscribers = Array(continuations.values)
    lock.unlock()
    for subscriber in subscribers {
      subscriber.yield(state)
    }
  }

  /// Ends every subscriber's stream; the owner is going away. Dropping a
  /// continuation does not finish its stream, so without this a subscriber's
  /// `for await` would wait forever.
  func finishAll() {
    lock.lock()
    let subscribers = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    // Finish outside the lock: finish() runs onTermination, which takes it.
    for subscriber in subscribers {
      subscriber.finish()
    }
  }

  var subscriberCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return continuations.count
  }

  private func unsubscribe(_ id: UUID) {
    lock.lock()
    continuations[id] = nil
    lock.unlock()
  }
}
