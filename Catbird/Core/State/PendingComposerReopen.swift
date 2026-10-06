import Foundation
import Observation

struct PendingComposerReopen: Identifiable {
  let id: UUID
  let sourceSceneID: UUID
  let accountDID: String
  let draft: PostComposerDraft
}

enum AccountSwitchOutcome: Equatable, Sendable {
  case switched(accountDID: String, reopenID: UUID?)
  case unchanged
  case busy
  case failed(String)
  /// The target's saved session expired; the previous account stays active.
  case needsReauthentication(accountDID: String)
  case blockedBySettings(String)
  case cancelled
}

/// Serializes account-switch admission and owns single-use, scene-bound handoffs.
/// Every operation is synchronous on the UI actor, including check-and-remove.
@MainActor
@Observable
final class ComposerAccountSwitchQueue {
  struct Attempt {
    let id: UUID
    let accountDID: String
    let reopen: PendingComposerReopen?
  }

  enum Admission {
    case accepted(Attempt)
    case rejected(AccountSwitchOutcome)
  }

  private var activeAttempt: Attempt?
  private var cancellationRequested = false
  private var commitStarted = false
  private var pending: [UUID: PendingComposerReopen] = [:]
  private(set) var revision: UInt64 = 0

  var isSwitching: Bool { activeAttempt != nil }

  func isCurrent(id: UUID) -> Bool { activeAttempt?.id == id }

  func canContinue(id: UUID) -> Bool {
    isCurrent(id: id) && (!cancellationRequested || commitStarted)
  }

  func hasBegunCommit(id: UUID) -> Bool { isCurrent(id: id) && commitStarted }

  func requestCancellation(id: UUID) {
    guard isCurrent(id: id), !commitStarted else { return }
    cancellationRequested = true
  }

  /// Cancellation loses once source retirement is admitted; that commit must settle.
  func beginCommit(id: UUID) -> Bool {
    guard isCurrent(id: id), !cancellationRequested else { return false }
    commitStarted = true
    return true
  }

  func begin(
    to accountDID: String,
    transfer: ComposerEditingSnapshot?,
    authenticatedAccountDID: String?,
    isTransitioning: Bool
  ) -> Admission {
    guard activeAttempt == nil, !isTransitioning else { return .rejected(.busy) }
    guard accountDID != authenticatedAccountDID else { return .rejected(.unchanged) }
    if let transfer, transfer.claim.accountDID != authenticatedAccountDID {
      return .rejected(.failed("The composer account changed. Please reopen the account picker."))
    }

    let reopen = transfer.map {
      PendingComposerReopen(
        id: UUID(), sourceSceneID: $0.claim.sceneID, accountDID: accountDID, draft: $0.draft
      )
    }
    let attempt = Attempt(id: UUID(), accountDID: accountDID, reopen: reopen)
    // An accepted newer switch supersedes every unclaimed handoff, including A → B → A.
    pending.removeAll()
    activeAttempt = attempt
    cancellationRequested = false
    commitStarted = false
    revision &+= 1
    return .accepted(attempt)
  }

  func finish(id: UUID, authenticatedAccountDID: String?) -> AccountSwitchOutcome {
    guard let attempt = activeAttempt, attempt.id == id else { return .cancelled }
    activeAttempt = nil
    revision &+= 1
    guard !cancellationRequested || commitStarted else { return .cancelled }
    guard authenticatedAccountDID == attempt.accountDID else {
      return .failed("The requested account is not ready. Your composer has been preserved.")
    }
    if let reopen = attempt.reopen { pending[reopen.id] = reopen }
    return .switched(accountDID: attempt.accountDID, reopenID: attempt.reopen?.id)
  }

  func fail(id: UUID) {
    guard activeAttempt?.id == id else { return }
    activeAttempt = nil
    revision &+= 1
  }

  func invalidate() {
    activeAttempt = nil
    pending.removeAll()
    revision &+= 1
  }

  func pendingReopen(
    sourceSceneID: UUID, accountDID: String, authenticatedAccountDID: String?
  ) -> PendingComposerReopen? {
    guard activeAttempt == nil, authenticatedAccountDID == accountDID else { return nil }
    return pending.values.first { $0.sourceSceneID == sourceSceneID && $0.accountDID == accountDID }
  }

  func claim(
    id: UUID, sourceSceneID: UUID, accountDID: String, authenticatedAccountDID: String?
  ) -> PendingComposerReopen? {
    guard activeAttempt == nil,
          authenticatedAccountDID == accountDID,
          let reopen = pending[id],
          reopen.sourceSceneID == sourceSceneID,
          reopen.accountDID == accountDID else { return nil }
    pending.removeValue(forKey: id)
    revision &+= 1
    return reopen
  }
}

/// Logout waits for already-started authentication to settle before clearing credentials.
/// This is a completion signal, not a timing-based readiness delay.
@MainActor
final class AccountSwitchOperationBarrier {
  private var operationCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func begin() { operationCount += 1 }

  func end() {
    precondition(operationCount > 0)
    operationCount -= 1
    guard operationCount == 0 else { return }
    let completed = waiters
    waiters.removeAll()
    for waiter in completed { waiter.resume() }
  }

  func waitUntilIdle() async {
    guard operationCount > 0 else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
