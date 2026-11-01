import Foundation

/// A failed or incomplete probe is distinct from an explicitly unsupported server.
enum CircleCapabilityState: Sendable, Equatable {
  case unknown
  case supported
  case unsupported
}

/// Where an account's latest capability probe stands. Capability still `.unknown`
/// after a finished probe means the probe was inconclusive, not that one is coming.
enum CircleCapabilityProbeState: Sendable, Equatable {
  case notStarted
  case running
  case finished
}

/// Compatibility accessor for surfaces migrating to the account-owned gate.
@MainActor
enum CircleFeatureFlags {
  static var isEnabled: Bool {
    AppStateManager.shared.lifecycle.appState?.circlesEnabled ?? false
  }
}
