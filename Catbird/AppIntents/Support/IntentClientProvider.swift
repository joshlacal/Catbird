//
//  IntentClientProvider.swift
//  Catbird
//
//  Builds and caches standalone ATProtoClient instances for App Intents.
//  App Intents can execute out-of-process from the host app (Shortcuts, Siri,
//  Spotlight), so this mirrors NotificationServiceExtension's standalone
//  client bootstrap (NotificationService.createStandaloneClientForUser)
//  rather than reaching into AppState/AppStateManager, which may not exist
//  in the intent's process.
//

import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import os.log

/// Vends per-account `ATProtoClient` instances to App Intents.
///
/// Intents should call `IntentClientProvider.shared.client(for:)` rather than
/// constructing an `ATProtoClient` themselves so the lexicon decoder registry
/// is guaranteed to be registered exactly once per process and clients are
/// reused across intents within the same process lifetime.
actor IntentClientProvider {
  static let shared = IntentClientProvider()

  /// One-time registration of blue.catbird.* / place.stream.* lexicon types with
  /// Petrel's decoder registry. App Intents can run in a process that never
  /// executes the main app's launch path (CatbirdApp.swift), so this can't
  /// assume registration already happened.
  private static let lexiconRegistration: Void = PetrelCatbirdLexicons.register()

  private let logger = Logger(subsystem: "blue.catbird", category: "AppIntents")

  private var clientsByDID: [String: ATProtoClient] = [:]
  private var inFlightByDID: [String: Task<ATProtoClient, Error>] = [:]

  private init() {
    _ = Self.lexiconRegistration
  }

  /// Returns a cached (or newly built) standalone client for `did`.
  /// When `did` is nil, resolves the active account via `IntentAccountResolver`
  /// and throws `IntentError.notSignedIn` if none is available.
  /// Concurrent first-time callers for the same DID share one in-flight
  /// bootstrap task (actor reentrancy would otherwise let each caller pass the
  /// cache-miss check and build a duplicate client).
  func client(for did: String?) async throws -> ATProtoClient {
    let resolvedDID: String
    if let did {
      resolvedDID = did
    } else if let activeDID = IntentAccountResolver.activeDID() {
      resolvedDID = activeDID
    } else {
      throw IntentError.notSignedIn
    }

    if let cached = clientsByDID[resolvedDID] {
      return cached
    }

    if let inFlight = inFlightByDID[resolvedDID] {
      return try await inFlight.value
    }

    let bootstrap = Task { try await self.makeStandaloneClient(for: resolvedDID) }
    inFlightByDID[resolvedDID] = bootstrap
    defer { inFlightByDID.removeValue(forKey: resolvedDID) }

    let client = try await bootstrap.value
    clientsByDID[resolvedDID] = client
    return client
  }

  /// Drops a cached client so the next `client(for:)` call rebuilds it from
  /// scratch, e.g. after an auth failure surfaced by the intent that used it.
  func invalidateClient(for did: String) {
    clientsByDID.removeValue(forKey: did)
    inFlightByDID[did]?.cancel()
    inFlightByDID.removeValue(forKey: did)
  }

  // MARK: - Client Bootstrap

  private func makeStandaloneClient(for did: String) async throws -> ATProtoClient {
    logger.info("🔐 [Intents] Creating standalone ATProtoClient for: \(did.prefix(24))...")

    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif

    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )

    let client: ATProtoClient
    do {
      client = try await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: URL(string: "https://api.catbird.blue")!,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: "did:web:api.bsky.app#bsky_appview",
        bskyChatDID: "did:web:api.bsky.chat#bsky_chat",
        accessGroup: accessGroup
      )
    } catch {
      logger.error(
        "❌ [Intents] Failed to create ATProtoClient: \(error.localizedDescription)")
      throw IntentError.accountUnavailable(did)
    }

    do {
      try await client.switchToAccount(did: did)
      logger.info("✅ [Intents] Standalone client switched to: \(did.prefix(24))...")
      return client
    } catch {
      logger.error(
        "❌ [Intents] Failed to switch standalone client to account: \(error.localizedDescription)"
      )
      throw IntentError.accountUnavailable(did)
    }
  }
}
