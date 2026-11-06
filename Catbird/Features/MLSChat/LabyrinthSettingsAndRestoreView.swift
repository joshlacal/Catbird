import AuthenticationServices
import CatbirdMLSCore
import CryptoKit
import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
  @State private var warningBanner: String?
  @State private var errorMessage: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "LabyrinthUI")

  var body: some View {
    Form {
      backupStatusSection
      recoveryWarningsSection
      recoveryCodeSection
      passkeyPrfSection
      otcPairingSection
      deviceListSection
      historyImportSection

      if let warningBanner {
        Section {
          Label(warningBanner, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.footnote)
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recovery warning: \(warningBanner)")
            .accessibilityIdentifier("labyrinth-warning-status")
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

  @ViewBuilder
  private var recoveryWarningsSection: some View {
    if let status, status.recoveryMethodStale || !status.rotationExclusions.isEmpty {
      Section {
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
          let method = exclusion.recoveryMethod?.capitalized ?? "Device"
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
        Text("Generate a new recovery code or register the affected passkey again below.")
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
        self.warningBanner = nil
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
        let restored = try await coordinator.restoreWithRecoveryCode(trimmed)
        self.status = restored
        self.restoreCodeInput = ""
        self.statusBanner = "Restored Labyrinth epoch keys and rotated virtual device."
        if restored.recoveryMethodStale {
          self.warningBanner = "This recovery method is stale but still valid. Recreate it before a future rotation removes it."
        } else if !restored.rotationExclusions.isEmpty {
          self.warningBanner = "Some recovery methods were removed during rotation. Recreate the affected methods below."
        } else {
          self.warningBanner = nil
        }
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
        guard #available(iOS 18.0, macOS 15.0, *) else {
          throw LabyrinthPasskeyRegistrationError.unsupportedPlatform
        }
        guard let anchor = labyrinthPasskeyPresentationAnchor() else {
          throw LabyrinthPasskeyRegistrationError.missingPresentationAnchor
        }
        let registrar = LabyrinthPasskeyRegistrar(anchor: anchor)
        let passkey = try await registrar.register(accountDid: coordinator.accountDid)
        self.status = try await coordinator.registerPasskeyPrf(
          credentialId: passkey.credentialID,
          prfOutput32: passkey.prfOutput
        )
        self.statusBanner = "Passkey PRF recovery secret registered."
        self.warningBanner = nil
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
        if self.status?.rotationExclusions.isEmpty == false {
          self.warningBanner = "Some recovery methods were removed during rotation. Recreate the affected methods below."
        } else {
          self.warningBanner = nil
        }
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

private enum LabyrinthPasskeyRegistrationError: LocalizedError {
  case invalidCredential
  case missingPresentationAnchor
  case prfUnsupported
  case unsupportedPlatform

  var errorDescription: String? {
    switch self {
    case .invalidCredential:
      "The passkey provider returned an invalid credential."
    case .missingPresentationAnchor:
      "Catbird cannot present passkey registration right now."
    case .prfUnsupported:
      "This passkey provider does not support encrypted PRF recovery."
    case .unsupportedPlatform:
      "Passkey PRF recovery requires iOS 18 or macOS 15."
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
      relyingPartyIdentifier: "catbird.blue"
    )
    let challengeKey = SymmetricKey(size: .bits256)
    let challenge = challengeKey.withUnsafeBytes { Data($0) }
    let userID = Data(SHA256.hash(data: Data(accountDid.utf8)))
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
