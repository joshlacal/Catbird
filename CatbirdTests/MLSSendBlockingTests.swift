import Testing
import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import Catbird
@testable import CatbirdMLSCore

// WS-6.5: send-blocking semantics derived from ConversationRecoveryState.
@Suite("MLSSendBlocking")
struct MLSSendBlockingTests {

  #if os(iOS)
  @MainActor
  @Test func composerTransitionsRetireActionsAndInstallAfterAcceptance() async throws {
    let userDID = "did:plc:composerfixture"
    let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
    let appState = AppState(userDID: userDID, client: client)
    let source = MLSConversationDataSource(
      conversationId: "550e8400-e29b-41d4-a716-446655440000", currentUserDID: userDID, appState: nil)
    let controller = ChatCollectionViewController(
      dataSource: source,
      navigationPath: .constant(NavigationPath()),
      appState: appState,
      sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID())
    )
    controller.loadViewIfNeeded()
    var sent: [String] = []
    var attachments = 0
    var recordings = 0
    let config = InlineComposerConfig(
      onSend: { sent.append($0) },
      onAttachTapped: { attachments += 1 },
      onVoiceRecordingStarted: { recordings += 1 }
    )

    // Pending consent starts without an input view; Accept installs it.
    controller.updateComposer(config: nil)
    #expect(controller.view.subviews.compactMap { $0 as? UIKitMLSComposerView }.isEmpty)
    controller.updateComposer(config: config)
    let first = try #require(controller.view.subviews.compactMap { $0 as? UIKitMLSComposerView }.first)
    first.text = "Unsent draft"
    controller.updateComposer(config: config)
    #expect(controller.view.subviews.compactMap { $0 as? UIKitMLSComposerView }.first === first)
    #expect(first.text == "Unsent draft")

    // Completion removes all actions, including callbacks already queued by UIKit.
    controller.updateComposer(config: nil)
    #expect(first.superview == nil)
    #expect(first.delegate == nil)
    controller.composerDidTapSend(first, text: "stale")
    controller.composerDidTapAttach(first)
    controller.composerDidStartVoiceRecording(first)
    #expect(sent.isEmpty && attachments == 0 && recordings == 0)

