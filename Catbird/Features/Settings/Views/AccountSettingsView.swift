import SwiftUI
import Petrel

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
                // Profile information section
                Section {
                    if let profile = profile {
                        ProfileHeaderRow(profile: profile)
                    }
                }
                
                // Account management section
                Section("Account Information") {
                    // Email management
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
                        
                        if isEmailVerified {
                            Text("Verified")
                                .appFont(AppTextRole.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .cornerRadius(4)
                        } else if !email.isEmpty {
                            Text("Unverified")
                                .appFont(AppTextRole.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .cornerRadius(4)
                        }
                    }
                    
                    if !isEmailVerified && !email.isEmpty {
                        Button("Verify Email") {
                            sendVerificationEmail()
                        }
                        .foregroundStyle(.blue)
                    }
                    
                    Button("Update Email") {
                        isShowingEmailSheet = true
                    }
                    
                    Divider()
                    
                    // Handle management
                    if let handle = profile?.handle.description {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Handle")
                                    .fontWeight(.medium)
                                
                                Text("@\(handle)")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Edit") {
                                isShowingHandleSheet = true
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .controlSize(.small)
                        }
                    }
                    
                    Divider()
                    
                    // Password management
                    NavigationLink("Update Password") {
                        PasswordUpdateView(appState: appState)
                    }
                    
                    // App passwords
                    NavigationLink("App Passwords") {
                        AppPasswordsView(appState: appState)
                    }
                }
                
                // Data export section
                Section("Data & Privacy") {
                    Button {
                        exportAccountData()
                    } label: {
                        if isExporting {
                            HStack {
                                Text("Requesting export...")
                                Spacer()
                                ProgressView()
                            }
                        } else if exportCompleted {
                            HStack {
                                Text("Export Account Data")
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        } else {
                            Text("Export Account Data")
                        }
                    }
                    .disabled(isExporting)
                }
                
                // Account deactivation/deletion
                Section {
                    Button(role: .destructive) {
                        isShowingDeactivateAlert = true
                    } label: {
                        Text("Deactivate Account")
                    }
                    
//                    Button(role: .destructive) {
//                        isShowingDeleteAlert = true
//                    } label: {
//                        Text("Delete Account")
//                    }
                }
                
                // Server information
                if let serverInfo = accountInfo {
                    Section("Server Information") {
//                        if let invitesAvailable = serverInfo.invitesAvailable {
//                            HStack {
//                                Text("Invites Available")
//                                Spacer()
//                                Text("\(invitesAvailable)")
//                                    .foregroundStyle(.secondary)
//                            }
//                        }
                        
                         let serverDID = serverInfo.did
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server DID")
                                    .fontWeight(.medium)
                                Text(serverDID.didString())
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                        
                         let availableUserDomains = serverInfo.availableUserDomains
                        VStack(alignment: .leading, spacing: 4) {
                                Text("Available Domains")
                                    .fontWeight(.medium)
                                Text(availableUserDomains.joined(separator: ", "))
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
            }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await loadAccountDetails()
        }
        .sheet(isPresented: $isShowingEmailSheet) {
            EmailUpdateView(email: email) { newEmail in
                updateEmail(newEmail)
                isShowingEmailSheet = false
            }
        }
        .sheet(isPresented: $isShowingHandleSheet) {
            if let handle = profile?.handle.description {
                HandleUpdateView(
                    currentHandle: handle,
                    checkingAvailability: $checkingAvailability,
                    appState: appState
                ) { newHandle in
                    updateHandle(newHandle)
                    isShowingHandleSheet = false
                }
            }
        }
        .alert("Deactivate Account", isPresented: $isShowingDeactivateAlert) {
            TextField("Type 'deactivate' to confirm", text: $deactivateConfirmText)
            
            Button("Cancel", role: .cancel) {
                deactivateConfirmText = ""
            }
            
            Button("Deactivate", role: .destructive) {
                if deactivateConfirmText.lowercased() == "deactivate" {
                    deactivateAccount()
                }
                deactivateConfirmText = ""
            }
            .disabled(deactivateConfirmText.lowercased() != "deactivate")
            
        } message: {
            Text("Your account will be temporarily deactivated. Your content won't be visible, but you can reactivate later. Type 'deactivate' to confirm.")
        }
//        .alert("Delete Account", isPresented: $isShowingDeleteAlert) {
//            TextField("Type 'delete' to confirm", text: $deleteConfirmText)
//            
//            Button("Cancel", role: .cancel) {
//                deleteConfirmText = ""
//            }
//            
//            Button("Delete", role: .destructive) {
//                if deleteConfirmText.lowercased() == "delete" {
//                    deleteAccount()
//                }
//                deleteConfirmText = ""
//            }
//            .disabled(deleteConfirmText.lowercased() != "delete")
//            
//        } message: {
//            Text("Your account will be permanently deleted. This action cannot be undone. Type 'delete' to confirm.")
//        }
        .alert("Error", isPresented: $showingFormError) {
            Button("OK") {
                formError = nil
            }
        } message: {
            if let error = formError {
                Text(error)
            }
        }
        .refreshable {
            await loadAccountDetails()
        }
    }
    
    private func loadAccountDetails() async {
        isLoading = true
        defer { isLoading = false }
        
        guard let client = appState.atProtoClient else { return }
        
        do {
            // Get current user DID
            guard let did = appState.currentUserDID else { return }
            
            // Fetch profile
            let (_, profileData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: ATIdentifier(string: did))
            )
            
            profile = profileData
            
            // Fetch account info from server
            let (serverCode, serverData) = try await client.com.atproto.server.describeServer()
            
            if serverCode == 200, let serverData = serverData {
                accountInfo = serverData
            }
            
            // Fetch session info to get email and verification status
            let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
            
            if sessionCode == 200, let sessionData = sessionData {
                if let userEmail = sessionData.email, let confirmedEmail = sessionData.emailConfirmed {
                    email = userEmail
                    isEmailVerified = confirmedEmail
                }
            }
            
        } catch {
            logger.debug("Error loading account details: \(error)")
            formError = "Failed to load account details: \(error.localizedDescription)"
            showingFormError = true
        }
    }
    
    private func sendVerificationEmail() {
        // Show progress indicator
        guard let client = appState.atProtoClient else { return }
        
        Task {
            do {
                let code = try await client.com.atproto.server.requestEmailConfirmation()
                
                if code == 200 {
                    // Show success notification
                    formError = "Verification email sent successfully!"
                    showingFormError = true
                } else {
                    formError = "Failed to send verification email. Please try again."
                    showingFormError = true
                }
            } catch {
                formError = "Error sending verification email: \(error.localizedDescription)"
                showingFormError = true
            }
        }
    }
    
    private func updateEmail(_ newEmail: String) {
        guard let client = appState.atProtoClient else { return }
        
        Task {
            do {
                let (code, _) = try await client.com.atproto.server.requestEmailUpdate()
                
                if code == 200 {
                    // Update local state and show success message
                    email = newEmail
                    isEmailVerified = false
                    formError = "Email update requested. Please check your email for confirmation."
                    showingFormError = true
                } else {
                    formError = "Failed to update email. Please try again."
                    showingFormError = true
                }
            } catch {
                formError = "Error updating email: \(error.localizedDescription)"
                showingFormError = true
            }
        }
    }
    
    private func updateHandle(_ newHandle: String) {
        guard let client = appState.atProtoClient else { return }
        
        Task {
            do {
                let code = try await client.com.atproto.identity.updateHandle(
                    input: .init(handle: try Handle(handleString: newHandle))
                )
                
                if code == 200 {
                    // Refresh profile to get the new handle
                    await loadAccountDetails()
                    formError = "Handle updated successfully!"
                    showingFormError = true
                } else {
                    formError = "Failed to update handle. Please try again."
                    showingFormError = true
                }
            } catch {
                formError = "Error updating handle: \(error.localizedDescription)"
                showingFormError = true
            }
        }
    }
    
    private func exportAccountData() {
        guard let client = appState.atProtoClient else { return }
        
        isExporting = true
        
        Task {
            do {
                let (code, _) = try await client.chat.bsky.actor.exportAccountData()
                
                if code == 200 {
                    exportCompleted = true
                    formError = "Export request successful. You'll receive an email with your data shortly."
                    showingFormError = true
                } else {
                    formError = "Failed to export account data. Please try again."
                    showingFormError = true
                }
            } catch {
                formError = "Error exporting account data: \(error.localizedDescription)"
                showingFormError = true
            }
            
            isExporting = false
        }
    }
    
    private func deactivateAccount() {
        guard let client = appState.atProtoClient else { return }
        
        Task {
            do {
                let code = try await client.com.atproto.server.deactivateAccount(
                    input: .init()
                )
                
                if code == 200 {
                    // Log out and return to the login screen
                    try await appState.handleLogout()
                } else {
                    formError = "Failed to deactivate account. Please try again."
                    showingFormError = true
                }
            } catch {
                formError = "Error deactivating account: \(error.localizedDescription)"
                showingFormError = true
            }
        }
    }
    
