import Foundation

/// Runtime availability for the shipped Catbird Circles feature.
///
/// The standalone AppView capability is global rather than account-specific.
/// Start optimistic so a transient probe failure never removes Circles from the
/// UI or falsely labels the active PDS unsupported. Only an explicit disabled
/// response from the AppView disables Circle-backed surfaces.
public enum CircleFeatureFlags {
  nonisolated(unsafe) private static var serverEnabled = true

  public static func serverCapability(enabled: Bool) {
    serverEnabled = enabled
  }

  public static var isEnabled: Bool {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--e2e-mode") {
      if ProcessInfo.processInfo.arguments.contains("--circles-unsupported-pds") {
        return false
      }
      if ProcessInfo.processInfo.arguments.contains("--circles-server-capable") {
        return true
      }
    }
    #endif
    return serverEnabled
  }
}
