import Foundation

/// Resolves a read-only web handoff, never a deletion request.
/// ATProto metadata identifies the OAuth issuer but defines no account-management URL.
/// Only the known Bluesky provider has an explicitly supported account-page convention.
struct AccountManagementPageResolver: Sendable {
  typealias Fetch = @Sendable (URL) async throws -> Data

  struct Destination: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case accountSettings
      case providerWebsite
    }
    let url: URL
    let kind: Kind
  }

  static let requestTimeout: TimeInterval = 8

  private let fetch: Fetch

  init(fetch: @escaping Fetch = AccountManagementPageResolver.fetchOverNetwork) {
    self.fetch = fetch
  }

  /// Unknown providers open their PDS website, without guessing an account or deletion route.
  /// Missing or invalid PDS information produces no destination.
  func destination(forPDS pdsURL: URL?) async -> Destination? {
    guard let pdsURL, let pdsOrigin = Self.origin(of: pdsURL) else { return nil }
    if Self.isKnownBlueskyOrigin(pdsOrigin) {
      return Destination(url: pdsOrigin.appendingPathComponent("account"), kind: .accountSettings)
    }
    let website = Destination(url: pdsOrigin, kind: .providerWebsite)
    let metadataURL = pdsOrigin.appendingPathComponent(".well-known/oauth-protected-resource")
    do {
      let data = try await fetch(metadataURL)
      try Task.checkCancellation()
      guard let issuer = Self.issuerOrigin(fromProtectedResourceMetadata: data, expectedResource: pdsOrigin),
            Self.isKnownBlueskyOrigin(issuer) else { return website }
      // A separate entryway must identify itself as the issuer selected by this PDS.
      let issuerData = try await fetch(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
      try Task.checkCancellation()
      guard let metadata = try? JSONDecoder().decode(AuthorizationServerMetadata.self, from: issuerData),
            let declaredIssuer = URL(string: metadata.issuer),
            Self.origin(of: declaredIssuer) == issuer else { return website }
      return Destination(url: issuer.appendingPathComponent("account"), kind: .accountSettings)
    } catch {
      return Task.isCancelled ? nil : website
    }
  }

  /// Accepts only a bare HTTPS origin, without credentials, query, fragment or a service path.
  static func origin(of url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.path.isEmpty || components.path == "/",
          components.query == nil, components.fragment == nil,
          components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host.lowercased()
    origin.port = components.port == 443 ? nil : components.port
    return origin.url
  }

  /// Binds protected-resource metadata to the exact resolved PDS before accepting an issuer.
  static func issuerOrigin(fromProtectedResourceMetadata data: Data, expectedResource: URL) -> URL? {
    guard let metadata = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data),
          let resourceURL = URL(string: metadata.resource),
          origin(of: resourceURL) == expectedResource,
          metadata.authorizationServers?.count == 1,
          let issuerString = metadata.authorizationServers?.first,
          let issuerURL = URL(string: issuerString) else { return nil }
    return origin(of: issuerURL)
  }

  private static func isKnownBlueskyOrigin(_ origin: URL) -> Bool {
    origin.host?.lowercased() == "bsky.social" && origin.port == nil
  }

  /// Hosts shown to people ("bsky.social"), without a port for the default HTTPS port.
  static func displayHost(of url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    if let port = url.port, port != 443 { return "\(host):\(port)" }
    return host
  }

  @Sendable
  static func fetchOverNetwork(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = requestTimeout
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
          http.statusCode == 200,
          http.url == url,
          http.mimeType?.lowercased() == "application/json" else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  private struct ProtectedResourceMetadata: Decodable {
    let resource: String
    let authorizationServers: [String]?

    enum CodingKeys: String, CodingKey {
      case resource
      case authorizationServers = "authorization_servers"
    }
  }

  private struct AuthorizationServerMetadata: Decodable {
    let issuer: String
  }
}
