import AuthenticationServices
import CatbirdMLSCore
import CryptoKit
import OSLog
import PetrelCatbird
import SwiftCBOR
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Scroll targets for the outcome rows at the top of the Labyrinth settings form.
enum LabyrinthResultAnchor {
  static let error = "labyrinth-result-error"
  static let warning = "labyrinth-result-warning"
  static let success = "labyrinth-result-success"
}

/// Labyrinth 1.1 backup, recovery code, WebAuthn Passkey PRF, hybrid PQ `OTC` pairing,
/// device revocation, and Space history import screen (`Spec §6.7`, `D4`, `I16`).
@MainActor
struct LabyrinthSettingsAndRestoreView: View {
  let coordinator: MLSClientCoordinator?
  var currentDeviceId: String? = nil
  var deviceMetadataByID: [String: DeviceRowModel] = [:]

  @Environment(AppState.self) private var appState: AppState?
  @State private var status: LabyrinthBackupStatus?
  @State private var isPendingDeviceApproval = false
  @State private var approvalState: DeviceApprovalState?
  @State private var fetchedDeviceMetadataByID: [String: DeviceRowModel] = [:]
  @State private var isLoading = false
  @State private var generatedRecoveryCode: String?
  @State private var restoreCodeInput = ""
  @State private var activeOtcOffer: OtcPairingOffer?
  @State private var initiatedOtcSession: OtcInitiatedSession?
  @State private var joinOtcCodeInput = ""
  @State private var respondOtcSessionIdInput = ""
  @State private var respondOtcCodeInput = ""
  @State private var lastOtcCompletion: OtcPairingCompletion?
  @State private var importConversationId = ""
  @State private var importedCount: UInt32?
  @State private var statusBanner: String?
  @State private var warningBanner: String?
  @State private var errorMessage: String?
  @State private var revocationReceipt: AppState.PendingMLSDeviceRevocationReceipt?
  @State private var recoveryCodeReceipt: AppState.PendingMLSRecoveryCodeReceipt?
  @State private var confirmedRevokedDeviceSecured = false
  @State private var hasUnversionedReceipt = false
  @State private var lastFlushOutcome: MLSBackupFlushOutcome?

  private let logger = Logger(subsystem: "blue.catbird", category: "LabyrinthUI")

  var body: some View {
    ScrollViewReader { proxy in
      form
        .onChange(of: errorMessage) { _, message in
          if let message {
            // The engine's own error text: endpoints and status codes, not secrets.
            logger.error("Labyrinth settings action failed: \(message, privacy: .public)")
          }
          reveal(LabyrinthResultAnchor.error, when: message, with: proxy)
        }
        .onChange(of: warningBanner) { _, message in
          reveal(LabyrinthResultAnchor.warning, when: message, with: proxy)
        }
        .onChange(of: statusBanner) { _, message in
          reveal(LabyrinthResultAnchor.success, when: message, with: proxy)
        }
    }
  }

  /// Scrolls the form to an outcome row that has just appeared or changed.
  private func reveal(_ anchor: String, when message: String?, with proxy: ScrollViewProxy) {
    guard message != nil else { return }
    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
  }

  private var form: some View {
    Form {
      if isPendingDeviceApproval {
        Section {
          if let approvalCopy {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text(approvalCopy.title)
                  .font(.footnote.weight(.semibold))
                Text(approvalCopy.message)
                  .font(.footnote)
              }
            } icon: {
              Image(systemName: "lock.trianglebadge.exclamationmark.fill")
            }
            .foregroundStyle(.orange)
          } else {
            Label(
              "This device is waiting for approval. Approve it from another approved device in Settings > Devices, restore your backup below, or pair it with a 6-digit code.",
              systemImage: "lock.trianglebadge.exclamationmark.fill"
            )
            .foregroundStyle(.orange)
            .font(.footnote)
          }
        }
        .accessibilityIdentifier("labyrinth-device-pending-approval-banner")
      }

      // The outcome of the last action sits at the top, where it can be seen. Below the
      // seven sections that follow, a failed tap looked like a button that did nothing.
      if let warningBanner {
        Section {
          Label(warningBanner, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.footnote)
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recovery warning: \(warningBanner)")
            .accessibilityIdentifier("labyrinth-warning-status")
            .id(LabyrinthResultAnchor.warning)
      }

      if let statusBanner {
        Section {
          Label(statusBanner, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.footnote)
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Success: \(statusBanner)")
            .accessibilityIdentifier("labyrinth-success-status")
            .id(LabyrinthResultAnchor.success)
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(errorMessage)")
            .accessibilityIdentifier("labyrinth-error-status")
            .id(LabyrinthResultAnchor.error)
      }

      if needsRestoreFirst {
        restoreFirstSection
      }
      backupStatusSection
      if !needsRestoreFirst {
        recoveryWarningsSection
        passkeyPrfSection
      }
      otcPairingSection
      recoveryCodeSection
      deviceListSection
      historyImportSection
    }
    .navigationTitle("Labyrinth Backup & Recovery")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    // Keyed by account: the engine can arrive after this screen is on show (it opens a
    // few seconds after launch), and an unkeyed task would never load its status.
    .task(id: coordinator?.accountDidHash) { await refreshStatus() }
    .refreshable { await refreshStatus() }
    .overlay(alignment: .bottom) { workingIndicator }
    .animation(.default, value: isLoading)
    .onChange(of: appState?.pendingMLSDeviceRevocationReceipt) { _, _ in
      Task { await refreshRecoveryMaterial() }
    }
    .onChange(of: appState?.pendingMLSRecoveryCodeReceipt) { _, _ in
      Task { await refreshRecoveryMaterial() }
    }
    .onChange(of: coordinator?.changeRevision) { _, _ in
      if case .labyrinthStatusChanged = coordinator?.lastChangeEvent {
        Task { await refreshRecoveryMaterial() }
      }
    }
    .sheet(item: $revocationReceipt) { receipt in
      DeviceRevocationReceiptSheet(receipt: receipt) {
        guard let coordinator, let generation = receipt.recoveryGeneration, generation > 0 else { return false }
        var acknowledgedStatus: LabyrinthBackupStatus?
        if let appState {
          guard await appState.acknowledgePendingMLSDeviceRevocationReceipt(
            expected: receipt, nativeAcknowledger: {
              acknowledgedStatus = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
            }
          ) else {
            return false
          }
        } else {
          do {
            acknowledgedStatus = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
            guard try AppState.loadPendingMLSDeviceRevocationReceipt(forDID: coordinator.accountDid) == receipt else { return false }
            try AppState.clearPendingMLSDeviceRevocationReceipt(forDID: coordinator.accountDid)
          } catch {
            return false
          }
        }
        self.status = acknowledgedStatus
        self.revocationReceipt = nil
        await self.refreshRecoveryMaterial()
        return true
      }
    }
    .accessibilityIdentifier("labyrinth-settings-and-restore-view")
  }

