import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore
import PetrelCatbird

#if os(iOS)

/// The account's `blue.catbird.chat.declaration/self`, whose `allowIncoming` the delivery service enforces.
/// A nil declaration means enrollment hasn't published one yet; this screen never creates it.
private struct EncryptedChatDeclarationRecord {
  var declaration: BlueCatbirdChatDeclaration?
  var cid: CIDString?
}

/// Settings view for MLS encrypted chat: who can send requests, backup and recovery, diagnostics, and opting out
struct MLSChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // Loading and error states
  @State private var isLoading = true
  @State private var privacyEditor: AccountSettingsEditSession<EncryptedChatDeclarationRecord>?
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

  // Opt-out confirmation
  @State private var showingOptOutConfirmation = false
  @State private var isOptingOut = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSChatSettings")

  var body: some View {
    Form {
      // MARK: - Who Can Message You

      privacySection

      // MARK: - Backup & Recovery

      Section("Backup & Recovery") {
        NavigationLink(
          destination: LabyrinthSettingsAndRestoreView(
            coordinator: appState.mlsCoordinator,
            currentDeviceId: appState.resolvedMLSDeviceID()
          )
          .id(appState.mlsCoordinator?.accountDidHash)
        ) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Labyrinth Backup & Recovery")
              Text("Recovery code, passkey PRF, post-quantum device pairing, and history restore")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "key.icloud.fill")
              .foregroundStyle(.green)
          }
        }
      }

      // MARK: - Diagnostics

      Section("Diagnostics") {
        NavigationLink(destination: MLSChatDiagnosticsView()) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Chat Diagnostics")
              Text("View delivery errors, recovery events, and export logs")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "stethoscope")
              .foregroundStyle(.blue)
          }
        }
      }

      // MARK: - Disable MLS Chat

      Section {
        Button(role: .destructive) {
          showingOptOutConfirmation = true
        } label: {
          HStack {
            if isOptingOut {
              ProgressView()
                .controlSize(.small)
              Text("Disabling…")
            } else {
              Text("Disable MLS Encrypted Chat")
            }
            Spacer()
          }
        }
        .disabled(isOptingOut)
      } header: {
        Text("Disable Encrypted Chat")
      } footer: {
        Text(
          "Disabling MLS chat will prevent you from sending or receiving end-to-end encrypted messages. You can re-enable this feature at any time."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Encrypted Chat")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      await openCoordinator()
    }
    .task {
      await loadPrivacyEditor()
    }
    .onDisappear { privacyEditor?.invalidate() }
    .alert("Chat Settings Error", isPresented: $showingErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "An unknown error occurred.")
    }
    .confirmationDialog(
      "Disable MLS Encrypted Chat?",
      isPresented: $showingOptOutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Disable Encrypted Chat", role: .destructive) {
        Task { await optOutOfMLS() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "You will no longer be able to send or receive end-to-end encrypted messages. Existing conversations will become inaccessible until you re-enable this feature."
      )
    }
    .overlay {
      if isLoading {
        ProgressView("Loading encrypted chat…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.ultraThinMaterial)
      }
    }
  }

  // MARK: - Data Loading

  /// Backup & Recovery reads the coordinator, so open it before showing the screen.
  @MainActor
  private func openCoordinator() async {
    _ = await appState.getOrOpenMLSCoordinator()
    isLoading = false
  }

  // MARK: - Who Can Message You

  @ViewBuilder
  private var privacySection: some View {
    Section {
      if let editor = privacyEditor {
        switch editor.state {
        case .unavailable:
          Text("This account is no longer active. Open Settings for the current account.")
        case .loading:
          ProgressView("Loading encrypted chat rule…")
        case .loadFailed:
          Text("Your encrypted chat rule couldn’t be loaded.")
          Text(editor.errorMessage ?? "Try again.").appFont(AppTextRole.footnote).foregroundStyle(.secondary)
          Button("Try Again") { Task { await editor.load() } }
        case .ready, .saving, .saveFailed:
          if editor.displayedValue?.declaration == nil {
            Text("Encrypted chat hasn’t finished setting up on this account. Open Messages, then come back to choose who can message you.")
              .appFont(AppTextRole.footnote).foregroundStyle(.secondary)
            Button("Try Again") { Task { await editor.load() } }
          } else {
            privacyPicker(editor: editor)
          }
          if editor.state == .saving {
            ProgressView("Saving encrypted chat rule…")
          } else if editor.state == .saveFailed {
            Text("This change couldn’t be confirmed. The last loaded rule is shown.")
            Text(editor.errorMessage ?? "Try the change again or reload the saved rule.").appFont(AppTextRole.footnote).foregroundStyle(.secondary)
            Button("Try This Change Again") { editor.retrySave() }
            Button("Reload Saved Rule") { Task { await editor.load() } }
          }
        }
      } else {
        ProgressView("Loading encrypted chat rule…")
      }
    } header: {
      Text("Who Can Message You")
    } footer: {
      Text("Choose who can send you encrypted chat requests. This is separate from your Bluesky chat rule.")
    }
  }

  private func privacyPicker(
    editor: AccountSettingsEditSession<EncryptedChatDeclarationRecord>
  ) -> some View {
    let raw = editor.displayedValue?.declaration?.allowIncoming ?? ""
    return Picker("Encrypted Requests From", selection: Binding(
      get: { raw },
      set: { selection in
        guard editor.canEdit, var value = editor.confirmedValue,
              let current = value.declaration, selection != raw else { return }
        value.declaration = BlueCatbirdChatDeclaration(
          allowIncoming: selection,
          deliveryService: current.deliveryService,
          protocolVersion: current.protocolVersion,
          createdAt: current.createdAt,
          extraFields: current.extraFields
        )
        editor.submit(value)
      }
    )) {
      if ChatPrivacyOption(rawValue: raw) == nil {
        Text("Unsupported Saved Rule").tag(raw)
      }
      ForEach(ChatPrivacyOption.allCases) { Text($0.title).tag($0.rawValue) }
    }
    .disabled(!editor.canEdit)
  }

  /// Reads and writes the declaration through the signed-in account's PDS. Enrollment keeps an
  /// existing declaration whose `allowIncoming` is valid, so a rule saved here isn't overwritten.
  @MainActor
  private func loadPrivacyEditor() async {
    privacyEditor?.invalidate()
    let state = appState
    let account = state.userDID
    let contextRevision = AppStateManager.shared.settingsAccountContextRevision
    let client = state.atProtoClient
    let editor = AccountSettingsEditSession<EncryptedChatDeclarationRecord>(
      accountDID: account,
      allowEditingAfterSaveFailure: false,
      isCurrentAccount: {
        AppStateManager.shared.lifecycle.userDID == account
          && AppStateManager.shared.settingsAccountContextRevision == contextRevision
          && !state.isTransitioningAccounts
          && state.atProtoClient === client
      },
      load: {
        return try await state.performSettingsAccountOperation {
          guard let client else { throw EncryptedChatPrivacyError.notAuthenticated }
          do {
            let (code, output) = try await client.com.atproto.repo.getRecord(input: .init(
              repo: try ATIdentifier(string: account),
              collection: try NSID(nsidString: BlueCatbirdChatDeclaration.typeIdentifier),
              rkey: try RecordKey(keyString: "self")
            ))
            guard code == 200, let output,
                  let record = output.value.decoded(BlueCatbirdChatDeclaration.self) else {
              throw EncryptedChatPrivacyError.response(code)
            }
            return EncryptedChatDeclarationRecord(declaration: record, cid: output.cid)
          } catch let error as ATProtoError<ComAtprotoRepoGetRecord.Error> where error.error == .recordNotFound {
            return EncryptedChatDeclarationRecord(declaration: nil, cid: nil)
          } catch let error as ATProtoXRPCError where error.error == "RecordNotFound" {
            return EncryptedChatDeclarationRecord(declaration: nil, cid: nil)
          }
        }
      },
      save: { value in
        return try await state.performSettingsAccountOperation {
          guard let client, AppStateManager.shared.lifecycle.userDID == account,
                AppStateManager.shared.settingsAccountContextRevision == contextRevision,
                !state.isTransitioningAccounts, state.atProtoClient === client else {
            throw EncryptedChatPrivacyError.accountChanged
          }
          guard let declaration = value.declaration, let cid = value.cid else {
            throw EncryptedChatPrivacyError.notSetUp
          }
          let (code, output) = try await client.com.atproto.repo.putRecord(input: .init(
            repo: try ATIdentifier(string: account),
            collection: try NSID(nsidString: BlueCatbirdChatDeclaration.typeIdentifier),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(declaration),
            swapRecord: .value(cid)
          ))
          guard code == 200, let output else { throw EncryptedChatPrivacyError.response(code) }
          return EncryptedChatDeclarationRecord(declaration: declaration, cid: output.cid)
        }
      }
    )
    privacyEditor = editor
    await editor.load()
  }

  // MARK: - Opt Out

  @MainActor
  private func optOutOfMLS() async {
    isOptingOut = true
    defer { isOptingOut = false }
    do {
      try await appState.optOutOfMLSChat()
      logger.info("Disabled MLS chat for current account")
      dismiss()
    } catch {
      logger.error("Failed to disable MLS chat: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

}

private enum EncryptedChatPrivacyError: LocalizedError {
  case notAuthenticated, accountChanged, notSetUp, response(Int)
  var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Sign in to load your encrypted chat rule."
    case .accountChanged: "The account changed. Open these settings again."
    case .notSetUp: "Encrypted chat hasn’t finished setting up on this account."
    case .response: "Your encrypted chat rule couldn’t be confirmed. Try again."
    }
  }
}

#Preview {
  NavigationStack {
    MLSChatSettingsView()
  }
}

#endif
