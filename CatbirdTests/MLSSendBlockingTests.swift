import Testing
import Foundation
@testable import Catbird
@testable import CatbirdMLSCore

// WS-6.5: send-blocking semantics derived from ConversationRecoveryState.
@Suite("MLSSendBlocking")
struct MLSSendBlockingTests {

  @Test func healthyDoesNotBlockSending() {
    #expect(ConversationRecoveryState.healthy.blocksSending == false)
  }

  @Test func transientDetectionStatesDoNotBlockSending() {
    // epochBehind / groupMissing frequently self-heal within a sync cycle;
    // blocking on them would flap the composer.
    #expect(ConversationRecoveryState.epochBehind.blocksSending == false)
    #expect(ConversationRecoveryState.groupMissing.blocksSending == false)
  }

  @Test func activeRecoveryStatesBlockSending() {
    #expect(ConversationRecoveryState.recovering.blocksSending)
    #expect(ConversationRecoveryState.needsRejoin.blocksSending)
    #expect(ConversationRecoveryState.resetPending.blocksSending)
    #expect(ConversationRecoveryState.unrecoverableLocal.blocksSending)
  }

  @Test func noticeExistsExactlyForBlockingStates() {
    for state in ConversationRecoveryState.allCases {
      let notice = SendBlockedNotice.notice(for: state)
      #expect(
        (notice != nil) == state.blocksSending,
        "notice presence must match blocksSending for \(state.rawValue)"
      )
    }
  }

  @Test func unrecoverableNoticeShowsNoProgress() {
    // Terminal local state: nothing is in flight, so no spinner.
    let notice = SendBlockedNotice.notice(for: .unrecoverableLocal)
    #expect(notice?.showsProgress == false)
  }

  @Test func inFlightRecoveryNoticeShowsProgress() {
    let notice = SendBlockedNotice.notice(for: .recovering)
    #expect(notice?.showsProgress == true)
  }
}
