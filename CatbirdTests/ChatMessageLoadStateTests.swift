import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Conversation message load states")
@MainActor
struct ChatMessageLoadStateTests {
  private let conversationID = "load-state-conversation"

  @Test("Only a successful empty response completes an empty transcript")
  func successfulEmptyResponse() async throws {
    let pages = MessagePageStub([.response(200, .init(messages: []))])
    let (manager, source) = await makeSource(pages)
    #expect(source.messageLoadState == .idle)

    await source.loadMessages()

    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.isEmpty)
    #expect(!source.isLoading)
    #expect(manager.errorState == nil)
    #expect(pages.requests.count == 1)
    #expect(pages.requests.first?.cursor == nil)
  }

  @Test("Successful populated response and reopening use the real message cache")
  func successfulPopulatedResponseAndCachedReopen() async throws {
    let pages = MessagePageStub([.response(200, try page("first"))])
    let (manager, source) = await makeSource(pages)
    await source.loadMessages()

    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.map(\.id) == ["first"])
    let reopened = BlueskyConversationDataSource(
      chatManager: manager, convoID: conversationID, currentUserDID: "did:plc:alice"
    )
    #expect(reopened.messages.map(\.id) == ["first"])
    #expect(reopened.messageLoadState == .loaded)
    #expect(pages.requests.count == 1)
  }

  @Test("Initial offline and timeout failures stay visible until real Retry succeeds",
    arguments: [URLError.Code.notConnectedToInternet, .timedOut])
  func initialNetworkFailureAndRetry(code: URLError.Code) async throws {
    let pages = MessagePageStub([
      .failure(URLError(code)), .response(200, try page("retried"))
    ])
    let (manager, source) = await makeSource(pages)
    await source.loadMessages()

    guard case .failed(let error) = source.messageLoadState else {
      Issue.record("A failed initial fetch must not become an empty success")
      return
    }
    #expect(!error.localizedDescription.isEmpty)
    #expect(source.messages.isEmpty)
    #expect(!source.isLoading)
    #expect(manager.errorState == nil, "Inline Retry must not depend on dismissing a global alert")

    await source.loadMessages()

    #expect(pages.requests.count == 2)
    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.map(\.id) == ["retried"])
  }

  @Test("HTTP errors and a missing response never claim an empty success",
    arguments: [400, 429, 503, 200])
  func responseFailureAndRetry(status: Int) async {
    let pages = MessagePageStub([
      .response(status, nil), .response(200, .init(messages: []))
    ])
    let (manager, source) = await makeSource(pages)
    await source.loadMessages()

    let expected: ChatManager.ChatError = status == 200 ? .emptyResponse : .networkError(code: status)
    #expect(source.messageLoadState == .failed(expected))
    #expect(manager.errorState == nil)
    await source.loadMessages()
    #expect(source.messageLoadState == .loaded)
    #expect(pages.requests.count == 2)
  }

  @Test("Thrown rate limits have an inline failure state and permit Retry")
  func thrownRateLimitAndRetry() async {
    let pages = MessagePageStub([
      .failure(Petrel.NetworkError.responseError(statusCode: 429)),
      .response(200, .init(messages: []))
    ])
    let (manager, source) = await makeSource(pages)
    await source.loadMessages()
    #expect(source.messageLoadState == .failed(.networkError(code: 429)))
    #expect(manager.errorState == nil)
    await source.loadMessages()
    #expect(source.messageLoadState == .loaded)
  }

  @Test("A detail opened during another request follows that request without false completion")
  func overlappingLoadUsesActiveRequest() async throws {
    let pages = MessagePageStub([.response(200, try page("shared"))])
    pages.pauseNextRequest = true
    let (manager, _) = await makeSource(pages)
    let first = Task { await manager.loadMessages(convoId: conversationID, refresh: true) }
    await pages.waitForPausedRequest()

    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: conversationID, currentUserDID: "did:plc:alice"
    )
    #expect(source.isLoading)
    await source.loadMessages()
    await manager.loadMessages(convoId: conversationID, refresh: true)
    #expect(source.messageLoadState == .loading)
    #expect(pages.requests.count == 1)

    pages.resumeRequest()
    await first.value
    await settleMessages(source, expectedID: "shared")
    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.map(\.id) == ["shared"])
  }

  @Test("Cancelled initial work cannot publish a late response or claim an empty conversation")
  func cancelledInitialLoad() async throws {
    let pages = MessagePageStub([
      .response(200, try page("cancelled")), .response(200, .init(messages: []))
    ])
    pages.pauseNextRequest = true
    let (_, source) = await makeSource(pages)
    let first = Task { await source.loadMessages() }
    await pages.waitForPausedRequest()
    first.cancel()
    // Model a transport that delivers after cancellation. The manager must reject it.
    pages.resumeRequest()
    await first.value

    #expect(source.messageLoadState == .interrupted)
    #expect(!source.isLoading)
    #expect(source.messages.isEmpty)
    await source.loadMessages()
    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.isEmpty)
  }

  @Test("A transport cancellation is not presented as a failure or an empty success")
  func transportCancellation() async {
    let pages = MessagePageStub([.failure(URLError(.cancelled))])
    let (manager, source) = await makeSource(pages)
    await source.loadMessages()
    #expect(source.messageLoadState == .interrupted)
    #expect(manager.errorState == nil)
    #expect(!source.isLoading)
  }

  @Test("Cancelled refresh restores loaded state and keeps cached history")
  func cancelledRefreshPreservesHistory() async throws {
    let pages = MessagePageStub([
      .response(200, try page("cached")), .response(200, .init(messages: []))
    ])
    let (_, source) = await makeSource(pages)
    await source.loadMessages()
    pages.pauseNextRequest = true
    let refresh = Task { await source.loadMessages() }
    await pages.waitForPausedRequest()
    #expect(source.messages.map(\.id) == ["cached"])
    refresh.cancel()
    pages.resumeRequest()
    await refresh.value
    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.map(\.id) == ["cached"])
  }

  @Test("A failed refresh and a later empty page preserve cached messages")
  func failedRefreshPreservesHistory() async throws {
    let pages = MessagePageStub([
      .response(200, try page("cached")), .failure(URLError(.notConnectedToInternet)),
      .response(200, .init(messages: []))
    ])
    let (_, source) = await makeSource(pages)
    await source.loadMessages()
    await source.loadMessages()
    #expect(source.messages.map(\.id) == ["cached"])
    guard case .failed = source.messageLoadState else {
      Issue.record("Refresh failure must retain its outcome independently from cached messages")
      return
    }
    await source.loadMessages()
    #expect(source.messageLoadState == .loaded)
    #expect(source.messages.map(\.id) == ["cached"])
  }

  @Test("Account retirement clears outcomes and rejects a previous account's late page")
  func retiredAccountRejectsLatePage() async throws {
    let pages = MessagePageStub([.response(200, try page("old-account"))])
    pages.pauseNextRequest = true
    let (manager, source) = await makeSource(pages)
    let request = Task { await source.loadMessages() }
    await pages.waitForPausedRequest()
    await manager.updateClient(nil)
    pages.resumeRequest()
    await request.value
    #expect(manager.messageLoadStates.isEmpty)
    #expect(source.messageLoadState == .idle)
    #expect(source.messages.isEmpty)
  }

  private func makeSource(_ pages: MessagePageStub) async -> (ChatManager, BlueskyConversationDataSource) {
    let client = await ATProtoClient(baseURL: URL(string: "https://message-load.invalid")!)
    let manager = ChatManager(client: client, messagePageLoader: { _, parameters in
      try await pages.load(parameters)
    })
    // No conversation with unread messages: success cannot dispatch updateRead to the network.
    let source = BlueskyConversationDataSource(
      chatManager: manager, convoID: conversationID, currentUserDID: "did:plc:alice"
    )
    return (manager, source)
  }

  private func page(_ id: String) throws -> ChatBskyConvoGetMessages.Output {
    .init(messages: [.chatBskyConvoDefsMessageView(.init(
      id: id, rev: "1", text: "Message \(id)",
      sender: .init(did: try DID(didString: "did:plc:alice")),
      sentAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    ))])
  }

  private func settleMessages(_ source: BlueskyConversationDataSource, expectedID: String) async {
    // Observation dispatches to the main actor; bound settling rather than sleeping.
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !source.messages.contains(where: { $0.id == expectedID }), ContinuousClock.now < deadline {
      await Task.yield()
    }
  }
}

@MainActor
private final class MessagePageStub {
  enum Outcome {
    case response(Int, ChatBskyConvoGetMessages.Output?)
    case failure(Error)
  }

  private var outcomes: [Outcome]
  private(set) var requests: [ChatBskyConvoGetMessages.Parameters] = []
  var pauseNextRequest = false
  private var pausedRequest: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?

  init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

  func load(_ parameters: ChatBskyConvoGetMessages.Parameters) async throws
    -> (Int, ChatBskyConvoGetMessages.Output?) {
    requests.append(parameters)
    guard !outcomes.isEmpty else {
      Issue.record("Unexpected extra message fetch")
      throw URLError(.badServerResponse)
    }
    let outcome = outcomes.removeFirst()
    if pauseNextRequest {
      pauseNextRequest = false
      await withCheckedContinuation { continuation in
        pausedRequest = continuation
        startWaiter?.resume()
        startWaiter = nil
      }
    }
    switch outcome {
    case .response(let status, let output): return (status, output)
    case .failure(let error): throw error
    }
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
