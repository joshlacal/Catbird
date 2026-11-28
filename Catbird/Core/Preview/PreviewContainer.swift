import Foundation
import OSLog
import Petrel
#if os(iOS)
import UIKit
#endif

/// Centralized container for preview app state with real or offline fixture access.
///
/// Authentication priority:
/// 1. PreviewAuthManager (xcconfig credentials) -> self-contained, no running app needed
/// 2. AppStateManager.shared (if app is running and logged in) -> reuses existing session
/// 3. nil -> triggers skeleton/placeholder UI in preview modifiers (or use `mode: .mock` /
///    `fixtureAppState()` for zero-credential, zero-network fixture rendering)
///
/// Usage:
/// ```swift
/// #Preview {
///   MyView()
///     .previewWithAuthenticatedState(mode: .mock)
/// }
/// ```
@MainActor
final class PreviewContainer {
  static let shared = PreviewContainer()

  /// DID of the fixture bot (`catbirdbot.bsky.social`) — the account all preview fixtures are
  /// authored as or interact with. See `scripts/preview-fixtures/README.md` (workspace root).
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
           let did = PreviewAuthManager.shared.cachedUserDID {
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

  // MARK: - Fixture-backed AppState (no network, no login, no keychain)

  /// Returns a cached offline `AppState` backed by the fixture bot DID and
  /// `OfflineFixtureURLProtocol` — zero network access, zero login, zero keychain.
  static func fixtureAppState() async -> AppState {
    if let cached = cachedFixtureAppState { return cached }

    #if DEBUG
    let client: ATProtoClient
    if let hookedClient = try? await OfflineFixtureURLProtocol.withNetworkTestHook(strict: false, construct: {
      await ATProtoClient(
        baseURL: URL(string: "https://127.0.0.1")!,
        userAgent: "Catbird/1.0-Preview"
      )
    }) {
      client = hookedClient
    } else {
      client = await ATProtoClient(
        baseURL: URL(string: "https://127.0.0.1")!,
        userAgent: "Catbird/1.0-Preview"
      )
    }
    #else
    let client = await ATProtoClient(
      baseURL: URL(string: "https://127.0.0.1")!,
      userAgent: "Catbird/1.0-Preview"
    )
    #endif
    let state = AppState(
      userDID: fixtureUserDID,
      client: client,
      regulatoryChecker: PreviewOfflineAgeChecker()
    )
    #if DEBUG
    if let bot = PreviewFixtures.profileBot {
      state.currentUserProfile = AppBskyActorDefs.ProfileViewBasic(
        did: bot.did,
        handle: bot.handle,
        displayName: bot.displayName,
        pronouns: bot.pronouns,
        avatar: bot.avatar,
        associated: bot.associated,
        viewer: bot.viewer,
        labels: bot.labels,
        createdAt: bot.createdAt,
        verification: bot.verification,
        status: bot.status,
        debug: bot.debug
      )
    }
    #endif
    cachedFixtureAppState = state
    shared.logger.info("Preview using offline fixture AppState for: \(fixtureUserDID, privacy: .public)")
    return state
  }
}

/// Deterministic no-prompt age checker for offline previews and catalog fixtures.
struct PreviewOfflineAgeChecker: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal {
    PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
  }

  #if os(iOS)
  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
    nil
  }
  #endif
}