  /// Backup actions wait on the server, sometimes for most of a minute, and every button
  /// is disabled meanwhile. Without this a tap looked like it did nothing.
  @ViewBuilder
  private var workingIndicator: some View {
    if isLoading, status != nil {
      HStack(spacing: 10) {
        ProgressView()
        Text("Working… this can take up to a minute.")
          .font(.footnote)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: Capsule())
      .padding(.bottom, 12)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("labyrinth-working-indicator")
      .transition(.opacity)
    }
  }

  /// The state that decides which buttons on this screen are enabled. No keys, codes or
  /// tokens: flags, counters and the engine's own publication error.
  private func supportDetails(_ status: LabyrinthBackupStatus) -> String {
    [
      "action running: \(isLoading), established: \(status.archiveEstablished)",
      "attention: \(status.recoveryNeedsAttention), generation set: \(status.recoveryGeneration > 0)",
      "code receipt: \(recoveryCodeReceipt != nil), revocation receipt: \(revocationReceipt != nil), unversioned: \(hasUnversionedReceipt)",
      "pending approval: \(isPendingDeviceApproval), devices: \(status.activeDeviceIds.count)",
      "mailbox space: \(status.mailboxSpaceUri)",
      "directory pending: \(status.pendingDirectoryEpoch.map { String($0) } ?? "none"), stalled: \(status.directoryPublicationStalled), retries: \(status.directoryPublicationRetryCount)",
      "directory error: \(status.directoryPublicationError ?? "none")",
    ].joined(separator: "\n")
  }

  /// "On" only once the engine has opened or created this account's archive on the server.
  /// A new account's local default says enabled before anything exists anywhere.
  nonisolated static func backupStatusLabel(enabled: Bool, established: Bool) -> String {
    guard enabled else {
      return String(localized: "Off")
    }
    return established
      ? String(localized: "On", comment: "Labyrinth encrypted backup status when active and established")
      : String(localized: "Setting Up", comment: "Labyrinth encrypted backup status before initial archive creation")
  }

  private var lastBackupAttemptLabel: String {
    guard let outcome = lastFlushOutcome else {
      return String(localized: "Not Run Yet", comment: "Labyrinth last backup attempt status before any backup has run")
    }
    let time = outcome.date.formatted(date: .omitted, time: .shortened)
    return outcome.failure == nil
      ? String(localized: "Completed \(time)", comment: "Labyrinth last backup attempt status on success. %@ is the formatted time.")
      : String(localized: "Failed \(time)", comment: "Labyrinth last backup attempt status on failure. %@ is the formatted time.")
  }

  private var lastBackupAttemptColor: Color {
    guard let outcome = lastFlushOutcome else { return .secondary }
    return outcome.failure == nil ? .green : .red
  }

  /// The account this screen is acting on: its handle when it is the signed-in account,
  /// otherwise its DID. Backup state is per account and easy to mistake after a switch.
  private func accountLabel(for coordinator: MLSClientCoordinator) -> String {
    if let appState, appState.userDID == coordinator.accountDid,
       let handle = appState.currentUserProfile?.handle.description, !handle.isEmpty {
      return "@" + handle
    }
    return coordinator.accountDid
  }

