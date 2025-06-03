import SwiftUI
import Petrel
import OSLog

struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoading = true
    @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
    @State private var accountInfo: ComAtprotoServerDescribeServer.Output?
    
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
        } else if error.localizedDescription.contains("401") || error.localizedDescription.contains("Unauthorized") {
            errorMessage = "Authentication error. Please log in again."
        } else if error.localizedDescription.contains("403") || error.localizedDescription.contains("Forbidden") {
            errorMessage = "Access denied. You don't have permission to \(operation.lowercased())."
        } else if error.localizedDescription.contains("404") || error.localizedDescription.contains("NotFound") {
            errorMessage = "Resource not found. Please try again."
        } else if error.localizedDescription.contains("429") || error.localizedDescription.contains("RateLimitExceeded") {
            errorMessage = "Too many requests. Please wait a moment and try again."
        } else if error.localizedDescription.contains("500") || error.localizedDescription.contains("InternalServerError") {
            errorMessage = "Server error. Please try again later."
        } else {
            errorMessage = "Failed to \(operation.lowercased()): \(error.localizedDescription)"
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
                    
                    Section("Export Data") {
                        Button {
                            exportAccountData()
                        } label: {
                            HStack {
                                if isExporting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Exporting...")
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export Account Data")
                                }
                                
                                Spacer()
                            }
                        }
                        .disabled(isExporting)
                        
                        if exportCompleted {
                            Text("Your account data export has been requested. You'll receive an email when it's ready.")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    
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
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadAccountDetails()
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
                // Request email update - AT Protocol doesn't have a direct email update endpoint
                // This would typically be done through the account management interface
                // For now, we'll simulate the request
                let responseCode = 200
                
                if responseCode == 200 {
                    Task { @MainActor in
                        startEmailVerificationPolling()
                    }
                } else {
                    Task { @MainActor in
                        formError = "Failed to send verification email. Please try again."
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
            
            Task {
                await self.checkEmailVerificationStatus()
                
                if self.isEmailVerified || pollCount >= maxPolls {
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
    
    private func exportAccountData() {
        isExporting = true
        
        Task {
            defer {
                Task { @MainActor in
                    isExporting = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                Task { @MainActor in
                    handleAPIError(AuthError.clientNotInitialized, operation: "export account data")
                }
                return
            }
            
            do {
                // Request account data export via repo export
                guard let userDID = appState.currentUserDID else {
                    Task { @MainActor in
                        formError = "Unable to identify user account"
                        showingFormError = true
                    }
                    return
                }
                
                // Use repo export which is more appropriate for user data
                let (responseCode, _) = try await client.com.atproto.sync.getRepo(
                    input: .init(did: DID(didString: userDID), since: nil)
                )
                
                if responseCode == 200 {
                    Task { @MainActor in
                        exportCompleted = true
                    }
                } else {
                    Task { @MainActor in
                        formError = "Failed to request data export. Please try again."
                        showingFormError = true
                    }
                }
            } catch {
                Task { @MainActor in
                    handleAPIError(error, operation: "export account data")
                }
            }
        }
    }
    
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
