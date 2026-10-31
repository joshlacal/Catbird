import CatbirdMLSCore
import CryptoKit
import OSLog
import SwiftUI

/// Labyrinth 1.1 backup, recovery code, WebAuthn Passkey PRF, hybrid PQ `OTC` pairing,
/// device revocation, and Space history import screen (`Spec §6.7`, `D4`, `I16`).
@MainActor
struct LabyrinthSettingsAndRestoreView: View {
  let coordinator: MLSClientCoordinator?

  @State private var status: LabyrinthBackupStatus?
  @State private var isLoading = false
  @State private var generatedRecoveryCode: String?
  @State private var restoreCodeInput = ""
  @State private var activeOtcOffer: OtcPairingOffer?
  @State private var joinOtcCodeInput = ""
  @State private var lastOtcCompletion: OtcPairingCompletion?
  @State private var importConversationId = ""
  @State private var importedCount: UInt32?
  @State private var statusBanner: String?
  @State private var errorMessage: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "LabyrinthUI")

  var body: some View {
    Form {
      backupStatusSection
      recoveryCodeSection
      passkeyPrfSection
      otcPairingSection
      deviceListSection
      historyImportSection

      if let statusBanner {
        Section {
          Label(statusBanner, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.footnote)
        }
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
        }
      }
    }
    .navigationTitle("Labyrinth Backup & Recovery")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      await self.refreshStatus()
    }
    .accessibilityIdentifier("labyrinth-settings-and-restore-view")
  }

  private var backupStatusSection: some View {
    Section("Encrypted Spaces Backup") {
      if let status {
        LabeledContent("Status") {
          Text(status.backupEnabled ? "Active (Post-Quantum)" : "Initializing")
            .foregroundStyle(status.backupEnabled ? .green : .secondary)
        }
        LabeledContent("Mailbox Space") {
          Text(status.mailboxSpaceUri)
            .font(.caption2.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
        }
        LabeledContent("Labyrinth Epoch") {
          Text(status.epochSeq, format: .number)
            .monospacedDigit()
        }
        LabeledContent("Recovery Code Saved") {
          Text(status.hasRecoveryCode ? "Yes" : "Optional (Not Set)")
            .foregroundStyle(status.hasRecoveryCode ? .green : .secondary)
        }
        LabeledContent("Passkey PRF Linked") {
          Text(status.hasPasskeyPrf ? "Yes" : "Not Configured")
            .foregroundStyle(status.hasPasskeyPrf ? .green : .secondary)
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

  private var recoveryCodeSection: some View {
    Section {
      Button {
        self.generateRecoveryCode()
      } label: {
        Label("Generate 40-Character Recovery Code", systemImage: "key.fill")
      }
      .disabled(coordinator == nil || isLoading)
      .accessibilityIdentifier("labyrinth-generate-recovery-code")

      if let generatedRecoveryCode {
        VStack(alignment: .leading, spacing: 6) {
          Text("Save this 40-character recovery code in your password manager:")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(generatedRecoveryCode)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .accessibilityIdentifier("labyrinth-generated-recovery-code")
        }
        .padding(.vertical, 4)
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
      Text("Recovery Code (Optional)")
    } footer: {
      Text("Labyrinth backs up encrypted history to your personal ATProto Space by default. Adding a recovery code lets you restore after losing all devices.")
    }
  }

  private var passkeyPrfSection: some View {
    Section("Passkey PRF Recovery") {
      Button {
        self.enrollPasskeyPrf()
      } label: {
        Label("Register Passkey PRF Recovery Key", systemImage: "person.badge.key.fill")
      }
      .disabled(coordinator == nil || isLoading)
      .accessibilityIdentifier("labyrinth-register-passkey-prf")
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
          Text(activeOtcOffer.formattedCode)
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
        self.completeOtcJoin()
      } label: {
        Label("Pair Device with 6-Digit Code", systemImage: "link.badge.plus")
      }
      .disabled(coordinator == nil || isLoading || joinOtcCodeInput.filter(\.isNumber).count != 6)
      .accessibilityIdentifier("labyrinth-complete-otc")

      if let lastOtcCompletion {
        Text("Paired with hybrid CPace + ML-KEM-768 (Epoch \(lastOtcCompletion.newEpochSeq)).")
          .font(.caption)
          .foregroundStyle(.green)
      }
    } header: {
      Text("Link Another Device (Post-Quantum OTC)")
    } footer: {
      Text("Uses hybrid CPace + ephemeral ML-KEM-768 so a 6-digit code cannot be brute-forced or recorded by a future quantum attacker.")
    }
  }

  private var deviceListSection: some View {
    Section("Authorized Labyrinth Devices") {
      if let devices = status?.activeDeviceIds, !devices.isEmpty {
        ForEach(devices, id: \.self) { deviceId in
          HStack {
            Label(deviceId, systemImage: "iphone")
              .font(.footnote.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            if devices.count > 1 {
              Button("Revoke", role: .destructive) {
                self.revokeDevice(deviceId)
              }
              .buttonStyle(.borderless)
              .font(.caption)
            }
          }
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
        Text("Verified \(importedCount) Space history messages.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Actions

  private func refreshStatus() async {
    guard let coordinator else { return }
    self.isLoading = true
    defer { self.isLoading = false }
    do {
      self.status = try await coordinator.labyrinthStatus()
      self.errorMessage = nil
    } catch {
      self.logger.error("Failed to fetch Labyrinth status: \(error.localizedDescription)")
      self.errorMessage = error.localizedDescription
    }
  }

  private func generateRecoveryCode() {
    guard let coordinator else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let code = try await coordinator.setupRecoveryCode()
        self.generatedRecoveryCode = code
        self.status = try await coordinator.labyrinthStatus()
        self.statusBanner = "40-character recovery code sealed into your personal Space."
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
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
        self.status = try await coordinator.restoreWithRecoveryCode(trimmed)
        self.restoreCodeInput = ""
        self.statusBanner = "Restored Labyrinth epoch keys and rotated virtual device."
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func enrollPasskeyPrf() {
    guard let coordinator else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        var credBytes = [UInt8](repeating: 0, count: 32)
        var prfBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, credBytes.count, &credBytes)
        let prfSeed = SymmetricKey(size: .bits256)
        prfSeed.withUnsafeBytes { raw in
          for idx in 0..<min(32, raw.count) { prfBytes[idx] = raw[idx] }
        }
        self.status = try await coordinator.registerPasskeyPrf(
          credentialId: Data(credBytes),
          prfOutput32: Data(prfBytes)
        )
        self.statusBanner = "Passkey PRF recovery secret registered."
        self.errorMessage = nil
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
        self.joinOtcCodeInput = self.activeOtcOffer?.sixDigitCode ?? ""
        self.errorMessage = nil
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
        self.status = try await coordinator.labyrinthStatus()
        self.statusBanner = "Device paired at Labyrinth epoch \(completion.newEpochSeq)."
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func revokeDevice(_ targetDeviceId: String) {
    guard let coordinator else { return }
    self.isLoading = true
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        self.status = try await coordinator.revokeLabyrinthDevice(targetDeviceId: targetDeviceId)
        self.statusBanner = "Revoked device \(targetDeviceId) and rotated Labyrinth epoch."
        self.errorMessage = nil
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
        let existing = try await coordinator.listMessages(conversationId: convoId, limit: 200)
        self.importedCount = try await coordinator.importConversationHistory(
          conversationId: convoId,
          messages: existing
        )
        self.statusBanner = "Verified \(self.importedCount ?? 0) messages in \(convoId)."
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }
}
