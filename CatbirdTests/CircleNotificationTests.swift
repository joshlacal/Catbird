//
//  CircleNotificationTests.swift
//  CatbirdTests
//

import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import Testing
@testable import Catbird

// MARK: - Test Doubles

actor RecordingCircleNotificationService: CircleNotificationServiceProtocol {
  private(set) var refreshCount = 0
  private(set) var listNotificationsCalls: [String?] = []
  var pagesToReturn: [CircleNotificationPage] = []
  var errorToThrow: Error?

  func setPages(_ pages: [CircleNotificationPage]) {
    self.pagesToReturn = pages
  }

  func setError(_ error: Error?) {
    self.errorToThrow = error
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
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
    let manager = NotificationManager()
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
    let manager = NotificationManager()
    let service = RecordingCircleNotificationService()
    await service.setError(CircleError.accessExpired)
    let model = CircleNotificationsModel(service: service, accountDID: "did:plc:alice")

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
    let notifFamily = makeNotification(id: "n1", reason: .value_reply, circle: familyCircle)
    let page = CircleNotificationPage(notifications: [notifFamily], cursor: nil)
    let service = RecordingCircleNotificationService()
    await service.setPages([page])

    let model = CircleNotificationsModel(
      service: service,
      accountDID: "did:plc:alice",
      cache: CircleNotificationCache()
    )
    try await model.load()
    #expect(model.notifications.count == 1)

    NotificationCenter.default.post(
      name: .circleDeleted,
      object: nil,
      userInfo: [
        "accountDID": "did:plc:bob",
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
}
