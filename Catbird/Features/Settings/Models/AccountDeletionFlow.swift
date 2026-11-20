import CatbirdMLS
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Security
import SwiftData
import os

/// Ephemeral, non-persisting direct PDS XRPC client for App Store Guideline 5.1.1(v) account deletion.
///
/// Upstream AT Protocol PDS implementations (`com.atproto.server.requestAccountDelete` &
/// `com.atproto.server.deleteAccount`) reject OAuth tokens (`403 Forbidden: OAuth credentials are not supported`).
/// This client exchanges `(identifier, password)` directly with the user's resolved HTTPS PDS via
/// `com.atproto.server.createSession` over an ephemeral `URLSession` (`urlCache = nil`,
/// `httpCookieStorage = nil`, `urlCredentialStorage = nil`), holding the returned `accessJwt`
/// strictly in local call-frame memory and discarding `refreshJwt` immediately.
struct PDSDirectDeletionClient: Sendable {
  private let sessionOverride: URLSession?
  private let timeoutSeconds: TimeInterval

  init(session: URLSession? = nil, timeoutSeconds: TimeInterval = 20.0) {
    self.sessionOverride = session
    self.timeoutSeconds = timeoutSeconds
  }

  private func withSession<T>(_ body: (URLSession) async throws -> T) async throws -> T {
    if let sessionOverride {
      return try await body(sessionOverride)
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let ephemeral = URLSession(configuration: config)
    defer { ephemeral.finishTasksAndInvalidate() }
    return try await body(ephemeral)
  }

  func createEphemeralSession(
    pdsURL: URL,
    identifier: String,
    password: String,
    authFactorToken: String? = nil
  ) async throws -> String {
    guard AccountDeletionFlow.isSafeDirectPDSEndpoint(pdsURL) else {
      throw PDSDirectDeletionError.invalidPDSEndpoint
    }
    guard !password.isEmpty else {
      throw PDSDirectDeletionError.missingPassword
    }

    let endpoint = pdsURL.appendingPathComponent("xrpc/com.atproto.server.createSession")
    var payload: [String: String] = [
      "identifier": identifier,
      "password": password,
    ]
    if let factor = authFactorToken?.trimmingCharacters(in: .whitespacesAndNewlines), !factor.isEmpty {
      payload["authFactorToken"] = factor
    }

    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    return try await withSession { session in
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw PDSDirectDeletionError.pdsRejected(statusCode: 0, errorCode: nil, message: nil)
      }
      if (200..<300).contains(http.statusCode) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessJwt = json["accessJwt"] as? String,
              !accessJwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw PDSDirectDeletionError.pdsRejected(
            statusCode: http.statusCode,
            errorCode: "MalformedCreateSessionResponse",
            message: "PDS did not return an access token"
          )
        }
        return accessJwt
      }

