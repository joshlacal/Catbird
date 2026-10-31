import Foundation
import Testing
@testable import NotificationHarness

@Suite(.serialized)
@MainActor
struct NotificationPreferenceTests {
  private let alice = "did:plc:notification-harness-alice"
  private let bob = "did:plc:notification-harness-bob"

  private struct Fixture {
    let state: AppState
    let defaults: NotificationHarness.UserDefaults
    let api: FakeNotificationAPI
    let client: ATProtoClient
    let manager: NotificationManager
  }

  private final class WeakManagerBox {
    weak var value: NotificationManager?
    init(_ value: NotificationManager) { self.value = value }
  }

  private func fixture(chat: Bool = true) async -> Fixture {
    let state = AppState(userDID: alice)
    let defaults = NotificationHarness.UserDefaults()
    let api = FakeNotificationAPI()
    api.defaultPreferences.chat.push = chat
    let client = ATProtoClient(did: alice, api: api)
    let manager = NotificationManager(testAppState: state, testDefaults: defaults)
    await manager.updateClient(client)
    return Fixture(state: state, defaults: defaults, api: api, client: client, manager: manager)
  }

  private func serverPreferences(chat: Bool) -> AppBskyNotificationDefs.Preferences {
    var preferences = NotificationPreferences()
    preferences.chat.push = chat
    return preferences.toServerPreferences()
  }

  private func expectMirrors(
    _ manager: NotificationManager,
    defaults: NotificationHarness.UserDefaults,
    did: String,
    chat: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(manager.preferences.chat.push == chat, sourceLocation: sourceLocation)
    #expect(manager.chatNotificationsEnabled == chat, sourceLocation: sourceLocation)
    #expect(defaults.object(forKey: "chatNotificationsEnabled_\(did)") != nil, sourceLocation: sourceLocation)
    #expect(defaults.bool(forKey: "chatNotificationsEnabled_\(did)") == chat, sourceLocation: sourceLocation)
  }

  @Test
  func persistedMasterDisabledWithCachedTokenNeverRegistersPush() async {
    let state = AppState(userDID: alice)
    let defaults = NotificationHarness.UserDefaults()
    defaults.set(false, forKey: "masterPushNotificationsEnabled_\(alice)")
    let api = FakeNotificationAPI()
    let client = ATProtoClient(did: alice, api: api)
    let token = Data([0xCA, 0x7B, 0x1D])
    let manager = NotificationManager(testAppState: state, testDefaults: defaults, testToken: token)

    await manager.updateClient(client)
    await manager.testAttemptTokenRegistration(token)

    #expect(api.registerInputs.isEmpty)
    #expect(!manager.notificationsEnabled)
    #expect(manager.status == .disabled)
    #expect(!defaults.bool(forKey: "masterPushNotificationsEnabled_\(alice)"))
  }

