import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
@Suite("Notification preference persistence", .serialized)
struct NotificationPreferencesPersistenceTests {
  @Test("A failed initial GET disables edits and Retry loads saved preferences without a PUT")
  func failedInitialLoadRequiresRetryBeforeEditing() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    fixture.service.failingFetchAccounts.insert(fixture.didA)

    await fixture.manager.updateClient(fixture.clientA)

    #expect(fixture.manager.preferencesState == .loadFailed(NotificationPersistenceError.fetch.localizedDescription))
    #expect(!fixture.manager.canEditNotificationPreferences)
    #expect(fixture.service.fetchAccounts == [fixture.didA])
    #expect(fixture.service.saveRequests.isEmpty)
    #expect(!fixture.manager.chatNotificationsEnabled)
    do {
      try await fixture.manager.updatePreferences({ $0.like = .init(include: "follows", list: true, push: false) },
        expectedAccountDID: fixture.didA)
      Issue.record("An edit was accepted before the saved preferences loaded")
    } catch {
      #expect(error is NotificationManager.NotificationServiceError)
    }
    #expect(fixture.service.saveRequests.isEmpty)

    fixture.service.failingFetchAccounts.remove(fixture.didA)
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)

    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.manager.canEditNotificationPreferences)
    #expect(fixture.manager.preferences == fixture.originalA)
    #expect(fixture.service.fetchAccounts == [fixture.didA, fixture.didA])
    #expect(fixture.service.saveRequests.isEmpty)
    #expect(fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
  }

  @Test("A PUT without a confirmed snapshot rolls back and retains its exact retry")
  func unconfirmedSaveRollsBackAndRetainsExactRetry() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    fixture.service.unconfirmedSaveAccounts.insert(fixture.didA)
    var requested = fixture.originalA
    requested.chat = .init(include: requested.chat.include, push: false)

    do {
      try await fixture.manager.updatePreferences(requested, expectedAccountDID: fixture.didA)
      Issue.record("A PUT without a confirmed snapshot was reported saved")
    } catch {
      #expect(error is NotificationManager.NotificationServiceError)
    }

    #expect(fixture.manager.preferences == fixture.originalA)
    #expect(!fixture.manager.canEditNotificationPreferences)
    if case .saveFailed(let message) = fixture.manager.preferencesState {
      #expect(message.contains("did not confirm"))
    } else {
      Issue.record("Missing confirmation must leave a retryable save failure")
    }
    #expect(fixture.manager.chatNotificationsEnabled)
    #expect(fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
    let failedInput = try #require(fixture.service.saveRequests.first?.input)
    let exactAttempt = try fixture.encodedInput(failedInput)

    fixture.service.unconfirmedSaveAccounts.remove(fixture.didA)
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)

    #expect(fixture.service.saveRequests.count == 2)
    let retriedInput = try #require(fixture.service.saveRequests.last?.input)
    #expect(try fixture.encodedInput(retriedInput) == exactAttempt)
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.manager.preferences == requested)
    #expect(!fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
    #expect(fixture.service.fetchAccounts == [fixture.didA])
  }

  @Test("Editing one category omits every sibling and preserves custom chat and mixed categories")
  func oneCategoryEditSendsPartialInput() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    var requested = fixture.originalA
    requested.like = .init(include: "follows", list: true, push: false)

    try await fixture.manager.updatePreferences({ $0.like = requested.like }, expectedAccountDID: fixture.didA)

    let input = try #require(fixture.service.saveRequests.first?.input)
    #expect(input.like == requested.like)
    #expect(input.chat == nil)
    #expect(input.follow == nil)
    #expect(input.likeViaRepost == nil)
    #expect(input.mention == nil)
    #expect(input.quote == nil)
    #expect(input.reply == nil)
    #expect(input.repost == nil)
    #expect(input.repostViaRepost == nil)
    #expect(input.starterpackJoined == nil)
    #expect(input.subscribedPost == nil)
    #expect(input.unverified == nil)
    #expect(input.verified == nil)
    #expect(fixture.service.saveRequests.count == 1)
    #expect(fixture.manager.preferences == requested)
    #expect(fixture.manager.preferences.chat.include == "custom-service-chat")
    #expect(fixture.manager.preferences.starterpackJoined == fixture.originalA.starterpackJoined)
    #expect(fixture.manager.preferences.verified == fixture.originalA.verified)
    #expect(fixture.manager.preferences.unverified == fixture.originalA.unverified)
  }

  @Test("A failed PUT rolls back values and account defaults, then retries the exact partial input")
  func failedSaveRollsBackAndRetriesExactAttempt() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    fixture.service.failingSaveAccounts.insert(fixture.didA)
    var requested = fixture.originalA
    requested.chat = .init(include: requested.chat.include, push: false)
    requested.like = .init(include: "follows", list: true, push: false)

    do {
      try await fixture.manager.updatePreferences(requested, expectedAccountDID: fixture.didA)
      Issue.record("The fixture PUT failure was accepted as a confirmed save")
    } catch {
      #expect(error as? NotificationPersistenceError == .save)
    }

    #expect(fixture.manager.preferences == fixture.originalA)
    #expect(fixture.manager.preferencesState == .saveFailed(NotificationPersistenceError.save.localizedDescription))
    #expect(!fixture.manager.canEditNotificationPreferences)
    #expect(fixture.manager.chatNotificationsEnabled)
    #expect(fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
    #expect(fixture.service.snapshots[fixture.didA] == fixture.originalA)
    let failedInput = try #require(fixture.service.saveRequests.first?.input)
    let exactAttempt = try fixture.encodedInput(failedInput)

    fixture.service.failingSaveAccounts.remove(fixture.didA)
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)

    #expect(fixture.service.saveRequests.count == 2)
    let retriedInput = try #require(fixture.service.saveRequests.last?.input)
    #expect(try fixture.encodedInput(retriedInput) == exactAttempt)
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.manager.preferences == requested)
    #expect(!fixture.manager.chatNotificationsEnabled)
    #expect(!fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
    #expect(fixture.service.fetchAccounts == [fixture.didA])
  }

  @Test("A later failure rolls back to the latest accepted response")
  func laterFailureRestoresLatestConfirmedSnapshot() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    let firstResponse = NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences?>()
    fixture.service.heldSave = (fixture.didA, firstResponse)
    let firstSave = Task { @MainActor in
      try await fixture.manager.updatePreferences({ $0.like = .init(include: "follows", list: true, push: false) },
        expectedAccountDID: fixture.didA)
    }
    defer {
      firstSave.cancel()
      firstResponse.resolve(.failure(CancellationError()))
    }
    do {
      try await firstResponse.waitUntilSuspended()
    } catch {
      firstSave.cancel()
      firstResponse.resolve(.failure(CancellationError()))
      _ = await firstSave.result
      throw error
    }
    var accepted = fixture.manager.preferences
    accepted.chat = .init(include: "accepted-custom-chat", push: false)
    accepted.mention = .init(include: "accepted-custom-mention", list: false, push: true)
    #expect(fixture.service.saveRequests.count == 1)
    firstResponse.resolve(.success(accepted.toServerPreferences()))
    let firstResult = await firstSave.result
    if case .failure(let error) = firstResult {
      Issue.record("The first PUT unexpectedly failed: \(error.localizedDescription)")
    }
    #expect(fixture.manager.preferencesState == .ready)

    fixture.service.failingSaveAccounts.insert(fixture.didA)
    let laterQuote = AppBskyNotificationDefs.FilterablePreference(include: "all", list: true, push: true)
    do {
      try await fixture.manager.updatePreferences({ $0.quote = laterQuote }, expectedAccountDID: fixture.didA)
      Issue.record("The later PUT unexpectedly succeeded")
    } catch {
      #expect(error as? NotificationPersistenceError == .save)
    }

    #expect(fixture.service.saveRequests.count == 2)
    #expect(fixture.manager.preferences == accepted)
    #expect(fixture.manager.preferencesState == .saveFailed(NotificationPersistenceError.save.localizedDescription))
    #expect(!fixture.manager.chatNotificationsEnabled)
    #expect(!fixture.defaults.bool(forKey: fixture.chatKey(fixture.didA)))
    #expect(fixture.service.snapshots[fixture.didA] == accepted)
    let laterInput = try #require(fixture.service.saveRequests.last?.input)
    #expect(laterInput.quote == laterQuote)
    #expect(laterInput.like == nil)
    #expect(laterInput.chat == nil)
    #expect(laterInput.mention == nil)
  }

  @Test("A pending Likes save refuses Quotes edits and retains its failure for exact retry before a later save")
  func failedFirstSaveRetainsRetryAndRefusesOverlappingEdit() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    var initial = fixture.originalA
    initial.quote = .init(include: "custom-service-quote", list: true, push: true)
    fixture.service.snapshots[fixture.didA] = initial
    await fixture.manager.updateClient(fixture.clientA)
    var firstRequested = initial
    firstRequested.like = .init(include: initial.like.include, list: initial.like.list, push: false)
    let firstResponse = NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences?>()
    fixture.service.heldSave = (fixture.didA, firstResponse)
    let firstSave = Task { @MainActor in
      try await fixture.manager.updatePreferences(firstRequested, expectedAccountDID: fixture.didA)
    }
    defer {
      firstSave.cancel()
      firstResponse.resolve(.failure(CancellationError()))
    }
    do {
      try await firstResponse.waitUntilSuspended()
    } catch {
      firstSave.cancel()
      firstResponse.resolve(.failure(CancellationError()))
      _ = await firstSave.result
      throw error
    }
    #expect(fixture.manager.preferencesState == .saving)
    #expect(!fixture.manager.canEditNotificationPreferences)
    #expect(fixture.manager.preferences == firstRequested)
    let quotesOff = AppBskyNotificationDefs.FilterablePreference(
      include: initial.quote.include, list: initial.quote.list, push: false)
    do {
      try await fixture.manager.updatePreferences({ $0.quote = quotesOff }, expectedAccountDID: fixture.didA)
      Issue.record("A second edit was admitted while the first save was pending")
    } catch {
      #expect(error is NotificationManager.NotificationServiceError)
      #expect(error.localizedDescription.contains("finish saving"))
    }
    #expect(fixture.service.saveRequests.count == 1)
    #expect(fixture.manager.preferencesState == .saving)
    #expect(fixture.manager.preferences == firstRequested)
    #expect(fixture.manager.pendingNotificationChangesDescription == nil)
    let failedInput = try #require(fixture.service.saveRequests.first?.input)
    #expect(failedInput.like == firstRequested.like)
    #expect(failedInput.quote == nil)
    #expect(failedInput.chat == nil)
    let exactAttempt = try fixture.encodedInput(failedInput)

    firstResponse.resolve(.failure(NotificationPersistenceError.save))
    switch await firstSave.result {
    case .success:
      Issue.record("The held first save unexpectedly succeeded")
    case .failure(let error):
      #expect(error as? NotificationPersistenceError == .save)
    }
    #expect(fixture.manager.preferencesState == .saveFailed(NotificationPersistenceError.save.localizedDescription))
    #expect(!fixture.manager.canEditNotificationPreferences)
    #expect(fixture.manager.preferences == initial)
    #expect(fixture.manager.pendingNotificationChangesDescription == failedInput.notificationChangesDescription)
    #expect(fixture.service.snapshots[fixture.didA] == initial)

    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)
    #expect(fixture.service.saveRequests.count == 2)
    let retriedInput = try #require(fixture.service.saveRequests.last?.input)
    #expect(try fixture.encodedInput(retriedInput) == exactAttempt)
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.manager.canEditNotificationPreferences)
    #expect(fixture.manager.preferences == firstRequested)
    #expect(fixture.manager.pendingNotificationChangesDescription == nil)

    try await fixture.manager.updatePreferences({ $0.quote = quotesOff }, expectedAccountDID: fixture.didA)
    #expect(fixture.service.saveRequests.count == 3)
    let laterInput = try #require(fixture.service.saveRequests.last?.input)
    #expect(laterInput.quote == quotesOff)
    #expect(laterInput.like == nil)
    #expect(laterInput.chat == nil)
    var finalRequested = firstRequested
    finalRequested.quote = quotesOff
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.manager.preferences == finalRequested)
    #expect(fixture.service.snapshots[fixture.didA] == finalRequested)
    #expect(fixture.manager.preferences.chat.include == "custom-service-chat")
    #expect(fixture.manager.preferences.quote.include == "custom-service-quote")
    #expect(fixture.manager.preferences.verified == initial.verified)
    #expect(fixture.manager.preferences.starterpackJoined == initial.starterpackJoined)
    #expect(fixture.service.fetchAccounts == [fixture.didA])
  }

  @Test("A delayed GET from account A cannot replace account B or write its defaults")
  func staleLoadCannotPublishAcrossAccountChange() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    let response = NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences>()
    fixture.service.heldFetch = (fixture.didA, response)
    let oldLoad = Task { @MainActor in await fixture.manager.updateClient(fixture.clientA) }
    defer {
      oldLoad.cancel()
      response.resolve(.failure(CancellationError()))
    }
    do {
      try await response.waitUntilSuspended()
    } catch {
      oldLoad.cancel()
      response.resolve(.failure(CancellationError()))
      await oldLoad.value
      throw error
    }
    #expect(fixture.manager.preferencesState == .loading)
    #expect(!fixture.manager.canEditNotificationPreferences)

    fixture.account.did = fixture.didB
    await fixture.manager.updateClient(fixture.clientB)
    let storedBeforeOldResponse = fixture.defaultsSnapshot()
    response.resolve(.success(fixture.originalA.toServerPreferences()))
    await oldLoad.value

    #expect(fixture.manager.preferences == fixture.originalB)
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.defaultsSnapshot() == storedBeforeOldResponse)
    #expect(!fixture.defaults.bool(forKey: fixture.chatKey(fixture.didB)))
    let fetchCount = fixture.service.fetchAccounts.count
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)
    #expect(fixture.service.fetchAccounts.count == fetchCount)
    #expect(fixture.service.saveRequests.isEmpty)
  }

  @Test("A delayed PUT result from account A cannot publish or become account B's retry", arguments: [false, true])
  func staleSaveCannotPublishOrRetryAcrossAccountChange(succeeds: Bool) async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    let response = NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences?>()
    fixture.service.heldSave = (fixture.didA, response)
    let oldSave = Task { @MainActor in
      try await fixture.manager.updatePreferences({ $0.chat = .init(include: "attempted-A-chat", push: false) },
        expectedAccountDID: fixture.didA)
    }
    defer {
      oldSave.cancel()
      response.resolve(.failure(CancellationError()))
    }
    do {
      try await response.waitUntilSuspended()
    } catch {
      oldSave.cancel()
      response.resolve(.failure(CancellationError()))
      _ = await oldSave.result
      throw error
    }

    fixture.account.did = fixture.didB
    await fixture.manager.updateClient(fixture.clientB)
    let storedBeforeOldResponse = fixture.defaultsSnapshot()
    if succeeds {
      response.resolve(.success(fixture.originalA.toServerPreferences()))
    } else {
      response.resolve(.failure(NotificationPersistenceError.save))
    }
    _ = await oldSave.result

    #expect(fixture.manager.preferences == fixture.originalB)
    #expect(fixture.manager.preferencesState == .ready)
    #expect(fixture.defaultsSnapshot() == storedBeforeOldResponse)
    #expect(fixture.service.saveRequests.count == 1)
    #expect(fixture.service.saveRequests.first?.accountDID == fixture.didA)
    let fetchCount = fixture.service.fetchAccounts.count
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didA)
    #expect(fixture.service.fetchAccounts.count == fetchCount)
    #expect(fixture.service.saveRequests.count == 1)
    await fixture.manager.retryNotificationPreferences(expectedAccountDID: fixture.didB)
    #expect(fixture.service.fetchAccounts.last == fixture.didB)
    #expect(fixture.service.fetchAccounts.count == fetchCount + 1)
    #expect(fixture.service.saveRequests.count == 1)
    #expect(fixture.manager.preferences == fixture.originalB)
  }

  @Test("Unread activity is checked with master push disabled and no device token")
  func unreadCheckingContinuesWithPushPaused() async throws {
    let fixture = try await NotificationPersistenceFixture()
    defer { fixture.removeDefaultsSuite() }
    await fixture.manager.updateClient(fixture.clientA)
    #expect(!fixture.manager.isPushRequested)
    #expect(!fixture.manager.notificationsEnabled)
    #expect(fixture.manager.status == .disabled)
    #expect(fixture.manager.deviceToken == nil)

    await fixture.manager.checkUnreadNotifications()

    #expect(fixture.service.unreadAccounts == [fixture.didA])
    #expect(fixture.manager.unreadCount == 0)
    #expect(fixture.manager.status == .disabled)
    #expect(!fixture.manager.notificationsEnabled)
    #expect(!fixture.defaults.bool(forKey: fixture.masterKey(fixture.didA)))
    #expect(fixture.service.saveRequests.isEmpty)
  }
}

