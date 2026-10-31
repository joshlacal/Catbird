import Foundation

/// Only the initiating account's existing service-auth capability is used. Tokens stay in memory.
actor VideoServiceTokenProvider {
  typealias Mint = @MainActor @Sendable (_ expiryEpochSeconds: Int) async throws -> String
  typealias Ownership = @MainActor @Sendable () -> Bool

  private struct CachedToken {
    let value: String
    let expiry: Date
  }

  private struct Refresh {
    let id: UUID
    let expiry: Date
    var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
  }

  private let now: @Sendable () -> Date
  private let isOwner: Ownership
  private let mint: Mint
  private let refreshTimeout: TimeInterval
  private var cached: CachedToken?
  private var refresh: Refresh?

  init(
    now: @escaping @Sendable () -> Date = { Date() },
    refreshTimeout: TimeInterval = 30,
    isOwner: @escaping Ownership,
    mint: @escaping Mint
  ) {
    self.now = now
    self.refreshTimeout = refreshTimeout.isFinite ? min(120, max(0.01, refreshTimeout)) : 30
    self.isOwner = isOwner
    self.mint = mint
  }

  /// `replacing` coalesces concurrent 401s that all rejected the same cached token.
  func token(forceRefresh: Bool = false, replacing rejectedToken: String? = nil) async throws -> String {
    try Task.checkCancellation()
    guard await isOwner() else { throw CancellationError() }
    if let cached, cached.expiry.timeIntervalSince(now()) > 60,
      !forceRefresh || (rejectedToken != nil && rejectedToken != cached.value) {
      return cached.value
    }

    if let rejectedToken, cached?.value == rejectedToken { cached = nil }
    let waiterID = UUID()
    let token: String = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if refresh == nil { beginRefresh() }
        refresh?.waiters[waiterID] = continuation
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
    try Task.checkCancellation()
    guard await isOwner() else { throw CancellationError() }
    return token
  }

  private func beginRefresh() {
    let id = UUID()
    let expiry = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970) + 1_800)
    refresh = Refresh(id: id, expiry: expiry)
    let mint = mint
    let isOwner = isOwner
    refresh?.task = Task {
      do {
        var result: String?
        for attempt in 0..<3 {
          try Task.checkCancellation()
          guard await isOwner() else { throw CancellationError() }
          do {
            result = try await mint(Int(expiry.timeIntervalSince1970))
            break
          } catch {
            guard attempt < 2, VideoMultipartTransportError.isTransient(error) else { throw error }
            try await Task.sleep(nanoseconds: UInt64(500_000_000 * (1 << attempt)))
          }
        }
        guard let result, !result.isEmpty else {
          throw VideoMultipartTransportError(code: "InvalidServiceToken", message: "The account did not provide video upload authorization.")
        }
        finishRefresh(id, result: .success(result))
      } catch {
        finishRefresh(id, result: .failure(error))
      }
    }
    let timeout = refreshTimeout
    refresh?.deadline = Task {
      do {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        finishRefresh(id, result: .failure(VideoMultipartTransportError(
          code: "ServiceAuthTimedOut", message: "Video upload authorization timed out.", retryable: true
        )))
      } catch { /* A finished or abandoned refresh canceled its deadline. */ }
    }
  }

  private func finishRefresh(_ id: UUID, result: Result<String, Error>) {
    guard let active = refresh, active.id == id else { return }
    refresh = nil
    active.task?.cancel()
    active.deadline?.cancel()
    if case .success(let value) = result { cached = CachedToken(value: value, expiry: active.expiry) }
    for continuation in active.waiters.values { continuation.resume(with: result) }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let continuation = refresh?.waiters.removeValue(forKey: id) else { return }
    continuation.resume(throwing: CancellationError())
    if refresh?.waiters.isEmpty == true, let active = refresh {
      refresh = nil
      active.task?.cancel()
      active.deadline?.cancel()
    }
  }
}