//    private func deleteAccount() {
//        guard let client = appState.atProtoClient else { return }
//        
//        Task {
//            do {
//                let code = try await client.com.atproto.server.deleteAccount(input: .init(did: <#T##DID#>, password: <#T##String#>, token: <#T##String#>))
//                
//                if code == 200 {
//                    // Log out and return to the login screen
//                    try await appState.handleLogout()
//                } else {
//                    formError = "Failed to delete account. Please try again."
//                    showingFormError = true
//                }
//            } catch {
//                formError = "Error deleting account: \(error.localizedDescription)"
//                showingFormError = true
//            }
//        }
//    }
}

// MARK: - Supporting Views

struct ProfileHeaderRow: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            if let avatarURL = profile.avatar?.url {
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(profile.handle.description.prefix(1).uppercased())
                            .appFont(AppTextRole.title2.weight(.medium))
                            .foregroundStyle(.gray)
                    )
            }
            
            // Profile info
            VStack(alignment: .leading, spacing: 4) {
                if let displayName = profile.displayName {
                    Text(displayName)
                        .appFont(AppTextRole.headline)
                }
                
                Text("@\(profile.handle.description)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(.secondary)
                
                if let followersCount = profile.followersCount {
                    Text("\(followersCount) followers")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct EmailUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newEmail: String
    @State private var errorMessage: String?
    
    let onSave: (String) -> Void
    
    init(email: String, onSave: @escaping (String) -> Void) {
        self._newEmail = State(initialValue: email)
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Update Email") {
                    TextField("Email", text: $newEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Text("We'll send a verification email to confirm this address.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    if let error = errorMessage {
                        Text(error)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                Section {
                    Button("Save") {
                        if isValidEmail(newEmail) {
                            onSave(newEmail)
                        } else {
                            errorMessage = "Please enter a valid email address."
                        }
                    }
                    .disabled(newEmail.isEmpty || !isValidEmail(newEmail))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Update Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}

struct HandleUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newHandle: String
    @State private var isHandleAvailable = false
    @State private var hasCheckedAvailability = false
    @State private var errorMessage: String?
    
    @Binding var checkingAvailability: Bool
    let appState: AppState
    let onSave: (String) -> Void
    
    init(currentHandle: String, checkingAvailability: Binding<Bool>, appState: AppState, onSave: @escaping (String) -> Void) {
        self._newHandle = State(initialValue: currentHandle)
        self._checkingAvailability = checkingAvailability
        self.appState = appState
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Update Handle") {
                    HStack {
                        Text("@")
                            .foregroundStyle(.secondary)
                        
                        TextField("handle", text: $newHandle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: newHandle) {
                                hasCheckedAvailability = false
                                isHandleAvailable = false
                            }
                    }
                    
                    if hasCheckedAvailability {
                        if isHandleAvailable {
                            Label("Handle available", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Handle not available", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.red)
                    }
                    
                    Button {
                        checkHandleAvailability()
                    } label: {
                        if checkingAvailability {
                            HStack {
                                Text("Checking availability...")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Text("Check Availability")
                        }
                    }
                    .disabled(checkingAvailability || newHandle.isEmpty)
                }
                
                Section {
                    Button("Save") {
                        if isHandleAvailable {
                            onSave(newHandle)
                        } else {
                            errorMessage = "Please check handle availability first."
                        }
                    }
                    .disabled(!isHandleAvailable || checkingAvailability)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                
                Section("About Handles") {
                    Text("Your handle is your unique identifier on Bluesky. It can contain letters, numbers, and underscores.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("You can also use a custom domain as your handle if you verify domain ownership.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .navigationTitle("Update Handle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func checkHandleAvailability() {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        checkingAvailability = true
        
        Task {
            do {
                // Check handle availability via resolveHandle
                let input = ComAtprotoIdentityResolveHandle.Parameters(handle: try Handle(handleString: newHandle))
                
                _ = try await client.com.atproto.identity.resolveHandle(input: input)
                
                // If we get here, the handle is already taken (no error was thrown)
                isHandleAvailable = false
                errorMessage = "This handle is already in use."
                
            } catch {
                // If we get a specific "not found" error, the handle is available
                if error.localizedDescription == "NotFound" {
                    isHandleAvailable = true
                    errorMessage = nil
                } else {
                    // Any other error means we couldn't check availability
                    isHandleAvailable = false
                    errorMessage = "Could not check availability: \(error.localizedDescription)"
                }
            }
            
            hasCheckedAvailability = true
            checkingAvailability = false
        }
    }
}

struct PasswordUpdateView: View {
    let appState: AppState
    
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("Current Password") {
                SecureField("Current Password", text: $currentPassword)
                    .textContentType(.password)
            }
            
            Section("New Password") {
                SecureField("New Password", text: $newPassword)
                    .textContentType(.newPassword)
                
                SecureField("Confirm New Password", text: $confirmPassword)
                    .textContentType(.newPassword)
                
                if !newPassword.isEmpty {
                    PasswordStrengthIndicator(password: newPassword)
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.callout)
                }
            }
            
            if let success = successMessage {
                Section {
                    Text(success)
                        .foregroundStyle(.green)
                        .appFont(AppTextRole.callout)
                }
            }
            
            Section {
                Button {
                    updatePassword()
                } label: {
                    if isUpdating {
                        HStack {
                            Text("Updating...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Update Password")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isUpdating || !isValidForm)
            }
        }
        .navigationTitle("Update Password")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var isValidForm: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        !confirmPassword.isEmpty &&
        newPassword == confirmPassword &&
        newPassword.count >= 8
    }
    
    private func updatePassword() {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        isUpdating = true
        errorMessage = nil
        successMessage = nil
        
        Task {
            do {
                let input = ComAtprotoServerResetPassword.Input(
                    token: currentPassword, password: newPassword
                )
                
                let code = try await client.com.atproto.server.resetPassword(input: input)
                
                if code == 200 {
                    successMessage = "Password updated successfully!"
                    
                    // Clear the password fields
                    currentPassword = ""
                    newPassword = ""
                    confirmPassword = ""
                    
                    // Dismiss after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        dismiss()
                    }
                } else {
                    errorMessage = "Failed to update password. Server returned code \(code)."
                }
            } catch {
                errorMessage = "Error updating password: \(error.localizedDescription)"
            }
            
            isUpdating = false
        }
    }
}

struct PasswordStrengthIndicator: View {
    let password: String
    
    var strength: Double {
        var score = 0.0
        
        // Length check
        if password.count >= 12 {
            score += 0.25
        } else if password.count >= 8 {
            score += 0.15
        }
        
        // Complexity checks
        if password.contains(where: { $0.isLowercase }) {
            score += 0.15
        }
        
        if password.contains(where: { $0.isUppercase }) {
            score += 0.15
        }
        
        if password.contains(where: { $0.isNumber }) {
            score += 0.15
        }
        
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) {
            score += 0.15
        }
        
        // Variety check (avoid repeated characters)
        let uniqueChars = Set(password)
        let variety = Double(uniqueChars.count) / Double(password.count)
        score += variety * 0.15
        
        return min(1.0, score)
    }
    
    var strengthColor: Color {
        if strength < 0.3 {
            return .red
        } else if strength < 0.6 {
            return .orange
        } else if strength < 0.8 {
            return .yellow
        } else {
            return .green
        }
    }
    
    var strengthLabel: String {
        if strength < 0.3 {
            return "Weak"
        } else if strength < 0.6 {
            return "Moderate"
        } else if strength < 0.8 {
            return "Strong"
        } else {
            return "Very Strong"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password Strength: \(strengthLabel)")
                .appFont(AppTextRole.caption)
                .foregroundStyle(strengthColor)
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .frame(width: geometry.size.width, height: 6)
                        .opacity(0.2)
                        .foregroundColor(Color(.systemGray4))
                    
                    Rectangle()
                        .frame(width: geometry.size.width * strength, height: 6)
                        .foregroundColor(strengthColor)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
            
            Text("Use at least 8 characters with a mix of letters, numbers, and symbols.")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AppPasswordsView: View {
    let appState: AppState
    
    @State private var appPasswords: [ComAtprotoServerListAppPasswords.AppPassword] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isShowingCreateSheet = false
    @State private var selectedPasswordId: String?
    @State private var isShowingDeleteConfirmation = false
    
    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if errorMessage != nil {
                Text(errorMessage ?? "Unknown error")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if appPasswords.isEmpty {
                Text("No app passwords found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(appPasswords, id: \.name) { password in
                    AppPasswordRow(password: password) {
                        selectedPasswordId = password.name
                        isShowingDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("App Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateAppPasswordView(appState: appState) { _ in
                isShowingCreateSheet = false
                Task { @MainActor in
                    
                   await fetchAppPasswords()
                }
            }
        }
        .alert("Delete App Password?", isPresented: $isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let id = selectedPasswordId {
                    deleteAppPassword(id)
                }
            }
        } message: {
            Text("This will revoke access for apps using this password. This action cannot be undone.")
        }
        .task {
            await fetchAppPasswords()
        }
        .refreshable {
            await fetchAppPasswords()
        }
    }
    
    private func fetchAppPasswords() async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            isLoading = false
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let (code, data) = try await client.com.atproto.server.listAppPasswords()
            
            if code == 200, let data = data {
                appPasswords = data.passwords
            } else {
                errorMessage = "Failed to fetch app passwords. Server returned code \(code)."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func deleteAppPassword(_ name: String) {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        Task {
            do {
                let input = ComAtprotoServerRevokeAppPassword.Input(name: name)
                let code = try await client.com.atproto.server.revokeAppPassword(input: input)
                
                if code == 200 {
                    // Remove the password from the list
                    appPasswords.removeAll { $0.name == name }
                } else {
                    errorMessage = "Failed to delete app password. Server returned code \(code)."
                }
            } catch {
                errorMessage = "Error deleting app password: \(error.localizedDescription)"
            }
        }
    }
}

struct AppPasswordRow: View {
    let password: ComAtprotoServerListAppPasswords.AppPassword
    let onDelete: () -> Void
    
    private var createdDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
         let date = password.createdAt.date
            return formatter.string(from: date)
        
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(password.name)
                    .fontWeight(.medium)
                
                Text("Created: \(createdDate)")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct CreateAppPasswordView: View {
    let appState: AppState
    let onComplete: (String?) -> Void
    
    @State private var passwordName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var newPassword: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Create App Password") {
                    TextField("Name (e.g., 'Mobile App')", text: $passwordName)
                    
                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.callout)
                    }
                }
                
                if let password = newPassword {
                    Section("Your New Password") {
                        Text(password)
                            .appFont(AppTextRole.title3.monospaced())
                            .padding()
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        
                        Text("Save this password now. You won't be able to see it again!")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section {
                    if newPassword == nil {
                        Button {
                            createAppPassword()
                        } label: {
                            if isCreating {
                                HStack {
                                    Text("Creating...")
                                    Spacer()
                                    ProgressView()
                                }
                            } else {
                                Text("Create App Password")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .disabled(isCreating || passwordName.isEmpty)
                    } else {
                        Button("Done") {
                            onComplete(newPassword)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("App Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func createAppPassword() {
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available"
            return
        }
        
        isCreating = true
        errorMessage = nil
        
        Task {
            do {
                let input = ComAtprotoServerCreateAppPassword.Input(name: passwordName)
                let (code, data) = try await client.com.atproto.server.createAppPassword(input: input)
                
                if code == 200, let data = data {
                    newPassword = data.password
                } else {
                    errorMessage = "Failed to create app password. Server returned code \(code)."
                }
            } catch {
                errorMessage = "Error creating app password: \(error.localizedDescription)"
            }
            
            isCreating = false
        }
    }
}

#Preview {
    NavigationStack {
        AccountSettingsView()
            .environment(AppState())
    }
}
