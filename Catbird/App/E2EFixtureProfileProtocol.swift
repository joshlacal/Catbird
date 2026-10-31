#if DEBUG
import Foundation
@testable import Petrel

/// Answers `app.bsky.actor.getProfile` for the e2e fixture's synthetic accounts, which exist only on
/// this device: the network has no profile for them, so their own profile screens could never load.
/// It handles nothing else; every other request goes to the default protocols.
final class E2EFixtureProfileProtocol: URLProtocol, @unchecked Sendable {
  struct Account: Sendable {
    let did: String
    let handle: String
    let displayName: String
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var accounts: [Account] = []

  /// Routes sessions created from now on through this protocol first, then the system defaults.
  static func install(serving accounts: [Account]) {
    lock.withLock { self.accounts = accounts }
    NetworkService.setNetworkTestProtocolClasses(
      [E2EFixtureProfileProtocol.self] + (URLSessionConfiguration.ephemeral.protocolClasses ?? []))
  }

  private static func account(for request: URLRequest) -> Account? {
    guard request.httpMethod == "GET", let url = request.url,
          url.path.hasSuffix("/xrpc/app.bsky.actor.getProfile"),
          let actor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "actor" })?.value
    else { return nil }
    return lock.withLock { accounts.first { $0.did == actor || $0.handle == actor } }
  }

  override class func canInit(with request: URLRequest) -> Bool { account(for: request) != nil }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let account = Self.account(for: request),
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]),
          let body = try? JSONSerialization.data(withJSONObject: [
            "did": account.did, "handle": account.handle, "displayName": account.displayName,
            "followersCount": 0, "followsCount": 0, "postsCount": 1,
          ])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
#endif
