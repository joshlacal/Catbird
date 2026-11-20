import Testing
@testable import Catbird

/// The text typed for a new one-to-one encrypted chat travels inside the request. It is
/// never sent as a second message while the request is waiting.
@Suite("MLS Direct Chat Start Tests")
struct MLSDirectChatStartTests {
  private typealias Start = MLSDirectChatStart

  @Test("A new request that carries the typed text needs nothing more sent")
  func newRequestCarriesTheText() {
    let plan = Start.plan(
      typedText: "Hello there",
      request: .init(consent: "outgoingPending", openingText: "Hello there"))
    #expect(plan == .carriedByRequest)
  }

  @Test("Surrounding whitespace does not make the carried text different")
  func whitespaceIsIgnored() {
    let plan = Start.plan(
      typedText: "  Hello there\n",
      request: .init(consent: "outgoingPending", openingText: "Hello there"))
    #expect(plan == .carriedByRequest)
  }

  @Test("An earlier waiting request with other text is reported, not sent into")
  func earlierRequestWithOtherText() {
    let plan = Start.plan(
      typedText: "Are you around?",
      request: .init(consent: "outgoingPending", openingText: "Hello there"))
    #expect(plan == .earlierRequestWaiting)
    #expect(Start.Delivery.earlierRequestWaiting.delivered == false)
    #expect(Start.Delivery.earlierRequestWaiting.notice != nil)
  }

  @Test("A waiting request whose text cannot be read is not assumed to carry the typed text")
  func unreadableOpening() {
    let plan = Start.plan(
      typedText: "Hello there",
      request: .init(consent: "outgoingPending", openingText: nil))
    #expect(plan == .earlierRequestWaiting)
  }

  @Test("Their request waiting for your answer is reported, not sent into")
  func theirRequestWaiting() {
    let plan = Start.plan(
      typedText: "Hello there",
      request: .init(consent: "incomingPending", openingText: "Hi"))
    #expect(plan == .theirRequestWaiting)
    #expect(Start.Delivery.theirRequestWaiting.notice != nil)
  }

  @Test("An accepted request, or a chat with no request, gets the text as a message")
  func openChatGetsAMessage() {
    #expect(Start.plan(typedText: "Hello", request: nil) == .sendMessage)
    #expect(
      Start.plan(typedText: "Hello", request: .init(consent: "accepted", openingText: "Earlier"))
        == .sendMessage)
  }

  @Test("Delivered outcomes carry no notice")
  func deliveredOutcomesHaveNoNotice() {
    #expect(Start.Delivery.sentWithRequest.delivered)
    #expect(Start.Delivery.sentAsMessage.delivered)
    #expect(Start.Delivery.sentWithRequest.notice == nil)
    #expect(Start.Delivery.sentAsMessage.notice == nil)
  }
}
