import CatbirdMLSCore
import Foundation

/// How a Circle key or post open failure is handled (I3). The FFI types every
/// failure as a `CircleCryptoError`; this is the one place Swift decides what
/// each class means:
///
/// - `.rejected` (`notOpenable`, `malformed`): the input itself is bad. Shown
///   as unverifiable and memoized (`CirclePostOpener.failedOpenTTL`).
/// - `.untrusted`: the sender or its epoch chain failed verification. The Rust
///   classification is new, so for now this is retryable with a warning:
///   shown as unverifiable, never memoized.
/// - `.ownerMismatch`: the Rust layer refused the Circle's owner as not the
///   Space authority (`CircleError.ownerMismatch`).
/// - `.transient` (`unavailable`, or any error that is not a
///   `CircleCryptoError`): I/O, directory, session or lock state. Retried,
///   never memoized, never shown as a verification failure.
enum CircleOpenFailure: Equatable, Sendable {
  case rejected
  case untrusted
  case ownerMismatch
  case transient

  init(_ error: any Error) {
    switch error {
    case let crypto as CircleCryptoError:
      switch crypto {
      case .notOpenable, .malformed:
        self = .rejected
      case .untrusted(let reason):
        self = Self.isOwnerAuthorityReason(reason) ? .ownerMismatch : .untrusted
      case .unavailable:
        self = .transient
      }
    case CircleError.ownerMismatch:
      self = .ownerMismatch
    default:
      self = .transient
    }
  }

  /// The Rust layer's fixed text for "owner is not the space authority"
  /// (`catbird-mls` `keys::require_owner_is_space_authority`).
  static func isOwnerAuthorityReason(_ reason: String) -> Bool {
    reason.localizedCaseInsensitiveContains("space authority")
  }

  /// Whether a result with this failure may be cached as a verdict.
  var isMemoizable: Bool { self == .rejected }
}