@MainActor
private final class NotificationPersistenceFixture {
  let didA: String
  let didB: String
  let suiteName: String
  let defaults: UserDefaults
  let service: NotificationPreferenceFakeService
  let account: NotificationFixtureAccount
  let clientA: ATProtoClient
  let clientB: ATProtoClient
  let manager: NotificationManager
  let originalA: NotificationPreferences
  let originalB: NotificationPreferences

  init() async throws {
    let didA = "did:plc:notification-preferences-a"
    let didB = "did:plc:notification-preferences-b"
    let suiteName = "NotificationPreferencesPersistenceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let service = NotificationPreferenceFakeService()
    let account = NotificationFixtureAccount(did: didA)
    let localURL = try #require(URL(string: "http://127.0.0.1:1"))
    let clientA = await ATProtoClient(baseURL: localURL)
    let clientB = await ATProtoClient(baseURL: localURL)
    let originalA = Self.samplePreferences()
    var originalB = Self.samplePreferences()
    originalB.chat = .init(include: "account-B-chat", push: false)
    originalB.like = .init(include: "account-B-like", list: false, push: false)
    service.accountDIDs[ObjectIdentifier(clientA)] = didA
    service.accountDIDs[ObjectIdentifier(clientB)] = didB
    service.snapshots[didA] = originalA
    service.snapshots[didB] = originalB
    defaults.set(false, forKey: "masterPushNotificationsEnabled_\(didA)")
    defaults.set(false, forKey: "masterPushNotificationsEnabled_\(didB)")
    defaults.set(false, forKey: "chatNotificationsEnabled_\(didA)")
    defaults.set(false, forKey: "chatNotificationsEnabled_\(didB)")
    self.didA = didA
    self.didB = didB
    self.suiteName = suiteName
    self.defaults = defaults
    self.service = service
    self.account = account
    self.clientA = clientA
    self.clientB = clientB
    self.originalA = originalA
    self.originalB = originalB
    self.manager = NotificationManager(
      notificationServiceDIDString: "did:web:notification-preferences.invalid",
      notificationDefaults: defaults,
      preferencesService: service.operations,
      accountDIDProvider: { account.did },
      seedsDebugWidgetData: false
    )
  }

