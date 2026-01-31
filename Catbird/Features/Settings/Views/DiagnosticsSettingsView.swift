import SwiftUI
import CatbirdMLSService

struct DiagnosticsSettingsView: View {
  @Environment(AppState.self) private var appState

  @State private var isResetting = false
  @State private var showResetConfirmation = false
  @State private var error: Error?

  var body: some View {
    ResponsiveContentView {
      List {
        Section {
          Text("Troubleshooting tools. These actions never run automatically.")
            .foregroundStyle(.secondary)
            .appFont(AppTextRole.caption)
        }

        Section("MLS Storage") {
          Button(role: .destructive) {
            showResetConfirmation = true
          } label: {
            HStack {
              if isResetting {
                ProgressView()
              }
              Text(isResetting ? "Resetting…" : "Reset MLS Storage")
            }
          }
          .disabled(isResetting)

          Text("Quarantines the encrypted MLS database files and recreates a fresh database. You may need to re-sync conversations.")
            .foregroundStyle(.secondary)
            .appFont(AppTextRole.caption)
        }
      }
    }
    .navigationTitle("Diagnostics")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .confirmationDialog(
      "Reset MLS Storage?",
      isPresented: $showResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset MLS Storage", role: .destructive) {
        Task {
          await resetMLSStorage()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will quarantine existing MLS storage files and create a new empty database. This cannot be undone inside the app.")
    }
    .alert("Error", isPresented: .constant(error != nil)) {
      Button("OK") { error = nil }
    } message: {
      Text(error?.localizedDescription ?? "Unknown error")
    }
  }

  @MainActor
  private func resetMLSStorage() async {
    guard !isResetting else { return }
    isResetting = true
    defer { isResetting = false }

    do {
      try await MLSClient.shared.clearStorage(for: appState.userDID)
    } catch {
      self.error = error
    }
  }
}
