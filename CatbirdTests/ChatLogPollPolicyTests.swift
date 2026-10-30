@testable import Catbird
import Foundation
import Testing

/// The getLog cursor is the only thing that delivers new messages to an open
/// conversation, so a cursor the server refuses must be rebuilt, not retried.
struct ChatLogPollPolicyTests {
  @Test("A rejected cursor resets immediately")
  func rejectedCursorResets() {
    var policy = ChatLogPollPolicy()
    #expect(policy.record(ChatLogPollPolicy.outcome(forStatusCode: 400)) == .resetCursor)
    #expect(policy.record(.rejected(statusCode: 404)) == .resetCursor)
  }

  @Test("Repeated server errors reset after the threshold; one success clears the count")
  func serverErrorsResetAfterThreshold() {
    var policy = ChatLogPollPolicy()
    #expect(policy.record(.serverError) == .backOff)
    #expect(policy.record(.serverError) == .backOff)
    #expect(policy.record(.success) == .none)
    #expect(policy.record(.serverError) == .backOff)
    #expect(policy.record(.serverError) == .backOff)
    #expect(policy.record(.serverError) == .resetCursor)
    #expect(policy.consecutiveServerErrors == 0)
  }

  @Test("Rate limits, auth failures and transport errors back off without dropping the cursor")
  func transientFailuresBackOff() {
    var policy = ChatLogPollPolicy()
    for _ in 0..<10 {
      #expect(policy.record(ChatLogPollPolicy.outcome(forStatusCode: 429)) == .backOff)
      #expect(policy.record(ChatLogPollPolicy.outcome(forStatusCode: 401)) == .backOff)
      #expect(policy.record(.transportError) == .backOff)
    }
    #expect(policy.record(.skipped) == .none)
  }

  @Test("Status codes map to outcomes")
  func statusCodeMapping() {
    #expect(ChatLogPollPolicy.outcome(forStatusCode: 200) == .success)
    #expect(ChatLogPollPolicy.outcome(forStatusCode: 429) == .rateLimited)
    #expect(ChatLogPollPolicy.outcome(forStatusCode: 403) == .unauthorized)
    #expect(ChatLogPollPolicy.outcome(forStatusCode: 400) == .rejected(statusCode: 400))
    #expect(ChatLogPollPolicy.outcome(forStatusCode: 502) == .serverError)
  }

  @Test("A createMessage event counts as unread only on its first sighting")
  func createMessageDedupe() {
    #expect(ChatLogPollPolicy.isNewMessage(logRev: "3kb2", convoRev: "3ka9", alreadySeen: false))
    #expect(!ChatLogPollPolicy.isNewMessage(logRev: "3kb2", convoRev: "3ka9", alreadySeen: true))
    #expect(!ChatLogPollPolicy.isNewMessage(logRev: "3kb2", convoRev: "3kb2", alreadySeen: false))
    #expect(!ChatLogPollPolicy.isNewMessage(logRev: "3ka1", convoRev: "3kb2", alreadySeen: false))
  }
}