      let (errCode, errMsg) = Self.parseXrpcError(from: data)
      if errCode == "AuthFactorTokenRequired" {
        throw PDSDirectDeletionError.authFactorTokenRequired(message: errMsg ?? "Email 2FA code required")
      }
      if http.statusCode == 400 || http.statusCode == 401 {
        throw PDSDirectDeletionError.invalidCredentials(
          statusCode: http.statusCode,
          errorCode: errCode,
          message: errMsg
        )
      }
      throw PDSDirectDeletionError.pdsRejected(
        statusCode: http.statusCode,
        errorCode: errCode,
        message: errMsg
      )
    }
  }

  func requestAccountDelete(pdsURL: URL, accessJwt: String) async throws {
    guard AccountDeletionFlow.isSafeDirectPDSEndpoint(pdsURL) else {
      throw PDSDirectDeletionError.invalidPDSEndpoint
    }
    let endpoint = pdsURL.appendingPathComponent("xrpc/com.atproto.server.requestAccountDelete")
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessJwt)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    try await withSession { session in
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw PDSDirectDeletionError.pdsRejected(statusCode: 0, errorCode: nil, message: nil)
      }
      guard (200..<300).contains(http.statusCode) else {
        let (errCode, errMsg) = Self.parseXrpcError(from: data)
        throw PDSDirectDeletionError.pdsRejected(
          statusCode: http.statusCode,
          errorCode: errCode,
          message: errMsg
        )
      }
    }
  }

  func deleteAccount(
    pdsURL: URL,
    did: String,
    password: String,
    token: String,
    accessJwt: String
  ) async throws {
    guard AccountDeletionFlow.isSafeDirectPDSEndpoint(pdsURL) else {
      throw PDSDirectDeletionError.invalidPDSEndpoint
    }
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      throw PDSDirectDeletionError.missingConfirmationToken
    }
    guard !password.isEmpty else {
      throw PDSDirectDeletionError.missingPassword
    }

    let endpoint = pdsURL.appendingPathComponent("xrpc/com.atproto.server.deleteAccount")
    let payload: [String: String] = [
      "did": did,
      "password": password,
      "token": trimmedToken,
    ]
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessJwt)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    try await withSession { session in
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw PDSDirectDeletionError.pdsRejected(statusCode: 0, errorCode: nil, message: nil)
      }
      guard (200..<300).contains(http.statusCode) else {
        let (errCode, errMsg) = Self.parseXrpcError(from: data)
        if errCode == "ExpiredToken" {
          throw PDSDirectDeletionError.expiredToken(message: errMsg)
        }
        if errCode == "InvalidToken" {
          throw PDSDirectDeletionError.invalidToken(message: errMsg)
        }
        if http.statusCode == 401 || errCode == "AuthenticationRequired" {
          throw PDSDirectDeletionError.invalidCredentials(
            statusCode: http.statusCode,
            errorCode: errCode,
            message: errMsg
          )
        }
        throw PDSDirectDeletionError.pdsRejected(
          statusCode: http.statusCode,
          errorCode: errCode,
          message: errMsg
        )
      }
    }
  }

  private static func parseXrpcError(from data: Data) -> (String?, String?) {
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return (nil, nil)
    }
    return (json["error"] as? String, json["message"] as? String)
  }
}

struct AccountErasureRecoveryRequired: LocalizedError {
  var errorDescription: String? {
    "Catbird could not confirm erasure of your encrypted chat history. Sign in to this account on a device authorized for encrypted chat, or open Encrypted Chat to enroll and approve this device, then retry. Your hosted account remains active."
  }
}

enum HostedPeerErasureError: LocalizedError {
  case pending
  case unverified

  var errorDescription: String? {
    switch self {
    case .pending:
      "Other chat services are still processing the request to erase your encrypted history. Keep this device signed in and retry. Your hosted account is still active."
    case .unverified:
      "Catbird could not verify that every chat service erased your encrypted history. Your hosted account is still active. Keep this device signed in and retry after the chat services can confirm erasure."
    }
  }
}

/// Coordinates the deletion and erasure of Catbird-held account data to satisfy
/// App Store Review Guideline 5.1.1(v).
@MainActor
struct AccountDeletionCoordinator {
  private static let logger = Logger(subsystem: "blue.catbird", category: "AccountDeletionCoordinator")

  /// Exchanges `(did, password)` for an in-memory-only PDS Bearer JWT and calls
  /// `com.atproto.server.requestAccountDelete` directly against `pdsURL`.
  static func requestHostedAccountDeletionCode(
    forDID did: String,
    password: String,
    authFactorToken: String? = nil,
    pdsURL: URL,
    directClient: PDSDirectDeletionClient = PDSDirectDeletionClient()
  ) async throws {
    let accessJwt = try await directClient.createEphemeralSession(
      pdsURL: pdsURL,
      identifier: did,
      password: password,
      authFactorToken: authFactorToken
    )
    try await directClient.requestAccountDelete(pdsURL: pdsURL, accessJwt: accessJwt)
  }

