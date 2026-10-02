import Testing
@testable import Catbird

@MainActor
struct MessageDraftTests {
  struct Content: Equatable {
    var text = ""
    var attachment: String?
    var reply: String?
  }

  @Test func failedSendPreservesCompleteDraftAndAllowsRetry() throws {
    let draft = MessageDraft(Content())
    let content = Content(text: "Please keep this", attachment: "post-A", reply: "message-A")
    draft.value = content
    let submission = try #require(draft.beginSend())
    #expect(draft.value == content)
    #expect(draft.beginSend() == nil)
    draft.finishSend(submission, succeeded: false)
    #expect(draft.value == content)
    let retry = try #require(draft.beginSend())
    #expect(retry.value == content)
    draft.finishSend(retry, succeeded: true)
    #expect(draft.value == Content())
  }

  @Test func successfulSendClearsOnlyItsUneditedDraft() throws {
    let draft = MessageDraft(Content())
    draft.value = Content(text: "First", attachment: "post-A", reply: "message-A")
    let first = try #require(draft.beginSend())
    let next = Content(text: "Second", attachment: "post-B", reply: "message-B")
    draft.value = next
    draft.finishSend(first, succeeded: true)
    #expect(draft.value == next)
    #expect(first.value == Content(text: "First", attachment: "post-A", reply: "message-A"))
  }

  @Test func attachmentOrReplyEditAloneProtectsTheNewDraft() throws {
    let draft = MessageDraft(Content())
    draft.value = Content(text: "Same text", attachment: "post-A", reply: "message-A")
    let first = try #require(draft.beginSend())
    draft.value.attachment = "post-B"
    draft.value.reply = "message-B"
    draft.finishSend(first, succeeded: true)
    #expect(draft.value == Content(text: "Same text", attachment: "post-B", reply: "message-B"))
  }

  @Test func editingBackToTheOriginalTextStillCreatesANewDraft() throws {
    let draft = MessageDraft(Content())
    draft.value.text = "Repeat"
    let first = try #require(draft.beginSend())
    draft.value.text = "Something else"
    draft.value.text = "Repeat"
    draft.finishSend(first, succeeded: true)
    #expect(draft.value.text == "Repeat")
  }

  @Test func oldSuccessBeforeNewFailurePreservesTheNewDraft() throws {
    let draft = MessageDraft(Content())
    draft.value.text = "First"
    let first = try #require(draft.beginSend())
    draft.value = Content(text: "Second", attachment: "post-B", reply: "message-B")
    let second = try #require(draft.beginSend())
    draft.finishSend(first, succeeded: true)
    draft.finishSend(second, succeeded: false)
    #expect(draft.value == second.value)
  }

  @Test func newSuccessBeforeOldFailureDoesNotRestoreAnAlreadyReplacedDraft() throws {
    let draft = MessageDraft(Content())
    draft.value.text = "First"
    let first = try #require(draft.beginSend())
    draft.value.text = "Second"
    let second = try #require(draft.beginSend())
    draft.finishSend(second, succeeded: true)
    draft.finishSend(first, succeeded: false)
    #expect(draft.value == Content())
  }

  @Test func duplicateCompletionCannotClearANewDraft() throws {
    let draft = MessageDraft(Content())
    draft.value.text = "First"
    let first = try #require(draft.beginSend())
    draft.finishSend(first, succeeded: true)
    draft.value.text = "Third"
    draft.finishSend(first, succeeded: true)
    #expect(draft.value.text == "Third")
  }

  @Test func asyncHandoffCapturesBeforeAnABAEditAndBeforeTheTaskRuns() async throws {
    let draft = MessageDraft(Content())
    let original = Content(text: "Repeat", attachment: "post-A", reply: "message-A")
    draft.value = original
    var transmitted: [Content] = []
    let task = try #require(draft.submitSend { value in
      transmitted.append(value)
      return true
    })

    // This synchronous main-actor turn has not yielded to the send task yet.
    draft.value.text = "Something else"
    draft.value = Content(text: "Repeat", attachment: "post-B", reply: "message-B")
    let next = draft.value
    #expect(transmitted.isEmpty)

    await task.value
    #expect(transmitted == [original])
    #expect(draft.value == next)
  }

  @Test func failedAsyncHandoffKeepsTheCompleteDraftAndDoesNotDuplicateTheSend() async throws {
    let draft = MessageDraft(Content())
    let original = Content(text: "Keep this", attachment: "post-A", reply: "message-A")
    draft.value = original
    var calls = 0
    let task = try #require(draft.submitSend { value in
      #expect(value == original)
      calls += 1
      return false
    })
    let duplicate = draft.submitSend { _ in
      calls += 1
      return true
    }
    #expect(duplicate == nil)
    await task.value
    #expect(calls == 1)
    #expect(draft.value == original)
  }
}
