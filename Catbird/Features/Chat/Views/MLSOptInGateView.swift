import CatbirdMLSCore
import OSLog
import SwiftUI

#if os(iOS)

/// Compact MLS opt-in gate displayed inline when Catbird Groups aren't enabled.
struct MLSOptInGateView: View {
  @Environment(AppState.self) private var appState
  @State private var isOptingIn = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSOptInGate")

  private var isEnabled: Bool {
    ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "lock.shield")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)

      Text("Catbird Groups")
        .font(.title3)
        .fontWeight(.semibold)

      Text("End-to-end encrypted group chat using the MLS protocol.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      VStack(spacing: 8) {
        Label("Highly Experimental", systemImage: "exclamationmark.triangle.fill")
          .font(.headline)
          .foregroundStyle(.orange)

        Text("This feature is under active development. You may experience bugs or missing messages.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      if isOptingIn {
        ProgressView("Enabling Catbird Groups...")
      } else {
        Toggle(isOn: Binding(
          get: { isEnabled },
          set: { newValue in
            if newValue {
              ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
              Task { await optIn() }
            }
          }
        )) {
          Text("Enable Catbird Groups")
            .fontWeight(.medium)
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 48)
      }

      Spacer()
    }
  }

  @MainActor
  private func optIn() async {
    isOptingIn = true
    defer { isOptingIn = false }
    do {
      try await appState.initializeMLS()
      guard let apiClient = await appState.getMLSAPIClient() else { return }
      _ = try await apiClient.optIn()
      if let manager = await appState.getMLSConversationManager() {
        try? await manager.ensureDeviceRecordPublished()
      }
      ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
      logger.info("Successfully opted in to MLS")
    } catch {
      logger.error("Failed to opt in to MLS: \(error.localizedDescription)")
      ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
    }
  }
}

#endif
