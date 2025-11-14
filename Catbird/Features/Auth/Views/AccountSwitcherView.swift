import AuthenticationServices
import OSLog
import Petrel
import SwiftUI
import NukeUI

struct AccountSwitcherView: View {
  // MARK: - Environment
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @Environment(\.dismiss) private var dismiss

  // MARK: - Presentation
  private let showsDismissButton: Bool
  
  // MARK: - Draft Transfer
  /// Optional draft to transfer when switching accounts (for composer account switching)
  private let draftToTransfer: PostComposerDraft?

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
  
  init(showsDismissButton: Bool = true, draftToTransfer: PostComposerDraft? = nil) {
    self.showsDismissButton = showsDismissButton
    self.draftToTransfer = draftToTransfer
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
      self.avatar = profile?.finalAvatarURL()
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
          EditButton()
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
        LoginView(isAddingNewAccount: true)
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
      .onChange(of: appStateManager.authentication.state) { _, newValue in
        if case .authenticated = newValue {
          // Refresh account list when auth state changes to authenticated
          Task {
            await loadAccounts()
          }
        }
      }
      .onChange(of: appStateManager.lifecycle.appState?.pendingReauthenticationRequest) { oldRequest, newRequest in
        Task { @MainActor in
          logger.info("🔔 [REAUTH-ONCHANGE] pendingReauthenticationRequest onChange triggered")
          logger.debug("🔔 [REAUTH-ONCHANGE] Old request: \(oldRequest?.handle ?? "nil") (DID: \(oldRequest?.did ?? "nil"))")
          logger.debug("🔔 [REAUTH-ONCHANGE] New request: \(newRequest?.handle ?? "nil") (DID: \(newRequest?.did ?? "nil"))")
          
          if let request = newRequest {
            // Automatically handle reauthentication when account switching fails
            logger.info("🔔 [REAUTH-ONCHANGE] Detected new reauthentication request for \(request.handle)")
            logger.info("🔔 [REAUTH-ONCHANGE] Starting handleReauthentication in Task")
            Task {
              await handleReauthentication(request)
            }
          } else {
            logger.debug("🔔 [REAUTH-ONCHANGE] Request is nil, ignoring")
          }
        }
      }
      .onChange(of: isAddingAccount) { _, newValue in
        if newValue {
          // Clear any pending reauthentication when user explicitly adds a new account
          appStateManager.lifecycle.appState?.pendingReauthenticationRequest = nil
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
            .onMove { source, destination in
              accounts.move(fromOffsets: source, toOffset: destination)
              Task {
                await saveAccountOrder()
              }
            }
          } header: {
//            Text("Your Accounts")
          } footer: {
            Text("You can add multiple Bluesky accounts and quickly switch between them. Drag to reorder.")
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
        #if os(iOS)
        // Do not force edit mode; swipe actions remain available when not editing
        #endif
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
          .shake(animatableParameter: showInvalidAnimation, appSettings: appStateManager.lifecycle.appState?.appSettings ?? AppSettings())

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
      await appStateManager.authentication.refreshAvailableAccounts()

      // Get the basic account info
      let accountInfos = appStateManager.authentication.availableAccounts

      // If we have an authenticated AppState with a client, fetch detailed profiles
      if let appState = appStateManager.lifecycle.appState,
         let client = appState.atProtoClient,
         !accountInfos.isEmpty {
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

    private func saveAccountOrder() async {
      // Save the new account order via AuthManager
      let orderedDIDs = accounts.map { $0.did }
      appStateManager.authentication.updateAccountOrder(orderedDIDs)
      logger.info("Saved account order: \(orderedDIDs)")
    }

    @MainActor
    private func switchToAccount(_ account: AccountViewModel) async {
      logger.info("🔄 [SWITCH] switchToAccount called for: \(account.handle) (DID: \(account.did))")
      logger.debug("🔄 [SWITCH] Account isActive: \(account.isActive), Has draft: \(draftToTransfer != nil)")

      guard !account.isActive else {
        logger.debug("ℹ️ [SWITCH] Account already active, returning")
        return
      }

      logger.debug("🔄 [SWITCH] Setting isLoading = true")
      isLoading = true
      defer {
        logger.debug("🔄 [SWITCH] Clearing loading state after switch attempt")
        isLoading = false
      }

      // Use AppStateManager to switch accounts - it will handle creating/retrieving the AppState for the target account
      logger.info("🔄 [SWITCH] Calling appStateManager.switchAccount(to: \(account.did), withDraft: \(draftToTransfer != nil))")
      await appStateManager.switchAccount(to: account.did, withDraft: draftToTransfer)
      logger.info("✅ [SWITCH] appStateManager.switchAccount completed")

      // Check authentication state after switch
      if case .unauthenticated = appStateManager.authentication.state {
        logger.info("🔐 [SWITCH] Account is unauthenticated, initiating reauthentication")

        // Get account info for reauthentication
        if let accountInfo = appStateManager.authentication.availableAccounts.first(where: { $0.did == account.did }) {
          let handle = accountInfo.handle ?? accountInfo.did
          logger.debug("🔐 [SWITCH] Account handle: \(handle)")

          do {
            // Start OAuth flow for this account
            logger.debug("🔐 [SWITCH] Calling authentication.addAccount(handle: \(handle))")
            let authURL = try await appStateManager.authentication.addAccount(handle: handle)
            logger.info("✅ [SWITCH] Got OAuth URL for reauthentication: \(authURL.absoluteString)")

            // Get the AppState if it exists
            guard let currentAppState = appStateManager.lifecycle.appState else {
              logger.error("❌ [SWITCH] No AppState available after switch")
              self.error = "Failed to switch account"
              isLoading = false
              return
            }

            // Create reauthentication request
            logger.debug("🔐 [SWITCH] Creating ReauthenticationRequest")
            let reauthRequest = AppState.ReauthenticationRequest(
              handle: handle,
              did: account.did,
              authURL: authURL
            )

            // Store in the AppState
            await MainActor.run {
              currentAppState.pendingReauthenticationRequest = reauthRequest
            }

            logger.info("✅ [SWITCH] Reauthentication flow initiated - triggering handleReauthentication")
            await handleReauthentication(reauthRequest)
          } catch {
            logger.error("❌ [SWITCH] Failed to initiate reauthentication: \(error.localizedDescription)")
            self.error = "Failed to switch account: \(error.localizedDescription)"
          }
        } else {
          logger.warning("⚠️ [SWITCH] No account info available for reauthentication")
          self.error = "Account not found"
        }
      } else {
        // Account is already authenticated, just refresh and dismiss
        logger.info("✅ [SWITCH] Account is authenticated, refreshing account list")
        await loadAccounts()

        logger.debug("🔄 [SWITCH] Dismissing switcher immediately after successful switch")
        dismiss()
      }
    }

    private func removeAccount(_ account: AccountViewModel) async {
      isLoading = true

      await appStateManager.authentication.removeAccount(did: account.did)

      // Refresh account list
      await loadAccounts()

      isLoading = false
    }

  private func removeAccount(_ account: AuthenticationManager.AccountInfo) async {
    isLoading = true

    await appStateManager.authentication.removeAccount(did: account.did)

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
      let authURL = try await appStateManager.authentication.addAccount(handle: cleanHandle)
      logger.debug("Auth URL for new account: \(authURL.absoluteString)")

      // Open web authentication session with timeout
      do {
        logger.info("Opening ASWebAuthenticationSession...")
        
        let callbackURL: URL = try await withThrowingTaskGroup(of: URL.self) { group in
          // Main authentication task
          group.addTask {
            if #available(iOS 17.4, *) {
              return try await self.webAuthenticationSession.authenticate(
                using: authURL,
                callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
              )
            } else {
              // Fallback on earlier versions - use the actual authURL
              return try await self.webAuthenticationSession.authenticate(
                using: authURL,
                callbackURLScheme: "catbird",
                preferredBrowserSession: .shared
              )
            }
          }
          
          // Timeout task (2 minutes)
          group.addTask {
            try await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
            throw AuthError.timeout
          }
          
          // Return the first result (either callback or timeout)
          guard let result = try await group.next() else {
            throw AuthError.unknown(NSError(domain: "Authentication", code: -1, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"]))
          }
          
          group.cancelAll()
          return result
        }

        logger.info("Authentication session completed successfully")
        logger.debug("Callback URL: \(callbackURL.absoluteString)")

        // Process callback
        try await appStateManager.authentication.handleCallback(callbackURL)

        // Success - close add account sheet
        isAddingAccount = false

        // Refresh account list
        await loadAccounts()
      } catch _ as ASWebAuthenticationSessionError {
        // User cancelled authentication
        logger.notice("Authentication was cancelled by user")
        authenticationCancelled = true
        isLoading = false
      } catch {
        // Other authentication errors (including timeout)
        logger.error("Authentication error: \(error.localizedDescription)")
        
        if case AuthError.timeout = error {
          self.error = "Authentication timed out. The authentication session took too long to complete. Please try again."
        } else {
          self.error = error.localizedDescription
        }
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
    logger.info("🔐 [REAUTH] Starting reauthentication for handle: \(request.handle)")
    logger.info("🔐 [REAUTH] DID: \(request.did)")
    logger.info("🔐 [REAUTH] Auth URL: \(request.authURL.absoluteString)")
    logger.debug("🔐 [REAUTH] Auth URL scheme: \(request.authURL.scheme ?? "no scheme")")
    logger.debug("🔐 [REAUTH] Auth URL host: \(request.authURL.host ?? "no host")")

    // Clear the pending request to prevent repeated attempts
    logger.debug("🔐 [REAUTH] Clearing pendingReauthenticationRequest")
    if let appState = appStateManager.lifecycle.appState {
      appState.pendingReauthenticationRequest = nil
    }

    // Update loading state
    logger.debug("🔐 [REAUTH] Setting isLoading = true, error = nil")
    isLoading = true
    error = nil

    // Open web authentication session with the provided auth URL with timeout
    do {
      let callbackURL: URL
      logger.info("🌐 [REAUTH] About to open ASWebAuthenticationSession...")
      logger.debug("🌐 [REAUTH] webAuthenticationSession environment value: \(String(describing: webAuthenticationSession))")
      
      // Add timeout to prevent indefinite hanging
      callbackURL = try await withThrowingTaskGroup(of: URL.self) { group in
        // Main authentication task
        group.addTask {
          self.logger.info("🌐 [REAUTH] Starting authentication task in TaskGroup")
          if #available(iOS 17.4, *) {
            self.logger.info("🌐 [REAUTH] Using iOS 17.4+ authenticate API with callback .https")
            self.logger.debug("🌐 [REAUTH] Callback: .https(host: catbird.blue, path: /oauth/callback)")
            self.logger.debug("🌐 [REAUTH] preferredBrowserSession: .shared")
            let result = try await self.webAuthenticationSession.authenticate(
              using: request.authURL,
              callback: .https(host: "catbird.blue", path: "/oauth/callback"),
              preferredBrowserSession: .shared,
              additionalHeaderFields: [:]
            )
            self.logger.info("✅ [REAUTH] authenticate() returned with callback URL: \(result.absoluteString)")
            return result
          } else {
            self.logger.info("🌐 [REAUTH] Using legacy authenticate API with callbackURLScheme")
            self.logger.debug("🌐 [REAUTH] callbackURLScheme: catbird")
            self.logger.debug("🌐 [REAUTH] preferredBrowserSession: .shared")
            let result = try await self.webAuthenticationSession.authenticate(
              using: request.authURL,
              callbackURLScheme: "catbird",
              preferredBrowserSession: .shared
            )
            self.logger.info("✅ [REAUTH] authenticate() returned with callback URL: \(result.absoluteString)")
            return result
          }
        }
        
        // Timeout task (2 minutes)
        group.addTask {
          self.logger.debug("⏱️ [REAUTH] Starting 120-second timeout task")
          try await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
          self.logger.warning("⏱️ [REAUTH] Timeout reached after 120 seconds!")
          throw AuthError.timeout
        }
        
        // Return the first result (either callback or timeout)
        self.logger.debug("🔄 [REAUTH] Waiting for first TaskGroup result...")
        guard let result = try await group.next() else {
          self.logger.error("❌ [REAUTH] TaskGroup.next() returned nil - no result available")
          throw AuthError.unknown(NSError(domain: "Authentication", code: -1, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"]))
        }
        
        self.logger.info("✅ [REAUTH] TaskGroup returned result, cancelling remaining tasks")
        group.cancelAll()
        return result
      }

      logger.info("✅ [REAUTH] Reauthentication session completed successfully")
      logger.info("🔗 [REAUTH] Callback URL: \(callbackURL.absoluteString)")
      logger.debug("🔗 [REAUTH] Callback scheme: \(callbackURL.scheme ?? "none")")
      logger.debug("🔗 [REAUTH] Callback host: \(callbackURL.host ?? "none")")

      // Process callback
      logger.info("🔄 [REAUTH] Processing callback with authManager.handleCallback()")
      try await appStateManager.authentication.handleCallback(callbackURL)
      logger.info("✅ [REAUTH] Callback processed successfully")

      // Refresh account list
      logger.debug("🔄 [REAUTH] Refreshing account list")
      await loadAccounts()

      // Try switching to the account again now that it's reauthenticated
      if let account = accounts.first(where: { $0.did == request.did }) {
        logger.info("🔄 [REAUTH] Re-attempting switch to reauthenticated account: \(account.handle)")
        await switchToAccount(account)
      } else {
        logger.warning("⚠️ [REAUTH] Could not find account with DID \(request.did) after reauthentication")
        // Still dismiss since reauthentication succeeded
        logger.debug("🔄 [REAUTH] Dismissing view after reauthentication")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          dismiss()
        }
      }

      logger.debug("🔄 [REAUTH] Setting isLoading = false")
      isLoading = false
    } catch let error as ASWebAuthenticationSessionError {
      // User cancelled reauthentication
      logger.notice("🚫 [REAUTH] Reauthentication was cancelled by user")
      logger.debug("🚫 [REAUTH] ASWebAuthenticationSessionError code: \(error.code.rawValue)")
      authenticationCancelled = true
      isLoading = false
    } catch {
      // Other authentication errors (including timeout)
      logger.error("❌ [REAUTH] Reauthentication error: \(error.localizedDescription)")
      logger.error("❌ [REAUTH] Error type: \(String(describing: type(of: error)))")
      
      if case AuthError.timeout = error {
        logger.error("⏱️ [REAUTH] Error was timeout")
        self.error = "Authentication timed out. The authentication session took too long to complete. Please try again."
      } else {
        self.error = "Failed to reauthenticate: \(error.localizedDescription)"
      }
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
