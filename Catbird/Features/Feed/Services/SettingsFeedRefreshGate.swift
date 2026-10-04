import Foundation

/// A Settings refresh belongs to one account activation and one client instance.
struct SettingsFeedRefreshContext: Equatable, Sendable {
  let accountDID: String
  let accountRevision: UInt64
  let clientIdentity: ObjectIdentifier?
}

/// Coalesces Settings requests without dropping a relaxation during an active load.
@MainActor
final class SettingsFeedRefreshGate {
  typealias IsCurrent = @MainActor () -> Bool
  private var revision: UInt64 = 0
  private var requestTask: Task<Void, Never>?
  private let pause: @MainActor () async throws -> Void

  init(pause: @escaping @MainActor () async throws -> Void = {
    try await Task.sleep(for: .milliseconds(100))
  }) {
    self.pause = pause
  }

  deinit { requestTask?.cancel() }

  func request(
    context: SettingsFeedRefreshContext,
    isCurrentContext: @escaping @MainActor (SettingsFeedRefreshContext) -> Bool,
    isLoading: @escaping @MainActor () -> Bool,
    prepare: @escaping @MainActor (@escaping IsCurrent) async -> Void,
    reload: @escaping @MainActor () async -> Void
  ) {
    revision &+= 1
    let requestRevision = revision
    requestTask?.cancel()
    let pause = self.pause
    requestTask = Task { [weak self] in
      let isCurrent: IsCurrent = { [weak self] in
        !Task.isCancelled && self?.revision == requestRevision && isCurrentContext(context)
      }
      guard isCurrent() else { return }
      await prepare(isCurrent)
      // Each wait is bounded and cancellable. The request remains pending while
      // loading, so a busy feed cannot silently discard an explicit Show edit.
      while isCurrent(), isLoading() {
        do { try await pause() } catch { return }
      }
      guard isCurrent() else { return }
      await reload()
      if self?.revision == requestRevision { self?.requestTask = nil }
    }
  }

  func cancel() {
    revision &+= 1
    requestTask?.cancel()
    requestTask = nil
  }
}
