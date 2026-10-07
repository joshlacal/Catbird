import Foundation

/// A local handoff to the provider's account settings, never a deletion request.
struct AccountDeletionTarget: Identifiable, Equatable {
  enum Purpose: Equatable {
    case manageAccount
    case deletionOptions
  }
  let id = UUID()
  let did: String
  let handle: String?
  let accountRevision: UInt64
  var purpose: Purpose = .deletionOptions
}

struct AccountDeletionFlow {
  enum Phase: Equatable {
    case ready
    case opening(UUID)
    case opened
    case failed
    case unavailable
    case accountChanged
    case cancelled
  }

  struct OpeningAttempt {
    let id: UUID
    let url: URL
  }

  let target: AccountDeletionTarget
  private(set) var phase = Phase.ready
  /// The destination never carries account or session details.
  private(set) var destination: AccountManagementPageResolver.Destination?

  var isResolvingDestination: Bool { phase == .ready && destination == nil }

  var canOpen: Bool {
    guard destination != nil else { return false }
    switch phase {
    case .ready, .opened, .failed:
      return !target.did.isEmpty
    case .opening, .unavailable, .accountChanged, .cancelled:
      return false
    }
  }

  /// Late discovery cannot attach a destination to a changed or cancelled account context.
  mutating func resolveDestination(
    _ result: AccountManagementPageResolver.Destination?,
    currentDID: String,
    currentRevision: UInt64
  ) {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .ready, destination == nil else { return }
    guard let result else {
      phase = .unavailable
      return
    }
    let url = result.url
    guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
      phase = .unavailable
      return
    }
    destination = result
  }

  mutating func prepareToOpen(currentDID: String, currentRevision: UInt64) -> OpeningAttempt? {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard canOpen, let destination else { return nil }
    let attempt = OpeningAttempt(id: UUID(), url: destination.url)
    phase = .opening(attempt.id)
    return attempt
  }

  mutating func finishOpening(_ attemptID: UUID, accepted: Bool, currentDID: String, currentRevision: UInt64) {
    guard phase == .opening(attemptID) else { return }
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .opening(attemptID) else { return }
    // OS acceptance of a URL is not confirmation of provider account deletion.
    phase = accepted ? .opened : .failed
  }

  mutating func accountDidChange(to currentDID: String, revision: UInt64) {
    guard phase != .cancelled else { return }
    if target.did.isEmpty || currentDID != target.did || revision != target.accountRevision {
      phase = .accountChanged
      destination = nil
    }
  }

  mutating func cancel() {
    phase = .cancelled
  }
}