  @Test
  func refreshSynchronizesChatMirrorAndDefaultsWithoutPutLoop() async {
    let f = await fixture()
    f.api.defaultPreferences.chat.push = false

    await f.manager.refreshNotificationPreferences()
    await f.manager.testWaitForMutation()

    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)
    #expect(f.manager.testServerSnapshot()?.chat.push == false)
    #expect(f.api.putInputs.isEmpty)
  }

  @Test
  func failedPutRestoresPreferencesChatMirrorAndDefaults() async throws {
    let f = await fixture()
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    // A failed refresh cannot hide whether rollback itself restored all mirrors.
    f.api.getHandler = { (503, nil) }
    let mutation = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await gate.waitForEntry()
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)

    gate.fail()
    let result = await mutation.result
    if case .success = result { Issue.record("A failed PUT must be reported to its caller") }

    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
    #expect(f.manager.testServerSnapshot()?.chat.push == true)
    #expect(f.api.putInputs.count == 1)
  }

  @Test
  func failedQueuedPutRollsBackToImmediatelyPriorAcceptedPut() async throws {
    let f = await fixture()
    let firstGate = ResponseGate<PutReply>()
    let secondGate = ResponseGate<PutReply>()
    f.api.getHandler = { (503, nil) }
    f.api.putHandler = { _ in
      if f.api.putInputs.count == 1 { return try await firstGate.response() }
      return try await secondGate.response()
    }
    var first = f.manager.preferences
    first.chat.push = false
    first.like.push = false
    let firstMutation = Task { try await f.manager.updatePreferences(first) }
    try await firstGate.waitForEntry()
    let firstGeneration = f.manager.testMutationGeneration()

    var second = first
    second.chat.push = true
    second.follow.push = false
    let secondMutation = Task { try await f.manager.updatePreferences(second) }
    try await eventually { f.manager.testMutationGeneration() != firstGeneration }
    #expect(f.api.putInputs.count == 1, "Queued PUT must wait for the earlier request")

    firstGate.succeed((200, .init(preferences: first.toServerPreferences())))
    _ = try await firstMutation.value
    try await secondGate.waitForEntry()
    secondGate.fail()
    let result = await secondMutation.result
    if case .success = result { Issue.record("The second failed PUT must be reported") }

    #expect(f.manager.preferences == first)
    #expect(f.manager.testServerSnapshot() == first.toServerPreferences())
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)
  }

  @Test
  func getResponseFromPreviousAccountCannotChangeNewAccount() async throws {
    let f = await fixture()
    let gate = ResponseGate<GetReply>()
    f.api.getHandler = { try await gate.response() }
    let oldRead = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    try await gate.waitForEntry()

    let newAPI = FakeNotificationAPI()
    let newClient = ATProtoClient(did: bob, api: newAPI)
    f.state.userDID = bob
    await f.manager.updateClient(newClient)
    gate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    let oldResult = await oldRead.value

    #expect(oldResult == nil)
    expectMirrors(f.manager, defaults: f.defaults, did: bob, chat: true)
    #expect(f.defaults.bool(forKey: "chatNotificationsEnabled_\(alice)"))
    #expect(newAPI.putInputs.isEmpty)
  }

  @Test
  func putResponseFromPreviousAccountCannotChangeNewAccount() async throws {
    let f = await fixture()
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    let oldWrite = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await gate.waitForEntry()

    let newAPI = FakeNotificationAPI()
    let newClient = ATProtoClient(did: bob, api: newAPI)
    f.state.userDID = bob
    await f.manager.updateClient(newClient)
    gate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    let oldResult = await oldWrite.result

    if case .success = oldResult { Issue.record("An account-switched PUT must be cancelled") }
    expectMirrors(f.manager, defaults: f.defaults, did: bob, chat: true)
    #expect(f.manager.testServerSnapshot()?.chat.push == true)
    #expect(newAPI.putInputs.isEmpty)
    #expect(newAPI.getCount == 1, "The old mutation must not schedule a refresh on the new account")
  }

  @Test
  func queuedChatEditCannotCrossAccounts() async throws {
    let state = AppState(userDID: alice)
    let defaults = NotificationHarness.UserDefaults()
    let oldAPI = FakeNotificationAPI()
    let oldClient = ATProtoClient(did: alice, api: oldAPI)
    var manager: NotificationManager? = NotificationManager(testAppState: state, testDefaults: defaults)
    let weakManager = WeakManagerBox(manager!)
    await manager!.updateClient(oldClient)
    manager!.testSetCachedServerSnapshot(nil)
    let gate = ResponseGate<GetReply>()
    oldAPI.getHandler = { try await gate.response() }

    // Invoke the exact production didSet/save task. Its initial GET is held
    // across the account change so the queued edit must reject its old context.
    manager!.chatNotificationsEnabled = false
    try await gate.waitForEntry()
    let newAPI = FakeNotificationAPI()
    let newClient = ATProtoClient(did: bob, api: newAPI)
    state.userDID = bob
    await manager!.updateClient(newClient)
    gate.succeed((200, .init(preferences: serverPreferences(chat: true))))
    manager = nil
    // The in-flight production task owns the manager until it returns. This
    // provides completion evidence without substituting its scheduling logic.
    try await eventually { weakManager.value == nil }

    #expect(oldAPI.putInputs.isEmpty)
    #expect(newAPI.putInputs.isEmpty)
    #expect(defaults.bool(forKey: "chatNotificationsEnabled_\(bob)"))
    #expect(!defaults.bool(forKey: "chatNotificationsEnabled_\(alice)"))
  }

  @Test
  func delayedGetCannotOverwriteOptimisticPut() async throws {
    let f = await fixture()
    let getGate = ResponseGate<GetReply>()
    let putGate = ResponseGate<PutReply>()
    f.api.getHandler = { try await getGate.response() }
    f.api.putHandler = { _ in try await putGate.response() }
    let read = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    try await getGate.waitForEntry()
    let write = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await putGate.waitForEntry()

    getGate.succeed((200, .init(preferences: serverPreferences(chat: true))))
    let readResult = await read.value
    #expect(readResult == nil)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)

    putGate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    _ = try await write.value
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)
  }

  @Test
  func getInvokedDuringPendingPutNeverDispatches() async throws {
    let f = await fixture()
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    let write = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await gate.waitForEntry()
    let readsBefore = f.api.getCount

    let result = await f.manager.fetchNotificationPreferences(using: f.client)

    #expect(result == nil)
    #expect(f.api.getCount == readsBefore)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)
    gate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    _ = try await write.value
  }

  @Test
  func cancellationBeforeGetStartsPreventsDispatch() async {
    let f = await fixture()
    let before = f.api.getCount
    let read = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    read.cancel()
    let result = await read.value
    #expect(result == nil)
    #expect(f.api.getCount == before)
  }

  @Test
  func cancellationDuringGetIdentityLookupPreventsDispatch() async throws {
    let f = await fixture()
    let before = f.api.getCount
    let gate = ResponseGate<String>()
    f.client.getDidHandler = { try await gate.response() }
    let read = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    try await gate.waitForEntry()
    read.cancel()
    gate.succeed(alice)
    let result = await read.value
    #expect(result == nil)
    #expect(f.api.getCount == before)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
  }

  @Test
  func accountSwitchDuringGetIdentityLookupPreventsOldDispatch() async throws {
    let f = await fixture()
    let before = f.api.getCount
    let gate = ResponseGate<String>()
    f.client.getDidHandler = { try await gate.response() }
    let read = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    try await gate.waitForEntry()
    let newAPI = FakeNotificationAPI()
    let newClient = ATProtoClient(did: bob, api: newAPI)
    f.state.userDID = bob
    await f.manager.updateClient(newClient)
    gate.succeed(alice)
    let result = await read.value
    #expect(result == nil)
    #expect(f.api.getCount == before)
    expectMirrors(f.manager, defaults: f.defaults, did: bob, chat: true)
  }

  @Test
  func cancelledGetCannotApplySuccessfulLateResponse() async throws {
    let f = await fixture()
    let gate = ResponseGate<GetReply>()
    f.api.getHandler = { try await gate.response() }
    let read = Task { await f.manager.fetchNotificationPreferences(using: f.client) }
    try await gate.waitForEntry()
    read.cancel()
    gate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    let result = await read.value
    #expect(result == nil)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
  }

  @Test
  func cancellationBeforePutStartsPreventsDispatch() async {
    let f = await fixture()
    let write = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    write.cancel()
    let result = await write.result
    if case .success = result { Issue.record("Pre-cancelled PUT must fail") }
    #expect(f.api.putInputs.isEmpty)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
  }

  @Test
  func cancellationDuringPutIdentityLookupPreventsDispatch() async throws {
    let f = await fixture()
    let gate = ResponseGate<String>()
    f.client.getDidHandler = { try await gate.response() }
    let write = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await gate.waitForEntry()
    write.cancel()
    gate.succeed(alice)
    let result = await write.result
    if case .success = result { Issue.record("PUT cancelled during identity lookup must fail") }
    #expect(f.api.putInputs.isEmpty)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
  }

  @Test
  func cancelledPutCannotApplySuccessfulLateResponse() async throws {
    let f = await fixture()
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    let write = Task { try await f.manager.updatePreferences { $0.chat.push = false } }
    try await gate.waitForEntry()
    write.cancel()
    gate.succeed((200, .init(preferences: serverPreferences(chat: false))))
    let result = await write.result
    if case .success = result { Issue.record("Cancelled PUT must not accept late success") }
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: true)
    #expect(f.manager.testServerSnapshot()?.chat.push == true)
  }

  @Test
  func cancelledQueuedPutNeverDispatchesAfterEarlierPutCompletes() async throws {
    let f = await fixture()
    let gate = ResponseGate<PutReply>()
    f.api.putHandler = { _ in try await gate.response() }
    var first = f.manager.preferences
    first.chat.push = false
    let firstWrite = Task { try await f.manager.updatePreferences(first) }
    try await gate.waitForEntry()
    let firstGeneration = f.manager.testMutationGeneration()
    let queued = Task { try await f.manager.updatePreferences { $0.chat.push = true } }
    try await eventually { f.manager.testMutationGeneration() != firstGeneration }
    queued.cancel()
    gate.succeed((200, .init(preferences: first.toServerPreferences())))
    _ = try await firstWrite.value
    let queuedResult = await queued.result
    if case .success = queuedResult { Issue.record("Cancelled queued PUT must fail") }
    #expect(f.api.putInputs.count == 1)
    expectMirrors(f.manager, defaults: f.defaults, did: alice, chat: false)
  }

  @Test
  func disablingDuringRegistrationUnregistersLateSuccess() async throws {
    let state = AppState(userDID: alice)
    let defaults = NotificationHarness.UserDefaults()
    let api = FakeNotificationAPI()
    let client = ATProtoClient(did: alice, api: api)
    let token = Data([0xCA, 0x7B, 0x1D])
    let manager = NotificationManager(testAppState: state, testDefaults: defaults, testToken: token)
    let gate = ResponseGate<Int>()
    api.registerHandler = { try await gate.response() }
    let registration = Task { await manager.updateClient(client) }
    try await gate.waitForEntry()

    await manager.disableNotifications()
    #expect(api.unregisterInputs.count == 1)
    gate.succeed(200)
    await registration.value

    #expect(api.registerInputs.count == 1)
    #expect(api.unregisterInputs.count == 2, "Late successful registration needs a compensating unregister")
    #expect(api.unregisterInputs.allSatisfy { $0.token == "ca7b1d" })
    #expect(!manager.notificationsEnabled)
    #expect(manager.status == .disabled)
    #expect(!defaults.bool(forKey: "masterPushNotificationsEnabled_\(alice)"))
  }
}
