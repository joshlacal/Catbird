import Testing
import Foundation
import GRDB
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
    let controller = ChatCollectionViewController(dataSource: source,
      navigationPath: .constant(NavigationPath()), appState: appState)
    controller.loadViewIfNeeded()
    var sent: [String] = []
    var attachments = 0
    var recordings = 0
    let config = InlineComposerConfig(onSend: { sent.append($0) },
      onAttachTapped: { attachments += 1 }, onVoiceRecordingStarted: { recordings += 1 })

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

  @Test func resetIsOfferedOnlyWhereWaitingCannotHelp() {
    // A dead local group (unrecoverable / needs rejoin) is what a
    // user-confirmed reset exists for; in-flight states must not offer it.
    #expect(SendBlockedNotice.notice(for: .unrecoverableLocal)?.offersReset == true)
    #expect(SendBlockedNotice.notice(for: .needsRejoin)?.offersReset == true)
    #expect(SendBlockedNotice.notice(for: .recovering)?.offersReset == false)
    #expect(SendBlockedNotice.notice(for: .resetPending)?.offersReset == false)
  }
}


extension MLSSendBlockingTests {
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
}

extension MLSSendBlockingTests {
  @MainActor
  @Test func coldTerminalPipelineLoadsSavedHistoryWithoutReadinessOrRetryFailure() async throws {
    for (stored, state) in [("closed", ConversationRecoveryState.closed), ("device_removed", .deviceRemoved)] {
      let fixture = try ColdTerminalPipelineFixture()
      try fixture.setTerminal(stored)
      #expect(fixture.visibleMessageIDs.isEmpty)
      // Production acquires the crypto manager inside the readiness closure.
      // Even an unavailable manager cannot obstruct known terminal history.
      let result = try await fixture.prepare(readiness: {
        throw MLSConversationPipelineAccess.Failure.managerUnavailable
      })
      #expect(result == .localHistory(.terminal(state)))
      #expect(fixture.readinessCalls == 0)
      #expect(fixture.historyLoads == 1)
      #expect(fixture.visibleMessageIDs == [fixture.messageID])
      try fixture.expectSavedBytesUnchanged()
    }
  }

