import Foundation

/// Independent rollout gate for Catbird Circles.
///
/// The feature is only enabled when both the local user/developer flag AND the
/// standalone Circle AppView capability gate report enabled (`blue.catbird.circle.getCapabilities`).
/// An unsupported AppView, network outage, unsupported PDS, or protocol revision mismatch
/// fails closed and keeps the alpha hidden.
public enum CircleFeatureFlags {
  private static let defaults = UserDefaults.standard
  private static let enabledKey = "feature.circles.enabled"

  /// AppView capability gate, populated by `CircleService.capabilities()`.
  nonisolated(unsafe) private static var serverEnabled: Bool = false

  public static func serverCapability(enabled: Bool) {
    serverEnabled = enabled
  }

  private static var isE2EMode: Bool {
    ProcessInfo.processInfo.arguments.contains("--e2e-mode")
  }

  /// True only when the local flag and the last-seen AppView capability agree.
  public static var isEnabled: Bool {
    #if DEBUG
    if isE2EMode {
      if ProcessInfo.processInfo.arguments.contains("--circles-unsupported-pds") {
        return false
      }
      if ProcessInfo.processInfo.arguments.contains("--circles-server-capable") {
        return localFlag
      }
    }
    #endif
    return localFlag && serverEnabled
  }

  public static var localFlag: Bool {
    #if DEBUG
    if isE2EMode && ProcessInfo.processInfo.arguments.contains("--enable-circles") {
      return true
    }
    #endif
    guard defaults.object(forKey: enabledKey) != nil else { return false }
    return defaults.bool(forKey: enabledKey)
  }

  public static func setLocalFlag(_ enabled: Bool) {
    defaults.set(enabled, forKey: enabledKey)
  }
}
