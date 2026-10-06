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
            } else if flow.isResolvingDestination {
              ProgressView()
                .accessibilityLabel("Finding your account provider")
            } else {
              Text("Unavailable")
                .foregroundStyle(.secondary)
            }
          }
        }

        Section {
          if flow.target.purpose == .deletionOptions {
            Text("Deleting your hosted account is permanent.")
          }
          Text(handoffExplanation)
            .foregroundStyle(.secondary)

          Button(action: openAccountPage) {
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
          .disabled(!flow.canOpen || !isCurrentAccount)
          .accessibilityIdentifier("AccountDeletion.OpenProvider")

          if let statusMessage {
            Text(statusMessage)
              .appFont(AppTextRole.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("AccountDeletion.Status")
          }
          if flow.phase == .failed, let destination = flow.destination {
            Text(destination.url.absoluteString)
              .appFont(AppTextRole.footnote)
              .textSelection(.enabled)
          }
        } footer: {
          Text("If the website is signed in to a different account, switch accounts there first. Opening this page does not change or delete an account.")
        }

        if let privacyURL = LegalConfig.privacyPolicyURL {
          Section {
            Link("Catbird Privacy Policy", destination: privacyURL)
          } footer: {
            Text("Hosted account deletion and removal of data held by Catbird are separate. See the privacy policy for Catbird data-removal instructions.")
          }
        }
      }
      .navigationTitle(flow.target.purpose == .manageAccount ? "Hosted Account" : "Account Deletion Options")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", role: .cancel) {
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
        flow.accountDidChange(to: did, revision: accountRevision)
      }
      .onChange(of: accountRevision) { _, revision in
        flow.accountDidChange(to: appState.userDID, revision: revision)
      }
      .onDisappear {
        flow.cancel()
      }
    }
  }

  private var providerHost: String? {
    flow.destination.map { AccountManagementPageResolver.displayHost(of: $0.url) }
  }

  private var accountRevision: UInt64 {
    AppStateManager.shared.settingsAccountContextRevision
  }

  private var isCurrentAccount: Bool {
    appState.userDID == flow.target.did
      && SettingsAccountBoundary.isCurrent(flow.target.did, revision: flow.target.accountRevision)
  }

  private var isOpening: Bool {
    if case .opening = flow.phase { return true }
    return false
  }

  private var continueTitle: String {
    guard let destination = flow.destination else {
      return flow.isResolvingDestination ? "Finding Your Account Provider…" : "Provider Website Unavailable"
    }
    return destination.kind == .accountSettings ? "Open Account Settings" : "Open Hosting Provider Website"
  }

  private var handoffExplanation: String {
    if flow.target.purpose == .deletionOptions {
      return "Catbird can’t delete your hosted account directly. Open your provider’s website and look for its account-deletion instructions."
    }
    if flow.destination?.kind == .providerWebsite {
      return "Open your hosting provider’s website and look for account settings to manage your handle, email, or sign-in options."
    }
    return "Manage your handle, email, and sign-in options on your hosting provider’s website."
  }

  private var statusMessage: String? {
    switch flow.phase {
    case .ready, .cancelled, .opening:
      return nil
    case .opened:
      return "The website opened. Catbird can’t confirm changes or deletion made there."
    case .failed:
      return "Couldn’t open the website. Copy this address into your browser instead:"
    case .accountChanged:
      return "Your account changed. Close this page and start again from the account you want to manage."
    case .unavailable:
      return "Your hosting provider couldn’t be resolved. Close this page and try again."
    }
  }

  private func resolveAccountPage() async {
    flow.accountDidChange(to: appState.userDID, revision: accountRevision)
    guard flow.isResolvingDestination else { return }
    let target = flow.target
    guard isCurrentAccount, let client = appState.atProtoClient else {
      flow.resolveDestination(nil, currentDID: appState.userDID, currentRevision: accountRevision)
      return
    }
    let originatingAppState = appState
    do {
      let destination = try await originatingAppState.performSettingsAccountOperation {
        try Task.checkCancellation()
        guard (await client.getCurrentAccount())?.did == target.did,
              SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
          throw CancellationError()
        }
        try Task.checkCancellation()
        let pdsURL = try await client.resolveDIDToPDSURL(did: target.did)
        try Task.checkCancellation()
        guard SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
          throw CancellationError()
        }
        return await AccountManagementPageResolver().destination(forPDS: pdsURL)
      }
      guard !Task.isCancelled else { return }
      flow.resolveDestination(destination, currentDID: appState.userDID, currentRevision: accountRevision)
    } catch {
      guard !Task.isCancelled else { return }
      flow.resolveDestination(nil, currentDID: appState.userDID, currentRevision: accountRevision)
    }
  }

  private func openAccountPage() {
    guard isCurrentAccount,
          let attempt = flow.prepareToOpen(currentDID: appState.userDID, currentRevision: accountRevision) else { return }
    openURL(attempt.url) { accepted in
      flow.finishOpening(attempt.id, accepted: accepted, currentDID: appState.userDID, currentRevision: accountRevision)
    }
  }
}
