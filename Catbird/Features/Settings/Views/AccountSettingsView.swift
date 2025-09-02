import SwiftUI
import Petrel
import OSLog

struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoading = true
    @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
    @State private var accountInfo: ComAtprotoServerDescribeServer.Output?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AccountSettings")
    
    // Email verification
    @State private var isEmailVerified = false
    @State private var email = ""
    @State private var isShowingEmailSheet = false
    
    // Handle management
    @State private var isShowingHandleSheet = false
    @State private var checkingAvailability = false
    
    // Account management
    @State private var isShowingDeactivateAlert = false
    @State private var isShowingDeleteAlert = false
    @State private var deactivateConfirmText = ""
    @State private var deleteConfirmText = ""
    @State private var formError: String?
    @State private var showingFormError = false
    
    // Export data
    @State private var isExporting = false
    @State private var exportCompleted = false
    
    
    // Email verification polling
    @State private var verificationPollingTimer: Timer?
    
    // MARK: - Error Handling
    
    private func handleAPIError(_ error: Error, operation: String) {
        let errorMessage: String
        
        // Check for network errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                errorMessage = "No internet connection. Please check your connection and try again."
            case .timedOut:
                errorMessage = "Request timed out. Please try again."
            case .networkConnectionLost:
                errorMessage = "Network connection lost. Please try again."
            default:
                errorMessage = "Network error occurred. Please try again."
            }
        } else {
            // Use our centralized error handler for consistent messaging
            let (_, userMessage, requiresReAuth) = AuthenticationErrorHandler.categorizeError(error)
            if requiresReAuth {
                errorMessage = "\(userMessage) You may need to sign in again to continue."
            } else {
                errorMessage = userMessage
            }
        }
        
        formError = errorMessage
        showingFormError = true
        isLoading = false
    }
    
    // MARK: - Computed Properties
    
    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email")
                        .fontWeight(.medium)
                    
                    if email.isEmpty {
                        Text("No email set")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(email)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                emailStatusBadge
            }
            
            if !isEmailVerified && !email.isEmpty {
                emailVerificationActions
            }
        }
    }
    
    private var emailStatusBadge: some View {
        Group {
            if isEmailVerified {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .cornerRadius(6)
            } else if !email.isEmpty {
                Label("Unverified", systemImage: "exclamationmark.triangle.fill")
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .cornerRadius(6)
            }
        }
    }
    
    private var emailVerificationActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                sendVerificationEmail()
            } label: {
                if isLoading {
                    HStack {
                        Text("Sending verification email...")
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                } else {
                    Text("Send Verification Email")
                }
            }
            .disabled(isLoading)
            .foregroundStyle(.blue)
            
            Text("A verification email will be sent to \(email). Click the link in the email to verify your address.")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                if isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        if let profile = profile {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(profile.displayName ?? profile.handle.description)
                                    .fontWeight(.bold)
                                    .appFont(AppTextRole.headline)
                                
                                Text("@\(profile.handle.description)")
                                    .appFont(AppTextRole.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    
                    Section("Account Information") {
                        emailSection
                        
                        Button("Update Email") {
                            isShowingEmailSheet = true
                        }
                    }
                    
                    Section("Handle Management") {
                        if let profile = profile {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Current Handle")
                                        .fontWeight(.medium)
                                    
                                    Text("@\(profile.handle.description)")
                                        .appFont(AppTextRole.callout)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "at")
                                    .foregroundStyle(.blue)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Button("Change Handle") {
                            isShowingHandleSheet = true
                        }
                    }
                    
                    // Data backup functionality removed
                    
                    // Migration functionality removed
                    
                    Section("Danger Zone") {
                        Button("Deactivate Account") {
                            isShowingDeactivateAlert = true
                        }
                        .foregroundStyle(.orange)
                        
                        Button("Delete Account") {
                            isShowingDeleteAlert = true
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Account Settings")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .task {
                logger.info("AccountSettingsView appeared, loading data...")
                await loadAccountDetails()
                
                // Add a small delay to ensure model context is ready
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Backup functionality removed
                logger.info("Initial data load complete")
            }
            .alert("Error", isPresented: $showingFormError) {
                Button("OK") { }
            } message: {
                Text(formError ?? "An unknown error occurred")
            }
            .sheet(isPresented: $isShowingEmailSheet) {
                EmailUpdateSheet(
                    currentEmail: email,
                    onEmailUpdated: { newEmail in
                        email = newEmail
                        isEmailVerified = false
                        Task {
                            await loadAccountDetails()
                        }
                    }
                )
            }
            .sheet(isPresented: $isShowingHandleSheet) {
                HandleUpdateSheet(
                    currentHandle: profile?.handle.description ?? "",
                    onHandleUpdated: {
                        Task {
                            await loadAccountDetails()
                        }
                    }
                )
            }
            // Backup settings sheet removed
            // Backup details sheet removed
            .alert("Deactivate Account", isPresented: $isShowingDeactivateAlert) {
                TextField("Type DEACTIVATE to confirm", text: $deactivateConfirmText)
                Button("Cancel", role: .cancel) { }
                Button("Deactivate", role: .destructive) {
                    if deactivateConfirmText == "DEACTIVATE" {
                        deactivateAccount()
                    }
                }
                .disabled(deactivateConfirmText != "DEACTIVATE")
            } message: {
                Text("This will temporarily disable your account. You can reactivate it by logging in again.")
            }
            .alert("Delete Account", isPresented: $isShowingDeleteAlert) {
                TextField("Type DELETE to confirm", text: $deleteConfirmText)
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if deleteConfirmText == "DELETE" {
                        deleteAccount()
                    }
                }
                .disabled(deleteConfirmText != "DELETE")
            } message: {
                Text("This will permanently delete your account and all associated data. This action cannot be undone.")
            }
        }
    }
    
    private func loadAccountDetails() async {
        isLoading = true
        defer { isLoading = false }
        
        guard let client = appState.atProtoClient else {
            handleAPIError(AuthError.clientNotInitialized, operation: "load account details")
            return
        }
        
        do {
            // Get current user profile
            guard let userDID = appState.currentUserDID else {
                handleAPIError(AuthError.invalidCredentials, operation: "get user DID")
                return
            }
            
            let (profileCode, profileData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: ATIdentifier(string: userDID))
            )
            
            if profileCode == 200, let profile = profileData {
                self.profile = profile
            }
            
            // Try to get session info which may include email
            let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
            
            if sessionCode == 200, let session = sessionData {
                self.email = session.email ?? ""
                self.isEmailVerified = session.emailConfirmed ?? false
            }
            
        } catch {
            handleAPIError(error, operation: "load account details")
        }
    }
    
    private func sendVerificationEmail() {
        isLoading = true
        
        Task {
            defer { 
                Task { @MainActor in
                    isLoading = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                Task { @MainActor in
                    handleAPIError(AuthError.clientNotInitialized, operation: "send verification email")
                }
                return
            }
            
            do {
                // Use the AT Protocol email confirmation API to (re)send verification email
                let (responseCode) = try await client.com.atproto.server.requestEmailConfirmation()
                
                if responseCode == 200 {
                    Task { @MainActor in
                        startEmailVerificationPolling()
                    }
                } else {
                    Task { @MainActor in
                        formError = "Failed to send verification email (Code: \(responseCode)). Please try again."
                        showingFormError = true
                    }
                }
                
            } catch {
                Task { @MainActor in
                    handleAPIError(error, operation: "send verification email")
                }
            }
        }
    }
    
    private func startEmailVerificationPolling() {
        verificationPollingTimer?.invalidate()
        
        var pollCount = 0
        let maxPolls = 60
        
        verificationPollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            
            pollCount += 1
            
            let pollCount = pollCount

            Task {
                await self.checkEmailVerificationStatus()
                if await self.isEmailVerified || pollCount >= maxPolls {
                    Task { @MainActor in
                        timer.invalidate()
                        self.verificationPollingTimer = nil
                    }
                }
            }
        }
    }
    
    private func checkEmailVerificationStatus() async {
        guard let client = appState.atProtoClient else { return }
        
        do {
            let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
            
            if sessionCode == 200, let session = sessionData {
                Task { @MainActor in
                    self.isEmailVerified = session.emailConfirmed ?? false
                    
                    if self.isEmailVerified {
                        self.verificationPollingTimer?.invalidate()
                        self.verificationPollingTimer = nil
                    }
                }
            }
        } catch {
            // Silently fail during polling
        }
    }
    
    // Backup functionality removed
    
    private func deactivateAccount() {
        Task {
            guard let client = appState.atProtoClient else {
                handleAPIError(AuthError.clientNotInitialized, operation: "deactivate account")
                return
            }
            
            do {
                let responseCode = try await client.com.atproto.server.deactivateAccount(
                    input: .init(deleteAfter: nil)
                )
                
                if responseCode == 200 {
                    try await appState.handleLogout()
                } else {
                    formError = "Failed to deactivate account. Please try again."
                    showingFormError = true
                }
            } catch {
                handleAPIError(error, operation: "deactivate account")
            }
        }
    }
    
    private func deleteAccount() {
        Task {
            guard let client = appState.atProtoClient else {
                handleAPIError(AuthError.clientNotInitialized, operation: "delete account")
                return
            }
            
            do {
                let responseCode = try await client.com.atproto.server.deleteAccount(
                    input: .init(did: try DID(didString: appState.currentUserDID ?? ""), password: "", token: "")
                )
                
                if responseCode == 200 {
                    try await appState.handleLogout()
                } else {
                    formError = "Failed to delete account. Please contact support."
                    showingFormError = true
                }
            } catch {
                handleAPIError(error, operation: "delete account")
            }
        }
    }
}


// MARK: - Helper Functions

private func colorFromString(_ colorName: String) -> Color {
    switch colorName {
    case "blue":
        return .blue
    case "green":
        return .green
    case "red":
        return .red
    case "orange":
        return .orange
    case "yellow":
        return .yellow
    case "purple":
        return .purple
    default:
        return .primary
    }
}
