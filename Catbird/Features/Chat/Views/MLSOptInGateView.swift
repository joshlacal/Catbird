import CatbirdMLSCore
import OSLog
import SwiftUI

/// Compact MLS opt-in gate displayed inline when Catbird Groups aren't enabled.
struct MLSOptInGateView: View {
  @Environment(AppState.self) private var appState
  @State private var isOptingIn = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSOptInGate")

  private var isEnabled: Bool {
    #if DEBUG
    if CatbirdGatewayConfiguration.current.isRuntimeFixture {
      return true
    }
    #endif
    return ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }

  var body: some View {
    if let eligibility = appState.spacesEligibility, !eligibility.eligible {
      MLSSpacesRequiredGateView(
        eligibility: eligibility,
        onReauthorizeScopes: {
          Task { await appState.reauthorizeSpacesForMLS() }
        },
        onRefreshCheck: {
          await optIn()
        }
      )
    } else {
      VStack(spacing: 24) {
        Spacer()

        Image(systemName: "lock.shield")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)

        Text("Catbird Groups")
          .font(.title3)
          .fontWeight(.semibold)

        Text("End-to-end encrypted post-quantum chat backed by ATProto Spaces.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)

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
  }

  @MainActor
  private func optIn() async {
    isOptingIn = true
    defer { isOptingIn = false }
    do {
      try await appState.initializeMLS()
      if let eligibility = appState.spacesEligibility, !eligibility.eligible {
        ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
        return
      }
      ExperimentalSettings.shared.enableMLSChat(for: appState.userDID)
      logger.info("Successfully enabled MLS via MLSClientCoordinator")
    } catch {
      logger.error("Failed to enable MLS: \(error.localizedDescription)")
      ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
    }
  }
}