  /// Executes permanent hosted PDS account deletion in the only fail-safe order available to the
  /// current APIs, after a separate UI warning explicitly accepts the non-atomic boundary:
  /// 1. Pre-validates `(did, password)` via ephemeral `com.atproto.server.createSession` BEFORE
  ///    running any irreversible Labyrinth/MLS server backup erasure.
  /// 2. Runs fail-closed `eraseServerSideLabyrinthDataIfAuthenticated` while OAuth/Spaces credentials
  ///    are still live. All participating delivery services must confirm erasure. AT Protocol cannot
  ///    validate `confirmationToken` without consuming it through `deleteAccount`, so a rejected or
  ///    expired token can leave the hosted account without that encrypted history.
  /// 3. Calls `com.atproto.server.deleteAccount` directly on `pdsURL`.
  /// 4. Wipes the remaining local Catbird SwiftData, caches, Keychain items, and OAuth session.
  static func performHostedAccountDeletion(
    forDID did: String,
    password: String,
    confirmationToken: String,
    authFactorToken: String? = nil,
    remoteErasureConsent: HostedAccountDeletionRemoteErasureConsent,
    pdsURL: URL,
    storageRoot: URL? = nil,
    keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
    circleKeychain: any CircleKeychain = SystemCircleKeychain(),
    modelContext: ModelContext? = nil,
    appStateOverride: AppState? = nil,
    clientOverride: ATProtoClient? = nil,
    coordinatorOverride: MLSClientCoordinator? = nil,
    remoteMLSErasure: (@MainActor @Sendable (String) async throws -> Void)? = nil,
    localErasureOverride: (@MainActor @Sendable (String) async throws -> Void)? = nil,
    directClient: PDSDirectDeletionClient = PDSDirectDeletionClient()
  ) async throws {
    try await HostedAccountDeletionSequence.run(
      password: password,
      confirmationToken: confirmationToken,
      remoteErasureConsent: remoteErasureConsent,
      authenticateHostedAccount: {
        try await directClient.createEphemeralSession(
          pdsURL: pdsURL,
          identifier: did,
          password: password,
          authFactorToken: authFactorToken
        )
      },
      eraseRemoteEncryptedData: {
        try await eraseServerSideLabyrinthDataIfAuthenticated(
          forDID: did,
          storageRoot: storageRoot,
          keystore: keystore,
          appStateOverride: appStateOverride,
          clientOverride: clientOverride,
          coordinatorOverride: coordinatorOverride,
          requirePeerErasureConfirmation: true,
          remoteMLSErasure: remoteMLSErasure
        )
      },
      deleteHostedAccount: { accessJwt, trimmedToken in
        try await directClient.deleteAccount(
          pdsURL: pdsURL,
          did: did,
          password: password,
          token: trimmedToken,
          accessJwt: accessJwt
        )
      },
      eraseRemainingLocalData: {
        let state = erasureAppState(for: did, override: appStateOverride)
        if let coordinator = coordinatorOverride ?? state?.mlsCoordinator {
          await coordinator.close()
        }
        if let localErasureOverride {
          try await localErasureOverride(did)
        } else {
          try await eraseCatbirdData(
            forDID: did,
            storageRoot: storageRoot,
            keystore: keystore,
            circleKeychain: circleKeychain,
            modelContext: modelContext,
            skipRemoteMLSErasure: true
          )
        }
      }
    )
  }

