//
//  MLSDiagnosticsPanel.swift
//  Catbird
//
//  TEMPORARY — sprint/messaging investigation (Task #1: cross-platform DM send failures).
//  A read-only debug panel that surfaces the live MLS state for a single conversation so
//  Android↔iOS send/delivery failures can be diagnosed in-app without attaching a debugger.
//
//  This file is gated behind `#if DEBUG` and is intended to be removed once the
//  investigation concludes. It does NOT mutate any MLS state — every value is read from
//  the existing public surface of `MLSConversationManager`.
//
//  REMOVE-AFTER: cross-platform DM RCA closed (see docs/sprint-polish/messaging-investigation.md).
//

#if DEBUG

import CatbirdMLSCore
import Observation
import OSLog
import Petrel
import SwiftUI

/// Snapshot of the diagnostic-relevant MLS state for one conversation.
///
/// The three epoch values are the core diagnostic: when they disagree, the conversation is
/// in (or heading toward) the divergence that drives the server-side groupInfo-404 auto-reset
/// loop and 409 send failures.
struct MLSConversationDiagnostics: Sendable {
  /// Server-reported epoch from the cached `ConvoView` (last `getConvos`).
  var serverViewEpoch: Int?
  /// Local OpenMLS epoch tracked in `groupStates` (FFI ground truth, populated by sync).
  var ffiTrackedEpoch: UInt64?
  /// Last server epoch the client recorded for GroupInfo-upload gating.
  var knownServerEpoch: UInt64?
  /// Server-side reset generation surfaced on the `ConvoView` — climbs each auto-reset.
  var resetGeneration: Int?
  /// Group ID hex prefix (changes on every system reset).
  var groupIdPrefix: String?
  /// Member count from the cached `ConvoView`.
  var convoMemberCount: Int?
  /// Member count from `groupStates` (FFI view).
  var ffiMemberCount: Int?
  /// Per-conversation send-queue depth (pending serialized sends).
  var sendQueueDepth: Int?
  /// Count of locally-staged optimistic messages still awaiting confirmation.
  var pendingOutboundCount: Int
  /// Whether a sync pass is currently running.
  var isSyncing: Bool
  /// Whether sync is paused (e.g. account switch in progress).
  var isSyncPaused: Bool
  /// Whether a rejoin is in progress, and for which conversation.
  var rejoinInProgress: Bool
  var rejoinConversationPrefix: String?
  /// Whether this conversation is present in the manager's in-memory map at all.
  var conversationKnownLocally: Bool
  /// Whether the FFI reports the underlying MLS group as existing.
  var groupExistsInFFI: Bool?
  /// Persistent decryption-failure strikes for this conversation (drives nuclear rejoin).
  var persistentDecryptFailures: Int

  /// `true` when the server-view epoch and the FFI epoch disagree — the canonical "stuck"
  /// signature behind 409 send failures and missing inbound messages.
  var epochDiverged: Bool {
    guard let server = serverViewEpoch, let ffi = ffiTrackedEpoch else { return false }
    return Int64(server) != Int64(ffi)
  }
}

/// Read-only collector. Reads the public surface of `MLSConversationManager`; never mutates.
enum MLSDiagnosticsCollector {
  static func collect(
    manager: MLSConversationManager,
    conversationId: String,
    pendingOutboundCount: Int
  ) async -> MLSConversationDiagnostics {
    let convo = manager.conversations[conversationId]
    let groupState = manager.groupStates[conversationId]

    var groupExists: Bool?
    if let userDid = manager.currentUserDID,
      let groupIdHex = convo?.groupId,
      let groupIdData = Data(hexEncoded: groupIdHex) {
      groupExists = await manager.mlsClient.groupExists(for: userDid, groupId: groupIdData)
    }

    let queueDepth = await manager.sendQueueCoordinator.getQueueDepth(
      conversationID: conversationId)

    let rejoinActive = manager.rejoinInProgress.withLock { $0 }
    let rejoinConvo = manager.rejoinInProgressConversationID.withLock { $0 }
    let decryptFailures = manager.persistentDecryptionFailures.withLock { $0[conversationId] ?? 0 }

    return MLSConversationDiagnostics(
      serverViewEpoch: convo?.epoch,
      ffiTrackedEpoch: groupState?.epoch,
      knownServerEpoch: groupState?.knownServerEpoch,
      resetGeneration: convo?.resetGeneration,
      groupIdPrefix: convo.map { String($0.groupId.prefix(12)) },
      convoMemberCount: convo?.members.count,
      ffiMemberCount: groupState?.members.count,
      sendQueueDepth: queueDepth,
      pendingOutboundCount: pendingOutboundCount,
      isSyncing: manager.isSyncing,
      isSyncPaused: manager.isSyncPaused,
      rejoinInProgress: rejoinActive,
      rejoinConversationPrefix: rejoinConvo.map { String($0.prefix(12)) },
      conversationKnownLocally: convo != nil,
      groupExistsInFFI: groupExists,
      persistentDecryptFailures: decryptFailures
    )
  }
}

