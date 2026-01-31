import OSLog
import Petrel
import SwiftUI
import CatbirdMLSService

#if os(iOS)

/// Settings view for MLS encrypted chat privacy and safety options
struct MLSChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // Settings state
  @State private var allowFollowersBypass: Bool = true
  @State private var allowFollowingBypass: Bool = false
  @State private var autoExpireDays: Int = 7

  // Loading and error states
  @State private var isLoading = true
  @State private var isSaving = false
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
      allowFollowersBypass = settings.allowFollowersBypass
      allowFollowingBypass = settings.allowFollowingBypass
      autoExpireDays = settings.autoExpireDays
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
    autoExpireDays: Int? = nil
  ) {
    Task {
      await saveSetting(
        allowFollowersBypass: allowFollowersBypass,
        allowFollowingBypass: allowFollowingBypass,
        autoExpireDays: autoExpireDays
      )
    }
  }

  @MainActor
  private func saveSetting(
    allowFollowersBypass: Bool?,
    allowFollowingBypass: Bool?,
    autoExpireDays: Int?
  ) async {
    guard let apiClient = await appState.getMLSAPIClient() else { return }

    isSaving = true
    defer { isSaving = false }

    do {
      _ = try await apiClient.updateChatRequestSettings(
        allowFollowersBypass: allowFollowersBypass,
        allowFollowingBypass: allowFollowingBypass,
        autoExpireDays: autoExpireDays
      )
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
}

#Preview {
  NavigationStack {
    MLSChatSettingsView()
  }
}

#endif
