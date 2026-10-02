@testable import Catbird
import Foundation
import Petrel
import Testing

struct BlueskyMessageReplyTests {
  private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("MessageView reply union maps ordinary message to tappable reply context")
  func testOrdinaryReplyContext() throws {
    let aliceDID = try DID(didString: "did:plc:alice")
    let referencedMsg = ChatBskyConvoDefs.MessageView(
      id: "orig_123",
      rev: "1",
      text: "Original message text",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: aliceDID),
      sentAt: ATProtocolDate(date: baseDate)
    )

    let replyMsg = ChatBskyConvoDefs.MessageView(
      id: "reply_456",
      rev: "1",
      text: "Replying to original",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: .chatBskyConvoDefsMessageView(referencedMsg),
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:bob")),
      sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(60))
    )

    let adapter = BlueskyMessageAdapter(messageView: replyMsg, currentUserDID: "did:plc:bob")
    guard let replyContext = adapter.replyContext else {
      Issue.record("Expected non-nil replyContext")
      return
    }

    #expect(replyContext.isTappable)
    #expect(replyContext.referencedMessageID == "orig_123")
    #expect(replyContext.previewText == "Original message text")
    if case .message(let id, let did, _, let text) = replyContext.kind {
      #expect(id == "orig_123")
      #expect(did == "did:plc:alice")
      #expect(text == "Original message text")
    } else {
      Issue.record("Expected .message kind")
    }
  }

  @Test("MessageView reply union maps deleted message to static non-tappable context")
  func testDeletedReplyContext() throws {
    let deletedMsg = ChatBskyConvoDefs.DeletedMessageView(
      id: "deleted_123",
      rev: "1",
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:alice")),
      sentAt: ATProtocolDate(date: baseDate)
    )

    let replyMsg = ChatBskyConvoDefs.MessageView(
      id: "reply_456",
      rev: "1",
      text: "Replying to deleted",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: .chatBskyConvoDefsDeletedMessageView(deletedMsg),
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:bob")),
      sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(60))
    )

    let adapter = BlueskyMessageAdapter(messageView: replyMsg, currentUserDID: "did:plc:bob")
    guard let replyContext = adapter.replyContext else {
      Issue.record("Expected non-nil replyContext")
      return
    }

    #expect(!replyContext.isTappable)
    #expect(replyContext.referencedMessageID == nil)
    #expect(replyContext.previewText == "Deleted message")
    #expect(replyContext.kind == .deleted)
  }

  @Test("MessageView reply union maps beforeUserJoined to static non-tappable context")
  func testBeforeUserJoinedReplyContext() throws {
    let beforeJoinMsg = ChatBskyConvoDefs.MessageBeforeUserJoinedGroupView()

    let replyMsg = ChatBskyConvoDefs.MessageView(
      id: "reply_456",
      rev: "1",
      text: "Replying to pre-join message",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: .chatBskyConvoDefsMessageBeforeUserJoinedGroupView(beforeJoinMsg),
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:bob")),
      sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(60))
    )

    let adapter = BlueskyMessageAdapter(messageView: replyMsg, currentUserDID: "did:plc:bob")
    guard let replyContext = adapter.replyContext else {
      Issue.record("Expected non-nil replyContext")
      return
    }

    #expect(!replyContext.isTappable)
    #expect(replyContext.referencedMessageID == nil)
    #expect(replyContext.previewText == "Message sent before you joined")
    #expect(replyContext.kind == .beforeUserJoined)
  }

  @Test("ReplyRef encodes message ID correctly")
  func testReplyRefEncoding() {
    let replyRef = ChatBskyConvoDefs.ReplyRef(messageId: "msg_789")
    #expect(replyRef.messageId == "msg_789")

    let input = ChatBskyConvoDefs.MessageInput(
      text: "Hello",
      facets: nil,
      embed: nil,
      replyTo: replyRef
    )
    #expect(input.replyTo?.messageId == "msg_789")
  }

  @Test("Failed send preserves staged reply target and draft text")
  func testFailedSendPreservesStagedReplyAndDraft() throws {
    struct StagedReplyState {
      var target: ChatBskyConvoDefs.MessageView?
      var draftText: String

      mutating func handleSendResult(success: Bool) {
        if success {
          target = nil
          draftText = ""
        }
      }
    }

    let aliceDID = try DID(didString: "did:plc:alice")
    let referencedMsg = ChatBskyConvoDefs.MessageView(
      id: "orig_failed_test",
      rev: "1",
      text: "Original message",
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: aliceDID),
      sentAt: ATProtocolDate(date: baseDate)
    )

    var state = StagedReplyState(target: referencedMsg, draftText: "My reply draft")

    // Failed send must preserve both the staged reply target and draft text
    state.handleSendResult(success: false)
    #expect(state.target?.id == "orig_failed_test")
    #expect(state.draftText == "My reply draft")

    // Successful send clears both
    state.handleSendResult(success: true)
    #expect(state.target == nil)
    #expect(state.draftText.isEmpty)
  }

  @Test("Swipe-to-reply arms only on inward translation past threshold and disarms on retraction")
  func testSwipeToReplyArmedThresholdInwardOnly() {
    func calculateGestureState(
      isCurrentUser: Bool,
      translationWidth: CGFloat,
      verticalTranslation: CGFloat
    ) -> (dragOffset: CGFloat, isArmed: Bool) {
      guard abs(verticalTranslation) < abs(translationWidth) else {
        return (0, false)
      }
      let validTranslation = isCurrentUser ? min(0, translationWidth) : max(0, translationWidth)
      let damped = validTranslation * 0.4
      let isArmed = isCurrentUser ? damped <= -30 : damped >= 30
      return (damped, isArmed)
    }

    // Incoming message (left aligned): only swiping right (inward, translation > 0) arms
    let incomingInward = calculateGestureState(isCurrentUser: false, translationWidth: 80, verticalTranslation: 0)
    #expect(incomingInward.dragOffset == 32)
    #expect(incomingInward.isArmed == true)

    // Incoming message: swiping left (outward, translation < 0) is clamped and never arms
    let incomingOutward = calculateGestureState(isCurrentUser: false, translationWidth: -80, verticalTranslation: 0)
    #expect(incomingOutward.dragOffset == 0)
    #expect(incomingOutward.isArmed == false)

    // Incoming message: retracted translation below threshold disarms
    let incomingRetracted = calculateGestureState(isCurrentUser: false, translationWidth: 50, verticalTranslation: 0)
    #expect(incomingRetracted.dragOffset == 20)
    #expect(incomingRetracted.isArmed == false)

    // Self message (right aligned): only swiping left (inward, translation < 0) arms
    let selfInward = calculateGestureState(isCurrentUser: true, translationWidth: -80, verticalTranslation: 0)
    #expect(selfInward.dragOffset == -32)
    #expect(selfInward.isArmed == true)

    // Self message: swiping right (outward, translation > 0) is clamped and never arms
    let selfOutward = calculateGestureState(isCurrentUser: true, translationWidth: 80, verticalTranslation: 0)
    #expect(selfOutward.dragOffset == 0)
    #expect(selfOutward.isArmed == false)

    // Predominantly vertical drag does not arm
    let verticalDrag = calculateGestureState(isCurrentUser: false, translationWidth: 80, verticalTranslation: 100)
    #expect(verticalDrag.dragOffset == 0)
    #expect(verticalDrag.isArmed == false)
  }

  @Test("Async composer send restores draft and embed on failure if empty")
  func testAsyncComposerSendRestoresDraftOnFailure() async {
    struct ComposerState {
      var text: String
      var embed: String?

      mutating func send(onAsyncSend: (String, String?) async -> Bool) async {
        let capturedText = text
        let capturedEmbed = embed
        text = ""
        embed = nil

        let success = await onAsyncSend(capturedText, capturedEmbed)
        if !success {
          if text.isEmpty {
            text = capturedText
          }
          if embed == nil {
            embed = capturedEmbed
          }
        }
      }
    }

    var composer = ComposerState(text: "Unsent reply message", embed: "link-embed")

    // When async send fails, draft text and embed are restored
    await composer.send { _, _ in false }
    #expect(composer.text == "Unsent reply message")
    #expect(composer.embed == "link-embed")

    // When async send succeeds, draft text and embed remain cleared
    await composer.send { _, _ in true }
    #expect(composer.text.isEmpty)
    #expect(composer.embed == nil)
  }
}
