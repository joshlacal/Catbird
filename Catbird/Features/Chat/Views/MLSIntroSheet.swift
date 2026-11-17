import OSLog
import SwiftUI

/// One-time introduction to encrypted chat, shown before the account's first device
/// enrollment. Enrollment publishes device key records to the user's repository, so it waits
/// for "Continue". "Not now" turns encrypted chat off for the account; Settings > Chat turns
/// it back on.
struct MLSIntroSheet: View {
  let onContinue: () -> Void
  let onNotNow: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .center, spacing: 12) {
          Image(systemName: "lock.shield")
            .font(.system(size: 52))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          Text("Encrypted Chat")
            .font(.title2.weight(.semibold))
          Text("Catbird adds end-to-end encrypted conversations next to your Bluesky messages.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 18) {
          row(
            systemImage: "bubble.left.and.bubble.right",
            title: "One inbox",
            detail: "Encrypted chats appear in the same list as your Bluesky messages, marked with a lock."
          )
          row(
            systemImage: "key",
            title: "Keys for this device",
            detail: "Catbird creates encryption keys on this device and publishes its public device keys to your account's repository so others can start encrypted chats with you."
          )
          row(
            systemImage: "archivebox",
            title: "Encrypted backup",
            detail: "Your encrypted history is backed up to your own account, so you can restore it on a new device."
          )
          row(
            systemImage: "gearshape",
            title: "Your choice",
            detail: "You can turn encrypted chat off at any time in Settings > Chat."
          )
        }

        VStack(spacing: 12) {
          Button(action: onContinue) {
            Text("Continue")
              .font(.headline)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .accessibilityIdentifier("mlsIntro.continue")

          Button("Not now", action: onNotNow)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("mlsIntro.notNow")
        }
      }
      .padding(24)
    }
    .interactiveDismissDisabled()
  }

  private func row(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body.weight(.semibold))
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Presents `MLSIntroSheet` once per account. Attach it with `.background(...)` so the chat
/// screen's own body does not grow by another presentation modifier.
struct MLSIntroSheetHost: View {
  @Environment(AppState.self) private var appState
  @State private var isPresented = false
  @State private var presentedAccountDID: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSIntro")

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onAppear(perform: evaluate)
      .onChange(of: appState.userDID) { _, _ in evaluate() }
      .sheet(isPresented: $isPresented) {
        MLSIntroSheet(
          onContinue: { respond(accept: true) },
          onNotNow: { respond(accept: false) }
        )
        .presentationDetents([.large])
      }
  }

  private func evaluate() {
    let did = appState.userDID
    let shouldPresent = !appState.isMLSRuntimeAllowed
      && ExperimentalSettings.shared.shouldPresentMLSIntro(for: did)
    presentedAccountDID = shouldPresent ? did : nil
    isPresented = shouldPresent
  }

  private func respond(accept: Bool) {
    let did = presentedAccountDID
    isPresented = false
    guard let did, did == appState.userDID else { return }
    Task { @MainActor in
      if accept {
        do {
          try await appState.optInToMLSChat()
        } catch {
          logger.error("Encrypted chat setup after the introduction failed: \(error.localizedDescription)")
        }
      } else {
        do {
          try await appState.optOutOfMLSChat()
        } catch {
          logger.error("Encrypted chat opt-out after the introduction failed: \(error.localizedDescription)")
        }
      }
    }
  }
}

#Preview {
  MLSIntroSheet(onContinue: {}, onNotNow: {})
}
