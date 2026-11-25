import CatbirdMLSCore
import OSLog
import SwiftUI

/// Compact MLS opt-in gate displayed inline when Catbird Groups aren't enabled.
struct MLSOptInGateView: View {
  @Environment(AppState.self) private var appState
  @State private var isOptingIn = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSOptInGate")

  private var isEnabled: Bool {
    appState.isMLSRuntimeAllowed
  }

  var body: some View {
    if let eligibility = appState.spacesEligibility, !eligibility.eligible {
      MLSSpacesRequiredGateView(
        eligibility: eligibility,
        onReauthorizeScopes: { present in
          await appState.reauthorizeSpacesForMLS(present: present)
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
          .appFont(AppTextRole.title3)
          .fontWeight(.semibold)

        Text("End-to-end encrypted post-quantum chat backed by ATProto Spaces.")
          .appFont(AppTextRole.subheadline)
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
    // Turning this on is the user's choice; a failure or an ineligible account leaves the
    // preference on and the Spaces gate above explains what is missing.
    do {
      try await appState.optInToMLSChat()
      logger.info("Successfully enabled MLS via MLSClientCoordinator")
    } catch {
      logger.error("Failed to enable MLS: \(error.localizedDescription)")
    }
  }
}
