//
//  MLSSendBlocking.swift
//  Catbird
//
//  Send-blocking presentation and the detail pipeline's local access guard.
//  Recovery semantics come from CatbirdMLSCore (spec §8.1).
//

import CatbirdMLSCore
import Foundation

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
    title: String(localized: "Waiting for secure access", comment: "Banner title when this device is waiting for another member to grant MLS access"),
    detail: String(localized: "Another member needs to add this device before it can load new messages. Keep Catbird open on a device that already has access.", comment: "Banner detail when this device is waiting for MLS access"),
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
    if leave == .left {
      return String(localized: "You left this conversation", comment: "Composer placeholder and notice title after leaving a group chat")
    }
    switch state {
    case .closed:
      return String(localized: "Conversation closed", comment: "Composer placeholder and notice title when a conversation is closed")
    case .deviceRemoved:
      return String(localized: "No access on this device", comment: "Composer placeholder when this device no longer has MLS access")
    default:
      return state.blocksSending
        ? String(localized: "Sending paused", comment: "Composer placeholder while encrypted session recovery blocks sending")
        : String(localized: "Message")
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
      return SendBlockedNotice(
        title: String(localized: "You left this conversation"),
        detail: String(localized: "You can still read your saved messages. You are no longer a member of this group.", comment: "Notice detail after leaving an encrypted group conversation"),
        iconName: "rectangle.portrait.and.arrow.right",
        showsProgress: false
      )
    case .pending:
      return SendBlockedNotice(
        title: String(localized: "Leave requested", comment: "Notice title when a leave request is pending confirmation"),
        detail: String(localized: "You are still a member until another member's device confirms your request. Your saved messages stay here.", comment: "Notice detail when a leave request is pending confirmation"),
        iconName: "clock",
        showsProgress: false
      )
    case .checking:
      return SendBlockedNotice(
        title: String(localized: "Checking leave status", comment: "Notice title while refreshing pending leave status"),
        detail: String(localized: "Your previous request needs a fresh status check. Your saved messages stay here.", comment: "Notice detail while refreshing pending leave status"),
        iconName: "clock",
        showsProgress: false
      )
    case .none: break
    }
    guard state.blocksSending else { return nil }
    switch state {
    case .deviceRemoved:
      return SendBlockedNotice(
        title: String(localized: "This device no longer has access", comment: "Notice title when this device was removed from an encrypted conversation"),
        detail: String(localized: "Your saved messages are still here. Another member must add this device before it can send or receive new messages.", comment: "Notice detail when this device was removed from an encrypted conversation"),
        iconName: "lock.fill",
        showsProgress: false
      )
    case .closed:
      return SendBlockedNotice(
        title: String(localized: "Conversation closed"),
        detail: String(localized: "You can still read your saved messages. Start a new conversation to chat again.", comment: "Notice detail when an encrypted conversation is closed"),
        iconName: "lock.fill",
        showsProgress: false
      )
    case .recovering:
      return SendBlockedNotice(
        title: String(localized: "Restoring secure session", comment: "Notice title while encryption keys are being refreshed"),
        detail: String(localized: "Sending is paused while encryption keys are refreshed.", comment: "Notice detail while encryption keys are being refreshed"),
        iconName: "arrow.triangle.2.circlepath.circle.fill",
        showsProgress: true
      )
    case .needsRejoin:
      return SendBlockedNotice(
        title: String(localized: "Secure session needs repair", comment: "Notice title when an encrypted conversation needs to rejoin"),
        detail: String(localized: "Sending is paused until this conversation rejoins the encrypted group.", comment: "Notice detail when an encrypted conversation needs to rejoin"),
        iconName: "exclamationmark.shield.fill",
        showsProgress: true,
        offersReset: true
      )
    case .resetPending:
      return SendBlockedNotice(
        title: String(localized: "Conversation is resetting", comment: "Notice title when an encrypted group is resetting"),
        detail: String(localized: "Sending is paused while the encrypted group is rebuilt.", comment: "Notice detail when an encrypted group is resetting"),
        iconName: "arrow.counterclockwise.circle.fill",
        showsProgress: true
      )
    case .unrecoverableLocal:
      return SendBlockedNotice(
        title: String(localized: "Secure session unavailable", comment: "Notice title when local MLS session recovery is exhausted"),
        detail: String(localized: "This device can't rejoin the encrypted group. Reset to start a fresh session.", comment: "Notice detail when local MLS session recovery is exhausted"),
        iconName: "exclamationmark.shield.fill",
        showsProgress: false,
        offersReset: true
      )
    case .healthy, .epochBehind, .groupMissing:
      return nil
    }
  }
}