  @MainActor
  @Test func coldPendingConsentAndActiveConversationUseDifferentPipelinePaths() async throws {
    let pending = try ColdTerminalPipelineFixture(requestState: .pendingInbound)
    #expect(try await pending.prepare(readiness: {
      throw MLSConversationPipelineAccess.Failure.managerUnavailable
    }) == .localHistory(.pendingConsent))
    #expect(pending.readinessCalls == 0 && pending.historyLoads == 1)
    let active = try ColdTerminalPipelineFixture()
    #expect(try await active.prepare() == .ready)
    #expect(active.readinessCalls == 1 && active.historyLoads == 0)

    let unavailable = try ColdTerminalPipelineFixture()
    do {
      _ = try await unavailable.prepare(readiness: {
        throw MLSConversationPipelineAccess.Failure.managerUnavailable
      })
      Issue.record("An active conversation must retain its manager acquisition failure")
    } catch MLSConversationPipelineAccess.Failure.managerUnavailable { }
    #expect(unavailable.readinessCalls == 1 && unavailable.historyLoads == 0)
  }

  @MainActor
  @Test func authorizedTerminalInvitationLoadsConsentHistoryBeforeReadiness() async throws {
    let fixture = try ColdTerminalPipelineFixture(requestState: .pendingInbound)
    try fixture.setTerminal("device_removed")
    try fixture.setPendingPolicy()

    #expect(try await fixture.prepare() == .localHistory(.pendingConsent))
    #expect(fixture.readinessCalls == 0 && fixture.historyLoads == 1)
    #expect(fixture.visibleMessageIDs == [fixture.messageID])
    try fixture.expectSavedBytesUnchanged()
  }

  @MainActor
  @Test func terminalInvitationRequiresAuthorizedPolicyForCurrentAccountConversationGroupAndEpoch() async throws {
    enum Evidence {
      case missing, unauthorized, foreignAccount, foreignConversation, oldGroup, futureEpoch
    }
    for evidence in [Evidence.missing, .unauthorized, .foreignAccount, .foreignConversation, .oldGroup, .futureEpoch] {
      let fixture = try ColdTerminalPipelineFixture(requestState: .pendingInbound)
      try fixture.setTerminal("device_removed")
      switch evidence {
      case .missing: break
      case .unauthorized: try fixture.setPendingPolicy(authorized: false)
      case .foreignAccount: try fixture.setPendingPolicy(userDID: "did:plc:cccccccccccccccccccccccc")
      case .foreignConversation: try fixture.setPendingPolicy(conversationID: "7abfe99f-3990-4880-8d7b-70753820697c")
      case .oldGroup: try fixture.setPendingPolicy(groupID: Data(repeating: 0x42, count: 32))
      case .futureEpoch: try fixture.setPendingPolicy(epoch: 1)
      }

      #expect(try await fixture.prepare() == .localHistory(.terminal(.deviceRemoved)))
      #expect(fixture.readinessCalls == 0 && fixture.historyLoads == 1)
      #expect(fixture.visibleMessageIDs == [fixture.messageID])
      try fixture.expectSavedBytesUnchanged()
    }
  }

  @MainActor
  @Test func malformedAuthorizedInvitationCannotSuppressFailure() async throws {
    let fixture = try ColdTerminalPipelineFixture(requestState: .pendingInbound)
    try fixture.setTerminal("device_removed")
    try fixture.setPendingPolicy()
    try await fixture.database.write { db in
      try db.execute(sql: "UPDATE mls_orchestrator_canonical_policy SET canonical_state_json = ? WHERE user_did = ? AND conversation_id = ?",
        arguments: ["not-json", fixture.scope.userDID, fixture.scope.conversationID])
    }

    do {
      _ = try await fixture.prepare()
      Issue.record("Malformed authorized policy must remain a failure")
    } catch is DecodingError { }
    #expect(fixture.readinessCalls == 0 && fixture.historyLoads == 0)
    #expect(fixture.visibleMessageIDs.isEmpty)
    try fixture.expectSavedBytesUnchanged()
  }

  @MainActor
  @Test func terminalArrivalDuringReadinessReplacesBothSuccessAndFailureWithLocalHistory() async throws {
    enum ReadinessFailure: Error { case unavailable }
    for throwsAfterTerminal in [false, true] {
      let fixture = try ColdTerminalPipelineFixture()
      let result = try await fixture.prepare(readiness: {
        await Task.yield()
        try fixture.setTerminal("device_removed")
        if throwsAfterTerminal { throw ReadinessFailure.unavailable }
      })
      #expect(result == .localHistory(.terminal(.deviceRemoved)))
      #expect(fixture.readinessCalls == 1 && fixture.historyLoads == 1)
      #expect(fixture.visibleMessageIDs == [fixture.messageID])
      try fixture.expectSavedBytesUnchanged()
    }
  }

  @MainActor
  @Test func missingMalformedAndUnreadableTerminalEvidenceCannotSuppressFailure() async throws {
    for mode in 0..<3 {
      let fixture = try ColdTerminalPipelineFixture()
      if mode == 0 {
        try await fixture.database.write { db in
          try db.execute(sql: "DELETE FROM MLSConversationModel WHERE conversationID = ?", arguments: [fixture.scope.conversationID])
        }
      } else if mode == 1 {
        try fixture.setTerminal("unknown")
      } else {
        try await fixture.database.write { try $0.execute(sql: "DROP TABLE mls_orchestrator_terminal_access") }
      }
      do {
        _ = try await fixture.prepare()
        Issue.record("Missing or unreadable local evidence must remain a failure")
      } catch is CancellationError {
        Issue.record("Unknown evidence is a failure, not a retired session")
      } catch { }
      #expect(fixture.readinessCalls == 0 && fixture.historyLoads == 0)
    }

    let fixture = try ColdTerminalPipelineFixture()
    do {
      _ = try await fixture.prepare(readiness: { throw MLSAPIError.httpError(statusCode: 400, message: "closed") })
      Issue.record("A server error cannot substitute for local terminal proof")
    } catch let MLSAPIError.httpError(statusCode, _) {
      #expect(statusCode == 400)
    }
    #expect(fixture.readinessCalls == 1 && fixture.historyLoads == 0)
  }

  @MainActor
  @Test func pipelineTerminalProofIsBoundToExactAccountConversationAndGroup() async throws {
    let fixture = try ColdTerminalPipelineFixture()
    try fixture.setTerminal("closed", userDID: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb")
    try fixture.setTerminal("closed", conversationID: "7abfe99f-3990-4880-8d7b-70753820697c")
    try fixture.setTerminal("closed", groupID: Data(repeating: 0x42, count: 32))
    #expect(try await fixture.prepare() == .ready)
    #expect(fixture.readinessCalls == 1 && fixture.historyLoads == 0)
  }

  @MainActor
  @Test func retiredAccountOrChangedGroupCannotPublishALateReadinessOutcome() async throws {
    for changesGroup in [false, true] {
      for readinessFails in [false, true] {
        let fixture = try ColdTerminalPipelineFixture()
        do {
          _ = try await fixture.prepare(readiness: {
            await Task.yield()
            if changesGroup {
              try fixture.changeGroup()
            } else {
              fixture.isCurrent = false
            }
            if readinessFails { throw MLSConversationError.groupNotInitialized }
          })
          Issue.record("The old attempt must retire after account or group replacement")
        } catch is CancellationError { }
        #expect(fixture.readinessCalls == 1 && fixture.historyLoads == 0)
        try fixture.expectSavedBytesUnchanged()
      }
    }
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

  @MainActor
  @Test func accountGroupOrTerminalChangesDuringHistoryLoadRetireTheResult() async throws {
    enum Change { case account, group, terminal }
    for change in [Change.account, .group, .terminal] {
      let fixture = try ColdTerminalPipelineFixture()
      try fixture.setTerminal("device_removed")
      do {
        _ = try await fixture.prepare(history: {
          await Task.yield()
          switch change {
          case .account: fixture.isCurrent = false
          case .group: try fixture.changeGroup()
          case .terminal: try fixture.setTerminal("closed")
          }
        })
        Issue.record("A history load must not publish retired account, group, or terminal evidence")
      } catch is CancellationError { }
      #expect(fixture.readinessCalls == 0 && fixture.historyLoads == 1)
      try fixture.expectSavedBytesUnchanged()
    }
  }
}

@MainActor
private final class ColdTerminalPipelineFixture {
  let database: DatabaseQueue
  let scope = MLSConversationPipelineAccess.Scope(
    userDID: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
    conversationID: "c38da5c7-6e64-4c06-b063-65c0a1d4fd99",
    groupID: Data(repeating: 0x31, count: 32))
  let messageID = "f63bcba8-f209-400a-96c8-c7d6bf01b4e1"
  let ciphertext = Data([0x11, 0x22, 0x33, 0x44])
  let hmac = Data([0x55, 0x66, 0x77])
  var isCurrent = true
  var readinessCalls = 0
  var historyLoads = 0
  var visibleMessageIDs: [String] = []

  init(requestState: MLSRequestState = .none) throws {
    database = try DatabaseQueue()
    try MLSGRDBManager.makeMigrator().migrate(database)
    try database.write { db in
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS mls_orchestrator_terminal_access (
          user_did TEXT NOT NULL, conversation_id TEXT NOT NULL,
          group_id BLOB NOT NULL, state TEXT NOT NULL,
          PRIMARY KEY(user_did, conversation_id))
        """)
      try MLSConversationModel(conversationID: scope.conversationID, currentUserDID: scope.userDID,
        groupID: scope.groupID, requestState: requestState).insert(db)
      try MLSMessageModel(messageID: messageID, currentUserDID: scope.userDID,
        conversationID: scope.conversationID, senderID: scope.userDID, epoch: 0, sequenceNumber: 1,
        payloadEncrypted: ciphertext, entryHMAC: hmac).insert(db)
    }
  }

  func setTerminal(_ state: String, userDID: String? = nil, conversationID: String? = nil, groupID: Data? = nil) throws {
    try database.write { db in
      try db.execute(sql: "INSERT OR REPLACE INTO mls_orchestrator_terminal_access VALUES (?, ?, ?, ?)",
        arguments: [userDID ?? scope.userDID, conversationID ?? scope.conversationID, groupID ?? scope.groupID, state])
    }
  }

  func changeGroup() throws {
    try database.write { db in
      try db.execute(sql: "UPDATE MLSConversationModel SET groupID = ? WHERE currentUserDID = ? AND conversationID = ?",
        arguments: [Data(repeating: 0x42, count: 32), scope.userDID, scope.conversationID])
    }
  }

  func setPendingPolicy(authorized: Bool = true, userDID: String? = nil,
                        conversationID: String? = nil, groupID: Data? = nil, epoch: Int = 0) throws {
    let account = userDID ?? scope.userDID
    let conversation = conversationID ?? scope.conversationID
    let group = groupID ?? scope.groupID
    let admin = try DID(didString: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb")
    let device = "750e8400-e29b-41d4-a716-446655440000"
    let transition = "650e8400-e29b-41d4-a716-446655440000"
    let key = "NHUPmL1Z_PyUbaRaqr6TO-FUpLUJThxKv0KGZQXzyX4"
    let contextHash = Bytes(data: Data(repeating: 0xcd, count: 32))
    let confirmation = Bytes(data: Data(repeating: 0xef, count: 32))
    var uuid = try #require(UUID(uuidString: conversation)).uuid
    let conversationBytes = withUnsafeBytes(of: &uuid) { Data($0) }
    let participants = [
      BlueCatbirdChatDefs.ParticipantView(userDid: try DID(didString: account), role: .value_member,
        status: .value_pending, invitationProvenance: .init(invitationTransitionId: transition,
          invitedByDid: admin, invitedByDeviceId: device), leafCount: 0),
      BlueCatbirdChatDefs.ParticipantView(userDid: admin, role: .value_admin, status: .value_active,
        invitationProvenance: nil, leafCount: 1)
    ].sorted { $0.userDid.description.utf8.lexicographicallyPrecedes($1.userDid.description.utf8) }
    let state = BlueCatbirdChatDefs.ConversationState(conversationKind: .value_group,
      coordinates: .init(conversationId: conversation, generation: 0, stateVersion: 1,
        groupId: Bytes(data: group), epoch: epoch, groupContextHash: contextHash,
        confirmationTag: confirmation, lifecycle: .value_active),
      cipherSuite: .value_MLS_u5f_256_u5f_XWING_u5f_CHACHA20POLY1305_u5f_SHA256_u5f_Ed25519,
      participants: participants,
      leaves: [.init(userDid: admin, deviceId: device, leafOrigin: .value_genesis,
        joinKeyPackageRef: nil, keyId: key, deviceStatus: .value_active)],
      metadataSnapshot: .init(coordinate: .init(conversationId: Bytes(data: conversationBytes),
        generation: 0, groupId: Bytes(data: group), epoch: epoch, groupContextHash: contextHash,
        confirmationTag: confirmation), originTransitionId: transition, metadataVersion: 1,
        nonce: Bytes(data: Data(repeating: 7, count: 12)), ciphertext: Bytes(data: Data(repeating: 0x42, count: 32)),
        ciphertextSha256: Bytes(data: try #require(Data(base64Encoded: "Ql7U5KNrMOohuQ4hxxLGSeghTCm36vaAidEDnG5VOEw="))),
        ciphertextSize: 32, avatarBinding: nil,
        authorProof: .init(authorDid: admin, authorDeviceId: device, authorKeyId: key,
          signaturePublicKey: Bytes(data: try #require(Data(base64Encoded: "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w="))),
          authGenerationAtOrigin: 1, originTransitionId: transition, originSeq: 1,
          roleAtOrigin: "admin", deviceStatusAtOrigin: "active")),
      snapshotSeq: 1, sequencerDid: nil, sequencerTerm: nil)
    let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    try database.write { db in
      let model = MLSConversationModel(conversationID: conversation, currentUserDID: account,
        groupID: group, epoch: Int64(epoch), requestState: .pendingInbound)
      let prepared = try MLSCanonicalPolicyProjection.prepare(json, existing: model, in: db)
      let update = try #require(prepared)
      // This persisted bit represents native invitation verification at the app's storage boundary.
      try MLSCanonicalPolicyProjection.persist(update, userDID: account,
        terminalInvitationAuthorized: authorized, in: db)
    }
  }

  func prepare(history: () async throws -> Void = {},
               readiness: () async throws -> Void = {}) async throws -> MLSConversationPipelineAccess.Preparation {
    try await MLSConversationPipelineAccess.prepare(
      isCurrent: { self.isCurrent },
      readAccess: { try self.database.read { try MLSConversationPipelineAccess.read(in: $0, scope: self.scope) } },
      ensureReady: { self.readinessCalls += 1; try await readiness() },
      loadLocalHistory: {
        self.historyLoads += 1
        do {
          self.visibleMessageIDs = try await self.database.read { db in
            try MLSMessageModel.filter(MLSMessageModel.Columns.currentUserDID == self.scope.userDID)
              .filter(MLSMessageModel.Columns.conversationID == self.scope.conversationID).fetchAll(db).map(\.messageID)
          }
          try await history()
        } catch { Issue.record("Saved history could not be read: \(error)") }
      })
  }

  func expectSavedBytesUnchanged() throws {
    let message = try database.read { db in
      try MLSMessageModel.filter(MLSMessageModel.Columns.messageID == messageID).fetchOne(db)
    }
    #expect(message?.payloadEncrypted == ciphertext)
    #expect(message?.entryHMAC == hmac)
  }
}