  /// Erases all account data held by Catbird:
  /// 1. Remote: Server-side Labyrinth/MLS erasure (`blue.catbird.labyrinth.deleteAccountData`) while
  ///    authenticated (unless explicitly performing a local-only wipe), plus Nest
  ///    gateway session/push revocation via `POST /auth/logout` using tokens resolved *before*
  ///    `removeAccount` wipes credentials.
  /// 2. Local SwiftData: `modelContext.delete` for `AppSettingsModel`, `Preferences`, `DraftPost` matching DID.
  /// 3. Filesystem & MLS Caches: purge draft/widget/spotlight caches + `MLSImageCache` + unconditional
  ///    local MLS SQLCipher DB (`<did_hash>.db*` + legacy `mls-state*`/`MLS*`) and Keychain key wipe.
  /// 4. Keychain & State: sign out and remove account from Petrel/Keychain and AppState.
  static func eraseCatbirdData(
    forDID did: String,
    token: String? = nil,
    storageRoot: URL? = nil,
    keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
    circleKeychain: any CircleKeychain = SystemCircleKeychain(),
    modelContext: ModelContext? = nil,
    skipRemoteMLSErasure: Bool = false,
    coordinatorOverride: MLSClientCoordinator? = nil,
    remoteMLSErasure: (@MainActor @Sendable (String) async throws -> Void)? = nil,
    accountRemovalOverride: (@MainActor @Sendable (String) async throws -> Void)? = nil
  ) async throws {
    guard !did.isEmpty else { return }
    logger.info("🗑️ Starting Catbird data erasure for account: \(did)")

    // 1a. Resolve active/stored auth tokens BEFORE removeAccount wipes Keychain credentials.
    let resolvedTokens = await resolveAuthTokensForRevocation(forDID: did, explicitToken: token)

    // 1b. D-3 / 5.1.1(v) fail-closed remote MLS & Labyrinth erasure while credentials are live.
    //     If remote deletion fails, throw BEFORE wiping local SQLCipher DB, Keychain keys,
    //     SwiftData, or the OAuth session so the user can retry without orphaning server state.
    if !skipRemoteMLSErasure {
      try await eraseServerSideLabyrinthDataIfAuthenticated(
        forDID: did,
        storageRoot: storageRoot,
        keystore: keystore,
        coordinatorOverride: coordinatorOverride,
        remoteMLSErasure: remoteMLSErasure
      )
    }

    // 1c. Remote: Revoke Nest gateway session and push registrations.
    await revokeNestGatewaySession(forDID: did, tokens: resolvedTokens)

    // 2. Local SwiftData: Purge account-scoped models.
    if let context = modelContext {
      purgeSwiftData(forDID: did, in: context)
    }

    // 3. Filesystem & MLS artifacts: Purge local caches, image cache, SQLCipher DB, and Keychain keys
    // unconditionally (even when mlsCoordinator == nil).
    await purgeFilesystemData(forDID: did)
    await MLSImageCache.shared.purge(for: did)
    try? CircleKeyStore.wipe(accountDID: did, keychain: circleKeychain)
    AppState.wipeLocalMLSArtifacts(for: did, storageRoot: storageRoot, keystore: keystore)
    AppState.clearPendingMLSDeviceRetirements(forDID: did)

    // 4 & 5. Keychain & State: Sign out and remove account from Petrel/Keychain and AppState.
    do {
      if let accountRemovalOverride {
        try await accountRemovalOverride(did)
      } else {
        try await AppStateManager.shared.authentication.removeAccount(did: did)
      }
      try? CircleKeyStore.wipe(accountDID: did, keychain: circleKeychain)
      AppState.wipeLocalMLSArtifacts(for: did, storageRoot: storageRoot, keystore: keystore)
      await MLSImageCache.shared.purge(for: did)
      logger.info("✅ Finished Catbird data erasure for account: \(did)")
    } catch {
      try? CircleKeyStore.wipe(accountDID: did, keychain: circleKeychain)
      AppState.wipeLocalMLSArtifacts(for: did, storageRoot: storageRoot, keystore: keystore)
      await MLSImageCache.shared.purge(for: did)
      logger.error("Failed to remove account from AuthManager: \(error.localizedDescription)")
      throw error
    }
  }

