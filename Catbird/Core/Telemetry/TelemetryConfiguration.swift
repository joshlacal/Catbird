import Foundation

/// Routing is approved in the app's build configuration, never by a runtime host override.
struct TelemetryConfiguration: Sendable {
  enum Backend: String, Sendable {
    case glitchTip = "glitchtip"
    case disabled
  }

  let backend: Backend
  let dsn: String?

  static func resolve(environment: [String: String], info: [String: Any]) -> Self {
    let disabled = Self(backend: .disabled, dsn: nil)
    func configured(_ key: String) -> String? {
      // An explicitly empty/invalid override disables; it must not revive a bundle value.
      validatedValue(environment[key] ?? info[key] as? String)
    }

    guard configured("CATBIRD_TELEMETRY_BACKEND") == Backend.glitchTip.rawValue,
      // Only a build-supplied bundle value can approve a destination host.
      let approved = validatedValue(info["CATBIRD_GLITCHTIP_ALLOWED_HOST"] as? String),
      let approvedHost = approvedHost(approved),
      let dsn = configured("GLITCHTIP_DSN"),
      !dsn.contains("%"),
      !dsn.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
      let url = URLComponents(string: dsn),
      let host = url.host?.lowercased(), host == approvedHost,
      let key = url.user, !key.isEmpty,
      key.utf8.allSatisfy({ asciiLetterOrNumber($0) || $0 == 45 || $0 == 95 }),
      url.password == nil, url.query == nil, url.fragment == nil,
      let project = url.path.split(separator: "/").last,
      url.path == "/" + project,
      project.utf8.allSatisfy({ (48...57).contains($0) }),
      project.utf8.contains(where: { $0 != 48 }),
      url.port.map({ (1...65_535).contains($0) }) ?? true,
      let authority = dsn.components(separatedBy: "://").last?.split(separator: "/").first,
      !authority.hasSuffix(":") else { return disabled }

    let loopback = host == "localhost" || canonicalIPv4(host)?.first == 127
    #if CATBIRD_TELEMETRY_PILOT
    let allowedScheme = url.scheme == "https" || (loopback && url.scheme == "http")
    #else
    let allowedScheme = !loopback && url.scheme == "https"
    #endif
    guard allowedScheme else { return disabled }
    return Self(backend: .glitchTip, dsn: dsn)
  }

  private static func validatedValue(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, !raw.contains("$("),
      raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return raw
  }

  private static func approvedHost(_ raw: String) -> String? {
    let host = raw.lowercased()
    guard host.utf8.count <= 253, !host.hasSuffix("."), !host.hasSuffix(".localhost"),
      host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
          && label.utf8.allSatisfy({ asciiLetterOrNumber($0) || $0 == 45 })
      }), !["sentry.io", "sentry.dev", "getsentry.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
      }) else { return nil }
    // Reject short, integer, octal and hex IPv4 aliases rather than guessing their resolution.
    let numericAddress = host.split(separator: ".").allSatisfy { part in
      part.utf8.allSatisfy({ (48...57).contains($0) })
        || (part.hasPrefix("0x") && part.dropFirst(2).utf8.allSatisfy({
          (48...57).contains($0) || (97...102).contains($0)
        }))
    }
    guard !numericAddress || canonicalIPv4(host) != nil else { return nil }
    return host
  }

  private static func canonicalIPv4(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [Int] = []
    for part in parts {
      guard let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
      octets.append(value)
    }
    return octets
  }

  private static func asciiLetterOrNumber(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
