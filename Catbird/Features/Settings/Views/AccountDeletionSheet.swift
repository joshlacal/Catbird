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
        Section("Account") {
          if let handle = flow.target.handle, !handle.isEmpty {
            Text("@\(handle)")
              .appFont(AppTextRole.headline)
          } else {
            Text(flow.target.did)
              .appFont(AppTextRole.footnote)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          LabeledContent("Account Provider") {
            if let host = providerHost {
              Text(host)
            } else {
              ProgressView()
                .accessibilityLabel("Finding your account provider")
            }
          }
        }

        Section {
          Text("Deleting your account is permanent and can’t be undone.")
          Text("Catbird can’t delete accounts directly. You’ll finish on your account provider’s website: sign in there if asked, then choose Delete account.")
            .foregroundStyle(.secondary)

          Button(role: .destructive, action: openAccountPage) {
            HStack {
              Text(continueTitle)
              Spacer()
              if flow.isResolvingDestination || isOpening {
                ProgressView()
              } else {
                Image(systemName: "arrow.up.right")
              }
            }
          }
          .disabled(!flow.canOpen || appState.userDID != flow.target.did)
          .accessibilityIdentifier("AccountDeletion.OpenProvider")

          if let statusMessage {
            Text(statusMessage)
              .appFont(AppTextRole.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("AccountDeletion.Status")
          }
          if flow.phase == .failed, let destination = flow.destination {
            Text(destination.absoluteString)
              .appFont(AppTextRole.footnote)
              .textSelection(.enabled)
          }
        } footer: {
          Text("If the website is signed in to a different account, switch accounts there first. Want a break instead? Deactivating your account is reversible.")
        }

        if let privacyURL = LegalConfig.privacyPolicyURL {
          Section {
            Link("Catbird Privacy Policy", destination: privacyURL)
          } footer: {
            Text("Explains what Catbird stores and how to remove it.")
          }
        }
      }
      .navigationTitle("Delete Account")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            flow.cancel()
            dismiss()
          }
          .accessibilityIdentifier("AccountDeletion.Cancel")
        }
      }
      .task {
        await resolveAccountPage()
      }
      .onChange(of: appState.userDID) { _, did in
        flow.accountDidChange(to: did)
      }
      .onDisappear {
        flow.cancel()
      }
    }
  }

  private var providerHost: String? {
    flow.destination.map(AccountManagementPageResolver.displayHost(of:))
  }

  private var isOpening: Bool {
    if case .opening = flow.phase { return true }
    return false
  }

  private var continueTitle: String {
    guard let providerHost else { return "Finding Your Account Provider…" }
    return "Continue to \(providerHost)"
  }

  private var statusMessage: String? {
    switch flow.phase {
    case .ready, .cancelled, .opening:
      return nil
    case .opened:
      return "Finish deleting your account on \(providerHost ?? "your provider’s website"). Catbird can’t confirm when it’s done."
    case .failed:
      return "Couldn’t open the website. Copy this address into your browser instead:"
    case .accountChanged:
      return "You switched accounts. Close this and start again from the account you want to delete."
    }
  }

  private func resolveAccountPage() async {
    guard flow.isResolvingDestination else { return }
    let did = flow.target.did
    var pdsURL: URL?
    if !did.isEmpty, let client = appState.atProtoClient {
      pdsURL = try? await client.resolveDIDToPDSURL(did: did)
    }
    let pageURL = await AccountManagementPageResolver().accountPageURL(forPDS: pdsURL)
    guard !Task.isCancelled else { return }
    flow.resolveDestination(pageURL)
  }

  private func openAccountPage() {
    guard let attempt = flow.prepareToOpen(currentDID: appState.userDID) else { return }
    openURL(attempt.url) { accepted in
      flow.finishOpening(attempt.id, accepted: accepted, currentDID: appState.userDID)
    }
  }
}