  static func eraseServerSideLabyrinthDataIfAuthenticated(
    forDID did: String,
    storageRoot: URL? = nil,
    keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
    appStateOverride: AppState? = nil,
    clientOverride: ATProtoClient? = nil,
    coordinatorOverride: MLSClientCoordinator? = nil,
    requirePeerErasureConfirmation: Bool = false,
    remoteMLSErasure: (@MainActor @Sendable (String) async throws -> Void)? = nil
  ) async throws {
    if let remoteMLSErasure {
      try await remoteMLSErasure(did)
      return
    }

    if let coordinatorOverride {
      try await eraseWithApprovedDevice(coordinatorOverride, requirePeerErasureConfirmation: requirePeerErasureConfirmation)
      return
    }

    let resolvedAppState = erasureAppState(for: did, override: appStateOverride)

    let resolvedClient = clientOverride ?? resolvedAppState?.atProtoClient ?? AppStateManager.shared.authentication.client
    guard let client = resolvedClient,
          (await client.getCurrentAccount())?.did == did
    else {
      throw AccountErasureRecoveryRequired()
    }

    var coordinator = resolvedAppState?.mlsCoordinator
    if coordinator?.isClosedForSession == true { coordinator = nil }
    if coordinator == nil, let appState = resolvedAppState {
      coordinator = await appState.getOrOpenMLSCoordinator()
    }

    var openedTransientCoordinator = false
    if coordinator == nil, hasLocalMLSArtifacts(forDID: did, storageRoot: storageRoot) {
      coordinator = try await openTransientCoordinatorForErasure(
        forDID: did,
        client: client,
        appState: resolvedAppState,
        storageRoot: storageRoot,
        keystore: keystore
      )
      openedTransientCoordinator = true
    }

    if let coordinator {
      defer {
        if openedTransientCoordinator {
          Task { await coordinator.close() }
        }
      }
      let erasingDeviceID = AppState.existingMLSDeviceID(for: did)
      try await eraseWithApprovedDevice(coordinator, requirePeerErasureConfirmation: requirePeerErasureConfirmation)
      if requirePeerErasureConfirmation { return }
      await coordinator.close()
      if let erasingDeviceID {
        AppState.clearErasedMLSDeviceID(for: did, expected: erasingDeviceID)
      }
      logger.info("🗑️ Erased server-side & local MLS/Labyrinth account data via MLSClientCoordinator")
      return
    }

    throw AccountErasureRecoveryRequired()
  }

  private static func erasureAppState(for did: String, override: AppState?) -> AppState? {
    if let override, override.userDID == did { return override }
    if let current = AppStateManager.shared.lifecycle.appState, current.userDID == did { return current }
    return AppStateManager.shared.getState(for: did)
  }

  private static func eraseWithApprovedDevice(
    _ coordinator: MLSClientCoordinator,
    requirePeerErasureConfirmation: Bool
  ) async throws {
    if coordinator.isHandleClosed {
      try await coordinator.resumeFromBackground()
    }
    guard try await !coordinator.isDevicePendingApproval() else {
      throw AccountErasureRecoveryRequired()
    }
    do {
      if requirePeerErasureConfirmation {
        try await coordinator.deleteAccountDataForHostedAccount()
      } else {
        try await coordinator.deleteAccountData()
      }
    } catch CatbirdMLS.MlsError.InvalidState(let message) where message.contains("PeerErasurePending") {
      throw HostedPeerErasureError.pending
    } catch CatbirdMLS.MlsError.InvalidState(let message) where message.contains("PeerErasureUnverified") {
      throw HostedPeerErasureError.unverified
    } catch CatbirdMLS.MlsError.InvalidState(let message) where message.localizedCaseInsensitiveContains("enroll") {
      throw AccountErasureRecoveryRequired()
    }
  }

  nonisolated static func hasLocalMLSArtifacts(forDID did: String, storageRoot: URL?) -> Bool {
    guard let root = try? (storageRoot ?? MLSAppGroupStorage.defaultStorageRoot()),
          let dbURL = try? MLSAppGroupStorage.databaseURL(storageRoot: root, accountDid: did)
    else {
      return false
    }
    for suffix in ["", "-wal", "-shm", "-journal"] {
      if FileManager.default.fileExists(atPath: dbURL.path + suffix) {
        return true
      }
    }
    return AppState.hasLegacyMLSDatabaseFiles(storageRoot: root, accountDid: did)
  }

