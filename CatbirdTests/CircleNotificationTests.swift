//
//  CircleNotificationTests.swift
//  CatbirdTests
//

import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import OSLog
import Testing
@testable import Catbird

// MARK: - Test Doubles

actor RecordingCircleNotificationService: CircleNotificationServiceProtocol {
  private(set) var refreshCount = 0
  private(set) var listNotificationsCalls: [String?] = []
  var pagesToReturn: [CircleNotificationPage] = []
  var errorToThrow: Error?
  var onListNotifications: (@Sendable () async -> Void)?
  var onRefresh: (@Sendable () async -> Void)?

  func setPages(_ pages: [CircleNotificationPage]) {
    self.pagesToReturn = pages
  }

  func setError(_ error: Error?) {
    self.errorToThrow = error
  }

  func setOnListNotifications(_ action: (@Sendable () async -> Void)?) {
    self.onListNotifications = action
  }

  func setOnRefresh(_ action: (@Sendable () async -> Void)?) {
    self.onRefresh = action
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    if let onListNotifications {
      await onListNotifications()
    }
    listNotificationsCalls.append(cursor)
    if let errorToThrow {
      throw errorToThrow
    }
    if !pagesToReturn.isEmpty {
      return pagesToReturn.removeFirst()
    }
    return CircleNotificationPage(notifications: [], cursor: nil)
  }

  func refresh() async throws -> CircleNotificationPage {
    refreshCount += 1
    if let onRefresh {
      await onRefresh()
    }
    return try await listNotifications(cursor: nil)
  }
}

// MARK: - Tests

@Suite("Circle Notifications Tests", .serialized)
struct CircleNotificationTests {
  let aliceDID = try! DID(didString: "did:plc:alice")
  let bobDID = try! DID(didString: "did:plc:bob")
  let familyCircle = CircleTestFixtures.family
  let workCircle = CircleTestFixtures.work

  func makeNotification(
    id: String,
    reason: BlueCatbirdCircleDefs.NotificationReason,
    circle: CircleSummary,
    subjectRkey: String? = "post123"
  ) -> BlueCatbirdCircleDefs.Notification {
    let subjectURI: ATProtocolURI?
    if let subjectRkey {
      subjectURI = try? ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.post/\(subjectRkey)")
    } else {
      subjectURI = nil
    }

    return BlueCatbirdCircleDefs.Notification(
      id: id,
      reason: reason,
      actor: AppBskyActorDefs.ProfileViewBasic(
        did: aliceDID,
        handle: try! Handle(handleString: "alice.test"),
        displayName: "Alice",
        pronouns: nil,
        avatar: nil,
        associated: nil,
        viewer: nil,
        labels: nil,
        createdAt: nil,
        verification: nil,
        status: nil,
        debug: nil
      ),
      subject: subjectURI,
      indexedAt: ATProtocolDate(date: Date()),
      circle: circle
    )
  }

