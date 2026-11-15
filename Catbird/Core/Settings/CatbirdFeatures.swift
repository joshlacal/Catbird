import Foundation

/// Build-level and server-driven rollout switches for features compiled into the app binary.
///
/// Each compile-time value comes from the `CatbirdFeatures` dictionary in the bundle's Info.plist,
/// which every build configuration populates from its `CATBIRD_FEATURE_*` build settings.
/// In Release builds (`R-1`), MLS Chat and Circles/Spaces are compiled in (`YES`) so one reviewed
/// binary serves both the pre-launch RC and the Dec 1 launch, while `defaultMLSPublicBetaEnabled`
/// and `defaultCirclesPublicBetaEnabled` stay strictly `false` in all non-`DEBUG` builds
/// (including TestFlight and App Store Review) unless explicitly enabled by `/oauth/client-config`
/// or an explicit local override.
enum CatbirdFeatures {
  static let appGroupSuiteName = "group.blue.catbird.shared"
  static let mlsPublicBetaEnabledKey = "mls_public_beta_enabled"
  static let circlesPublicBetaEnabledKey = "circles_public_beta_enabled"

  struct ClientFeatureConfigResponse: Equatable, Sendable {
    let mlsChatEnabled: Bool
    let circlesSpacesEnabled: Bool

    static let failClosedDisabled = ClientFeatureConfigResponse(
      mlsChatEnabled: false,
      circlesSpacesEnabled: false
    )
  }

  /// Whether the current binary has MLS chat compiled in via `Info.plist`.
  static var isMLSChatCompiledIn: Bool { isEnabled("MLSChat") }

  /// Whether the current binary has Circles / Spaces compiled in via `Info.plist`.
  static var isCirclesSpacesCompiledIn: Bool { isEnabled("CirclesSpaces") }

  /// Runtime server capability / rollout flag (`mls_public_beta_enabled`).
  /// Defaults to `true` only in `DEBUG` builds, and strictly `false` in all non-`DEBUG`
  /// builds (TestFlight and App Store) until enabled by `/oauth/client-config`.
  static var mlsPublicBetaEnabled: Bool {
    mlsPublicBetaEnabled(in: nil, defaultValue: nil)
  }

  static func mlsPublicBetaEnabled(
    in defaults: UserDefaults?,
    defaultValue: Bool? = nil
  ) -> Bool {
    readFlag(
      key: mlsPublicBetaEnabledKey,
      in: defaults,
      fallback: defaultValue ?? defaultMLSPublicBetaEnabled
    )
  }

  /// Persists or clears the server-driven `mls_public_beta_enabled` capability override.
  static func setMLSPublicBetaEnabled(_ enabled: Bool?, in defaults: UserDefaults? = nil) {
    writeFlag(enabled, key: mlsPublicBetaEnabledKey, in: defaults)
  }

  /// Runtime server capability / rollout flag (`circles_public_beta_enabled`).
  /// Defaults to `true` only in `DEBUG` builds, and strictly `false` in all non-`DEBUG`
  /// builds (TestFlight and App Store) until enabled by `/oauth/client-config`.
  static var circlesPublicBetaEnabled: Bool {
    circlesPublicBetaEnabled(in: nil, defaultValue: nil)
  }

  static func circlesPublicBetaEnabled(
    in defaults: UserDefaults?,
    defaultValue: Bool? = nil
  ) -> Bool {
    readFlag(
      key: circlesPublicBetaEnabledKey,
      in: defaults,
      fallback: defaultValue ?? defaultCirclesPublicBetaEnabled
    )
  }

  /// Persists or clears the server-driven `circles_public_beta_enabled` capability override.
  static func setCirclesPublicBetaEnabled(_ enabled: Bool?, in defaults: UserDefaults? = nil) {
    writeFlag(enabled, key: circlesPublicBetaEnabledKey, in: defaults)
  }

  static var nonDebugDefaultPublicBetaEnabled: Bool { false }

