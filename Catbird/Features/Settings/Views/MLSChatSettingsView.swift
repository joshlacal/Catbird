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

      MLSRequestDeliverySettingsSection()

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
          "This expiry applies to legacy invitations. Encrypted introductions remain pending until you accept or close them."
        )
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      }
      // MARK: - Backup & Recovery

      Section("Backup & Recovery") {
        NavigationLink(
          destination: LabyrinthSettingsAndRestoreView(
            coordinator: appState.mlsCoordinator,
            currentDeviceId: appState.resolvedMLSDeviceID()
          )
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
        ProgressView("Loading settings…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.ultraThinMaterial)
      }
    }
  }

  // MARK: - Data Loading

  private var settingsKeyPrefix: String {
    "blue.catbird.mls.privacy.\(appState.userDID.lowercased())"
  }

  @MainActor
  private func loadSettings() async {
    let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
    let prefix = settingsKeyPrefix
    if let rawWho = defaults.string(forKey: "\(prefix).whoCanMessageMe"),
       let parsed = MLSWhoCanMessageMe(rawValue: rawWho) {
      whoCanMessageMe = parsed
    }
    if defaults.object(forKey: "\(prefix).allowFollowersBypass") != nil {
      allowFollowersBypass = defaults.bool(forKey: "\(prefix).allowFollowersBypass")
    }
    if defaults.object(forKey: "\(prefix).allowFollowingBypass") != nil {
      allowFollowingBypass = defaults.bool(forKey: "\(prefix).allowFollowingBypass")
    }
    let storedExpire = defaults.integer(forKey: "\(prefix).autoExpireDays")
    if storedExpire > 0 {
      autoExpireDays = storedExpire
    }
    _ = await appState.getOrOpenMLSCoordinator()
    isLoading = false
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
    isSaving = true
    defer { isSaving = false }
    let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
    let prefix = settingsKeyPrefix
    if let allowFollowersBypass {
      defaults.set(allowFollowersBypass, forKey: "\(prefix).allowFollowersBypass")
    }
    if let allowFollowingBypass {
      defaults.set(allowFollowingBypass, forKey: "\(prefix).allowFollowingBypass")
    }
    if let autoExpireDays {
      defaults.set(autoExpireDays, forKey: "\(prefix).autoExpireDays")
    }
    if let whoCanMessageMe {
      defaults.set(whoCanMessageMe.rawValue, forKey: "\(prefix).whoCanMessageMe")
    }
    logger.debug("Chat settings saved locally")
  }

  // MARK: - Opt Out

  @MainActor
  private func optOutOfMLS() async {
    isOptingOut = true
    defer { isOptingOut = false }
    ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
    logger.info("Disabled MLS chat for current account")
    dismiss()
  }

}

#Preview {
  NavigationStack {
    MLSChatSettingsView()
  }
}

#endif