  private var backupStatusSection: some View {
    Section("Encrypted Spaces Backup") {
      if let coordinator {
        LabeledContent("Account") {
          Text(verbatim: accountLabel(for: coordinator))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .accessibilityIdentifier("labyrinth-account")
      }
      if let status, needsRestoreFirst {
        DisclosureGroup("Details for Support") {
          Text(verbatim: supportDetails(status))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-support-details")
        }
      } else if let status {
        LabeledContent("Status") {
          Text(Self.backupStatusLabel(enabled: status.backupEnabled, established: status.archiveEstablished))
            .foregroundStyle(status.backupEnabled && status.archiveEstablished ? .green : .secondary)
        }
        .accessibilityIdentifier("labyrinth-backup-status")
        if status.backupEnabled && !status.archiveEstablished {
          Text("Nothing is stored on your server yet. Backup starts with your first encrypted message, or when you create a recovery code.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if status.archiveEstablished {
          LabeledContent("Labyrinth Epoch") {
            Text(status.epochSeq, format: .number)
              .monospacedDigit()
          }
        }
        LabeledContent("Recovery Code Saved") {
          if hasUnacknowledgedRecoveryAttention {
            Text("Needs a New Code").foregroundStyle(.orange)
          } else if status.hasRecoveryCode {
            Text("Yes").foregroundStyle(.green)
          } else {
            Text("Optional (Not Set)").foregroundStyle(.secondary)
          }
        }
        LabeledContent("Passkey PRF Linked") {
          if hasUnacknowledgedRecoveryAttention {
            Text("Set Up Again After a New Code").foregroundStyle(.orange)
          } else if status.hasPasskeyPrf {
            Text("Yes").foregroundStyle(.green)
          } else {
            Text("Not Configured").foregroundStyle(.secondary)
          }
        }
        LabeledContent("Last Backup Attempt") {
          Text(lastBackupAttemptLabel)
            .foregroundStyle(lastBackupAttemptColor)
        }
        .accessibilityIdentifier("labyrinth-last-backup-attempt")
        if let failure = lastFlushOutcome?.failure {
          // The engine's own error text: endpoints and status codes, not secrets.
          Text(verbatim: failure)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-last-backup-failure")
        }
        DisclosureGroup("Details for Support") {
          Text(verbatim: supportDetails(status))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-support-details")
        }
      } else if coordinator == nil {
        Text("Enable MLS Encrypted Chat on an ATProto Spaces account to manage Labyrinth backups.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        ProgressView("Loading Labyrinth status...")
      }
    }
  }

  @ViewBuilder
  private var recoveryWarningsSection: some View {
    if let status,
       hasUnacknowledgedRecoveryAttention || status.recoveryMethodStale || !status.rotationExclusions.isEmpty
    {
      Section {
        if hasUnacknowledgedRecoveryAttention
          && !hasPersistedDeviceRevocationReceipt
          && !hasPersistedRecoveryCodeReceipt
        {
          Label(
            "Encrypted-backup recovery was rotated, but the one-time replacement details are no longer available on this device. Generate a new recovery code below. Recovery remains not ready until you save and explicitly acknowledge the new code.",
            systemImage: "key.slash.fill"
          )
          .foregroundStyle(.red)
          .font(.footnote)
          .accessibilityIdentifier("labyrinth-unavailable-recovery-material-warning")
        }

        if hasUnacknowledgedRecoveryAttention && hasPersistedRecoveryCodeReceipt {
          Label(
            "A replacement recovery code is stored securely on this device. Save it and confirm below before recovery can become ready.",
            systemImage: "key.fill"
          )
          .foregroundStyle(.orange)
          .font(.footnote)
          .accessibilityIdentifier("labyrinth-pending-recovery-code-warning")
        }

        if status.recoveryMethodStale {
          Label(
            "This keychain or passkey recovery method is older than 180 days. It still works, but recreate it before the next recovery rotation.",
            systemImage: "clock.badge.exclamationmark"
          )
          .foregroundStyle(.orange)
          .font(.footnote)
          .accessibilityLabel(
            "Recovery warning: This recovery method is older than 180 days. Recreate it before the next rotation."
          )
          .accessibilityIdentifier("labyrinth-stale-recovery-warning")
        }

        ForEach(Array(status.rotationExclusions.enumerated()), id: \.offset) { offset, exclusion in
          let method = exclusion.recoveryMethod?.localizedCapitalized
            ?? String(localized: "Device", comment: "Fallback recovery method name when a device key is excluded during rotation")
          VStack(alignment: .leading, spacing: 4) {
            Label(
              "\(method) recovery was removed during rotation",
              systemImage: "key.slash.fill"
            )
            .foregroundStyle(.red)

            Text("Reason: \(exclusion.reason.replacingOccurrences(of: "-", with: " "))")
              .font(.caption)
              .foregroundStyle(.secondary)

            if let deviceKey = exclusion.deviceKeyHex {
              Text("Device key: \(deviceKey)")
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(method) recovery removed during rotation. Reason: \(exclusion.reason.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))."
          )
          .accessibilityIdentifier("labyrinth-rotation-exclusion-\(offset)")
        }
      } header: {
        Text("Recovery Attention Required")
      } footer: {
        Text("Generate and save a new recovery code below, then register a new passkey recovery method if needed.")
      }
    }
  }

  private var recoveryCodeSection: some View {
    Section {
      if !needsRestoreFirst {
        Button {
          self.generateRecoveryCode()
        } label: {
          Label("Generate 40-Character Recovery Code", systemImage: "key.fill")
        }
        .disabled(
          coordinator == nil || status == nil || isLoading
            || hasPersistedDeviceRevocationReceipt || hasPersistedRecoveryCodeReceipt
        )
        .accessibilityIdentifier("labyrinth-generate-recovery-code")
      }

      if let generatedRecoveryCode {
        VStack(alignment: .leading, spacing: 6) {
          Text("Save this 40-character recovery code in your password manager:")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: generatedRecoveryCode)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-generated-recovery-code")
        }
        .padding(.vertical, 4)

        if recoveryCodeReceipt?.requiresDeviceSafetyConfirmation == true {
          Toggle(
            "I removed or secured every device I no longer control",
            isOn: $confirmedRevokedDeviceSecured
          )
          .accessibilityIdentifier("labyrinth-confirm-revoked-device-secured")
        }

        if hasPersistedRecoveryCodeReceipt {
          Button {
            self.acknowledgeGeneratedRecoveryCode()
          } label: {
            Label("I Saved This Recovery Code", systemImage: "checkmark.shield.fill")
          }
          .disabled(
            coordinator == nil || isLoading
              || (recoveryCodeReceipt?.requiresDeviceSafetyConfirmation == true
                && !confirmedRevokedDeviceSecured)
          )
          .accessibilityIdentifier("labyrinth-acknowledge-generated-recovery-code")
        }
      }

      TextField("Enter 40-character recovery code", text: $restoreCodeInput)
        .font(.footnote.monospaced())
        #if os(iOS)
        .textInputAutocapitalization(.characters)
        #endif
        .autocorrectionDisabled()
        .accessibilityIdentifier("labyrinth-restore-code-input")

      Button {
        self.restoreFromCode()
      } label: {
        Label("Restore Backup from Recovery Code", systemImage: "arrow.counterclockwise.icloud.fill")
      }
      .disabled(coordinator == nil || isLoading || restoreCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("labyrinth-restore-from-code")
    } header: {
      Text(needsRestoreFirst ? "Restore with a Recovery Code" : "Recovery Code (Optional)")
    } footer: {
      if !needsRestoreFirst {
        Text("Labyrinth backs up encrypted history to your personal ATProto Space by default. Adding a recovery code lets you restore after losing all devices.")
      }
    }
  }

  /// This device waits for approval and holds no copy of the backup yet. Its own backup
  /// flags describe an empty local copy, so the screen leads with the restore instead.
  private var needsRestoreFirst: Bool {
    isPendingDeviceApproval && status?.archiveEstablished != true
  }

  private var restoreFirstSection: some View {
    Section {
      Button {
        self.restoreFromPasskeyPrf()
      } label: {
        Label("Restore with Passkey", systemImage: "person.badge.key.fill")
      }
      .disabled(coordinator == nil || isLoading)
      .accessibilityIdentifier("labyrinth-restore-passkey-prf")
    } header: {
      Text("Restore Your Backup")
    } footer: {
      Text("Use the passkey you saved your backup with. If you saved a recovery code instead, enter it below.")
    }
  }

  private var hasPersistedDeviceRevocationReceipt: Bool {
    revocationReceipt != nil
  }

  private var hasPersistedRecoveryCodeReceipt: Bool {
    recoveryCodeReceipt != nil
  }

  private var hasUnacknowledgedRecoveryAttention: Bool {
    status == nil || hasUnversionedReceipt || hasPersistedDeviceRevocationReceipt
      || hasPersistedRecoveryCodeReceipt
      || status?.recoveryNeedsAttention == true
  }

  private var passkeyPrfSection: some View {
    Section {
      Button {
        self.enrollPasskeyPrf()
      } label: {
        Label("Register Passkey PRF Recovery Key", systemImage: "person.badge.key.fill")
      }
      .disabled(coordinator == nil || isLoading || hasUnacknowledgedRecoveryAttention)
      .accessibilityIdentifier("labyrinth-register-passkey-prf")

      Button {
        self.restoreFromPasskeyPrf()
      } label: {
        Label("Restore Backup with Passkey PRF", systemImage: "key.icloud.fill")
      }
      .disabled(coordinator == nil || isLoading)
      .accessibilityIdentifier("labyrinth-restore-passkey-prf")
    } header: {
      Text("Passkey PRF Recovery")
    } footer: {
      if hasUnacknowledgedRecoveryAttention {
        Text("A passkey can be registered after you generate a recovery code below and confirm you saved it.")
      }
    }
  }

  private var otcPairingSection: some View {
    Section {
      Button {
        self.startOtcOffer()
      } label: {
        Label("Show 6-Digit Pairing Code (This Device)", systemImage: "qrcode.viewfinder")
      }
      .disabled(coordinator == nil || isLoading)
      .accessibilityIdentifier("labyrinth-start-otc")

      if let activeOtcOffer {
        HStack {
          Text("One-Time Code")
            .foregroundStyle(.secondary)
          Spacer()
          Text(verbatim: activeOtcOffer.formattedCode)
            .font(.title3.monospaced().bold())
            .accessibilityIdentifier("labyrinth-otc-formatted-code")
        }
      }

      TextField("Enter 6-digit code from another device", text: $joinOtcCodeInput)
        .font(.body.monospaced())
        #if os(iOS)
        .keyboardType(.numberPad)
        #endif
        .accessibilityIdentifier("labyrinth-join-otc-input")

      Button {
        self.startLiveOtcSession()
      } label: {
        Label("Start Multi-Device OTC Session", systemImage: "antenna.radiowaves.left.and.right")
      }
      .disabled(coordinator == nil || isLoading || joinOtcCodeInput.filter(\.isNumber).count != 6)
      .accessibilityIdentifier("labyrinth-start-live-otc-session")

      if let initiatedOtcSession {
        VStack(alignment: .leading, spacing: 4) {
          Text("Session ID (enter on authorized device):")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: initiatedOtcSession.sessionIdHex)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-otc-session-id")
        }
      }

      Button {
        self.completeOtcJoin()
      } label: {
        Label("Pair Device with 6-Digit Code", systemImage: "link.badge.plus")
      }
      .disabled(
        coordinator == nil || isLoading || initiatedOtcSession == nil
          || joinOtcCodeInput.filter(\.isNumber).count != 6
      )
      .accessibilityIdentifier("labyrinth-complete-otc")

      Divider()

      TextField("Responder Session ID (hex)", text: $respondOtcSessionIdInput)
        .font(.caption.monospaced())
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .accessibilityIdentifier("labyrinth-respond-otc-session-input")

      TextField("Responder 6-digit code", text: $respondOtcCodeInput)
        .font(.body.monospaced())
        #if os(iOS)
        .keyboardType(.numberPad)
        #endif
        .accessibilityIdentifier("labyrinth-respond-otc-code-input")

      Button {
        self.respondToLiveOtcSession()
      } label: {
        Label("Approve Pairing Session (Authorized Device)", systemImage: "checkmark.shield.fill")
      }
      .disabled(
        coordinator == nil
          || isLoading
          || respondOtcSessionIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || respondOtcCodeInput.filter(\.isNumber).count != 6
      )
      .accessibilityIdentifier("labyrinth-respond-otc-button")

      if let lastOtcCompletion {
        Text(
          "Paired with hybrid CPace + ML-KEM-768 (Epoch \(Int(lastOtcCompletion.newEpochSeq))).",
          comment: "Status text after post-quantum OTC device pairing completes. %lld is the new Labyrinth epoch number."
        )
          .font(.caption)
          .foregroundStyle(.green)
      }
    } header: {
      Text("Link Another Device (Post-Quantum OTC)")
    } footer: {
      Text("Uses hybrid CPace + ephemeral ML-KEM-768 so a 6-digit code cannot be brute-forced or recorded by a future quantum attacker.")
    }
  }

  nonisolated static func canRevokeDevice(
    _ targetDeviceId: String,
    currentDeviceId: String?,
    totalActiveCount: Int
  ) -> Bool {
    let trimmed = targetDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, totalActiveCount > 1 else { return false }
    if DeviceRowModel.matchesDeviceID(trimmed, currentDeviceId) {
      return false
    }
    return true
  }

  nonisolated static func mapOwnDevicesByID(
    _ items: [BlueCatbirdChatDefs.OwnDeviceView],
    currentDeviceId: String?,
    now: Date = Date()
  ) -> [String: DeviceRowModel] {
    var mapped: [String: DeviceRowModel] = [:]
    for item in items {
      let row = DeviceRowModel(item, currentDeviceId: currentDeviceId, now: now)
      let key = row.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !key.isEmpty {
        mapped[key] = row
      }
    }
    return mapped
  }

  nonisolated static func resolveDeviceMetadata(
    for deviceId: String,
    explicit: [String: DeviceRowModel],
    fetched: [String: DeviceRowModel]
  ) -> DeviceRowModel? {
    let normalized = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let match = explicit[normalized] {
      return match
    }
    if let caseInsensitiveExplicit = explicit.first(where: { $0.key.lowercased() == normalized })?.value {
      return caseInsensitiveExplicit
    }
    return fetched[normalized]
  }

  private var resolvedCurrentDeviceId: String? {
    if let currentDeviceId, !currentDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return currentDeviceId
    }
    guard let coordinator else { return nil }
    let sharedDefaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
    if let stored = sharedDefaults?.string(forKey: "mlsDeviceId_\(coordinator.accountDidHash)"),
       !stored.isEmpty
    {
      return stored
    }
    let key = AppState.mlsDeviceIDDefaultsKey(for: coordinator.accountDid)
    return sharedDefaults?.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
  }

  private var deviceListSection: some View {
    Section("Authorized Labyrinth Devices") {
      if let devices = status?.activeDeviceIds, !devices.isEmpty {
        let activeLocalId = resolvedCurrentDeviceId
        ForEach(devices, id: \.self) { deviceId in
          let isThisDevice = DeviceRowModel.matchesDeviceID(deviceId, activeLocalId)
          let meta = Self.resolveDeviceMetadata(
            for: deviceId,
            explicit: deviceMetadataByID,
            fetched: fetchedDeviceMetadataByID
          )
          let displayName = meta?.deviceName
            ?? (isThisDevice
              ? AppState.localMLSDeviceDisplayName(shortDeviceId: deviceId)
              : String(
                localized: "Device \(String(deviceId.prefix(8)))",
                comment: "Fallback display name for an enrolled MLS device. %@ is the 8-character device ID prefix."
              ))
          let state = meta?.activityState ?? .active
          let allowRevoke = Self.canRevokeDevice(
            deviceId,
            currentDeviceId: activeLocalId,
            totalActiveCount: devices.count
          )

          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Label(displayName, systemImage: isThisDevice ? "laptopcomputer.and.iphone" : "iphone")
                  .font(.subheadline.weight(.medium))
                  .lineLimit(1)
                if isThisDevice {
                  Text("This Device")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.18))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("labyrinth-this-device-badge")
                }
                Text(state.badgeTitle)
                  .font(.caption2.weight(.medium))
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(state.badgeTint.opacity(0.16))
                  .foregroundStyle(state.badgeTint)
                  .clipShape(Capsule())
              }
              Text(verbatim: deviceId)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if allowRevoke {
              Button("Revoke", role: .destructive) {
                self.revokeDevice(deviceId)
              }
              .buttonStyle(.borderless)
              .font(.caption)
              .accessibilityIdentifier("labyrinth-revoke-\(deviceId)")
            }
          }
          .padding(.vertical, 2)
        }
      } else {
        Text("No active Labyrinth devices enrolled yet.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var historyImportSection: some View {
    Section("Conversation Space History") {
      TextField("Conversation ID to verify/sync", text: $importConversationId)
        .font(.footnote.monospaced())
        .autocorrectionDisabled()

      Button {
        self.syncHistorySnapshot()
      } label: {
        Label("Verify & Re-Index Local Space History", systemImage: "tray.and.arrow.down.fill")
      }
      .disabled(coordinator == nil || isLoading || importConversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if let importedCount {
        Text(
          "Verified \(Int(importedCount)) Space history messages.",
          comment: "Status label showing how many Space history messages were verified. %lld is the message count."
        )
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Actions

  private func refreshDeviceMetadata() async {
    let actorDeviceId = resolvedCurrentDeviceId ?? appState?.resolvedMLSDeviceID() ?? ""
    if let coordinator, let coordDevices = try? await coordinator.listDevices(), !coordDevices.isEmpty {
      var mapped: [String: DeviceRowModel] = [:]
      for dev in coordDevices {
        let row = DeviceRowModel(dev, currentDeviceId: actorDeviceId)
        let key = row.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty {
          mapped[key] = row
        }
      }
      self.fetchedDeviceMetadataByID = mapped
      return
    }
    guard let appState, appState.client != nil, !actorDeviceId.isEmpty else { return }
    do {
      guard let mlsClient = await appState.getMLSAPIClient() else { return }
      if let output = try await mlsClient.getOwnDevices(actorDeviceId: actorDeviceId) {
        self.fetchedDeviceMetadataByID = Self.mapOwnDevicesByID(
          output.items,
          currentDeviceId: actorDeviceId
        )
      }
    } catch {
      self.logger.debug("Skipping optional device metadata enrichment in Labyrinth settings: \(error.localizedDescription)")
    }
  }

  private func refreshRecoveryMaterial() async {
    guard let coordinator else { return }
    lastFlushOutcome = coordinator.lastBackupFlushOutcome
    do {
      let latest = try await coordinator.labyrinthStatus()
      applyRecoveryStatus(latest)
    } catch {
      status = nil
      recoveryCodeReceipt = nil
      revocationReceipt = nil
      generatedRecoveryCode = nil
      errorMessage = error.localizedDescription
    }
  }

  /// What this device needs to be approved, worded as the Messages card words it.
  private var approvalCopy: DeviceApprovalCopy? {
    guard let approvalState, approvalState.isPending else { return nil }
    return DeviceApprovalCopy.make(
      for: approvalState,
      restoreQueued: status?.pendingDirectoryEpoch != nil
    )
  }

  private func refreshApprovalState() async {
    guard let coordinator else { return }
    isPendingDeviceApproval = (try? await coordinator.isDevicePendingApproval()) ?? false
    approvalState = await appState?.loadDeviceApprovalState()
  }

  /// The banner after a restore: whether this device is approved now, or when it will be.
  nonisolated static func restoreOutcome(stillPending: Bool, approval: DeviceApprovalState?, now: Date = Date()) -> String {
    guard stillPending else {
      return String(
        localized: "Backup restored. This device is approved for encrypted chat.",
        comment: "Banner after a backup restore approved this device"
      )
    }
    if let due = approval?.selfApprovalDate, due > now {
      let when = DeviceApprovalCopy.formatted(due, now: now, locale: .current, timeZone: .current)
      return String(
        localized: "Backup restored. This device approves itself \(when), unless another of your devices approves it sooner.",
        comment: "Banner after a backup restore on a device that waits out the approval hold"
      )
    }
    return String(
      localized: "Backup restored. This device is finishing its approval. Check again in a moment.",
      comment: "Banner after a backup restore whose approval is still publishing"
    )
  }

  private func applyRecoveryStatus(_ latest: LabyrinthBackupStatus) {
    guard let coordinator, latest.recoveryGeneration >= (status?.recoveryGeneration ?? 0) else { return }
    status = latest
    let reported = appState?.pendingMLSDeviceRevocationReceipt
      ?? (try? AppState.loadPendingMLSDeviceRevocationReceipt(forDID: coordinator.accountDid))
    let generated = appState?.pendingMLSRecoveryCodeReceipt
      ?? (try? AppState.loadPendingMLSRecoveryCodeReceipt(forDID: coordinator.accountDid))
    hasUnversionedReceipt = latest.recoveryGeneration == 0 && (reported != nil || generated != nil)
    revocationReceipt = reported.flatMap { $0.isCurrent(for: latest) ? $0 : nil }
    recoveryCodeReceipt = generated.flatMap { $0.isCurrent(for: latest) ? $0 : nil }
    generatedRecoveryCode = revocationReceipt?.replacementRecoveryCode ?? recoveryCodeReceipt?.recoveryCode
  }

  /// Reads the status. It does not set `isLoading`: that flag belongs to an action the
  /// user started, and a refresh finishing must not re-enable buttons under one.
  private func refreshStatus() async {
    guard let coordinator else { return }
    self.lastFlushOutcome = coordinator.lastBackupFlushOutcome
    do {
      self.applyRecoveryStatus(try await coordinator.labyrinthStatus())
      await self.refreshApprovalState()
      self.errorMessage = nil
    } catch {
      self.logger.error("Failed to fetch Labyrinth status: \(error.localizedDescription)")
      self.errorMessage = error.localizedDescription
    }
    await self.refreshDeviceMetadata()
  }

  private func generateRecoveryCode() {
    guard let coordinator else { return }
    guard status != nil, !hasPersistedDeviceRevocationReceipt && !hasPersistedRecoveryCodeReceipt else {
      self.errorMessage = String(
        localized: "Save and acknowledge the pending recovery report before generating another recovery code.",
        comment: "Error message when attempting to generate a new recovery code while an unacknowledged recovery report exists"
      )
      return
    }
    let requiresDeviceSafetyConfirmation = hasUnacknowledgedRecoveryAttention
    self.isLoading = true
    self.statusBanner = nil
    self.errorMessage = nil
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        // Native durably marks recovery as needing attention before returning this one-shot code.
        let material = try await coordinator.setupRecoveryCodeWithReceipt()

        let receipt: AppState.PendingMLSRecoveryCodeReceipt
        if let appState {
          receipt = try appState.retainGeneratedMLSRecoveryCode(
            material,
            requiresDeviceSafetyConfirmation: requiresDeviceSafetyConfirmation
          )
        } else {
          let didHash = try MLSAppGroupStorage.accountDidHash(for: coordinator.accountDid)
          let pendingReceipt = AppState.PendingMLSRecoveryCodeReceipt(
            recoveryCode: material.code,
            accountDidHash: didHash,
            requiresDeviceSafetyConfirmation: requiresDeviceSafetyConfirmation,
            recoveryGeneration: material.recoveryGeneration
          )
          try AppState.storePendingMLSRecoveryCodeReceipt(pendingReceipt)
          receipt = pendingReceipt
        }
        let refreshed = try await coordinator.labyrinthStatus()
        self.applyRecoveryStatus(refreshed)
        guard self.recoveryCodeReceipt == receipt else { return }
        self.warningBanner = String(
          localized: "Save the new recovery code, then explicitly confirm it below. Recovery remains not ready until confirmation.",
          comment: "Warning banner after generating a new Labyrinth recovery code"
        )
        if !refreshed.recoveryNeedsAttention {
          self.errorMessage = String(
            localized: "The recovery code is stored, but recovery safety status could not be confirmed. Keep the code and retry acknowledgement.",
            comment: "Error message when recovery safety state cannot be verified after generating a code"
          )
        }
      } catch {
        await self.refreshRecoveryMaterial()
        self.warningBanner = String(
          localized: "Recovery remains not ready. If secure code storage failed, retry generation; the previous recovery code may no longer work.",
          comment: "Warning banner when generating or storing a Labyrinth recovery code fails"
        )
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func acknowledgeGeneratedRecoveryCode() {
    guard let coordinator, let receipt = recoveryCodeReceipt, let generation = receipt.recoveryGeneration, generation > 0 else { return }
    self.isLoading = true
    self.statusBanner = nil
    self.errorMessage = nil
    Task { @MainActor in
      defer { self.isLoading = false }
      var acknowledgedStatus: LabyrinthBackupStatus?

      if let appState {
        let acknowledged = await appState.acknowledgePendingMLSRecoveryCodeReceipt(
          expected: receipt, nativeAcknowledger: {
            acknowledgedStatus = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
          }
        )
        guard acknowledged else {
          await self.refreshRecoveryMaterial()
          self.errorMessage = String(
            localized: "Couldn’t finish acknowledgement. The recovery code remains stored on this device; retry after resolving the error.",
            comment: "Error message when acknowledging a saved Labyrinth recovery code fails"
          )
          return
        }
      } else {
        do {
          acknowledgedStatus = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
          guard try AppState.loadPendingMLSRecoveryCodeReceipt(forDID: coordinator.accountDid) == receipt else { throw CancellationError() }
          try AppState.clearPendingMLSRecoveryCodeReceipt(forDID: coordinator.accountDid)
          self.status = acknowledgedStatus
        } catch {
          await self.refreshRecoveryMaterial()
          self.errorMessage = error.localizedDescription
          return
        }
      }

      await self.refreshRecoveryMaterial()
      self.confirmedRevokedDeviceSecured = false
      self.warningBanner = nil
      self.statusBanner = String(
        localized: "Recovery code saved and recovery attention cleared.",
        comment: "Success banner after acknowledging a saved Labyrinth recovery code"
      )
    }
  }

  private func restoreFromCode() {
    guard let coordinator else { return }
    let trimmed = self.restoreCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let restored = try await coordinator.restoreWithRecoveryCode(trimmed)
        self.applyRecoveryStatus(restored)
        self.restoreCodeInput = ""
        await self.refreshApprovalState()
        self.statusBanner = Self.restoreOutcome(
          stillPending: self.isPendingDeviceApproval,
          approval: self.approvalState
        )
        if restored.recoveryMethodStale {
          self.warningBanner = String(
            localized: "This recovery method is stale but still valid. Recreate it before a future rotation removes it.",
            comment: "Warning banner when a restored recovery method is older than the rotation threshold"
          )
        } else if !restored.rotationExclusions.isEmpty {
          self.warningBanner = String(
            localized: "Some recovery methods were removed during rotation. Recreate the affected methods below.",
            comment: "Warning banner when stale recovery methods were excluded during epoch rotation"
          )
        } else {
          self.warningBanner = nil
        }
        self.errorMessage = nil
        await self.refreshDeviceMetadata()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func enrollPasskeyPrf() {
    guard let coordinator else { return }
    guard !hasUnacknowledgedRecoveryAttention else {
      self.errorMessage = String(
        localized: "Save and acknowledge the pending recovery report before registering another passkey.",
        comment: "Error message when attempting to register a passkey while recovery attention is unacknowledged"
      )
      return
    }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        guard #available(iOS 18.0, macOS 15.0, *) else {
          throw LabyrinthPasskeyRegistrationError.unsupportedPlatform
        }
        guard let anchor = labyrinthPasskeyPresentationAnchor() else {
          throw LabyrinthPasskeyRegistrationError.missingPresentationAnchor
        }
        let registrar = LabyrinthPasskeyRegistrar(anchor: anchor)
        let passkey = try await registrar.register(accountDid: coordinator.accountDid)
        let latest = try await coordinator.registerPasskeyPrf(
          credentialId: passkey.credentialID,
          prfOutput32: passkey.prfOutput
        )
        self.applyRecoveryStatus(latest)
        self.statusBanner = String(
          localized: "Passkey PRF recovery secret registered.",
          comment: "Success banner after registering a passkey PRF recovery key"
        )
        self.warningBanner = nil
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func restoreFromPasskeyPrf() {
    guard let coordinator else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        guard #available(iOS 18.0, macOS 15.0, *) else {
          throw LabyrinthPasskeyRegistrationError.unsupportedPlatform
        }
        guard let anchor = labyrinthPasskeyPresentationAnchor() else {
          throw LabyrinthPasskeyRegistrationError.missingPresentationAnchor
        }
        let asserter = LabyrinthPasskeyAsserter(anchor: anchor)
        let passkey = try await asserter.authenticate(accountDid: coordinator.accountDid)
        let restored = try await coordinator.restoreWithPasskeyPrf(
          credentialId: passkey.credentialID,
          prfOutput32: passkey.prfOutput
        )
        self.applyRecoveryStatus(restored)
        await self.refreshApprovalState()
        self.statusBanner = Self.restoreOutcome(
          stillPending: self.isPendingDeviceApproval,
          approval: self.approvalState
        )
        self.warningBanner = nil
        self.errorMessage = nil
        await self.refreshDeviceMetadata()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func startOtcOffer() {
    guard let coordinator else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        self.activeOtcOffer = try await coordinator.initiateOtcPairing()
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func startLiveOtcSession() {
    guard let coordinator else { return }
    let digits = self.joinOtcCodeInput.filter(\.isNumber)
    guard digits.count == 6 else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let session = try await coordinator.startOtcPairing(sixDigitCode: digits)
        self.initiatedOtcSession = session
        self.statusBanner = String(
          localized: "Started OTC pairing session. Approve it on an authorized device.",
          comment: "Status banner after starting a 6-digit OTC device pairing session"
        )
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func respondToLiveOtcSession() {
    guard let coordinator else { return }
    let sessionId = self.respondOtcSessionIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = self.respondOtcCodeInput.filter(\.isNumber)
    guard !sessionId.isEmpty, digits.count == 6 else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        try await coordinator.respondOtcPairing(sessionIdHex: sessionId, sixDigitCode: digits)
        self.respondOtcSessionIdInput = ""
        self.respondOtcCodeInput = ""
        self.applyRecoveryStatus(try await coordinator.labyrinthStatus())
        self.statusBanner = String(
          localized: "Approved OTC pairing session and sealed epoch keys.",
          comment: "Status banner after approving an OTC device pairing session"
        )
        self.errorMessage = nil
        await self.refreshDeviceMetadata()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func completeOtcJoin() {
    guard let coordinator else { return }
    let digits = self.joinOtcCodeInput.filter(\.isNumber)
    guard digits.count == 6 else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let completion = try await coordinator.completeOtcPairing(sixDigitCode: digits)
        self.lastOtcCompletion = completion
        self.initiatedOtcSession = nil
        self.applyRecoveryStatus(try await coordinator.labyrinthStatus())
        self.isPendingDeviceApproval = (try? await coordinator.isDevicePendingApproval()) ?? false
        self.statusBanner = String(
          localized: "Device paired at Labyrinth epoch \(Int(completion.newEpochSeq)).",
          comment: "Status banner after completing OTC device pairing. %lld is the new Labyrinth epoch number."
        )
        self.errorMessage = nil
        await self.refreshDeviceMetadata()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func revokeDevice(_ targetDeviceId: String) {
    guard let coordinator else { return }
    let totalCount = status?.activeDeviceIds.count ?? 2
    guard Self.canRevokeDevice(
      targetDeviceId,
      currentDeviceId: resolvedCurrentDeviceId,
      totalActiveCount: totalCount
    ) else {
      self.errorMessage = DeviceManagementViewModel.selfRevokeBlockedMessage
      return
    }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        // Unified revocation covers the directory, affected groups, encrypted backup, and PDS record,
        // and returns the one-time replacement recovery material. A Labyrinth-only fallback could
        // leave the lost device active elsewhere, so this path remains fail-closed.
        let report = try await coordinator.revokeDevice(targetDeviceId: targetDeviceId)
        if let appState {
          do {
            _ = try appState.retainDeviceRevocationReport(report)
          } catch {
            await self.refreshRecoveryMaterial()
            throw error
          }
        } else {
          let receipt = AppState.PendingMLSDeviceRevocationReceipt(
            report: report,
            accountDidHash: coordinator.accountDidHash
          )
          try AppState.storePendingMLSDeviceRevocationReceipt(receipt)
        }
        guard report.dsRevoked else {
          throw NSError(
            domain: "LabyrinthDeviceRevocation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: DeviceManagementViewModel.incompleteRevocationMessage]
          )
        }
        self.applyRecoveryStatus(try await coordinator.labyrinthStatus())
        self.fetchedDeviceMetadataByID.removeValue(
          forKey: targetDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        self.statusBanner = String(
          localized: "Revoked device \(targetDeviceId) and rotated Labyrinth epoch.",
          comment: "Status banner after revoking an MLS device. %@ is the revoked device ID."
        )
        if self.status?.rotationExclusions.isEmpty == false {
          self.warningBanner = String(
            localized: "Some recovery methods were removed during rotation. Recreate the affected methods below."
          )
        } else {
          self.warningBanner = nil
        }
        self.errorMessage = nil
        await self.refreshDeviceMetadata()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func syncHistorySnapshot() {
    guard let coordinator else { return }
    let convoId = self.importConversationId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !convoId.isEmpty else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let reindexed = try await coordinator.verifyAndReindexHistory(conversationId: convoId)
        if reindexed > 0 {
          self.importedCount = reindexed
        } else {
          let existing = try await coordinator.listMessages(conversationId: convoId, limit: 200)
          self.importedCount = try await coordinator.importConversationHistory(
            conversationId: convoId,
            messages: existing
          )
        }
        let verifiedCount = Int(self.importedCount ?? 0)
        self.statusBanner = String(
          localized: "Verified \(verifiedCount) messages in \(convoId).",
          comment: "Status banner after verifying Space conversation history. %1$lld is the message count, %2$@ is the conversation ID."
        )
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }
}

enum LabyrinthPasskeyPolicy {
  static let relyingParty = "passkey.catbird.blue"

  static func newUserHandle() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }

  static func isBackupEligible(authenticatorData: Data, registration: Bool) -> Bool {
    // WebAuthn authenticatorData starts with rpIdHash, flags, then the four-byte sign counter.
    guard authenticatorData.count >= 37,
          authenticatorData.prefix(32).elementsEqual(SHA256.hash(data: Data(relyingParty.utf8)))
    else { return false }
    let flags = authenticatorData[authenticatorData.startIndex + 32]
    let required: UInt8 = registration ? 0x4d : 0x0d // UP, UV, BE; AT on registration
    guard flags & required == required else { return false }
    if registration {
      // Attested data includes a 16-byte AAGUID, a big-endian credential ID length,
      // the ID itself, and a CBOR public key. Reject truncated fixed headers or IDs.
      let bytes = Array(authenticatorData)
      guard bytes.count >= 55 else { return false }
      let credentialLength = Int(bytes[53]) << 8 | Int(bytes[54])
      let keyStart = 55 + credentialLength
      guard credentialLength > 0, keyStart < bytes.count,
            let key = try? CBOR.decode(Array(bytes[keyStart...])), case .map = key else { return false }
    } else if flags & 0x40 != 0 {
      return false
    }
    return true
  }

  static func isBackupEligible(attestation: Data?) -> Bool {
    guard let attestation, attestation.count <= 64 * 1024,
          let decoded = try? CBOR.decode(Array(attestation)), case .map(let map) = decoded,
          case .byteString(let bytes)? = map[.utf8String("authData")]
    else { return false }
    return isBackupEligible(authenticatorData: Data(bytes), registration: true)
  }
}

private enum LabyrinthPasskeyRegistrationError: LocalizedError {
  case invalidCredential
  case backupIneligible
  case missingPresentationAnchor
  case prfUnsupported
  case unsupportedPlatform

  var errorDescription: String? {
    switch self {
    case .invalidCredential:
      String(localized: "The passkey provider returned an invalid credential.", comment: "Error when WebAuthn passkey registration returns invalid credential data")
    case .backupIneligible:
      String(localized: "This passkey cannot be verified as backup eligible. Choose a synced passkey or use another recovery method.", comment: "Error when a passkey is not backup-eligible for Labyrinth recovery")
    case .missingPresentationAnchor:
      String(localized: "Catbird cannot present passkey registration right now.", comment: "Error when no window is available to present passkey registration")
    case .prfUnsupported:
      String(localized: "This passkey provider does not support encrypted PRF recovery.", comment: "Error when the passkey authenticator does not support the WebAuthn PRF extension")
    case .unsupportedPlatform:
      String(localized: "Passkey PRF recovery requires iOS 18 or macOS 15.", comment: "Error when the OS version does not support WebAuthn PRF")
    }
  }
}

private func labyrinthPasskeyPresentationAnchor() -> ASPresentationAnchor? {
  #if os(iOS)
  for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
    if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
      return window
    }
  }
  return nil
  #elseif os(macOS)
  return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
  #endif
}

@available(iOS 18.0, macOS 15.0, *)
@MainActor
private final class LabyrinthPasskeyRegistrar: NSObject,
  ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  struct Result {
    let credentialID: Data
    let prfOutput: Data
  }

  private let anchor: ASPresentationAnchor
  private var continuation: CheckedContinuation<Result, Error>?
  private var controller: ASAuthorizationController?

  init(anchor: ASPresentationAnchor) {
    self.anchor = anchor
    super.init()
  }

  func register(accountDid: String) async throws -> Result {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: LabyrinthPasskeyPolicy.relyingParty
    )
    let challengeKey = SymmetricKey(size: .bits256)
    let challenge = challengeKey.withUnsafeBytes { Data($0) }
    let userID = LabyrinthPasskeyPolicy.newUserHandle()
    let request = provider.createCredentialRegistrationRequest(
      challenge: challenge,
      name: accountDid,
      userID: userID
    )
    let salt = Data(
      SHA256.hash(
        data: Data("catbird.labyrinth.passkey-recovery.v1:\(accountDid)".utf8)
      )
    )
    request.userVerificationPreference = .required
    request.prf = .inputValues(.init(saltInput1: salt))

    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let controller = ASAuthorizationController(authorizationRequests: [request])
      self.controller = controller
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    self.anchor
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard
      let credential =
        authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration
    else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.invalidCredential))
      return
    }
    guard LabyrinthPasskeyPolicy.isBackupEligible(attestation: credential.rawAttestationObject) else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.backupIneligible))
      return
    }
    guard let prf = credential.prf, prf.isSupported, let first = prf.first else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.prfUnsupported))
      return
    }
    let output = first.withUnsafeBytes { Data($0) }
    guard output.count == 32, !credential.credentialID.isEmpty else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.invalidCredential))
      return
    }
    self.finish(
      .success(Result(credentialID: credential.credentialID, prfOutput: output))
    )
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    self.finish(.failure(error))
  }

  private func finish(_ result: Swift.Result<Result, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    self.controller = nil
    continuation.resume(with: result)
  }
}

