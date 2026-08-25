import Foundation

/// Independent rollout gate for Catbird Circles. The feature is only enabled
/// when both the local server flag AND the server-advertised capability gate
/// report enabled, so a draft-protocol revision mismatch or unsupported server
/// keeps the alpha hidden.
enum CircleFeatureFlags {
  private static let defaults = UserDefaults.standard
  private static let enabledKey = "feature.circles.enabled"

  /// Server capability gate, populated by `CircleService.capabilities()`.
  nonisolated(unsafe) private static var serverEnabled: Bool = false

  static func serverCapability(enabled: Bool) {
    serverEnabled = enabled
  }

  /// True only when the local flag and the last-seen server capability agree.
  static var isEnabled: Bool {
    localFlag && serverEnabled
  }

  static var localFlag: Bool {
    guard defaults.object(forKey: enabledKey) != nil else { return false }
    return defaults.bool(forKey: enabledKey)
  }

  static func setLocalFlag(_ enabled: Bool) {
    defaults.set(enabled, forKey: enabledKey)
  }
}
