import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore

#if os(iOS)

/// Settings view for MLS encrypted chat privacy and safety options
struct MLSChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // Settings state
  @State private var allowFollowersBypass: Bool = true
  @State private var allowFollowingBypass: Bool = false
  @State private var whoCanMessageMe: MLSWhoCanMessageMe = .everyone
  @State private var autoExpireDays: Int = 7
  @State private var declarationRolloutMode: MLSDeclarationRolloutMode = .shadow

  // Loading and error states
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var isUpdatingRolloutMode = false
  @State private var isRepairingDeclaration = false
  @State private var isRotatingDeclarationRoot = false
  @State private var isRecoveringDeclarationRoot = false
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

  // Opt-out confirmation
  @State private var showingOptOutConfirmation = false
  @State private var isOptingOut = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSChatSettings")

  var body: some View {
    Form {
      // MARK: - Who Can Message Me

      Section("Who Can Message Me Directly") {
        Picker("Allow Messages From", selection: $whoCanMessageMe) {
          Text("Everyone").tag(MLSWhoCanMessageMe.everyone)
          Text("Mutuals Only").tag(MLSWhoCanMessageMe.mutuals)
          Text("People I Follow").tag(MLSWhoCanMessageMe.following)
          Text("Nobody").tag(MLSWhoCanMessageMe.nobody)
        }
        .pickerStyle(.menu)
        .disabled(isSaving)
        .onChange(of: whoCanMessageMe) { _, newValue in
          saveSettings(whoCanMessageMe: newValue)
        }

        Toggle("People You Follow", isOn: $allowFollowersBypass)
          .tint(.blue)
          .disabled(isSaving)
          .onChange(of: allowFollowersBypass) { _, newValue in
            saveSettings(allowFollowersBypass: newValue)
          }

        Toggle("People Who Follow You", isOn: $allowFollowingBypass)
          .tint(.blue)
          .disabled(isSaving)
          .onChange(of: allowFollowingBypass) { _, newValue in
            saveSettings(allowFollowingBypass: newValue)
          }

        Text(
          "When enabled, these users can start a conversation directly without going through your message requests."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }

      // MARK: - Request Expiration

      Section("Message Requests") {
        Picker("Auto-Expire After", selection: $autoExpireDays) {
          Text("1 Day").tag(1)
          Text("3 Days").tag(3)
          Text("7 Days").tag(7)
          Text("14 Days").tag(14)
          Text("30 Days").tag(30)
        }
        .pickerStyle(.menu)
        .disabled(isSaving)
        .onChange(of: autoExpireDays) { _, newValue in
          saveSettings(autoExpireDays: newValue)
        }

        Text(
          "Pending message requests from users you don't follow will automatically expire after this period."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }

      Section("Identity Verification Rollout") {
        Picker("Mode", selection: $declarationRolloutMode) {
          Text("Shadow").tag(MLSDeclarationRolloutMode.shadow)
          Text("Soft").tag(MLSDeclarationRolloutMode.soft)
          Text("Enforce").tag(MLSDeclarationRolloutMode.full)
        }
        .disabled(isUpdatingRolloutMode || isSaving)
        .onChange(of: declarationRolloutMode) { _, newValue in
          Task { await updateDeclarationRolloutMode(newValue) }
        }

        Text(
          "Shadow logs only. Soft asks for explicit trust confirmation. Enforce blocks unverified devices."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }

      Section("Declaration Identity Chain") {
        Button {
          Task { await repairDeclarationChain() }
        } label: {
          HStack {
            if isRepairingDeclaration {
              ProgressView()
                .controlSize(.small)
              Text("Repairing...")
            } else {
              Text("Repair Declaration Chain")
            }
            Spacer()
          }
        }
        .disabled(
          isLoading || isSaving || isUpdatingRolloutMode || isRepairingDeclaration || isRotatingDeclarationRoot
            || isRecoveringDeclarationRoot
        )

        Button {
          Task { await rotateDeclarationOnlineRoot() }
        } label: {
          HStack {
            if isRotatingDeclarationRoot {
              ProgressView()
                .controlSize(.small)
              Text("Rotating Root...")
            } else {
              Text("Rotate Online Root")
            }
            Spacer()
          }
        }
        .disabled(
          isLoading || isSaving || isUpdatingRolloutMode || isRepairingDeclaration || isRotatingDeclarationRoot
            || isRecoveringDeclarationRoot
        )

        Button(role: .destructive) {
          Task { await recoverDeclarationOnlineRoot() }
        } label: {
          HStack {
            if isRecoveringDeclarationRoot {
              ProgressView()
                .controlSize(.small)
              Text("Recovering Root...")
            } else {
              Text("Recover Online Root")
            }
            Spacer()
          }
        }
        .disabled(
          isLoading || isSaving || isUpdatingRolloutMode || isRepairingDeclaration || isRotatingDeclarationRoot
            || isRecoveringDeclarationRoot
        )

        Text(
          "Repair publishes missing declaration steps. Rotate performs normal continuity rotation. Recover uses the recovery root when online root continuity is broken."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
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
              Text("Disabling...")
            } else {
              Text("Disable MLS Encrypted Chat")
            }
            Spacer()
          }
        }
        .disabled(isOptingOut || isSaving)
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
    .navigationTitle("Chat Privacy")
    .toolbarTitleDisplayMode(.inline)
    .task {
      await loadSettings()
    }
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
        ProgressView("Loading settings...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.ultraThinMaterial)
      }
    }
  }

  // MARK: - Data Loading

  @MainActor
  private func loadSettings() async {
    guard let apiClient = await appState.getMLSAPIClient() else {
      errorMessage = "MLS client not available"
      showingErrorAlert = true
      isLoading = false
      return
    }

    do {
      let settings = try await apiClient.getChatRequestSettings()
      allowFollowersBypass = settings.allowFollowersBypass ?? false
      allowFollowingBypass = settings.allowFollowingBypass ?? false
      autoExpireDays = settings.autoExpireDays ?? 0
      declarationRolloutMode = ExperimentalSettings.shared.declarationRolloutMode(for: appState.userDID)
      
      if let conversationManager = await appState.getMLSConversationManager() {
        if let policy = await conversationManager.getDeclarationChatPolicy() {
          if let who = policy.whoCanMessageMe { whoCanMessageMe = who }
          if let followers = policy.allowFollowersBypass { allowFollowersBypass = followers }
          if let following = policy.allowFollowingBypass { allowFollowingBypass = following }
          if let expire = policy.autoExpireDays { autoExpireDays = expire }
        }
      }
      isLoading = false
    } catch {
      logger.error("Failed to load chat settings: \(error.localizedDescription)")
      // Use defaults on error
      isLoading = false
    }
  }

  // MARK: - Settings Updates

  private func saveSettings(
    allowFollowersBypass: Bool? = nil,
    allowFollowingBypass: Bool? = nil,
    autoExpireDays: Int? = nil,
    whoCanMessageMe: MLSWhoCanMessageMe? = nil
  ) {
    Task {
      await saveSetting(
        allowFollowersBypass: allowFollowersBypass,
        allowFollowingBypass: allowFollowingBypass,
        autoExpireDays: autoExpireDays,
        whoCanMessageMe: whoCanMessageMe
      )
    }
  }

  @MainActor
  private func saveSetting(
    allowFollowersBypass: Bool?,
    allowFollowingBypass: Bool?,
    autoExpireDays: Int?,
    whoCanMessageMe: MLSWhoCanMessageMe?
  ) async {
    guard let apiClient = await appState.getMLSAPIClient() else { return }

    isSaving = true
    defer { isSaving = false }

    do {
      // Legacy update - ignore whoCanMessageMe as it's declaration-only
      _ = try await apiClient.updateChatRequestSettings(
        allowFollowersBypass: allowFollowersBypass,
        allowFollowingBypass: allowFollowingBypass,
        autoExpireDays: autoExpireDays
      )
      if let conversationManager = await appState.getMLSConversationManager() {
        let effectiveFollowers = allowFollowersBypass ?? self.allowFollowersBypass
        let effectiveFollowing = allowFollowingBypass ?? self.allowFollowingBypass
        let effectiveAutoExpire = autoExpireDays ?? self.autoExpireDays
        let effectiveWhoCanMessageMe = whoCanMessageMe ?? self.whoCanMessageMe
        
        do {
          try await conversationManager.ensureDeclarationChainReady()
          try await conversationManager.publishDeclarationChatPolicyUpdate(
            allowFollowersBypass: effectiveFollowers,
            allowFollowingBypass: effectiveFollowing,
            whoCanMessageMe: effectiveWhoCanMessageMe,
            autoExpireDays: effectiveAutoExpire
          )
        } catch {
          logger.error("Failed to publish declaration chat policy update: \(error.localizedDescription)")
        }
      }
      logger.debug("Chat settings saved successfully")
    } catch {
      logger.error("Failed to save chat settings: \(error.localizedDescription)")
      errorMessage = "Failed to save settings. Please try again."
      showingErrorAlert = true
      // Reload to restore server state
      await loadSettings()
    }
  }

  // MARK: - Opt Out

  @MainActor
  private func optOutOfMLS() async {
    guard let apiClient = await appState.getMLSAPIClient() else { return }

    isOptingOut = true
    defer { isOptingOut = false }

    do {
      let success = try await apiClient.optOut()
      if success {
        if let conversationManager = await appState.getMLSConversationManager() {
          _ = try? await conversationManager.publishDeclarationDeviceRevoke(
            deviceId: nil,
            reason: "mls-opt-out"
          )
        }
        // Also update local settings
        ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
        logger.info("Successfully opted out of MLS chat")
        // Navigate back after opt-out
        dismiss()
      } else {
        errorMessage = "Failed to disable MLS chat. Please try again."
        showingErrorAlert = true
      }
    } catch {
      logger.error("Failed to opt out of MLS: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  @MainActor
  private func updateDeclarationRolloutMode(_ mode: MLSDeclarationRolloutMode) async {
    isUpdatingRolloutMode = true
    defer { isUpdatingRolloutMode = false }

    ExperimentalSettings.shared.setDeclarationRolloutMode(mode, for: appState.userDID)
    if let manager = await appState.getMLSConversationManager() {
      await manager.setDeclarationRolloutMode(mode)
    }
  }

  @MainActor
  private func repairDeclarationChain() async {
    guard let manager = await appState.getMLSConversationManager() else {
      errorMessage = "MLS service is not available."
      showingErrorAlert = true
      return
    }

    isRepairingDeclaration = true
    defer { isRepairingDeclaration = false }

    do {
      try await manager.ensureDeclarationChainReady()
      logger.info("Declaration chain repair completed")
    } catch {
      logger.error("Declaration chain repair failed: \(error.localizedDescription)")
      errorMessage = "Declaration repair failed: \(error.localizedDescription)"
      showingErrorAlert = true
    }
  }

  @MainActor
  private func rotateDeclarationOnlineRoot() async {
    guard let manager = await appState.getMLSConversationManager() else {
      errorMessage = "MLS service is not available."
      showingErrorAlert = true
      return
    }

    isRotatingDeclarationRoot = true
    defer { isRotatingDeclarationRoot = false }

    do {
      _ = try await manager.rotateDeclarationOnlineRoot()
      try await manager.ensureDeclarationChainReady()
      logger.info("Declaration online root rotation completed")
    } catch {
      logger.error("Declaration online root rotation failed: \(error.localizedDescription)")
      errorMessage = "Root rotation failed: \(error.localizedDescription)"
      showingErrorAlert = true
    }
  }

  @MainActor
  private func recoverDeclarationOnlineRoot() async {
    guard let manager = await appState.getMLSConversationManager() else {
      errorMessage = "MLS service is not available."
      showingErrorAlert = true
      return
    }

    isRecoveringDeclarationRoot = true
    defer { isRecoveringDeclarationRoot = false }

    do {
      _ = try await manager.recoverDeclarationOnlineRoot(reason: "manual-recovery")
      try await manager.ensureDeclarationChainReady()
      logger.info("Declaration online root recovery completed")
    } catch {
      logger.error("Declaration online root recovery failed: \(error.localizedDescription)")
      errorMessage = "Root recovery failed: \(error.localizedDescription)"
      showingErrorAlert = true
    }
  }
}

#Preview {
  NavigationStack {
    MLSChatSettingsView()
  }
}

#endif
