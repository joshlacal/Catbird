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

  let target: AccountDeletionTarget
  private(set) var phase = Phase.ready
  /// The provider's account page, discovered by `AccountManagementPageResolver`. It never carries
  /// account or session details.
  private(set) var destination: URL?

  var isResolvingDestination: Bool { destination == nil }

  var canOpen: Bool {
    guard destination != nil else { return false }
    switch phase {
    case .ready, .opened, .failed:
      return !target.did.isEmpty
    case .opening, .accountChanged, .cancelled:
      return false
    }
  }

  /// Records the discovered provider page. Only plain HTTPS addresses are accepted.
  mutating func resolveDestination(_ url: URL) {
    guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return }
    destination = url
  }

  mutating func prepareToOpen(currentDID: String) -> OpeningAttempt? {
    accountDidChange(to: currentDID)
    guard canOpen, let destination else { return nil }
    let attempt = OpeningAttempt(id: UUID(), url: destination)
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
