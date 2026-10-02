import Foundation
import Observation

/// Owns the editable draft independently of outstanding network operations.
/// A revision changes on every edit, even when text is changed back to its old value.
@MainActor
@Observable
final class MessageDraft<Value> {
  struct Submission {
    let value: Value
    fileprivate let revision: UUID
  }

  var value: Value {
    didSet { revision = UUID() }
  }
  private let emptyValue: Value
  private var revision = UUID()
  private var pendingRevisions: Set<UUID> = []

  init(_ emptyValue: Value) {
    self.emptyValue = emptyValue
    self.value = emptyValue
  }

  /// Capture synchronously at the button tap, before starting an async task.
  func beginSend() -> Submission? {
    guard pendingRevisions.insert(revision).inserted else { return nil }
    return Submission(value: value, revision: revision)
  }

  /// Hand a snapshot to async work without letting scheduling change its owner.
  @discardableResult
  func submitSend(
    using operation: @escaping @MainActor (Value) async -> Bool
  ) -> Task<Void, Never>? {
    guard let submission = beginSend() else { return nil }
    return Task { @MainActor in
      let succeeded = await operation(submission.value)
      self.finishSend(submission, succeeded: succeeded)
    }
  }

  func finishSend(_ submission: Submission, succeeded: Bool) {
    guard pendingRevisions.remove(submission.revision) != nil else { return }
    if succeeded, revision == submission.revision {
      value = emptyValue
    }
  }
}