/// A compact, refreshable debug panel for one conversation's MLS state.
///
/// Present it as a sheet from the conversation detail view (debug builds only). It refreshes
/// on appear and via a manual button so an investigator can watch epoch/queue/sync state change
/// in real time while reproducing a send failure.
struct MLSDiagnosticsPanel: View {
  let conversationId: String
  /// Closure that fetches the live manager lazily (matches `appState.getMLSConversationManager`).
  let managerProvider: () async -> MLSConversationManager?
  /// Snapshot of locally-staged optimistic messages count, supplied by the host view.
  let pendingOutboundCount: Int

  @State private var diagnostics: MLSConversationDiagnostics?
  @State private var lastRefresh: Date?
  @State private var isRefreshing = false

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let diag = diagnostics {
          epochSection(diag)
          deliverySection(diag)
          syncSection(diag)
          membershipSection(diag)
        } else {
          Section {
            HStack {
              ProgressView()
              Text("Collecting MLS state…")
                .foregroundStyle(.secondary)
            }
          }
        }

        Section {
          if let lastRefresh {
            LabeledContent("Snapshot at", value: lastRefresh.formatted(date: .omitted, time: .standard))
          }
          Text("Conversation ID")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(conversationId)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
        } header: {
          Text("Context")
        } footer: {
          Text("Debug-only panel (sprint/messaging). Read-only; does not change MLS state.")
        }
      }
      .navigationTitle("MLS Diagnostics")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button {
            Task { await refresh() }
          } label: {
            if isRefreshing {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(isRefreshing)
          .accessibilityLabel("Refresh MLS diagnostics")
        }
      }
      .task { await refresh() }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private func epochSection(_ diag: MLSConversationDiagnostics) -> some View {
    Section {
      diagnosticRow("Server-view epoch", value: diag.serverViewEpoch.map(String.init) ?? "—")
      diagnosticRow("FFI local epoch", value: diag.ffiTrackedEpoch.map(String.init) ?? "—")
      diagnosticRow("Known server epoch", value: diag.knownServerEpoch.map(String.init) ?? "—")
      diagnosticRow("Reset generation", value: diag.resetGeneration.map(String.init) ?? "—")
      diagnosticRow("Group ID", value: diag.groupIdPrefix ?? "—", monospaced: true)
    } header: {
      HStack {
        Text("Epoch")
        if diag.epochDiverged {
          Spacer()
          Label("DIVERGED", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
    } footer: {
      if diag.epochDiverged {
        Text("Server-view and FFI epochs disagree — sends will 409 and inbound messages may stall until commit catch-up or rejoin resolves the gap.")
          .foregroundStyle(.red)
      } else {
        Text("Three-way epoch comparison. Divergence is the canonical 'stuck conversation' signature.")
      }
    }
  }

  @ViewBuilder
  private func deliverySection(_ diag: MLSConversationDiagnostics) -> some View {
    Section("Outbound") {
      diagnosticRow("Send-queue depth", value: diag.sendQueueDepth.map(String.init) ?? "—")
      diagnosticRow("Pending optimistic", value: String(diag.pendingOutboundCount))
      diagnosticRow(
        "Persistent decrypt failures",
        value: String(diag.persistentDecryptFailures),
        warn: diag.persistentDecryptFailures > 0)
    }
  }

  @ViewBuilder
  private func syncSection(_ diag: MLSConversationDiagnostics) -> some View {
    Section("Sync / Recovery") {
      diagnosticRow("Syncing", value: diag.isSyncing ? "yes" : "no")
      diagnosticRow("Sync paused", value: diag.isSyncPaused ? "yes" : "no", warn: diag.isSyncPaused)
      diagnosticRow(
        "Rejoin in progress",
        value: diag.rejoinInProgress ? (diag.rejoinConversationPrefix ?? "yes") : "no",
        warn: diag.rejoinInProgress)
    }
  }

  @ViewBuilder
  private func membershipSection(_ diag: MLSConversationDiagnostics) -> some View {
    Section("Membership / Presence") {
      diagnosticRow("Known locally", value: diag.conversationKnownLocally ? "yes" : "no", warn: !diag.conversationKnownLocally)
      diagnosticRow(
        "Group exists in FFI",
        value: diag.groupExistsInFFI.map { $0 ? "yes" : "no" } ?? "—",
        warn: diag.groupExistsInFFI == false)
      diagnosticRow("Members (server view)", value: diag.convoMemberCount.map(String.init) ?? "—")
      diagnosticRow("Members (FFI view)", value: diag.ffiMemberCount.map(String.init) ?? "—")
    }
  }

  // MARK: - Row helper

  @ViewBuilder
  private func diagnosticRow(
    _ label: String, value: String, monospaced: Bool = false, warn: Bool = false
  ) -> some View {
    LabeledContent {
      Text(value)
        .font(monospaced ? .system(.body, design: .monospaced) : .body)
        .foregroundStyle(warn ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    } label: {
      Text(label)
    }
  }

  // MARK: - Refresh

  private func refresh() async {
    isRefreshing = true
    defer { isRefreshing = false }
    guard let manager = await managerProvider() else {
      diagnostics = nil
      return
    }
    let collected = await MLSDiagnosticsCollector.collect(
      manager: manager,
      conversationId: conversationId,
      pendingOutboundCount: pendingOutboundCount
    )
    diagnostics = collected
    lastRefresh = Date()
  }
}

#endif
