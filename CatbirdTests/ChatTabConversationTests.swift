import Foundation
import Petrel
import Testing
@testable import Catbird

/// ChatTabView's selection, not ConversationView's appearance, keeps a conversation open.
/// A compact split view hosts a programmatically opened detail twice and can end with an
/// onDisappear while the conversation stays on screen.
@Suite("Chat tab conversation")
@MainActor
struct ChatTabConversationTests {
  @Test("A double-hosted detail's last onDisappear keeps the open conversation active")
  func doubleHostedDisappearKeepsConversationActive() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }

    manager.setChatTabConversation("open")
    // The sequence SwiftUI delivers to the one ConversationView identity it hosts twice.
    manager.startMessagePolling(for: "open")
    manager.conversationViewDisappeared("open")
    manager.startMessagePolling(for: "open")
    manager.conversationViewDisappeared("open")

    #expect(manager.activeConversationId == "open")
  }

  @Test("Cancelling the view's load task does not interrupt the open conversation's first load")
  func viewTaskCancellationKeepsFirstLoad() async {
    let pages = MessagePagesStub()
    pages.pauseNextRequest = true
    let manager = await makeManager(pages)
    defer { manager.stopAllPolling() }
    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: "open", currentUserDID: "did:plc:alice"
    )

    manager.setChatTabConversation("open")
    let viewLoad = Task { await source.loadMessages() }
    await pages.waitForPausedRequest()
    // The spurious onDisappear cancels the view's task while the request is in flight.
    viewLoad.cancel()
    pages.resumeRequest()
    await viewLoad.value
    await settle { source.messageLoadState != .loading }

    #expect(source.messageLoadState == .loaded)
    #expect(pages.requestCount == 1)
  }

  @Test("Selecting another conversation or leaving the tab stops the previous one")
  func selectionChangesAndLeavingStopConversations() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }

    manager.setChatTabConversation("first")
    #expect(manager.activeConversationId == "first")

    manager.setChatTabConversation("second")
    #expect(manager.activeConversationId == "second")
    // The first conversation's view disappears after the second was selected.
    manager.conversationViewDisappeared("first")
    #expect(manager.activeConversationId == "second")

    manager.setChatTabConversation(nil)
    #expect(manager.activeConversationId == nil)
    #expect(manager.chatTabConversationId == nil)
  }

  @Test("The view of a conversation the split view moves out does not take over polling")
  func outgoingConversationViewDoesNotTakeOverPolling() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }

    manager.setChatTabConversation("previous")
    manager.setChatTabConversation("selected")
    manager.conversationViewAppeared("selected", isChatTabSelection: true)
    // The previously shown conversation's view appears and disappears once more in the transition.
    manager.conversationViewAppeared("previous", isChatTabSelection: true)
    manager.conversationViewDisappeared("previous")

    #expect(manager.activeConversationId == "selected")
  }

  @Test("A conversation shown outside ChatTabView still stops when its view disappears")
  func conversationOutsideChatTabStopsOnDisappear() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }

    manager.conversationViewAppeared("pushed", isChatTabSelection: false)
    #expect(manager.activeConversationId == "pushed")
    manager.conversationViewDisappeared("pushed")
    #expect(manager.activeConversationId == nil)
  }

  // MARK: - Destinations pushed over the selected conversation

  @Test("The tab publishes its selection only while that Bluesky conversation is on screen")
  func shownConversationIsTheVisibleBlueskySelection() {
    func shown(_ selection: String?, visible: Bool = true, pushed: Bool = false) -> String? {
      ChatTabView.shownConversation(
        selection: selection, isTabVisible: visible, hasPushedDestination: pushed, isMLS: { $0 == "mls" }
      )
    }

    #expect(shown("open") == "open")
    #expect(shown("open", visible: false) == nil)
    #expect(shown("open", pushed: true) == nil)
    #expect(shown("mls") == nil)
    #expect(shown(nil) == nil)
  }

  /// `tabUpdate` is where ChatTabView's publish falls among the view's onAppear and
  /// onDisappear, since SwiftUI does not order them.
  @Test(
    "A destination pushed over the selected conversation makes it inactive until it is popped",
    arguments: [0, 1]
  )
  func pushedDestinationDeactivatesSelectedConversation(tabUpdate: Int) async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    publish("open", pushed: false, to: manager)
    manager.conversationViewAppeared("open", isChatTabSelection: true)
    #expect(manager.activeConversationId == "open")

    // A profile is pushed over the conversation.
    run({ publish("open", pushed: true, to: manager) }, at: tabUpdate, among: [
      { manager.conversationViewDisappeared("open") }
    ])
    #expect(manager.activeConversationId == nil)
    #expect(manager.chatTabConversationId == nil)

    // The profile is popped.
    run({ publish("open", pushed: false, to: manager) }, at: tabUpdate, among: [
      { manager.conversationViewAppeared("open", isChatTabSelection: true) }
    ])
    #expect(manager.activeConversationId == "open")
  }

  @Test(
    "Another conversation pushed over the selected one is active while shown",
    arguments: [0, 1, 2]
  )
  func pushedConversationIsActiveWhileShown(tabUpdate: Int) async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    publish("selected", pushed: false, to: manager)
    manager.conversationViewAppeared("selected", isChatTabSelection: true)

    run({ publish("selected", pushed: true, to: manager) }, at: tabUpdate, among: [
      { manager.conversationViewAppeared("pushed", isChatTabSelection: false) },
      { manager.conversationViewDisappeared("selected") },
    ])
    #expect(manager.activeConversationId == "pushed")

    run({ publish("selected", pushed: false, to: manager) }, at: tabUpdate, among: [
      { manager.conversationViewDisappeared("pushed") },
      { manager.conversationViewAppeared("selected", isChatTabSelection: true) },
    ])
    #expect(manager.activeConversationId == "selected")
  }

  /// Publishes what ChatTabView publishes for `selection` while its tab is visible.
  private func publish(_ selection: String, pushed: Bool, to manager: ChatManager) {
    manager.setChatTabConversation(
      ChatTabView.shownConversation(
        selection: selection, isTabVisible: true, hasPushedDestination: pushed, isMLS: { _ in false }
      )
    )
  }

  /// Runs `viewEvents` in order with `tabUpdate` inserted at `position`.
  private func run(_ tabUpdate: () -> Void, at position: Int, among viewEvents: [() -> Void]) {
    for (index, event) in viewEvents.enumerated() {
      if index == position { tabUpdate() }
      event()
    }
    if position >= viewEvents.count { tabUpdate() }
  }

  private func makeManager(_ pages: MessagePagesStub) async -> ChatManager {
    let client = await ATProtoClient(baseURL: URL(string: "https://chat-tab.invalid")!)
    return ChatManager(client: client, messagePageLoader: { _, _ in try await pages.load() })
  }

  private func settle(_ condition: () -> Bool) async {
    // Observation and the manager's own task run on the main actor; bound settling rather than sleeping.
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !condition(), ContinuousClock.now < deadline {
      await Task.yield()
    }
  }
}

/// Answers every message page with an empty successful response, optionally pausing one.
@MainActor
private final class MessagePagesStub {
  private(set) var requestCount = 0
  var pauseNextRequest = false
  private var pausedRequest: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?

  func load() async throws -> (Int, ChatBskyConvoGetMessages.Output?) {
    requestCount += 1
    if pauseNextRequest {
      pauseNextRequest = false
      await withCheckedContinuation { continuation in
        pausedRequest = continuation
        startWaiter?.resume()
        startWaiter = nil
      }
    }
    return (200, .init(messages: []))
  }

  func waitForPausedRequest() async {
    if pausedRequest != nil { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func resumeRequest() {
    pausedRequest?.resume()
    pausedRequest = nil
  }
}
