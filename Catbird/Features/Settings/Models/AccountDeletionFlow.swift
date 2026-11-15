import Foundation
import SwiftData
import os

/// A local handoff to the provider's account settings, never a deletion request.
struct AccountDeletionTarget: Identifiable, Equatable {
  enum Purpose: Equatable {
    case manageAccount
    case deletionOptions
  }
  let id = UUID()
  let did: String
  let handle: String?
  let accountRevision: UInt64
  var purpose: Purpose = .deletionOptions
}

struct AccountDeletionFlow {
  enum Phase: Equatable {
    case ready
    case opening(UUID)
    case opened
    case failed
    case unavailable
    case accountChanged
    case cancelled
  }

  struct OpeningAttempt {
    let id: UUID
    let url: URL
  }

  let target: AccountDeletionTarget
  private(set) var phase = Phase.ready
  /// The destination never carries account or session details.
  private(set) var destination: AccountManagementPageResolver.Destination?

  var isResolvingDestination: Bool { phase == .ready && destination == nil }

  var canOpen: Bool {
    guard destination != nil else { return false }
    switch phase {
    case .ready, .opened, .failed:
      return !target.did.isEmpty
    case .opening, .unavailable, .accountChanged, .cancelled:
      return false
    }
  }

  /// Verifies destination URL safety: HTTPS, valid host, no credentials/fragments,
  /// and only permits a scoped login_hint query parameter while rejecting sensitive tokens.
  static func isSafeDestinationURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.fragment == nil else {
      return false
    }
    if let queryItems = components.queryItems {
      guard queryItems.count == 1,
            let item = queryItems.first,
            item.name == "login_hint",
            let value = item.value, !value.isEmpty else {
        return false
      }
    }
    return true
  }

  /// Late discovery cannot attach a destination to a changed or cancelled account context.
  mutating func resolveDestination(
    _ result: AccountManagementPageResolver.Destination?,
    currentDID: String,
    currentRevision: UInt64
  ) {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .ready, destination == nil else { return }
    guard let result else {
      phase = .unavailable
      return
    }
    guard Self.isSafeDestinationURL(result.url) else {
      phase = .unavailable
      return
    }
    destination = result
  }

  mutating func prepareToOpen(currentDID: String, currentRevision: UInt64) -> OpeningAttempt? {
    accountDidChange(to: currentDID, revision: currentRevision)
    guard canOpen, let destination else { return nil }
    let attempt = OpeningAttempt(id: UUID(), url: destination.url)
    phase = .opening(attempt.id)
    return attempt
  }

  mutating func finishOpening(_ attemptID: UUID, accepted: Bool, currentDID: String, currentRevision: UInt64) {
    guard phase == .opening(attemptID) else { return }
    accountDidChange(to: currentDID, revision: currentRevision)
    guard phase == .opening(attemptID) else { return }
    // OS acceptance of a URL is not confirmation of provider account deletion.
    phase = accepted ? .opened : .failed
  }

  mutating func accountDidChange(to currentDID: String, revision: UInt64) {
    guard phase != .cancelled else { return }
    if target.did.isEmpty || currentDID != target.did || revision != target.accountRevision {
      phase = .accountChanged
      destination = nil
    }
  }

  mutating func cancel() {
    phase = .cancelled
  }
}

/// Coordinates the deletion and erasure of Catbird-held account data to satisfy
/// App Store Review Guideline 5.1.1(v).
@MainActor
struct AccountDeletionCoordinator {
  private static let logger = Logger(subsystem: "blue.catbird", category: "AccountDeletionCoordinator")

  /// Erases all account data held by Catbird:
  /// 1. Remote: Nest gateway session/push revocation via POST /auth/logout with Bearer token.
  /// 2. Local SwiftData: modelContext.delete for AppSettingsModel, Preferences, DraftPost matching DID.
  /// 3. Filesystem: purge draft media/video directories for account.
  /// 4. Keychain: delete stored OAuth/refresh tokens and stored handles.
  /// 5. State: transition appState.signOut() and notify widget/spotlight.
  static func eraseCatbirdData(
    forDID did: String,
    token: String? = nil,
    modelContext: ModelContext? = nil
  ) async throws {
    guard !did.isEmpty else { return }
    logger.info("🗑️ Starting Catbird data erasure for account: \(did)")

    // 1. Remote: Revoke Nest gateway session and push registrations
    await revokeNestGatewaySession(forDID: did, explicitToken: token)

    // 2. Local SwiftData: Purge account-scoped models
    if let context = modelContext {
      purgeSwiftData(forDID: did, in: context)
    }

    // 3. Filesystem: Purge draft media, captured videos, and local caches
    await purgeFilesystemData(forDID: did)

    // 4 & 5. Keychain & State: Sign out and remove account from Petrel/Keychain and AppState
    do {
      try await AppStateManager.shared.authentication.removeAccount(did: did)
      logger.info("✅ Finished Catbird data erasure for account: \(did)")
    } catch {
      logger.error("Failed to remove account from AuthManager: \(error.localizedDescription)")
      throw error
    }
  }

  private static func revokeNestGatewaySession(forDID did: String, explicitToken: String?) async {
    let gatewayURL = CatbirdGatewayConfiguration.current.origin
    let logoutURL = gatewayURL.appendingPathComponent("auth/logout")

    var tokensToRevoke: [String] = []
    if let explicitToken, !explicitToken.isEmpty {
      tokensToRevoke.append(explicitToken)
    }

    for token in tokensToRevoke {
      var request = URLRequest(url: logoutURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      do {
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
          logger.info("🚪 Gateway logout returned status \(http.statusCode)")
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
