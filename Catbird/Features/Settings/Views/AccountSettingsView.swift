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
    @State private var hasLoadedOnce = false
    @State private var sessionLoadFailed = false
    @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
    private let logger = Logger(subsystem: "blue.catbird", category: "AccountSettings")
    
    // Native management entry points are withheld for launch until permission escalation works.
    // Deferred handlers below remain unmounted; loading this view reads only profile/repository data.
    // Email management & verification
    @State private var isEmailVerified = false
    @State private var email = ""
    @State private var hasEmailScope = false
    @State private var emailAuthFactor: Bool?
    @State private var isShowingEmailSheet = false
    @State private var isManagingEmail = false
    @State private var isSendingVerification = false
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
    @State private var accountDeletionTarget: AccountDeletionTarget?
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
        
        guard let errorMessage = UserFacingError.message(for: error, action: operation) else { return }
        logger.error("Account settings couldn’t \(operation, privacy: .public): \(error.localizedDescription)")
        
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
            SettingsFocusedForm(initialFocus: initialFocus, isReady: hasLoadedOnce || !isLoading) {
                SettingsScopeSection(scope: "This account")
                if isLoading && !hasLoadedOnce {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Handle") {
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
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                        }
                        
                    }
                    
                    .settingsControl(.init(rawValue: "account.handle"))
                    
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
                                    Text("Exporting Account Data…")
                                    Spacer()
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            } else {
                                HStack {
                                    Text("Export Public Account Data")
                                    Spacer()
                                    Image(systemName: "arrow.down.doc")
                                }
                            }
                        }
                        .disabled(isLoading || isExportingData || isDeactivating || isReactivating)
                    } header: {
                        Text("Data Export")
                    } footer: {
                        Text("Download a copy of your public Bluesky data (posts, likes, follows and profile) as a .car file. Messages and drafts aren’t included.")
                            .appFont(AppTextRole.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .settingsControl(.init(rawValue: "account.export"))
                }
                Section {
                    Button("Manage Hosted Account") {
                        showProviderPage(for: .manageAccount)
                    }
                    .disabled(appState.userDID.isEmpty || isExportingData)
                } footer: {
                    Text("Manage your handle, email, and sign-in options on your hosting provider’s website.")
                }
                .settingsControl(.init(rawValue: "account.management"))
                Section {
                    Button("Account Deletion Options") {
                        showProviderPage(for: .deletionOptions)
                    }
                    .disabled(appState.userDID.isEmpty || isExportingData)
                    .accessibilityIdentifier("AccountDeletion.Options")
                } footer: {
                    Text("Find deletion instructions from your hosting provider. Opening its website does not delete anything.")
                }
                .settingsControl(.init(rawValue: "account.delete"))
            }
            .navigationTitle("Account Details")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .task(id: appState.userDID) {
                if mountedAccountDID != nil, mountedAccountDID != appState.userDID {
                    hasLoadedOnce = false
                }
                mountedAccountDID = appState.userDID
                mountedAccountRevision = AppStateManager.shared.settingsAccountContextRevision
                logger.info("AccountSettingsView appeared, loading data...")
                await loadAccountDetails()
                logger.info("Initial data load complete")
            }
            .alert("Something Went Wrong", isPresented: $showingFormError) {
                Button("OK") { }
            } message: {
                Text(formError ?? "Something went wrong. Try again.")
            }
            .sheet(item: $accountDeletionTarget) { target in
                AccountDeletionSheet(target: target)
                    .environment(\.openURL, OpenURLAction { url in .systemAction(url) })
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
    
    private var deactivateConfirmed: Bool {
        deactivateConfirmText.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("DEACTIVATE") == .orderedSame
    }
    
    private func showProviderPage(for purpose: AccountDeletionTarget.Purpose) {
        let did = appState.userDID
        guard !did.isEmpty else { return }
        let revision = AppStateManager.shared.settingsAccountContextRevision
        let handle = profile.flatMap { $0.did.description == did ? $0.handle.description : nil }
            ?? appStateManager.authentication.getCachedProfileData(for: did)?.handle
        accountDeletionTarget = AccountDeletionTarget(
            did: did,
            handle: handle,
            accountRevision: revision,
            purpose: purpose
        )
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
                        logger.error("Repository export returned status \(code)")
                        formError = "Couldn’t export your data. Try again."
                        showingFormError = true
                    }
                }
            } catch {
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(userDID, revision: operationRevision) else { return }
                handleAPIError(error, operation: "export your data")
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
        if !hasLoadedOnce {
            hasConfirmedAccountType = false
            isAccountActive = nil
            accountStatus = nil
        }
        
        defer {
            if !Task.isCancelled {
                isLoading = false
                hasLoadedOnce = true
            }
        }
        
        guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
            if !Task.isCancelled {
                handleAPIError(AuthError.clientNotInitialized, operation: "load your account details")
            }
            return
        }
        
        let userDID = appState.userDID
        let operationRevision = AppStateManager.shared.settingsAccountContextRevision
        
        // Profile and public repository reads do not require account-management escalation.
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
                    handleAPIError(AuthError.clientNotInitialized, operation: "open email settings")
                }
                return
            }
            isManagingEmail = true
            defer {
                if !Task.isCancelled {
                    isManagingEmail = false
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
                        formError = "Catbird needs permission to manage your email. Try again and allow access when asked."
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
                        logger.error("getSession returned status \(sessionCode) while opening email settings")
                        formError = "Couldn’t open email settings. Try again."
                        showingFormError = true
                    }
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "open email settings")
            }
        }
    }
    
    @MainActor
    private func sendVerificationEmail() {
        isSendingVerification = true
        
        sendVerificationTask?.cancel()
        sendVerificationTask = Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    isSendingVerification = false
                }
            }
            
            guard mountedAccountDID == appState.userDID,
                  mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true,
                  let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    handleAPIError(AuthError.clientNotInitialized, operation: "send the verification email")
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
                        logger.error("requestEmailConfirmation returned status \(responseCode)")
                        formError = "Couldn’t send the verification email. Try again."
                        showingFormError = true
                    }
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "send the verification email")
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
                        formError = "Couldn’t check whether your email is verified. Try again."
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
                    handleAPIError(AuthError.clientNotInitialized, operation: "deactivate your account")
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
                    logger.error("deactivateAccount returned status \(responseCode)")
                    formError = "Couldn’t deactivate your account. Try again."
                    showingFormError = true
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "deactivate your account")
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
                    handleAPIError(AuthError.clientNotInitialized, operation: "reactivate your account")
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
                    logger.error("activateAccount returned status \(responseCode)")
                    formError = "Couldn’t reactivate your account. Try again."
                    showingFormError = true
                }
            } catch is CancellationError {
                // User cancelled permission upgrade - preserve form
            } catch GatewayPermissionError.cancelled {
                // User cancelled permission upgrade - preserve form
            } catch {
                guard !Task.isCancelled, mountedAccountDID.map { SettingsAccountBoundary.isCurrent($0, revision: mountedAccountRevision) } == true else { return }
                handleAPIError(error, operation: "reactivate your account")
            }
        }
    }
    
    // MARK: - Computed Subviews
    
    private var emailSection: some View {
        Section("Email & Sign-In Codes") {
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
                
                Button("Manage Email & Sign-In Codes") {
                    manageEmailAction()
                }
                .disabled(isManagingEmail || isDeactivating || isReactivating)
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
                
                Button("Manage Email & Sign-In Codes") {
                    manageEmailAction()
                }
                .disabled(isManagingEmail || isDeactivating || isReactivating)
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
                if isSendingVerification {
                    HStack {
                        Text("Sending Verification Email…")
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                } else {
                    Text("Send Verification Email")
                }
            }
            .disabled(isSendingVerification || isDeactivating || isReactivating)
            
            Text("We’ll send a verification email to \(email). Tap the link in the email to verify your address.")
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