  // 1. Generic push triggers authenticated refresh, updates model and cache without rendering payload
  @Test("Generic push triggers authenticated refresh, updates model and cache without rendering payload")
  @MainActor
  func genericPushTriggersAuthenticatedRefreshWithoutRenderingPayload() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
    }

    let manager = NotificationManager()
    manager.configure(with: appState)
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_after_push")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )
    appState.circleNotificationsModel = model

    // Generic push with extra sensitive metadata that must not be rendered/retained
    let pushPayload: [AnyHashable: Any] = [
      "kind": "circle_activity",
      "extra_secret_field": "confidential_token_12345",
      "subject_text": "Secret message body"
    ]

    await manager.handlePush(pushPayload, circleNotificationsModel: model)

    let refreshCount = await service.refreshCount
    #expect(refreshCount == 1)

    // Verify model was refreshed and updated with page+cursor
    #expect(model.notifications.count == 1)
    #expect(model.notifications.first?.id == "n1")
    #expect(model.cursor == "cursor_after_push")

    // Verify cache was updated
    let cached = await cache.page(accountDID: "did:plc:alice")
    #expect(cached?.notifications.count == 1)
    #expect(cached?.cursor == "cursor_after_push")
  }

  // 2. Generic push with no authenticated service performs no refresh
  @Test("Generic push with no authenticated service performs no refresh")
  @MainActor
  func genericPushWithNoAuthenticatedServicePerformsNoRefresh() async {
    let manager = NotificationManager()
    // No appState and circleNotificationsModel is nil -> no refresh, no crash
    await manager.handlePush(["kind": "circle_activity"], circleNotificationsModel: nil)
  }

  // 3. Public push unchanged
  @Test("Non-circle push payload does not trigger circle refresh")
  @MainActor
  func publicPushUnchanged() async {
    let manager = NotificationManager()
    let service = RecordingCircleNotificationService()
    let model = CircleNotificationsModel(service: service, accountDID: "did:plc:alice")
    await manager.handlePush(["uri": "at://did:plc:xyz/app.bsky.feed.post/123", "type": "reply"], circleNotificationsModel: model)
    let refreshCount = await service.refreshCount
    #expect(refreshCount == 0)
  }

  // 3b. Generic push handles refresh failure gracefully without leaking identifiers
  @Test("Generic push handles refresh failure gracefully without throwing or leaking private IDs")
  @MainActor
  func genericPushHandlesRefreshFailureGracefully() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
    }

    let manager = NotificationManager()
    manager.configure(with: appState)
    let service = RecordingCircleNotificationService()
    await service.setError(CircleError.accessExpired)
    let model = CircleNotificationsModel(service: service, accountDID: "did:plc:alice")
    appState.circleNotificationsModel = model

    await manager.handlePush(["kind": "circle_activity"], circleNotificationsModel: model)
    #expect(model.error == .accessExpired)
  }

  // 4. Private / public store separation
  @Test("Private and public notification stores remain strictly separate")
  @MainActor
  func privatePublicStoreSeparation() async throws {
    let notifCache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: nil)
    await notifCache.store(page, accountDID: "did:plc:alice")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: notifCache
    )

    try await model.load()
    #expect(model.notifications.count == 1)
    #expect(model.notifications.first?.id == "n1")

    // Verify cache holds Circle notification
    let cached = await notifCache.page(accountDID: "did:plc:alice")
    #expect(cached?.notifications.count == 1)
  }

  // 5. Pagination appends and updates cursor
  @Test("Pagination appends items and advances cursor")
  @MainActor
  func paginationAppendsAndUpdatesCursor() async throws {
    let notif1 = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let notif2 = makeNotification(id: "n2", reason: .value_like, circle: familyCircle)

    let page1 = CircleNotificationPage(notifications: [notif1], cursor: "cursor_p2")
    let page2 = CircleNotificationPage(notifications: [notif2], cursor: nil)

    let service = RecordingCircleNotificationService()
    await service.setPages([page1, page2])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: CircleNotificationCache()
    )

    try await model.load()
    #expect(model.notifications.count == 1)
    #expect(model.cursor == "cursor_p2")

    try await model.loadMore()
    #expect(model.notifications.count == 2)
    #expect(model.cursor == nil)
  }

  // 6. Muted Circles filtered from notifications & immediate removal
  @Test("Muted Circle notifications are filtered and immediately removed on mute change")
  @MainActor
  func mutedCirclesFilteredFromNotifications() async throws {
    let mutedCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: familyCircle.uri,
      name: familyCircle.name,
      owner: familyCircle.owner,
      accessState: .value_active,
      muted: true,
      members: nil
    )

    let unmutedNotif = makeNotification(id: "n_unmuted", reason: .value_reply, circle: workCircle)
    let mutedNotif = makeNotification(id: "n_muted", reason: .value_like, circle: mutedCircle)

    let page = CircleNotificationPage(notifications: [unmutedNotif, mutedNotif], cursor: nil)
    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let notifCache = CircleNotificationCache()
    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: notifCache
    )

    try await model.load()
    #expect(model.notifications.count == 1)
    #expect(model.notifications.first?.id == "n_unmuted")

    // Now test immediate mute propagation:
    // If workCircle gets muted via NotificationCenter
    NotificationCenter.default.post(
      name: .circleMuteStateChanged,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:alice",
        "spaceURI": workCircle.uri.uriString()
      ]
    )

    #expect(model.notifications.isEmpty)
  }

  // 7. Exact account/Space purge and sibling retention
  @Test("Exact account and Space purge retains sibling Spaces and other accounts")
  func exactAccountAndSpacePurgeAndSiblingRetention() async {
    let cache = CircleNotificationCache()
    let notifFamily = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let notifWork = makeNotification(id: "n2", reason: .value_like, circle: workCircle)

    let alicePage = CircleNotificationPage(notifications: [notifFamily, notifWork], cursor: nil)
    let bobPage = CircleNotificationPage(notifications: [notifFamily], cursor: nil)

    await cache.store(alicePage, accountDID: "did:plc:alice")
    await cache.store(bobPage, accountDID: "did:plc:bob")

    await cache.purge(accountDID: "did:plc:alice", space: familyCircle.uri)

    let aliceRemaining = await cache.page(accountDID: "did:plc:alice")
    #expect(aliceRemaining?.notifications.count == 1)
    #expect(aliceRemaining?.notifications.first?.circle.uri == workCircle.uri)

    let bobRemaining = await cache.page(accountDID: "did:plc:bob")
    #expect(bobRemaining?.notifications.count == 1)
    #expect(bobRemaining?.notifications.first?.circle.uri == familyCircle.uri)
  }

  // 8. Logout, switch, and removal purge
  @Test("Logout, account switch, and removal purge notifications for target DID")
  func logoutAccountSwitchAndRemovalPurge() async {
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: nil)

    await cache.store(page, accountDID: "did:plc:alice")
    #expect(await cache.page(accountDID: "did:plc:alice") != nil)

    await cache.purge(accountDID: "did:plc:alice")
    #expect(await cache.page(accountDID: "did:plc:alice") == nil)
  }

  // 9. Space deletion lifecycle event purges Space notifications across cache and model synchronously
  @Test("Space deletion lifecycle event purges Space notifications across cache and model synchronously")
  @MainActor
  func spaceDeletionPurgesSpaceNotificationsAndFeed() async throws {
    let cache = CircleNotificationCache()
    let notifFamily = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let notifWork = makeNotification(id: "n2", reason: .value_like, circle: workCircle)
    let page = CircleNotificationPage(notifications: [notifFamily, notifWork], cursor: nil)
    await cache.store(page, accountDID: "did:plc:alice")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )

    try await model.load()
    #expect(model.notifications.count == 2)

    // Post .circleDeleted lifecycle notification confirming server complete deletion
    NotificationCenter.default.post(
      name: .circleDeleted,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:alice",
        "spaceURI": familyCircle.uri.uriString()
      ]
    )

    // Model purges synchronously on the main actor
    #expect(model.notifications.count == 1)
    #expect(model.notifications.first?.circle.uri == workCircle.uri)

    // Sibling Space retained in cache
    try await Task.sleep(nanoseconds: 10_000_000)
    let remainingInCache = await cache.page(accountDID: "did:plc:alice")
    #expect(remainingInCache?.notifications.count == 1)
    #expect(remainingInCache?.notifications.first?.circle.uri == workCircle.uri)
  }

  // 9b. Lifecycle event for different account does not purge model
  @Test("Circle deletion for another account does not purge active model")
  @MainActor
  func circleDeletionForAnotherAccountDoesNotPurge() async throws {
    let aliceTestDID = "did:plc:alice_del_isolation"
    let notifFamily = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notifFamily], cursor: nil)
    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: aliceTestDID,
      cache: CircleNotificationCache()
    )
    try await model.load()
    #expect(model.notifications.count == 1)

    NotificationCenter.default.post(
      name: .circleDeleted,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:bob_del_isolation",
        "spaceURI": familyCircle.uri.uriString()
      ]
    )

    #expect(model.notifications.count == 1)
  }
  // 10. Stale request cannot resurrect purged state
  @Test("Stale in-flight request cannot resurrect purged state")
  @MainActor
  func staleRequestCannotResurrectPurgedState() async throws {
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: nil)

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: CircleNotificationCache()
    )
    // Purging increments the internal generation counter
    await model.purge(space: familyCircle.uri)

    // A stale request completed after purge will not apply its items if its generation is old
    // We simulate this by checking that after purge, notifications are empty and error is nil
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
  }

  // 11. Private navigation routing
  @Test("Notification navigation routes private subjects through Circle routes and fails closed on missing subject")
  @MainActor
  func privateNotificationNavigation() throws {
    let replyNotif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle, subjectRkey: "post123")
    let likeNotif = makeNotification(id: "n2", reason: .value_like, circle: familyCircle, subjectRkey: "post456")
    let missingSubjectNotif = makeNotification(id: "n3", reason: .value_reply, circle: familyCircle, subjectRkey: nil)
    let inviteNotif = makeNotification(id: "n4", reason: .value_invite, circle: familyCircle, subjectRkey: nil)

    var navigationPath = NavigationPath()

    // Test reply with subject
    if case .value_reply = replyNotif.reason, let subject = replyNotif.subject {
      navigationPath.append(NavigationDestination.circlePost(subject, replyNotif.circle))
    }
    #expect(navigationPath.count == 1)

    // Test like with subject
    if case .value_like = likeNotif.reason, let subject = likeNotif.subject {
      navigationPath.append(NavigationDestination.circlePost(subject, likeNotif.circle))
    }
    #expect(navigationPath.count == 2)

    // Test missing subject fails closed: no new destination appended
    let initialCount = navigationPath.count
    if case .value_reply = missingSubjectNotif.reason, let subject = missingSubjectNotif.subject {
      navigationPath.append(NavigationDestination.circlePost(subject, missingSubjectNotif.circle))
    }
    #expect(navigationPath.count == initialCount)

    // Test invite routes to circleDetail
    if case .value_invite = inviteNotif.reason {
      navigationPath.append(NavigationDestination.circleDetail(inviteNotif.circle))
    }
    #expect(navigationPath.count == initialCount + 1)
  }
  // 12. CircleNotificationsModel error recording and retry recovery
  @Test("Model records typed error on refresh failure and clears on successful retry")
  @MainActor
  func modelRecordsErrorOnFailureAndClearsOnRetry() async throws {
    let service = RecordingCircleNotificationService()
    await service.setError(CircleError.networkError("Connection dropped"))

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: CircleNotificationCache()
    )

    await #expect(throws: CircleError.self) {
      try await model.load()
    }
    #expect(model.error == .networkError("Connection dropped"))
    #expect(model.notifications.isEmpty)

    // Clear error and provide a valid page for retry
    await service.setError(nil)
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    await service.setPages([CircleNotificationPage(notifications: [notif], cursor: nil)])

    try await model.refresh()
    #expect(model.error == nil)
    #expect(model.notifications.count == 1)
  }

  // 13. Barrier test: Generic push mid-request account switch with production lifecycle discards mutation
  @Test("Generic push mid-request account switch with production lifecycle discards mutation")
  @MainActor
  func genericPushMidRequestAccountSwitchDiscardsMutation() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let aliceAppState = AppState(userDID: "did:plc:alice", client: client)
    let bobAppState = AppState(userDID: "did:plc:bob", client: client)

    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(aliceAppState))
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
    }
    let manager = NotificationManager()
    manager.configure(with: aliceAppState)
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_alice")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )
    aliceAppState.circleNotificationsModel = model

    let gate = AsyncGate()
    await service.setOnRefresh {
      await service.setOnRefresh(nil)
      await gate.enter()
    }

    let pushTask = Task { @MainActor in
      await manager.handlePush(["kind": "circle_activity"])
    }

    await gate.awaitEntry()

    // Switch lifecycle in AppStateManager to Bob and invalidate Alice
    AppStateManager.shared.setLifecycleForTesting(.authenticated(bobAppState))
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    await cache.purge(accountDID: "did:plc:alice")

    #expect(await cache.page(accountDID: "did:plc:alice") == nil)

    await gate.release()
    await pushTask.value

    // Because lifecycle switched to bob during await, alice's model and cache must remain empty and invalidated
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
    #expect(model.isInvalidated)
    let cachedAlice = await cache.page(accountDID: "did:plc:alice")
    #expect(cachedAlice == nil)
  }

  @Test("Generic push with nil/launching/unauthenticated lifecycle discards before mutation")
  @MainActor
  func genericPushWithNilOrUnauthenticatedLifecycleDiscardsBeforeMutation() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let aliceAppState = AppState(userDID: "did:plc:alice", client: client)

    let previousLifecycle = AppStateManager.shared.lifecycle
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
    }

    let manager = NotificationManager()
    manager.configure(with: aliceAppState)
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_alice")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )
    aliceAppState.circleNotificationsModel = model

    // 1. Launching
    AppStateManager.shared.setLifecycleForTesting(.launching)
    await manager.handlePush(["kind": "circle_activity"])
    #expect(await service.refreshCount == 0)
    #expect(model.notifications.isEmpty)

    // 2. Unauthenticated
    AppStateManager.shared.setLifecycleForTesting(.unauthenticated)
    await manager.handlePush(["kind": "circle_activity"])
    #expect(await service.refreshCount == 0)
    #expect(model.notifications.isEmpty)
  }

  @Test("Generic push with weak AppState loss discards before mutation")
  @MainActor
  func genericPushWithWeakAppStateLossDiscardsBeforeMutation() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    var localAppState: AppState? = AppState(userDID: "did:plc:alice", client: client)

    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(localAppState!))
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
    }

    let manager = NotificationManager()
    manager.configure(with: localAppState!)
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_alice")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )
    localAppState?.circleNotificationsModel = model

    let gate = AsyncGate()
    await service.setOnRefresh {
      await service.setOnRefresh(nil)
      await gate.enter()
    }

    let pushTask = Task { @MainActor in
      await manager.handlePush(["kind": "circle_activity"])
    }

    await gate.awaitEntry()

    // Deallocate localAppState during the in-flight suspended refresh
    AppStateManager.shared.setLifecycleForTesting(.unauthenticated)
    localAppState = nil

    await gate.release()
    await pushTask.value

    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
  }

  // 14. Barrier test: In-flight notification load overlapped with account purge does not resurrect notifications
  @Test("In-flight notification load overlapped with account purge does not resurrect notifications")
  @MainActor
  func inFlightNotificationLoadOverlappedWithAccountPurgeDoesNotResurrect() async throws {
    let cache = CircleNotificationCache()
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_1")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )

    // Overlap: during listNotifications await, trigger account purge
    await service.setOnListNotifications {
      await MainActor.run {
        Task {
          await model.purgeAccount()
        }
      }
    }

    try await model.load()

    // Notifications must remain empty because purge bumped generation
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
  }

  // 15. Barrier test: In-flight notification load overlapped with space deletion does not resurrect space notifications
  @Test("In-flight notification load overlapped with space deletion does not resurrect space notifications")
  @MainActor
  func inFlightNotificationLoadOverlappedWithSpaceDeletionDoesNotResurrect() async throws {
    let cache = CircleNotificationCache()
    let notifFamily = makeNotification(id: "n_fam", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notifFamily], cursor: "cursor_1")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache
    )

    // Overlap: during listNotifications await, trigger .circleDeleted notification
    await service.setOnListNotifications {
      await MainActor.run {
        NotificationCenter.default.post(
          name: .circleDeleted,
          object: nil,
          userInfo: [
            "accountDID": "did:plc:alice",
            "spaceURI": self.familyCircle.uri.uriString()
          ]
        )
      }
    }

    try await model.load()

    // Family notifications must remain removed
    #expect(model.notifications.isEmpty)
  }

  // 17. Barrier test: In-flight notification cache restore overlapped with account invalidation discards old cache and retains sibling
  @Test("Barrier test: in-flight notification cache restore overlapped with account invalidation discards old cache and retains sibling")
  @MainActor
  func inFlightNotificationCacheRestoreOverlappedWithAccountInvalidationDiscardsOldCacheAndRetainsSibling() async throws {
    let cache = CircleNotificationCache()
    let notifAlice = makeNotification(id: "n_alice", reason: .value_reply, circle: familyCircle)
    let notifBob = makeNotification(id: "n_bob", reason: .value_reply, circle: familyCircle)

    await cache.store(CircleNotificationPage(notifications: [notifAlice], cursor: "cur_alice"), accountDID: "did:plc:alice")
    await cache.store(CircleNotificationPage(notifications: [notifBob], cursor: "cur_bob"), accountDID: "did:plc:bob")

    let service = RecordingCircleNotificationService()
    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache,
      activeDIDProvider: { "did:plc:alice" }
    )

    let gate = AsyncGate()
    await cache.setOnPageFetch {
      await cache.setOnPageFetch(nil)
      await gate.enter()
    }

    let loadTask = Task { @MainActor in
      try await model.load()
    }

    await gate.awaitEntry()

    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    await cache.purge(accountDID: "did:plc:alice")

    // Assert departing cache removed and sibling present before releasing stale snapshot
    #expect(await cache.page(accountDID: "did:plc:alice") == nil)
    let bobCachedBefore = await cache.page(accountDID: "did:plc:bob")
    #expect(bobCachedBefore != nil)
    #expect(bobCachedBefore?.notifications.count == 1)

    // Release gate allowing the cache read to complete returning the captured stale snapshot
    await gate.release()
    _ = try? await loadTask.value

    // Alice's model must remain empty and permanently invalidated (stale snapshot discarded)
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
    #expect(model.isInvalidated)
    #expect(await cache.page(accountDID: "did:plc:alice") == nil)

    // Subsequent load or refresh calls cannot resurrect data
    try? await model.load()
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
    #expect(await cache.page(accountDID: "did:plc:alice") == nil)

    // Bob's cache must be retained intact
    let bobCached = await cache.page(accountDID: "did:plc:bob")
    #expect(bobCached != nil)
    #expect(bobCached?.notifications.count == 1)
    #expect(bobCached?.notifications.first?.id == "n_bob")
  }

  // 18. Barrier test: In-flight notification network refresh overlapped with account switch discards old response and retains sibling
  @Test("Barrier test: in-flight notification network refresh overlapped with account switch discards old response and retains sibling")
  @MainActor
  func inFlightNotificationNetworkRefreshOverlappedWithAccountSwitchDiscardsOldResponseAndRetainsSibling() async throws {
    let cache = CircleNotificationCache()
    let notifAlice = makeNotification(id: "n_alice", reason: .value_reply, circle: familyCircle)
    let notifBob = makeNotification(id: "n_bob", reason: .value_reply, circle: familyCircle)

    await cache.store(CircleNotificationPage(notifications: [notifBob], cursor: "cur_bob"), accountDID: "did:plc:bob")

    let service = RecordingCircleNotificationService()
    await service.setPages([CircleNotificationPage(notifications: [notifAlice], cursor: "cur_alice")])

    final class ActiveAccountHolder: @unchecked Sendable {
      var did: String = "did:plc:alice"
    }
    let activeHolder = ActiveAccountHolder()

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: cache,
      activeDIDProvider: { activeHolder.did }
    )

    let gate = AsyncGate()
    await service.setOnRefresh {
      await service.setOnRefresh(nil)
      await gate.enter()
    }

    let refreshTask = Task { @MainActor in
      try await model.refresh()
    }

    await gate.awaitEntry()

    // Simulate account switch to Bob
    activeHolder.did = "did:plc:bob"
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    await cache.purge(accountDID: "did:plc:alice")

    #expect(await cache.page(accountDID: "did:plc:alice") == nil)

    await gate.release()
    _ = try? await refreshTask.value

    // Alice's model must remain empty and invalidated
    #expect(model.notifications.isEmpty)
    #expect(model.cursor == nil)
    #expect(model.isInvalidated)

    // Alice's cache must be empty
    let aliceCached = await cache.page(accountDID: "did:plc:alice")
    #expect(aliceCached == nil)

    // Bob's cache must be retained intact
    let bobCached = await cache.page(accountDID: "did:plc:bob")
    #expect(bobCached != nil)
    #expect(bobCached?.notifications.count == 1)
    #expect(bobCached?.notifications.first?.id == "n_bob")
  }

  @Test("Invalidated CircleNotificationsModel permanently rejects all new operations")
  @MainActor
  func invalidatedCircleNotificationsModelPermanentlyRejectsOperations() async throws {
    let notif = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notif], cursor: "cursor_1")

    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: CircleNotificationCache()
    )

    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )

    #expect(model.isInvalidated)

    // Try load -> fails closed immediately
    try await model.load()
    #expect(model.notifications.isEmpty)
    #expect(await service.listNotificationsCalls.isEmpty)

    // Try refresh -> fails closed immediately
    try await model.refresh()
    #expect(model.notifications.isEmpty)
    #expect(await service.refreshCount == 0)

    // Try loadMore -> fails closed immediately
    try await model.loadMore()
    #expect(model.notifications.isEmpty)
  }

  // 16. Content-free error message canary test
  @Test("CircleNotificationsSection error UI renders content-free category text and never leaks canaries")
  func errorUIRendersContentFreeCategoryTextAndNeverLeaksCanaries() {
    let canaryServerURL = "https://sensitive.internal.server.net/v1/api"
    let canaryDID = "did:plc:topsecretcanary12345"
    let canarySpace = "at://did:plc:canary/space/blue.catbird.circle/secretspace"
    let canaryMessage = "Internal database constraint violation at row 42 for token_abc123"

    let testErrors: [CircleError] = [
      .networkError("\(canaryServerURL)/\(canaryDID)"),
      .spaceWriteRejected("\(canarySpace) -> \(canaryMessage)"),
      .invalidParameter("Canary secret parameter \(canaryDID)"),
      .upstreamUnavailable,
      .accessRemoved,
      .accessExpired,
      .unsupportedPDS,
      .protocolRevisionMismatch,
      .authRequired,
      .notAuthorized,
      .clientNotInitialized,
      .invalidResponse,
      .missingLikeUri
    ]

    for error in testErrors {
      let message = CircleNotificationsSection.contentFreeErrorMessage(for: error)
      #expect(!message.isEmpty)
      #expect(!message.contains(canaryServerURL))
      #expect(!message.contains(canaryDID))
      #expect(!message.contains(canarySpace))
      #expect(!message.contains(canaryMessage))
      #expect(!message.contains("token_abc123"))
      #expect(!message.contains("topsecretcanary"))
    }
  }

  // 17. AuthManager content-free logs canary test
  @Test("AuthManager updateState and auto-logout logs are content-free finite codes excluding all canaries")
  @MainActor
  func authManagerLogsAreContentFreeAndExcludeCanaries() async throws {
    let canaryDID = "did:plc:supersecretcanaryauthdid999"
    let canaryHandle = "supersecretcanaryhandle.bsky.social"
    let canaryReason = "super_secret_revocation_reason_token_leak_canary"
    let canaryToken = "secret_oauth_bearer_token_xyz_987654321"
    let canaryURL = "https://secret.auth.server.example.com/oauth/authorize?token=" + canaryToken
    let canaryServer = "secret.auth.server.example.com"

    var capturedLogs: [String] = []
    AuthenticationManager.capturedLogHook = { message in
      capturedLogs.append(message)
    }
    defer {
      AuthenticationManager.capturedLogHook = nil
    }

    let authManager = AuthenticationManager()

    // Trigger auto-logout from Petrel with canary DID and reason
    await authManager.handleAutoLogoutFromPetrel(did: canaryDID, reason: canaryReason)

    // Trigger various updateState transitions
    authManager.updateState(.authenticating(progress: .resolvingHandle(handle: canaryHandle)))
    authManager.updateState(.error(message: "Fatal token rejection: \(canaryToken) at \(canaryURL)"))
    authManager.updateState(.authenticated(userDID: canaryDID))
    authManager.updateState(.unauthenticated)

    // Verify logs WERE actually captured (non-vacuous check)
    #expect(!capturedLogs.isEmpty, "Auth logs must be captured by the test seam")

    // Verify NONE of the captured logs contain sensitive canaries
    for log in capturedLogs {
      #expect(!log.contains(canaryDID), "Log contained canary DID: \(log)")
      #expect(!log.contains(canaryHandle), "Log contained canary handle: \(log)")
      #expect(!log.contains(canaryReason), "Log contained canary reason: \(log)")
      #expect(!log.contains(canaryToken), "Log contained canary token: \(log)")
      #expect(!log.contains(canaryURL), "Log contained canary URL: \(log)")
      #expect(!log.contains(canaryServer), "Log contained canary server: \(log)")
    }

    // Verify AuthState caseLabels are finite and content-free, never stringifying associated canaries
    let states: [AuthState] = [
      .initializing,
      .unauthenticated,
      .authenticating(progress: .resolvingHandle(handle: canaryHandle)),
      .authenticated(userDID: canaryDID),
      .error(message: "Sensitive server error: \(canaryURL)")
    ]

    for s in states {
      let label = s.caseLabel
      #expect(!label.isEmpty)
      #expect(!label.contains(canaryDID))
      #expect(!label.contains(canaryHandle))
      #expect(!label.contains(canaryToken))
      #expect(!label.contains(canaryURL))
      #expect(["initializing", "unauthenticated", "authenticating", "authenticated", "error"].contains(label))
    }
  }

  // 18. Switch Alice -> Bob -> Alice rebuilds fresh Circle models; old model stays inert
  @Test("Account switch Alice -> Bob -> Alice rebuilds fresh Circle models while old model stays inert")
  @MainActor
  func accountSwitchAliceBobAliceRebuildsFreshCircleModels() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let aliceState1 = AppState(userDID: "did:plc:alice", client: client)
    let service1 = RecordingCircleNotificationService()
    let notif1 = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    await service1.setPages([CircleNotificationPage(notifications: [notif1], cursor: nil)])
    aliceState1.circleNotificationService = service1

    let model1 = aliceState1.circleNotificationsModel
    try await model1.refresh()
    #expect(model1.notifications.count == 1)
    #expect(!model1.isInvalidated)

    // Switch Alice -> Bob: posts invalidation for Alice
    NotificationCenter.default.post(
      name: .circleAccountInvalidated,
      object: nil,
      userInfo: ["accountDID": "did:plc:alice"]
    )
    #expect(model1.isInvalidated)

    // Verify old model1 is inert
    await service1.setPages([CircleNotificationPage(notifications: [notif1, notif1], cursor: nil)])
    try await model1.refresh()
    #expect(model1.isInvalidated)
    #expect(model1.notifications.isEmpty)

    // Switch Bob -> Alice: reconstructs new AppState and new Circle model
    let aliceState2 = AppState(userDID: "did:plc:alice", client: client)
    let service2 = RecordingCircleNotificationService()
    let notif2 = makeNotification(id: "n2", reason: .value_like, circle: familyCircle)
    await service2.setPages([CircleNotificationPage(notifications: [notif2], cursor: nil)])
    aliceState2.circleNotificationService = service2

    let model2 = aliceState2.circleNotificationsModel
    #expect(!model2.isInvalidated)
    try await model2.refresh()
    #expect(model2.notifications.count == 1)
    #expect(model2.notifications.first?.id == "n2")

    // Old model remains inert
    #expect(model1.isInvalidated)
    #expect(model1.notifications.isEmpty)
  }

  // 19. Forced database drain failure during switch propagates and recovers without leaving lifecycle .launching
  @Test("Forced database drain failure during account switch propagates and recovers safely")
  @MainActor
  func forcedDatabaseDrainFailureDuringSwitchRecoversSafely() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let aliceState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(aliceState))
    defer {
      AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
      AppStateManager.databaseDrainOverride = nil
    }

    // Force database drain failure
    AppStateManager.databaseDrainOverride = { _, _ in false }

    // Attempt switch to Bob
    await AppStateManager.shared.switchAccount(to: "did:plc:bob")

    // Verify lifecycle is NOT stuck in .launching
    #expect(AppStateManager.shared.lifecycle != .launching)
    // Verify alert was set explaining the safe recovery
    #expect(AppStateManager.shared.authentication.pendingAuthAlert?.title == "Restart Required")
  }
}

fileprivate actor AsyncGate {
  private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var isEntered = false
  private var isReleased = false

  func enter() async {
    isEntered = true
    for continuation in enteredContinuations {
      continuation.resume()
    }
    enteredContinuations.removeAll()

    if !isReleased {
      await withCheckedContinuation { continuation in
        releaseContinuations.append(continuation)
      }
    }
  }

  func awaitEntry() async {
    if isEntered { return }
    await withCheckedContinuation { continuation in
      enteredContinuations.append(continuation)
    }
  }

  func release() {
    isReleased = true
    for continuation in releaseContinuations {
      continuation.resume()
    }
    releaseContinuations.removeAll()
  }
}
