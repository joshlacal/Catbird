import Foundation
import OSLog
import Petrel

/// Centralized container for preview app state with real network access.
///
/// Authentication priority:
/// 1. PreviewAuthManager (xcconfig credentials) → self-contained, no running app needed
/// 2. AppStateManager.shared (if app is running and logged in) → reuses existing session
/// 3. nil → triggers skeleton/placeholder UI in preview modifiers
///
/// Usage:
/// ```swift
/// #Preview {
///   MyView()
///     .previewWithAuthenticatedState()
/// }
/// ```
@MainActor
final class PreviewContainer {
  static let shared = PreviewContainer()

  /// DID of the fixture bot (`catbirdbot.bsky.social`) — the account all preview fixtures are
  /// authored as or interact with. See `scripts/preview-fixtures/README.md` (workspace-root repo).
  static let fixtureUserDID = "did:plc:oq3qa6f332ergklpj2dvd3up"

  private let logger = Logger(subsystem: "blue.catbird", category: "Preview")
  private var cachedAppState: AppState?
  private var hasAttemptedAuth = false
  private static var cachedFixtureAppState: AppState?

  private init() {}

  /// Main entry point: returns an authenticated AppState for previews.
  /// Tries xcconfig credentials first, then falls back to running app session.
  var appState: AppState? {
    get async {
      if let cached = cachedAppState { return cached }
      if hasAttemptedAuth { return nil }
      hasAttemptedAuth = true

      // Strategy 1: Self-authenticate via PreviewAuthManager (xcconfig credentials)
      if PreviewAuthManager.shared.isConfigured {
        if let client = await PreviewAuthManager.shared.getClient(),
          let did = PreviewAuthManager.shared.cachedUserDID
        {
          let state = AppState(userDID: did, client: client)
          cachedAppState = state
          logger.info("Preview using xcconfig-authenticated AppState for: \(did)")
          return state
        }
      }

      // Strategy 2: Fall back to AppStateManager.shared (requires running app login)
      await AppStateManager.shared.initialize()
      if case .authenticated(let state) = AppStateManager.shared.lifecycle {
        cachedAppState = state
        logger.info("Preview using running app AppState for: \(state.userDID)")
        return state
      }

      logger.warning("No preview authentication available — configure PreviewSecrets.xcconfig")
      return nil
    }
  }

  /// Access to the app state manager
  var appStateManager: AppStateManager {
    AppStateManager.shared
  }

  /// Access to auth manager
  var authManager: AuthenticationManager {
    AppStateManager.shared.authentication
  }

  // MARK: - Fixture-backed AppState (no network, no login)

  /// Returns a cached AppState backed by the fixture bot DID, with zero network access and zero
  /// login — used by `.mock`-mode previews and fixture-first `#Preview` blocks. Constructing the
  /// underlying `ATProtoClient` requires `await` (local keychain/namespace setup) but never calls
  /// `loginWithPassword`, so it works with zero credentials configured.
  static func fixtureAppState() async -> AppState {
    if let cached = cachedFixtureAppState { return cached }

    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )

    do {
      let client = try await ATProtoClient(
        baseURL: URL(string: "https://bsky.social")!,
        oauthConfig: oauthConfig,
        namespace: "blue.catbird.preview-fixtures",
        authMode: .legacy,
        userAgent: "Catbird/1.0-Preview"
      )
      let state = AppState(userDID: fixtureUserDID, client: client)
      cachedFixtureAppState = state
      shared.logger.info("Preview using unauthenticated fixture AppState for: \(fixtureUserDID, privacy: .public)")
      return state
    } catch {
      // Construction here is purely local (keychain/namespace setup) and makes no network
      // call, so this should never fail in practice — recover by asserting rather than
      // threading Optional through every fixture-first preview call site.
      preconditionFailure("PreviewContainer.fixtureAppState: ATProtoClient construction failed unexpectedly: \(error)")
    }
  }
}