@available(iOS 18.0, macOS 15.0, *)
@MainActor
private final class LabyrinthPasskeyAsserter: NSObject,
  ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  struct Result {
    let credentialID: Data
    let prfOutput: Data
  }

  private let anchor: ASPresentationAnchor
  private var continuation: CheckedContinuation<Result, Error>?
  private var controller: ASAuthorizationController?

  init(anchor: ASPresentationAnchor) {
    self.anchor = anchor
    super.init()
  }

  func authenticate(accountDid: String) async throws -> Result {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: LabyrinthPasskeyPolicy.relyingParty
    )
    let challengeKey = SymmetricKey(size: .bits256)
    let challenge = challengeKey.withUnsafeBytes { Data($0) }
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    let salt = Data(
      SHA256.hash(
        data: Data("catbird.labyrinth.passkey-recovery.v1:\(accountDid)".utf8)
      )
    )
    request.userVerificationPreference = .required
    request.prf = .inputValues(.init(saltInput1: salt))

    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let controller = ASAuthorizationController(authorizationRequests: [request])
      self.controller = controller
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    self.anchor
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard
      let credential =
        authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
    else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.invalidCredential))
      return
    }
    guard LabyrinthPasskeyPolicy.isBackupEligible(authenticatorData: credential.rawAuthenticatorData, registration: false) else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.backupIneligible))
      return
    }
    guard let prf = credential.prf else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.prfUnsupported))
      return
    }
    let first = prf.first
    let output = first.withUnsafeBytes { Data($0) }
    guard output.count == 32, !credential.credentialID.isEmpty else {
      self.finish(.failure(LabyrinthPasskeyRegistrationError.invalidCredential))
      return
    }
    self.finish(
      .success(Result(credentialID: credential.credentialID, prfOutput: output))
    )
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    self.finish(.failure(error))
  }

  private func finish(_ result: Swift.Result<Result, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    self.controller = nil
    continuation.resume(with: result)
  }
}