  func removeDefaultsSuite() {
    self.defaults.removePersistentDomain(forName: self.suiteName)
  }

  func chatKey(_ did: String) -> String { "chatNotificationsEnabled_\(did)" }
  func masterKey(_ did: String) -> String { "masterPushNotificationsEnabled_\(did)" }

  func defaultsSnapshot() -> [String: String] {
    (self.defaults.persistentDomain(forName: self.suiteName) ?? [:]).mapValues { String(describing: $0) }
  }

  func encodedInput(_ input: AppBskyNotificationPutPreferencesV2.Input) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(input)
  }

  func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    throw NotificationPersistenceError.didNotSuspend
  }

  static func samplePreferences() -> NotificationPreferences {
    NotificationPreferences(serverPreferences: .init(
      chat: .init(include: "custom-service-chat", push: true),
      follow: .init(include: "follows", list: true, push: false),
      like: .init(include: "all", list: false, push: true),
      likeViaRepost: .init(include: "follows", list: true, push: true),
      mention: .init(include: "all", list: true, push: false),
      quote: .init(include: "follows", list: false, push: false),
      reply: .init(include: "all", list: true, push: true),
      repost: .init(include: "follows", list: true, push: false),
      repostViaRepost: .init(include: "all", list: false, push: true),
      starterpackJoined: .init(list: true, push: false),
      subscribedPost: .init(list: true, push: true),
      unverified: .init(list: false, push: false),
      verified: .init(list: false, push: true)
    ))
  }
}

