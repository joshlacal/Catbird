@testable import Catbird
import Foundation
import Petrel
import Testing

struct AccountPollingBarrierTests {
  @Test("A delayed response is invalidated before account-switch draining finishes")
  func delayedResponseCannotPublish() async throws {
    let barrier = AccountPollingBarrier()
    let request = try #require(barrier.begin(accountDID: "did:plc:original"))
    barrier.suspend(accountDID: "did:plc:original")
    let generation = try #require(barrier.suspensionGeneration)
    #expect(!barrier.isCurrent(request, accountDID: "did:plc:original"))
    #expect(barrier.begin(accountDID: "did:plc:target") == nil)
    #expect(!barrier.resume(accountDID: "did:plc:original", generation: generation))

    let drain = Task { await barrier.drain() }
    // Model a cancellation-insensitive network completion. Drain owns its full lifetime.
    barrier.finish(request)
    await drain.value
    #expect(!barrier.resume(accountDID: "did:plc:target", generation: generation))
    #expect(barrier.isSuspended)
    #expect(barrier.resume(accountDID: "did:plc:original", generation: generation))
    #expect(!barrier.isCurrent(request, accountDID: "did:plc:original"))
    let resumed = try #require(barrier.begin(accountDID: "did:plc:original"))
    #expect(barrier.isCurrent(resumed, accountDID: "did:plc:original"))
    barrier.finish(resumed)
  }

  @Test("A replaced lifecycle rejects an old request even for the same DID")
  func replacementInvalidatesSameAccount() throws {
    let barrier = AccountPollingBarrier()
    let old = try #require(barrier.begin(accountDID: "did:plc:original"))
    barrier.invalidate()
    let current = try #require(barrier.begin(accountDID: "did:plc:original"))
    #expect(!barrier.isCurrent(old, accountDID: "did:plc:original"))
    #expect(barrier.isCurrent(current, accountDID: "did:plc:original"))
    #expect(!barrier.isCurrent(current, accountDID: "did:plc:other"))
    barrier.finish(old)
    barrier.finish(current)
  }

  @Test("An earlier resume proof cannot reopen a later suspension of the same account")
  func supersededResumeProof() throws {
    let barrier = AccountPollingBarrier()
    barrier.suspend(accountDID: "did:plc:original")
    let earlier = try #require(barrier.suspensionGeneration)
    #expect(barrier.resume(accountDID: "did:plc:original", generation: earlier))
    barrier.suspend(accountDID: "did:plc:original")
    #expect(!barrier.resume(accountDID: "did:plc:original", generation: earlier))
    #expect(barrier.isSuspended)
    let current = try #require(barrier.suspensionGeneration)
    #expect(barrier.resume(accountDID: "did:plc:original", generation: current))
  }

  @Test("All overlapping caller-owned requests must finish before resume")
  func overlappingRequestsAndRepeatedSuspension() async throws {
    let barrier = AccountPollingBarrier()
    let first = try #require(barrier.begin(accountDID: "did:plc:original"))
    let second = try #require(barrier.begin(accountDID: "did:plc:original"))
    barrier.suspend(accountDID: "did:plc:original")
    let generation = try #require(barrier.suspensionGeneration)
    barrier.suspend(accountDID: "did:plc:other")
    async let firstWait: Void = barrier.drain()
    async let secondWait: Void = barrier.drain()
    barrier.finish(first)
    #expect(!barrier.resume(accountDID: "did:plc:original", generation: generation))
    barrier.finish(second)
    _ = await (firstWait, secondWait)
    #expect(!barrier.resume(accountDID: "did:plc:other", generation: generation))
    #expect(barrier.resume(accountDID: "did:plc:original", generation: generation))
  }
}

@MainActor
struct AccountPollingManagerTests {
  @Test("Suspension preserves the visible chat and rejects poller restarts and loads")
  func chatSuspensionPreservesState() async {
    let manager = ChatManager()
    manager.startMessagePolling(for: "visible-conversation")
    manager.conversations = [.init(id: "visible-conversation", rev: "original", members: [], muted: false, unreadCount: 3)]
    manager.conversationsCursor = "original-cursor"
    manager.errorState = .noClient
    await manager.suspendForAccountSwitch()
    manager.startMessagePolling(for: "other-conversation")
    manager.startConversationsPolling()
    await manager.updateClient(nil)
    await manager.handleStateInvalidation(.accountSwitched)
    await manager.loadConversations(refresh: true)
    await manager.loadMessages(convoId: "visible-conversation", refresh: true)
    #expect(manager.activeConversationId == "visible-conversation")
    #expect(manager.conversations.map(\.id) == ["visible-conversation"])
    #expect(manager.conversationsCursor == "original-cursor")
    #expect(manager.totalUnreadCount == 3)
    #expect(manager.errorState == .noClient)
    #expect(!manager.loadingConversations)
    #expect(manager.loadingMessages["visible-conversation"] != true)
    #expect(await manager.resumeAfterInterruptedAccountSwitch(accountDID: "did:plc:other") == false)
    manager.stopMessagePolling(for: "visible-conversation")
    #expect(manager.activeConversationId == nil)
  }

  @Test("Suspended notification checking preserves its existing delivery state")
  func notificationSuspensionPreservesState() async {
    let manager = NotificationManager()
    var originalPreferences = NotificationPreferences()
    originalPreferences.chat = .init(include: "all", push: false)
    manager.applyNotificationPreferencesSnapshot(originalPreferences.toServerPreferences())
    let originalStatus = manager.status
    let originalCount = manager.unreadCount
    await manager.suspendForAccountSwitch()
    manager.startUnreadNotificationChecking()
    await manager.updateClient(nil)
    await manager.checkUnreadNotifications()
    #expect(manager.status == originalStatus)
    #expect(manager.unreadCount == originalCount)
    #expect(manager.preferences.chat.push == false)
    #expect(manager.chatNotificationsEnabled == false)
    #expect(await manager.resumeAfterInterruptedAccountSwitch(accountDID: "did:plc:other") == false)
  }
}
