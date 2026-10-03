import Foundation

/// A local handoff to the provider's account settings, never a deletion request.
struct AccountDeletionTarget: Identifiable, Equatable {
  let id = UUID()
  let did: String
  let handle: String?
}

struct AccountDeletionFlow {
  enum Phase: Equatable {
    case ready
    case opening(UUID)
    case opened
    case failed
    case accountChanged
    case cancelled
  }

  struct OpeningAttempt {
    let id: UUID
    let url: URL
  }

  // The official client supports federated PDS sign-in. Do not guess a deletion
  // URL from a handle or PDS origin, or put account/session details in this URL.
  static let accountSettingsURL = URL(string: "https://bsky.app/settings/account")!

  let target: AccountDeletionTarget
  private(set) var phase = Phase.ready

  var canOpen: Bool {
    switch phase {
    case .ready, .opened, .failed:
      return !target.did.isEmpty
    case .opening, .accountChanged, .cancelled:
      return false
    }
  }

  mutating func prepareToOpen(currentDID: String) -> OpeningAttempt? {
    accountDidChange(to: currentDID)
    guard canOpen else { return nil }
    let attempt = OpeningAttempt(id: UUID(), url: Self.accountSettingsURL)
    phase = .opening(attempt.id)
    return attempt
  }

  mutating func finishOpening(_ attemptID: UUID, accepted: Bool, currentDID: String) {
    guard phase == .opening(attemptID) else { return }
    accountDidChange(to: currentDID)
    guard phase == .opening(attemptID) else { return }
    // OS acceptance of a URL is not confirmation of provider account deletion.
    phase = accepted ? .opened : .failed
  }

  mutating func accountDidChange(to currentDID: String) {
    guard phase != .cancelled else { return }
    if target.did.isEmpty || currentDID != target.did {
      phase = .accountChanged
    }
  }

  mutating func cancel() {
    phase = .cancelled
  }
}
