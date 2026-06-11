//
//  MessageDeliveryState.swift
//  Catbird
//
//  Derived delivery state for outgoing MLS messages.
//  Pure function — no side effects, no async.
//

import CatbirdMLSCore

/// The display state for an outgoing message's delivery indicator.
public enum MessageDeliveryState: Equatable {
  /// Message is being sent (not yet confirmed by server).
  case sending
  /// Server confirmed receipt; no member has acked yet.
  case sent
  /// Some but not all non-sender members have acked.
  case deliveredPartial(count: Int, total: Int)
  /// All non-sender members have acked.
  case deliveredAll
  /// At least one read receipt received (requires opt-in).
  case read
  /// The send pipeline gave up on this message (network/server/recovery
  /// failure after the package's retry semantics). Never derived from ack
  /// signals — `compute` cannot produce it. Set directly by the send
  /// pipeline so the UI can render a failed indicator with a retry
  /// affordance instead of an eternally pending state (WS-6.5).
  case failed(reason: String)
}

public extension MessageDeliveryState {
  /// True when the message terminally failed to send.
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

public extension MessageDeliveryState {

  /// Derives the delivery state from raw signal inputs.
  ///
  /// - Parameters:
  ///   - isSent: Whether the server has confirmed the message (seq assigned).
  ///   - acks: All delivery ack rows for this message from `MLSDeliveryAckModel`.
  ///   - hasReadReceipt: Whether any read receipt exists for this message.
  ///   - memberCount: Total member count of the conversation (including sender).
  ///   - readReceiptsEnabled: Whether the local user has read receipts enabled.
  static func compute(
    isSent: Bool,
    acks: [MLSDeliveryAckModel],
    hasReadReceipt: Bool,
    memberCount: Int,
    readReceiptsEnabled: Bool
  ) -> MessageDeliveryState {
    guard isSent else { return .sending }
    if readReceiptsEnabled && hasReadReceipt { return .read }
    let ackedDIDs = Set(acks.map(\.senderDID))
    let expected = max(memberCount - 1, 0)  // exclude sender
    if ackedDIDs.isEmpty { return .sent }
    if ackedDIDs.count < expected {
      return .deliveredPartial(count: ackedDIDs.count, total: expected)
    }
    return .deliveredAll
  }
}
