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
    manager.conversationViewAppeared("selected")
    // The previously shown conversation's view appears and disappears once more in the transition.
    manager.conversationViewAppeared("previous")
    manager.conversationViewDisappeared("previous")

    #expect(manager.activeConversationId == "selected")
  }

  @Test("A conversation shown outside ChatTabView still stops when its view disappears")
  func conversationOutsideChatTabStopsOnDisappear() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }

    manager.conversationViewAppeared("pushed")
    #expect(manager.activeConversationId == "pushed")
    manager.conversationViewDisappeared("pushed")
    #expect(manager.activeConversationId == nil)
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
