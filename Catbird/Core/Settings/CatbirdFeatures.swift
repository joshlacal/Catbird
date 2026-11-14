import Foundation

/// Build-level switches for features that live in the codebase but stay off in builds
/// that are not ready to ship them.
///
/// Each value comes from the `CatbirdFeatures` dictionary in the bundle's Info.plist,
/// which every build configuration fills from its `CATBIRD_FEATURE_*` build settings.
/// A missing key reads as off, so a target that never declares a feature never runs it.
/// These gates sit above the runtime ones (per-account MLS opt-in, the server's Circle
/// capability probe): a feature runs only when its switch here is on *and* its runtime
/// gate allows it.
enum CatbirdFeatures {
  static let appGroupSuiteName = "group.blue.catbird.shared"
  static let mlsPublicBetaEnabledKey = "mls_public_beta_enabled"

  /// Whether the current binary has MLS chat compiled in via `Info.plist`.
  static var isMLSChatCompiledIn: Bool { isEnabled("MLSChat") }

  /// Runtime server capability / rollout flag (`mls_public_beta_enabled`).
  /// Defaults to `true` in `DEBUG` and TestFlight (`sandboxReceipt`) builds, and `false`
  /// on production App Store builds until enabled by server capability configuration.
  static var mlsPublicBetaEnabled: Bool {
    mlsPublicBetaEnabled(in: nil, defaultValue: nil)
  }

  static func mlsPublicBetaEnabled(
    in defaults: UserDefaults?,
    defaultValue: Bool? = nil
  ) -> Bool {
    if let defaults, let explicit = defaults.object(forKey: mlsPublicBetaEnabledKey) as? Bool {
      return explicit
    }
    if defaults == nil {
      if let shared = UserDefaults(suiteName: appGroupSuiteName),
         let explicit = shared.object(forKey: mlsPublicBetaEnabledKey) as? Bool {
        return explicit
      }
      if let explicit = UserDefaults.standard.object(forKey: mlsPublicBetaEnabledKey) as? Bool {
        return explicit
      }
    }
    return defaultValue ?? defaultMLSPublicBetaEnabled
  }

  /// Persists or clears the server-driven `mls_public_beta_enabled` capability override.
  static func setMLSPublicBetaEnabled(_ enabled: Bool?, in defaults: UserDefaults? = nil) {
    if let defaults {
      if let enabled {
        defaults.set(enabled, forKey: mlsPublicBetaEnabledKey)
      } else {
        defaults.removeObject(forKey: mlsPublicBetaEnabledKey)
      }
      return
    }
    let targets = [UserDefaults(suiteName: appGroupSuiteName), .standard].compactMap { $0 }
    for target in targets {
      if let enabled {
        target.set(enabled, forKey: mlsPublicBetaEnabledKey)
      } else {
        target.removeObject(forKey: mlsPublicBetaEnabledKey)
      }
    }
  }

  private static var defaultMLSPublicBetaEnabled: Bool {
    #if DEBUG
    return true
    #else
    return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    #endif
  }

  /// End-to-end encrypted MLS group chat ("Catbird Groups").
  static var mlsChat: Bool { isMLSChatCompiledIn && mlsPublicBetaEnabled }

  /// Circles backed by private AT Protocol Spaces.
  static var circlesSpaces: Bool { isEnabled("CirclesSpaces") }

  /// Live status and live event surfaces.
  static var live: Bool { isEnabled("Live") }

  /// Repository browser and repository backup.
  static var repositoryTools: Bool { isEnabled("RepositoryTools") }

  private static func isEnabled(_ key: String) -> Bool {
    flags[key] ?? false
  }

  /// Resolved once from Info.plist into plain booleans so any isolation domain can read it.
  private static let flags: [String: Bool] = {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: "CatbirdFeatures") as? [String: Any] else {
      return [:]
    }
    return raw.compactMapValues { value in
      switch value {
      case let flag as Bool:
        return flag
      case let text as String:
        return ["yes", "true", "1"].contains(text.lowercased())
      case let number as NSNumber:
        return number.boolValue
      default:
        return nil
      }
    }
  }()
}
