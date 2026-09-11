import Foundation

/// A failed or incomplete probe is distinct from an explicitly unsupported server.
enum CircleCapabilityState: Sendable, Equatable {
  case unknown
  case supported
  case unsupported
}

/// Compatibility accessor for surfaces migrating to the account-owned gate.
@MainActor
enum CircleFeatureFlags {
  static var isEnabled: Bool {
    AppStateManager.shared.lifecycle.appState?.circlesEnabled ?? false
  }
}