    controller.updateComposer(config: config)
    let second = try #require(controller.view.subviews.compactMap { $0 as? UIKitMLSComposerView }.first)
    #expect(second !== first)
    controller.composerDidTapSend(first, text: "stale after reinstall")
    controller.composerDidTapAttach(first)
    controller.composerDidStartVoiceRecording(first)
    #expect(sent.isEmpty && attachments == 0 && recordings == 0)
    controller.composerDidTapSend(second, text: "accepted")
    controller.composerDidTapAttach(second)
    controller.composerDidStartVoiceRecording(second)
    #expect(sent == ["accepted"] && attachments == 1 && recordings == 1)
  }
  #endif

  @Test func composerIsRemovedOnlyForVerifiedAccountExitOrClosure() {
    #expect(SendBlockedNotice.hidesComposer(for: .deviceRemoved, leave: .left))
    for leave in [MLSConversationLeavePresentation.none, .pending, .checking, .left] {
      #expect(SendBlockedNotice.hidesComposer(for: .closed, leave: leave))
    }
    // Pending requests and local device loss are not proof of account departure.
    #expect(!SendBlockedNotice.hidesComposer(for: .healthy, leave: .pending))
    #expect(!SendBlockedNotice.hidesComposer(for: .deviceRemoved, leave: .none))
    #expect(ConversationRecoveryState.deviceRemoved.blocksSending)
    for state in [ConversationRecoveryState.healthy, .recovering, .needsRejoin, .resetPending] {
      #expect(!SendBlockedNotice.hidesComposer(for: state, leave: .none))
      // Even a stale display hint cannot turn an active/recovering session into a terminal one.
      #expect(!SendBlockedNotice.hidesComposer(for: state, leave: .left))
    }
  }

  @Test func removedAndClosedRetainHistoryWithoutOfferingReset() {
    for state in [ConversationRecoveryState.deviceRemoved, .closed] {
      #expect(state.blocksSending)
      #expect(state.allowsRecoveryAttempt == false)
      let notice = SendBlockedNotice.notice(for: state)
      #expect(notice?.showsProgress == false)
      #expect(notice?.offersReset == false)
      #expect(notice?.detail.contains("saved messages") == true)
    }
  }

  @Test func pendingHintDoesNotGrantAccessOrPretendToComplete() {
    #expect(SendBlockedNotice.notice(for: .healthy, leave: .pending)?.title == "Leave requested")
    #expect(SendBlockedNotice.notice(for: .healthy, leave: .checking)?.title == "Checking leave status")
    #expect(SendBlockedNotice.composerPlaceholder(for: .healthy, leave: .pending) == "Message")
    #expect(SendBlockedNotice.notice(for: .closed, leave: .pending)?.title == "Conversation closed")
    #expect(SendBlockedNotice.notice(for: .deviceRemoved, leave: .checking)?.title == "This device no longer has access")
  }

  @Test func verifiedDepartureUsesLeftCopyAndRetainsSendBlock() {
    #expect(ConversationRecoveryState.deviceRemoved.blocksSending)
    #expect(SendBlockedNotice.notice(for: .deviceRemoved, leave: .left)?.title == "You left this conversation")
    #expect(SendBlockedNotice.notice(for: .deviceRemoved, leave: .left)?.offersReset == false)
    #expect(SendBlockedNotice.composerPlaceholder(for: .deviceRemoved, leave: .left) == "You left this conversation")
    #expect(SendBlockedNotice.composerPlaceholder(for: .deviceRemoved, leave: .none) == "No access on this device")
    #expect(SendBlockedNotice.composerPlaceholder(for: .closed, leave: .none) == "Conversation closed")
  }

  @Test func healthyDoesNotBlockSending() {
    #expect(ConversationRecoveryState.healthy.blocksSending == false)
  }

  @Test func transientDetectionStatesDoNotBlockSending() {
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
    let notice = SendBlockedNotice.notice(for: .unrecoverableLocal)
    #expect(notice?.showsProgress == false)
  }

  @Test func inFlightRecoveryNoticeShowsProgress() {
    let notice = SendBlockedNotice.notice(for: .recovering)
    #expect(notice?.showsProgress == true)
  }

  @Test func resetIsOfferedOnlyWhereWaitingCannotHelp() {
    #expect(SendBlockedNotice.notice(for: .unrecoverableLocal)?.offersReset == true)
    #expect(SendBlockedNotice.notice(for: .needsRejoin)?.offersReset == true)
    #expect(SendBlockedNotice.notice(for: .recovering)?.offersReset == false)
    #expect(SendBlockedNotice.notice(for: .resetPending)?.offersReset == false)
  }

  @Test func pendingDeviceAccessPresentationWaitsForVerifiedReadinessAndRetiresOnTerminalState() {
    let notice = SendBlockedNotice.pendingDeviceAccess
    #expect(notice.title == "Waiting for secure access")
    #expect(!notice.offersReset)
    #expect(!notice.detail.contains("failed"))
    for state in [ConversationRecoveryState.deviceRemoved, .closed, .resetPending, .unrecoverableLocal] {
      #expect(!SendBlockedNotice.keepsWaitingForDeviceAccess(state))
    }
    for state in [ConversationRecoveryState.healthy, .groupMissing, .needsRejoin] {
      #expect(SendBlockedNotice.keepsWaitingForDeviceAccess(state))
    }
  }

  @Test func groupRequestTitleUsesOnlyKnownGroupMetadata() {
    #expect(MLSChatRequestPresentation.groupTitle(nil) == "Group chat invitation")
    #expect(MLSChatRequestPresentation.groupTitle("  ") == "Group chat invitation")
    #expect(MLSChatRequestPresentation.groupTitle("Project chat") == "Project chat")
  }

  @MainActor
  @Test func retiredSessionDuringFailedAccessReadCancelsBeforePublishingTheError() async throws {
    enum ReadFailure: Error { case unavailable }
    var isCurrent = true
    var readinessCalls = 0
    var historyLoads = 0
    do {
      _ = try await MLSConversationPipelineAccess.prepare(
        isCurrent: { isCurrent },
        readAccess: {
          await Task.yield()
          isCurrent = false
          throw ReadFailure.unavailable
        },
        ensureReady: { readinessCalls += 1 },
        loadLocalHistory: { historyLoads += 1 })
      Issue.record("An access-read failure from a retired session must cancel")
    } catch is CancellationError { }
    #expect(readinessCalls == 0 && historyLoads == 0)
  }
}
