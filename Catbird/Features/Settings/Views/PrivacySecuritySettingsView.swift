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

enum LoggedOutVisibilitySelfLabels {
    static let noUnauthenticated = "!no-unauthenticated"

    static func reconciled(_ labels: [String], isVisible: Bool) -> [String] {
        var result = labels.filter { $0 != noUnauthenticated }
        if !isVisible {
            result.append(noUnauthenticated)
        }
        return result
    }
}

struct LoggedOutVisibilityChangeGate {
    private var suppressedTarget: Bool?

    mutating func prepareProgrammaticChange(current: Bool, target: Bool) -> Bool {
        guard current != target else { return false }
        suppressedTarget = target
        return true
    }

    mutating func shouldWriteChange(to value: Bool) -> Bool {
        defer { suppressedTarget = nil }
        return suppressedTarget != value
    }
}

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppStateManager.self) private var appStateManager
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    
    // 2FA state
    @State private var email: String = ""
    @State private var isEmailVerified: Bool = false
    @State private var emailAuthFactor: Bool? = nil
    @State private var isLoading2FA: Bool = true
    @State private var isUpdating2FA: Bool = false
    @State private var isRequestingDisableCode: Bool = false
    @State private var isSubmittingDisableCode: Bool = false
    @State private var showEnable2FAConfirmation: Bool = false
    @State private var showDisable2FASheet: Bool = false
    @State private var disable2FACode: String = ""
    @State private var show2FAError: Bool = false
    @State private var twoFAErrorMessage: String = ""
    @State private var twoFATask: Task<Void, Never>? = nil
    
    // Loading states
    @State private var isLoadingBlocks = false
    @State private var isLoadingMutes = false
    
    // Block and mute lists
    @State private var blockedProfiles: [String] = []
    @State private var mutedProfiles: [String] = []
    
    // Privacy settings
    @State private var loggedOutVisibility: Bool = false
    @State private var biometricAuthEnabled: Bool = false
    @State private var isLoadingLoggedOutVisibility = false
    @State private var isUpdatingLoggedOutVisibility = false
    @State private var showLoggedOutVisibilityError = false
    @State private var loggedOutVisibilityErrorMessage = ""
    @State private var loggedOutVisibilityChangeGate = LoggedOutVisibilityChangeGate()
    
    // Algorithmic Recommendations Opt-Out (G34)
    @State private var hideFromAlgorithmicRecommendations: Bool = false
    @State private var isLoadingAlgorithmicVisibility = false
    @State private var isUpdatingAlgorithmicVisibility = false
    @State private var showAlgorithmicVisibilityError = false
    @State private var algorithmicVisibilityErrorMessage = ""
    @State private var algorithmicVisibilityTask: Task<Void, Never>? = nil
    // Biometric error handling
    @State private var showBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var isEnablingBiometric = false
    
    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "PrivacySecuritySettings")
    
    let initialFocus: SettingsControlID?
    @State private var mountedAccountDID: String?
    @State private var hasFinishedInitialLoad = false
    @State private var hasLoadedVisibility = false
    @State private var hasLoadedAlgorithmicVisibility = false
    @State private var visibilityTask: Task<Void, Never>?
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
    
    /// Display name for the current biometric type
    private var biometricDisplayName: String {
        switch AppStateManager.shared.authentication.biometricType {
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
        SettingsFocusedForm(initialFocus: initialFocus, isReady: hasFinishedInitialLoad) {
            SettingsScopeSection()
            SettingsPersistenceStatusSection(settings: appState.appSettings)
            Section {
                if hasLoadedVisibility {
                Toggle("Visible to Signed-Out Visitors", isOn: Binding(
                    get: { loggedOutVisibility },
                    set: { value in
                        guard hasLoadedVisibility, mountedAccountDID == appState.userDID else { return }
                        let previous = loggedOutVisibility
                        loggedOutVisibility = value
                        visibilityTask?.cancel()
                        visibilityTask = Task { await updateLoggedOutVisibility(value, previousValue: previous) }
                    }
                ))
                .disabled(!hasLoadedVisibility || isLoadingLoggedOutVisibility || isUpdatingLoggedOutVisibility)
                }
                if isLoadingLoggedOutVisibility { ProgressView("Loading visibility…") }
                if !hasLoadedVisibility && !isLoadingLoggedOutVisibility {
                    Text("Couldn’t load visibility. Your current setting is unchanged.").foregroundStyle(.secondary)
                    Button("Try Again") { visibilityTask = Task { await loadLoggedOutVisibility() } }
                }
            } footer: { Text("Turning this off asks Bluesky and other apps not to show your profile and posts to people who aren’t signed in. Other apps may not honor this request, and it doesn’t make your account private.") }
            .settingsControl(.init(rawValue: "privacy.loggedOutVisibility"))
            Section {
                if hasLoadedAlgorithmicVisibility {
                Toggle("Ask Apps to Exclude My Posts from Recommendations", isOn: Binding(
                    get: { hideFromAlgorithmicRecommendations },
                    set: { value in
                        guard hasLoadedAlgorithmicVisibility, mountedAccountDID == appState.userDID else { return }
                        let previous = hideFromAlgorithmicRecommendations
                        hideFromAlgorithmicRecommendations = value
                        algorithmicVisibilityTask?.cancel()
                        algorithmicVisibilityTask = Task { await updateAlgorithmicVisibility(value, previousValue: previous) }
                    }
                ))
                .disabled(!hasLoadedAlgorithmicVisibility || isLoadingAlgorithmicVisibility || isUpdatingAlgorithmicVisibility)
                }
                if isLoadingAlgorithmicVisibility { ProgressView("Loading recommendation request…") }
                if !hasLoadedAlgorithmicVisibility && !isLoadingAlgorithmicVisibility {
                    Text("Couldn’t load the recommendation request. Your current setting is unchanged.").foregroundStyle(.secondary)
                    Button("Try Again") { algorithmicVisibilityTask = Task { await loadAlgorithmicVisibility() } }
                }
            } footer: { Text("Requests that Bluesky and third-party apps exclude your posts from algorithmic feeds and discovery. Apps decide whether to honor this request.") }
            .settingsControl(.init(rawValue: "privacy.algorithmicVisibility"))
            Section {
                Toggle("Credit Repost Discovery", isOn: Binding(
                    get: { appState.appSettings.enableViaAttribution },
                    set: { appState.appSettings.enableViaAttribution = $0 }
                ))
                .disabled(!appState.appSettings.canEditPersistedSettings)
                .settingsControl(.init(rawValue: "privacy.attribution"))
            } footer: { Text("Shows attribution when you discover a post through another person’s repost.") }
        }
        .navigationTitle("Visibility & Attribution")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task(id: appState.userDID) {
            hasFinishedInitialLoad = false
            mountedAccountDID = appState.userDID
            hasLoadedVisibility = false
            hasLoadedAlgorithmicVisibility = false
            await loadData()
            if !Task.isCancelled { hasFinishedInitialLoad = true }
        }
        .alert("Couldn’t Update Visibility", isPresented: $showLoggedOutVisibilityError) { Button("OK", role: .cancel) { } }
            message: { Text(loggedOutVisibilityErrorMessage) }
        .alert("Couldn’t Update Recommendations", isPresented: $showAlgorithmicVisibilityError) { Button("OK", role: .cancel) { } }
            message: { Text(algorithmicVisibilityErrorMessage) }
        .onDisappear { visibilityTask?.cancel(); algorithmicVisibilityTask?.cancel() }
    }

    private func loadData() async {
        await loadLoggedOutVisibility()
        await loadAlgorithmicVisibility()
    }

    // MARK: - Progressive Permission & 2FA
    
    @MainActor
    private func ensurePermission(_ permission: GatewayPermission) async throws {
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
    }
    
    @MainActor
    private func load2FAStatus() async {
        guard appState.isAuthenticated, let client = appState.atProtoClient else {
            isLoading2FA = false
            return
        }
        
        isLoading2FA = true
        defer { isLoading2FA = false }
        
        do {
            let (code, session) = try await client.com.atproto.server.getSession()
            if code == 200, let session = session {
                self.email = session.email ?? ""
                self.isEmailVerified = session.emailConfirmed ?? false
                self.emailAuthFactor = session.emailAuthFactor
            }
        } catch {
            logger.error("Error loading 2FA session info: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func enable2FAAction() {
        twoFATask?.cancel()
        twoFATask = Task { @MainActor in
            guard let client = appState.atProtoClient else { return }
            
            isUpdating2FA = true
            defer { isUpdating2FA = false }
            
            do {
                try await ensurePermission(.accountEmailManage)
                guard !Task.isCancelled else { return }
                
                // Fetch fresh session to get the authoritative unredacted email under the upgraded scope
                let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                guard !Task.isCancelled else { return }
                guard sessionCode == 200, let session = sessionData, let sessionEmail = session.email, !sessionEmail.isEmpty else {
                    throw NSError(
                        domain: "PrivacySecuritySettings",
                        code: sessionCode,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve account email from server."]
                    )
                }
                self.email = sessionEmail
                self.isEmailVerified = session.emailConfirmed ?? false
                self.emailAuthFactor = session.emailAuthFactor
                
                let input = ComAtprotoServerUpdateEmail.Input(
                    email: sessionEmail,
                    emailAuthFactor: true,
                    token: nil
                )
                let responseCode = try await client.com.atproto.server.updateEmail(input: input)
                
                if (200...299).contains(responseCode) {
                            } else if !Task.isCancelled {
                    twoFAErrorMessage = "Failed to enable two-factor authentication (Code: \(responseCode))."
                    show2FAError = true
                }
            } catch is CancellationError {
                // Cancelled
            } catch GatewayPermissionError.cancelled {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                twoFAErrorMessage = error.localizedDescription
                show2FAError = true
            }
        }
    }
    
    @MainActor
    private func startDisable2FAFlow() {
        twoFATask?.cancel()
        twoFATask = Task { @MainActor in
            guard let client = appState.atProtoClient else { return }
            
            isRequestingDisableCode = true
            defer { isRequestingDisableCode = false }
            
            do {
                try await ensurePermission(.accountEmailManage)
                guard !Task.isCancelled else { return }
                
                let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                guard !Task.isCancelled else { return }
                if sessionCode == 200, let session = sessionData, let sessionEmail = session.email, !sessionEmail.isEmpty {
                    self.email = sessionEmail
                    self.isEmailVerified = session.emailConfirmed ?? false
                    self.emailAuthFactor = session.emailAuthFactor
                }
                
                let (responseCode, _) = try await client.com.atproto.server.requestEmailUpdate()
                
                if (200...299).contains(responseCode) {
                    disable2FACode = ""
                    showDisable2FASheet = true
                } else if !Task.isCancelled {
                    twoFAErrorMessage = "Failed to request confirmation code (Code: \(responseCode))."
                    show2FAError = true
                }
            } catch is CancellationError {
                // Cancelled
            } catch GatewayPermissionError.cancelled {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                twoFAErrorMessage = error.localizedDescription
                show2FAError = true
            }
        }
    }
    
    @MainActor
    private func submitDisable2FA(token: String) {
        twoFATask?.cancel()
        twoFATask = Task { @MainActor in
            guard let client = appState.atProtoClient else { return }
            
            isSubmittingDisableCode = true
            defer { isSubmittingDisableCode = false }
            
            do {
                try await ensurePermission(.accountEmailManage)
                guard !Task.isCancelled else { return }
                
                // Fetch fresh session to get the authoritative unredacted email under the upgraded scope
                let (sessionCode, sessionData) = try await client.com.atproto.server.getSession()
                guard !Task.isCancelled else { return }
                guard sessionCode == 200, let session = sessionData, let sessionEmail = session.email, !sessionEmail.isEmpty else {
                    throw NSError(
                        domain: "PrivacySecuritySettings",
                        code: sessionCode,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve account email from server."]
                    )
                }
                self.email = sessionEmail
                self.isEmailVerified = session.emailConfirmed ?? false
                self.emailAuthFactor = session.emailAuthFactor
                
                let input = ComAtprotoServerUpdateEmail.Input(
                    email: sessionEmail,
                    emailAuthFactor: false,
                    token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let responseCode = try await client.com.atproto.server.updateEmail(input: input)
                
                if (200...299).contains(responseCode) {
                    showDisable2FASheet = false
                            } else if !Task.isCancelled {
                    twoFAErrorMessage = "Failed to disable two-factor authentication (Code: \(responseCode)). Please check your code and try again."
                    show2FAError = true
                }
            } catch is CancellationError {
                // Cancelled
            } catch GatewayPermissionError.cancelled {
                // Cancelled
            } catch {
                guard !Task.isCancelled else { return }
                twoFAErrorMessage = error.localizedDescription
                show2FAError = true
            }
        }
    }

    private static let noUnauthenticatedLabel = "!no-unauthenticated"

    private func loadLoggedOutVisibility() async {
        let expectedDID = appState.userDID
        let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
        guard appState.isAuthenticated, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision), let client = appState.atProtoClient else { return }
        isLoadingLoggedOutVisibility = true
        defer { if SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) { isLoadingLoggedOutVisibility = false } }

        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let (code, record) = try await client.com.atproto.repo.getRecord(
                    input: try profileRecordParameters(for: expectedDID)
                )
                let isVisible: Bool
                if code == 200, let record {
                    guard case let .knownType(value) = record.value,
                          let profile = value as? AppBskyActorProfile else {
                        throw visibilityError("Unexpected profile record format.")
                    }
                    isVisible = !Self.hasNoUnauthenticatedLabel(profile.labels)
                } else if code == 404 {
                    isVisible = true
                } else {
                    throw visibilityError("Failed to load profile record (\(code)).")
                }

                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
                setLoggedOutVisibilityProgrammatically(isVisible)
                hasLoadedVisibility = true
            }
        } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            setLoggedOutVisibilityProgrammatically(true)
            hasLoadedVisibility = true
        } catch is CancellationError {
            // Cancelled
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            logger.error("Error loading logged-out visibility: \(error.localizedDescription)")
        }
    }

    private func updateLoggedOutVisibility(_ isVisible: Bool, previousValue: Bool) async {
        let expectedDID = appState.userDID
        let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
        guard SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision), let client = appState.atProtoClient else {
            revertLoggedOutVisibility(to: previousValue, message: "Sign in to change this setting.")
            return
        }

        isUpdatingLoggedOutVisibility = true
        defer { isUpdatingLoggedOutVisibility = false }

        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let (code, record) = try await client.com.atproto.repo.getRecord(
                    input: try profileRecordParameters(for: expectedDID)
                )
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
                if code == 200, let record {
                    try await putProfileVisibility(
                        record: record,
                        isVisible: isVisible,
                        client: client,
                        accountDID: expectedDID
                    )
                } else if code == 404 {
                    try await createProfileVisibility(isVisible: isVisible, client: client, accountDID: expectedDID)
                } else {
                    throw visibilityError("Failed to load profile record (\(code)).")
                }
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
                appState.appSettings.loggedOutVisibility = isVisible
            }
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            logger.error("Error updating logged-out visibility: \(error.localizedDescription)")
            revertLoggedOutVisibility(
                to: previousValue,
                message: UserFacingError.message(for: error, action: "update this setting") ?? "Couldn’t update this setting. Try again."
            )
        }
    }

    private func loadAlgorithmicVisibility() async {
        let expectedDID = appState.userDID
        let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
        guard appState.isAuthenticated, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision), let client = appState.atProtoClient else { return }
        isLoadingAlgorithmicVisibility = true
        defer { if SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) { isLoadingAlgorithmicVisibility = false } }

        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let (code, recordData) = try await client.com.atproto.repo.getRecord(
                    input: .init(
                        repo: try ATIdentifier(string: expectedDID),
                        collection: try NSID(nsidString: "app.bsky.actor.contentVisibilityDeclaration"),
                        rkey: try RecordKey(keyString: "self")
                    )
                )
                guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
                if code == 200, let record = recordData,
                   case let .knownType(declarationValue) = record.value,
                   let declaration = declarationValue as? AppBskyActorContentVisibilityDeclaration {
                    self.hideFromAlgorithmicRecommendations = declaration.hideFromAlgorithmicRecommendations
                    hasLoadedAlgorithmicVisibility = true
                } else if code == 404 {
                    // Explicit record-not-found implies false (opted in to recommendations)
                    self.hideFromAlgorithmicRecommendations = false
                    hasLoadedAlgorithmicVisibility = true
                } else {
                    throw NSError(domain: "PrivacySecuritySettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to load content visibility declaration (\(code))."])
                }
            }
        } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            self.hideFromAlgorithmicRecommendations = false
            hasLoadedAlgorithmicVisibility = true
        } catch is CancellationError {
            // Cancelled
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            // The section shows an inline retry; an alert on open would be redundant.
            logger.error("Failed to load content visibility declaration: \(error.localizedDescription)")
        }
    }

    private func updateAlgorithmicVisibility(_ hide: Bool, previousValue: Bool) async {
        let expectedDID = appState.userDID
        let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
        guard SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision), let client = appState.atProtoClient else {
            revertAlgorithmicVisibility(to: previousValue, message: "Sign in to change this setting.")
            return
        }

        isUpdatingAlgorithmicVisibility = true
        defer { isUpdatingAlgorithmicVisibility = false }

        do {
            let originatingAppState = appState
            try await originatingAppState.performSettingsAccountOperation {
                try Task.checkCancellation()
                let decl = AppBskyActorContentVisibilityDeclaration(hideFromAlgorithmicRecommendations: hide)
                let input = ComAtprotoRepoPutRecord.Input(
                    repo: try ATIdentifier(string: expectedDID),
                    collection: try NSID(nsidString: "app.bsky.actor.contentVisibilityDeclaration"),
                    rkey: try RecordKey(keyString: "self"),
                    record: .knownType(decl)
                )
                let (code, _) = try await client.com.atproto.repo.putRecord(input: input)
                guard code == 200 else {
                    throw NSError(domain: "PrivacySecuritySettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to update algorithmic recommendations setting (\(code))."])
                }
            }
        } catch {
            guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return }
            logger.error("Error updating algorithmic recommendations setting: \(error.localizedDescription)")
            revertAlgorithmicVisibility(to: previousValue, message: UserFacingError.message(for: error, action: "update this setting") ?? "Couldn’t update this setting. Try again.")
        }
    }

    private func revertAlgorithmicVisibility(to previousValue: Bool, message: String) {
        hideFromAlgorithmicRecommendations = previousValue
        algorithmicVisibilityErrorMessage = message
        showAlgorithmicVisibilityError = true
    }

    private func profileRecordParameters(for accountDID: String) throws -> ComAtprotoRepoGetRecord.Parameters {
        ComAtprotoRepoGetRecord.Parameters(
            repo: try ATIdentifier(string: accountDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self")
        )
    }
    private func putProfileVisibility(
        record: ComAtprotoRepoGetRecord.Output,
        isVisible: Bool,
        client: ATProtoClient,
        accountDID: String
    ) async throws {
        guard case let .knownType(value) = record.value,
              let profile = value as? AppBskyActorProfile else {
            throw visibilityError("Unexpected profile record format.")
        }

        let updatedProfile = AppBskyActorProfile(
            displayName: profile.displayName,
            description: profile.description,
            pronouns: profile.pronouns,
            website: profile.website,
            avatar: profile.avatar,
            banner: profile.banner,
            labels: try Self.updatedLabels(profile.labels, isVisible: isVisible),
            joinedViaStarterPack: profile.joinedViaStarterPack,
            pinnedPost: profile.pinnedPost,
            createdAt: profile.createdAt
        )
        let input = ComAtprotoRepoPutRecord.Input(
            repo: try ATIdentifier(string: accountDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(updatedProfile),
            swapRecord: record.cid
        )
        let (code, _) = try await client.com.atproto.repo.putRecord(input: input)
        guard code == 200 else { throw visibilityError("Profile update failed (\(code)).") }
    }

    private func createProfileVisibility(isVisible: Bool, client: ATProtoClient, accountDID: String) async throws {
        let profile = AppBskyActorProfile(
            displayName: nil,
            description: nil,
            pronouns: nil,
            website: nil,
            avatar: nil,
            banner: nil,
            labels: try Self.updatedLabels(nil, isVisible: isVisible),
            joinedViaStarterPack: nil,
            pinnedPost: nil,
            createdAt: ATProtocolDate(date: Date())
        )
        let input = ComAtprotoRepoCreateRecord.Input(
            repo: try ATIdentifier(string: accountDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(profile)
        )
        let (code, _) = try await client.com.atproto.repo.createRecord(input: input)
        guard code == 200 else { throw visibilityError("Profile creation failed (\(code)).") }
    }

    private static func hasNoUnauthenticatedLabel(
        _ labels: AppBskyActorProfile.AppBskyActorProfileLabelsUnion?
    ) -> Bool {
        guard case let .comAtprotoLabelDefsSelfLabels(selfLabels) = labels else { return false }
        return selfLabels.values.contains { $0.val == noUnauthenticatedLabel }
    }

    private static func updatedLabels(
        _ labels: AppBskyActorProfile.AppBskyActorProfileLabelsUnion?,
        isVisible: Bool
    ) throws -> AppBskyActorProfile.AppBskyActorProfileLabelsUnion? {
        let sourceValues: [ComAtprotoLabelDefs.SelfLabel]
        switch labels {
        case .comAtprotoLabelDefsSelfLabels(let selfLabels):
            sourceValues = selfLabels.values
        case .unexpected:
            throw visibilityError("Unsupported profile label format; no changes were made.")
        case nil:
            sourceValues = []
        }
        let values = LoggedOutVisibilitySelfLabels
            .reconciled(sourceValues.map(\.val), isVisible: isVisible)
            .map { ComAtprotoLabelDefs.SelfLabel(val: $0) }
        guard !values.isEmpty else { return nil }
        return .comAtprotoLabelDefsSelfLabels(.init(values: values))
    }

    private func revertLoggedOutVisibility(to previousValue: Bool, message: String) {
        setLoggedOutVisibilityProgrammatically(previousValue)
        loggedOutVisibilityErrorMessage = message
        showLoggedOutVisibilityError = true
    }

    private func setLoggedOutVisibilityProgrammatically(_ value: Bool) {
        _ = loggedOutVisibilityChangeGate.prepareProgrammaticChange(
            current: loggedOutVisibility,
            target: value
        )
        loggedOutVisibility = value
    }

    private static func visibilityError(_ message: String) -> NSError {
        NSError(
            domain: "PrivacySecuritySettings",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func visibilityError(_ message: String) -> NSError {
        Self.visibilityError(message)
    }
    
    private func handleBiometricToggle(_ enabled: Bool) async {
        await MainActor.run {
            isEnablingBiometric = true
        }
        
        // Call the AuthManager to set biometric auth
        await AppStateManager.shared.authentication.setBiometricAuthEnabled(enabled)
        
        // Update local state to match AuthManager state
        await MainActor.run {
            isEnablingBiometric = false
            biometricAuthEnabled = AppStateManager.shared.authentication.biometricAuthEnabled
            
            // Check if the operation failed
            if biometricAuthEnabled != enabled && enabled {
                // The toggle didn't work as expected, show an error
                if let error = AppStateManager.shared.authentication.lastBiometricError {
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
    
    // Age-related helper removed
    @ViewBuilder
    private var twoFactorSection: some View {
        Section {
            if isLoading2FA {
                HStack {
                    Text("Email 2FA")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            } else if email.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email Authentication")
                        .fontWeight(.medium)
                    Text("No email address configured. Add an email in Account Settings to enable two-factor authentication.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !isEmailVerified {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Email Authentication")
                        .fontWeight(.medium)
                        Spacer()
                        Label("Unverified", systemImage: "exclamationmark.triangle.fill")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Your email (\(email)) must be verified before enabling two-factor authentication. Please verify it in Account Settings.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                let is2FAEnabled = (emailAuthFactor == true)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email Authentication")
                            .fontWeight(.medium)
                        Text(is2FAEnabled
                             ? "Security codes are required when signing in."
                             : "Require a security code sent to your email when signing in.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if is2FAEnabled {
                        Label("Enabled", systemImage: "checkmark.shield.fill")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Disabled", systemImage: "shield.slash")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if is2FAEnabled {
                    Button("Disable Email 2FA") {
                        startDisable2FAFlow()
                    }
                    .foregroundStyle(.red)
                    .disabled(isUpdating2FA || isRequestingDisableCode)
                } else {
                    Button("Enable Email 2FA") {
                        showEnable2FAConfirmation = true
                    }
                    .disabled(isUpdating2FA || isRequestingDisableCode)
                }
            }
        } header: {
            Text("Two-Factor Authentication")
        } footer: {
            Text("When enabled, an email with a verification code will be sent to your email address each time you sign in.")
                .appFont(AppTextRole.footnote)
                .foregroundStyle(.secondary)
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                            avatar: profile.finalAvatarURL()
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                            avatar: profile.finalAvatarURL()
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

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            PrivacySecuritySettingsView()
        }
  }

}
