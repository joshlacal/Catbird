import Foundation

/// Resolves a read-only web handoff, never a deletion request.
/// ATProto metadata identifies the OAuth issuer but defines no account-management URL.
/// Supports reference ATProto providers (bsky.social, self-hosted reference PDS, Swan)
/// and probes `/account` support using HTTP navigation headers.
struct AccountManagementPageResolver: Sendable {
  typealias Fetch = @Sendable (URL) async throws -> Data
  typealias Probe = @Sendable (URLRequest) async -> Bool

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
  private let probe: Probe

  init(
    fetch: @escaping Fetch = AccountManagementPageResolver.fetchOverNetwork,
    probe: @escaping Probe = AccountManagementPageResolver.probeOverNetwork
  ) {
    self.fetch = fetch
    self.probe = probe
  }

  /// Discovers authoritative OAuth issuer from PDS metadata and probes /account support.
  /// Falls back safely to the provider website root if /account fails.
  func destination(
    forPDS pdsURL: URL?,
    accountHandle: String? = nil,
    userDID: String? = nil
  ) async -> Destination? {
    guard let pdsURL, let pdsOrigin = Self.origin(of: pdsURL) else { return nil }
    let website = Destination(url: pdsOrigin, kind: .providerWebsite)
    let loginHint = (accountHandle?.isEmpty == false ? accountHandle : userDID)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    var targetOrigin: URL?
    if Self.isKnownBlueskyOrigin(pdsOrigin) {
      targetOrigin = pdsOrigin
    } else {
      let metadataURL = pdsOrigin.appendingPathComponent(".well-known/oauth-protected-resource")
      do {
        let data = try await fetch(metadataURL)
        try Task.checkCancellation()
        guard let issuer = Self.issuerOrigin(fromProtectedResourceMetadata: data, expectedResource: pdsOrigin) else {
          return website
        }
        if issuer == pdsOrigin {
          // Self-hosted reference PDS (acts as its own authorization server)
          targetOrigin = pdsOrigin
        } else if Self.isKnownBlueskyOrigin(issuer) || Self.isKnownSwanOrigin(issuer) {
          // A separate reference entryway must identify itself as the issuer selected by this PDS.
          let issuerData = try await fetch(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
          try Task.checkCancellation()
          guard let metadata = try? JSONDecoder().decode(AuthorizationServerMetadata.self, from: issuerData),
                let declaredIssuer = URL(string: metadata.issuer),
                Self.origin(of: declaredIssuer) == issuer else { return website }
          targetOrigin = issuer
        } else {
          // An unknown separate issuer does not become an invented management page.
          return website
        }
      } catch {
        return Task.isCancelled ? nil : website
      }
    }

    guard let origin = targetOrigin else { return website }

    let accountURL = origin.appendingPathComponent("account")
    let probeRequest = Self.makeNavigationProbeRequest(for: accountURL)
    let supportsAccount = await probe(probeRequest)
    if Task.isCancelled { return nil }

    if supportsAccount {
      let finalURL: URL
      if let loginHint, !loginHint.isEmpty {
        finalURL = Self.appendLoginHint(loginHint, to: accountURL)
      } else {
        finalURL = accountURL
      }
      return Destination(url: finalURL, kind: .accountSettings)
    } else {
      return website
    }
  }

  /// Appends a target login_hint query parameter scoping the provider UI to the deleted account.
  static func appendLoginHint(_ hint: String, to url: URL) -> URL {
    guard !hint.isEmpty,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "login_hint", value: hint))
    components.queryItems = queryItems
    return components.url ?? url
  }

  /// Builds a probe request using HTTP navigation metadata headers.
  static func makeNavigationProbeRequest(for url: URL) -> URLRequest {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    request.httpMethod = "GET"
    request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
    request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    return request
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

  static func isKnownBlueskyOrigin(_ origin: URL) -> Bool {
    guard let host = origin.host?.lowercased() else { return false }
    return (host == "bsky.social" || host.hasSuffix(".bsky.social")) && origin.port == nil
  }

  static func isKnownSwanOrigin(_ origin: URL) -> Bool {
    guard let host = origin.host?.lowercased() else { return false }
    return (host == "swan.place" || host.hasSuffix(".swan.place")) && origin.port == nil
  }

  static func isReferenceProvider(_ origin: URL, pdsOrigin: URL) -> Bool {
    if isKnownBlueskyOrigin(origin) || isKnownSwanOrigin(origin) {
      return true
    }
    return origin == pdsOrigin
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

  @Sendable
  static func probeOverNetwork(_ request: URLRequest) async -> Bool {
    guard let url = request.url else { return false }
    if isKnownBlueskyOrigin(url) {
      return true
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = requestTimeout
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200...399).contains(http.statusCode)
    } catch {
      return false
    }
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
