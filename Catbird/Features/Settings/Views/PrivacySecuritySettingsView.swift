import SwiftUI
import Petrel
import LocalAuthentication
import OSLog

// MARK: - Protocols

protocol ProfileBasicInfo {
    var id: String { get }
    var did: String { get }
    var handle: String { get }
    var displayName: String? { get }
    var avatar: URL? { get }
}

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    
    // Loading states
    @State private var isLoadingAppPasswords = false
    @State private var isLoadingBlocks = false
    @State private var isLoadingMutes = false
    
    // App passwords
    @State private var appPasswords: [AppPassword] = []
    @State private var isShowingAppPasswordSheet = false
    
    // Block and mute lists
    @State private var blockedProfiles: [String] = []
    @State private var mutedProfiles: [String] = []
    
    // Privacy settings
    @State private var loggedOutVisibility: Bool
    @State private var biometricAuthEnabled: Bool = false
    
    // Biometric error handling
    @State private var showBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var isEnablingBiometric = false
    
    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "PrivacySecuritySettings")
    
    init() {
        _loggedOutVisibility = State(initialValue: AppState.shared.appSettings.loggedOutVisibility)
    }
    
    /// Display name for the current biometric type
    private var biometricDisplayName: String {
        switch appState.authManager.biometricType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        default:
            return "Biometric Authentication"
        }
    }
    
    var body: some View {
        Form {
            // Biometric Authentication Section
            if appState.authManager.biometricType != .none {
                Section("App Security") {
                    Toggle(biometricDisplayName, isOn: $biometricAuthEnabled)
                        .tint(.blue)
                        .onChange(of: biometricAuthEnabled) {
                            Task {
                                await handleBiometricToggle(biometricAuthEnabled)
                            }
                        }
                        .disabled(isEnablingBiometric)
                    
                    if isEnablingBiometric {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Setting up \(biometricDisplayName)...")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Use \(biometricDisplayName.lowercased()) to unlock Catbird and authenticate sensitive actions.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("App Passwords") {
                NavigationLink {
                    AppPasswordsView()
                        .environment(appState)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("App Passwords")
                                .fontWeight(.medium)
                            
                            Text("Create passwords for third-party apps")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if isLoadingAppPasswords {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("\(appPasswords.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Section("Account Privacy") {
                Toggle("Logged-Out Visibility", isOn: $loggedOutVisibility)
                    .tint(.blue)
                    .onChange(of: loggedOutVisibility) {
                        appState.appSettings.loggedOutVisibility = loggedOutVisibility
                    }
                
                Toggle("Attribution Tracking", isOn: Binding(
                    get: { appState.appSettings.enableViaAttribution },
                    set: { appState.appSettings.enableViaAttribution = $0 }
                ))
                .tint(.blue)
                
                Text("When enabled, people who aren't signed into Bluesky can view your profile and posts.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                Text("Attribution tracking credits users when you like or repost content you discovered through their reposts.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Social Graph Management") {
                NavigationLink {
                    BlockedAccountsView()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Blocked Accounts")
                                .fontWeight(.medium)
                            
                            Text("Manage accounts you've blocked")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if isLoadingBlocks {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("\(blockedProfiles.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                NavigationLink {
                    MutedAccountsView()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Muted Accounts")
                                .fontWeight(.medium)
                            
                            Text("Manage accounts you've muted")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if isLoadingMutes {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("\(mutedProfiles.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Section("About App Passwords") {
                Text("App passwords let you securely use third-party apps with your Bluesky account without sharing your main password.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("About Privacy Controls") {
                Text("Blocking prevents an account from interacting with you, including following you or seeing your content in their feeds.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                Text("Muting hides content from an account without them knowing. They can still interact with your posts, but you won't see their content.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy & Security")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await loadData()
            // Initialize biometric state
            await MainActor.run {
                biometricAuthEnabled = appState.authManager.biometricAuthEnabled
            }
        }
        .alert("Biometric Authentication", isPresented: $showBiometricError) {
            Button("OK", role: .cancel) {
                showBiometricError = false
            }
        } message: {
            Text(biometricErrorMessage)
        }
    }
    
    private func loadData() async {
        // Load app passwords
        await loadAppPasswords()
        
        // Load blocks and mutes counts
        await loadBlocksCount()
        await loadMutesCount()
    }
    
    private func handleBiometricToggle(_ enabled: Bool) async {
        await MainActor.run {
            isEnablingBiometric = true
        }
        
        // Call the AuthManager to set biometric auth
        await appState.authManager.setBiometricAuthEnabled(enabled)
        
        // Update local state to match AuthManager state
        await MainActor.run {
            isEnablingBiometric = false
            biometricAuthEnabled = appState.authManager.biometricAuthEnabled
            
            // Check if the operation failed
            if biometricAuthEnabled != enabled && enabled {
                // The toggle didn't work as expected, show an error
                if let error = appState.authManager.lastBiometricError {
                    switch error.code {
                    case .userCancel:
                        // User cancelled, no need to show error
                        break
                    case .biometryNotEnrolled:
                        biometricErrorMessage = "No \(biometricDisplayName) credentials are set up. Please configure \(biometricDisplayName) in Settings and try again."
                        showBiometricError = true
                    case .biometryLockout:
                        biometricErrorMessage = "\(biometricDisplayName) is temporarily locked. Please try again later or use your device passcode."
                        showBiometricError = true
                    case .biometryNotAvailable:
                        biometricErrorMessage = "\(biometricDisplayName) is not available on this device."
                        showBiometricError = true
                    default:
                        biometricErrorMessage = "Failed to enable \(biometricDisplayName). Please try again."
                        showBiometricError = true
                    }
                } else {
                    biometricErrorMessage = "Failed to enable \(biometricDisplayName). Please ensure \(biometricDisplayName) is set up in your device settings and try again."
                    showBiometricError = true
                }
            }
        }
    }
    
    private func loadAppPasswords() async {
        guard appState.isAuthenticated, let client = appState.atProtoClient else { return }
        
        isLoadingAppPasswords = true
        defer { isLoadingAppPasswords = false }
        
        do {
            let (responseCode, response) = try await client.com.atproto.server.listAppPasswords()
            
            if responseCode == 200, let passwords = response?.passwords {
                let mappedPasswords = passwords.map { password in
                    AppPassword(
                        id: password.name,
                        name: password.name,
                        createdAt: password.createdAt.date,
                        lastUsed: nil,
                        isPrivileged: password.privileged ?? false
                    )
                }
                await MainActor.run {
                    self.appPasswords = mappedPasswords
                }
            }
        } catch {
            logger.debug("Error loading app passwords: \(error)")
        }
    }
    
    private func loadBlocksCount() async {
        guard appState.isAuthenticated else { return }
        
        isLoadingBlocks = true
        defer { isLoadingBlocks = false }
        
        do {
            let blocks = try await appState.graphManager.refreshBlockCache()
            await MainActor.run {
                blockedProfiles = Array(blocks)
            }
        } catch {
            logger.debug("Error loading blocked accounts: \(error)")
        }
    }
    
    private func loadMutesCount() async {
        guard appState.isAuthenticated else { return }
        
        isLoadingMutes = true
        defer { isLoadingMutes = false }
        
        do {
            let mutes = try await appState.graphManager.refreshMuteCache()
            await MainActor.run {
                mutedProfiles = Array(mutes)
            }
        } catch {
            logger.debug("Error loading muted accounts: \(error)")
        }
    }
}

// MARK: - App Passwords View

struct AppPasswordsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var appPasswords: [AppPassword] = []
    @State private var isShowingCreateSheet = false
    @State private var isShowingDeleteAlert = false
    @State private var passwordToDelete: AppPassword?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            
            Section {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Label("Create New App Password", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            
            Section("Your App Passwords") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                } else if appPasswords.isEmpty {
                    Text("You haven't created any app passwords yet.")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(appPasswords) { password in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(password.name)
                                    .fontWeight(.medium)
                                
                                Text("Created \(formattedDate(password.createdAt))")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                                
                                if let lastUsed = password.lastUsed {
                                    Text("Last used \(formattedDate(lastUsed))")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                if password.isPrivileged {
                                    Text("Privileged")
                                        .appFont(AppTextRole.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(4)
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                passwordToDelete = password
                                isShowingDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            Section("About App Passwords") {
                Text("App passwords are used with third-party apps that don't support Bluesky's secure sign-in flow. Each app password provides limited access to your account.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                
                Text("Never share your main account password with third-party apps. Use app passwords instead.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle("App Passwords")
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            await loadAppPasswords()
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateAppPasswordView(appState: appState) { name, isPrivileged in
                return await createAppPassword(name: name, isPrivileged: isPrivileged)
            }
        }
        .alert("Delete App Password", isPresented: $isShowingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                passwordToDelete = nil
            }
            
            Button("Delete", role: .destructive) {
                if let password = passwordToDelete {
                    Task {
                        await deleteAppPassword(name: password.name)
                    }
                }
                passwordToDelete = nil
            }
        } message: {
            if let password = passwordToDelete {
                Text("Are you sure you want to delete the app password '\(password.name)'? Any apps using this password will no longer be able to access your account.")
            } else {
                Text("Are you sure you want to delete this app password?")
            }
        }
        .task {
            await loadAppPasswords()
        }
    }
    
    private func loadAppPasswords() async {
        guard let client = appState.atProtoClient else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let (responseCode, response) = try await client.com.atproto.server.listAppPasswords()
            
            if responseCode == 200, let passwords = response?.passwords {
                let mappedPasswords = passwords.map { password in
                    AppPassword(
                        id: password.name,
                        name: password.name,
                        createdAt: password.createdAt.date,
                        lastUsed: nil,
                        isPrivileged: password.privileged ?? false
                    )
                }
                await MainActor.run {
                    self.appPasswords = mappedPasswords
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Failed to load app passwords (Status: \(responseCode))"
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func createAppPassword(name: String, isPrivileged: Bool) async -> String? {
        guard let client = appState.atProtoClient else { return nil }
        
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let input = ComAtprotoServerCreateAppPassword.Input(
                name: name,
                privileged: isPrivileged
            )
            
            let (responseCode, response) = try await client.com.atproto.server.createAppPassword(input: input)
            
            if responseCode == 200, let newPassword = response {
                // Add to the local list
                let appPassword = AppPassword(
                    id: newPassword.name,
                    name: newPassword.name,
                    createdAt: newPassword.createdAt.date,
                    lastUsed: nil,
                    isPrivileged: newPassword.privileged ?? false
                )
                
                await MainActor.run {
                    self.appPasswords.append(appPassword)
                    self.isLoading = false
                }
                return newPassword.password
            } else {
                await MainActor.run {
                    self.errorMessage = "Failed to create app password (Status: \(responseCode))"
                    self.isLoading = false
                }
                return nil
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
            return nil
        }
    }
    
    private func deleteAppPassword(name: String) async {
        guard let client = appState.atProtoClient else { return }
        
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let input = ComAtprotoServerRevokeAppPassword.Input(name: name)
            
            let responseCode = try await client.com.atproto.server.revokeAppPassword(input: input)
            
            if responseCode >= 200 && responseCode < 300 {
                await MainActor.run {
                    self.appPasswords.removeAll { $0.name == name }
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Failed to delete app password (Status: \(responseCode))"
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Create App Password View

struct CreateAppPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var passwordName = ""
    @State private var isPrivileged = false
    @State private var isCreating = false
    @State private var generatedPassword: String?
    @State private var showGeneratedPassword = false
    
    let appState: AppState
    let onCreate: (String, Bool) async -> String?
    
    init(appState: AppState, onCreate: @escaping (String, Bool) async -> String?) {
        self.appState = appState
        self.onCreate = onCreate
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("App Password Details") {
                    TextField("Name (e.g., Third-party App)", text: $passwordName)
                        .autocorrectionDisabled()
                    
                    Toggle("Privileged Access", isOn: $isPrivileged)
                        .tint(.blue)
                }
                
                Section("About Privileged Access") {
                    Text("Privileged app passwords have additional permissions for advanced features. Only enable this for apps you fully trust.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let generatedPassword = generatedPassword {
                    Section("Your New App Password") {
                        HStack {
                            Text(generatedPassword)
                                .appFont(AppTextRole.footnote)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            Button {
                                UIPasteboard.general.string = generatedPassword
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        
                        Text("Copy this password now - you won't be able to see it again. Store it safely in your password manager.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.red)
                            .fontWeight(.medium)
                    }
                }
            }
            .navigationTitle("Create App Password")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createPassword()
                        }
                    }
                    .disabled(passwordName.isEmpty || isCreating)
                }
            }
        }
        .alert("App Password Created", isPresented: $showGeneratedPassword) {
            Button("Done") {
                dismiss()
            }
        } message: {
            Text("Your app password has been created successfully. Make sure to copy it from above - you won't be able to see it again.")
        }
    }
    
    private func createPassword() async {
        isCreating = true
        
        if let password = await onCreate(passwordName, isPrivileged) {
            await MainActor.run {
                generatedPassword = password
                showGeneratedPassword = true
                isCreating = false
            }
        } else {
            await MainActor.run {
                isCreating = false
            }
        }
    }
}

// MARK: - Blocked Accounts View

struct BlockedAccountsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var blockedProfiles: [any ProfileBasicInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingUnblockAlert = false
    @State private var profileToUnblock: (any ProfileBasicInfo)?
    
    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                } else if blockedProfiles.isEmpty {
                    Text("You haven't blocked any accounts.")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(blockedProfiles, id: \.id) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName ?? profile.handle)
                                    .fontWeight(.medium)
                                
                                if profile.displayName != nil {
                                    Text("@\(profile.handle)")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                profileToUnblock = profile
                                showingUnblockAlert = true
                            } label: {
                                Text("Unblock")
                                    .appFont(AppTextRole.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.2))
                                    .foregroundStyle(.primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            Section("About Blocking") {
                Text("Blocking prevents an account from interacting with you. Blocked accounts cannot follow you, see your content in their feeds, or mention you in posts.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                
                Text("Blocks are not visible to the blocked account - they won't be notified that you've blocked them.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle("Blocked Accounts")
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            await loadBlockedAccounts()
        }
        .alert("Unblock Account", isPresented: $showingUnblockAlert) {
            Button("Cancel", role: .cancel) {
                profileToUnblock = nil
            }
            
            Button("Unblock", role: .destructive) {
                if let profile = profileToUnblock {
                    Task {
                        await unblockAccount(did: profile.did)
                    }
                }
                profileToUnblock = nil
            }
        } message: {
            if let profile = profileToUnblock {
                Text("Are you sure you want to unblock @\(profile.handle)? They will be able to interact with you and see your content again.")
            } else {
                Text("Are you sure you want to unblock this account?")
            }
        }
        .task {
            await loadBlockedAccounts()
        }
    }
    
    private func loadBlockedAccounts() async {
        guard let client = appState.atProtoClient else { return }
        
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            var collectedProfiles: [any ProfileBasicInfo] = []
            var cursor: String?
            
            repeat {
                let params = AppBskyGraphGetBlocks.Parameters(limit: 50, cursor: cursor)
                let (responseCode, response) = try await client.app.bsky.graph.getBlocks(input: params)
                
                if responseCode == 200, let blocks = response?.blocks {
                    let profiles = blocks.map { profile in
                        BasicProfileInfo(
                            id: profile.did.didString(),
                            did: profile.did.didString(),
                            handle: profile.handle.description,
                            displayName: profile.displayName,
                            avatar: profile.avatar?.url
                        )
                    }
                    collectedProfiles.append(contentsOf: profiles)
                    cursor = response?.cursor
                } else {
                    throw NSError(domain: "AppError", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Failed to load blocked accounts"])
                }
            } while cursor != nil
            
            await MainActor.run {
                self.blockedProfiles = collectedProfiles
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func unblockAccount(did: String) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let success = try await appState.unblock(did: did)
            
            if success {
                // Remove from our local list
                await MainActor.run {
                    self.blockedProfiles.removeAll { $0.did == did }
                    self.isLoading = false
                }
            } else {
                throw NSError(domain: "AppError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to unblock account"])
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// MARK: - Muted Accounts View

struct MutedAccountsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var mutedProfiles: [any ProfileBasicInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingUnmuteAlert = false
    @State private var profileToUnmute: (any ProfileBasicInfo)?
    
    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                } else if mutedProfiles.isEmpty {
                    Text("You haven't muted any accounts.")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(mutedProfiles, id: \.id) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName ?? profile.handle)
                                    .fontWeight(.medium)
                                
                                if profile.displayName != nil {
                                    Text("@\(profile.handle)")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                profileToUnmute = profile
                                showingUnmuteAlert = true
                            } label: {
                                Text("Unmute")
                                    .appFont(AppTextRole.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.2))
                                    .foregroundStyle(.primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            Section("About Muting") {
                Text("Muting hides an account's content from you without them knowing. Muted accounts can still interact with your content, but you won't see their posts, replies, or mentions.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                
                Text("Mutes are private - muted accounts won't know that you've muted them.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle("Muted Accounts")
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            await loadMutedAccounts()
        }
        .alert("Unmute Account", isPresented: $showingUnmuteAlert) {
            Button("Cancel", role: .cancel) {
                profileToUnmute = nil
            }
            
            Button("Unmute", role: .destructive) {
                if let profile = profileToUnmute {
                    Task {
                        await unmuteAccount(did: profile.did)
                    }
                }
                profileToUnmute = nil
            }
        } message: {
            if let profile = profileToUnmute {
                Text("Are you sure you want to unmute @\(profile.handle)? Their content will appear in your feeds again.")
            } else {
                Text("Are you sure you want to unmute this account?")
            }
        }
        .task {
            await loadMutedAccounts()
        }
    }
    
    private func loadMutedAccounts() async {
        guard let client = appState.atProtoClient else { return }
        
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            var collectedProfiles: [any ProfileBasicInfo] = []
            var cursor: String?
            
            repeat {
                let params = AppBskyGraphGetMutes.Parameters(limit: 50, cursor: cursor)
                let (responseCode, response) = try await client.app.bsky.graph.getMutes(input: params)
                
                if responseCode == 200, let mutes = response?.mutes {
                    let profiles = mutes.map { profile in
                        BasicProfileInfo(
                            id: profile.did.didString(),
                            did: profile.did.didString(),
                            handle: profile.handle.description,
                            displayName: profile.displayName,
                            avatar: profile.avatar?.url
                        )
                    }
                    collectedProfiles.append(contentsOf: profiles)
                    cursor = response?.cursor
                } else {
                    throw NSError(domain: "AppError", code: responseCode, userInfo: [NSLocalizedDescriptionKey: "Failed to load muted accounts"])
                }
            } while cursor != nil
            
            await MainActor.run {
                self.mutedProfiles = collectedProfiles
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func unmuteAccount(did: String) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let success = try await appState.unmute(did: did)
            
            if success {
                // Remove from our local list
                await MainActor.run {
                    self.mutedProfiles.removeAll { $0.did == did }
                    self.isLoading = false
                }
            } else {
                throw NSError(domain: "AppError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to unmute account"])
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// MARK: - Supporting Models

// Concrete implementation of ProfileBasicInfo protocol
struct BasicProfileInfo: ProfileBasicInfo {
    let id: String
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?
}

struct AppPassword: Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    let lastUsed: Date?
    let isPrivileged: Bool
}

#Preview {
    NavigationStack {
        PrivacySecuritySettingsView()
            .environment(AppState.shared)
    }
}
