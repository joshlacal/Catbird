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
  /// End-to-end encrypted MLS group chat ("Catbird Groups").
  static var mlsChat: Bool { isEnabled("MLSChat") }

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
