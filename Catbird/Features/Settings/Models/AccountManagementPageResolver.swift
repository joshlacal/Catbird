import Foundation
import OSLog

/// Finds the web page where an account's own provider lets its owner manage (and delete) the account.
///
/// OAuth sessions cannot delete accounts, so Catbird hands off to the provider. The atproto reference
/// OAuth provider, used by bsky.social and self-hosted PDSes, serves that page at `<issuer>/account`.
/// The issuer is discovered from the PDS's protected-resource metadata
/// (`/.well-known/oauth-protected-resource`, `authorization_servers[0]`).
struct AccountManagementPageResolver: Sendable {
  typealias Fetch = @Sendable (URL) async throws -> Data

  /// Used only when the account's PDS is unknown.
  static let fallbackURL = URL(string: "https://bsky.app/settings/account")!
  static let requestTimeout: TimeInterval = 8

  private static let logger = Logger(subsystem: "blue.catbird", category: "AccountManagementPage")

  private let fetch: Fetch

  init(fetch: @escaping Fetch = AccountManagementPageResolver.fetchOverNetwork) {
    self.fetch = fetch
  }

  /// The best account page for an account hosted on `pdsURL`. Never throws: discovery failures fall
  /// back to `<pds origin>/account`, and an unknown or non-HTTPS PDS falls back to `fallbackURL`.
  func accountPageURL(forPDS pdsURL: URL?) async -> URL {
    guard let pdsURL, let pdsOrigin = Self.origin(of: pdsURL) else { return Self.fallbackURL }
    let pdsAccountPage = Self.accountPage(atOrigin: pdsOrigin)
    guard let metadataURL = URL(string: "/.well-known/oauth-protected-resource", relativeTo: pdsOrigin)?.absoluteURL else {
      return pdsAccountPage
    }
    do {
      let data = try await fetch(metadataURL)
      if let issuer = Self.issuerOrigin(fromProtectedResourceMetadata: data) {
        return Self.accountPage(atOrigin: issuer)
      }
      Self.logger.info("Protected-resource metadata had no usable authorization server; using the PDS account page")
    } catch {
      Self.logger.info("Account page discovery failed: \(error.localizedDescription, privacy: .public)")
    }
    return pdsAccountPage
  }

  /// The bare HTTPS origin of `url` (scheme, host and port only), or `nil` when the URL isn't HTTPS
  /// or carries credentials.
  static func origin(of url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host.lowercased()
    origin.port = components.port
    return origin.url
  }

  /// The issuer from protected-resource metadata, accepted only when it is a bare HTTPS origin
  /// (no path beyond "/", no query, fragment or credentials), per the atproto OAuth profile.
  static func issuerOrigin(fromProtectedResourceMetadata data: Data) -> URL? {
    guard let metadata = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data),
          let issuerString = metadata.authorizationServers?.first,
          let components = URLComponents(string: issuerString),
          components.path.isEmpty || components.path == "/",
          components.query == nil, components.fragment == nil,
          let issuerURL = components.url else { return nil }
    return origin(of: issuerURL)
  }

  static func accountPage(atOrigin origin: URL) -> URL {
    origin.appendingPathComponent("account")
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
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  private struct ProtectedResourceMetadata: Decodable {
    let authorizationServers: [String]?

    enum CodingKeys: String, CodingKey {
      case authorizationServers = "authorization_servers"
    }
  }
}
