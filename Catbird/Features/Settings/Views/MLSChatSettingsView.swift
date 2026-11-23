import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore

#if os(iOS)

/// Settings view for MLS encrypted chat: backup and recovery, diagnostics, and opting out
struct MLSChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // Loading and error states
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

  // Opt-out confirmation
  @State private var showingOptOutConfirmation = false
  @State private var isOptingOut = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSChatSettings")

  var body: some View {
    Form {
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

#Preview {
  NavigationStack {
    MLSChatSettingsView()
  }
}

#endif
