//
//  MLSSendBlocking.swift
//  Catbird
//
//  WS-6.5: pure send-blocking semantics derived from the package's
//  ConversationRecoveryState (spec §8.1). No side effects, no async.
//

import CatbirdMLSCore

extension ConversationRecoveryState {
  /// Whether the app should block outgoing sends while the conversation is in
  /// this recovery state (WS-6.5: "block sends while a conversation is in
  /// active recovery/rejoin, with a visible state").
  ///
  /// Blocking states are the ones where the local MLS group is known to be
  /// unusable or about to be replaced — a send would either fail or land in
  /// the wrong epoch:
  /// - `.recovering`: an External Commit / Welcome fetch is in flight.
  /// - `.needsRejoin`: flagged for deferred rejoin; the group is stale.
  /// - `.resetPending`: the server issued a group reset; the local group is dead.
  /// - `.unrecoverableLocal`: max attempts exhausted, awaiting server reset.
  ///
  /// `.epochBehind` and `.groupMissing` are transient *detection* states that
  /// frequently self-heal within one sync cycle; blocking on them would flap
  /// the composer. The send path still surfaces a `.failed` message state if
  /// a send actually fails while in them.
  var blocksSending: Bool {
    switch self {
    case .recovering, .needsRejoin, .resetPending, .unrecoverableLocal:
      return true
    case .healthy, .epochBehind, .groupMissing:
      return false
    }
  }
}

/// Presentation payload for the "sending paused during recovery" notice.
/// Pure mapping so it stays unit-testable without SwiftUI.
struct SendBlockedNotice: Equatable {
  let title: String
  let detail: String
  let iconName: String
  let showsProgress: Bool

  /// Returns the user-facing notice for a blocking recovery state, or `nil`
  /// when sends are not blocked.
  static func notice(for state: ConversationRecoveryState) -> SendBlockedNotice? {
    guard state.blocksSending else { return nil }
    switch state {
    case .recovering:
      return SendBlockedNotice(
        title: "Restoring secure session",
        detail: "Sending is paused while encryption keys are refreshed.",
        iconName: "arrow.triangle.2.circlepath.circle.fill",
        showsProgress: true
      )
    case .needsRejoin:
      return SendBlockedNotice(
        title: "Secure session needs repair",
        detail: "Sending is paused until this conversation rejoins the encrypted group.",
        iconName: "exclamationmark.shield.fill",
        showsProgress: true
      )
    case .resetPending:
      return SendBlockedNotice(
        title: "Conversation is resetting",
        detail: "Sending is paused while the encrypted group is rebuilt.",
        iconName: "arrow.counterclockwise.circle.fill",
        showsProgress: true
      )
    case .unrecoverableLocal:
      return SendBlockedNotice(
        title: "Secure session unavailable",
        detail: "Waiting for this conversation to be reset. You can't send messages right now.",
        iconName: "exclamationmark.shield.fill",
        showsProgress: false
      )
    case .healthy, .epochBehind, .groupMissing:
      return nil
    }
  }
}
