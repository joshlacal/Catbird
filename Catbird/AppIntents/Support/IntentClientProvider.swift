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

import Foundation
import Petrel
import PetrelCatbirdLite
import os.log

/// Vends per-account `ATProtoClient` instances to App Intents.
///
/// Intents should call `IntentClientProvider.shared.client(for:)` rather than
/// constructing an `ATProtoClient` themselves so the lexicon decoder registry
/// is guaranteed to be registered exactly once per process and clients are
/// reused across intents within the same process lifetime.
actor IntentClientProvider {
  static let shared = IntentClientProvider()

  enum Purpose: Sendable, Equatable {
    case coveredUse
    /// Only block/unblock and their profile parameter resolution may use this.
    case safety
    /// Only unlike/unrepost/unfollow and their target resolution may use this.
    case removal
  }

  /// One-time registration of blue.catbird.* / place.stream.* lexicon types with
  /// Petrel's decoder registry. App Intents can run in a process that never
  /// executes the main app's launch path (CatbirdApp.swift), so this can't
  /// assume registration already happened.
  private static let lexiconRegistration: Void = PetrelCatbirdLiteLexicons.register()

  private let logger = Logger(subsystem: "blue.catbird", category: "AppIntents")

  private var clientsByDID: [String: ATProtoClient] = [:]
  private var inFlightByDID: [String: Task<ATProtoClient, Error>] = [:]
  private let regulatoryChecker: any AgeRegulatoryChecking
  private var accountsRequiringAgeCheck: Set<String> = []
  private var preflightsByDID: [String: Task<Void, Never>] = [:]
  init(regulatoryChecker: any AgeRegulatoryChecking = AppleAgeRangeAdapter.shared) {
    self.regulatoryChecker = regulatoryChecker
    _ = Self.lexiconRegistration
  }

  /// Returns a cached (or newly built) standalone client for `did`.
  /// When `did` is nil, resolves the active account via `IntentAccountResolver`
  /// and throws `IntentError.notSignedIn` if none is available.
  /// Concurrent first-time callers for the same DID share one in-flight
  /// bootstrap task (actor reentrancy would otherwise let each caller pass the
  /// cache-miss check and build a duplicate client).
  func client(for did: String?, purpose: Purpose = .coveredUse) async throws -> ATProtoClient {
    let resolvedDID = try resolveDID(did)
    if purpose == .coveredUse {
      try await requireCoveredUse(for: resolvedDID)
    }

    // Reuse the app's active ATProtoClient when available for this DID (P235)
    if let appClient = await resolveAppClient(for: resolvedDID) {
      return appClient
    }

    if let cached = clientsByDID[resolvedDID] {
      return cached
    }

    if let inFlight = inFlightByDID[resolvedDID] {
      let client = try await inFlight.value
      if purpose == .coveredUse {
        try await requireCoveredUse(for: resolvedDID)
      }
      return client
    }

    let bootstrap = Task { try await self.makeStandaloneClient(for: resolvedDID) }
    inFlightByDID[resolvedDID] = bootstrap
    defer { inFlightByDID.removeValue(forKey: resolvedDID) }

    let client = try await bootstrap.value
    clientsByDID[resolvedDID] = client
    if purpose == .coveredUse {
      try await requireCoveredUse(for: resolvedDID)
    }
    return client
  }

  /// Performs only a passive OS check; a headless process cannot satisfy a
  /// required age check. No age band or successful verification is retained.
  /// Call again immediately before a covered write after asynchronous preparation.
  func requireCoveredUse(for did: String?) async throws {
    let resolvedDID = try resolveDID(did)
    try Task.checkCancellation()

    // If the active AppState already evaluated age access for this account, reuse its decision
    let activeRequirement: PlatformAgeSignal.Requirement? = await MainActor.run {
      guard let appState = AppStateManager.shared.lifecycle.appState,
            appState.userDID == resolvedDID,
            !appState.ageAccess.isCheckingRequirement else { return nil }
      let requirement = appState.ageAccess.signal.requirement
      return requirement == .unavailable ? nil : requirement
    }

    if let activeRequirement {
      recordRequirement(activeRequirement, for: resolvedDID)
    } else if let preflight = preflightsByDID[resolvedDID] {
      await preflight.value
    } else {
      // Share concurrent checks for this account so an older response cannot
      // overwrite a newer requirement. The task records its result before any
      // waiter resumes; waiters never reapply an older result.
      let preflight = Task {
        let requirement = await self.regulatoryChecker.preflight().requirement
        self.recordRequirement(requirement, for: resolvedDID)
      }
      preflightsByDID[resolvedDID] = preflight
      defer { preflightsByDID.removeValue(forKey: resolvedDID) }
      await preflight.value
    }

    try Task.checkCancellation()
    guard !accountsRequiringAgeCheck.contains(resolvedDID) else {
      throw IntentError.serviceUnavailable(
        "This shortcut is unavailable under your device’s age requirements. Open Catbird to continue.")
    }
  }

  private func resolveAppClient(for did: String) async -> ATProtoClient? {
    await MainActor.run {
      guard let appState = AppStateManager.shared.lifecycle.appState,
            appState.userDID == did,
            let client = appState.atProtoClient else {
        return nil
      }
      return client
    }
  }

  private func recordRequirement(_ requirement: PlatformAgeSignal.Requirement, for did: String) {
    switch requirement {
    case .ageCheckRequired:
      accountsRequiringAgeCheck.insert(did)
    case .none:
      accountsRequiringAgeCheck.remove(did)
    case .unavailable:
      break
    }
  }

  private func resolveDID(_ did: String?) throws -> String {
    if let did { return did }
    guard let activeDID = IntentAccountResolver.activeDID() else {
      throw IntentError.notSignedIn
    }
    return activeDID
  }

  /// Drops a cached client so the next `client(for:)` call rebuilds it from
  /// scratch, e.g. after an auth failure surfaced by the intent that used it.
  func invalidateClient(for did: String) {
    // Auth invalidation must not erase an already-observed OS requirement.
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
      let accessGroup: String? = KeychainAccessGroup.resolved(
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
        gatewayURL: CatbirdGatewayConfiguration.current.origin,
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