private final class NotificationFixtureAccount {
  var did: String
  init(did: String) { self.did = did }
}

@MainActor
private final class NotificationPreferenceFakeService {
  struct SaveRequest {
    let accountDID: String
    let input: AppBskyNotificationPutPreferencesV2.Input
  }

  var accountDIDs: [ObjectIdentifier: String] = [:]
  var snapshots: [String: NotificationPreferences] = [:]
  var failingFetchAccounts: Set<String> = []
  var failingSaveAccounts: Set<String> = []
  var unconfirmedSaveAccounts: Set<String> = []
  var fetchAccounts: [String] = []
  var saveRequests: [SaveRequest] = []
  var unreadAccounts: [String] = []
  var heldFetch: (String, NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences>)?
  var heldSave: (String, NotificationSuspendedResponse<AppBskyNotificationDefs.Preferences?>)?

  var operations: NotificationPreferencesService {
    .init(
      authenticatedDID: { [self] client in try self.accountDID(for: client) },
      fetch: { [self] client in
        let did = try self.accountDID(for: client)
        self.fetchAccounts.append(did)
        if let (heldDID, response) = self.heldFetch, heldDID == did {
          self.heldFetch = nil
          return try await response.suspend()
        }
        if self.failingFetchAccounts.contains(did) { throw NotificationPersistenceError.fetch }
        guard let snapshot = self.snapshots[did] else { throw NotificationPersistenceError.unknownAccount }
        return snapshot.toServerPreferences()
      },
      save: { [self] client, input in
        let did = try self.accountDID(for: client)
        self.saveRequests.append(.init(accountDID: did, input: input))
        if let (heldDID, response) = self.heldSave, heldDID == did {
          self.heldSave = nil
          let saved = try await response.suspend()
          if let saved { self.snapshots[did] = NotificationPreferences(serverPreferences: saved) }
          return saved
        }
        if self.failingSaveAccounts.contains(did) { throw NotificationPersistenceError.save }
        guard var snapshot = self.snapshots[did] else { throw NotificationPersistenceError.unknownAccount }
        if let value = input.chat { snapshot.chat = value }
        if let value = input.follow { snapshot.follow = value }
        if let value = input.like { snapshot.like = value }
        if let value = input.likeViaRepost { snapshot.likeViaRepost = value }
        if let value = input.mention { snapshot.mention = value }
        if let value = input.quote { snapshot.quote = value }
        if let value = input.reply { snapshot.reply = value }
        if let value = input.repost { snapshot.repost = value }
        if let value = input.repostViaRepost { snapshot.repostViaRepost = value }
        if let value = input.starterpackJoined { snapshot.starterpackJoined = value }
        if let value = input.subscribedPost { snapshot.subscribedPost = value }
        if let value = input.unverified { snapshot.unverified = value }
        if let value = input.verified { snapshot.verified = value }
        self.snapshots[did] = snapshot
        if self.unconfirmedSaveAccounts.contains(did) { return nil }
        return snapshot.toServerPreferences()
      },
      unreadCount: { [self] client in
        self.unreadAccounts.append(try self.accountDID(for: client))
        return 0
      }
    )
  }

