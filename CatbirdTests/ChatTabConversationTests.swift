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

  @Test("Optimistic DM send clears draft immediately on tap and preserves diffableID across server confirmation")
  func optimisticSendClearsDraftImmediatelyAndPreservesDiffableIDOnHandover() async throws {
    let pages = MessagePagesStub()
    let manager = await makeManager(pages)
    defer { manager.stopAllPolling() }

    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: "open", currentUserDID: "did:plc:alice"
    )

    let initialTrigger = source.scrollToBottomTrigger
    let pendingID = source.beginPendingSend(text: "Hello instantly!")

    #expect(source.scrollToBottomTrigger == initialTrigger + 1)
    #expect(source.messages.count == 1)

    let pendingMsg = try #require(source.messages.first)
    #expect(pendingMsg.id == pendingID)
    #expect(pendingMsg.diffableID == pendingID)
    #expect(pendingMsg.text == "Hello instantly!")
    #expect(pendingMsg.isFromCurrentUser == true)
    #expect(pendingMsg.sendState == .sending)
    #expect(source.message(for: pendingID)?.text == "Hello instantly!")

    // Simulate server confirmation arriving with real message ID
    let realID = "3lserverconfirmed123"
    let confirmedView = ChatBskyConvoDefs.MessageView(
      id: realID,
      rev: "rev1",
      text: "Hello instantly!",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:alice")),
      sentAt: ATProtocolDate(date: pendingMsg.sentAt)
    )

    source.completePendingSend(id: pendingID, realMessageID: realID)
    pages.messages = [.chatBskyConvoDefsMessageView(confirmedView)]
    await source.loadMessages()
    await settle { source.messages.first?.sendState == .sent }

    #expect(source.messages.count == 1)
    let confirmedAdapter = try #require(source.messages.first)
    #expect(confirmedAdapter.id == realID)
    #expect(confirmedAdapter.diffableID == pendingID)
    #expect(confirmedAdapter.sendState == .sent)
    #expect(source.message(for: pendingID)?.id == realID)
    #expect(source.message(for: realID)?.diffableID == pendingID)
  }

  // MARK: - Optimistic send queue

  @Test("Quick consecutive sends reach the server one at a time, in the order they were sent")
  func optimisticSendsReachTheServerInOrder() async {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    let server = MessageSendStub()
    let source = makeSource(manager, server)
    let mention = "hey @alice.bsky.social look at this"
    // The mention's handle lookup keeps its send busy before the POST.
    server.held = [mention]

    source.draftText = mention
    source.submitDraft()
    await settle { server.isHolding(mention) }
    source.draftText = "lol"
    source.submitDraft()
    #expect(source.draftText.isEmpty)
    // Give the second send every chance to start while the first is still busy.
    await settle { server.inFlight > 1 }
    #expect(server.inFlight == 1)
    #expect(server.sent.isEmpty)
    #expect(source.messages.map(\.text) == [mention, "lol"])

    server.release(mention)
    await settle { server.sent.count == 2 }
    #expect(server.sent.map(\.text) == [mention, "lol"])
    #expect(server.maxInFlight == 1)
    #expect(source.pendingSends.isEmpty)
  }

  @Test("A failed send does not hold back later sends, and Retry sends it again at the back once")
  func failedSendDoesNotWedgeTheQueue() async throws {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    let server = MessageSendStub()
    let source = makeSource(manager, server)
    server.failing = ["first"]

    source.draftText = "first"
    source.submitDraft()
    source.draftText = "second"
    source.submitDraft()
    await settle { server.sent.count == 2 && source.pendingSends.first?.sendState != .sending }

    #expect(server.sent.map(\.text) == ["first", "second"])
    let failed = try #require(source.pendingSends.first)
    #expect(source.pendingSends.count == 1)
    #expect(failed.text == "first")
    #expect(failed.sendState == .failed("Failed to send"))
    #expect(source.message(for: failed.id)?.sendState == .failed("Failed to send"))

    // Two taps on Retry before the row re-renders send the message once.
    server.failing = []
    async let firstTap: Void = source.retryFailedSend(pendingID: failed.id)
    async let secondTap: Void = source.retryFailedSend(pendingID: failed.id)
    _ = await (firstTap, secondTap)
    #expect(server.sent.map(\.text) == ["first", "second", "first"])
    #expect(source.pendingSends.isEmpty)
  }

  @Test("A send still in flight stays below confirmed messages whatever the device clock says")
  func inFlightSendStaysAtTheBottom() async throws {
    let pages = MessagePagesStub()
    let manager = await makeManager(pages)
    defer { manager.stopAllPolling() }
    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: "open", currentUserDID: "did:plc:alice"
    )
    // The device clock runs behind the server's.
    let pendingID = source.beginPendingSend(text: "still sending", sentAt: Date(timeIntervalSince1970: 1_000))
    pages.messages = [.chatBskyConvoDefsMessageView(
      try messageView(id: "3lpeer", text: "from bob", senderDID: "did:plc:bob", sentAt: Date(timeIntervalSince1970: 2_000))
    )]
    await source.loadMessages()
    await settle { source.messages.count == 2 }

    #expect(source.messages.map(\.id) == ["3lpeer", pendingID])

    // A failed send is no longer on its way and keeps the place of the time it was sent.
    source.failPendingSend(id: pendingID)
    #expect(source.messages.map(\.id) == [pendingID, "3lpeer"])
  }

  // MARK: - Actions on rows the server has not confirmed

  @Test("A pending or failed row takes no replies or reactions, and only a failed one can be deleted")
  func unconfirmedRowsOfferNoServerActions() async throws {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: "open", currentUserDID: "did:plc:alice"
    )
    let callbacks = ChatMessageMenuCallbacks(canReply: true, canDelete: true, canReport: true)

    let pendingID = source.beginPendingSend(text: "on its way")
    let sending = try #require(source.message(for: pendingID))
    #expect(!sending.canReply)
    #expect(!sending.canReact)
    #expect(!sending.canDeleteForMe)
    #expect(ChatMessageMenuActions.available(for: sending, callbacks: callbacks, quickReactions: ["👍"]) == [.copy])

    source.failPendingSend(id: pendingID)
    let failed = try #require(source.message(for: pendingID))
    #expect(!failed.canReply)
    #expect(!failed.canReact)
    #expect(failed.canDeleteForMe)
    #expect(ChatMessageMenuActions.available(for: failed, callbacks: callbacks, quickReactions: ["👍"])
      == [.copy, .deleteForMe])

    // Once confirmed, the row keeps its pending item identity but names the server's message.
    let confirmed = BlueskyMessageAdapter(
      messageView: try messageView(id: "3lconfirmed", text: "on its way", senderDID: "did:plc:alice", sentAt: Date()),
      currentUserDID: "did:plc:alice",
      diffableID: pendingID
    )
    #expect(confirmed.canReply)
    #expect(confirmed.canReact)
    #expect(confirmed.canDeleteForMe)
    #expect(ChatMessageMenuActions.available(for: confirmed, callbacks: callbacks, quickReactions: ["👍"])
      == [.reaction("👍"), .moreReactions, .reply, .copy, .deleteForMe])
  }

  @Test("Deleting a row whose send is on its way leaves the send to land; a failed row is discarded for good")
  func deletingUnconfirmedRows() async throws {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    let server = MessageSendStub()
    let source = makeSource(manager, server)
    server.held = ["in flight"]

    source.draftText = "in flight"
    source.submitDraft()
    await settle { server.isHolding("in flight") }
    let inFlightID = try #require(source.pendingSends.first?.id)
    await source.deleteMessage(messageID: inFlightID)
    #expect(source.message(for: inFlightID)?.sendState == .sending)
    server.release("in flight")
    await settle { source.pendingSends.isEmpty }
    #expect(server.sent.map(\.text) == ["in flight"])
    #expect(source.error == nil)

    server.failing = ["lost"]
    source.draftText = "lost"
    source.submitDraft()
    await settle { source.pendingSends.first?.sendState == .failed("Failed to send") }
    let failedID = try #require(source.pendingSends.first?.id)
    await source.deleteMessage(messageID: failedID)
    #expect(source.pendingSends.isEmpty)
    #expect(source.message(for: failedID) == nil)
    await source.retryFailedSend(pendingID: failedID)
    #expect(server.sent.map(\.text) == ["in flight", "lost"])
  }

  @Test("A reply to a local send names its server ID, on Retry too, and never a pending ID")
  func replyToLocalSendNamesTheServerID() async throws {
    let manager = await makeManager(MessagePagesStub())
    defer { manager.stopAllPolling() }
    let server = MessageSendStub()
    let source = makeSource(manager, server)

    source.draftText = "original"
    source.submitDraft()
    let originalID = try #require(source.pendingSends.first?.id)
    await settle { source.pendingSends.isEmpty }
    let repliedToConfirmed = await source.sendMessage(
      text: "reply", embed: nil, replyTo: ChatBskyConvoDefs.ReplyRef(messageId: originalID)
    )
    #expect(repliedToConfirmed)
    #expect(server.sent.last == MessageSendStub.Sent(text: "reply", replyTo: "3lserver1"))

    // The target has not been confirmed: the reply goes out without it rather than failing for good.
    let unconfirmedID = source.beginPendingSend(text: "not sent yet")
    server.failing = ["reply to unconfirmed"]
    let repliedToUnconfirmed = await source.sendMessage(
      text: "reply to unconfirmed", embed: nil, replyTo: ChatBskyConvoDefs.ReplyRef(messageId: unconfirmedID)
    )
    #expect(!repliedToUnconfirmed)
    #expect(server.sent.last == MessageSendStub.Sent(text: "reply to unconfirmed", replyTo: nil))

    // Retry names the target's server ID once it has one.
    source.completePendingSend(id: unconfirmedID, realMessageID: "3ltarget")
    server.failing = []
    let failedReply = try #require(source.pendingSends.first { $0.text == "reply to unconfirmed" })
    await source.retryFailedSend(pendingID: failedReply.id)
    #expect(server.sent.last == MessageSendStub.Sent(text: "reply to unconfirmed", replyTo: "3ltarget"))
    #expect(server.sent.allSatisfy { $0.replyTo?.hasPrefix(BlueskyConversationDataSource.pendingIDPrefix) != true })
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

  private func makeSource(_ manager: ChatManager, _ server: MessageSendStub) -> BlueskyConversationDataSource {
    BlueskyConversationDataSource(
      chatManager: manager, convoID: "open", currentUserDID: "did:plc:alice",
      messageSender: { _, text, _, replyTo, confirm in
        await server.send(text: text, replyTo: replyTo, confirm: confirm)
      }
    )
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
  var messages: [ChatBskyConvoGetMessages.OutputMessagesUnion] = []
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
    return (200, .init(messages: messages))
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

/// Stands in for ChatManager.sendMessage. A send records its POST once any hold is
/// released, then confirms with a server ID unless its text is listed as failing.
@MainActor
private final class MessageSendStub {
  struct Sent: Equatable {
    let text: String
    let replyTo: String?
  }

  private(set) var sent: [Sent] = []
  private(set) var inFlight = 0
  private(set) var maxInFlight = 0
  /// Texts whose send fails instead of being confirmed.
  var failing: Set<String> = []
  /// Texts whose send waits for `release(_:)` before its POST.
  var held: Set<String> = []
  private var holds: [String: CheckedContinuation<Void, Never>] = [:]

  func send(
    text: String,
    replyTo: ChatBskyConvoDefs.ReplyRef?,
    confirm: (ChatBskyConvoDefs.MessageView) -> Void
  ) async -> Bool {
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    defer { inFlight -= 1 }
    if held.contains(text) {
      await withCheckedContinuation { holds[text] = $0 }
    }
    sent.append(Sent(text: text, replyTo: replyTo?.messageId))
    guard !failing.contains(text) else { return false }
    // swiftlint:disable:next force_try
    confirm(try! messageView(id: "3lserver\(sent.count)", text: text, senderDID: "did:plc:alice", sentAt: Date()))
    return true
  }

  func isHolding(_ text: String) -> Bool { holds[text] != nil }

  func release(_ text: String) {
    held.remove(text)
    holds.removeValue(forKey: text)?.resume()
  }
}

private func messageView(id: String, text: String, senderDID: String, sentAt: Date) throws -> ChatBskyConvoDefs.MessageView {
  ChatBskyConvoDefs.MessageView(
    id: id,
    rev: "rev-\(id)",
    text: text,
    facets: nil,
    embed: nil,
    reactions: nil,
    replyTo: nil,
    sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: senderDID)),
    sentAt: ATProtocolDate(date: sentAt)
  )
}