  static func openTransientCoordinatorForErasure(
    forDID did: String,
    client: ATProtoClient,
    appState: AppState?,
    storageRoot: URL?,
    keystore: any PlatformKeyStore
  ) async throws -> MLSClientCoordinator {
    let resolvedRoot = try storageRoot ?? MLSAppGroupStorage.defaultStorageRoot()
    let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID(for: did)
    let environment: MLSEnvironment = if let mlsServiceDID {
      .custom(serviceDID: mlsServiceDID)
    } else {
      .production
    }
    let clientBaseURL = await client.networkService.baseURL
    let pdsEndpoint = clientBaseURL.absoluteString
    let deviceId = appState?.resolvedMLSDeviceID()
      ?? AppState.existingMLSDeviceID(for: did)
      ?? UUID().uuidString.lowercased()
    let config = CatbirdMlsClientConfig(
      storageRoot: resolvedRoot.path,
      accountDid: did,
      deviceId: deviceId,
      homeDsDid: environment.bareServiceDID,
      homeDsEndpoint: environment.endpointURL.absoluteString,
      pdsEndpoint: pdsEndpoint
    )
    let transport = PetrelPlatformTransport(
      atProtoClient: client,
      boundAccountDid: did,
      homeDsEndpoint: environment.endpointURL,
      homeDsDid: environment.bareServiceDID,
      ownPdsEndpoint: clientBaseURL,
      actorDeviceId: deviceId
    )
    return try await MLSClientCoordinator.open(
      config: config,
      keystore: keystore,
      transport: transport
    )
  }

  static func resolveAuthTokensForRevocation(
    forDID did: String,
    explicitToken: String?
  ) async -> [String] {
    var tokens: [String] = []
    func appendUnique(_ candidate: String?) {
      guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            !tokens.contains(trimmed) else { return }
      tokens.append(trimmed)
    }

    appendUnique(explicitToken)

    #if targetEnvironment(simulator)
    let accessGroup: String? = nil
    #else
    let accessGroup: String? = KeychainPlatformKeyStore.resolvedAccessGroup(suffix: "blue.catbird.shared")
    #endif

    let storage = KeychainStorage(namespace: "blue.catbird", accessGroup: accessGroup)
    if let session = try? await storage.getSession(for: did) {
      appendUnique(session.accessToken)
    }

    for accountKey in ["blue.catbird.gatewaySession.\(did)", "gatewaySession.\(did)"] {
      appendUnique(readGenericPasswordUTF8(account: accountKey, accessGroup: accessGroup))
      if accessGroup != nil {
        appendUnique(readGenericPasswordUTF8(account: accountKey, accessGroup: nil))
      }
    }

    return tokens
  }

  private static func readGenericPasswordUTF8(account: String, accessGroup: String?) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let accessGroup, !accessGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    #if os(macOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let data = item as? Data,
          let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    return text
  }

  private static func revokeNestGatewaySession(forDID did: String, tokens: [String]) async {
    guard !tokens.isEmpty else { return }
    let gatewayURL = CatbirdGatewayConfiguration.current.origin
    let logoutURL = gatewayURL.appendingPathComponent("auth/logout")

    for token in tokens {
      var request = URLRequest(url: logoutURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      do {
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
          logger.info("🚪 Gateway logout for \(did, privacy: .private) returned status \(http.statusCode)")
        }
      } catch {
        logger.warning("🚪 Gateway logout request failed (continuing erasure): \(error.localizedDescription)")
      }
    }
  }

  private static func purgeSwiftData(forDID did: String, in context: ModelContext) {
    let settingsId = AppSettingsModel.settingsId(for: did)
    do {
      try context.delete(model: AppSettingsModel.self, where: #Predicate { $0.id == settingsId })
      try context.delete(model: Preferences.self, where: #Predicate { $0.accountDID == did })
      try context.delete(model: DraftPost.self, where: #Predicate { $0.accountDID == did })
      try context.save()
      logger.info("✅ SwiftData purged for account \(did)")
    } catch {
      logger.error("Failed to purge SwiftData for account \(did): \(error.localizedDescription)")
    }
  }

  private static func purgeFilesystemData(forDID did: String) async {
    LabelerDefinitionsDiskCache.remove(accountDID: did)
    TrendingTopicsDiskCache.remove(accountDID: did)
    FeedWidgetDataProvider.shared.clearWidgetData(for: did)
    await SpotlightEntityDonator.shared.removeAll()
    ThreadManager.clearPrefillCache()
  }
}
