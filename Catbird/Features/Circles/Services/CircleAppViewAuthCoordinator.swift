import AuthenticationServices
import Foundation
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#endif

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
  private(set) var authorizingDID: String?
  private(set) var authorizedDID: String?
  private var generation: Int = 0

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
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self else { return }
        let targetAccountDID = (notification.userInfo?["accountDID"] as? String)
          ?? (notification.userInfo?["did"] as? String)
          ?? ""
        self.invalidate(for: targetAccountDID)
      }
    }
  }

  deinit {
    if let invalidationObserver {
      NotificationCenter.default.removeObserver(invalidationObserver)
    }
  }

  /// Drops local belief in an AppView grant for the given DID (or active DID if nil).
  func invalidate(for did: String? = nil) {
    let target = did ?? authorizedDID ?? authorizingDID ?? ""
    if target.isEmpty || target == authorizedDID || target == authorizingDID {
      generation += 1
      authorizingDID = nil
      authorizedDID = nil
      state = .idle
    }
  }

  /// True when a Circle read failed for want of an AppView grant for the given DID.
  func needsAuthorization(for did: String) -> Bool {
    if state == .authorized, authorizedDID == did {
      return false
    }
    if state == .authorizing, authorizingDID == did {
      return false
    }
    return true
  }

  /// True when a Circle read failed for want of an AppView grant.
  var needsAuthorization: Bool {
    switch state {
    case .idle, .failed: return true
    case .authorizing, .authorized: return false
    }
  }

  /// Requires completed consent, not merely an authorization attempt.
  func ensureAuthorization(did: DID, using session: WebAuthenticationSession) async throws {
    let targetDID = did.didString()
    if needsAuthorization(for: targetDID) {
      await authorize(did: did, using: session)
    }
    switch state {
    case .authorized where authorizedDID == targetDID:
      return
    case .idle:
      throw CancellationError()
    case .failed(let message):
      throw CircleError.networkError(message)
    default:
      throw CircleError.authRequired
    }
  }

  /// Presents the AppView-hosted authorization page, resolving when the AppView
  /// redirects to `blue.catbird://oauth/circle-appview`.
  ///
  /// Uses the gateway's `webAuthenticationSession` seam, waiting for its
  /// browser dismissal to finish before presenting the second consent screen.
  func authorize(did: DID, using session: WebAuthenticationSession) async {
    guard state != .authorizing else { return }
    let targetDID = did.didString()
    generation += 1
    let localGeneration = generation
    authorizingDID = targetDID
    state = .authorizing

    var components = URLComponents(
      url: baseURL.appendingPathComponent("oauth/start"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "did", value: targetDID)]
    guard let startURL = components?.url else {
      guard localGeneration == self.generation, authorizingDID == targetDID else { return }
      state = .failed("Could not build the Circle authorization URL.")
      authorizingDID = nil
      return
    }

    do {
      #if os(iOS)
      // The preceding gateway session returns its callback before UIKit has
      // finished dismissing its browser. Starting here too early loads an
      // invisible second browser and never completes authorization.
      for scene in UIApplication.shared.connectedScenes {
        guard let scene = scene as? UIWindowScene,
              scene.activationState != .background else { continue }
        for window in scene.windows where !window.isHidden {
          if let root = window.rootViewController {
            await Self.waitForPresentationTransition(in: root)
          }
        }
      }
      #endif
      guard localGeneration == self.generation, authorizingDID == targetDID else { return }
      try Task.checkCancellation()
      let callback = try await session.authenticate(
        using: startURL,
        callbackURLScheme: callbackScheme,
        preferredBrowserSession: .ephemeral
      )
      guard localGeneration == self.generation, authorizingDID == targetDID else {
        return
      }
      complete(callback: callback, expectedDID: targetDID)
    } catch where error is CancellationError
      || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
      // User dismissed the sheet. Not a failure; leave it retryable.
      guard localGeneration == self.generation, authorizingDID == targetDID else { return }
      state = .idle
      authorizingDID = nil
    } catch {
      guard localGeneration == self.generation, authorizingDID == targetDID else { return }
      state = .failed(error.localizedDescription)
      authorizingDID = nil
    }
  }

  #if os(iOS)
  /// Waits for UIKit's actual dismissal completion, not an arbitrary delay.
  static func waitForPresentationTransition(in root: UIViewController) async {
    var presenter = root
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    guard presenter.isBeingDismissed,
          let transition = presenter.transitionCoordinator else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      transition.animate(alongsideTransition: nil) { _ in
        continuation.resume()
      }
    }
  }
  #endif

  /// Completes authorization from the deep link.
  ///
  /// Reached from the presented session's return value and from
  /// `CatbirdApp`'s `.onOpenURL` when the redirect lands outside that session.
  /// Returns `false` for a URL this coordinator does not own so the caller can
  /// keep routing it.
  @discardableResult
  func complete(callback url: URL, expectedDID: String? = nil) -> Bool {
    guard url.scheme == callbackScheme,
          url.host == "oauth",
          url.lastPathComponent == "circle-appview"
    else { return false }

    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if let failure = query.first(where: { $0.name == "error" })?.value {
      state = .failed(failure)
      authorizingDID = nil
    } else {
      let targetDID = expectedDID ?? authorizingDID
      if let callbackDID = query.first(where: { $0.name == "did" })?.value,
         let targetDID, !targetDID.isEmpty, callbackDID != targetDID {
        return false
      }
      state = .authorized
      authorizedDID = targetDID
      authorizingDID = nil
    }
    return true
  }
}
