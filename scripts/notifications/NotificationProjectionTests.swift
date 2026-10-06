import Foundation
import Observation
import Testing
@testable import NotificationHarness

@Suite(.serialized)
@MainActor
struct NotificationProjectionTests {
  private struct Fixture {
    let appState: AppState
    let api: FakeNotificationAPI
    let manager: NotificationManager
    let viewModel: NotificationsViewModel
  }

  private func fixture() async -> Fixture {
    let appState = AppState(userDID: "did:plc:policy-viewer")
    let api = FakeNotificationAPI()
    let client = ATProtoClient(did: appState.userDID, api: api)
    let manager = NotificationManager(testAppState: appState, testDefaults: .init())
    await manager.updateClient(client)
    let viewModel = NotificationsViewModel(client: client, notificationManager: manager)
    return Fixture(appState: appState, api: api, manager: manager, viewModel: viewModel)
  }

  private func notification(
    _ reason: String,
    token: String,
    timestamp: TimeInterval = 1_000,
    isRead: Bool = false,
    subject: String? = nil,
    record: FakeRecord = .object([:])
  ) throws -> AppBskyNotificationListNotifications.Notification {
    .init(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/\(token)"),
      cid: try CID.parse("cid-\(token)"),
      author: .init(did: try DID(didString: "did:plc:author"), handle: try Handle(handleString: "author.test")),
      reason: reason,
      reasonSubject: try subject.map { try ATProtocolURI(uriString: $0) },
      record: record,
      isRead: isRead,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: timestamp))
    )
  }

  private func group(_ notification: AppBskyNotificationListNotifications.Notification, id: String, type: NotificationType, page: Int = 0) -> GroupedNotification {
    .init(id: id, type: type, notifications: [notification], subjectPost: nil, parentPost: nil, pageNumber: page)
  }

  private func hideLikes(_ manager: NotificationManager) {
    var preferences = manager.preferences
    preferences.like.list = false
    manager.applyNotificationPreferencesSnapshot(preferences.toServerPreferences())
  }

  @Test
  func preferenceProjectionInvalidatesAndReappearsWithoutRefetch() async throws {
    let f = await fixture()
    let like = try notification("like", token: "like", isRead: true)
    let follow = try notification("follow", token: "follow", isRead: false)
    let cached = [group(like, id: "like", type: .like), group(follow, id: "follow", type: .follow)]
    f.viewModel.testSeedCachedGroups(cached)
    let hiddenInvalidation = ObservationCounter()
    withObservationTracking {
      #expect(f.viewModel.groupedNotifications.map(\.id) == ["like", "follow"])
    } onChange: {
      hiddenInvalidation.increment()
    }

    hideLikes(f.manager)

    #expect(hiddenInvalidation.value == 1, "Live manager preferences must invalidate the computed projection")
    #expect(f.viewModel.groupedNotifications.map(\.id) == ["follow"])
    #expect(f.viewModel.testRawGroups.map(\.id) == ["like", "follow"])
    #expect(f.api.listInputs.isEmpty)

    let restoredInvalidation = ObservationCounter()
    withObservationTracking {
      _ = f.viewModel.groupedNotifications
    } onChange: {
      restoredInvalidation.increment()
    }
    f.manager.applyNotificationPreferencesSnapshot(NotificationPreferences().toServerPreferences())

    #expect(restoredInvalidation.value == 1)
    #expect(f.viewModel.groupedNotifications.map(\.id) == ["like", "follow"])
    #expect(f.viewModel.groupedNotifications.flatMap(\.notifications).map(\.isRead) == [true, false])
    #expect(f.api.listInputs.isEmpty, "Re-enabling uses the unchanged raw cache")
  }

  @Test
  func failedOptimisticPreferencePutRestoresCachedProjectionWithoutRefetch() async throws {
    let f = await fixture()
    let like = try notification("like", token: "retained", isRead: false)
    f.viewModel.testSeedCachedGroups([group(like, id: "retained-like", type: .like)])
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    f.api.getHandler = { (503, nil) }
    let optimisticInvalidation = ObservationCounter()
    withObservationTracking {
      _ = f.viewModel.groupedNotifications
    } onChange: {
      optimisticInvalidation.increment()
    }

    let write = Task { try await f.manager.updatePreferences { $0.like.list = false } }
    try await gate.waitForEntry()
    #expect(optimisticInvalidation.value == 1)
    #expect(f.viewModel.groupedNotifications.isEmpty)
    #expect(f.viewModel.testRawGroups.count == 1)
    let rollbackInvalidation = ObservationCounter()
    withObservationTracking {
      _ = f.viewModel.groupedNotifications
    } onChange: {
      rollbackInvalidation.increment()
    }

    gate.fail()
    let result = await write.result
    if case .success = result { Issue.record("Injected PUT failure must reach its caller") }

    #expect(rollbackInvalidation.value == 1)
    #expect(f.viewModel.groupedNotifications.map(\.id) == ["retained-like"])
    #expect(f.viewModel.groupedNotifications.first?.hasUnreadNotifications == true)
    #expect(f.api.listInputs.isEmpty, "Rollback must re-project retained data without refetching notifications")
  }

  @Test
  func hiddenPagesRetainServerCursorsAndLoadMoreAppendsRawPages() async throws {
    let f = await fixture()
    hideLikes(f.manager)
    let first = try notification("like", token: "hidden-first")
    let second = try notification("follow", token: "visible-second")
    let third = try notification("like", token: "hidden-third")
    f.api.listHandler = { input in
      switch input.cursor {
      case nil: return (200, .init(cursor: "server-page-two", notifications: [first]))
      case "server-page-two": return (200, .init(cursor: "server-page-three", notifications: [second]))
      case "server-page-three": return (200, .init(cursor: nil, notifications: [third]))
      default: throw HarnessError.injectedFailure
      }
    }

    await f.viewModel.testFetchPage(resetCursor: true)
    #expect(f.viewModel.groupedNotifications.isEmpty)
    #expect(f.viewModel.testRawGroups.count == 1)
    #expect(f.viewModel.testCursor == "server-page-two")
    #expect(f.viewModel.hasMoreNotifications)
    #expect(f.viewModel.testCurrentPage == 0)

    await f.viewModel.loadMoreNotifications()
    #expect(f.viewModel.groupedNotifications.flatMap(\.notifications).map(\.uri) == [second.uri])
    #expect(f.viewModel.testRawGroups.count == 2)
    #expect(f.viewModel.testCursor == "server-page-three")
    #expect(f.viewModel.hasMoreNotifications)

    await f.viewModel.loadMoreNotifications()
    #expect(f.viewModel.testRawGroups.count == 3)
    #expect(f.viewModel.testRawGroups.map(\.pageNumber) == [0, 1, 2])
    #expect(f.viewModel.testCursor == nil)
    #expect(!f.viewModel.hasMoreNotifications)
    #expect(f.api.listInputs.map(\.cursor) == [nil, "server-page-two", "server-page-three"])
    await f.viewModel.loadMoreNotifications()
    #expect(f.api.listInputs.count == 3, "Exhausted raw cursor must prevent a fourth request")

    f.manager.applyNotificationPreferencesSnapshot(NotificationPreferences().toServerPreferences())
    #expect(f.viewModel.groupedNotifications.flatMap(\.notifications).map(\.uri) == [first.uri, second.uri, third.uri])
    #expect(f.api.listInputs.count == 3)
  }

  @Test
  func refreshDiscardsPreviousCursorChainBeforeAppendingNewPages() async throws {
    let f = await fixture()
    let oldFirst = try notification("mention", token: "old-first")
    let oldLater = try notification("mention", token: "old-later")
    let newFirst = try notification("mention", token: "new-first")
    let newLater = try notification("mention", token: "new-later")
    f.api.listHandler = { input in
      if f.api.listInputs.count == 1 { return (200, .init(cursor: "old-page-two", notifications: [oldFirst])) }
      if input.cursor == "old-page-two" { return (200, .init(cursor: "old-page-three", notifications: [oldLater])) }
      if input.cursor == nil { return (200, .init(cursor: "new-page-two", notifications: [newFirst])) }
      if input.cursor == "new-page-two" { return (200, .init(cursor: nil, notifications: [newLater])) }
      throw HarnessError.injectedFailure
    }
    await f.viewModel.testFetchPage(resetCursor: true)
    await f.viewModel.loadMoreNotifications()
    #expect(f.viewModel.testRawGroups.flatMap(\.notifications).map(\.uri) == [oldFirst.uri, oldLater.uri])

    // The real refresh method resets the chain, then fills from its new cursor.
    await f.viewModel.refreshNotifications()

    #expect(f.viewModel.testRawGroups.flatMap(\.notifications).map(\.uri) == [newFirst.uri, newLater.uri])
    #expect(f.viewModel.groupedNotifications.flatMap(\.notifications).map(\.uri) == [newFirst.uri, newLater.uri])
    #expect(f.viewModel.testRawGroups.map(\.pageNumber) == [0, 1])
    #expect(!f.viewModel.hasMoreNotifications)
    #expect(f.viewModel.testCursor == nil)
    #expect(f.api.listInputs.map(\.cursor) == [nil, "old-page-two", nil, "new-page-two"])
  }

  @Test
  func allHiddenPagesFillBoundedlyAndRetainNextServerCursor() async throws {
    let f = await fixture()
    hideLikes(f.manager)
    f.api.listHandler = { _ in
      let page = f.api.listInputs.count
      let row = try notification("like", token: "hidden-\(page)")
      return (200, .init(cursor: "server-cursor-\(page)", notifications: [row]))
    }

    await f.viewModel.loadNotifications()

    #expect(f.api.listInputs.count == 4, "Initial page plus at most three bounded fill pages")
    #expect(f.api.listInputs.map(\.cursor) == [nil, "server-cursor-1", "server-cursor-2", "server-cursor-3"])
    #expect(f.viewModel.groupedNotifications.isEmpty)
    #expect(f.viewModel.testRawGroups.count == 4)
    #expect(f.viewModel.testCursor == "server-cursor-4")
    #expect(f.viewModel.hasMoreNotifications)
    #expect(!f.viewModel.isLoading)
    #expect(!f.viewModel.isLoadingMore)

    await f.viewModel.loadMoreNotifications()
    #expect(f.api.listInputs.last?.cursor == "server-cursor-4")
    #expect(f.viewModel.testRawGroups.count == 5)
    #expect(f.viewModel.testCursor == "server-cursor-5")
  }

  @Test
  func repeatedServerCursorStopsAutomaticFill() async throws {
    let f = await fixture()
    hideLikes(f.manager)
    f.api.listHandler = { _ in
      let row = try notification("like", token: "repeat-\(f.api.listInputs.count)")
      return (200, .init(cursor: "repeated-cursor", notifications: [row]))
    }

    await f.viewModel.loadNotifications()

    #expect(f.api.listInputs.count == 2)
    #expect(f.viewModel.testRawGroups.count == 2)
    #expect(f.viewModel.testCursor == "repeated-cursor")
    #expect(f.viewModel.hasMoreNotifications)
    #expect(!f.viewModel.isLoading)
  }

  @Test
  func viaRepostGroupingUsesDecodedOriginalSubjectForBothReasons() async throws {
    let f = await fixture()
    let firstOriginal = try ATProtocolURI(uriString: "at://did:plc:original/app.bsky.feed.post/first")
    let secondOriginal = try ATProtocolURI(uriString: "at://did:plc:original/app.bsky.feed.post/second")
    for reason in ["like-via-repost", "repost-via-repost"] {
      func record(_ original: ATProtocolURI) -> FakeRecord {
        if reason == "like-via-repost" { return .knownType(AppBskyFeedLike(subject: .init(uri: original))) }
        return .knownType(AppBskyFeedRepost(subject: .init(uri: original)))
      }
      let first = try notification(reason, token: "first", timestamp: 300, subject: "at://did:plc:reposter/app.bsky.feed.repost/shared", record: record(firstOriginal))
      let second = try notification(reason, token: "second", timestamp: 200, subject: "at://did:plc:reposter/app.bsky.feed.repost/shared", record: record(secondOriginal))
      let sameOriginal = try notification(reason, token: "same-original", timestamp: 100, subject: "at://did:plc:reposter/app.bsky.feed.repost/different", record: record(firstOriginal))

      #expect(NotificationsViewModel.viaRepostGroupingSubject(for: first) == firstOriginal.uriString())
      #expect(NotificationsViewModel.viaRepostGroupingSubject(for: second) == secondOriginal.uriString())
      #expect(NotificationsViewModel.viaRepostGroupingSubject(for: sameOriginal) == firstOriginal.uriString())
      let groups = await f.viewModel.groupNotifications([first, second, sameOriginal], pageNumber: 0)
      #expect(groups.count == 2)
      let firstGroup = try #require(groups.first { $0.notifications.contains { $0.uri == first.uri } })
      #expect(firstGroup.notifications.map(\.uri) == [first.uri, sameOriginal.uri])
      let secondGroup = try #require(groups.first { $0.notifications.contains { $0.uri == second.uri } })
      #expect(secondGroup.notifications.map(\.uri) == [second.uri])
    }
  }

  @Test
  func viaRepostFallbackUsesReasonSubjectOrUniqueEventIdentity() async throws {
    let f = await fixture()
    for reason in ["like-via-repost", "repost-via-repost"] {
      let fallbackSubject = "at://did:plc:author/app.bsky.feed.post/fallback"
      let withSubject = try notification(reason, token: "subject", subject: fallbackSubject)
      let first = try notification(reason, token: "first-missing", timestamp: 200)
      let second = try notification(reason, token: "second-missing", timestamp: 100)

      #expect(NotificationsViewModel.viaRepostGroupingSubject(for: withSubject) == fallbackSubject)
      #expect(NotificationsViewModel.viaRepostGroupingSubject(for: first) != NotificationsViewModel.viaRepostGroupingSubject(for: second))
      let groups = await f.viewModel.groupNotifications([first, second], pageNumber: 0)
      #expect(groups.count == 2, "Missing subjects must not collapse unrelated events into an empty grouping key")
    }
  }

  @Test
  func viewModelWithoutManagerUsesDefaultListPreferences() throws {
    let model = NotificationsViewModel(client: nil)
    let like = try notification("like", token: "preview-like")
    let cached = group(like, id: "preview-like", type: .like)
    model.testSeedCachedGroups([cached])
    #expect(model.groupedNotifications.map(\.id) == ["preview-like"])
    #expect(model.testRawGroups.count == 1)
  }
}
