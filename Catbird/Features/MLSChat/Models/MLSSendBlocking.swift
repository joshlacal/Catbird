//
//  MLSSendBlocking.swift
//  Catbird
//
//  Send-blocking presentation and the detail pipeline's local access guard.
//  Recovery semantics come from CatbirdMLSCore (spec §8.1).
//

import CatbirdMLSCore
import Foundation
import GRDB

/// Local presentation evidence for one account and one generation of a conversation.
/// A missing proof never means that a conversation has ended.
enum MLSConversationPipelineAccess: Equatable, Sendable {
  struct Scope: Equatable, Sendable {
    let userDID: String
    let conversationID: String
    let groupID: Data
  }

  enum Failure: Error { case unavailable, managerUnavailable }
  enum Preparation: Equatable, Sendable {
    case ready
    case localHistory(MLSConversationPipelineAccess)
  }

  case requiresReadiness
  case pendingConsent
  case terminal(ConversationRecoveryState)

  static func read(in db: Database, scope: Scope) throws -> Self {
    guard let model = try MLSConversationModel.fetchOne(db,
      sql: "SELECT * FROM MLSConversationModel WHERE currentUserDID = ? AND conversationID = ?",
      arguments: [scope.userDID, scope.conversationID]) else { throw Failure.unavailable }
    guard model.groupID == scope.groupID else { throw CancellationError() }
    let terminal = try String.fetchOne(db,
      sql: """
        SELECT state FROM mls_orchestrator_terminal_access
        WHERE user_did = ? AND conversation_id = ? AND group_id = ?
        """,
      arguments: [scope.userDID, scope.conversationID, scope.groupID])
    guard terminal == nil || terminal == "closed" || terminal == "device_removed" else {
      throw Failure.unavailable
    }
    if terminal == "closed" { return .terminal(.closed) }
    // A verified newer invitation can coexist with this device's old terminal
    // access. Its explicit consent UI takes precedence over automatic setup.
    if try model.hasPendingConsent(in: db) { return .pendingConsent }
    if terminal == "device_removed" { return .terminal(.deviceRemoved) }
    return .requiresReadiness
  }

  /// The detail pipeline uses this boundary before readiness and again after
  /// its awaited result. Terminal arrival must not become an initialization error.
  @MainActor
  static func prepare(
    isCurrent: () -> Bool,
    readAccess: () async throws -> Self,
    ensureReady: () async throws -> Void,
    loadLocalHistory: () async -> Void
  ) async throws -> Preparation {
    func currentAccess() async throws -> Self {
      guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
      let result: Result<Self, Error>
      do {
        result = .success(try await readAccess())
      } catch {
        result = .failure(error)
      }
      guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
      return try result.get()
    }
    func localHistory(_ access: Self) async throws -> Preparation {
      await loadLocalHistory()
      guard try await currentAccess() == access else { throw CancellationError() }
      return .localHistory(access)
    }

    let initial = try await currentAccess()
    guard initial == .requiresReadiness else { return try await localHistory(initial) }
    let result: Result<Void, Error>
    do {
      try await ensureReady()
      result = .success(())
    } catch {
      result = .failure(error)
    }
    let latest = try await currentAccess()
    guard latest == .requiresReadiness else { return try await localHistory(latest) }
    try result.get()
    return .ready
  }
}

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
    case .recovering, .needsRejoin, .resetPending, .unrecoverableLocal, .deviceRemoved, .closed:
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
  /// Offer a user-confirmed conversation reset: the local group is gone and
  /// automatic recovery has nothing left to wait for.
  let offersReset: Bool

  init(title: String, detail: String, iconName: String, showsProgress: Bool, offersReset: Bool = false) {
    self.title = title
    self.detail = detail
    self.iconName = iconName
    self.showsProgress = showsProgress
    self.offersReset = offersReset
  }

  static let pendingDeviceAccess = SendBlockedNotice(
    title: "Waiting for secure access",
    detail: "Another member needs to add this device before it can load new messages. Keep Catbird open on a device that already has access.",
    iconName: "lock.clock",
    showsProgress: true
  )

  static func keepsWaitingForDeviceAccess(_ state: ConversationRecoveryState) -> Bool {
    switch state {
    case .deviceRemoved, .closed, .resetPending, .unrecoverableLocal: return false
    default: return true
    }
  }

  static func composerPlaceholder(for state: ConversationRecoveryState, leave: MLSConversationLeavePresentation) -> String {
    if leave == .left { return "You left this conversation" }
    switch state {
    case .closed: return "Conversation closed"
    case .deviceRemoved: return "No access on this device"
    default: return state.blocksSending ? "Sending paused" : "Message"
    }
  }

  /// Account departure and closure retain the transcript without offering new
  /// drafts, attachments or recordings. Device removal alone can be repaired.
  static func hidesComposer(for state: ConversationRecoveryState, leave: MLSConversationLeavePresentation) -> Bool {
    state == .closed || (state == .deviceRemoved && leave == .left)
  }

  /// Returns the user-facing notice for a blocking recovery state, or `nil`
  /// when sends are not blocked.
  static func notice(
    for state: ConversationRecoveryState,
    leave: MLSConversationLeavePresentation = .none
  ) -> SendBlockedNotice? {
    // A terminal access state takes precedence over a stale pending display hint.
    let displayedLeave = (state == .closed || state == .deviceRemoved) && leave != .left ? .none : leave
    switch displayedLeave {
    case .left:
      return SendBlockedNotice(title: "You left this conversation",
        detail: "You can still read your saved messages. You are no longer a member of this group.",
        iconName: "rectangle.portrait.and.arrow.right", showsProgress: false)
    case .pending:
      return SendBlockedNotice(title: "Leave requested",
        detail: "You are still a member until another member's device confirms your request. Your saved messages stay here.",
        iconName: "clock", showsProgress: false)
    case .checking:
      return SendBlockedNotice(title: "Checking leave status",
        detail: "Your previous request needs a fresh status check. Your saved messages stay here.",
        iconName: "clock", showsProgress: false)
    case .none: break
    }
    guard state.blocksSending else { return nil }
    switch state {
    case .deviceRemoved:
      return SendBlockedNotice(title: "This device no longer has access",
        detail: "Your saved messages are still here. Another member must add this device before it can send or receive new messages.",
        iconName: "lock.fill", showsProgress: false)
    case .closed:
      return SendBlockedNotice(title: "Conversation closed",
        detail: "You can still read your saved messages. Start a new conversation to chat again.",
        iconName: "lock.fill", showsProgress: false)
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
        showsProgress: true,
        offersReset: true
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
        detail: "This device can't rejoin the encrypted group. Reset to start a fresh session.",
        iconName: "exclamationmark.shield.fill",
        showsProgress: false,
        offersReset: true
      )
    case .healthy, .epochBehind, .groupMissing:
      return nil
    }
  }
}
