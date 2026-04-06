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
}
