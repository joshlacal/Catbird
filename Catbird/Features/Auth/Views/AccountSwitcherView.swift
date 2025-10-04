import AuthenticationServices
import OSLog
import Petrel
import SwiftUI
import NukeUI

struct AccountSwitcherView: View {
  // MARK: - Environment
  @Environment(AppState.self) private var appState
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @Environment(\.dismiss) private var dismiss

  // MARK: - Presentation
  private let showsDismissButton: Bool

  // MARK: - State
  @State private var accounts: [AccountViewModel] = []
  @State private var isAddingAccount = false
  @State private var newAccountHandle = ""
  @State private var error: String?
  @State private var isLoading = false
  @State private var showConfirmRemove: AccountViewModel?

  @State private var validationError: String?
  @State private var showInvalidAnimation = false
  @State private var authenticationCancelled = false

  // Logger
  private let logger = Logger(subsystem: "blue.catbird", category: "AccountSwitcher")
  
  init(showsDismissButton: Bool = true) {
    self.showsDismissButton = showsDismissButton
  }

  // Model for account display
  struct AccountViewModel: Identifiable {
    let id: String // Using DID as identifier
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?
    let isActive: Bool
    
    init(from accountInfo: AuthenticationManager.AccountInfo, profile: AppBskyActorDefs.ProfileViewDetailed?) {
      self.id = accountInfo.did
      self.did = accountInfo.did
      self.handle = profile?.handle.description ?? accountInfo.handle ?? "Unknown"
      self.displayName = profile?.displayName
      self.avatar = profile?.avatar?.url
      self.isActive = accountInfo.isActive
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        if isLoading {
          ProgressView("Loading accounts...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          accountsContentView
        }
      }
      .navigationTitle("Accounts")
      #if os(iOS)
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
      #endif
      .toolbar {
        #if os(iOS)
        if showsDismissButton {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              dismiss()
            }
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            isAddingAccount = true
          } label: {
            Image(systemName: "plus")
          }
        }
        #elseif os(macOS)
        if showsDismissButton {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              dismiss()
            }
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            isAddingAccount = true
          } label: {
            Image(systemName: "plus")
          }
        }
        #endif
      }
      .sheet(isPresented: $isAddingAccount) {
        LoginView()
              .environment(appState)
      }
      .alert(
        "Remove Account",
        isPresented: .init(
          get: { showConfirmRemove != nil },
          set: { if !$0 { showConfirmRemove = nil } }
        ),
        presenting: showConfirmRemove
      ) { account in
        Button("Remove", role: .destructive) {
          Task {
            await removeAccount(account)
          }
        }
        Button("Cancel", role: .cancel) {
          showConfirmRemove = nil
        }
      } message: { account in
        Text(
          "Are you sure you want to remove the account '\(account.handle)'? You can add it again later."
        )
      }
      .onChange(of: appState.authManager.state) { _, newValue in
        if case .authenticated = newValue {
          // Refresh account list when auth state changes to authenticated
          Task {
            await loadAccounts()
          }
        }
      }
      .onChange(of: appState.pendingReauthenticationRequest) { _, newRequest in
        if let request = newRequest {
          // Automatically handle reauthentication when account switching fails
          Task {
            await handleReauthentication(request)
          }
        }
      }
      .task {
        await loadAccounts()
      }
    }
  }

  // MARK: - Account List View

  private var accountsContentView: some View {
    Group {
      if accounts.isEmpty {
        ContentUnavailableView(
          "No Accounts",
          systemImage: "person.crop.circle.badge.exclamationmark",
          description: Text("You don't have any Bluesky accounts set up.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          Section {
            ForEach(accounts) { account in
              accountRow(for: account)
            }
          } header: {
            Text("Your Accounts")
          } footer: {
            Text("You can add multiple Bluesky accounts and quickly switch between them.")
          }

          if let errorMessage = error {
            Section {
              VStack(alignment: .leading, spacing: 8) {
                Text("Error")
                  .appFont(AppTextRole.headline)
                  .foregroundStyle(.red)

                Text(errorMessage)
                  .appFont(AppTextRole.callout)
                  .foregroundStyle(.secondary)

                Button("Dismiss") {
                  error = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
              }
              .padding(.vertical, 8)
            }
          }
        }
      }
    }
  }

  private func accountRow(for account: AccountViewModel) -> some View {
    HStack(spacing: 12) {
      // Avatar
      ProfileAvatarView(url: account.avatar, fallbackText: account.handle.prefix(1).uppercased())
        .frame(width: 36, height: 36)

      // Account info
      VStack(alignment: .leading, spacing: 2) {
        Text(account.displayName ?? "@" + account.handle)
          .appFont(AppTextRole.headline)
          .lineLimit(1)

        Text("@\(account.handle)")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if account.isActive {
        Text("Active")
          .appFont(AppTextRole.caption)
          .padding(6)
          .background(.tint.opacity(0.1))
          .foregroundStyle(.tint)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !account.isActive else { return }
      Task {
        await switchToAccount(account)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if !account.isActive {
        Button(role: .destructive) {
          showConfirmRemove = account
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }

  // MARK: - Add Account Sheet

  private var addAccountSheet: some View {
    NavigationStack {
      VStack(spacing: 24) {
        // Header
        VStack(spacing: 16) {
          Image(systemName: "person.crop.circle.badge.plus")
            .appFont(size: 50)
            .foregroundStyle(.tint)
            .padding()

          Text("Add Bluesky Account")
            .appFont(AppTextRole.title2)

          Text("Enter your Bluesky handle to sign in to another account.")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .padding(.top)

        // Input form
        VStack(spacing: 16) {
          Group {
            #if os(iOS)
            ValidatingTextField(
              text: $newAccountHandle,
              prompt: "username.bsky.social",
              icon: "at",
              validationError: validationError,
              isDisabled: isLoading,
              keyboardType: .emailAddress,
              submitLabel: .go,
              onSubmit: {
                addNewAccount()
              }
            )
            #elseif os(macOS)
            ValidatingTextField(
              text: $newAccountHandle,
              prompt: "username.bsky.social",
              icon: "at",
              validationError: validationError,
              isDisabled: isLoading,
              submitLabel: .go,
              onSubmit: {
                addNewAccount()
              }
            )
            #endif
          }
          .shake(animatableParameter: showInvalidAnimation, appSettings: appState.appSettings)

          if isLoading {
            HStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)

              Text("Authenticating...")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 12))
          } else {
            Button {
              addNewAccount()
            } label: {
              Text("Add Account")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(newAccountHandle.isEmpty)
          }
        }
        .padding(.horizontal)

        // Canceled auth toast
        if authenticationCancelled {
          HStack {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
            Text("Authentication cancelled")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.systemBackground.opacity(0.8))
          .clipShape(Capsule())
          .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .onAppear {
            // Reset the canceled state after a few seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
              withAnimation {
                authenticationCancelled = false
              }
            }
          }
        }

        Spacer()
      }
      #if os(iOS)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Cancel", systemImage: "xmark") {
            isAddingAccount = false
          }
        }
      }
    }
  }

  // MARK: - Data Methods
    
    private func loadAccounts() async {
      isLoading = true
      defer { isLoading = false }

      // First refresh available accounts
      await appState.authManager.refreshAvailableAccounts()

      // Get the basic account info
      let accountInfos = appState.authManager.availableAccounts
      
      // If we have an ATP client, fetch detailed profiles for all accounts
      if let client = appState.atProtoClient, !accountInfos.isEmpty {
        do {
          // Create identifiers for all accounts
          let actors = try accountInfos.map { try ATIdentifier(string: $0.did) }
          
          // Fetch profiles for all accounts in a single API call
          let (responseCode, profilesData) = try await client.app.bsky.actor.getProfiles(
            input: .init(actors: actors)
          )
          
          if responseCode == 200, let profilesData = profilesData {
            // Map the accounts with their profiles
            accounts = accountInfos.map { accountInfo in
              // Find the profile that matches this account's DID
              let matchingProfile = profilesData.profiles.first {
                $0.did.description == accountInfo.did
              }
              
              return AccountViewModel(from: accountInfo, profile: matchingProfile)
            }
          } else {
            // If profiles fetch fails, just use basic account info
            accounts = accountInfos.map { AccountViewModel(from: $0, profile: nil) }
            logger.warning("Failed to fetch profiles with code \(responseCode)")
          }
        } catch {
          // If profiles fetch fails, just use basic account info
          accounts = accountInfos.map { AccountViewModel(from: $0, profile: nil) }
          logger.warning("Error fetching profiles: \(error.localizedDescription)")
        }
      } else {
        // If no client available, just use basic account info
        accounts = accountInfos.map { AccountViewModel(from: $0, profile: nil) }
      }
    }

    private func switchToAccount(_ account: AccountViewModel) async {
      guard !account.isActive else { return }

      isLoading = true

      do {
        // Use AppState's switchToAccount which has enhanced error handling and reauthentication
        try await appState.switchToAccount(did: account.did)

        // Refresh account list
        await loadAccounts()

        // Close the account switcher
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          dismiss()
        }
      } catch {
        // If we get here, reauthentication wasn't possible or failed
        // The error will be shown to the user, but reauthentication might be triggered automatically
        logger.error("Failed to switch account: \(error.localizedDescription)")
        if appState.pendingReauthenticationRequest == nil {
          // Only show error if reauthentication wasn't triggered
          self.error = "Failed to switch account: \(error.localizedDescription)"
        }
      }

      isLoading = false
    }

    private func removeAccount(_ account: AccountViewModel) async {
      isLoading = true

      await appState.authManager.removeAccount(did: account.did)

      // Refresh account list
      await loadAccounts()

      isLoading = false
    }

  private func removeAccount(_ account: AuthenticationManager.AccountInfo) async {
    isLoading = true

    await appState.authManager.removeAccount(did: account.did)

    // Refresh account list
    await loadAccounts()

    isLoading = false
  }

  private func addNewAccount() {
    // Validate handle format
    guard validateHandle(newAccountHandle) else {
      return
    }

    // Start authentication process
    Task {
      await startAddAccount()
    }
  }

  private func validateHandle(_ handle: String) -> Bool {
    let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)

    // Simple validation - must contain a dot or @ symbol
    guard trimmedHandle.contains(".") || trimmedHandle.contains("@") else {
      logger.warning("Invalid handle format: \(trimmedHandle)")
      validationError = "Please include a domain (example.bsky.social)"
      showInvalidAnimation = true
      // Reset animation flag after a delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        showInvalidAnimation = false
      }
      return false
    }

    // Clear validation error
    validationError = nil
    return true
  }

  private func startAddAccount() async {
    logger.info("Starting add account flow for handle: \(newAccountHandle)")

    // Update state
    isLoading = true
    error = nil

    // Clean up handle - remove @ prefix and whitespace
    let cleanHandle = newAccountHandle.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "@", with: "")

    do {
      // Get auth URL
      let authURL = try await appState.authManager.addAccount(handle: cleanHandle)

      // Open web authentication session
      do {
          let callbackURL: URL
          if #available(iOS 17.4, *) {
              callbackURL = try await webAuthenticationSession.authenticate(
                using: authURL,
                callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
              )
          } else {
              // Fallback on earlier versions
              callbackURL = try await webAuthenticationSession.authenticate(using: URL(string: "https://catbird/oauth/callback")!, callbackURLScheme: "catbird", preferredBrowserSession: .shared
                )
          }

        logger.info("Authentication session completed successfully")

        // Process callback
        try await appState.authManager.handleCallback(callbackURL)

        // Success - close add account sheet
        isAddingAccount = false

        // Refresh account list
        await loadAccounts()
      } catch _ as ASWebAuthenticationSessionError { // Replace authSessionError with _
        // User cancelled authentication
        logger.notice("Authentication was cancelled by user")
        authenticationCancelled = true
        isLoading = false
      } catch {
        // Other authentication errors
        logger.error("Authentication error: \(error.localizedDescription)")
        self.error = error.localizedDescription
        isLoading = false
      }

    } catch {
      // Error starting login flow
      logger.error("Error starting add account: \(error.localizedDescription)")
      self.error = error.localizedDescription
      isLoading = false
    }
  }

  private func handleReauthentication(_ request: AppState.ReauthenticationRequest) async {
    logger.info("Handling automatic reauthentication for handle: \(request.handle)")

    // Clear the pending request to prevent repeated attempts
    appState.pendingReauthenticationRequest = nil

    // Update loading state
    isLoading = true
    error = nil

    // Open web authentication session with the provided auth URL
    do {
      let callbackURL: URL
      if #available(iOS 17.4, *) {
        callbackURL = try await webAuthenticationSession.authenticate(
          using: request.authURL,
          callback: .https(host: "catbird.blue", path: "/oauth/callback"),
          preferredBrowserSession: .shared,
          additionalHeaderFields: [:]
        )
      } else {
        // Fallback on earlier versions
        callbackURL = try await webAuthenticationSession.authenticate(
          using: URL(string: "https://catbird/oauth/callback")!,
          callbackURLScheme: "catbird",
          preferredBrowserSession: .shared
        )
      }

      logger.info("Reauthentication session completed successfully")

      // Process callback
      try await appState.authManager.handleCallback(callbackURL)

      // Refresh account list
      await loadAccounts()

      // Try switching to the account again now that it's reauthenticated
      if let account = accounts.first(where: { $0.did == request.did }) {
        await switchToAccount(account)
      }

      isLoading = false
    } catch _ as ASWebAuthenticationSessionError {
      // User cancelled reauthentication
      logger.notice("Reauthentication was cancelled by user")
      authenticationCancelled = true
      isLoading = false
    } catch {
      // Other authentication errors
      logger.error("Reauthentication error: \(error.localizedDescription)")
      self.error = "Failed to reauthenticate: \(error.localizedDescription)"
      isLoading = false
    }
  }
}

struct ProfileAvatarView: View {
  let url: URL?
  let fallbackText: String
  var size: CGFloat = 40
  
  var body: some View {
    ZStack {
      Circle()
        .fill(Color.blue.opacity(0.2))
        .frame(width: size, height: size)
      
      if let url = url {
        LazyImage(url: url) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: size, height: size)
              .clipShape(Circle())
          } else {
            Text(fallbackText)
              .appFont(size: size * 0.5)
              .foregroundColor(.white)
          }
        }
      } else {
        Text(fallbackText)
          .appFont(size: size * 0.5)
          .foregroundColor(.white)
      }
    }
  }
}