  private static var defaultMLSPublicBetaEnabled: Bool {
    #if DEBUG
    return true
    #else
    return nonDebugDefaultPublicBetaEnabled
    #endif
  }

  private static var defaultCirclesPublicBetaEnabled: Bool {
    #if DEBUG
    return true
    #else
    return nonDebugDefaultPublicBetaEnabled
    #endif
  }

  private static var defaultGatewayOrigin: URL {
    if let raw = Bundle.main.object(forInfoDictionaryKey: "CatbirdGatewayOrigin") as? String,
       let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       url.scheme != nil,
       url.host != nil
    {
      return url
    }
    return URL(string: "https://api.catbird.blue")!
  }

  /// Fetches `GET <origin>/oauth/client-config` from `nest` and updates both
  /// `mls_public_beta_enabled` and `circles_public_beta_enabled`.
  ///
  /// Strictly fail-closed (`false` for both flags) on network failure, timeout,
  /// HTTP `404` / non-`200`, or malformed JSON.
  @discardableResult
  static func refreshFromGatewayConfig(
    origin: URL = defaultGatewayOrigin,
    session: URLSession = .shared,
    defaults: UserDefaults? = nil,
    timeoutSeconds: TimeInterval = 5.0
  ) async -> ClientFeatureConfigResponse {
    let resolved = await fetchGatewayClientConfig(
      origin: origin,
      session: session,
      timeoutSeconds: timeoutSeconds
    )
    setMLSPublicBetaEnabled(resolved.mlsChatEnabled, in: defaults)
    setCirclesPublicBetaEnabled(resolved.circlesSpacesEnabled, in: defaults)
    return resolved
  }

  private static func fetchGatewayClientConfig(
    origin: URL,
    session: URLSession,
    timeoutSeconds: TimeInterval
  ) async -> ClientFeatureConfigResponse {
    let endpoint = origin.appendingPathComponent("oauth").appendingPathComponent("client-config")
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "GET"
    request.timeoutInterval = max(0.5, timeoutSeconds)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            data.count <= 65_536,
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return .failClosedDisabled
      }
      let mlsEnabled = (payload["mlsChatEnabled"] as? Bool)
        ?? (payload["mls_chat_enabled"] as? Bool)
        ?? false
      let circlesEnabled = (payload["circlesSpacesEnabled"] as? Bool)
        ?? (payload["circles_spaces_enabled"] as? Bool)
        ?? false
      return ClientFeatureConfigResponse(
        mlsChatEnabled: mlsEnabled,
        circlesSpacesEnabled: circlesEnabled
      )
    } catch {
      return .failClosedDisabled
    }
  }

  private static func readFlag(
    key: String,
    in defaults: UserDefaults?,
    fallback: Bool
  ) -> Bool {
    if let defaults, let explicit = defaults.object(forKey: key) as? Bool {
      return explicit
    }
    if defaults == nil {
      if let shared = UserDefaults(suiteName: appGroupSuiteName),
         let explicit = shared.object(forKey: key) as? Bool {
        return explicit
      }
      if let explicit = UserDefaults.standard.object(forKey: key) as? Bool {
        return explicit
      }
    }
    return fallback
  }

  private static func writeFlag(_ enabled: Bool?, key: String, in defaults: UserDefaults?) {
    if let defaults {
      if let enabled {
        defaults.set(enabled, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
      return
    }
    let targets = [UserDefaults(suiteName: appGroupSuiteName), .standard].compactMap { $0 }
    for target in targets {
      if let enabled {
        target.set(enabled, forKey: key)
      } else {
        target.removeObject(forKey: key)
      }
    }
  }

  /// End-to-end encrypted MLS group chat ("Catbird Groups").
  static var mlsChat: Bool { isMLSChatCompiledIn && mlsPublicBetaEnabled }

  /// Circles backed by private AT Protocol Spaces.
  static var circlesSpaces: Bool { isCirclesSpacesCompiledIn && circlesPublicBetaEnabled }

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
