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
    
    // Backup management
    @State private var backupRecords: [BackupRecord] = []
    @State private var backupConfiguration: BackupConfiguration?
    @State private var isShowingBackupSettings = false
    @State private var selectedBackupRecord: BackupRecord?
    @State private var isShowingBackupDetails = false
    
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
                    
                    Section("Data Backup") {
                        // Manual backup button
                        Button {
                            createManualBackup()
                        } label: {
                            HStack {
                                if appState.backupManager.isBackingUp {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Creating Backup...")
                                        if !appState.backupManager.backupStatusMessage.isEmpty {
                                            Text(appState.backupManager.backupStatusMessage)
                                                .appFont(AppTextRole.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Create Local Backup")
                                }
                                
                                Spacer()
                            }
                        }
                        .disabled(appState.backupManager.isBackingUp)
                        
                        // Backup progress indicator
                        if appState.backupManager.isBackingUp && appState.backupManager.backupProgress > 0 {
                            ProgressView(value: appState.backupManager.backupProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        
                        // Backup settings
                        Button {
                            isShowingBackupSettings = true
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text("Backup Settings")
                                Spacer()
                                
                                if let config = backupConfiguration {
                                    Text(config.autoBackupEnabled ? "Auto: On" : "Auto: Off")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Image(systemName: "chevron.right")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        
                        // Backup history section
                        if !backupRecords.isEmpty {
                            ForEach(backupRecords.prefix(3), id: \.id) { record in
                                Button {
                                    selectedBackupRecord = record
                                    isShowingBackupDetails = true
                                } label: {
                                    BackupRecordRowView(record: record)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            
                            if backupRecords.count > 3 {
                                Button("View All Backups (\(backupRecords.count))") {
                                    // Could show a full backup list view
                                }
                                .foregroundStyle(.blue)
                            }
                        } else {
                            Text("No backups created yet. Create your first backup to get started.")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        
                        // 🧪 EXPERIMENTAL: Repository Browser
                        NavigationLink {
                            // Navigate to Repository Browser within the settings sheet
                            RepositoryBrowserView()
                        } label: {
                            HStack {
                                Image(systemName: "archivebox.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("🧪 Repository Browser")
                                        .fontWeight(.medium)
                                    Text("EXPERIMENTAL: Browse parsed backup data")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Section("🚨 EXPERIMENTAL: Account Migration") {
                        // 🚨 EXPERIMENTAL: Account Migration
                        Button {
                            // Navigate to Migration Wizard
                            appState.navigationManager.navigate(to: .migrationWizard)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("🚨 Migrate Account")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.red)
                                    Text("EXPERIMENTAL: Move your account to another AT Protocol server")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("⚠️ CRITICAL WARNING")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.red)
                            
                            Text("• Account migration is experimental and EXTREMELY RISKY\n• May result in complete data loss or account corruption\n• No guarantees or support provided - use at your own risk\n• Always create backups before attempting migration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
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
                logger.info("AccountSettingsView appeared, loading data...")
                await loadAccountDetails()
                
                // Add a small delay to ensure model context is ready
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                await loadBackupData()
                logger.info("Initial data load complete, backup count: \(backupRecords.count)")
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
            .sheet(isPresented: $isShowingBackupSettings) {
                if let config = backupConfiguration {
                    BackupSettingsSheet(
                        configuration: config,
                        onConfigurationUpdated: { updatedConfig in
                            Task {
                                do {
                                    try await appState.backupManager.updateBackupConfiguration(updatedConfig)
                                    await MainActor.run {
                                        backupConfiguration = updatedConfig
                                    }
                                } catch {
                                    await MainActor.run {
                                        handleAPIError(error, operation: "update backup settings")
                                    }
                                }
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingBackupDetails) {
                if let record = selectedBackupRecord {
                    BackupDetailsSheet(
                        record: record,
                        onVerifyBackup: { record in
                            Task {
                                do {
                                    try await appState.backupManager.verifyBackupIntegrity(record)
                                    await loadBackupData() // Refresh the list
                                } catch {
                                    handleAPIError(error, operation: "verify backup")
                                }
                            }
                        },
                        onDeleteBackup: { record in
                            Task {
                                do {
                                    try appState.backupManager.deleteBackup(record)
                                    await loadBackupData() // Refresh the list
                                } catch {
                                    handleAPIError(error, operation: "delete backup")
                                }
                            }
                        }
                    )
                }
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
                // Use the AT Protocol email confirmation API
                let (responseCode, response) = try await client.com.atproto.server.requestEmailUpdate()
                
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
    
    // MARK: - Backup Methods
    
    private func createManualBackup() {
        guard let userDID = appState.currentUserDID,
              let client = appState.atProtoClient,
              let userHandle = profile?.handle.description else {
            handleAPIError(AuthError.clientNotInitialized, operation: "create backup")
            return
        }
        
        Task {
            do {
                logger.info("Creating manual backup for user: \(userHandle)")
                let backupRecord = try await appState.backupManager.createManualBackup(
                    for: userDID,
                    userHandle: userHandle,
                    client: client
                )
                logger.info("Backup created successfully: \(backupRecord.id)")
                
                await loadBackupData() // Refresh backup list
                logger.info("Backup list refreshed, count: \(self.backupRecords.count)")
                
            } catch {
                await MainActor.run {
                    handleAPIError(error, operation: "create backup")
                }
            }
        }
    }
    
    private func loadBackupData() async {
        guard let userDID = appState.currentUserDID else { 
            logger.warning("Cannot load backup data: no current user DID")
            return 
        }
        
        logger.info("Loading backup data for user: \(userDID)")
        logger.info("appState.currentUserDID: '\(userDID)'")
        logger.info("appState.authManager.state.userDID: '\(appState.authManager.state.userDID ?? "nil")'")
        
        do {
            let records = try await appState.backupManager.getBackupRecords(for: userDID)
            let config = try await appState.backupManager.getBackupConfiguration(for: userDID)
            
            logger.info("Successfully loaded \(records.count) backup records")
            
            await MainActor.run {
                self.backupRecords = records
                self.backupConfiguration = config
            }
        } catch {
            logger.error("Failed to load backup data: \(error.localizedDescription)")
            await MainActor.run {
                // Silently handle error for initial load
                self.backupRecords = []
                self.backupConfiguration = nil
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

// MARK: - Backup UI Components

struct BackupRecordRowView: View {
    let record: BackupRecord
    
    var body: some View {
        HStack {
            // Status icon
            Image(systemName: record.status.systemImage)
                .foregroundStyle(colorFromString(record.status.color))
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Backup from \(record.ageDescription)")
                    .appFont(AppTextRole.callout)
                    .fontWeight(.medium)
                
                HStack {
                    Text(record.formattedFileSize)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(record.status.displayName)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(colorFromString(record.status.color))
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct BackupSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var config: BackupConfiguration
    @State private var experimentalParsingEnabled: Bool = false
    let onConfigurationUpdated: (BackupConfiguration) -> Void
    
    init(configuration: BackupConfiguration, onConfigurationUpdated: @escaping (BackupConfiguration) -> Void) {
        self._config = State(initialValue: configuration)
        self.onConfigurationUpdated = onConfigurationUpdated
    }
    
    var body: some View {
        @Bindable var appState = AppState.shared
        NavigationView {
            Form {
                Section("Automatic Backups") {
                    Toggle("Enable Automatic Backups", isOn: $config.autoBackupEnabled)
                    
                    if config.autoBackupEnabled {
                        Picker("Backup Frequency", selection: $config.backupFrequencyHours) {
                            Text("Daily").tag(24)
                            Text("Weekly").tag(168)
                            Text("Monthly").tag(720)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        Toggle("Backup on App Launch", isOn: $config.backupOnLaunch)
                    }
                }
                
                Section("Backup Management") {
                    Stepper("Keep \(config.maxBackupsToKeep) backups", value: $config.maxBackupsToKeep, in: 1...20)
                    
                    Toggle("Verify Backup Integrity", isOn: $config.verifyIntegrityAfterBackup)
                    
                    Toggle("Show Backup Notifications", isOn: $config.showBackupNotifications)
                }
                
                Section("🧪 Experimental Features") {
                    Toggle("Repository Parsing", isOn: $experimentalParsingEnabled)
                        .onChange(of: experimentalParsingEnabled) { _, newValue in
                            appState.repositoryParsingService.experimentalParsingEnabled = newValue
                        }
                    
                    if experimentalParsingEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("⚠️ Experimental CAR file parsing")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.orange)
                                .fontWeight(.medium)
                            
                            Text("• Parse CAR backups into structured data for analysis\n• May fail with malformed CAR files\n• Processing can take several minutes\n• Original backup files are never modified")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if let lastBackupDate = config.lastAutoBackupDate {
                    Section("Status") {
                        HStack {
                            Text("Last Automatic Backup")
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: lastBackupDate, relativeTo: Date()))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Backup Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onConfigurationUpdated(config)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            experimentalParsingEnabled = appState.repositoryParsingService.experimentalParsingEnabled
        }
    }
}

struct BackupDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let record: BackupRecord
    let onVerifyBackup: (BackupRecord) -> Void
    let onDeleteBackup: (BackupRecord) -> Void
    @State private var showDeleteAlert = false
    @State private var showExperimentalParsingAlert = false
    @State private var isParsingRepository = false
    @State private var parsingError: String?
    @State private var showParsingError = false
    @State private var repositoryRecord: RepositoryRecord?
    
    var body: some View {
        NavigationView {
            Form {
                Section("Backup Information") {
                    HStack {
                        Text("Created")
                        Spacer()
                        Text(record.createdDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("User")
                        Spacer()
                        Text("@\(record.userHandle)")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("File Size")
                        Spacer()
                        Text(record.formattedFileSize)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Status")
                        Spacer()
                        Label(record.status.displayName, systemImage: record.status.systemImage)
                            .foregroundStyle(colorFromString(record.status.color))
                    }
                    
                    if let lastVerified = record.lastVerifiedDate {
                        HStack {
                            Text("Last Verified")
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: lastVerified, relativeTo: Date()))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                if let errorMessage = record.errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                
                Section("Actions") {
                    Button("Verify Backup Integrity") {
                        onVerifyBackup(record)
                    }
                    .disabled(record.status == .verifying)
                    
                    // ⚠️ EXPERIMENTAL: Repository parsing button
                    Button {
                        showExperimentalParsingAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "cpu")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Parse Repository (EXPERIMENTAL)")
                                    .fontWeight(.medium)
                                Text("⚠️ Experimental feature - may fail with some CAR files")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!appState.repositoryParsingService.experimentalParsingEnabled)
                    
                    Button("Delete Backup", role: .destructive) {
                        showDeleteAlert = true
                    }
                }
                
                Section("Technical Details") {
                    HStack {
                        Text("File Path")
                        Spacer()
                        Text(record.filePath)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Data Hash")
                        Spacer()
                        Text(String(record.carDataHash.prefix(8)) + "...")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // ⚠️ EXPERIMENTAL: Repository parsing status
                if appState.repositoryParsingService.experimentalParsingEnabled {
                    Section("🧪 Experimental: Repository Parsing") {
                        if let repoRecord = repositoryRecord {
                            HStack {
                                Image(systemName: repoRecord.parsingStatus.systemImage)
                                    .foregroundStyle(colorFromString(repoRecord.parsingStatus.color))
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Repository Parsed")
                                        .fontWeight(.medium)
                                    
                                    Text("\(repoRecord.successfullyParsedCount) of \(repoRecord.totalRecordCount) records parsed (\(repoRecord.successRate))")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    Text("Confidence: \(String(format: "%.1f%%", repoRecord.parsingConfidenceScore * 100))")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(repoRecord.isParsingReliable ? .green : .orange)
                                }
                                
                                Spacer()
                            }
                            
                            if repoRecord.postCount > 0 {
                                HStack {
                                    Image(systemName: "text.bubble")
                                    Text("\(repoRecord.postCount) posts")
                                    Spacer()
                                }
                            }
                            
                            if repoRecord.connectionCount > 0 {
                                HStack {
                                    Image(systemName: "person.2")
                                    Text("\(repoRecord.connectionCount) connections")
                                    Spacer()
                                }
                            }
                            
                            if repoRecord.mediaCount > 0 {
                                HStack {
                                    Image(systemName: "photo")
                                    Text("\(repoRecord.mediaCount) media items")
                                    Spacer()
                                }
                            }
                            
                        } else if isParsingRepository {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Parsing Repository...")
                                        .fontWeight(.medium)
                                    
                                    if let operation = appState.repositoryParsingService.currentParsingOperation,
                                       operation.backupRecord.id == record.id {
                                        Text(operation.status.displayName)
                                            .appFont(AppTextRole.caption)
                                            .foregroundStyle(.secondary)
                                        
                                        if operation.progress > 0 {
                                            ProgressView(value: operation.progress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                        }
                                    }
                                }
                                
                                Spacer()
                            }
                            
                        } else {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                
                                Text("Repository not parsed yet")
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Backup Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Backup", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    onDeleteBackup(record)
                    dismiss()
                }
            } message: {
                Text("This will permanently delete this backup file. This action cannot be undone.")
            }
            .alert("🧪 Experimental Repository Parsing", isPresented: $showExperimentalParsingAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Parse Repository") {
                    startRepositoryParsing()
                }
            } message: {
                Text("⚠️ This is experimental functionality that parses CAR files into structured data.\n\n• May fail with malformed CAR files\n• Processing may take several minutes\n• Original backup file will not be modified\n• Parsed data is stored separately for analysis")
            }
            .alert("Parsing Error", isPresented: $showParsingError) {
                Button("OK") { }
            } message: {
                Text(parsingError ?? "An unknown parsing error occurred")
            }
            .task {
                // Check if repository is already parsed
                do {
                    repositoryRecord = try appState.repositoryParsingService.getRepositoryRecord(for: record.id)
                } catch {
                    // Silently handle error
                }
            }
        }
    }
    
    // MARK: - Experimental Repository Parsing Methods
    
    private func startRepositoryParsing() {
        isParsingRepository = true
        parsingError = nil
        
        Task {
            do {
                let repoRecord = try await appState.repositoryParsingService.startRepositoryParsing(for: record)
                
                await MainActor.run {
                    self.repositoryRecord = repoRecord
                    self.isParsingRepository = false
                }
                
            } catch {
                await MainActor.run {
                    self.isParsingRepository = false
                    self.parsingError = error.localizedDescription
                    self.showParsingError = true
                }
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