  private func accountDID(for client: ATProtoClient) throws -> String {
    guard let did = self.accountDIDs[ObjectIdentifier(client)] else {
      throw NotificationPersistenceError.unknownAccount
    }
    return did
  }
}

@MainActor
private final class NotificationSuspendedResponse<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, any Error>?
  private var resolution: Result<Value, any Error>?
  private(set) var isSuspended = false

  func suspend() async throws -> Value {
    if let resolution { return try resolution.get() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      self.isSuspended = true
    }
  }

  func waitUntilSuspended() async throws {
    for _ in 0..<1_000 {
      if self.isSuspended { return }
      await Task.yield()
    }
    throw NotificationPersistenceError.didNotSuspend
  }

  func resolve(_ result: Result<Value, any Error>) {
    guard self.resolution == nil else { return }
    self.resolution = result
    self.continuation?.resume(with: result)
    self.continuation = nil
  }
}

private enum NotificationPersistenceError: Error, LocalizedError, Equatable {
  case fetch, save, unknownAccount, didNotSuspend

  var errorDescription: String? {
    switch self {
    case .fetch: return "Fixture GET failed"
    case .save: return "Fixture PUT failed"
    case .unknownAccount: return "Unexpected fixture account"
    case .didNotSuspend: return "The fixture operation did not reach its suspension point"
    }
  }
}
