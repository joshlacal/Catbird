import SwiftUI
import SwiftData
#if canImport(SafariServices)
import SafariServices
#endif

struct IdentifiableURL: Identifiable {
  let id = UUID()
  let url: URL
}

struct AccountDeletionSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.modelContext) private var modelContext
  @State private var flow: AccountDeletionFlow
  @State private var inAppBrowserURL: IdentifiableURL?
  @State private var confirmingDataErasure = false
  @State private var isErasingData = false
  @State private var erasureError: String?

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

        Section {
          Button(role: .destructive) {
            confirmingDataErasure = true
          } label: {
            HStack {
              Text("Erase Catbird Data & Sign Out")
              Spacer()
              if isErasingData {
                ProgressView()
              }
            }
          }
          .disabled(isErasingData || !isCurrentAccount)
          .accessibilityIdentifier("AccountDeletion.EraseData")

          if let erasureError {
            Text(erasureError)
              .appFont(AppTextRole.footnote)
              .foregroundStyle(.red)
          }
        } header: {
          Text("Catbird Data")
        } footer: {
          Text("Erase all data held by Catbird for this account, including gateway sessions, push notification registrations, draft posts, and local settings on this device.")
        }

        if let privacyURL = LegalConfig.privacyPolicyURL {
          Section {
            Link("Catbird Privacy Policy", destination: privacyURL)
          } footer: {
            Text("Hosted account deletion and removal of data held by Catbird are separate. See the privacy policy for Catbird data-removal instructions.")
          }
        }
      }
      .navigationTitle(flow.target.purpose == .manageAccount ? "Manage Hosted Account" : "Delete Account")
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
      #if os(iOS)
      .sheet(item: $inAppBrowserURL) { item in
        SafariView(url: item.url)
      }
      #endif
      .confirmationDialog("Erase Catbird Data & Sign Out?", isPresented: $confirmingDataErasure, titleVisibility: .visible) {
        Button("Erase Catbird Data & Sign Out", role: .destructive) {
          eraseAccountData()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will revoke your gateway session, unregister push notifications, remove all drafts and local settings for this account on this device, and sign you out.")
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
    if flow.target.purpose == .deletionOptions {
      return destination.kind == .accountSettings ? "Continue Account Deletion" : "Open Hosting Provider Website"
    }
    return destination.kind == .accountSettings ? "Open Account Settings" : "Open Hosting Provider Website"
  }

  private var handoffExplanation: String {
    if flow.target.purpose == .deletionOptions {
      return "Catbird can’t delete your hosted account directly. Open your provider’s website to complete deletion of your account and hosted data."
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
        return await AccountManagementPageResolver().destination(
          forPDS: pdsURL,
          accountHandle: target.handle,
          userDID: target.did
        )
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
    #if os(iOS)
    inAppBrowserURL = IdentifiableURL(url: attempt.url)
    flow.finishOpening(attempt.id, accepted: true, currentDID: appState.userDID, currentRevision: accountRevision)
    #else
    openURL(attempt.url) { accepted in
      flow.finishOpening(attempt.id, accepted: accepted, currentDID: appState.userDID, currentRevision: accountRevision)
    }
    #endif
  }

  private func eraseAccountData() {
    guard isCurrentAccount, !isErasingData else { return }
    isErasingData = true
    let did = flow.target.did
    Task { @MainActor in
      do {
        try await AccountDeletionCoordinator.eraseCatbirdData(forDID: did, modelContext: modelContext)
        dismiss()
      } catch {
        erasureError = error.localizedDescription
        isErasingData = false
      }
    }
  }
}

#if os(iOS)
struct SafariView: UIViewControllerRepresentable {
  let url: URL
  var onDismiss: (() -> Void)? = nil

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let configuration = SFSafariViewController.Configuration()
    configuration.entersReaderIfAvailable = false
    let controller = SFSafariViewController(url: url, configuration: configuration)
    controller.dismissButtonStyle = .close
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onDismiss: onDismiss)
  }

  final class Coordinator: NSObject, SFSafariViewControllerDelegate {
    let onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)?) {
      self.onDismiss = onDismiss
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
      onDismiss?()
    }
  }
}
#endif
