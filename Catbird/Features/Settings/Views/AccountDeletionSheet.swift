import SwiftUI

struct AccountDeletionSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var flow: AccountDeletionFlow

  init(target: AccountDeletionTarget) {
    _flow = State(initialValue: AccountDeletionFlow(target: target))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Account to Delete") {
          if let handle = flow.target.handle, !handle.isEmpty {
            Text("@\(handle)")
              .font(.headline)
          }
          Text(flow.target.did)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Text("Bluesky may already be signed in to a different account. Verify that its account matches this one before choosing Delete account.")
        }

        Section("Permanent Provider Deletion") {
          Text("Deleting your account at its hosting provider is irreversible. It affects Bluesky and other AT Protocol apps you use with this account. Your provider controls deletion of the account and associated data; other services may retain copies under their own policies.")
          Text("Open Bluesky's account settings, sign in to this account if needed, then choose Delete account. Complete the provider's verification and final confirmation there. Opening settings does not send a deletion code or delete anything.")

          Button(action: openAccountSettings) {
            Label("Open Bluesky Account Settings", systemImage: "arrow.up.right")
          }
          .disabled(!flow.canOpen || appState.userDID != flow.target.did)
          .accessibilityIdentifier("AccountDeletion.OpenProvider")

          if let statusMessage {
            Text(statusMessage)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("AccountDeletion.Status")
          }
          if flow.phase == .failed {
            Text(AccountDeletionFlow.accountSettingsURL.absoluteString)
              .font(.footnote)
              .textSelection(.enabled)
          }
        }

        Section("Accounts Hosted Elsewhere") {
          Text("For a custom hosting provider, choose that provider when signing in to Bluesky. If Bluesky cannot manage your account, use your provider's documented account-deletion process. Catbird cannot confirm deletion for that provider.")
        }

        Section("Catbird Data and Sign-In") {
          Text("This flow does not submit a request to delete data held by Catbird. Signing out or removing this account from Catbird disconnects it on this device; it does not erase all Catbird-held server records or delete your provider account.")
          Text("Deactivation is separate: it temporarily disables your provider account and can be reversed. It is not permanent deletion.")
          if let privacyURL = LegalConfig.privacyPolicyURL {
            Link("Catbird Privacy Policy", destination: privacyURL)
          }
        }

        Section {
          Text("You can cancel here or return from Bluesky before its final confirmation without deleting your account. Returning to Catbird does not confirm that deletion succeeded.")
        }
      }
      .navigationTitle("Account Deletion")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            flow.cancel()
            dismiss()
          }
          .accessibilityIdentifier("AccountDeletion.Cancel")
        }
      }
      .onChange(of: appState.userDID) { _, did in
        flow.accountDidChange(to: did)
      }
      .onDisappear {
        flow.cancel()
      }
    }
  }

  private var statusMessage: String? {
    switch flow.phase {
    case .ready, .cancelled:
      return nil
    case .opening:
      return "Opening account settings…"
    case .opened:
      return "The link was opened. Catbird has not received confirmation of account deletion."
    case .failed:
      return "Account settings could not be opened. Try again, or copy the address below into your browser."
    case .accountChanged:
      return "The active account changed. Cancel and reopen Account Deletion for the account you want to delete."
    }
  }

  private func openAccountSettings() {
    guard let attempt = flow.prepareToOpen(currentDID: appState.userDID) else { return }
    openURL(attempt.url) { accepted in
      flow.finishOpening(attempt.id, accepted: accepted, currentDID: appState.userDID)
    }
  }
}
