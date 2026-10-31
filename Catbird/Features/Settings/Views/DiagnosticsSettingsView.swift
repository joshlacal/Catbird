import SwiftUI
import CatbirdMLSCore

struct DiagnosticsSettingsView: View {
  @Environment(AppState.self) private var appState

  @State private var isResetting = false
  @State private var showResetConfirmation = false
  @State private var error: Error?

  var body: some View {
    ResponsiveContentView {
      List {
        Section {
          NavigationLink(destination: MLSChatDiagnosticsView()) {
            SettingsNavigationRow(
              title: "Chat Diagnostics",
              summary: "Recent send failures and recovery events",
              systemImage: "bubble.left.and.exclamationmark.bubble.right",
              family: .advanced
            )
          }
        } header: {
          Text("Encrypted Chat")
        } footer: {
          Text("These troubleshooting tools never run automatically.")
        }

        Section {
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
        } header: {
          Text("MLS Storage")
        } footer: {
          Text("Quarantines the encrypted MLS database files and recreates a fresh database. You may need to re-sync conversations.")
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
    .alert("Couldn’t Reset MLS Storage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error?.localizedDescription ?? "")
    }
  }

  @MainActor
  private func resetMLSStorage() async {
    guard !isResetting else { return }
    isResetting = true
    defer { isResetting = false }

    do {
      await appState.prepareMLSStorageReset()
      try await MLSClient.shared.clearStorage(for: appState.userDID)
    } catch {
      self.error = error
    }
  }
}

#Preview("DiagnosticsSettingsView") {
  NavigationStack {
    DiagnosticsSettingsView()
  }
  .previewWithAuthenticatedState()
}
