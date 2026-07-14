import Foundation

enum GatewayOAuthLegacyCallbackError: Error, Equatable {
  case configuration
  case flowInProgress
  case unauthorized
}

/// Temporary compatibility for Nest's legacy fragment callback.
/// Remove only after the conditions in the hotfix design document are met.
actor GatewayOAuthLegacyCallback {
  static let attemptLifetime: TimeInterval = 60
  static let maximumSessionIDBytes = 512

  private let callbackURL: URL
  private let uptime: @Sendable () -> TimeInterval
  private var pendingCreatedAt: TimeInterval?

  init(
    callbackURL: URL,
    uptime: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.callbackURL = callbackURL
    self.uptime = uptime
  }

  func prepareLogin(_ loginURL: URL) throws -> URL {
    if let pendingCreatedAt,
      uptime() - pendingCreatedAt <= Self.attemptLifetime
    {
      throw GatewayOAuthLegacyCallbackError.flowInProgress
    }
    pendingCreatedAt = nil

    guard Self.isValidConfiguredCallback(callbackURL) else {
      throw GatewayOAuthLegacyCallbackError.configuration
    }
    pendingCreatedAt = uptime()
    return loginURL
  }

  func consume(_ callback: URL) throws -> String {
    guard let createdAt = pendingCreatedAt else {
      throw GatewayOAuthLegacyCallbackError.unauthorized
    }
    pendingCreatedAt = nil

    guard uptime() - createdAt <= Self.attemptLifetime,
      let sessionID = Self.validatedSessionID(from: callback, expected: callbackURL)
    else {
      throw GatewayOAuthLegacyCallbackError.unauthorized
    }
    return sessionID
  }

  func cancelPendingLogin() {
    pendingCreatedAt = nil
  }

  private static func validatedSessionID(from callback: URL, expected: URL) -> String? {
    guard let callbackComponents = URLComponents(
      url: callback,
      resolvingAgainstBaseURL: false
    ),
      let expectedComponents = URLComponents(
        url: expected,
        resolvingAgainstBaseURL: false
      ),
      callback.scheme?.lowercased() == expected.scheme?.lowercased(),
      callback.host?.lowercased() == expected.host?.lowercased(),
      effectivePort(of: callback) == effectivePort(of: expected),
      callbackComponents.percentEncodedPath == expectedComponents.percentEncodedPath,
      callback.user == nil,
      callback.password == nil,
      callbackComponents.percentEncodedQuery == nil,
      let rawFragment = callbackComponents.percentEncodedFragment
    else {
      return nil
    }

    let items = rawFragment.split(separator: "&", omittingEmptySubsequences: false)
    guard items.count == 1 else { return nil }

    let parts = items[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "session_id" else { return nil }

    guard let sessionID = String(parts[1]).removingPercentEncoding else { return nil }
    guard !sessionID.isEmpty,
      sessionID.utf8.count <= maximumSessionIDBytes,
      sessionID.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e })
    else {
      return nil
    }
    return sessionID
  }

  private static func isValidConfiguredCallback(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }

    return url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "catbird.blue"
      && url.user == nil
      && url.password == nil
      && components.percentEncodedQuery == nil
      && components.percentEncodedFragment == nil
      && components.percentEncodedPath == "/oauth/callback"
      && effectivePort(of: url) == 443
  }

  private static func effectivePort(of url: URL) -> Int? {
    if let port = url.port { return port }
    return url.scheme?.lowercased() == "https" ? 443 : nil
  }
}
