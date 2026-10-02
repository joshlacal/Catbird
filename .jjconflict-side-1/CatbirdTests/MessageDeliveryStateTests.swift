import Testing
import Foundation
@testable import Catbird
@testable import CatbirdMLSCore

@Suite("MessageDeliveryState")
struct MessageDeliveryStateTests {

  private func ack(messageId: String = "m1", senderDID: String) -> MLSDeliveryAckModel {
    MLSDeliveryAckModel(
      messageId: messageId,
      conversationId: "c1",
      senderDID: senderDID,
      ackedAt: Date(),
      currentUserDID: "did:plc:sender"
    )
  }

  @Test func sendingWhenNotSent() {
    let state = MessageDeliveryState.compute(
      isSent: false, acks: [], hasReadReceipt: false, memberCount: 2, readReceiptsEnabled: true
    )
    #expect(state == .sending)
  }

  @Test func sentWhenNoAcks() {
    let state = MessageDeliveryState.compute(
      isSent: true, acks: [], hasReadReceipt: false, memberCount: 2, readReceiptsEnabled: true
    )
    #expect(state == .sent)
  }

  @Test func deliveredPartialWhenSomeAcked() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: false,
      memberCount: 3,
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredPartial(count: 1, total: 2))
  }

  @Test func deliveredAllWhenAllAcked() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice"), ack(senderDID: "did:plc:bob")],
      hasReadReceipt: false,
      memberCount: 3,
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredAll)
  }

  @Test func readWhenReceiptAndEnabled() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: true,
      memberCount: 2,
      readReceiptsEnabled: true
    )
    #expect(state == .read)
  }

  @Test func deliveredAllNotReadWhenReceiptsDisabled() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: true,
      memberCount: 2,
      readReceiptsEnabled: false
    )
    #expect(state == .deliveredAll)
  }

  @Test func deduplicatesDuplicateAcksFromSameSender() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice"), ack(senderDID: "did:plc:alice")],
      hasReadReceipt: false,
      memberCount: 3,
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredPartial(count: 1, total: 2))
  }

  // MARK: - .failed (WS-6.5)

  @Test func failedIsNeverDerivedFromAckSignals() {
    // compute() derives from ack signals only; .failed is set by the send
    // pipeline. Exhaustively confirm no signal combination yields .failed.
    for isSent in [true, false] {
      for hasReadReceipt in [true, false] {
        for readReceiptsEnabled in [true, false] {
          let state = MessageDeliveryState.compute(
            isSent: isSent,
            acks: [ack(senderDID: "did:plc:alice")],
            hasReadReceipt: hasReadReceipt,
            memberCount: 2,
            readReceiptsEnabled: readReceiptsEnabled
          )
          #expect(!state.isFailed)
        }
      }
    }
  }

  @Test func failedCarriesReasonAndIsEquatable() {
    let state = MessageDeliveryState.failed(reason: "network down")
    #expect(state.isFailed)
    #expect(state == .failed(reason: "network down"))
    #expect(state != .failed(reason: "other"))
    #expect(MessageDeliveryState.sending.isFailed == false)
    #expect(MessageDeliveryState.sent.isFailed == false)
  }
}
