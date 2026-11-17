import Petrel
import PetrelCatbird
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
  @State private var confirmingLocalOnlyErasure = false
  @State private var isErasingData = false
  @State private var erasureError: String?

  // Native 2-step PDS permanent account deletion (Guideline 5.1.1(v))
  @State private var isRequestingDeletionCode = false
  @State private var hasRequestedDeletionCode = false
  @State private var showManualCodeEntry = false
  @State private var deletionPassword = ""
  @State private var requiresAuthFactorToken = false
  @State private var deletionAuthFactorToken = ""
  @State private var deletionConfirmationToken = ""
  @State private var confirmingRemoteBackupErasure = false
  @State private var confirmingPermanentDeletion = false
  @State private var isDeletingHostedAccount = false
  @State private var permanentDeletionNotice: String?
  @State private var permanentDeletionError: String?

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

        if flow.target.purpose == .deletionOptions {
          Section {
            Text("Permanently delete your hosted Bluesky / AT Protocol account and all Catbird data directly in the app. Enter your account password first so your hosting provider can email a one-time confirmation code.")
              .foregroundStyle(.secondary)

            SecureField("Account password", text: $deletionPassword)
              .accessibilityIdentifier("AccountDeletion.Password")

            if requiresAuthFactorToken {
              TextField("2FA sign-in code (from email)", text: $deletionAuthFactorToken)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier("AccountDeletion.AuthFactorToken")
            }

            Button(action: requestDeletionCode) {
              HStack {
                Text(hasRequestedDeletionCode ? "Resend Email Confirmation Code" : "Send Email Confirmation Code")
                Spacer()
                if isRequestingDeletionCode {
                  ProgressView()
                } else {
                  Image(systemName: "envelope.badge.shield.half.filled")
                }
              }
            }
            .disabled(!canRequestDeletionCode)
            .accessibilityIdentifier("AccountDeletion.RequestDeleteCode")

            if !hasRequestedDeletionCode {
              Button(showManualCodeEntry ? "Hide Code Entry" : "I Already Have a Confirmation Code") {
                showManualCodeEntry.toggle()
              }
              .disabled(!isCurrentAccount || isDeletingHostedAccount)
              .accessibilityIdentifier("AccountDeletion.ToggleCodeEntry")
            }

            if let permanentDeletionNotice {
              Text(permanentDeletionNotice)
                .appFont(AppTextRole.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("AccountDeletion.CodeSentNotice")
            }

            if hasRequestedDeletionCode || showManualCodeEntry {
              TextField("Email confirmation code", text: $deletionConfirmationToken)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier("AccountDeletion.ConfirmationToken")

              Button(role: .destructive) {
                confirmingRemoteBackupErasure = true
              } label: {
                HStack {
                  Text("Permanently Delete Account")
                  Spacer()
                  if isDeletingHostedAccount {
                    ProgressView()
                  }
                }
              }
              .disabled(!canSubmitPermanentDeletion)
              .accessibilityIdentifier("AccountDeletion.ConfirmDelete")
            }

            if let permanentDeletionError {
              Text(permanentDeletionError)
                .appFont(AppTextRole.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("AccountDeletion.PermanentDeleteError")
            }
          } header: {
            Text("Delete Account Permanently")
          } footer: {
            Text("Your password is verified directly with your hosting provider in memory and is never saved. Deleting your hosted account permanently removes your profile, posts, social graph, and all Catbird encrypted chat data.")
          }
        }

        Section {
          if flow.target.purpose == .deletionOptions {
            Text("External Hosting Provider Fallback")
              .appFont(AppTextRole.subheadline)
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
              Text("Erase Catbird Cloud & Local Data")
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
              .accessibilityIdentifier("AccountDeletion.ErasureError")

            Button(role: .destructive) {
              confirmingLocalOnlyErasure = true
            } label: {
              HStack {
                Text("Sign Out & Erase Local Device Data Only")
                Spacer()
                Image(systemName: "iphone.slash")
              }
            }
            .disabled(isErasingData || !isCurrentAccount)
            .accessibilityIdentifier("AccountDeletion.EraseLocalOnly")
          }
        } header: {
          Text("Catbird Data")
        } footer: {
          Text("Erase all data held by Catbird for this account across Catbird servers and this device, including encrypted chat state, gateway sessions, push notification registrations, draft posts, and local settings.")
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
            deletionPassword = ""
            deletionAuthFactorToken = ""
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
      .confirmationDialog("Erase Catbird Cloud & Local Data?", isPresented: $confirmingDataErasure, titleVisibility: .visible) {
        Button("Erase Catbird Cloud & Local Data", role: .destructive) {
          eraseAccountData(skipRemoteMLSErasure: false)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This erases your Catbird encrypted chat cloud data, revokes your gateway session, unregisters push notifications, removes all drafts and local settings on this device, and signs you out.")
      }
      .confirmationDialog("Erase Local Device Data Only?", isPresented: $confirmingLocalOnlyErasure, titleVisibility: .visible) {
        Button("Sign Out & Erase Local Device Data Only", role: .destructive) {
          eraseAccountData(skipRemoteMLSErasure: true)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Catbird's encrypted chat servers could not be reached. Continuing will immediately sign out and erase all local keys, databases, drafts, and settings on this device, while server-side ciphertext or backups may remain until deleted later.")
      }
      .confirmationDialog(
        "Allow Encrypted Backup Erasure Before Account Deletion?",
        isPresented: $confirmingRemoteBackupErasure,
        titleVisibility: .visible
      ) {
        Button("I Understand the Risk", role: .destructive) {
          confirmingPermanentDeletion = true
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Your hosting provider cannot validate the email code without deleting the account. Catbird must erase encrypted cloud backups first while you are still signed in, and that operation also retires this device’s encrypted-chat store. If the provider then rejects or expires the code, your account will remain but that encrypted history cannot be restored from Catbird’s backups. You can retry account deletion with a new code."
        )
      }
      .confirmationDialog("Permanently Delete Hosted Account?", isPresented: $confirmingPermanentDeletion, titleVisibility: .visible) {
        Button("Permanently Delete Account", role: .destructive) {
          performPermanentAccountDeletion()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Catbird will first erase the encrypted cloud backups and device chat store you explicitly approved, then ask your hosting provider to permanently delete the account. Other local Catbird account data is removed only after the provider confirms deletion.")
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
        deletionPassword = ""
        deletionAuthFactorToken = ""
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
      return "If your external hosting provider uses passwordless OAuth and does not accept password confirmation above, you can also complete deletion on your provider’s website."
    }
    if flow.destination?.kind == .providerWebsite {
      return "Open your hosting provider’s website and look for account settings to manage your handle, email, or sign-in options."
    }
    return "Manage your handle, email, and sign-in options on your hosting provider’s website."
  }

  private var canRequestDeletionCode: Bool {
    isCurrentAccount
      && !isRequestingDeletionCode
      && !isDeletingHostedAccount
      && !deletionPassword.isEmpty
  }

  private var canSubmitPermanentDeletion: Bool {
    isCurrentAccount
      && !isDeletingHostedAccount
      && !deletionConfirmationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !deletionPassword.isEmpty
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

  private func requestDeletionCode() {
    guard canRequestDeletionCode, let client = appState.atProtoClient else { return }
    let password = deletionPassword
    let factor = deletionAuthFactorToken
    isRequestingDeletionCode = true
    permanentDeletionError = nil
    permanentDeletionNotice = nil
    let target = flow.target
    let originatingAppState = appState
    Task { @MainActor in
      defer { isRequestingDeletionCode = false }
      do {
        try await originatingAppState.performSettingsAccountOperation {
          try Task.checkCancellation()
          guard (await client.getCurrentAccount())?.did == target.did,
                SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
            throw CancellationError()
          }
          let pdsURL = try await client.resolveDIDToPDSURL(did: target.did)
          try Task.checkCancellation()
          guard SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
            throw CancellationError()
          }
          try await AccountDeletionCoordinator.requestHostedAccountDeletionCode(
            forDID: target.did,
            password: password,
            authFactorToken: factor,
            pdsURL: pdsURL
          )
        }
        hasRequestedDeletionCode = true
        permanentDeletionNotice = "Check your email for the deletion confirmation code, then enter it below to confirm permanent account deletion."
      } catch is CancellationError {
        return
      } catch let err as PDSDirectDeletionError {
        if case .authFactorTokenRequired = err {
          requiresAuthFactorToken = true
        }
        permanentDeletionError = err.localizedDescription
      } catch {
        permanentDeletionError = Self.describePermanentDeletionError(error)
      }
    }
  }

  private func performPermanentAccountDeletion() {
    guard canSubmitPermanentDeletion, let client = appState.atProtoClient else { return }
    let trimmedToken = deletionConfirmationToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = deletionPassword
    let factor = deletionAuthFactorToken
    let target = flow.target
    let originatingAppState = appState
    isDeletingHostedAccount = true
    permanentDeletionError = nil

    Task { @MainActor in
      do {
        try await originatingAppState.performSettingsAccountOperation {
          try Task.checkCancellation()
          guard (await client.getCurrentAccount())?.did == target.did,
                SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
            throw CancellationError()
          }
          let pdsURL = try await client.resolveDIDToPDSURL(did: target.did)
          try Task.checkCancellation()
          guard SettingsAccountBoundary.isCurrent(target.did, revision: target.accountRevision) else {
            throw CancellationError()
          }
          try await AccountDeletionCoordinator.performHostedAccountDeletion(
            forDID: target.did,
            password: password,
            confirmationToken: trimmedToken,
            authFactorToken: factor,
            remoteErasureConsent: .explicitlyConfirmed,
            pdsURL: pdsURL,
            modelContext: modelContext,
            appStateOverride: originatingAppState,
            clientOverride: client
          )
        }
        deletionPassword = ""
        deletionAuthFactorToken = ""
        deletionConfirmationToken = ""
        dismiss()
      } catch is CancellationError {
        isDeletingHostedAccount = false
      } catch let err as PDSDirectDeletionError {
        if case .authFactorTokenRequired = err {
          requiresAuthFactorToken = true
        }
        permanentDeletionError = err.localizedDescription
        isDeletingHostedAccount = false
      } catch {
        permanentDeletionError = Self.describePermanentDeletionError(error)
        isDeletingHostedAccount = false
      }
    }
  }

  static func describePermanentDeletionError(_ error: Error) -> String {
    if let directError = error as? PDSDirectDeletionError {
      return directError.localizedDescription
    }
    let raw = String(describing: error)
    if raw.contains("ExpiredToken") {
      return "That confirmation code has expired. Request a new email confirmation code and try again."
    }
    if raw.contains("InvalidToken") {
      return "That confirmation code is invalid. Check the code from your email and try again."
    }
    return error.localizedDescription
  }

  private func eraseAccountData(skipRemoteMLSErasure: Bool) {
    guard isCurrentAccount, !isErasingData else { return }
    isErasingData = true
    erasureError = nil
    let did = flow.target.did
    Task { @MainActor in
      do {
        try await AccountDeletionCoordinator.eraseCatbirdData(
          forDID: did,
          modelContext: modelContext,
          skipRemoteMLSErasure: skipRemoteMLSErasure
        )
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
