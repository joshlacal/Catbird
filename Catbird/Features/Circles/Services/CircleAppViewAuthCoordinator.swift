import AuthenticationServices
import Foundation
import Petrel
import SwiftUI

/// Drives the Circle AppView's own OAuth authorization.
///
/// The AppView is a standalone confidential client and owns its entire OAuth
/// dance server-side. This coordinator only opens the AppView-hosted
/// `/oauth/start?did=…` page and waits for the completion deep link. It runs no
/// PKCE and no PAR, performs no token exchange, and never stores an AppView
/// token: the grant lives in the AppView's own session store, keyed by DID.
///
/// Shared rather than owned by `AppState` because the completion deep link is
/// delivered to `CatbirdApp`'s `.onOpenURL`, which needs a stable instance, and
/// because `AppState` is not `@MainActor`-isolated.
@MainActor
@Observable
final class CircleAppViewAuthCoordinator {
  static let shared = CircleAppViewAuthCoordinator()

  enum State: Equatable {
    case idle
    case authorizing
    case authorized
    case failed(String)
  }

  private(set) var state: State = .idle

  private let baseURL: URL
  private let callbackScheme: String
  // Written once on the main actor at init, read once in a nonisolated deinit.
  nonisolated(unsafe) private var invalidationObserver: NSObjectProtocol?

  init(
    baseURL: URL = CircleConfiguration.appViewBaseURL,
    callbackScheme: String = "blue.catbird"
  ) {
    self.baseURL = baseURL
    self.callbackScheme = callbackScheme

    // Logout, account switch, and account removal all post this. The grant
    // itself lives in the AppView; this only drops local belief in it, so a
    // second account never inherits the first account's authorized state.
    invalidationObserver = NotificationCenter.default.addObserver(
      forName: .circleAccountInvalidated,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.state = .idle
      }
    }
  }

  deinit {
    if let invalidationObserver {
      NotificationCenter.default.removeObserver(invalidationObserver)
    }
  }

  /// True when a Circle read failed for want of an AppView grant.
  var needsAuthorization: Bool {
    switch state {
    case .idle, .failed: return true
    case .authorizing, .authorized: return false
    }
  }

  /// Presents the AppView-hosted authorization page, resolving when the AppView
  /// redirects to `blue.catbird://oauth/circle-appview`.
  ///
  /// Uses the same `webAuthenticationSession` seam as gateway login, so the
  /// second consent screen behaves identically to the first.
  func authorize(did: DID, using session: WebAuthenticationSession) async {
    guard state != .authorizing else { return }
    state = .authorizing

    var components = URLComponents(
      url: baseURL.appendingPathComponent("oauth/start"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "did", value: did.didString())]
    guard let startURL = components?.url else {
      state = .failed("Could not build the Circle authorization URL.")
      return
    }

    do {
      let callback = try await session.authenticate(
        using: startURL,
        callbackURLScheme: callbackScheme,
        preferredBrowserSession: .ephemeral
      )
      complete(callback: callback)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      // User dismissed the sheet. Not a failure; leave it retryable.
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Completes authorization from the deep link.
  ///
  /// Reached from the presented session's return value and from
  /// `CatbirdApp`'s `.onOpenURL` when the redirect lands outside that session.
  /// Returns `false` for a URL this coordinator does not own so the caller can
  /// keep routing it.
  @discardableResult
  func complete(callback url: URL) -> Bool {
    guard url.scheme == callbackScheme,
          url.host == "oauth",
          url.lastPathComponent == "circle-appview"
    else { return false }

    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if let failure = query.first(where: { $0.name == "error" })?.value {
      state = .failed(failure)
    } else {
      state = .authorized
    }
    return true
  }
}
