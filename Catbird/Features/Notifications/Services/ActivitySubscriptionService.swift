import Foundation
import Observation
import OSLog
import Petrel

@MainActor
@Observable
final class ActivitySubscriptionService {
  struct SubscriptionEntry: Identifiable {
    struct ProfileSummary {
      let did: String
      let handle: String
      let displayName: String?
      let avatar: URI?

      var displayNameOrHandle: String {
        if let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
          return trimmed
        }
        return "@" + handle
      }
    }

    var profile: ProfileSummary
    var subscription: AppBskyNotificationDefs.ActivitySubscription?

    var id: String { profile.did }
  }

  enum ServiceError: Error, LocalizedError {
    case clientUnavailable
    case invalidResponse(Int)
    case profileLookupFailed

    var errorDescription: String? {
      switch self {
      case .clientUnavailable:
        return "ATProto client unavailable"
      case .invalidResponse(let code):
        return "Unexpected response code: \(code)"
      case .profileLookupFailed:
        return "Unable to load profile information"
      }
    }
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "ActivitySubscriptionService")
  private var client: ATProtoClient?
  @ObservationIgnored private var notificationManager: NotificationManager?
  @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
  private let autoSyncInterval: TimeInterval = 300

  private(set) var subscriptions: [SubscriptionEntry] = []
  private(set) var isLoading = false
  private(set) var lastError: Error?
  private(set) var pendingUpdates: Set<String> = []

  private var subscriptionLookup: [String: AppBskyNotificationDefs.ActivitySubscription] = [:]

  @MainActor
  init(client: ATProtoClient?, notificationManager: NotificationManager? = nil) {
    self.client = client
    self.notificationManager = notificationManager
    scheduleAutoSyncIfNeeded()
  }

  func updateClient(_ newClient: ATProtoClient?) {
    client = newClient
    resetState()
    scheduleAutoSyncIfNeeded()
  }

  func updateNotificationManager(_ newManager: NotificationManager?) {
    notificationManager = newManager
    scheduleAutoSyncIfNeeded()
  }

  func resetState() {
    subscriptions = []
    subscriptionLookup = [:]
    lastError = nil
    isLoading = false
    pendingUpdates = []
  }

  deinit {
    autoSyncTask?.cancel()
    autoSyncTask = nil
  }

  func refreshSubscriptions(limit: Int = 50) async {
    guard let client else {
      lastError = ServiceError.clientUnavailable
      return
    }

    if isLoading { return }

    isLoading = true
    lastError = nil

    defer { isLoading = false }

    do {
      let params = AppBskyNotificationListActivitySubscriptions.Parameters(limit: limit)
      let (code, data) = try await client.app.bsky.notification.listActivitySubscriptions(input: params)

      guard code == 200, let output = data else {
        throw ServiceError.invalidResponse(code)
      }

      var lookup: [String: AppBskyNotificationDefs.ActivitySubscription] = [:]
      var entries: [SubscriptionEntry] = []

      for profile in output.subscriptions {
        let summary = makeSummary(from: profile)
        let subscription = profile.viewer?.activitySubscription
        if let subscription {
          lookup[summary.did] = subscription
        }
        entries.append(SubscriptionEntry(profile: summary, subscription: subscription))
      }

      subscriptionLookup = lookup
      subscriptions = entries.sorted {
        $0.profile.displayNameOrHandle.localizedCaseInsensitiveCompare($1.profile.displayNameOrHandle) == .orderedAscending
      }

      await syncWithNotificationServer(localLookup: lookup)

    } catch {
      logger.error("Failed to refresh activity subscriptions: \(error.localizedDescription)")
      lastError = error
    }
  }

  func subscription(for did: String) -> AppBskyNotificationDefs.ActivitySubscription? {
    subscriptionLookup[did]
  }

  func isUpdating(did: String) -> Bool {
    pendingUpdates.contains(did)
  }

  @discardableResult
  func setSubscription(for did: String, posts: Bool, replies: Bool) async throws -> AppBskyNotificationDefs.ActivitySubscription? {
    guard let client else {
      throw ServiceError.clientUnavailable
    }

    pendingUpdates.insert(did)
    defer { pendingUpdates.remove(did) }

    let subject = try DID(didString: did)
    let input = AppBskyNotificationPutActivitySubscription.Input(
      subject: subject,
      activitySubscription: AppBskyNotificationDefs.ActivitySubscription(post: posts, reply: replies)
    )

    let (code, response) = try await client.app.bsky.notification.putActivitySubscription(input: input)

    guard (200 ... 299).contains(code) else {
      throw ServiceError.invalidResponse(code)
    }

    let resolvedSubscription = response?.activitySubscription
    let effectiveSubscription = resolvedSubscription ?? (
      posts || replies ? AppBskyNotificationDefs.ActivitySubscription(post: posts, reply: replies) : nil
    )

    try await apply(updateFor: did, subscription: effectiveSubscription)

    await syncSubscriptionWithNotificationServer(
      did: did,
      subscription: effectiveSubscription
    )

    return subscriptionLookup[did]
  }

  func clearSubscription(for did: String) async throws {
    _ = try await setSubscription(for: did, posts: false, replies: false)
  }

  private func apply(updateFor did: String, subscription: AppBskyNotificationDefs.ActivitySubscription?) async throws {
    subscriptionLookup[did] = subscription

    if let index = subscriptions.firstIndex(where: { $0.id == did }) {
      if let subscription, isActive(subscription) {
        subscriptions[index].subscription = subscription
      } else {
        subscriptions.remove(at: index)
      }
      return
    }

    guard let subscription, isActive(subscription) else {
      return
    }

    guard let profile = try await loadProfileSummary(for: did) else {
      throw ServiceError.profileLookupFailed
    }

    subscriptions.append(SubscriptionEntry(profile: profile, subscription: subscription))
    subscriptions.sort {
      $0.profile.displayNameOrHandle.localizedCaseInsensitiveCompare($1.profile.displayNameOrHandle) == .orderedAscending
    }
  }

  private func isActive(_ subscription: AppBskyNotificationDefs.ActivitySubscription?) -> Bool {
    guard let subscription else { return false }
    return subscription.post || subscription.reply
  }

  private func makeSummary(from profile: AppBskyActorDefs.ProfileView) -> SubscriptionEntry.ProfileSummary {
    SubscriptionEntry.ProfileSummary(
      did: profile.did.didString(),
      handle: profile.handle.description,
      displayName: profile.displayName,
      avatar: profile.avatar
    )
  }

  private func makeSummary(from profile: AppBskyActorDefs.ProfileViewDetailed) -> SubscriptionEntry.ProfileSummary {
    SubscriptionEntry.ProfileSummary(
      did: profile.did.didString(),
      handle: profile.handle.description,
      displayName: profile.displayName,
      avatar: profile.avatar
    )
  }

  private func loadProfileSummary(for did: String) async throws -> SubscriptionEntry.ProfileSummary? {
    guard let client else { return nil }
    let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
    let (code, profile) = try await client.app.bsky.actor.getProfile(input: params)
    guard code == 200, let profile else {
      return nil
    }
    return makeSummary(from: profile)
  }

  private func syncWithNotificationServer(
    localLookup: [String: AppBskyNotificationDefs.ActivitySubscription]
  ) async {
    guard let manager = notificationManager else {
      logger.debug("Notification manager unavailable - skipping server reconciliation")
      return
    }

    guard let serverSubscriptions = await manager.fetchActivitySubscriptionsFromServer() else {
      logger.debug("Skipping activity subscription fetch - notification server not ready")
      return
    }

    let localActive = Set(
      localLookup.compactMap { did, subscription in
        isActive(subscription) ? did : nil
      }
    )

    let remoteActive = Set(
      serverSubscriptions
        .filter { $0.includePosts || $0.includeReplies }
        .map { $0.subjectDid }
    )

    let missingOnServer = localActive.subtracting(remoteActive)
    if !missingOnServer.isEmpty {
      logger.info("Pushing missing activity subscriptions to notification server: \(missingOnServer.count)")
      for did in missingOnServer {
        guard let subscription = localLookup[did] else { continue }
        await manager.updateActivitySubscriptionOnServer(
          subjectDid: did,
          includePosts: subscription.post,
          includeReplies: subscription.reply
        )
      }
    }

    let staleOnServer = remoteActive.subtracting(localActive)
    if !staleOnServer.isEmpty {
      logger.info("Removing stale activity subscriptions from notification server: \(staleOnServer.count)")
      for did in staleOnServer {
        await manager.removeActivitySubscriptionFromServer(subjectDid: did)
      }
    }
  }

  private func syncSubscriptionWithNotificationServer(
    did: String,
    subscription: AppBskyNotificationDefs.ActivitySubscription?
  ) async {
    guard let manager = notificationManager else {
      logger.debug("Notification manager unavailable - skipping direct subscription sync")
      return
    }

    guard let subscription, isActive(subscription) else {
      await manager.removeActivitySubscriptionFromServer(subjectDid: did)
      return
    }

    await manager.updateActivitySubscriptionOnServer(
      subjectDid: did,
      includePosts: subscription.post,
      includeReplies: subscription.reply
    )
  }

  @MainActor
  private func scheduleAutoSyncIfNeeded() {
    guard client != nil, notificationManager != nil else {
      cancelAutoSync()
      return
    }

    if autoSyncTask == nil {
      startAutoSyncLoop()
    }

    if shouldAutoSync {
      Task { [weak self] in
        await self?.performAutoSyncIfNeeded()
      }
    }
  }

  private func startAutoSyncLoop() {
    autoSyncTask = Task { [weak self] in
      await self?.runAutoSyncLoop()
    }
  }

  @MainActor
  private func runAutoSyncLoop() async {
    await self.performAutoSyncIfNeeded()

    while !Task.isCancelled {
      let interval = UInt64(autoSyncInterval * 1_000_000_000)
      do {
        try await Task.sleep(nanoseconds: interval)
      } catch {
        break
      }
      guard !Task.isCancelled else { break }
      await self.performAutoSyncIfNeeded()
    }
  }

  private func cancelAutoSync() {
    autoSyncTask?.cancel()
    autoSyncTask = nil
  }

  @MainActor
  private func performAutoSyncIfNeeded() async {
    guard shouldAutoSync else { return }
    let currentLocal = subscriptionLookup
    await syncWithNotificationServer(localLookup: currentLocal)
    await refreshSubscriptions()
  }

  private var shouldAutoSync: Bool {
    guard client != nil else { return false }
    guard let manager = notificationManager else { return false }

    guard case .registered = manager.status else {
      return false
    }

    return true
  }

  @MainActor
  func requestImmediateSync() async {
    await performAutoSyncIfNeeded()
  }

  @MainActor
  func pushAllSubscriptionsToNotificationServer() async {
    await syncWithNotificationServer(localLookup: subscriptionLookup)
  }
}
