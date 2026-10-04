import SwiftUI
import Petrel
import OSLog
import UniformTypeIdentifiers

private struct CARFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        if let carType = UTType(filenameExtension: "car") {
            return [carType, .data]
        }
        return [.data]
    }
    
    var data: Data
    
    init(data: Data = Data()) {
        self.data = data
    }
    
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppStateManager.self) private var appStateManager
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    
    @State private var isLoading = true
    @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
    private let logger = Logger(subsystem: "blue.catbird", category: "AccountSettings")
    
    // Email management & verification
    @State private var isEmailVerified = false
    @State private var email = ""
    @State private var hasEmailScope = false
    @State private var emailAuthFactor: Bool?
    @State private var isShowingEmailSheet = false
    // Handle management
    @State private var isShowingHandleSheet = false
    
    // Automation / Bot label
    @State private var isBotAccount = false
    @State private var hasConfirmedAccountType = false
    
    // CAR Repository Export
    @State private var isExportingData = false
    @State private var exportDocument: CARFileDocument?
    @State private var isShowingFileExporter = false
    @State private var exportFilename = "repository.car"
    // Account status & management
    @State private var isAccountActive: Bool?
    @State private var accountStatus: String?
    @State private var isShowingDeactivateAlert = false
    @State private var deactivateConfirmText = ""
    @State private var isDeactivating = false
    @State private var isReactivating = false
    @State private var formError: String?
    @State private var showingFormError = false

    // Retained operation tasks
    @State private var loadDetailsTask: Task<Void, Never>?
    @State private var manageEmailTask: Task<Void, Never>?
    @State private var sendVerificationTask: Task<Void, Never>?
    @State private var deactivationTask: Task<Void, Never>?
    @State private var reactivationTask: Task<Void, Never>?
    @State private var verificationPollingTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var consecutivePollingErrors = 0
    
    // MARK: - Progressive Permission Presenter
    
    @MainActor
    private func ensurePermission(_ permission: GatewayPermission) async throws {
        let expectedDID = appState.userDID
        let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
        try await appStateManager.authentication.ensureGatewayPermission(permission) { authURL in
            if #available(iOS 17.4, macOS 14.4, *) {
                return try await webAuthenticationSession.authenticate(
                    using: authURL,
                    callback: .https(host: "catbird.blue", path: "/oauth/permission-callback"),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
            } else {
                return try await webAuthenticationSession.authenticate(
                    using: authURL,
                    callbackURLScheme: "catbird",
                    preferredBrowserSession: .shared
                )
            }
        }
        guard appState.userDID == expectedDID, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else {
            throw GatewayPermissionError.stateChanged
        }
    }
    
    // MARK: - Error Handling
    
    @MainActor
    private func handleAPIError(_ error: Error, operation: String) {
        if error is CancellationError {
            return
        }
        if let gatewayError = error as? GatewayPermissionError, gatewayError == .cancelled {
            return
        }
        
        let errorMessage: String
        
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
    
    let initialFocus: SettingsControlID?
    @State private var mountedAccountDID: String?
    @State private var mountedAccountRevision: UInt64 = 0
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }

    // MARK: - Body
    
    var body: some View {
        Group {
            SettingsFocusedForm(initialFocus: initialFocus, isReady: !isLoading) {
                SettingsScopeSection()
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
                        .disabled(isLoading || isDeactivating || isReactivating)
                    }
                    
                    .settingsControl(.init(rawValue: "account.handle"))
                    emailSection.settingsControl(.init(rawValue: "account.email"))
                    
                    Section("Account Type") {
                        SettingsLink(screen: .automationLabel, summary: hasConfirmedAccountType ? (isBotAccount ? "Bot" : "None") : "Unknown", systemImage: "person.crop.rectangle.badge.plus", family: .account)

                    }
                    
                    .settingsControl(.init(rawValue: "account.automation"))
                    Section {
                        Button {
                            exportRepositoryData()
                        } label: {
                            if isExportingData {
                                HStack {
                                    Text("Downloading Repository Data...")
                                    Spacer()
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            } else {
                                HStack {
                                    Text("Export Public Account Data")
                                    Spacer()
                                    Image(systemName: "arrow.down.doc")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .disabled(isLoading || isExportingData || isDeactivating || isReactivating)
                    } header: {
                        Text("Data Export")
                    } footer: {
                        Text("Download your public AT Protocol repository as a CAR (Content Addressable aRchive) file. This contains your public posts, likes, follows, and profile data, Messages and local drafts are not included.")
                            .appFont(AppTextRole.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .settingsControl(.init(rawValue: "account.export"))
                    Section("Account Status") {
                        if isAccountActive == true {
                            Button("Deactivate Account") {
                                deactivateConfirmText = ""
                                isShowingDeactivateAlert = true
                            }
                            .foregroundStyle(.orange)
                            .disabled(isDeactivating || isReactivating || isLoading)
                            
                            if let status = accountStatus, !status.isEmpty && status.lowercased() != "active" {
                                Text("Account status: \(status.capitalized)")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if isAccountActive == false {
                            if let status = accountStatus?.lowercased(), status == "deactivated" {
                                Button {
                                    reactivateAccount()
                                } label: {
                                    if isReactivating {
                                        HStack {
                                            Text("Reactivating Account...")
                                            Spacer()
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        }
                                    } else {
                                        Text("Reactivate Account")
                                    }
                                }
                                .disabled(isReactivating || isDeactivating || isLoading)
                                .foregroundStyle(.blue)
                            } else if let status = accountStatus, !status.isEmpty {
                                accountUnavailableView(for: status)
                            } else {
                                accountUnavailableView(for: "inactive")
                            }
                        } else {
                            if let status = accountStatus, !status.isEmpty {
                                accountUnavailableView(for: status)
                            } else {
                                accountUnavailableView(for: "unavailable")
                            }
                        }
                    }
                    .settingsControl(.init(rawValue: "account.deactivate"))
                }
            }
            .navigationTitle("Account Details")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .task(id: appState.userDID) {
                mountedAccountDID = appState.userDID
                mountedAccountRevision = AppStateManager.shared.settingsAccountContextRevision
                logger.info("AccountSettingsView appeared, loading data...")
                await loadAccountDetails()
                logger.info("Initial data load complete")
            }
            .alert("Error", isPresented: $showingFormError) {
                Button("OK") { }
            } message: {
                Text(formError ?? "An unknown error occurred")
            }
            .sheet(isPresented: $isShowingEmailSheet) {
                EmailUpdateSheet(
                    currentEmail: hasEmailScope ? email : "",
                    emailAuthFactor: hasEmailScope ? emailAuthFactor : nil,
                    ensurePermission: { permission in
                        let targetDID = appState.userDID
                        let targetRevision = AppStateManager.shared.settingsAccountContextRevision
                        try await ensurePermission(permission)
                        guard appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                            throw GatewayPermissionError.stateChanged
                        }
                    },
                    onEmailUpdated: { _ in
                        reloadAccountDetails()
                    }
                )
            }
            .sheet(isPresented: $isShowingHandleSheet) {
                HandleUpdateSheet(
                    currentHandle: profile?.handle.description ?? "",
                    ensurePermission: { permission in
                        let targetDID = appState.userDID
                        let targetRevision = AppStateManager.shared.settingsAccountContextRevision
                        try await ensurePermission(permission)
                        guard appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                            throw GatewayPermissionError.stateChanged
                        }
                    },
                    onHandleUpdated: { newHandle in
                        let targetDID = appState.userDID
                        let targetRevision = AppStateManager.shared.settingsAccountContextRevision
                        guard appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else { return }
                        do {
                            try appStateManager.authentication.recordCurrentHandleChange(newHandle, for: targetDID)
                        } catch {
                            handleAPIError(error, operation: "update handle")
                        }
                        reloadAccountDetails()
                    }
                )
            }
            .alert("Deactivate Account", isPresented: $isShowingDeactivateAlert) {
                TextField("Type DEACTIVATE to confirm", text: $deactivateConfirmText)
                Button("Cancel", role: .cancel) {
                    deactivateConfirmText = ""
                }
                Button("Deactivate", role: .destructive) {
                    if deactivateConfirmText == "DEACTIVATE" {
                        deactivateAccount()
                    }
                }
                .disabled(deactivateConfirmText != "DEACTIVATE")
            } message: {
                Text("This will temporarily disable your account. You can reactivate it by logging in again.")
            }
            .fileExporter(
                isPresented: $isShowingFileExporter,
                document: exportDocument,
                contentType: UTType(filenameExtension: "car") ?? .data,
                defaultFilename: exportFilename
            ) { result in
                switch result {
                case .success(let url):
                    logger.info("Successfully exported repository CAR file to \(url.path)")
                case .failure(let error):
                    logger.error("Failed to save exported CAR file: \(error.localizedDescription)")
                }
                exportDocument = nil
            }
            .interactiveDismissDisabled(isDeactivating || isReactivating || isExportingData)
            .onDisappear {
                loadDetailsTask?.cancel()
                loadDetailsTask = nil
                manageEmailTask?.cancel()
                manageEmailTask = nil
                sendVerificationTask?.cancel()
                sendVerificationTask = nil
                if !isDeactivating {
                    deactivationTask?.cancel()
                    deactivationTask = nil
                }
                if !isReactivating {
                    reactivationTask?.cancel()
                    reactivationTask = nil
                }
                verificationPollingTask?.cancel()
                verificationPollingTask?.cancel()
                verificationPollingTask = nil
                exportTask?.cancel()
                exportTask = nil
            }
        }
    }
    
    // MARK: - Data Export
    
    @MainActor
    private func exportRepositoryData() {
        guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else { return }
        let userDID = appState.userDID
        let operationRevision = AppStateManager.shared.settingsAccountContextRevision
        let handle = profile?.handle.description ?? userDID
        let sanitizedHandle = handle.replacingOccurrences(of: "/", with: "-")
        exportFilename = "\(sanitizedHandle)-repository.car"
        isExportingData = true
        
        exportTask?.cancel()
        exportTask = Task { @MainActor in
            defer { isExportingData = false }
            do {
                let originatingAppState = appState
                try await originatingAppState.performSettingsAccountOperation {
                    try Task.checkCancellation()
                    let (code, output) = try await client.com.atproto.sync.getRepo(
                        input: .init(did: try DID(didString: userDID))
                    )
                    guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
                    if code == 200, let output = output, !output.data.isEmpty {
                        self.exportDocument = CARFileDocument(data: output.data)
                        self.isShowingFileExporter = true
                    } else {
                        formError = "Failed to export repository (status \(code))."
                        showingFormError = true
                    }
                }
            } catch {
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
                handleAPIError(error, operation: "export repository data")
            }
        }
    }
    
    // MARK: - Data Loading
    
    @MainActor
    private func reloadAccountDetails() {
        loadDetailsTask?.cancel()
        loadDetailsTask = Task { @MainActor in
            await loadAccountDetails()
        }
    }
    
    @MainActor
    private func loadAccountDetails() async {
        isLoading = true
        hasConfirmedAccountType = false
        isAccountActive = nil
        accountStatus = nil
        
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }
        
        guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
            if !Task.isCancelled {
                handleAPIError(AuthError.clientNotInitialized, operation: "load account details")
            }
            return
        }
        
        let userDID = appState.userDID
        let operationRevision = AppStateManager.shared.settingsAccountContextRevision
        
        // 1. Load session status & email info in independent do/catch
        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let grantedScopes = try await client.fetchGrantedScopes(for: userDID)
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            
                let emailScopeGranted = grantedScopes.contains(GatewayPermission.accountEmailManage.rawValue)
                self.hasEmailScope = emailScopeGranted
            
                let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            
                if sessionCode == 200, let session = sessionData {
                    if emailScopeGranted {
                        if let sessionEmail = session.email, !sessionEmail.isEmpty {
                            self.email = sessionEmail
                        } else {
                            self.email = ""
                        }
                        self.isEmailVerified = session.emailConfirmed ?? false
                        self.emailAuthFactor = session.emailAuthFactor
                    } else {
                        self.email = ""
                        self.isEmailVerified = false
                        self.emailAuthFactor = nil
                    }
                    self.isAccountActive = session.active
                    self.accountStatus = session.status
                } else {
                    self.email = ""
                    self.isEmailVerified = false
                    self.emailAuthFactor = nil
                    self.isAccountActive = nil
                    self.accountStatus = nil
                }
            }
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            self.hasEmailScope = false
            self.email = ""
            self.isEmailVerified = false
            self.emailAuthFactor = nil
            self.isAccountActive = nil
            self.accountStatus = nil
            handleAPIError(error, operation: "load account session")
        }
        
        guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
        
        // 2. Load profile and self-labels in independent do/catch so profile failure cannot erase status or reactivation
        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let (profileCode, profileData) = try await client.app.bsky.actor.getProfile(
                    input: .init(actor: ATIdentifier(string: userDID))
                )
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            
                if profileCode == 200, let profile = profileData {
                    self.profile = profile
                }
            
                let (recCode, recData) = try await client.com.atproto.repo.getRecord(
                    input: .init(
                        repo: try ATIdentifier(string: userDID),
                        collection: try NSID(nsidString: "app.bsky.actor.profile"),
                        rkey: try RecordKey(keyString: "self")
                    )
                )
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
                if recCode == 200, let record = recData,
                   case let .knownType(profileRecord) = record.value,
                   let profile = profileRecord as? AppBskyActorProfile {
                    switch profile.labels {
                    case .comAtprotoLabelDefsSelfLabels(let selfLabels):
                        self.isBotAccount = selfLabels.values.contains { $0.val == "bot" }
                        hasConfirmedAccountType = true
                    case nil:
                        self.isBotAccount = false
                        hasConfirmedAccountType = true
                    case .unexpected:
                        hasConfirmedAccountType = false
                    }
                }
            }
        } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            isBotAccount = false
            hasConfirmedAccountType = true
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
            logger.warning("Failed to load profile details: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Email Actions
    
    @MainActor
    private func manageEmailAction() {
        manageEmailTask?.cancel()
        manageEmailTask = Task { @MainActor in
            guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    handleAPIError(AuthError.clientNotInitialized, operation: "manage email")
                }
                return
            }
            isLoading = true
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }
            
            let targetDID = appState.userDID
            let targetRevision = AppStateManager.shared.settingsAccountContextRevision
            do {
                let originatingAppState = appState
                try await originatingAppState.performSettingsAccountOperation {
                    try Task.checkCancellation()
                    try await ensurePermission(.accountEmailManage)
                    guard !Task.isCancelled, appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                        if appState.userDID != targetDID {
                            throw GatewayPermissionError.stateChanged
                        }
                        return
                    }
                
                    let grantedScopes = try await client.fetchGrantedScopes(for: targetDID)
                    guard !Task.isCancelled, appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                        if appState.userDID != targetDID {
                            throw GatewayPermissionError.stateChanged
                        }
                        return
                    }
                
                    let emailScopeGranted = grantedScopes.contains(GatewayPermission.accountEmailManage.rawValue)
                    self.hasEmailScope = emailScopeGranted
                
                    guard emailScopeGranted else {
                        self.email = ""
                        self.isEmailVerified = false
                        self.emailAuthFactor = nil
                        formError = "Missing required email management permission."
                        showingFormError = true
                        return
                    }
                    let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                    guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                
                    if sessionCode == 200, let session = sessionData {
                        if let sessionEmail = session.email, !sessionEmail.isEmpty {
                            self.email = sessionEmail
                        } else {
                            self.email = ""
                        }
                        self.isEmailVerified = session.emailConfirmed ?? false
                        self.emailAuthFactor = session.emailAuthFactor
                        self.isAccountActive = session.active
                        self.accountStatus = session.status

                        guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                        isShowingEmailSheet = true
                    } else {
                        self.email = ""
                        self.isEmailVerified = false
                        self.emailAuthFactor = nil
                        formError = "Failed to load account session (Code: \(sessionCode))."
                        showingFormError = true
                    }
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "manage email")
            }
        }
    }
    
    @MainActor
    private func sendVerificationEmail() {
        isLoading = true
        
        sendVerificationTask?.cancel()
        sendVerificationTask = Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }
            
            guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    handleAPIError(AuthError.clientNotInitialized, operation: "send verification email")
                }
                return
            }
            let targetDID = appState.userDID
            let targetRevision = AppStateManager.shared.settingsAccountContextRevision
            do {
                let originatingAppState = appState
                try await originatingAppState.performSettingsAccountOperation {
                    try Task.checkCancellation()
                    try await ensurePermission(.accountEmailManage)
                    guard !Task.isCancelled, appState.userDID == targetDID, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                        if appState.userDID != targetDID {
                            throw GatewayPermissionError.stateChanged
                        }
                        return
                    }
                
                    let (responseCode) = try await client.com.atproto.server.requestEmailConfirmation()
                    guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else { return }
                
                    if (200...299).contains(responseCode) {
                        startEmailVerificationPolling()
                    } else if !Task.isCancelled {
                        formError = "Failed to send verification email (Code: \(responseCode)). Please try again."
                        showingFormError = true
                    }
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "send verification email")
            }
        }
    }
    
    @MainActor
    private func startEmailVerificationPolling() {
        verificationPollingTask?.cancel()
        consecutivePollingErrors = 0
        
        verificationPollingTask = Task { @MainActor in
            var pollCount = 0
            let maxPolls = 60
            let maxConsecutiveErrors = 3
            
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    break
                }
                
                guard !Task.isCancelled else { break }
                
                pollCount += 1
                let success = await checkEmailVerificationStatus()
                
                guard !Task.isCancelled else { break }
                
                if !success {
                    consecutivePollingErrors += 1
                    if consecutivePollingErrors >= maxConsecutiveErrors {
                        formError = "Email verification check failed after multiple attempts. Please try again."
                        showingFormError = true
                        break
                    }
                } else {
                    consecutivePollingErrors = 0
                }
                
                if isEmailVerified || pollCount >= maxPolls {
                    break
                }
            }
            
            if !Task.isCancelled {
                verificationPollingTask = nil
            }
        }
    }
    
    @MainActor
    @discardableResult
    private func checkEmailVerificationStatus() async -> Bool {
        guard mountedAccountDID == appState.userDID,
              mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
              let client = appState.atProtoClient else { return false }
        
        do {
            let originatingAppState = appState
            return try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let userDID = appState.userDID
                let operationRevision = AppStateManager.shared.settingsAccountContextRevision
                let grantedScopes = try await client.fetchGrantedScopes(for: userDID)
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return false }
            
                let emailScopeGranted = grantedScopes.contains(GatewayPermission.accountEmailManage.rawValue)
                self.hasEmailScope = emailScopeGranted
            
                if !emailScopeGranted {
                    self.email = ""
                    self.isEmailVerified = false
                    self.emailAuthFactor = nil
                    return false
                }
            
                let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return false }
            
                if sessionCode == 200, let session = sessionData {
                    self.isEmailVerified = session.emailConfirmed ?? false
                    if let sessionEmail = session.email, !sessionEmail.isEmpty {
                        self.email = sessionEmail
                    } else {
                        self.email = ""
                    }
                    self.emailAuthFactor = session.emailAuthFactor
                    self.isAccountActive = session.active
                    self.accountStatus = session.status
                    return true
                } else {
                    self.email = ""
                    self.isEmailVerified = false
                    self.emailAuthFactor = nil
                    self.isAccountActive = nil
                    self.accountStatus = nil
                    return false
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return false
            }
            logger.warning("Polling getSession error: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Account Management Actions
    
    @MainActor
    private func deactivateAccount() {
        isDeactivating = true
        
        deactivationTask?.cancel()
        deactivationTask = Task { @MainActor in
            defer {
                isDeactivating = false
            }
            
            guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    handleAPIError(AuthError.clientNotInitialized, operation: "deactivate account")
                }
                return
            }
            let targetDID = appState.userDID
            let targetRevision = AppStateManager.shared.settingsAccountContextRevision
            do {
                let originatingAppState = appState
                let responseCode = try await originatingAppState.performSettingsAccountOperation {
                    try Task.checkCancellation()
                    try await ensurePermission(.accountStatusManage)
                    guard !Task.isCancelled, originatingAppState.userDID == targetDID,
                          SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                        throw GatewayPermissionError.stateChanged
                    }
                    return try await client.com.atproto.server.deactivateAccount(
                        input: .init(deleteAfter: nil)
                    )
                }
                
                if (200...299).contains(responseCode) {
                    // Always process 2xx and reconcile logout even if view disappears
                    try? await appState.handleLogout()
                } else if !Task.isCancelled {
                    formError = "Failed to deactivate account (Code: \(responseCode)). Please try again."
                    showingFormError = true
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "deactivate account")
            }
        }
    }
    
    @MainActor
    private func reactivateAccount() {
        guard isAccountActive == false, accountStatus?.lowercased() == "deactivated" else { return }
        isReactivating = true
        
        reactivationTask?.cancel()
        reactivationTask = Task { @MainActor in
            defer {
                isReactivating = false
            }
            
            guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    handleAPIError(AuthError.clientNotInitialized, operation: "reactivate account")
                }
                return
            }
            let targetDID = appState.userDID
            let targetRevision = AppStateManager.shared.settingsAccountContextRevision
            do {
                let originatingAppState = appState
                let responseCode = try await originatingAppState.performSettingsAccountOperation {
                    try Task.checkCancellation()
                    try await ensurePermission(.accountStatusManage)
                    guard !Task.isCancelled, originatingAppState.userDID == targetDID,
                          SettingsAccountBoundary.isCurrent(targetDID, revision: targetRevision) else {
                        throw GatewayPermissionError.stateChanged
                    }
                    return try await client.com.atproto.server.activateAccount()
                }
                
                if (200...299).contains(responseCode) {
                    // Always process 2xx and reconcile status even if view disappears
                    await loadAccountDetails()
                } else if !Task.isCancelled {
                    formError = "Failed to reactivate account (Code: \(responseCode)). Please try again."
                    showingFormError = true
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "reactivate account")
            }
        }
    }
    
    // MARK: - Computed Subviews
    
    private var emailSection: some View {
        Section("Email & Sign-In Protection") {
            if hasEmailScope {
                LabeledContent("Email Sign-In Codes", value: emailAuthFactor.map { $0 ? "Required" : "Not required" } ?? "Not available")
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email Address")
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
                
                Button("Manage Email & Email 2FA") {
                    manageEmailAction()
                }
                .disabled(isLoading || isDeactivating || isReactivating)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email")
                            .fontWeight(.medium)
                        
                        Text("Manage email")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                Button("Manage Email & Email 2FA") {
                    manageEmailAction()
                }
                .disabled(isLoading || isDeactivating || isReactivating)
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
            .disabled(isLoading || isDeactivating || isReactivating)
            
            Text("A verification email will be sent to \(email). Click the link in the email to verify your address.")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
    
    private func accountUnavailableInfo(for status: String) -> (title: String, message: String, icon: String) {
        let normalizedStatus = status.lowercased()
        switch normalizedStatus {
        case "takendown", "taken-down":
            return ("Account Taken Down", "This account has been taken down and is unavailable.", "xmark.octagon.fill")
        case "suspended":
            return ("Account Suspended", "This account is suspended and cannot be reactivated.", "exclamationmark.octagon.fill")
        case "deleted":
            return ("Account Deleted", "This account has been deleted.", "trash.fill")
        case "inactive":
            return ("Account Inactive", "This account is inactive.", "exclamationmark.triangle.fill")
        case "unavailable":
            return ("Account Unavailable", "Account status is currently unavailable.", "exclamationmark.triangle.fill")
        default:
            return ("Account Unavailable", "This account is currently \(status).", "exclamationmark.triangle.fill")
        }
    }
    
    private func accountUnavailableView(for status: String) -> some View {
        let info = accountUnavailableInfo(for: status)
        return VStack(alignment: .leading, spacing: 6) {
            Label(info.title, systemImage: info.icon)
                .fontWeight(.medium)
                .foregroundStyle(.red)
            
            Text(info.message)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview("AccountSettingsView") {
    NavigationStack {
        AccountSettingsView()
    }
    .previewWithAuthenticatedState()
}
