import Foundation

/// Build-level switches for surfaces that are not part of the shipping app.
///
/// Each value comes from the `CatbirdFeatures` dictionary in the bundle's Info.plist, which
/// every build configuration fills from its `CATBIRD_FEATURE_*` build settings. Encrypted chat,
/// encrypted backup and Circles have no switch here: they are part of every build, and each
/// account controls encrypted chat in Settings > Chat.
enum CatbirdFeatures {
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
