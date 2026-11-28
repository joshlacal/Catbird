import AVKit
import BluemojiKit
import CatbirdMLSCore
import Foundation
import NaturalLanguage
import Nuke
import OSLog
import Petrel
import Security
import SwiftData
import SwiftUI
import UserNotifications

#if os(iOS)
    import UIKit
#endif

// MARK: - MLS Service State

/// Observable state tracking MLS service initialization with retry logic
/// NOTE: Not marked @Observable to prevent SwiftUI observation loops when accessed
/// through @ObservationIgnored properties. Views should poll or use explicit refresh.
final class MLSServiceState {
    var status: MLSInitStatus = .notStarted
    var retryCount: Int = 0
    var lastError: Error?
    let maxRetries: Int = 3

    /// Tracks database failure state with cooldown
    var databaseFailedAt: Date?

    /// Cooldown period before allowing database retry (5 minutes)
    let databaseRetryCooldown: TimeInterval = 300

    enum MLSInitStatus: Equatable {
        case notStarted
        case initializing
        case ready
        case failed(String)
        case retrying(attempt: Int)
        /// Database is severely corrupted and needs manual intervention or app restart
        case databaseFailed(String)

        static func == (lhs: MLSInitStatus, rhs: MLSInitStatus) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted),
                 (.initializing, .initializing),
                 (.ready, .ready):
                return true
            case let (.failed(lhsMsg), .failed(rhsMsg)):
                return lhsMsg == rhsMsg
            case let (.retrying(lhsAttempt), .retrying(rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case let (.databaseFailed(lhsMsg), .databaseFailed(rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }

        /// Check if the service is in a state that should prevent polling
        var shouldStopPolling: Bool {
            switch self {
            case .databaseFailed, .failed:
                return true
            case .notStarted, .initializing, .ready, .retrying:
                return false
            }
        }
    }

    /// Check if we're within the cooldown period after database failure
    var isInDatabaseCooldown: Bool {
        guard let failedAt = databaseFailedAt else { return false }
        return Date().timeIntervalSince(failedAt) < databaseRetryCooldown
    }

    /// Mark database as failed - stops polling until cooldown expires
    func markDatabaseFailed(message: String) {
        status = .databaseFailed(message)
        databaseFailedAt = Date()
    }

    /// Clear database failure state (call after successful recovery)
    func clearDatabaseFailure() {
        if case .databaseFailed = status {
            status = .notStarted
        }
        databaseFailedAt = nil
    }
}

/// Owns AppState account tasks and admitted asynchronous service entry points.
/// Closing admission precedes cancellation; a failed drain keeps the account closed.
@MainActor
final class AccountServiceWork {
    enum BarrierError: LocalizedError {
        case drainTimedOut, accountChanged, serviceResumeFailed, retirementFailed

        var errorDescription: String? {
            switch self {
            case .drainTimedOut: return "The previous account is still finishing a request. Try switching again."
            case .accountChanged: return "The original account could not be verified after the interrupted switch."
            case .serviceResumeFailed: return "The original account's services could not be safely resumed."
            case .retirementFailed: return "The previous account's storage could not be safely closed."
            }
        }
    }

    private(set) var isSuspended = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var operations: Set<UUID> = []

    @discardableResult
    func start(
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard !isSuspended else { return nil }
        let id = UUID()
        let task = Task(priority: priority) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks.removeValue(forKey: id) }
            guard !self.isSuspended, !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }

    func beginOperation() -> UUID? {
        guard !isSuspended, !Task.isCancelled else { return nil }
        let id = UUID()
        operations.insert(id)
        return id
    }

    func endOperation(_ id: UUID) { operations.remove(id) }
    func isCurrent(_ id: UUID) -> Bool { !isSuspended && operations.contains(id) && !Task.isCancelled }

    func suspend() {
        isSuspended = true
        for task in tasks.values { task.cancel() }
    }

    func drain(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !tasks.isEmpty || !operations.isEmpty {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BarrierError.drainTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func resume() { isSuspended = false }
}

/// Retains the real completion task independently of the caller's deadline.
/// Timing out never cancels away the evidence that services are still draining.
@MainActor
final class AccountServiceDrainReceipt {
    private(set) var isComplete = false
    private var task: Task<Void, Never>?

    init(operation: @escaping @MainActor () async -> Void) {
        task = Task { @MainActor [weak self] in
            await operation()
            self?.isComplete = true
        }
    }

    func wait(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isComplete {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw AccountServiceWork.BarrierError.drainTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - AppState

/// Central state container for the Catbird app
@Observable
final class AppState {
    // MARK: - Nested Types

    struct SearchRequest: Equatable {
        enum Focus: Equatable {
            case all
            case profiles
            case posts
            case feeds
        }

        let id: UUID
        let query: String
        let focus: Focus
        let originProfileDID: String?

        init(query: String, focus: Focus = .posts, originProfileDID: String? = nil) {
            id = UUID()
            self.query = query
            self.focus = focus
            self.originProfileDID = originProfileDID
        }
    }

    struct ReauthenticationRequest: Equatable {
        let id: UUID
        let handle: String
        let did: String
        let authURL: URL

        init(handle: String, did: String, authURL: URL) {
            id = UUID()
            self.handle = handle
            self.did = did
            self.authURL = authURL
        }
    }

    /// Durable, account-scoped result of revoking a lost device. The replacement recovery code is
    /// stored only in this device's Keychain, never in UserDefaults or logs.
    struct PendingMLSDeviceRevocationReceipt: Codable, Equatable, Identifiable, Sendable {
        let accountDidHash: String
        let targetDeviceId: String
        let dsRevoked: Bool
        let groupsUpdated: UInt32
        let labyrinthRotated: Bool
        let newEpochSeq: UInt64?
        let pdsRecordDeleted: Bool
        let replacementRecoveryCode: String?
        let rekeyedPasskeyCount: Int
        let recoveryGeneration: UInt64?
        let recordedAtEpochSeconds: Int64

        var id: String {
            "\(accountDidHash):\(targetDeviceId):\(recordedAtEpochSeconds)"
        }

        func isCurrent(for status: LabyrinthBackupStatus) -> Bool {
            status.recoveryGeneration > 0 && recoveryGeneration == status.recoveryGeneration
                && (replacementRecoveryCode != nil || !status.recoveryNeedsAttention)
        }

        init(
            report: DeviceRevocationReport,
            accountDidHash: String,
            recordedAtEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)
        ) {
            self.accountDidHash = accountDidHash
            self.targetDeviceId = report.targetDeviceId
            self.dsRevoked = report.dsRevoked
            self.groupsUpdated = report.groupsUpdated
            self.labyrinthRotated = report.labyrinthRotated
            self.newEpochSeq = report.newEpochSeq
            self.pdsRecordDeleted = report.pdsRecordDeleted
            self.replacementRecoveryCode = report.rekeyedRecoveryCode
            self.rekeyedPasskeyCount = report.rekeyedPasskeyIds.count
            self.recoveryGeneration = report.recoveryGeneration
            self.recordedAtEpochSeconds = recordedAtEpochSeconds
        }
    }

    /// A newly minted recovery code that still needs an explicit "saved" acknowledgement. The app
    /// treats recovery as not ready until its device-only Keychain receipt is acknowledged.
    struct PendingMLSRecoveryCodeReceipt: Codable, Equatable, Identifiable, Sendable {
        let accountDidHash: String
        let recoveryCode: String
        let requiresDeviceSafetyConfirmation: Bool
        let recoveryGeneration: UInt64?
        let recordedAtEpochSeconds: Int64

        var id: String {
            "\(accountDidHash):\(recordedAtEpochSeconds)"
        }

        func isCurrent(for status: LabyrinthBackupStatus) -> Bool {
            status.recoveryGeneration > 0 && recoveryGeneration == status.recoveryGeneration
        }

        init(
            recoveryCode: String,
            accountDidHash: String,
            requiresDeviceSafetyConfirmation: Bool = false,
            recoveryGeneration: UInt64? = nil,
            recordedAtEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)
        ) {
            self.accountDidHash = accountDidHash
            self.recoveryCode = recoveryCode
            self.requiresDeviceSafetyConfirmation = requiresDeviceSafetyConfirmation
            self.recoveryGeneration = recoveryGeneration
            self.recordedAtEpochSeconds = recordedAtEpochSeconds
        }
    }

    /// What a successful label-definitions load covered: the subscribed labelers and the client.
    /// It mirrors the identity `ContentLabelDefinitionLookup` caches by, so an unchanged key needs no load.
    private struct ModerationDefinitionsKey: Equatable {
        let labelerDIDs: [String]
        let client: ObjectIdentifier
    }

    private struct ModerationDefinitionsLoad {
        let id: UUID
        let key: ModerationDefinitionsKey
        let task: Task<Void, Never>
    }

    // MARK: - Core Properties

    /// User DID for this AppState instance (one AppState per account)
    let userDID: String

    /// Authenticated Petrel client (passed from AppStateManager)
    /// Note: This is a var to support E2E re-login with short-lived tokens
    private(set) var client: ATProtoClient

    /// Logger
    @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "AppState")

    /// Graph manager - handles social graph operations
    @ObservationIgnored var graphManager: GraphManager

    /// Resolves blocked-author DIDs to profiles for the blocking UX (Task 4 UI).
    /// Recreated alongside `graphManager` at every point the client is (re)established
    /// so its cache never straddles two different `ATProtoClient` instances or accounts.
    @ObservationIgnored private(set) var blockedAuthorHydrator: BlockedAuthorHydrator?



    /// Account-scoped derived access; raw Apple age bands never live on AppState.
    let ageAccess: PlatformAgeAccess

    @MainActor
    var platformAgeSignal: PlatformAgeSignal { ageAccess.signal }

    /// Regulatory checker for on-device platform regulatory preflight
    @ObservationIgnored let regulatoryChecker: any AgeRegulatoryChecking

    /// Live status manager for authoring and editing stream status
    @ObservationIgnored private(set) var liveStatusManager: LiveStatusManager

    /// Live event service for event feed banners
    @ObservationIgnored private(set) var liveEventService: LiveEventService

    /// NUX announcement presenter
    @ObservationIgnored private(set) var nuxPresenter: NuxAnnouncementPresenter
    /// Shared renderer for inline Bluemoji custom emoji (verify + forge + cache).
    @ObservationIgnored let bluemojiRenderer = BluemojiRenderer()

    /// Moderation policy for this account, rebuilt by `refreshModerationPolicy()` from the account's
    /// server-confirmed preferences and its subscribed labelers' label definitions. It starts fail-closed.
    private(set) var moderationPolicy: ModerationPolicy = .failClosed
    /// Preserves confirmed preference values while a temporary platform ceiling applies.
    @ObservationIgnored private var baseModerationPolicy: ModerationPolicy = .failClosed

    /// Whether adult content may be shown for this account. It is derived from `moderationPolicy`, so it
    /// is never stored, restored or written anywhere else.
    var isAdultContentEnabled: Bool { moderationPolicy.adultContentEnabled }

    /// Chat mode preference, scoped per-account
    var chatMode: String {
        didSet {
            UserDefaults.standard.set(chatMode, forKey: scopedStandardDefaultsKey("chatMode"))
        }
    }

    /// Last successfully loaded label value definitions of this account's subscribed labelers.
    @ObservationIgnored private var moderationDefinitions: ContentLabelDefinitionLookup.Definitions = [:]
    /// Subscribed labeler DIDs the current policy was built for, in subscription order.
    @ObservationIgnored private var moderationLabelerDIDs: [String] = []
    /// The labelers and client the last successful definitions load covered.
    @ObservationIgnored private var loadedModerationDefinitionsKey: ModerationDefinitionsKey?
    @ObservationIgnored private var moderationDefinitionsLoad: ModerationDefinitionsLoad? {
        didSet {
            let isLoading = moderationDefinitionsLoad != nil
            if isLoadingModerationDefinitions != isLoading { isLoadingModerationDefinitions = isLoading }
        }
    }
    /// Whether the subscribed labelers' label definitions are loading. Observed, so a view that must not
    /// show content under a label the policy cannot resolve yet can wait for the load to finish.
    private(set) var isLoadingModerationDefinitions = false
    /// The normalized labeler set the on-disk definitions cache was last consulted or written for.
    @ObservationIgnored private var moderationDefinitionsDiskKey: [String]?


    /// Current user's profile data for optimistic updates.
    /// Observed so the toolbar avatar and other account chrome update when it loads.
    var currentUserProfile: AppBskyActorDefs.ProfileViewBasic?

    // Account switching transition state for smooth UX
    // NOTE: Do NOT use @ObservationIgnored here - SwiftUI must observe this to dismiss the loading overlay
    var isTransitioningAccounts: Bool = false
    @ObservationIgnored var prewarmingFeedData: [AppBskyFeedDefs.FeedViewPost]?

    // MARK: - Component Managers

    /// Central event bus for coordinating state invalidation
    @ObservationIgnored let stateInvalidationBus = StateInvalidationBus()

    // Settings change tracking to prevent loops
    @ObservationIgnored private var lastSettingsHash: Int = 0
    @ObservationIgnored private var settingsUpdateDebounceTimer: Timer?

    /// Post shadow manager for handling interaction state (likes, reposts) - per account
    @ObservationIgnored let postShadowManager: PostShadowManager

    /// Bookmarks manager for handling bookmark operations - per account
    @ObservationIgnored let bookmarksManager: BookmarksManager

    /// Post manager for handling post creation and management
    @ObservationIgnored let postManager: PostManager

    /// Preferences manager for handling user preferences
    @ObservationIgnored let preferencesManager = PreferencesManager()
    private struct PreferencesBootstrapKey: Equatable {
        let userDID: String
        let containerID: ObjectIdentifier
    }
    @ObservationIgnored private var lastPreferencesBootstrapKey: PreferencesBootstrapKey?
    @MainActor @ObservationIgnored lazy var feedLibraryActions = FeedLibraryActions(appState: self)

    /// Feed feedback manager for custom feed interactions
    /// Scoped to this account: suspension for a switch or sign-out discards what it queued.
    @MainActor @ObservationIgnored lazy var feedFeedbackManager = FeedFeedbackManager(
        accountDID: userDID,
        accountServiceWork: accountServiceWork,
        clientProvider: { [weak self] in self?.atProtoClient }
    )

    /// Feed generator info by feed URI, so feeds know at once whether they accept feedback
    @MainActor @ObservationIgnored lazy var feedGeneratorInfoCache = FeedGeneratorInfoCache()

    /// App-specific settings that aren't synced with the server
    @ObservationIgnored let appSettings = AppSettings()

    /// Font manager for handling typography and font settings - observes via fontDidChange
    @ObservationIgnored private let _fontManager = FontManager()

    #if canImport(FoundationModels)
        /// Shared Bluesky intelligence agent storage (lazy)
        @ObservationIgnored private var blueskyAgentStorage: Any?
    #endif

    /// Backing storage for AppModelStore (iOS 26+ only, stored type-erased to avoid
    /// leaking availability requirements into AppState's deployment target surface).
    @ObservationIgnored var _appModelStoreInstance: (any Sendable)?

    /// Theme manager for handling app-wide theme changes - observes via themeDidChange
    @ObservationIgnored private let _themeManager: ThemeManager

    // MARK: - Observable Theme/Font State

    /// Observable theme state that triggers SwiftUI updates
    var themeDidChange: Int = 0

    /// Observable font state that triggers SwiftUI updates
    var fontDidChange: Int = 0

    /// Font settings last pushed through `fontDidChange`. The debounced settings path fires for any
    /// settings edit; bumping the counter when fonts did not change rebuilds every feed controller.
    @ObservationIgnored private var appliedFontSignature: String?

    private var currentFontSignature: String {
        "\(appSettings.fontStyle)|\(appSettings.fontSize)|\(appSettings.lineSpacing)|\(appSettings.letterSpacing)|"
            + "\(appSettings.dynamicTypeEnabled)|\(appSettings.maxDynamicTypeSize)"
    }

    /// Public access to theme manager
    var themeManager: ThemeManager {
        _themeManager
    }

    /// Public access to font manager
    var fontManager: FontManager {
        _fontManager
    }


    /// Pending reauthentication request when account switching fails due to expired tokens
    @ObservationIgnored var pendingReauthenticationRequest: ReauthenticationRequest?

    /// Feed filter settings manager
    @ObservationIgnored let feedFilterSettings: FeedFilterSettings

    /// Notification manager for handling push notifications
    @ObservationIgnored let notificationManager = NotificationManager()

    /// Activity subscription manager for app-level access
    @ObservationIgnored
    private var activitySubscriptionServiceStorage: ActivitySubscriptionService?

    @MainActor
    var activitySubscriptionService: ActivitySubscriptionService {
        if let existing = activitySubscriptionServiceStorage {
            return existing
        }

        let service = ActivitySubscriptionService(
            client: client,
            notificationManager: notificationManager
        )
        activitySubscriptionServiceStorage = service
        return service
    }

    /// Composer draft manager for handling minimized post composer drafts
    @ObservationIgnored var composerDraftManager: ComposerDraftManager

    /// Toast manager for displaying temporary notifications
    @ObservationIgnored let toastManager = ToastManager()

    /// List manager for handling list operations
    @ObservationIgnored var listManager: ListManager

    /// Post hiding manager for hiding/unhiding posts with server sync
    @ObservationIgnored var postHidingManager: PostHidingManager

    /// Observable chat unread count for UI updates (Bluesky DMs)
    var chatUnreadCount: Int = 0

    /// Observable MLS unread count for UI updates (Catbird Groups)
    var mlsUnreadCount: Int = 0

    /// Combined unread count for Messages tab badge (Bluesky DMs + MLS)
    var totalMessagesUnreadCount: Int {
        chatUnreadCount + mlsUnreadCount
    }

    /// Chat manager for handling Bluesky chat operations
    @ObservationIgnored let chatManager: ChatManager

    /// Heartbeat manager for chat push notification liveness
    @ObservationIgnored let chatHeartbeatManager = ChatHeartbeatManager()

    /// Stateless XRPC service-DID router for home `mls-ds` push-gateway registration (`D2`)
    @ObservationIgnored
    private var mlsAPIClientStorage: MLSAPIClient?

    /// Unified Rust-backed MLS coordinator (`Spec §4`, `§6.3`, `I8`, `I9`, `I11`, `I15`)
    private(set) var mlsCoordinator: MLSClientCoordinator?

    /// Account's Spaces eligibility (`I15` Spaces-required gate; Bluesky DMs remain active when unavailable)
    private(set) var spacesEligibility: SpacesEligibilityStatus?

    /// A revocation report that still needs an explicit "saved" acknowledgement.
    /// Loaded from this-device-only Keychain storage on each account launch.
    private(set) var pendingMLSDeviceRevocationReceipt: PendingMLSDeviceRevocationReceipt?

    /// A generated recovery code awaiting explicit confirmation that it was saved.
    /// Loaded from this-device-only Keychain storage on each account launch.
    private(set) var pendingMLSRecoveryCodeReceipt: PendingMLSRecoveryCodeReceipt?

    /// Default home sequencer DID for creating new groups (`D1`)
    var defaultMLSSequencerDID: String {
        CatbirdGatewayConfiguration.current.mlsServiceDID(for: userDID) ?? "did:web:chat.catbird.blue#atproto_mls"
    }

    /// Backing storage for the MLS block coordinator (lazy).
    @ObservationIgnored
    @MainActor private var mlsBlockCoordinatorStorage: MLSBlockCoordinator?

    /// Bridges Bluesky social blocks and MLS group membership.
    @MainActor var mlsBlockCoordinator: MLSBlockCoordinator? {
        if let existing = mlsBlockCoordinatorStorage { return existing }
        guard let coordinator = mlsCoordinator else { return nil }
        let blockCoord = MLSBlockCoordinator(coordinator: coordinator, graphManager: graphManager)
        mlsBlockCoordinatorStorage = blockCoord
        return blockCoord
    }

    /// Task for opening MLSClientCoordinator (prevents concurrent initialization)
    @ObservationIgnored
    private var mlsCoordinatorInitTask: Task<MLSClientCoordinator?, Never>?

    /// Keeps the gateway's answer about this session's OAuth scopes between chat checks.
    @ObservationIgnored
    private let grantedScopeResolver = MLSGrantedScopeResolver()

    /// MLS conversations list for encrypted messaging
    @ObservationIgnored var mlsConversations: [MLSConversationViewModel] = []

    /// Observable counter that triggers SwiftUI updates when MLS conversations change
    var mlsConversationsDidChange: Int = 0

    /// Conversations the last MLS sync could not finish (`MlsError.SyncIncomplete`); every other
    /// conversation in that sync was applied. Only canonical IDs are kept: the native failure text
    /// can carry internal detail and is never presented.
    private(set) var mlsSyncIncompleteConversationIDs: Set<String> = []

    /// Observable counter that triggers active chat views to reload messages from DB.
    var nseStateReloadTrigger: Int = 0

    /// Profile enricher for MLS participants
    @ObservationIgnored
    let mlsProfileEnricher = MLSProfileEnricher()

    /// MLS service state for retry logic and status tracking
    @ObservationIgnored var mlsServiceState = MLSServiceState()

    // MARK: - Backup & Repository

    /// Backup manager for local data backup operations (per-account)
    @ObservationIgnored private var backupManagerStorage: BackupManager?

    /// Repository parsing service for CAR file parsing
    @ObservationIgnored private(set) var repositoryParsingService: RepositoryParsingService?

    /// Accessor for backup manager
    var backupManager: BackupManager? {
        backupManagerStorage
    }

    /// Connectivity belongs to the app, including retained account states.
    @MainActor @ObservationIgnored let networkMonitor = NetworkMonitor.shared

    /// Onboarding manager for tracking user onboarding progress
    @ObservationIgnored let onboardingManager = OnboardingManager()

    // MARK: - Feed State

    /// Cache of prefetched feeds by type
    @ObservationIgnored private let prefetchedFeedCache = PrefetchedFeedCache()
    @MainActor @ObservationIgnored let trendingTopicMediaStore = TrendingTopicMediaStore()

    /// Flag to track if AuthManager initialization is complete
    @ObservationIgnored private var isAuthManagerInitialized = false

    // For task cancellation when needed
    @ObservationIgnored private var backgroundPollingTask: Task<Void, Never>?
    @MainActor @ObservationIgnored private let accountServiceWork = AccountServiceWork()
    @MainActor var isAccountSwitchSuspended: Bool { accountServiceWork.isSuspended }
    @MainActor @ObservationIgnored private var accountRetirementTask: Task<Void, Error>?
    @MainActor @ObservationIgnored private var accountPollerSuspension: AccountServiceDrainReceipt?
    @MainActor @ObservationIgnored private var mlsStartupTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Builds a fresh `BlockedAuthorHydrator` whose fetcher reads `atProtoClient` at call
    /// time (rather than capturing a client value), so it keeps working across token
    /// refreshes. Callers still recreate the hydrator itself (new instance, empty cache)
    /// at every point `graphManager` is recreated, so identity data never leaks across
    /// accounts or straddles two different `ATProtoClient` instances.
    private func makeBlockedAuthorHydrator() -> BlockedAuthorHydrator {
        BlockedAuthorHydrator { [weak self] dids in
            guard let client = self?.atProtoClient else { return [] }
            // Parse each DID independently: one malformed identifier in a batch must
            // not fail the whole chunk and delay the other (valid) DIDs in it. A
            // dropped identifier simply won't come back in `profiles`, and the
            // hydrator's own flush logic marks it unresolvable from that.
            let identifiers = dids.compactMap { try? ATIdentifier(string: $0) }
            guard !identifiers.isEmpty else { return [] }
            let (responseCode, data) = try await client.app.bsky.actor.getProfiles(
                input: AppBskyActorGetProfiles.Parameters(actors: identifiers)
            )
            guard (200 ... 299).contains(responseCode), let data else { return [] }
            return data.profiles
        }
    }


    /// Opens an MLS conversation in the most recently active scene showing this account.
    @MainActor
    @discardableResult
    func navigateToMLSConversation(
        _ conversationID: String,
        preferredSceneID: UUID? = nil
    ) -> SceneRouteCoordinator.DeliveryResult {
        let chatTab = AppNavigationManager.chatTabIndex
        chatMode = "Catbird Groups"
        #if os(iOS)
        let command = SceneRouteCommand.navigate(.mlsConversation(conversationID), tabIndex: chatTab)
        #else
        let command = SceneRouteCommand.showTab(chatTab, resetPath: false)
        #endif
        let accountDID = userDID
        return SceneRouteCoordinator.shared.submit(
            SceneRouteRequest(accountDID: accountDID, command: command, preferredSceneID: preferredSceneID),
            beforeDelivery: { context in
                guard !context.isInvalidated, context.accountDID == accountDID else { return false }
                #if !os(iOS)
                context.navigationManager.targetMLSConversationId = conversationID
                #endif
                return true
            }
        )
    }

    @MainActor
    init(
        userDID: String,
        client: ATProtoClient,
        regulatoryChecker: any AgeRegulatoryChecking = AppleAgeRangeAdapter.shared
    ) {
        self.userDID = userDID
        self.client = client
        self.regulatoryChecker = regulatoryChecker
        self.ageAccess = PlatformAgeAccess(checker: regulatoryChecker)
        self.pendingMLSDeviceRevocationReceipt =
            try? Self.loadPendingMLSDeviceRevocationReceipt(forDID: userDID)
        self.pendingMLSRecoveryCodeReceipt =
            try? Self.loadPendingMLSRecoveryCodeReceipt(forDID: userDID)
        logger.info("AppState initializing for account: \(userDID)")
        appSettings.configure(accountDID: userDID)

        let chatModeKey = AppSettingsModel.scopedKey("chatMode", accountDID: userDID)
        if let storedChatMode = UserDefaults.standard.string(forKey: chatModeKey) {
            chatMode = storedChatMode
        } else if let legacyChatMode = UserDefaults.standard.string(forKey: "chatMode") {
            chatMode = legacyChatMode
            UserDefaults.standard.set(legacyChatMode, forKey: chatModeKey)
        } else {
            chatMode = "Bluesky DMs"
        }

        liveStatusManager = LiveStatusManager(appState: nil)
        liveEventService = LiveEventService(appState: nil)
        nuxPresenter = NuxAnnouncementPresenter(appState: nil)

        // Create per-account manager instances
        feedFilterSettings = FeedFilterSettings(accountDID: userDID)
        postShadowManager = PostShadowManager()
        bookmarksManager = BookmarksManager()

        // Initialize composer draft manager
        composerDraftManager = ComposerDraftManager(appState: nil)

        // Initialize theme manager with font manager dependency
        _themeManager = ThemeManager(fontManager: _fontManager)

        // Initialize post manager with authenticated client
        postManager = PostManager(client: client, appState: nil)

        // Initialize graph manager with authenticated client
        graphManager = GraphManager(atProtoClient: client)

        // Initialize list manager with authenticated client
        listManager = ListManager(client: client, appState: nil)

        // Initialize post hiding manager (connected to preferences after initialization)
        postHidingManager = PostHidingManager()

        // Initialize chat manager with authenticated client
        chatManager = ChatManager(client: client, appState: nil)


        onboardingManager.configure(accountDID: userDID)
        liveStatusManager.configure(with: self)
        liveEventService.configure(with: self)
        nuxPresenter.configure(with: self)

        // Configure notification manager with app state reference (skip for FaultOrdering)
        notificationManager.configure(with: self)

        // Initialize blocked-author identity hydrator now that `self` is fully
        // initialized (its fetcher closure captures `self` weakly).
        blockedAuthorHydrator = makeBlockedAuthorHydrator()

        // Set up circular references after initialization
        postManager.updateAppState(self)
        composerDraftManager.updateAppState(self)
        chatManager.updateAppState(self)

        // Settings requests and post-save effects belong to the actual source-account drain.
        preferencesManager.beginSettingsAccountOperation = { [weak self] in
            self?.accountServiceWork.beginOperation()
        }
        preferencesManager.endSettingsAccountOperation = { [weak self] token in
            self?.accountServiceWork.endOperation(token)
        }
        // Trend lists are cached and stored under this account, so none is requested or stored while a
        // switch has it suspended: the shared client may already hold the next account's credentials.
        trendingTopicMediaStore.lists.admitsRequests = { [weak self] in
            self?.isAccountSwitchSuspended == false
        }
        postHidingManager.updatePreferencesManager(preferencesManager, accountDID: userDID)
        appSettings.persistence.startEffect = { [weak self] action in
            guard let self else { return false }
            return self.accountServiceWork.start(operation: action) != nil
        }

        // The moderation policy follows this account's stored preferences: every successful fetch and
        // confirmed write rebuilds it. Until preferences are readable it is this account's fail-closed policy.
        preferencesManager.storedPreferencesDidChange = { [weak self] accountDID in
            guard let self, accountDID == self.userDID else { return }
            self.refreshModerationPolicy()
        }
        ageAccess.decisionDidChange = { [weak self] in
            guard let self else { return }
            self.applyModerationPolicy(self.baseModerationPolicy)
            NotificationCenter.default.post(
                name: .platformAgeAccessDidChange, object: nil,
                userInfo: ["accountDID": self.userDID])
        }
        refreshModerationPolicy()

        // Apply initial theme settings immediately from UserDefaults
        appSettings.applyInitialThemeSettings(to: _themeManager)

        // Apply initial font settings immediately from UserDefaults
        appSettings.applyInitialFontSettings(to: _fontManager)

        // Set up theme/font change observation on main actor
        Task { @MainActor in
            setupThemeAndFontObservation()
        }

        // Export observers must exist before the first derived-access invalidation.
        _ = FeedWidgetDataProvider.shared
        if #available(iOS 18.0, macOS 15.0, *) {
            _ = SpotlightEntityDonator.shared
        }
        // This passive task is owned and fenced by the account's age-access coordinator.
        // A visible scene supplies a presenter only after an affirmative requirement.
        ageAccess.startPreflight()
        // NOTE: Settings observation is set up later in initializePreferencesManager
        // to avoid duplicate observers

        logger.debug("AppState initialization complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        backgroundPollingTask?.cancel()
    }

    /// Pause account-bound work before the shared client changes its credentials.
    /// No service, editing session, cached model, or database is retired here.
    @MainActor
    func suspendForAccountSwitch() async throws {
        guard appSettings.suspendLocalChanges(for: userDID) else {
            throw AccountServiceWork.BarrierError.accountChanged
        }
        accountServiceWork.suspend()
        ageAccess.suspend()
        feedFeedbackManager.discardPending()
        trendingTopicMediaStore.invalidateForSuspension()
        settingsUpdateDebounceTimer?.invalidate()
        settingsUpdateDebounceTimer = nil
        backgroundPollingTask?.cancel()
        backgroundPollingTask = nil
        // The definitions load holds the settings account-I/O lease the drain below waits for. Cancel it
        // before draining so its request aborts instead of running to the drain deadline.
        moderationDefinitionsLoad?.task.cancel()
        moderationDefinitionsLoad = nil
        #if os(iOS)
        // MLS writers stop and the MLS context closes before the drain, so the database
        // close that follows a switch never races an in-flight MLS operation.
        stopMLSStreams()
        let mlsShutdownCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.prepareMLSStorageReset()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !mlsShutdownCompleted {
            logger.critical("🚨 MLS shutdown timed out while suspending account services")
        }
        #endif
        try await suspendAccountPollers()
        try await accountServiceWork.drain()
        guard appSettings.flushPendingChangesForAccountSwitch(for: userDID) else {
            throw SettingsAccountSwitchError.localSaveRefused(
                appSettings.accountSwitchFlushFailure?.localizedDescription
                    ?? "Your Settings changes could not be saved. Retry or discard them in Settings before switching accounts."
            )
        }
    }

    @MainActor
    private func suspendAccountPollers() async throws {
        let receipt: AccountServiceDrainReceipt
        if let pending = accountPollerSuspension, !pending.isComplete {
            receipt = pending
        } else {
            let notifications = notificationManager
            let chat = chatManager
            receipt = AccountServiceDrainReceipt {
                async let notificationDrain: Void = notifications.suspendForAccountSwitch()
                async let chatDrain: Void = chat.suspendForAccountSwitch()
                _ = await (notificationDrain, chatDrain)
            }
            accountPollerSuspension = receipt
        }
        try await receipt.wait()
    }

    /// Reopen only the same retained account after authentication has been restored.
    /// A failed proof or partial service resume leaves admission closed.
    @MainActor
    func resumeAfterInterruptedAccountSwitch(using expectedClient: ATProtoClient? = nil) async throws {
        guard accountRetirementTask == nil else { throw AccountServiceWork.BarrierError.retirementFailed }
        // Authentication switches credentials on the shared client in place. Keep
        // the suspended service graph intact; updateClient would discard it.
        let originalClient = client
        if let expectedClient, originalClient !== expectedClient {
            throw AccountServiceWork.BarrierError.accountChanged
        }
        guard accountServiceWork.isSuspended else { return }
        try await accountPollerSuspension?.wait()
        try await accountServiceWork.drain()
        let authenticatedDID = try await originalClient.getDid()
        guard authenticatedDID == userDID, client === originalClient else {
            throw AccountServiceWork.BarrierError.accountChanged
        }
        do {
            guard await notificationManager.resumeAfterInterruptedAccountSwitch(accountDID: userDID),
                  await chatManager.resumeAfterInterruptedAccountSwitch(accountDID: userDID),
                  client === originalClient,
                  try await originalClient.getDid() == userDID else {
                throw AccountServiceWork.BarrierError.serviceResumeFailed
            }
            guard appSettings.resumeLocalChanges(for: userDID) else {
                throw AccountServiceWork.BarrierError.accountChanged
            }
        } catch {
            try? await suspendAccountPollers()
            throw error
        }
        accountPollerSuspension = nil
        accountServiceWork.resume()
        ageAccess.startPreflight()
        startBackgroundPolling()
        // The drain above finished every admitted task, including a startup cancelled before it ran.
        mlsStartupTask = nil
        startMLSIfEnabled()
    }

    /// Whether MLS / Spaces runtime work is permitted for this account: encrypted chat is on
    /// unless the user turned it off, and nothing runs (no database, enrollment or network)
    /// until the account has acknowledged the one-time introduction.
    @MainActor
    var isMLSRuntimeAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--e2e-mode")
            || CatbirdGatewayConfiguration.current.isRuntimeFixture
        {
            return true
        }
        #endif
        return ExperimentalSettings.shared.isMLSRuntimeAllowed(for: userDID)
    }

    /// The user continued past the encrypted chat introduction or turned encrypted chat on.
    /// A failure leaves the preference on; it never records an opt-out.
    @MainActor
    func optInToMLSChat() async throws {
        ExperimentalSettings.shared.enableMLSChat(for: userDID)
        try await initializeMLS()
        await notificationManager.syncMLSPushGatewayRegistration()
    }

    /// Turns encrypted chat off only after its server-side push binding is confirmed disabled.
    /// A failure leaves both the preference and local MLS identity intact so the operation can retry.
    @MainActor
    func optOutOfMLSChat() async throws {
        let accountDID = userDID
        try await MLSUserOptOutSequence(
            unregisterPushGateway: { [self] in
                try await notificationManager.unregisterMLSPushGatewayForUserOptOut(
                    accountDID: accountDID
                )
            },
            persistUserDisabled: {
                ExperimentalSettings.shared.disableMLSChat(for: accountDID)
            },
            resetLocalMLSState: { [self] in
                guard userDID == accountDID else { return }
                await prepareMLSStorageReset()
                await loadMLSConversations()
            }
        ).run()
    }

    /// MLS starts only while this account admits work, so suspension cancels and drains it.
    @MainActor
    private func startMLSIfEnabled() {
        guard mlsStartupTask == nil else { return }
        guard isMLSRuntimeAllowed else { return }
        mlsStartupTask = accountServiceWork.start(priority: .utility) { [self] in
            defer { mlsStartupTask = nil }
            do {
                try await initializeMLS()
            } catch {
                logger.error("MLS init failed from AppState startup: \(error.localizedDescription)")
            }
        }
    }

    /// Successful switches permanently retire this container; rollback must use
    /// resumeAfterInterruptedAccountSwitch before this point instead.
    @MainActor
    func retireAfterAccountSwitch() async throws {
        if let retirement = accountRetirementTask {
            try await retirement.value
            return
        }
        let retirement = Task { @MainActor [self] in
            try await suspendForAccountSwitch()
            ageAccess.suspend()
        }
        accountRetirementTask = retirement
        try await retirement.value
    }

    /// Start a task only while this account admits work; suspension cancels and drains it.
    @MainActor
    @discardableResult
    func startAccountTask(
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        accountServiceWork.start(priority: priority, operation: operation)
    }

    /// Direct preview reads finish before the shared client's account credentials may change.
    @MainActor
    func withTopicPreviewAccountOperation(_ operation: @MainActor () async -> Void) async {
        guard let lease = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(lease) }
        await operation()
    }

    /// Settings I/O is registered until its actual body ends, including cancellation.
    @MainActor
    func performSettingsAccountOperation<Value>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard AppStateManager.shared.lifecycle.appState === self,
              let token = accountServiceWork.beginOperation() else {
            throw AccountServiceWork.BarrierError.accountChanged
        }
        defer { accountServiceWork.endOperation(token) }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Cleanup method called when this AppState is evicted from cache
    @MainActor
    func cleanup() {
        logger.info("🧹 Cleaning up AppState for user: \(self.userDID)")
        _ = appSettings.suspendLocalChanges(for: userDID)
        accountServiceWork.suspend()
        ageAccess.suspend()
        feedFeedbackManager.discardPending()
        trendingTopicMediaStore.invalidateForSuspension()
        settingsUpdateDebounceTimer?.invalidate()
        settingsUpdateDebounceTimer = nil

        // Cancel long-running tasks
        backgroundPollingTask?.cancel()
        backgroundPollingTask = nil
        moderationDefinitionsLoad?.task.cancel()
        moderationDefinitionsLoad = nil

        // Stop the list poller AND every per-conversation message poller; a
        // surviving message poll loop retains self and keeps polling with the
        // evicted account's stale client.
        chatManager.stopAllPolling()

        mlsCoordinatorInitTask?.cancel()
        mlsCoordinatorInitTask = nil

        let coordinator = mlsCoordinator
        mlsCoordinator = nil
        mlsBlockCoordinatorStorage = nil
        mlsAPIClientStorage = nil
        _circleNotificationsModel = nil
        _circleNotificationService = nil
        _circleService = nil
        circleEncryptionCache.reset()
        circleOpenerCache.reset()
        circleCapabilityProbeID = nil
        circleCapabilityProbeState = .notStarted
        circleCapability = .unknown

        Task {
            await coordinator?.close()
        }

        logger.info("🧹 MLS cleanup initiated for user: \(self.userDID)")
    }

    // MARK: - Data Services Configuration

    /// Configure backup and repository parsing services.
    func configureDataServices(modelContainer: ModelContainer) {
        guard backupManagerStorage == nil else { return }

        let parsingService = RepositoryParsingService()
        parsingService.configure(with: ModelContext(modelContainer))
        repositoryParsingService = parsingService

        let mgr = BackupManager(
            userDID: userDID,
            client: client,
            modelContainer: modelContainer
        )
        mgr.setRepositoryParsingService(parsingService)
        backupManagerStorage = mgr

        logger.info("Backup and repository parsing services configured")
    }

    // MARK: - Background Polling

    @MainActor
    private func startBackgroundPolling() {
        guard !accountServiceWork.isSuspended, backgroundPollingTask == nil else { return }
        backgroundPollingTask = accountServiceWork.start(priority: .background) { [self] in
            while !Task.isCancelled {
                // Prune old feed models
                FeedModelContainer.shared.pruneOldModels(olderThan: 1800)

                // Wait before next check (no forced 5-min preferences poll; refreshed on foreground when stale)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Refreshes server preferences on foreground or demand when stale (15 min window)
    @MainActor
    func refreshPreferencesIfStale(staleThreshold: TimeInterval = 900) async {
        guard await isAuthenticated else { return }
        do {
            try await preferencesManager.refreshIfStale(staleThreshold: staleThreshold)
            self.nuxPresenter.evaluateAndPresentIfNeeded(
                isWelcomeShowing: self.onboardingManager.showWelcomeSheet
            )
        } catch {
            logger.debug("Stale preferences refresh skipped or failed: \(error.localizedDescription)")
        }
    }

    // MARK: - App Initialization

    @MainActor
    func initialize() async {
        logger.info("🚀 Starting AppState.initialize() for user: \(self.userDID)")

        // Normal initialization path
        // Configure Nuke image pipeline with GIF support
        configureImagePipeline()


        // NOTE: Auth initialization removed - client is already authenticated and passed in init
        // All managers were initialized with the client in init

        // MLS database setup is now lazy - it will be initialized when user first accesses MLS chat
        // This saves ~50-100ms on app startup for users who don't use encrypted messaging
        logger.info("🔐 MLS database will be initialized lazily when first accessed")

        // Update manager client references (should already be set from init, but ensure consistency)
        logger.info("Updating manager clients for authenticated user")

        postManager.updateClient(client)
        preferencesManager.updateClient(client)
        // Seed accept-labelers from the stored confirmed preferences before any feed request.
        // No-op until `initializePreferencesManager` has configured the account's row.
        await preferencesManager.applyAcceptLabelersHeaderFromConfirmedPreferences()
        // P128: notification-client setup moved off launch critical path
        accountServiceWork.start { [self] in
            await notificationManager.updateClient(client)
        }
        graphManager = GraphManager(atProtoClient: client)
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(client)
        listManager.updateAppState(self)

        chatManager.updateAppState(self)
        await chatManager.updateClient(client)
        updateChatUnreadCount()

        accountServiceWork.start { [self] in
            await probeCircleCapabilities()
            startMLSIfEnabled()
        }

        // Setup other components as needed (skip for FaultOrdering)
        startBackgroundPolling()
        setupNotifications()
        setupChatObservers()
        startMLSIfEnabled()

        // Apply current theme settings (this will now use SwiftData if available, UserDefaults fallback otherwise)
        _themeManager.applyTheme(
            theme: appSettings.theme,
            darkThemeMode: appSettings.darkThemeMode,
            forceImmediateNavigationTypography: true
        )

        logger.info(
            "Theme applied on startup: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode)"
        )

        if isAuthenticated {
            accountServiceWork.start { [self] in
                // Load current user profile for optimistic updates, concurrently with the preferences
                // fetch: the feed's moderation policy and accept-labelers header wait on preferences.
                async let profileLoad: Void = self.loadCurrentUserProfile(did: userDID)

                // Synchronize server preferences with app settings
                do {
                    try await preferencesManager.fetchPreferences(forceRefresh: true, sharingQueuedRead: true)
                    await postHidingManager.loadFromPreferences()
                    try await preferencesManager.syncPreferencesWithAppSettings(self)
                    logger.info("Successfully synchronized server preferences with app settings")
                } catch {
                    logger.error("Failed to synchronize preferences: \(error.localizedDescription)")
                }

                await profileLoad
                await AppStateManager.shared.authentication.refreshAvailableAccounts()

                await self.activitySubscriptionService.refreshSubscriptions()
                self.nuxPresenter.evaluateAndPresentIfNeeded(
                    isWelcomeShowing: self.onboardingManager.showWelcomeSheet
                )
            }
        }
        // Connect VideoCoordinator to app settings for real-time autoplay updates
        VideoCoordinator.shared.appSettings = appSettings

        logger.info("🏁 AppState.initialize() completed")
    }

    // REMOVED: switchToAccount(did:) method
    // AppState represents a SINGLE account (userDID is immutable).
    // Account switching is handled by AppStateManager, which creates/retrieves different AppState instances.
    // See AppStateManager.switchAccount(to:withDraft:) for proper account switching.

    @MainActor
    func refreshAfterAccountSwitch() async {
        logger.info("Refreshing data after account switch")
        // Before any network work, the policy becomes this account's own confirmed state (or fail-closed).
        refreshModerationPolicy()
        isTransitioningAccounts = true
        _circleNotificationsModel = nil
        _circleNotificationService = nil
        _circleService = nil
        circleEncryptionCache.reset()
        circleOpenerCache.reset()
        circleCapabilityProbeID = nil
        circleCapabilityProbeState = .notStarted
        circleCapability = .unknown
        #if DEBUG
        if let transport = e2eCircleTransport { installE2ECircleFixture(transport: transport) }
        #endif

        accountServiceWork.start { [self] in
            await probeCircleCapabilities()
            startMLSIfEnabled()
        }
        ageAccess.startPreflight()
        // Clear old prefetched data and any shadowed interactions
        await prefetchedFeedCache.clear()
        await postShadowManager.clearAll()

        postManager.updateClient(client)
        preferencesManager.updateClient(client)
        // The shared client still carries the previous account's labelers; seed this account's
        // confirmed ones before the feed load below.
        await preferencesManager.applyAcceptLabelersHeaderFromConfirmedPreferences()
        // P128: notification-client setup moved off account-switch critical path
        accountServiceWork.start { [self] in
            await notificationManager.updateClient(client)
        }

        chatManager.updateAppState(self)
        await chatManager.updateClient(client)
        await chatManager.loadConversations(refresh: true)
        updateChatUnreadCount()

        graphManager = GraphManager(atProtoClient: client)
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(client)
        listManager.updateAppState(self)

        // Run the heavyweight refresh in the background to keep the UI responsive
        accountServiceWork.start(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPostSwitchRefreshWork()
        }

        isTransitioningAccounts = false
    }

    @MainActor
    private func runPostSwitchRefreshWork() async {
        guard let operation = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(operation) }
        async let preferencesTask: Void = refreshPreferencesAfterAccountSwitch()
        async let profileTask: Void = loadCurrentUserProfile(did: userDID)

        // Pre-warm following feed without blocking the main transition
        accountServiceWork.start(priority: .userInitiated) { [weak self] in
            await self?.prewarmFollowingFeed()
        }

        // Trigger explicit feed data load for all active feeds
        // This ensures that even if we preserved cache, we check for new content
        // and that the UI has data to show if the cache was empty.
        accountServiceWork.start(priority: .userInitiated) {
            await FeedStateStore.shared.triggerPostAuthenticationFeedLoad()
        }

        await reinitializeMLSAfterSwitch()
        await preferencesTask
        await profileTask
    }

    @MainActor
    private func refreshPreferencesAfterAccountSwitch() async {
        guard let operation = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(operation) }
        do {
            try await preferencesManager.fetchPreferences(forceRefresh: true, sharingQueuedRead: true)
            await postHidingManager.loadFromPreferences()
            logger.info("Successfully refreshed preferences after account switch")

            try await preferencesManager.syncPreferencesWithAppSettings(self)
            logger.info("Successfully synchronized preferences with app settings after account switch")

            await activitySubscriptionService.refreshSubscriptions()
            nuxPresenter.evaluateAndPresentIfNeeded(
                isWelcomeShowing: onboardingManager.showWelcomeSheet
            )
        } catch {
            logger.error("Failed to refresh preferences after account switch: \(error)")
        }
    }

    @MainActor
    private func reinitializeMLSAfterSwitch() async {
        logger.info("MLS: Beginning clean-slate coordinator reset for account switch")
        await prepareMLSStorageReset()
        mlsAPIClientStorage = nil

        guard isMLSRuntimeAllowed else {
            mlsConversations = []
            mlsConversationsDidChange += 1
            updateMLSUnreadCount()
            return
        }

        do {
            try await initializeMLS()
            logger.info("✅ MLS: Initialized coordinator after account switch")
        } catch {
            logger.error("⚠️ MLS: Coordinator initialization after switch failed: \(error.localizedDescription)")
        }
    }

    /// Pre-warms the Following feed for the new account to enable smooth crossfade
    @MainActor
    private func prewarmFollowingFeed() async {
        guard let operation = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(operation) }
        // Use this AppState's authenticated client
        let client = self.client

        do {
            logger.info("Pre-warming following feed for smooth account transition")

            // Fetch initial posts for the following feed
            // Use 50 posts to match normal fetch behavior and account for filtering
            let (response, output) = try await client.app.bsky.feed.getTimeline(
                input: .init(limit: 50) // Increased from 15 to account for aggressive filtering
            )
            if response != 200 {
                logger.error("Failed to pre-warm feed: HTTP \(response)")
                prewarmingFeedData = nil
                return
            }

            guard let output = output else {
                logger.error("Failed to pre-warm feed: No output data")
                prewarmingFeedData = nil
                return
            }
            guard accountServiceWork.isCurrent(operation) else { return }
            // Store for potential crossfade transition
            prewarmingFeedData = output.feed

            logger.info("Pre-warmed \(output.feed.count) posts for feed transition")
        } catch {
            logger.error("Failed to pre-warm feed: \(error.localizedDescription)")
            prewarmingFeedData = nil
        }
    }

    // MARK: - OAuth Callback Handling

    /// Handles OAuth callback URLs - delegates to AppStateManager's auth manager
    @MainActor
    func handleOAuthCallback(_ url: URL) async throws {
        logger.info("AppState handling OAuth callback")
        try await AppStateManager.shared.authentication.handleGatewayCallback(url)
    }

    /// Force updates the authentication state (used in rare cases where state updates aren't properly propagated)
    @MainActor
    func forceUpdateAuthState(_ isAuthenticated: Bool) {
        logger.warning("Force updating auth state to: \(isAuthenticated)")
        // This is a safety mechanism, prefer not to use it
    }

    // MARK: - Feed Methods

    /// Stores a prefetched feed for faster initial loading
    func storePrefetchedFeed(
        _ posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, for fetchType: FetchType
    ) async {
        await prefetchedFeedCache.set(posts, cursor: cursor, for: fetchType)
    }

    /// Gets a prefetched feed if available
    func getPrefetchedFeed(_ fetchType: FetchType) async -> (
        posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?
    )? {
        return await prefetchedFeedCache.get(for: fetchType)
    }

    // MARK: - Convenience Accessors

    /// Access to the AT Protocol client (returns this AppState's authenticated client)
    var atProtoClient: ATProtoClient? {
        client
    }

    /// Availability belongs to this account and its authenticated client, never the process.
    var circleCapability: CircleCapabilityState = .unknown {
        didSet { if circleCapability != .supported { circleSupportsImages = false } }
    }
    private(set) var circleSupportsImages = false
    var circlesEnabled: Bool { circleCapability == .supported }
    /// Whether this account's capability probe has run. Surfaces waiting on an unknown
    /// capability stop waiting once a probe finishes without an answer.
    private(set) var circleCapabilityProbeState: CircleCapabilityProbeState = .notStarted
    @ObservationIgnored private var circleCapabilityProbeID: UUID?
    @ObservationIgnored private var circleCapabilityPDSURL: URL?

    @ObservationIgnored private var _circleService: CircleService?

    /// Circle service using the current authenticated client
    var circleService: CircleService {
        get {
            if let _circleService {
                return _circleService
            }
            let service = CircleService(
                transport: GatewayCircleTransport(client: client),
                encryption: { [weak self] in await self?.circleEncryptionContext() }
            )
            _circleService = service
            return service
        }
        set {
            _circleService = newValue
        }
    }

    /// I5: one context (so one `CircleKeyManager` and one `CircleKeyStore`)
    /// per live coordinator, held weakly and matched by identity.
    @ObservationIgnored private let circleEncryptionCache = CircleCoordinatorCache<CircleEncryptionContext>()

    /// This account's encrypted-Circle machinery (one `CircleKeyManager`, so its
    /// queue serializes every key operation), created once the MLS client is
    /// up. Nil until then: posting to an encrypted Circle fails closed with
    /// `CircleError.encryptionUnavailable`. Reset with `_circleService`.
    @MainActor
    func circleEncryptionContext() -> CircleEncryptionContext? {
        guard let coordinator = mlsCoordinator, !coordinator.isHandleClosed,
              let accountDID = try? DID(didString: userDID)
        else { return nil }
        if let cached = circleEncryptionCache.cached(for: coordinator) {
            return cached
        }
        let crypto = coordinator.circleCrypto()
        let manager = CircleKeyManager(
            crypto: crypto,
            // I5: the account's one store, shared with every manager made for
            // this DID (including one a closed coordinator still holds).
            store: CircleKeyStoreRegistry.shared.store(accountDID: userDID) { SystemCircleKeychain() },
            transport: GatewayCircleTransport(client: client),
            ownerDID: accountDID,
            ownerStateSync: CoordinatorCircleOwnerStateSync(coordinator: coordinator)
        )
        let context = CircleEncryptionContext(
            keyManager: manager,
            crypto: crypto,
            accountDID: accountDID,
            mailboxEnrolled: { [weak coordinator] in
                // I9: a failed or impossible check throws (→ `.checkFailed`,
                // Create stops); only a successful read can say "not enrolled".
                guard let coordinator else { throw CircleError.clientNotInitialized }
                let status = try await coordinator.labyrinthStatus()
                return !status.mailboxSpaceUri.isEmpty
            }
        )
        return circleEncryptionCache.value(for: coordinator) { context }
    }

    @ObservationIgnored private let circleOpenerCache = CircleCoordinatorCache<CirclePostOpener>()

    /// This account's encrypted-Circle post opener, shared by Circle feeds and
    /// threads so its concurrency bound (2 opens) and memo are per account.
    /// Nil until the MLS client is up (encrypted posts then show as
    /// unreadable). Reset with `_circleService`.
    @MainActor
    func circlePostOpener() -> CirclePostOpener? {
#if DEBUG
        if let e2eCircleOpener { return e2eCircleOpener }
#endif
        guard let context = circleEncryptionContext(), let coordinator = mlsCoordinator else { return nil }
        let client = self.client
        let accountDID = userDID
        return circleOpenerCache.value(for: coordinator) {
            CirclePostOpener(
                crypto: context.crypto,
                keys: context.keyManager,
                epochs: RepoAuthorEpochResolver.live(client: client),
                accountDID: accountDID
            )
        }
    }

    /// Resolves a DID's handle (the Circle owner on a "waiting for access" row).
    var circleOwnerHandleResolver: @Sendable (DID) async -> String? {
        let client = self.client
        return { did in
            guard let actor = try? ATIdentifier(string: did.didString()),
                  let (code, profile) = try? await client.app.bsky.actor.getProfile(
                    input: AppBskyActorGetProfile.Parameters(actor: actor)
                  ),
                  code == 200, let profile
            else { return nil }
            return profile.handle.description
        }
    }

    @ObservationIgnored private var _circleNotificationService: (any CircleNotificationServiceProtocol)?

    /// Circle notification service using the current authenticated Circle service
    var circleNotificationService: any CircleNotificationServiceProtocol {
        get {
            if let _circleNotificationService {
                return _circleNotificationService
            }
            return CircleNotificationService(service: circleService)
        }
        set {
            _circleNotificationService = newValue
        }
    }

    @ObservationIgnored private var _circleNotificationsModel: CircleNotificationsModel?

    /// Model owning private Circle notifications for this active account
    @MainActor
    var circleNotificationsModel: CircleNotificationsModel {
        get {
            if let model = _circleNotificationsModel {
                return model
            }
            let model = CircleNotificationsModel(
                service: circleNotificationService,
                accountDID: userDID,
                activeDIDProvider: { AppStateManager.shared.lifecycle.userDID }
            )
            _circleNotificationsModel = model
            return model
        }
        set {
            _circleNotificationsModel = newValue
        }
    }

#if DEBUG
    @ObservationIgnored var e2eCircleTransport: E2ECircleTransport?
    /// `--e2e-encrypted-circles`: the fixture's opener over fake crypto.
    @ObservationIgnored var e2eCircleOpener: CirclePostOpener?

    @MainActor
    func installE2ECircleFixture(transport: E2ECircleTransport) {
        self.circleCapability = ProcessInfo.processInfo.arguments.contains("--circles-unsupported-pds") ? .unsupported : .supported
        self.circleSupportsImages = self.circleCapability == .supported && !ProcessInfo.processInfo.arguments.contains("--circles-images-unavailable")
        self.e2eCircleTransport = transport
        let service: CircleService
        if E2EEncryptedCircleFixture.isEnabled, let accountDID = try? DID(didString: userDID) {
            let machinery = E2EEncryptedCircleFixture.make(accountDID: accountDID, transport: transport)
            service = machinery.service
            self.e2eCircleOpener = machinery.opener
        } else {
            service = CircleService(transport: transport)
        }
        self.circleService = service
        self.circleNotificationsModel = CircleNotificationsModel(
            service: CircleNotificationService(service: service),
            accountDID: userDID,
            activeDIDProvider: { AppStateManager.shared.lifecycle.userDID }
        )
    }
#endif

    /// Require both the active PDS Spaces API and the shared Circle service.
    /// Unknown errors hide entry points without classifying the PDS as unsupported.
    @MainActor
    func probeCircleCapabilities() async {
        guard AppStateManager.shared.lifecycle.appState === self else { return }
        let probeID = UUID()
        circleCapabilityProbeID = probeID
        circleCapabilityProbeState = .running
        defer {
            // A probe replaced by a newer one, or by an account change, leaves the state to that.
            if circleCapabilityProbeID == probeID { circleCapabilityProbeState = .finished }
        }
        let probeClient = client
        let account = await probeClient.getActiveAccountInfo()
        guard AppStateManager.shared.lifecycle.appState === self, client === probeClient,
              circleCapabilityProbeID == probeID else { return }
        if let accountDID = account.did, accountDID != userDID {
            circleCapability = .unknown
            return
        }
        if circleCapabilityPDSURL != account.pdsURL {
            circleCapability = .unknown
        }
        await client.setServiceDID(
            CircleConfiguration.serviceDID, for: CircleConfiguration.serviceNSIDPrefix
        )
        let result: CircleCapabilityState
        var supportsImages = false
        do {
            let caps = try await circleService.capabilities()
            result = caps.isCompatible ? .supported : .unsupported
            supportsImages = caps.isCompatible && caps.supportsImages
        } catch {
            let circleError = error as? CircleError
            result = (circleError == .unsupportedPDS || circleError == .protocolRevisionMismatch) ? .unsupported : .unknown
            logger.debug("Circle capability probe did not establish support: \(error.localizedDescription)")
        }
        let currentAccount = await probeClient.getActiveAccountInfo()
        guard !Task.isCancelled, client === probeClient,
              circleCapabilityProbeID == probeID,
              AppStateManager.shared.lifecycle.appState === self else { return }
        guard account.did == currentAccount.did, account.pdsURL == currentAccount.pdsURL else {
            circleCapability = .unknown
            return
        }
        circleCapabilityPDSURL = currentAccount.pdsURL
        circleCapability = result
        circleSupportsImages = supportsImages
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, macOS 26.0, *)
        var blueskyAgent: BlueskyIntelligenceAgent {
            if let blueskyAgentStorage = blueskyAgentStorage as? BlueskyIntelligenceAgent {
                return blueskyAgentStorage
            }

            let agent = BlueskyIntelligenceAgent(client: client)
            blueskyAgentStorage = agent
            return agent
        }
    #endif

    /// Update post manager when client changes
    private func updatePostManagerClient() {
        postManager.updateClient(client)
    }

    /// Check if user is authenticated
    /// NOTE: In new architecture, AppState only exists for authenticated users
    var isAuthenticated: Bool {
        true // AppState is only created for authenticated accounts
    }

    /// Current auth state
    /// NOTE: This property is deprecated in new architecture - access auth via AppStateManager
    var authState: AuthState {
        .authenticated(userDID: userDID) // AppState is always authenticated
    }

    /// The shared Nuke image pipeline
    var imagePipeline: ImagePipeline {
        ImagePipeline.shared
    }

    /// Get or create MLS API client lazily (only when MLS chat is actually accessed)
    @MainActor
    func getMLSAPIClient() async -> MLSAPIClient? {
        // Use this AppState's authenticated client
        let client = self.client

        if let existing = mlsAPIClientStorage {
            logger.debug("MLS: Reusing existing API client")
            return existing
        }

        let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID(for: userDID)
        logger.info("MLS: Creating new API client for configured environment (lazy initialization)")
        // Create MLS client off main actor to avoid blocking UI
        let mlsClient = await Task.detached(priority: .userInitiated) {
            let environment: MLSEnvironment = if let mlsServiceDID {
                .custom(serviceDID: mlsServiceDID)
            } else {
                .production
            }
            return await MLSAPIClient(
                client: client,
                environment: environment
            )
        }.value
        mlsAPIClientStorage = mlsClient
        logger.info("MLS: API client created successfully")
        return mlsClient
    }

    /// UserDefaults key storing the per-account installation `deviceId` UUIDv4.
    nonisolated static func mlsDeviceIDDefaultsKey(for accountDid: String) -> String {
        let normalized = accountDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "blue.catbird.mls.deviceId.\(normalized)"
    }

    /// Resolves or creates a canonical lowercase UUIDv4 `deviceId` for `accountDid` inside `defaults`.
    nonisolated static func resolveOrCreateMLSDeviceID(
        for accountDid: String,
        in defaults: UserDefaults
    ) -> String {
        let canonical = ((try? MLSAppGroupStorage.canonicalizeAccountDid(accountDid)) ?? accountDid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonicalKey = mlsDeviceIDDefaultsKey(for: canonical)
        let rawKey = mlsDeviceIDDefaultsKey(for: accountDid)

        for candidateKey in [canonicalKey, rawKey] {
            if let existing = defaults.string(forKey: candidateKey), !existing.isEmpty {
                let trimmed = existing.hasPrefix("dev-") ? String(existing.dropFirst(4)) : existing
                if UUID(uuidString: trimmed) != nil {
                    let normalizedUUID = trimmed.lowercased()
                    if candidateKey != canonicalKey {
                        defaults.set(normalizedUUID, forKey: canonicalKey)
                    }
                    return normalizedUUID
                }
            }
        }

        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: canonicalKey)
        return created
    }

    /// Reads an already-persisted installation `deviceId` UUIDv4 for `accountDid` without minting a new one.
    nonisolated static func existingMLSDeviceID(
        for accountDid: String,
        in defaultsOverride: UserDefaults? = nil
    ) -> String? {
        let defaults = defaultsOverride
            ?? UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
            ?? .standard
        let trimmed = accountDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = ((try? MLSAppGroupStorage.canonicalizeAccountDid(trimmed)) ?? trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var candidateKeys = [
            mlsDeviceIDDefaultsKey(for: canonical),
            mlsDeviceIDDefaultsKey(for: trimmed),
        ]
        if let didHash = try? MLSAppGroupStorage.accountDidHash(for: trimmed) {
            candidateKeys.append("mlsDeviceId_\(didHash)")
        }
        for key in candidateKeys {
            if let raw = defaults.string(forKey: key), !raw.isEmpty {
                let normalized = raw.hasPrefix("dev-") ? String(raw.dropFirst(4)) : raw
                if UUID(uuidString: normalized) != nil {
                    return normalized.lowercased()
                }
            }
        }
        return nil
    }

    /// Successful signed erasure revokes this installation's previous UUID on the PDS.
    /// If a hosted provider subsequently rejects the email code, a new enrollment must use a new UUID.
    nonisolated static func clearErasedMLSDeviceID(
        for accountDid: String, expected: String, in defaultsOverride: UserDefaults? = nil
    ) {
        let defaults = defaultsOverride ?? UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        guard let canonical = try? MLSAppGroupStorage.canonicalizeAccountDid(accountDid),
              let hash = try? MLSAppGroupStorage.accountDidHash(for: canonical) else { return }
        for key in [mlsDeviceIDDefaultsKey(for: canonical), mlsDeviceIDDefaultsKey(for: accountDid), "mlsDeviceId_\(hash)"] {
            guard let raw = defaults.string(forKey: key) else { continue }
            let identifier = raw.hasPrefix("dev-") ? String(raw.dropFirst(4)) : raw
            if identifier.caseInsensitiveCompare(expected) == .orderedSame {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Human-readable platform display name for the current device (capped at 128 characters).
    nonisolated static func localMLSDeviceDisplayName(shortDeviceId: String? = nil) -> String {
        let baseName: String = {
            #if os(iOS)
                let raw = Self.assumeIsolatedFallbackDeviceName()
                return raw.isEmpty ? "iPhone" : raw
            #elseif os(macOS)
                let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return host.isEmpty ? "Mac" : host
            #else
                return "Catbird Device"
            #endif
        }()
        let sanitized = String(baseName.prefix(96))
        if let shortDeviceId, !shortDeviceId.isEmpty {
            return String("\(sanitized) · \(shortDeviceId.prefix(8))".prefix(128))
        }
        return sanitized
    }

    #if os(iOS)
    private nonisolated static func assumeIsolatedFallbackDeviceName() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "iOS Device"
    }
    #endif

    /// Resolve stable per-account logical device identifier (canonical lowercase UUID).
    @MainActor
    func resolvedMLSDeviceID(in defaultsOverride: UserDefaults? = nil) -> String {
        let defaults = defaultsOverride
            ?? UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
            ?? .standard
        guard defaultsOverride != nil || Self.isProtectedDataAvailable else {
            // Before the first unlock the app-group defaults read as empty, so a stored id
            // can't be told apart from a missing one. Never mint and persist an id then: it
            // would replace this device's id and strand its approval.
            return Self.existingMLSDeviceID(for: userDID, in: defaults)
                ?? Self.unpersistedLockedDeviceID
        }
        return Self.resolveOrCreateMLSDeviceID(for: userDID, in: defaults)
    }

    /// Stands in for the device id while protected data is unavailable. Never stored and
    /// never enrolled, because the coordinator doesn't open until protected data is back.
    nonisolated static let unpersistedLockedDeviceID = UUID().uuidString.lowercased()

    /// False on iOS between a restart and the first unlock, when the app-group container
    /// can't be read.
    @MainActor
    static var isProtectedDataAvailable: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// The OAuth scopes this account's session holds, as the gateway reports them, for
    /// Spaces eligibility checks (`I15`).
    ///
    /// The gateway is asked at most once every few minutes; chat checks in between reuse
    /// its answer. When the gateway cannot be reached this is its last answer; when it has
    /// never answered (offline first launch, or a sign-in that does not go through the
    /// gateway) it is the set chat needs, which is what every launch assumed before the
    /// gateway was consulted.
    @MainActor
    func resolveGrantedOAuthScopes() async -> [String] {
        let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        let client = self.client
        let did = userDID
        if let scopes = await grantedScopeResolver.gatewayScopes(fetch: {
            try await client.fetchGrantedScopes(for: did)
        }) {
            MLSGrantedScopeCache.store(Set(scopes), for: did, defaults: defaults)
            return scopes
        }
        return MLSGrantedScopeCache.load(for: did, defaults: defaults)
            ?? MLSAppGroupStorage.requiredSpacesScopes
    }

    /// Open or reuse the per-account `MLSClientCoordinator` (`Spec §4`, `§6.3`, `I8`, `I15`).
    @MainActor
    func getOrOpenMLSCoordinator() async -> MLSClientCoordinator? {
        guard isMLSRuntimeAllowed else {
            return nil
        }

        if AppStateManager.shared.isTransitioning {
            logger.warning("MLS: Coordinator access deferred during account transition")
            return nil
        }

        if let activeUserDID = AppStateManager.shared.lifecycle.userDID,
           activeUserDID != userDID
        {
            return nil
        }

        if let existing = mlsCoordinator, !existing.isClosedForSession {
            if existing.isHandleClosed {
                try? await existing.resumeFromBackground()
            }
            mlsServiceState.status = .ready
            return existing
        }

        if let existingTask = mlsCoordinatorInitTask {
            return await existingTask.value
        }

        guard Self.isProtectedDataAvailable else {
            // Before the first unlock after a restart, the stored device id reads as
            // missing. Opening now would enroll a new, pending device for this account.
            logger.info("MLS: protected data unavailable; not opening the coordinator yet")
            return nil
        }

        mlsServiceState.status = .initializing
        let targetUserDID = userDID
        let activeClient = client
        let deviceId = resolvedMLSDeviceID()

        let initTask = Task<MLSClientCoordinator?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer {
                if !Task.isCancelled {
                    self.mlsCoordinatorInitTask = nil
                }
            }

            do {
                let storageRoot = try MLSAppGroupStorage.defaultStorageRoot()
                let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID(for: targetUserDID)
                let environment: MLSEnvironment = if let mlsServiceDID {
                    .custom(serviceDID: mlsServiceDID)
                } else {
                    .production
                }
                let clientBaseURL = await activeClient.networkService.baseURL
                let pdsEndpoint = clientBaseURL.absoluteString
                let bareHomeDsDid = environment.bareServiceDID
                let homeDsEndpointString = environment.endpointURL.absoluteString

                let config = CatbirdMlsClientConfig(
                    storageRoot: storageRoot.path,
                    accountDid: targetUserDID,
                    deviceId: deviceId,
                    homeDsDid: bareHomeDsDid,
                    homeDsEndpoint: homeDsEndpointString,
                    pdsEndpoint: pdsEndpoint
                )
                let keystore = KeychainPlatformKeyStore()
                let transport = PetrelPlatformTransport(
                    atProtoClient: activeClient,
                    boundAccountDid: targetUserDID,
                    homeDsEndpoint: environment.endpointURL,
                    homeDsDid: bareHomeDsDid,
                    ownPdsEndpoint: clientBaseURL,
                    actorDeviceId: deviceId
                )

                let coordinator: MLSClientCoordinator
                do {
                    coordinator = try await MLSClientCoordinator.open(
                        config: config,
                        keystore: keystore,
                        transport: transport
                    )
                } catch CatbirdMLS.MlsError.LocalStateFormatUnsupported(let message) {
                    self.logger.warning(
                        "MLS: Local database format unsupported (\(message, privacy: .public)); wiping SQLite files while preserving Keychain recovery keys and retrying once"
                    )
                    Self.wipeUnsupportedLocalMLSDatabaseFiles(
                        storageRoot: storageRoot,
                        accountDid: targetUserDID
                    )
                    coordinator = try await MLSClientCoordinator.open(
                        config: config,
                        keystore: keystore,
                        transport: transport
                    )
                }
                if let sharedDefaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) {
                    sharedDefaults.set(deviceId, forKey: "mlsDeviceId_\(coordinator.accountDidHash)")
                    sharedDefaults.set(homeDsEndpointString, forKey: "mlsHomeDsEndpoint_\(coordinator.accountDidHash)")
                    sharedDefaults.set(pdsEndpoint, forKey: "mlsPdsEndpoint_\(coordinator.accountDidHash)")
                }
                coordinator.onChangeCallback = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.loadMLSConversations()
                        self.nseStateReloadTrigger += 1
                    }
                }

                self.mlsCoordinator = coordinator
                self.mlsBlockCoordinatorStorage = nil
                self.mlsServiceState.status = .ready
                self.mlsServiceState.retryCount = 0
                self.mlsServiceState.lastError = nil

                let scopes = await self.resolveGrantedOAuthScopes()
                if let status = try? await coordinator.checkSpacesEligibility(grantedScopes: scopes) {
                    self.spacesEligibility = status
                }
                return coordinator
            } catch {
                self.logger.error("MLS: Failed to open MLSClientCoordinator: \(error.localizedDescription)")
                self.mlsServiceState.status = .failed(error.localizedDescription)
                self.mlsServiceState.lastError = error
                return nil
            }
        }

        mlsCoordinatorInitTask = initTask
        return await initTask.value
    }

    /// Retry MLS initialization with exponential backoff
    @MainActor
    func retryMLSInitialization() async {
        guard mlsServiceState.retryCount < mlsServiceState.maxRetries else {
            mlsServiceState.status = .failed("Max retry attempts reached. Please restart the app.")
            return
        }
        mlsServiceState.retryCount += 1
        mlsServiceState.status = .retrying(attempt: mlsServiceState.retryCount)
        let delaySeconds = pow(2.0, Double(mlsServiceState.retryCount - 1))
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        await prepareMLSStorageReset()
        _ = await getOrOpenMLSCoordinator()
    }

    /// Prepare MLS coordinator for account switch or storage reset.
    @MainActor
    func prepareMLSStorageReset() async {
        mlsCoordinatorInitTask?.cancel()
        mlsCoordinatorInitTask = nil
        let coordinator = mlsCoordinator
        mlsCoordinator = nil
        mlsBlockCoordinatorStorage = nil
        mlsSyncIncompleteConversationIDs = []
        // I5: the key manager and opener belong to the coordinator being closed.
        circleEncryptionCache.reset()
        circleOpenerCache.reset()
        await coordinator?.close()
    }

    /// Checkpoint WAL and close SQLite file descriptors before suspension (`I9` zero `0xdead10cc`).
    @MainActor
    func prepareMLSForBackground() async {
        mlsCoordinatorInitTask?.cancel()
        mlsCoordinatorInitTask = nil
        guard let coordinator = mlsCoordinator else { return }
        do {
            _ = try await coordinator.prepareForBackground()
            logger.info("MLS: Checkpointed and closed SQLite descriptors for background (I9)")
        } catch {
            logger.error("MLS: prepareForBackground failed: \(error.localizedDescription)")
        }
    }

    /// Re-open SQLite handle and refresh conversation projection on foreground resume (`I9`, `I11`).
    @MainActor
    func resumeMLSFromBackground() async {
        if let coordinator = mlsCoordinator {
            do {
                try await coordinator.resumeFromBackground()
            } catch {
                logger.error("MLS: resumeFromBackground failed: \(error.localizedDescription)")
            }
        }
        await reloadMLSProjectionFromDisk()
    }

    private nonisolated static func isAllowedDatabaseSidecarTail(_ rawTail: String) -> Bool {
        var tail = rawTail
        let allowedSuffixes = [
            "-wal", "-shm", "-journal",
            ".sqlite3", ".sqlite", ".db",
            ".wal", ".shm", ".journal", ".lock", ".meta", ".json",
        ]
        while !tail.isEmpty {
            guard let matched = allowedSuffixes.first(where: { tail.hasPrefix($0) }) else {
                return false
            }
            tail.removeFirst(matched.count)
        }
        return true
    }

    /// Prefix- and delimiter-safe matcher identifying legacy pre-clean-slate MLS SQLite / sidecar files
    /// (`mls-state-*`, `MLS-*`, `epoch-checkpoints-*`, `mls_welcome_gate-*`, `mls-coordination-*`)
    /// belonging strictly to `accountDid` / `didHash`, never matching sibling accounts with shared prefixes.
    nonisolated static func isLegacyMLSDatabaseFileName(
        _ fileName: String,
        accountDid: String,
        didHash: String? = nil
    ) -> Bool {
        let rawTrimmed = accountDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else { return false }
        let canonicalDid = ((try? MLSAppGroupStorage.canonicalizeAccountDid(rawTrimmed)) ?? rawTrimmed).lowercased()
        let underscoreDid = canonicalDid
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let hyphenDid = canonicalDid
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let resolvedHash = (didHash ?? (try? MLSAppGroupStorage.accountDidHash(for: rawTrimmed)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var tokens = [canonicalDid, underscoreDid, hyphenDid]
        if let resolvedHash, resolvedHash.count == 64 {
            tokens.append(resolvedHash)
        }

        let lowerName = fileName.lowercased()
        let legacyPrefixes = [
            "mls-state-", "mls-state_",
            "mls-", "mls_",
            "epoch-checkpoints-", "epoch-checkpoints_",
            "mls_welcome_gate-", "mls_welcome_gate_",
            "mls-coordination-", "mls-coordination_",
        ]

        for prefix in legacyPrefixes where lowerName.hasPrefix(prefix) {
            let remainder = String(lowerName.dropFirst(prefix.count))
            for token in tokens where remainder.hasPrefix(token) {
                let tail = String(remainder.dropFirst(token.count))
                if isAllowedDatabaseSidecarTail(tail) {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func legacyMLSCandidateDirectories(storageRoot: URL) -> [URL] {
        [
            storageRoot,
            MLSAppGroupStorage.mlsDirectoryURL(storageRoot: storageRoot),
            storageRoot.appendingPathComponent("MLS", isDirectory: true),
            storageRoot.appendingPathComponent("mls-state", isDirectory: true),
        ]
    }

    /// Returns `true` when legacy pre-clean-slate MLS database files exist on disk for `accountDid`.
    nonisolated static func hasLegacyMLSDatabaseFiles(
        storageRoot: URL,
        accountDid: String
    ) -> Bool {
        let fm = FileManager.default
        let didHash = try? MLSAppGroupStorage.accountDidHash(for: accountDid)
        for dir in legacyMLSCandidateDirectories(storageRoot: storageRoot) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            if entries.contains(where: {
                isLegacyMLSDatabaseFileName($0.lastPathComponent, accountDid: accountDid, didHash: didHash)
            }) {
                return true
            }
        }
        return false
    }

    /// Removes `<did_hash>.db*` and legacy `mls-state-*` / `MLS-*` SQLite artifacts (including `-wal`, `-shm`,
    /// and `-journal` sidecars) for `accountDid` while keeping Keychain recovery and identity keys intact.
    nonisolated static func wipeUnsupportedLocalMLSDatabaseFiles(
        storageRoot: URL,
        accountDid: String
    ) {
        let fm = FileManager.default
        if let dbURL = try? MLSAppGroupStorage.databaseURL(storageRoot: storageRoot, accountDid: accountDid) {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(atPath: dbURL.path + suffix)
            }
        }
        let didHash = try? MLSAppGroupStorage.accountDidHash(for: accountDid)
        if let didHash {
            let mlsDir = MLSAppGroupStorage.mlsDirectoryURL(storageRoot: storageRoot)
            let prefix = "\(didHash).db"
            if let entries = try? fm.contentsOfDirectory(at: mlsDir, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent == prefix
                    || entry.lastPathComponent.hasPrefix(prefix + "-")
                    || entry.lastPathComponent.hasPrefix(prefix + ".")
                {
                    try? fm.removeItem(at: entry)
                }
            }
        }

        for dir in legacyMLSCandidateDirectories(storageRoot: storageRoot) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries where isLegacyMLSDatabaseFileName(
                entry.lastPathComponent,
                accountDid: accountDid,
                didHash: didHash
            ) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Token-boundary-safe matcher identifying legacy pre-clean-slate Keychain `kSecAttrAccount` names
    /// (`mls-db-key-*`, `MLS-*`, `mls-state-*`, `encryption-key-*`, `signing-key-*`) for `accountDid`.
    nonisolated static func isLegacyMLSKeychainAccountForDID(
        _ account: String,
        accountDid: String,
        didHash: String,
        previousDeviceId: String? = nil
    ) -> Bool {
        let rawTrimmed = accountDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else { return false }
        let canonicalDid = ((try? MLSAppGroupStorage.canonicalizeAccountDid(rawTrimmed)) ?? rawTrimmed).lowercased()
        let underscoreDid = canonicalDid
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let hyphenDid = canonicalDid
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let normalizedHash = didHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrevDevice = previousDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let lower = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }

        if normalizedHash.count == 64 && lower.contains(normalizedHash) {
            return true
        }

        let exactTokens: Set<String> = [canonicalDid, underscoreDid, hyphenDid]
        if exactTokens.contains(lower) {
            return true
        }

        let knownPrefixes = [
            "mls-state-", "mls-state_",
            "mls-db-key-", "mls-db-key_",
            "mls-key-", "mls-key_",
            "mls-", "mls_",
            "db-key-", "db-key_",
            "dbkey:", "dbkey-",
            "encryption-key-", "encryption-key:",
            "signing-key-", "signing-key:",
            "sigkey:mls-signer:", "sigkey:",
        ]
        var candidate = lower
        if let matchedPrefix = knownPrefixes.first(where: { candidate.hasPrefix($0) }) {
            candidate.removeFirst(matchedPrefix.count)
        }

        var knownSuffixes = [
            "-db-key", "_db_key",
            "-key", "_key", ".key", ":key",
            ".sqlite3", ".sqlite", ".db",
        ]
        if let dev = normalizedPrevDevice, !dev.isEmpty {
            knownSuffixes.insert(":\(dev)", at: 0)
            knownSuffixes.insert("-\(dev)", at: 1)
        }
        while let matchedSuffix = knownSuffixes.first(where: { candidate.hasSuffix($0) }) {
            candidate.removeLast(matchedSuffix.count)
        }

        return exactTokens.contains(candidate)
    }

    /// Pure prefix-safe filter identifying Keychain item `kSecAttrAccount` keys belonging strictly
    /// to `accountDid` / `didHash` across MLS (`sigkey:*`) and E2EE Circles (`<accountDID>|<spaceURI>`),
    /// never matching sibling accounts signed in on the same device.
    nonisolated static func filterAccountScopedKeychainAccounts(
        mlsAccounts: [String],
        circleAccounts: [String],
        accountDid: String,
        didHash: String,
        previousDeviceId: String? = nil
    ) -> (mlsSigKeyAccounts: [String], circleKeyAccounts: [String]) {
        let normalizedHash = didHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawTrimmed = accountDid.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalDid = (try? MLSAppGroupStorage.canonicalizeAccountDid(rawTrimmed)) ?? rawTrimmed
        let lowerDid = canonicalDid.lowercased()
        let normalizedPrevDevice = previousDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let matchedMLS: [String]
        if normalizedHash.count == 64 {
            matchedMLS = mlsAccounts.filter { account in
                let lower = account.lowercased()
                guard lower.hasPrefix("sigkey:") else { return false }
                let segments = lower.dropFirst("sigkey:".count).split(separator: ":").map(String.init)
                if segments.contains(normalizedHash) {
                    return true
                }
                if let dev = normalizedPrevDevice, !dev.isEmpty,
                   lower.contains("\(normalizedHash):\(dev)") || lower.contains("\(normalizedHash)-\(dev)")
                {
                    return true
                }
                return false
            }
        } else {
            matchedMLS = []
        }

        let matchedCircles = circleAccounts.filter { account in
            guard let pipeIdx = account.firstIndex(of: "|") else { return false }
            let prefixDid = String(account[..<pipeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            return !prefixDid.isEmpty && (
                prefixDid == canonicalDid
                    || prefixDid == rawTrimmed
                    || prefixDid.lowercased() == lowerDid
            )
        }

        return (matchedMLS, matchedCircles)
    }

    private nonisolated static func wipeAccountScopedSystemKeychainResiduals(
        accountDid: String,
        didHash: String,
        previousDeviceId: String?,
        backend: any KeychainBackend = SystemKeychainBackend()
    ) {
        let mlsService = "blue.catbird.mls.clean-slate"
        let circlesService = "blue.catbird.circles.keys"
        let accessGroup = KeychainPlatformKeyStore.resolvedAccessGroup()

        func listAccounts(service: String, accessGroup: String?, dataProtection: Bool) -> [String] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if let accessGroup, !accessGroup.isEmpty {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            if dataProtection {
                query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
                query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            }
            let (status, result) = backend.copyMatching(query)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                return []
            }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        }

        func deleteAccountItem(service: String, account: String, accessGroup: String?, dataProtection: Bool) {
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if let accessGroup, !accessGroup.isEmpty {
                deleteQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            if dataProtection {
                deleteQuery[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
                deleteQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            }
            _ = backend.delete(deleteQuery)
        }

        let mlsAccounts = listAccounts(service: mlsService, accessGroup: accessGroup, dataProtection: false)
        let circleAccounts = listAccounts(service: circlesService, accessGroup: nil, dataProtection: true)
        let (sigKeysToDelete, circleKeysToDelete) = filterAccountScopedKeychainAccounts(
            mlsAccounts: mlsAccounts,
            circleAccounts: circleAccounts,
            accountDid: accountDid,
            didHash: didHash,
            previousDeviceId: previousDeviceId
        )

        for sigAccount in sigKeysToDelete {
            deleteAccountItem(service: mlsService, account: sigAccount, accessGroup: accessGroup, dataProtection: false)
        }

        for circleAccount in circleKeysToDelete {
            deleteAccountItem(service: circlesService, account: circleAccount, accessGroup: nil, dataProtection: true)
        }

        // Sweep legacy pre-clean-slate shared MLS Keychain services (`blue.catbird.mls`, `MLS`, etc.)
        let candidateGroups: [String?] = accessGroup == nil ? [nil] : [accessGroup, nil]
        let sharedLegacyServices = [
            "blue.catbird.mls",
            "blue.catbird.mls.encryption",
            "blue.catbird.mls.keychain",
            "MLS",
        ]
        for legacyService in sharedLegacyServices {
            for group in candidateGroups {
                for dataProtection in [false, true] {
                    let accounts = listAccounts(service: legacyService, accessGroup: group, dataProtection: dataProtection)
                    for account in accounts where isLegacyMLSKeychainAccountForDID(
                        account,
                        accountDid: accountDid,
                        didHash: didHash,
                        previousDeviceId: previousDeviceId
                    ) {
                        deleteAccountItem(
                            service: legacyService,
                            account: account,
                            accessGroup: group,
                            dataProtection: dataProtection
                        )
                    }
                }
            }
        }

        // Sweep legacy per-account MLS Keychain service namespaces (`MLS-<did>`, `mls-state-<did>`, etc.)
        let canonicalLower = accountDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let underscoreDid = canonicalLower
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let hyphenDid = canonicalLower
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let dedicatedLegacyServices = Set([
            "MLS-\(accountDid)",
            "MLS-\(canonicalLower)",
            "MLS-\(underscoreDid)",
            "MLS-\(hyphenDid)",
            "MLS-\(didHash)",
            "mls-state-\(accountDid)",
            "mls-state-\(canonicalLower)",
            "mls-state-\(underscoreDid)",
            "mls-state-\(hyphenDid)",
            "mls-state-\(didHash)",
        ])
        for dedicatedService in dedicatedLegacyServices {
            for group in candidateGroups {
                for dataProtection in [false, true] {
                    var deleteServiceQuery: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: dedicatedService,
                    ]
                    if let group, !group.isEmpty {
                        deleteServiceQuery[kSecAttrAccessGroup as String] = group
                    }
                    if dataProtection {
                        deleteServiceQuery[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
                        deleteServiceQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
                    }
                    _ = backend.delete(deleteServiceQuery)
                }
            }
        }
    }

    /// Unconditionally wipes all local MLS SQLite artifacts (including legacy `mls-state-*` / `MLS-*`
    /// databases and sidecars), Keychain keys (`I8` + legacy `blue.catbird.mls` / `MLS-*`), E2EE Circle
    /// cached keys, and per-installation `deviceId` metadata for `accountDid`, even when `mlsCoordinator`
    /// was never opened in this launch. Clearing `blue.catbird.mls.deviceId.<did>` guarantees a subsequent
    /// sign-in on the same hardware mints a fresh `deviceId` UUIDv4 matching its freshly generated signing keypair.
    nonisolated static func wipeLocalMLSArtifacts(
        for accountDid: String,
        storageRoot: URL? = nil,
        keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier),
        legacyKeychainBackend: (any KeychainBackend)? = nil,
        receiptPurgeDefaults: UserDefaults = .standard
    ) {
        let trimmedDid = accountDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDid.isEmpty else { return }
        if let root = storageRoot ?? (try? MLSAppGroupStorage.defaultStorageRoot()) {
            wipeUnsupportedLocalMLSDatabaseFiles(storageRoot: root, accountDid: trimmedDid)
        }

        let canonicalDid = (try? MLSAppGroupStorage.canonicalizeAccountDid(trimmedDid)) ?? trimmedDid
        let lowerDid = canonicalDid.lowercased()
        let underscoreDid = lowerDid
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let rawDeviceKey = mlsDeviceIDDefaultsKey(for: trimmedDid)
        let canonicalDeviceKey = mlsDeviceIDDefaultsKey(for: canonicalDid)
        let previousDeviceId = sharedDefaults?.string(forKey: canonicalDeviceKey)
            ?? sharedDefaults?.string(forKey: rawDeviceKey)

        sharedDefaults?.removeObject(forKey: rawDeviceKey)
        sharedDefaults?.removeObject(forKey: canonicalDeviceKey)
        if sharedDefaults == nil || sharedDefaults === UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) {
            UserDefaults.standard.removeObject(forKey: rawDeviceKey)
            UserDefaults.standard.removeObject(forKey: canonicalDeviceKey)
        }

        if let didHash = try? MLSAppGroupStorage.accountDidHash(for: trimmedDid) {
            let resolvedPrevDevice = previousDeviceId ?? sharedDefaults?.string(forKey: "mlsDeviceId_\(didHash)")
            purgeMLSReceiptsForAccountRemoval(
                accountDidHash: didHash, backend: legacyKeychainBackend ?? SystemKeychainBackend(),
                defaults: receiptPurgeDefaults
            )
            try? keystore.deleteAccountKeys(accountDidHash: didHash)
            if let residualBackend = legacyKeychainBackend ?? (keystore is KeychainPlatformKeyStore ? SystemKeychainBackend() : nil) {
                wipeAccountScopedSystemKeychainResiduals(
                    accountDid: canonicalDid,
                    didHash: didHash,
                    previousDeviceId: resolvedPrevDevice,
                    backend: residualBackend
                )
            }
            sharedDefaults?.removeObject(forKey: "mlsDeviceId_\(didHash)")
            sharedDefaults?.removeObject(forKey: "mlsHomeDsEndpoint_\(didHash)")
            sharedDefaults?.removeObject(forKey: "mlsPdsEndpoint_\(didHash)")
            sharedDefaults?.removeObject(forKey: "blue.catbird.mls.deviceNames.\(didHash)")

            if let keys = sharedDefaults?.dictionaryRepresentation().keys {
                let ownerPrefix = "blue.catbird.mls.database-owner.\(didHash)"
                for key in keys where key == ownerPrefix
                    || key.hasPrefix(ownerPrefix + ".")
                    || key == "MLS-\(canonicalDid)"
                    || key == "MLS-\(underscoreDid)"
                    || key == "mls-state-\(canonicalDid)"
                    || key == "mls-state-\(underscoreDid)"
                {
                    sharedDefaults?.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - Bounded Sign-Out & Secondary Account Device Retirement (`A6`)

    /// Privacy-preserving retry marker queued when `retireCurrentDevice()` times out or fails while offline.
    enum PendingMLSDeviceRetirementReason: String, Sendable {
        case timeout
        case error
        case missingSecondarySessionToken = "missing_secondary_session_token"
        case secondaryCoordinatorOpenFailed = "secondary_coordinator_open_failed"
        case transientCoordinatorOpenFailed = "transient_coordinator_open_failed"
    }

    /// Stores only `accountDidHash` (SHA-256 hex) rather than raw DIDs to prevent post-sign-out DID leakage.
    struct PendingMLSDeviceRetirementRecord: Codable, Equatable, Sendable {
        let accountDidHash: String
        let deviceId: String?
        let recordedAtEpochSeconds: Int64
        let reason: String
    }

    nonisolated static let pendingDeviceRetirementsDefaultsKey = "blue.catbird.mls.pendingDeviceRetirements"

    nonisolated static func pendingMLSDeviceRetirements(
        in defaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
    ) -> [PendingMLSDeviceRetirementRecord] {
        guard let defaults,
              let data = defaults.data(forKey: pendingDeviceRetirementsDefaultsKey),
              let decoded = try? JSONDecoder().decode([PendingMLSDeviceRetirementRecord].self, from: data)
        else {
            return []
        }
        guard decoded.contains(where: {
            PendingMLSDeviceRetirementReason(rawValue: $0.reason) == nil
        }) else {
            return decoded
        }
        let sanitized = decoded.map { record in
            guard PendingMLSDeviceRetirementReason(rawValue: record.reason) == nil else {
                return record
            }
            return PendingMLSDeviceRetirementRecord(
                accountDidHash: record.accountDidHash,
                deviceId: record.deviceId,
                recordedAtEpochSeconds: record.recordedAtEpochSeconds,
                reason: PendingMLSDeviceRetirementReason.error.rawValue
            )
        }
        persistPendingMLSDeviceRetirements(sanitized, in: defaults)
        return sanitized
    }

    private struct MLSDeviceRevocationReceiptStoreError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "OSStatus \(status)"
            return "Couldn’t \(operation) the device revocation report securely: \(detail)"
        }
    }

    private struct MLSRecoveryCodeReceiptStoreError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "OSStatus \(status)"
            return "Couldn’t \(operation) the recovery-code receipt securely: \(detail)"
        }
    }

    nonisolated static let deviceRevocationReceiptKeychainService =
        "blue.catbird.mls.device-revocation-receipt.v1"

    private nonisolated static func deviceRevocationReceiptKeychainQuery(
        accountDidHash: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceRevocationReceiptKeychainService,
            kSecAttrAccount as String: accountDidHash,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    nonisolated static let recoveryCodeReceiptKeychainService =
        "blue.catbird.mls.recovery-code-receipt.v1"

    private nonisolated static func recoveryCodeReceiptKeychainQuery(
        accountDidHash: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recoveryCodeReceiptKeychainService,
            kSecAttrAccount as String: accountDidHash,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private nonisolated static let receiptLifecycleLock = NSLock()

    private nonisolated static func purgeMLSReceiptsForAccountRemoval(
        accountDidHash: String, backend: any KeychainBackend, defaults: UserDefaults
    ) {
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        defaults.set(true, forKey: "blue.catbird.mls.receipt-purge.\(accountDidHash)")
        do {
            try completePendingMLSReceiptPurge(accountDidHash: accountDidHash, backend: backend, defaults: defaults)
        } catch {
            // The flag suppresses reads and retries cleanup on the next read or replacement.
            Logger(subsystem: "blue.catbird", category: "MLS").notice("Account receipt cleanup deferred until Keychain is available")
        }
    }

    /// Caller holds the same lock through its subsequent read or save. A previous sign-out
    /// can never retry deletion after a new receipt has been successfully persisted.
    private nonisolated static func completePendingMLSReceiptPurge(
        accountDidHash: String, backend: any KeychainBackend, defaults: UserDefaults
    ) throws {
        let key = "blue.catbird.mls.receipt-purge.\(accountDidHash)"
        guard defaults.bool(forKey: key) else { return }
        let codeStatus = backend.delete(recoveryCodeReceiptKeychainQuery(accountDidHash: accountDidHash))
        let reportStatus = backend.delete(deviceRevocationReceiptKeychainQuery(accountDidHash: accountDidHash))
        guard codeStatus == errSecSuccess || codeStatus == errSecItemNotFound else {
            throw MLSRecoveryCodeReceiptStoreError(operation: "remove", status: codeStatus)
        }
        guard reportStatus == errSecSuccess || reportStatus == errSecItemNotFound else {
            throw MLSDeviceRevocationReceiptStoreError(operation: "remove", status: reportStatus)
        }
        defaults.removeObject(forKey: key)
    }

    /// Reads the unacknowledged lost-device report from this-device-only Keychain storage.
    nonisolated static func loadPendingMLSDeviceRevocationReceipt(
        forDID accountDid: String,
        backend: any KeychainBackend = SystemKeychainBackend(),
        purgeDefaults: UserDefaults = .standard
    ) throws -> PendingMLSDeviceRevocationReceipt? {
        let didHash = try MLSAppGroupStorage.accountDidHash(for: accountDid)
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        try completePendingMLSReceiptPurge(accountDidHash: didHash, backend: backend, defaults: purgeDefaults)
        var query = deviceRevocationReceiptKeychainQuery(accountDidHash: didHash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = backend.copyMatching(query)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MLSDeviceRevocationReceiptStoreError(operation: "read", status: status)
        }
        return try JSONDecoder().decode(PendingMLSDeviceRevocationReceipt.self, from: data)
    }

    /// Replaces the prior report because each later recovery rotation invalidates its predecessor.
    /// This stores no account DID, bearer token, cookie, or other reusable credential.
    nonisolated static func storePendingMLSDeviceRevocationReceipt(
        _ receipt: PendingMLSDeviceRevocationReceipt,
        backend: any KeychainBackend = SystemKeychainBackend(),
        purgeDefaults: UserDefaults = .standard
    ) throws {
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        try completePendingMLSReceiptPurge(accountDidHash: receipt.accountDidHash, backend: backend, defaults: purgeDefaults)
        let data = try JSONEncoder().encode(receipt)
        let query = deviceRevocationReceiptKeychainQuery(accountDidHash: receipt.accountDidHash)
        let updateStatus = backend.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MLSDeviceRevocationReceiptStoreError(operation: "save", status: updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = backend.add(attributes)
        guard addStatus == errSecSuccess else {
            throw MLSDeviceRevocationReceiptStoreError(operation: "save", status: addStatus)
        }
    }

    nonisolated static func clearPendingMLSDeviceRevocationReceipt(
        forDID accountDid: String,
        backend: any KeychainBackend = SystemKeychainBackend()
    ) throws {
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        let didHash = try MLSAppGroupStorage.accountDidHash(for: accountDid)
        let status = backend.delete(deviceRevocationReceiptKeychainQuery(accountDidHash: didHash))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSDeviceRevocationReceiptStoreError(operation: "remove", status: status)
        }
    }

    nonisolated static func loadPendingMLSRecoveryCodeReceipt(
        forDID accountDid: String,
        backend: any KeychainBackend = SystemKeychainBackend(),
        purgeDefaults: UserDefaults = .standard
    ) throws -> PendingMLSRecoveryCodeReceipt? {
        let didHash = try MLSAppGroupStorage.accountDidHash(for: accountDid)
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        try completePendingMLSReceiptPurge(accountDidHash: didHash, backend: backend, defaults: purgeDefaults)
        var query = recoveryCodeReceiptKeychainQuery(accountDidHash: didHash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = backend.copyMatching(query)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MLSRecoveryCodeReceiptStoreError(operation: "read", status: status)
        }
        return try JSONDecoder().decode(PendingMLSRecoveryCodeReceipt.self, from: data)
    }

    nonisolated static func storePendingMLSRecoveryCodeReceipt(
        _ receipt: PendingMLSRecoveryCodeReceipt,
        backend: any KeychainBackend = SystemKeychainBackend(),
        purgeDefaults: UserDefaults = .standard
    ) throws {
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        try completePendingMLSReceiptPurge(accountDidHash: receipt.accountDidHash, backend: backend, defaults: purgeDefaults)
        let data = try JSONEncoder().encode(receipt)
        let query = recoveryCodeReceiptKeychainQuery(accountDidHash: receipt.accountDidHash)
        let updateStatus = backend.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MLSRecoveryCodeReceiptStoreError(operation: "save", status: updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = backend.add(attributes)
        guard addStatus == errSecSuccess else {
            throw MLSRecoveryCodeReceiptStoreError(operation: "save", status: addStatus)
        }
    }

    nonisolated static func clearPendingMLSRecoveryCodeReceipt(
        forDID accountDid: String,
        backend: any KeychainBackend = SystemKeychainBackend()
    ) throws {
        receiptLifecycleLock.lock()
        defer { receiptLifecycleLock.unlock() }
        let didHash = try MLSAppGroupStorage.accountDidHash(for: accountDid)
        let status = backend.delete(recoveryCodeReceiptKeychainQuery(accountDidHash: didHash))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSRecoveryCodeReceiptStoreError(operation: "remove", status: status)
        }
    }

    /// Captures the full report before any caller dismisses or refreshes the destructive flow.
    /// If Keychain persistence fails, the observed in-memory receipt remains visible and the error
    /// is rethrown so automatic retirement reconciliation keeps its retry marker.
    @MainActor
    @discardableResult
    func retainDeviceRevocationReport(
        _ report: DeviceRevocationReport
    ) throws -> PendingMLSDeviceRevocationReceipt {
        let didHash = try MLSAppGroupStorage.accountDidHash(for: userDID)
        let receipt = PendingMLSDeviceRevocationReceipt(
            report: report,
            accountDidHash: didHash
        )
        if let prior = pendingMLSDeviceRevocationReceipt, let priorGeneration = prior.recoveryGeneration,
           priorGeneration > (receipt.recoveryGeneration ?? 0)
            || (priorGeneration == receipt.recoveryGeneration && prior.replacementRecoveryCode != nil && receipt.replacementRecoveryCode == nil) {
            return prior
        }
        pendingMLSDeviceRevocationReceipt = receipt
        do {
            try Self.storePendingMLSDeviceRevocationReceipt(receipt)
            return receipt
        } catch {
            logger.error("Couldn’t persist the device revocation report in Keychain: \(error.localizedDescription)")
            throw error
        }
    }

    /// Persists the one-shot code before the UI claims recovery is ready. Native attention remains
    /// set until explicit acknowledgement, so a crash before this write can safely retry generation.
    @MainActor
    @discardableResult
    func retainGeneratedMLSRecoveryCode(
        _ material: GeneratedRecoveryCode,
        requiresDeviceSafetyConfirmation: Bool
    ) throws -> PendingMLSRecoveryCodeReceipt {
        let didHash = try MLSAppGroupStorage.accountDidHash(for: userDID)
        let receipt = PendingMLSRecoveryCodeReceipt(
            recoveryCode: material.code,
            accountDidHash: didHash,
            requiresDeviceSafetyConfirmation: requiresDeviceSafetyConfirmation,
            recoveryGeneration: material.recoveryGeneration
        )
        if let prior = pendingMLSRecoveryCodeReceipt, let priorGeneration = prior.recoveryGeneration,
           priorGeneration > material.recoveryGeneration {
            return prior
        }
        do {
            try Self.storePendingMLSRecoveryCodeReceipt(receipt)
            pendingMLSRecoveryCodeReceipt = receipt
            return receipt
        } catch {
            logger.error("Couldn’t persist the generated recovery code in Keychain: \(error.localizedDescription)")
            throw error
        }
    }

    /// Native acknowledgement must commit before the Keychain receipt is cleared. If clearing the
    /// receipt then fails, the code remains visible and retrying the idempotent native acknowledgement
    /// is safe; reversing this order could lose the only durable copy of the replacement code.
    @MainActor
    static func completeMLSDeviceRevocationAcknowledgement(
        nativeAcknowledger: @MainActor () async throws -> Void,
        receiptClearer: @MainActor () throws -> Void
    ) async throws {
        try await nativeAcknowledger()
        try receiptClearer()
    }

    /// Clears the durable report only after the user explicitly says it was saved and the native
    /// recovery-attention marker is durably acknowledged.
    @MainActor
    @discardableResult
    func acknowledgePendingMLSDeviceRevocationReceipt(
        expected: PendingMLSDeviceRevocationReceipt,
        nativeAcknowledger: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await Self.completeMLSDeviceRevocationAcknowledgement(
                nativeAcknowledger: nativeAcknowledger,
                receiptClearer: {
                    guard self.pendingMLSDeviceRevocationReceipt == expected else { throw CancellationError() }
                    try Self.clearPendingMLSDeviceRevocationReceipt(forDID: self.userDID)
                }
            )
            pendingMLSDeviceRevocationReceipt = nil
            return true
        } catch {
            logger.error("Couldn’t acknowledge the device revocation recovery report: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    @discardableResult
    func acknowledgePendingMLSRecoveryCodeReceipt(
        expected: PendingMLSRecoveryCodeReceipt,
        nativeAcknowledger: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await Self.completeMLSDeviceRevocationAcknowledgement(
                nativeAcknowledger: nativeAcknowledger,
                receiptClearer: {
                    guard self.pendingMLSRecoveryCodeReceipt == expected else { throw CancellationError() }
                    try Self.clearPendingMLSRecoveryCodeReceipt(forDID: self.userDID)
                }
            )
            pendingMLSRecoveryCodeReceipt = nil
            return true
        } catch {
            logger.error("Couldn’t acknowledge the generated recovery code: \(error.localizedDescription)")
            return false
        }
    }

    private nonisolated static func persistPendingMLSDeviceRetirements(
        _ records: [PendingMLSDeviceRetirementRecord],
        in defaults: UserDefaults
    ) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: pendingDeviceRetirementsDefaultsKey)
            return
        }
        if let encoded = try? JSONEncoder().encode(records) {
            defaults.set(encoded, forKey: pendingDeviceRetirementsDefaultsKey)
        }
    }

    /// Retries only the signed-in account's old device IDs. Successful remote revocation must
    /// finish the caller's durable report write before its marker is consumed.
    @MainActor
    @discardableResult
    static func reconcilePendingMLSDeviceRetirements(
        accountDid: String,
        currentDeviceId: String,
        registeredDevices: [RegisteredDeviceInfo],
        in defaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier),
        revoke: @MainActor (String) async throws -> Void
    ) async -> Int {
        guard let defaults,
              let didHash = try? MLSAppGroupStorage.accountDidHash(for: accountDid)
        else { return 0 }

        var records = pendingMLSDeviceRetirements(in: defaults)
        let candidates = records.filter { $0.accountDidHash == didHash }
        var consumed = 0
        for record in candidates {
            guard let target = record.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty,
                  target.caseInsensitiveCompare(currentDeviceId) != .orderedSame
            else { continue }

            let registered = registeredDevices.first {
                $0.deviceId.caseInsensitiveCompare(target) == .orderedSame
            }
            if let registered, registered.status.lowercased() != "revoked" {
                do {
                    try await revoke(target)
                } catch {
                    continue
                }
            }

            records.removeAll { $0 == record }
            persistPendingMLSDeviceRetirements(records, in: defaults)
            consumed += 1
        }
        return consumed
    }

    nonisolated static func clearPendingMLSDeviceRetirements(
        forDID accountDid: String,
        in defaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
    ) {
        guard let defaults,
              let didHash = try? MLSAppGroupStorage.accountDidHash(for: accountDid)
        else { return }
        var records = pendingMLSDeviceRetirements(in: defaults)
        records.removeAll { $0.accountDidHash == didHash }
        persistPendingMLSDeviceRetirements(records, in: defaults)
    }

    nonisolated static func recordPendingMLSDeviceRetirement(
        accountDid: String,
        deviceId: String?,
        reason: PendingMLSDeviceRetirementReason,
        in defaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier)
    ) {
        guard let defaults,
              let didHash = try? MLSAppGroupStorage.accountDidHash(for: accountDid)
        else { return }
        var records = pendingMLSDeviceRetirements(in: defaults)
        records.removeAll { $0.accountDidHash == didHash && $0.deviceId == deviceId }
        records.append(
            PendingMLSDeviceRetirementRecord(
                accountDidHash: didHash,
                deviceId: deviceId,
                recordedAtEpochSeconds: Int64(Date().timeIntervalSince1970),
                reason: reason.rawValue
            )
        )
        if records.count > 32 {
            records = Array(records.suffix(32))
        }
        persistPendingMLSDeviceRetirements(records, in: defaults)
    }

    private actor OneShotRetirementGate<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        private var resolvedValue: Value?

        func install(_ continuation: CheckedContinuation<Value, Never>) {
            if let resolvedValue {
                continuation.resume(returning: resolvedValue)
            } else {
                self.continuation = continuation
            }
        }

        func resolve(_ value: Value) {
            guard resolvedValue == nil else { return }
            resolvedValue = value
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: value)
            }
        }
    }

    private nonisolated static func runBoundedAsync<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error>? {
        let gate = OneShotRetirementGate<Result<Value, Error>?>()
        let clampedNanoseconds = UInt64(max(0.01, timeoutSeconds) * 1_000_000_000)

        let workTask = Task {
            do {
                let value = try await operation()
                await gate.resolve(.success(value))
            } catch {
                await gate.resolve(.failure(error))
            }
        }
        let timerTask = Task {
            try? await Task.sleep(nanoseconds: clampedNanoseconds)
            guard !Task.isCancelled else { return }
            await gate.resolve(nil)
        }

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Error>?, Never>) in
            Task { await gate.install(continuation) }
        }
        workTask.cancel()
        timerTask.cancel()
        return outcome
    }

    /// Runs `retireCurrentDevice` under a hard wall-clock timeout (default `3.0s`) so sign-out or account
    /// removal never blocks when offline. On timeout or failure, logs a warning and persists a hashed
    /// `PendingMLSDeviceRetirementRecord` retry marker before local wipe proceeds.
    @discardableResult
    nonisolated static func retireDeviceBounded(
        timeoutSeconds: TimeInterval = 3.0,
        accountDid: String,
        deviceId: String?,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier),
        operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let log = Logger(subsystem: "blue.catbird", category: "MLSRetirement")
        guard let result = await runBoundedAsync(timeoutSeconds: timeoutSeconds, operation: operation) else {
            log.warning("MLS device retirement timed out after \(timeoutSeconds, privacy: .public)s; queued retry marker and continuing local wipe")
            recordPendingMLSDeviceRetirement(
                accountDid: accountDid,
                deviceId: deviceId,
                reason: .timeout,
                in: sharedDefaults
            )
            return false
        }

        switch result {
        case .success:
            return true
        case .failure:
            log.warning("MLS device retirement failed; queued retry marker and continuing local wipe")
            recordPendingMLSDeviceRetirement(
                accountDid: accountDid,
                deviceId: deviceId,
                reason: .error,
                in: sharedDefaults
            )
            return false
        }
    }

    private nonisolated static func makeSecondaryAccountGatewayTransport(
        bearerToken: String,
        gatewayOrigin: URL,
        homeDsEndpoint: URL,
        homeDsDid: String,
        deviceId: String
    ) -> PetrelPlatformTransport {
        let strippedHomeDid = homeDsDid.split(separator: "#").first.map(String.init) ?? homeDsDid
        return PetrelPlatformTransport(
            atProtoClient: nil,
            homeDsEndpoint: homeDsEndpoint,
            homeDsDid: strippedHomeDid,
            ownPdsEndpoint: gatewayOrigin,
            actorDeviceId: deviceId,
            httpOverride: { request in
                guard let url = URL(string: request.url),
                      url.scheme?.lowercased() == "https",
                      let host = url.host?.lowercased(),
                      (host == gatewayOrigin.host?.lowercased() || host == homeDsEndpoint.host?.lowercased())
                else {
                    throw CatbirdMLS.MlsError.InvalidInput(message: "Disallowed secondary retirement URL")
                }
                let nsid = url.path.hasPrefix("/xrpc/") ? String(url.path.dropFirst("/xrpc/".count)) : ""
                guard nsid.hasPrefix("blue.catbird.") || nsid.hasPrefix("com.atproto.repo.") else {
                    throw CatbirdMLS.MlsError.InvalidInput(message: "Disallowed secondary retirement NSID")
                }

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 2.5
                config.timeoutIntervalForResource = 2.5
                config.urlCache = nil
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                let session = URLSession(configuration: config)
                defer { session.finishTasksAndInvalidate() }

                func performSync(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
                    final class SyncBox: @unchecked Sendable {
                        var result: Result<(Data, HTTPURLResponse), Error>?
                    }
                    let box = SyncBox()
                    let sema = DispatchSemaphore(value: 0)
                    let task = session.dataTask(with: req) { data, response, error in
                        defer { sema.signal() }
                        if let error {
                            box.result = .failure(error)
                            return
                        }
                        guard let http = response as? HTTPURLResponse else {
                            box.result = .failure(URLError(.badServerResponse))
                            return
                        }
                        box.result = .success((data ?? Data(), http))
                    }
                    task.resume()
                    if sema.wait(timeout: .now() + 2.7) == .timedOut {
                        task.cancel()
                        throw URLError(.timedOut)
                    }
                    return try (box.result ?? .failure(URLError(.unknown))).get()
                }

                var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
                urlRequest.httpMethod = request.method
                urlRequest.httpBody = request.body
                var hasAuth = false
                for header in request.headers {
                    if header.name.caseInsensitiveCompare("Authorization") == .orderedSame {
                        hasAuth = true
                    }
                    urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
                }

                if !hasAuth {
                    if url.host?.caseInsensitiveCompare(gatewayOrigin.host ?? "") == .orderedSame {
                        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    } else if url.host?.caseInsensitiveCompare(homeDsEndpoint.host ?? "") == .orderedSame,
                              nsid.hasPrefix("blue.catbird.chat.")
                    {
                        var components = URLComponents(
                            url: gatewayOrigin.appendingPathComponent("xrpc/com.atproto.server.getServiceAuth"),
                            resolvingAgainstBaseURL: false
                        )
                        components?.queryItems = [
                            URLQueryItem(name: "aud", value: strippedHomeDid),
                            URLQueryItem(name: "lxm", value: nsid),
                        ]
                        guard let authURL = components?.url else {
                            throw CatbirdMLS.MlsError.Internal(message: "Invalid secondary getServiceAuth URL")
                        }
                        var authReq = URLRequest(url: authURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
                        authReq.httpMethod = "GET"
                        authReq.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                        authReq.setValue("application/json", forHTTPHeaderField: "Accept")
                        let (authData, authHTTP) = try performSync(authReq)
                        guard (200..<300).contains(authHTTP.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
                              let serviceJwt = json["token"] as? String,
                              !serviceJwt.isEmpty
                        else {
                            throw CatbirdMLS.MlsError.Internal(
                                message: "Secondary getServiceAuth(\(nsid)) failed closed with HTTP \(authHTTP.statusCode)"
                            )
                        }
                        urlRequest.setValue("Bearer \(serviceJwt)", forHTTPHeaderField: "Authorization")
                    }
                }

                let (data, http) = try performSync(urlRequest)
                var headers: [PlatformHttpHeader] = []
                for (rawName, rawValue) in http.allHeaderFields {
                    headers.append(PlatformHttpHeader(name: String(describing: rawName), value: String(describing: rawValue)))
                }
                return PlatformHttpResponse(status: UInt16(clamping: http.statusCode), headers: headers, body: data)
            }
        )
    }

    @MainActor
    private static func retireSecondaryAccountDeviceIfPossible(
        did: String,
        storageRoot: URL? = nil,
        keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier),
        transportOverride: (@Sendable (PlatformHttpRequest) throws -> PlatformHttpResponse)? = nil
    ) async {
        guard AccountDeletionCoordinator.hasLocalMLSArtifacts(forDID: did, storageRoot: storageRoot) else {
            return
        }
        let existingDeviceId = existingMLSDeviceID(for: did, in: sharedDefaults)
        guard let resolvedRoot = try? (storageRoot ?? MLSAppGroupStorage.defaultStorageRoot()) else {
            return
        }

        let gatewayOrigin = CatbirdGatewayConfiguration.current.origin
        let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID(for: did)
        let environment: MLSEnvironment = if let mlsServiceDID {
            .custom(serviceDID: mlsServiceDID)
        } else {
            .production
        }
        let deviceId = existingDeviceId ?? UUID().uuidString.lowercased()

        let transport: PetrelPlatformTransport
        if let transportOverride {
            transport = PetrelPlatformTransport(
                atProtoClient: nil,
                homeDsEndpoint: environment.endpointURL,
                homeDsDid: environment.bareServiceDID,
                ownPdsEndpoint: gatewayOrigin,
                actorDeviceId: deviceId,
                allowLoopbackForTesting: true,
                httpOverride: transportOverride
            )
        } else {
            let tokens = await AccountDeletionCoordinator.resolveAuthTokensForRevocation(forDID: did, explicitToken: nil)
            guard let bearerToken = tokens.first else {
                recordPendingMLSDeviceRetirement(
                    accountDid: did,
                    deviceId: existingDeviceId,
                    reason: .missingSecondarySessionToken,
                    in: sharedDefaults
                )
                return
            }
            transport = makeSecondaryAccountGatewayTransport(
                bearerToken: bearerToken,
                gatewayOrigin: gatewayOrigin,
                homeDsEndpoint: environment.endpointURL,
                homeDsDid: environment.bareServiceDID,
                deviceId: deviceId
            )
        }

        let config = CatbirdMlsClientConfig(
            storageRoot: resolvedRoot.path,
            accountDid: did,
            deviceId: deviceId,
            homeDsDid: environment.bareServiceDID,
            homeDsEndpoint: environment.endpointURL.absoluteString,
            pdsEndpoint: gatewayOrigin.absoluteString
        )

        guard let openResult = await runBoundedAsync(
            timeoutSeconds: 2.0,
            operation: {
                try await MLSClientCoordinator.open(
                    config: config,
                    keystore: keystore,
                    transport: transport
                )
            }
        ),
        case .success(let transientCoordinator) = openResult
        else {
            recordPendingMLSDeviceRetirement(
                accountDid: did,
                deviceId: existingDeviceId,
                reason: .secondaryCoordinatorOpenFailed,
                in: sharedDefaults
            )
            return
        }

        _ = await retireDeviceBounded(
            timeoutSeconds: 3.0,
            accountDid: did,
            deviceId: deviceId,
            sharedDefaults: sharedDefaults,
            operation: { try await transientCoordinator.retireCurrentDevice() }
        )
        _ = await runBoundedAsync(timeoutSeconds: 2.0) {
            try await transientCoordinator.signOutAndWipe()
        }
    }

    /// Retires any enrolled local MLS device for an unloaded secondary account (`authenticatedStates[did] == nil`)
    /// under a bounded timeout and wipes all local MLS + Circle + legacy artifacts (`A6`).
    @MainActor
    static func retireAndWipeSecondaryAccountIfPossible(
        did: String,
        storageRoot: URL? = nil,
        keystore: any PlatformKeyStore = KeychainPlatformKeyStore(),
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier),
        legacyKeychainBackend: (any KeychainBackend)? = nil,
        transportOverride: (@Sendable (PlatformHttpRequest) throws -> PlatformHttpResponse)? = nil
    ) async {
        await retireSecondaryAccountDeviceIfPossible(
            did: did,
            storageRoot: storageRoot,
            keystore: keystore,
            sharedDefaults: sharedDefaults,
            transportOverride: transportOverride
        )
        try? CircleKeyStore.wipe(accountDID: did, keychain: SystemCircleKeychain())
        wipeLocalMLSArtifacts(
            for: did,
            storageRoot: storageRoot,
            keystore: keystore,
            sharedDefaults: sharedDefaults,
            legacyKeychainBackend: legacyKeychainBackend
        )
    }

    /// Wipe local SQLCipher DB + Keychain items on sign-out (`I8`), retiring only this device first (`D-5`, `A6`).
    @MainActor
    func wipeMLSOnSignOut() async {
        let accountDid = userDID
        pendingMLSDeviceRevocationReceipt = nil
        pendingMLSRecoveryCodeReceipt = nil
        let existingDeviceId = Self.existingMLSDeviceID(for: accountDid)
        mlsCoordinatorInitTask?.cancel()
        mlsCoordinatorInitTask = nil
        var coordinator = mlsCoordinator
        mlsCoordinator = nil
        mlsBlockCoordinatorStorage = nil
        mlsConversations = []
        mlsConversationsDidChange += 1
        mlsSyncIncompleteConversationIDs = []
        mlsUnreadCount = 0

        let activeClientDid = (await client.getActiveAccountInfo()).did
        if activeClientDid == accountDid {
            if coordinator == nil,
               AccountDeletionCoordinator.hasLocalMLSArtifacts(forDID: accountDid, storageRoot: nil)
            {
                let clientRef = self.client
                if let openResult = await Self.runBoundedAsync(
                    timeoutSeconds: 2.0,
                    operation: { [weak self] in
                        try await AccountDeletionCoordinator.openTransientCoordinatorForErasure(
                            forDID: accountDid,
                            client: clientRef,
                            appState: self,
                            storageRoot: nil,
                            keystore: KeychainPlatformKeyStore()
                        )
                    }
                ),
                case .success(let opened) = openResult {
                    coordinator = opened
                } else if existingDeviceId != nil {
                    Self.recordPendingMLSDeviceRetirement(
                        accountDid: accountDid,
                        deviceId: existingDeviceId,
                        reason: .transientCoordinatorOpenFailed
                    )
                }
            }

            if let coordinator {
                _ = await Self.retireDeviceBounded(
                    timeoutSeconds: 3.0,
                    accountDid: accountDid,
                    deviceId: existingDeviceId,
                    operation: { try await coordinator.retireCurrentDevice() }
                )
                _ = await Self.runBoundedAsync(timeoutSeconds: 2.0) {
                    try await coordinator.signOutAndWipe()
                }
            }
        } else {
            if let coordinator {
                _ = await Self.runBoundedAsync(timeoutSeconds: 1.5) {
                    await coordinator.close()
                }
            }
            await Self.retireSecondaryAccountDeviceIfPossible(did: accountDid)
        }

        circleEncryptionCache.reset()
        circleOpenerCache.reset()
        // Encrypted Circle keys and the pending re-wrap list live in the
        // Keychain, not the Rust DB; wipe them with it (I8).
        do {
            try CircleKeyStore.wipe(accountDID: accountDid, keychain: SystemCircleKeychain())
        } catch {
            logger.error("Circles: key wipe on sign-out failed: \(error.localizedDescription)")
        }
        Self.wipeLocalMLSArtifacts(for: accountDid)
        await MLSImageCache.shared.purge(for: accountDid)
    }

    /// Marks every MLS conversation as read up to its latest known sequence number and refreshes unread counts.
    @MainActor
    func markAllMLSConversationsAsRead() async -> Bool {
        guard isMLSRuntimeAllowed else { return true }
        guard let coordinator = await getOrOpenMLSCoordinator() else {
            return mlsConversations.isEmpty
        }
        do {
            let rows = try await coordinator.listConversations(limit: 200)
            var allSucceeded = true
            for row in rows where row.unreadCount > 0 || row.lastSeq > 0 {
                var targetSeq = row.lastSeq
                if targetSeq <= 0,
                   let latest = try? await coordinator.listMessages(
                       conversationId: row.conversationId,
                       beforeSeq: nil,
                       limit: 1
                   ).first
                {
                    targetSeq = latest.seq
                }
                guard targetSeq > 0 else { continue }
                do {
                    try await coordinator.markConversationRead(
                        conversationId: row.conversationId,
                        readThroughSeq: targetSeq
                    )
                    try await coordinator.acknowledgeEntriesUpTo(
                        conversationId: row.conversationId,
                        upToSeq: targetSeq
                    )
                    _ = try? await coordinator.advanceReadState(
                        conversationId: row.conversationId,
                        candidateSeq: UInt64(targetSeq)
                    )
                } catch {
                    allSucceeded = false
                    logger.error("MLS: Failed to mark conversation \(row.conversationId, privacy: .public) read: \(error.localizedDescription)")
                }
            }
            await loadMLSConversations()
            return allSucceeded
        } catch {
            logger.error("MLS: Failed to list conversations for markAllMLSConversationsAsRead: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func stopMLSStreams() {}

    @MainActor
    func cancelMLSInitialization() {
        if let task = mlsCoordinatorInitTask {
            task.cancel()
            mlsCoordinatorInitTask = nil
            mlsServiceState.status = .notStarted
        }
    }

    // MARK: - MLS Lifecycle Compatibility

    @MainActor
    func flushMLSStorageForSuspension() async {
        await prepareMLSForBackground()
    }

    @MainActor
    func reloadMLSStateFromDisk() async {
        await resumeMLSFromBackground()
    }

    @MainActor
    func reloadMLSProjectionFromDisk() async {
        await loadMLSConversations()
        nseStateReloadTrigger += 1
    }

    // MARK: - User Profile Methods

    /// Load the current user's profile for optimistic updates
    @MainActor
    private func loadCurrentUserProfile(did: String) async {
        guard let operation = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(operation) }
        guard let client = atProtoClient else {
            logger.error("❌ Cannot load profile - atProtoClient is nil")
            return
        }

        do {
            let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: ATIdentifier(string: did))
            )

            guard accountServiceWork.isCurrent(operation) else { return }
            if responseCode == 200, let profile = profileData {
                // Convert ProfileViewDetailed to ProfileViewBasic
                currentUserProfile = AppBskyActorDefs.ProfileViewBasic(
                    did: profile.did,
                    handle: profile.handle,
                    displayName: profile.displayName,
                    pronouns: profile.pronouns, avatar: profile.avatar,
                    associated: profile.associated,
                    viewer: profile.viewer,
                    labels: profile.labels,
                    createdAt: profile.createdAt,
                    verification: profile.verification,
                    status: profile.status,
                    debug: nil
                )

            } else {
                logger.error("❌ Failed to load current user profile: HTTP \(responseCode)")
            }
        } catch {
            logger.error("❌ Failed to load current user profile: \(error.localizedDescription)")
        }
    }

    // MARK: Navigation

    /// Configure Nuke image pipeline with GIF animation support
    private func configureImagePipeline() {
        Task {
            // Use the custom pipeline from ImageLoadingManager which has GIF support enabled
            let pipeline = ImageLoadingManager.shared.pipeline
            await MainActor.run {
                ImagePipeline.shared = pipeline
                logger.info("Configured Nuke image pipeline with GIF animation support")
            }
        }
    }

    // MARK: - Preferences Management

    /// Initializes the preferences manager with a model context
    @MainActor
    func initializePreferencesManager(with modelContext: ModelContext) {
        let key = PreferencesBootstrapKey(userDID: userDID, containerID: ObjectIdentifier(modelContext.container))
        if lastPreferencesBootstrapKey == key {
            logger.debug("Skipping duplicate preferences bootstrap for \(self.userDID)")
            return
        }
        lastPreferencesBootstrapKey = key

        preferencesManager.configure(accountDID: userDID)
        preferencesManager.setModelContext(modelContext)
        appSettings.initialize(with: modelContext, accountDID: userDID)
        logger.debug("Initialized PreferencesManager and AppSettings with ModelContext")

        // The persisted row is readable now: use this account's own confirmed preferences, if any.
        refreshModerationPolicy()
        // Seed the accept-labelers header from the same confirmed row before any feed request; the
        // server preferences fetch keeps it current. No-op until the client is set in `initialize()`.
        accountServiceWork.start { [self] in
            await preferencesManager.applyAcceptLabelersHeaderFromConfirmedPreferences()
        }

        // Apply theme settings (now that SwiftData is available, this will use the persisted values)
        _themeManager.applyTheme(theme: appSettings.theme, darkThemeMode: appSettings.darkThemeMode, accentColor: appSettings.accentColor)
        logger.info(
            "Theme reapplied after SwiftData initialization: theme=\(self.appSettings.theme), darkMode=\(self.appSettings.darkThemeMode), accent=\(self.appSettings.accentColor)"
        )

        // Apply initial font settings
        _fontManager.applyFontSettings(
            fontStyle: appSettings.fontStyle,
            fontSize: appSettings.fontSize,
            lineSpacing: appSettings.lineSpacing,
            letterSpacing: appSettings.letterSpacing,
            dynamicTypeEnabled: appSettings.dynamicTypeEnabled,
            maxDynamicTypeSize: appSettings.maxDynamicTypeSize
        )
        if appliedFontSignature == nil { appliedFontSignature = currentFontSignature }

        // Set up proper reactive observation for settings changes
        setupSettingsObservation()
    }

    // MARK: - Theme and Font Observation

    /// Set up observation for theme and font manager changes
    @MainActor
    private func setupThemeAndFontObservation() {
        // Set up theme change observer that triggers SwiftUI updates
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ThemeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Trigger SwiftUI update for theme changes
            self.themeDidChange += 1
            logger.debug("Theme change triggered SwiftUI update")
        }

        // Set up font change observer that triggers SwiftUI updates
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FontChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Trigger SwiftUI update for font changes
            self.fontDidChange += 1
            logger.debug("Font change triggered SwiftUI update")
        }

        #if os(iOS)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.logger.warning("⚠️ Memory warning received")
                if UIApplication.shared.applicationState != .active {
                    Task { @MainActor [weak self] in
                        await self?.prepareMLSForBackground()
                    }
                }
            }
        #endif

        // GraphManager posts this whenever the viewer's block/mute graph changes
        // (block, unblock, mute, unmute). Invalidate cached identities so a
        // freshly (re-)blocked author is re-hydrated rather than served stale data.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UserGraphChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.blockedAuthorHydrator?.invalidateAll() }
        }

        logger.debug("Theme and font observation configured")
    }

    // MARK: - Settings Observation

    /// Set up reactive observation for settings changes with change tracking
    @MainActor
    private func setupSettingsObservation() {
        // Remove any existing observers to prevent duplicates
        NotificationCenter.default.removeObserver(
            self, name: NSNotification.Name("AppSettingsChanged"), object: nil
        )

        // Set up observation for theme and font changes via NotificationCenter
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppSettingsChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, !self.accountServiceWork.isSuspended,
                  AppStateManager.shared.lifecycle.appState === self,
                  notification.userInfo?["accountDID"] as? String == self.userDID else { return }

            // Create a hash of current settings to detect actual changes
            let currentSettingsHash = self.createSettingsHash()

            // Only process if settings actually changed
            guard currentSettingsHash != self.lastSettingsHash else {
                self.logger.debug("Settings notification received but no actual changes detected")
                return
            }

            self.lastSettingsHash = currentSettingsHash
            self.logger.debug("Processing actual settings change (hash: \(currentSettingsHash))")

            // Debounce rapid setting changes
            self.settingsUpdateDebounceTimer?.invalidate()
            self.settingsUpdateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self, !self.accountServiceWork.isSuspended,
                      AppStateManager.shared.lifecycle.appState === self else { return }

                self.logger.debug("Applying debounced settings change")

                // Apply theme when settings change
                self._themeManager.applyTheme(
                    theme: self.appSettings.theme,
                    darkThemeMode: self.appSettings.darkThemeMode,
                    accentColor: self.appSettings.accentColor
                )

                // Apply font settings when they change
                self._fontManager.applyFontSettings(
                    fontStyle: self.appSettings.fontStyle,
                    fontSize: self.appSettings.fontSize,
                    lineSpacing: self.appSettings.lineSpacing,
                    letterSpacing: self.appSettings.letterSpacing,
                    dynamicTypeEnabled: self.appSettings.dynamicTypeEnabled,
                    maxDynamicTypeSize: self.appSettings.maxDynamicTypeSize
                )

                // Trigger SwiftUI updates. ThemeManager posts ThemeChanged itself when the theme
                // really changed; fonts only rebuild views when their settings moved.
                self.themeDidChange += 1
                let fontSignature = self.currentFontSignature
                if fontSignature != self.appliedFontSignature {
                    self.appliedFontSignature = fontSignature
                    self.fontDidChange += 1
                }

                // Update VideoCoordinator with new autoplay preference
                VideoCoordinator.shared.appSettings = self.appSettings

                self.logger.debug(
                    "Applied debounced settings changes - theme: \(self.appSettings.theme), font: \(self.appSettings.fontStyle)"
                )
            }
        }

        logger.debug("Settings observation configured with change tracking")
    }

    /// Create a hash of current settings to detect actual changes
    private func createSettingsHash() -> Int {
        var hasher = Hasher()
        hasher.combine(appSettings.theme)
        hasher.combine(appSettings.darkThemeMode)
        hasher.combine(appSettings.accentColor)
        hasher.combine(appSettings.fontStyle)
        hasher.combine(appSettings.fontSize)
        hasher.combine(appSettings.lineSpacing)
        hasher.combine(appSettings.letterSpacing)
        hasher.combine(appSettings.dynamicTypeEnabled)
        hasher.combine(appSettings.maxDynamicTypeSize)
        hasher.combine(appSettings.useInAppBrowser)
        hasher.combine(appSettings.autoplayVideos)
        hasher.combine(appSettings.externalMediaConsent(for: .tenor) != .hide)
        hasher.combine(appSettings.requireAltText)
        hasher.combine(appSettings.reduceMotion)
        hasher.combine(appSettings.increaseContrast)
        hasher.combine(appSettings.boldText)
        hasher.combine(appSettings.displayScale)
        hasher.combine(appSettings.prefersCrossfade)
        hasher.combine(appSettings.largerAltTextBadges)
        hasher.combine(appSettings.disableHaptics)
        return hasher.finalize()
    }

    // MARK: - Post Creation Method (for backward compatibility)

    /// Creates a new post or reply (delegates to PostManager)
    func createNewPost(
        _ postText: String,
        languages: [LanguageCodeContainer],
        metadata: [String: String],
        hashtags: [String],
        facets: [AppBskyRichtextFacet],
        parentPost: AppBskyFeedDefs.PostView?,
        selfLabels: ComAtprotoLabelDefs.SelfLabels,
        embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?,
        threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
    ) async throws {
        // Delegate to PostManager with the threadgate rules
        try await postManager.createPost(
            postText,
            languages: languages,
            metadata: metadata,
            hashtags: hashtags,
            facets: facets,
            parentPost: parentPost,
            selfLabels: selfLabels,
            embed: embed,
            threadgateAllowRules: threadgateAllowRules
        )
    }

    // MARK: - Push Notifications Setup

    /// Set up push notifications
    @MainActor
    private func setupNotifications() {
        // Set the notification manager as the delegate for UNUserNotificationCenter
        UNUserNotificationCenter.current().delegate = notificationManager

        // P010/L6: removed delayed updateWidgetUnreadCount write; configure/checkUnread publish with dedup

        // Configure notification manager with app state reference for navigation
        notificationManager.configure(with: self)

        // Check current notification status
        accountServiceWork.start { [self] in
            await notificationManager.checkNotificationStatus()
        }

        // Start background unread notification checking
        notificationManager.startUnreadNotificationChecking()

        // Observe notifications marked as seen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotificationsMarkedAsSeen),
            name: NSNotification.Name("NotificationsMarkedAsSeen"),
            object: nil
        )

        // Also check when app comes to foreground
        #if os(iOS)
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.notificationManager.scheduleUnreadCheck()
                    await self.refreshPreferencesIfStale()
                    await self.probeCircleCapabilities()
                }
            }
        #elseif os(macOS)
            NotificationCenter.default.addObserver(
                forName: NSApplication.willBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.notificationManager.scheduleUnreadCheck()
                    await self.refreshPreferencesIfStale()
                    await self.probeCircleCapabilities()
                }
            }
        #endif
    }

    /// Update chat unread count from chat manager
    @MainActor
    func updateChatUnreadCount() {
        let newCount = chatManager.totalUnreadCount
        if chatUnreadCount != newCount {
            chatUnreadCount = newCount
            logger.debug("Chat unread count updated: \(newCount)")
        }
    }

    /// Update MLS unread count from current canonical conversation projection
    @MainActor
    func updateMLSUnreadCount() {
        let unreadCountTotal = mlsConversations.reduce(0) { $0 + max(0, $1.unreadCount) }
        if mlsUnreadCount != unreadCountTotal {
            mlsUnreadCount = unreadCountTotal
            logger.debug("MLS unread count updated: \(unreadCountTotal)")
        }
    }

    // MARK: - MLS (Encrypted Messaging)

    /// Reconciles hashed sign-out retry markers only after this replacement device has enrolled.
    /// An active target's marker is removed only after revocation and secure receipt persistence.
    @MainActor
    private func reconcilePendingMLSDeviceRetirements(
        using coordinator: MLSClientCoordinator
    ) async {
        let currentDeviceId = resolvedMLSDeviceID()
        guard let didHash = try? MLSAppGroupStorage.accountDidHash(for: userDID),
              Self.pendingMLSDeviceRetirements().contains(where: { record in
                  guard record.accountDidHash == didHash,
                        let target = record.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !target.isEmpty
                  else { return false }
                  return target.caseInsensitiveCompare(currentDeviceId) != .orderedSame
              })
        else { return }

        let registeredDevices: [RegisteredDeviceInfo]
        do {
            registeredDevices = try await coordinator.listDevices()
        } catch {
            logger.warning("MLS: Pending device retirement inventory deferred: \(error.localizedDescription)")
            return
        }

        let consumed = await Self.reconcilePendingMLSDeviceRetirements(
            accountDid: userDID,
            currentDeviceId: currentDeviceId,
            registeredDevices: registeredDevices
        ) { [self] targetDeviceId in
            let report = try await coordinator.revokeDevice(targetDeviceId: targetDeviceId)
            _ = try retainDeviceRevocationReport(report)
            guard report.dsRevoked else {
                throw NSError(
                    domain: "MLSDeviceRetirement",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The server returned an incomplete device revocation report."
                    ]
                )
            }
        }
        if consumed > 0 {
            logger.info("MLS: Reconciled \(consumed) pending device retirement marker(s)")
        }
    }

    /// Initialize MLS for the current account via the unified Rust `CatbirdMlsClient` SDK (`Spec §4`, `§6.3`, `I15`).
    @MainActor
    func initializeMLS() async throws {
        guard isMLSRuntimeAllowed else {
            logger.debug("MLS: Skipping initializeMLS because MLS is disabled for this account")
            return
        }

        guard let coordinator = await getOrOpenMLSCoordinator() else {
            logger.warning("MLS: Coordinator unavailable during initializeMLS")
            throw MLSInitializationError.noConversationManager
        }

        let grantedScopes = await resolveGrantedOAuthScopes()
        let status = try await coordinator.checkSpacesEligibility(grantedScopes: grantedScopes)
        spacesEligibility = status

        if status.eligible {
            do {
                _ = try await coordinator.enrollDevice(grantedScopes: grantedScopes)
                ExperimentalSettings.shared.recordMLSEnrollment(for: userDID)
                logger.info("MLS: Device enrolled with post-quantum credentials (I16)")
                await reconcilePendingMLSDeviceRetirements(using: coordinator)
            } catch {
                logger.warning("MLS: Device enrollment deferred (possibly offline): \(error.localizedDescription)")
            }
        }

        await reloadMLSConversations()
        scheduleBlockReconcileIfNeeded()
        logger.info("MLS: Initialized via MLSClientCoordinator")
    }

    /// Asks the account's server for the encrypted-chat permissions the session lacks, then
    /// re-checks Spaces eligibility and enrolls this device (`I15`).
    /// Explicitly invoked from the user-facing Spaces gate button after an opt-in attempt.
    ///
    /// - Parameter present: Shows the server's consent page and returns its callback URL.
    /// - Returns: What to show when the permissions were not granted; `nil` when they were,
    ///   or when the user closed the consent page.
    @MainActor
    func reauthorizeSpacesForMLS(
        present: @escaping @MainActor (URL) async throws -> URL
    ) async -> EncryptedChatPermissionFailure? {
        // Re-authorizing is an explicit request to use encrypted chat.
        ExperimentalSettings.shared.enableMLSChat(for: userDID)
        guard var coordinator = await getOrOpenMLSCoordinator() else {
            return .unavailable
        }
        var scopes = await resolveGrantedOAuthScopes()
        var status = try? await coordinator.checkSpacesEligibility(grantedScopes: scopes)
        var failure: EncryptedChatPermissionFailure?

        let missing: Set<String>
        if case .missingOAuthScopes(let missingScopes)? = status?.reason {
            // `atproto` is the sign-in itself, never something an upgrade adds.
            missing = Set(missingScopes).subtracting(["atproto"])
        } else {
            missing = []
        }
        if !missing.isEmpty {
            do {
                let granted = try await AppStateManager.shared.authentication.requestGatewayScopes(
                    missing,
                    label: "encrypted chat",
                    present: present
                )
                let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
                MLSGrantedScopeCache.store(granted, for: userDID, defaults: defaults)
                grantedScopeResolver.record(granted)
                scopes = granted.sorted()
                // The upgrade replaced the session; take the coordinator that follows it.
                guard let current = await getOrOpenMLSCoordinator() else {
                    return .unavailable
                }
                coordinator = current
                status = try? await coordinator.checkSpacesEligibility(grantedScopes: scopes)
                if status?.eligible != true {
                    logger.error("MLS: Server granted \(granted.count) scopes but encrypted chat is still not eligible")
                    var stillMissing: [String] = []
                    if case .missingOAuthScopes(let remaining)? = status?.reason {
                        stillMissing = remaining.sorted()
                    }
                    failure = .partialGrant(missing: stillMissing)
                }
            } catch let error as GatewayPermissionError where error == .cancelled {
                return nil
            } catch {
                let detail: String
                if case .upgradeFailed(let message)? = error as? GatewayPermissionError {
                    detail = message
                } else {
                    detail = error.localizedDescription
                }
                logger.error("MLS: Encrypted-chat permission request failed: \(detail, privacy: .public)")
                failure = EncryptedChatPermissionFailure(error: error)
            }
        }

        if let status {
            spacesEligibility = status
        }
        guard spacesEligibility?.eligible == true else {
            return failure
        }
        if (try? await coordinator.enrollDevice(grantedScopes: scopes)) != nil {
            ExperimentalSettings.shared.recordMLSEnrollment(for: userDID)
            await reconcilePendingMLSDeviceRetirements(using: coordinator)
        }
        await reloadMLSConversations()
        return nil
    }

    @MainActor
    func updateMLSEpochRetentionPolicy(days: Int) async {
        let clampedDays = max(1, days)
        let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        defaults.set(clampedDays, forKey: "blue.catbird.mls.retentionDays.\(userDID.lowercased())")
        logger.info("MLS: Updated message retention policy preference to \(clampedDays) day(s)")
    }

    /// Fire-and-forget block reconciliation against pending direct requests, guarded once per day per user.
    @MainActor
    private func scheduleBlockReconcileIfNeeded() {
        guard isMLSRuntimeAllowed else { return }
        let key = "mls.blockReconcile.\(userDID).lastRun"
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        if let last = defaults.object(forKey: key) as? Date,
           calendar.isDate(last, inSameDayAs: Date()) {
            logger.debug("MLS: Block reconcile already ran today, skipping")
            return
        }

        Task { @MainActor [weak self] in
            guard let self, self.isMLSRuntimeAllowed,
                  let coordinator = await self.getOrOpenMLSCoordinator() else { return }
            _ = try? await self.graphManager.refreshBlockCache()
            let blocks = await self.graphManager.blockCache
            if let pending = try? await coordinator.listRequests(consentFilter: "incomingPending") {
                for request in pending where blocks.contains(request.senderDid) {
                    try? await coordinator.declineDirectRequest(requestId: request.requestId)
                }
            }
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    /// Load MLS conversations from local encrypted SQLite projection via `MLSClientCoordinator`.
    @MainActor
    func loadMLSConversations() async {
        guard isMLSRuntimeAllowed else {
            if !mlsConversations.isEmpty || mlsUnreadCount != 0 {
                mlsConversations = []
                mlsConversationsDidChange += 1
                updateMLSUnreadCount()
            }
            return
        }

        guard let coordinator = await getOrOpenMLSCoordinator() else {
            mlsConversations = []
            mlsConversationsDidChange += 1
            updateMLSUnreadCount()
            return
        }

        do {
            let rows = try await coordinator.listConversations()
            let models = rows.map { MLSConversationModel(row: $0, currentUserDID: userDID) }
            let canonicalModels = try MLSConversationIdentityBoundary.canonicalize(models)

            let conversations = canonicalModels.map { model -> MLSConversationViewModel in
                MLSConversationViewModel(
                    id: model.conversationID,
                    name: model.title,
                    participants: [],
                    lastMessagePreview: model.description,
                    lastMessageTimestamp: model.lastMessageAt ?? model.updatedAt,
                    unreadCount: model.unreadCount,
                    isGroupChat: true,
                    groupId: model.groupID.hexEncodedString()
                )
            }

            mlsConversations = conversations
            mlsConversationsDidChange += 1
            updateMLSUnreadCount()
            stateInvalidationBus.notify(.mlsConversationListChanged)
            logger.info("MLS: Loaded \(conversations.count) canonical conversation(s)")
        } catch {
            logger.error("MLS: Failed to load conversations: \(error.localizedDescription)")
            mlsConversations = []
            mlsConversationsDidChange += 1
            updateMLSUnreadCount()
        }
    }

    /// Reload MLS conversations (syncs remote mls-ds Welcomes/entries, then refreshes local projection)
    @MainActor
    func reloadMLSConversations() async {
        if isMLSRuntimeAllowed, let coordinator = await getOrOpenMLSCoordinator() {
            await syncMLS(using: coordinator)
        }
        await loadMLSConversations()
    }

    /// One MLS sync pass. A `SyncIncomplete` still applied every conversation it does not name, so
    /// callers go on to refresh; only the named conversations are marked.
    @MainActor
    func syncMLS(using coordinator: MLSClientCoordinator) async {
        do {
            try await coordinator.sync()
            mlsSyncIncompleteConversationIDs = []
        } catch {
            recordMLSSyncFailure(error)
        }
    }

    /// Any failure other than `SyncIncomplete` keeps the previous marks: nothing verified those
    /// conversations since.
    @MainActor
    func recordMLSSyncFailure(_ error: Error) {
        if let failed = (error as? MlsError)?.syncIncompleteConversationIDs {
            mlsSyncIncompleteConversationIDs = failed
        }
        logger.error("MLS: sync did not complete: \(error.localizedDescription)")
    }

    /// Update MLS conversation list when a message is received
    @MainActor
    func handleMLSMessageReceived(conversationID: String) async {
        await reloadMLSConversations()
        logger.debug("MLS: Conversations reloaded after message in: \(conversationID)")
    }

    /// Setup chat observers and background polling for unread messages
    @MainActor
    private func setupChatObservers() {
        chatManager.onUnreadCountChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.accountServiceWork.isSuspended else { return }
                self.updateChatUnreadCount()
            }
        }

        chatManager.onConversationsPolled = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.accountServiceWork.isSuspended,
                      case .authenticated = self.authState else { return }
                self.updateChatUnreadCount()
                if self.isMLSRuntimeAllowed {
                    self.accountServiceWork.start { [weak self] in
                        await self?.reloadMLSConversations()
                    }
                }
            }
        }
        chatManager.startConversationsPolling()

        // Update chat unread count initially
        accountServiceWork.start { [self] in
            updateChatUnreadCount()
        }

        // Load MLS conversations initially only if MLS is enabled for this account
        if isMLSRuntimeAllowed {
            accountServiceWork.start { [self] in
                await reloadMLSConversations()
            }
        }

        #if os(iOS)
            let chatForegroundNotification = UIApplication.willEnterForegroundNotification
        #elseif os(macOS)
            let chatForegroundNotification = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(
            forName: chatForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accountServiceWork.start { [weak self] in
                    guard let self else { return }
                    self.chatManager.startConversationsPolling()
                    await self.chatManager.loadConversations(refresh: true)
                    self.updateChatUnreadCount()

                    // Reload MLS conversations only if MLS is enabled for this account
                    if self.isMLSRuntimeAllowed {
                        await self.reloadMLSConversations()
                    }
                }
            }
        }
    }

    @objc private func handleNotificationsMarkedAsSeen() {
        notificationManager.updateUnreadCountAfterSeen()
    }

    /// Syncs notification-related user data with the server
    @MainActor
    func syncNotificationData() async {
        guard let operation = accountServiceWork.beginOperation() else { return }
        defer { accountServiceWork.endOperation(operation) }
        await notificationManager.syncAllUserData()
    }

    // MARK: - Authentication Methods (for backward compatibility)

    /// Logs out the current user (delegates to AppStateManager's authentication manager)
    @MainActor
    func handleLogout() async throws {
        logger.info("Logout requested - delegating to AppStateManager")

        await wipeMLSOnSignOut()

        await preferencesManager.clearAllPreferences()
        logger.info("User preferences cleared during logout")

        await AppStateManager.shared.logout()
    }

    /// Add a new account (delegates to AppStateManager's authentication manager)
    @MainActor
    func addAccount(handle: String) async throws -> URL {
        logger.info("Adding new account: \(handle)")
        return try await AppStateManager.shared.authentication.addAccount(handle: handle)
    }

    /// Remove an account (delegates to AppStateManager's authentication manager)
    @MainActor
    func removeAccount(did: String) async throws {
        logger.info("Removing account: \(did)")

        if did == userDID {
            await wipeMLSOnSignOut()
        }

        // Secondary accounts are retired + wiped inside AppStateManager.removeAccount(_:)
        // BEFORE AuthManager deletes their stored session token.
        try await AppStateManager.shared.authentication.removeAccount(did: did)

        if did != userDID {
            Self.wipeLocalMLSArtifacts(for: did)
            await MLSImageCache.shared.purge(for: did)
        }

        if isAuthenticated {
            await refreshAfterAccountSwitch()
        }
    }

    /// Updates the client reference when reusing a cached AppState or after E2E re-login
    @MainActor
    func updateClient(_ newClient: ATProtoClient) {
        logger.info("Updating AppState client reference for user: \(self.userDID)")
        ageAccess.suspend()
        circleCapabilityProbeID = nil
        circleCapabilityProbeState = .notStarted
        circleCapability = .unknown
        _circleService = nil
        circleEncryptionCache.reset()
        circleOpenerCache.reset()
        _circleNotificationService = nil
        _circleNotificationsModel = nil
        client = newClient
        ageAccess.startPreflight()
        #if DEBUG
        if let transport = e2eCircleTransport { installE2ECircleFixture(transport: transport) }
        #endif

        postManager.updateClient(newClient)
        preferencesManager.updateClient(newClient)
        // Re-read this account's own stored policy for the new client before any request uses it.
        refreshModerationPolicy()
        // The new client starts without this account's accept-labelers header; seed it from the
        // confirmed stored row so feed requests made before the next preferences fetch carry it.
        accountServiceWork.start { [self] in
            await preferencesManager.applyAcceptLabelersHeaderFromConfirmedPreferences()
        }
        graphManager = GraphManager(atProtoClient: newClient)
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(newClient)
        // Update notification manager (async operation)
        accountServiceWork.start { [self] in
            await notificationManager.updateClient(newClient)
        }

        // Update chat manager (async operation)
        accountServiceWork.start { [self] in
            await chatManager.updateClient(newClient)
        }

        logger.info("Clearing MLS API client and coordinator caches for fresh token propagation")
        mlsAPIClientStorage = nil
        Task { @MainActor [weak self] in
            await self?.prepareMLSStorageReset()
        }

        logger.info("✅ Client reference updated for all managers")
    }

    // MARK: - Social Graph Methods

    @discardableResult
    func follow(did: String) async throws -> Bool {
        // graphManager is non-optional, direct access is safe if initialized correctly
        // Throwing an error if client isn't set might be handled within GraphManager itself
        return try await graphManager.follow(did: did)
    }

    /// Using GraphError instead of AuthError
    @discardableResult
    func unfollow(did: String) async throws -> Bool {
        // graphManager is non-optional, direct access is safe if initialized correctly
        // Throwing an error if client isn't set might be handled within GraphManager itself
        return try await graphManager.unfollow(did: did)
    }

    // MARK: - Thread Creation / Post Management

    /// Add support for thread creation with threadgates
    func createThread(
        posts: [String],
        languages: [LanguageCodeContainer],
        selfLabels: ComAtprotoLabelDefs.SelfLabels,
        hashtags: [String] = [],
        facets: [[AppBskyRichtextFacet]?] = [],
        embeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?]? = nil,
        parentPost: AppBskyFeedDefs.PostView? = nil,
        threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
    ) async throws {
        try await postManager.createThread(
            posts: posts,
            languages: languages,
            selfLabels: selfLabels,
            hashtags: hashtags,
            facets: facets,
            embeds: embeds,
            parentPost: parentPost,
            threadgateAllowRules: threadgateAllowRules
        )
    }

    // MARK: - Performance Optimization Methods

    /// Waits for the next refresh cycle of the app state
    /// This is a performance optimization method that allows components to wait for a good moment to update
    /// rather than using arbitrary fixed delays
    func waitForNextRefreshCycle() async {
        // Default implementation: a small but adaptive delay
        // In the future, this could be connected to actual app refresh cycles
        let baseDelay: UInt64 = 100_000_000 // 100ms base delay

        // Adjust based on current system load if needed
        let processingPressure = ProcessInfo.processInfo.thermalState

        let finalDelay: UInt64
        switch processingPressure {
        case .nominal:
            finalDelay = baseDelay
        case .fair:
            finalDelay = baseDelay * 2 // 200ms
        case .serious:
            finalDelay = baseDelay * 3 // 300ms
        case .critical:
            finalDelay = baseDelay * 4 // 400ms
        @unknown default:
            finalDelay = baseDelay
        }

        // Wait for the calculated delay
        try? await Task.sleep(nanoseconds: finalDelay)

        // Log at debug level for performance profiling
        //    logger.debug(
        //      "Completed waitForNextRefreshCycle (delay: \(Double(finalDelay) / 1_000_000_000.0))s"
        //    )
    }

    // MARK: - State Invalidation Methods

    /// Notify that a post was created (triggers feed refresh)
    @MainActor
    func notifyPostCreated(_ post: AppBskyFeedDefs.PostView) {
        logger.info("Post created notification: \(post.uri)")
        stateInvalidationBus.notifyPostCreated(post)
    }

    /// Notify that a reply was created (triggers thread and feed refresh)
    @MainActor
    func notifyReplyCreated(_ reply: AppBskyFeedDefs.PostView, parentUri: String) {
        logger.info("Reply created notification: \(reply.uri) -> \(parentUri)")
        stateInvalidationBus.notifyReplyCreated(reply, parentUri: parentUri)
    }

    /// Notify that account was switched (triggers full state refresh)
    @MainActor
    func notifyAccountSwitched() {
        logger.info("Account switched notification")
        ThreadManager.clearPrefillCache()
        stateInvalidationBus.notifyAccountSwitched()
    }

    /// Notify that authentication was completed (triggers initial feed load)
    @MainActor
    func notifyAuthenticationCompleted() {
        logger.info("Authentication completed notification")
        stateInvalidationBus.notifyAuthenticationCompleted()
    }

    /// Notify that a feed was updated
    @MainActor
    func notifyFeedUpdated(_ fetchType: FetchType) {
        logger.debug("Feed updated notification: \(fetchType.identifier)")
        stateInvalidationBus.notifyFeedUpdated(fetchType)
    }

    /// Notify that a profile was updated
    @MainActor
    func notifyProfileUpdated(_ did: String) {
        logger.debug("Profile updated notification: \(did)")
        stateInvalidationBus.notifyProfileUpdated(did)
    }

    /// Notify that a thread was updated
    @MainActor
    func notifyThreadUpdated(_ rootUri: String) {
        logger.debug("Thread updated notification: \(rootUri)")
        stateInvalidationBus.notifyThreadUpdated(rootUri)
    }

    // MARK: - Platform-required age access

    #if os(iOS)
    /// The scene supplies only its presenter. Apple bands stay inside the coordinator's
    /// immediate decision; a switched account or replaced client cannot accept a result.
    @MainActor
    func requestPlatformAgeBand(
        from presenter: UIViewController,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        let manager = AppStateManager.shared
        let accountRevision = manager.settingsAccountContextRevision
        let requestClient = client
        let ownsRequest: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled
                && manager.lifecycle.appState === self
                && manager.settingsAccountContextRevision == accountRevision
                && self.client === requestClient
                && !self.accountServiceWork.isSuspended
                && isCurrent()
        }
        guard ownsRequest() else { return }
        await ageAccess.request(
            using: { [regulatoryChecker] in
                guard ownsRequest() else { throw CancellationError() }
                return try await regulatoryChecker.requestAgeBand(from: presenter)
            },
            isCurrent: ownsRequest)
    }
    #endif

    // MARK: - Moderation Policy

    /// Rebuilds `moderationPolicy` for this account from its server-confirmed preferences.
    ///
    /// The policy is built from the account's stored `Preferences` row only when that row belongs to
    /// `userDID` and `hasConfirmedServerPreferences` is true: `adultContentEnabled`, `contentLabelPrefs`
    /// and `labelers`. Without such a row it is this account's fail-closed policy: adult content off,
    /// builtin label defaults, and only the Bluesky moderation service. A row that cannot be read leaves
    /// an existing policy for this account in place and never borrows another account's value.
    ///
    /// Subscribed labelers' label definitions load in the background. The policy is built at once with the
    /// last successful definitions and rebuilt when a load completes for the same labelers. A failed load
    /// keeps those definitions.
    @MainActor
    func refreshModerationPolicy() {
        guard let subscriptions = rebuildModerationPolicy() else { return }
        loadModerationDefinitions(for: subscriptions)
    }

    /// Waits for the label-definitions load in flight, if any. The load never throws; a result that no
    /// longer applies is dropped. Callers use this to sequence work after the background load.
    @MainActor
    func awaitModerationDefinitionsLoad() async {
        await moderationDefinitionsLoad?.task.value
    }

    /// Returns the confirmed row's labeler subscriptions, or `nil` when the policy is fail-closed or kept.
    @MainActor
    @discardableResult
    private func rebuildModerationPolicy() -> [LabelerPreference]? {
        let stored: Preferences?
        do {
            stored = try preferencesManager.confirmedFeedFilterPreferences()
        } catch {
            logger.debug("Stored preferences are not readable yet: \(error.localizedDescription)")
            if moderationPolicy.accountDID != userDID { applyModerationPolicy(failClosedModerationPolicy()) }
            return nil
        }
        guard let stored, stored.accountDID == userDID else {
            moderationLabelerDIDs = []
            applyModerationPolicy(failClosedModerationPolicy())
            return nil
        }
        let subscriptions = stored.labelers
        let labelerDIDs = subscriptions.map { $0.did.didString() }
        moderationLabelerDIDs = labelerDIDs
        seedModerationDefinitionsFromDisk(labelerDIDs: labelerDIDs)
        applyModerationPolicy(ModerationPolicy(
            accountDID: userDID,
            serverAdultContentEnabled: stored.adultContentEnabled,
            contentLabelPrefs: stored.contentLabelPrefs,
            labelerDIDs: labelerDIDs,
            labelerDefinitions: moderationDefinitions,
            isConfirmed: stored.hasConfirmedServerPreferences))
        return subscriptions
    }

    private func failClosedModerationPolicy() -> ModerationPolicy {
        ModerationPolicy(
            accountDID: userDID,
            serverAdultContentEnabled: false,
            contentLabelPrefs: [],
            labelerDIDs: [],
            labelerDefinitions: [:],
            isConfirmed: false)
    }

    /// Before the first network load for a labeler set, uses the definitions stored on disk for exactly
    /// this account and set, so custom labels resolve on the first frame. Only raw labeler definitions
    /// come from disk; preferences and the age restriction are applied at runtime as always. Called only
    /// with server-confirmed subscriptions. The network load still runs and overwrites the entry.
    @MainActor
    private func seedModerationDefinitionsFromDisk(labelerDIDs: [String]) {
        let key = LabelerDefinitionsDiskCache.normalizedLabelerDIDs(labelerDIDs)
        guard moderationDefinitionsDiskKey != key else { return }
        moderationDefinitionsDiskKey = key
        // Definitions already loaded from the network for this set are newer than the disk copy.
        if let loaded = loadedModerationDefinitionsKey,
           LabelerDefinitionsDiskCache.normalizedLabelerDIDs(loaded.labelerDIDs) == key { return }
        guard let cached = LabelerDefinitionsDiskCache.load(accountDID: userDID, labelerDIDs: key) else { return }
        moderationDefinitions = cached
    }

    @MainActor
    private func applyModerationPolicy(_ policy: ModerationPolicy) {
        baseModerationPolicy = policy
        let effective = policy.restrictingMatureContent(ageAccess.restrictsMatureContent)
        guard effective != moderationPolicy else { return }
        moderationPolicy = effective
        NotificationCenter.default.post(
            name: .moderationPolicyDidChange, object: nil, userInfo: ["accountDID": userDID])
    }

    @MainActor
    private func loadModerationDefinitions(for subscriptions: [LabelerPreference]) {
        let client = self.client
        let key = ModerationDefinitionsKey(
            labelerDIDs: subscriptions.map { $0.did.didString() }, client: ObjectIdentifier(client))
        guard loadedModerationDefinitionsKey != key else { return }
        if let load = moderationDefinitionsLoad, load.key == key, !load.task.isCancelled { return }
        moderationDefinitionsLoad?.task.cancel()
        moderationDefinitionsLoad = nil
        // The lookup reads the subscriptions from a value it owns, so the stored row can change meanwhile.
        let snapshot = Preferences(accountDID: userDID, labelers: subscriptions)
        let id = UUID()
        guard let task = startAccountTask(priority: .utility, operation: { [weak self] in
            await self?.performModerationDefinitionsLoad(id: id, key: key, snapshot: snapshot, client: client)
        }) else { return }
        moderationDefinitionsLoad = ModerationDefinitionsLoad(id: id, key: key, task: task)
    }

    @MainActor
    private func performModerationDefinitionsLoad(
        id: UUID, key: ModerationDefinitionsKey, snapshot: Preferences, client: ATProtoClient
    ) async {
        defer { if moderationDefinitionsLoad?.id == id { moderationDefinitionsLoad = nil } }
        do {
            let definitions = try await ContentLabelDefinitionLookup.subscribedDefinitions(
                appState: self, preferences: snapshot, client: client)
            guard !Task.isCancelled, self.client === client, moderationLabelerDIDs == key.labelerDIDs else { return }
            moderationDefinitions = definitions
            loadedModerationDefinitionsKey = key
            moderationDefinitionsDiskKey = LabelerDefinitionsDiskCache.normalizedLabelerDIDs(key.labelerDIDs)
            LabelerDefinitionsDiskCache.store(definitions, accountDID: userDID, labelerDIDs: key.labelerDIDs)
            rebuildModerationPolicy()
        } catch {
            logger.error("Could not load labeler definitions for the moderation policy: \(error.localizedDescription)")
        }
    }

    // MARK: - Content Filtering Helper

    /// Build FeedTunerSettings from current user preferences
    /// This ensures consistent filtering across feeds, threads, profiles, and search
    @MainActor
    func buildFilterSettings() async -> FeedTunerSettings {
        let confirmed = (try? preferencesManager.confirmedFeedFilterPreferences()).map(FeedPreferenceSnapshot.init)
        let retainedLocal = confirmed == nil
            ? (try? preferencesManager.retainedLocalFeedFilterPreferences()).map(FeedPreferenceSnapshot.init) : nil
        let snapshot = FeedPreferenceSnapshotStore.shared.resolve(accountDID: userDID,
            confirmed: confirmed, retainedLocal: retainedLocal)
        return makeFilterSettings(snapshot: snapshot)
    }

    /// A side-effect-free snapshot shared by feed and search consumers.
    @MainActor
    func makeFilterSettings(preferences suppliedPreferences: Preferences?, localFilters: FeedFilterSettings? = nil) -> FeedTunerSettings {
        makeFilterSettings(snapshot: suppliedPreferences.map(FeedPreferenceSnapshot.init), localFilters: localFilters)
    }

    @MainActor
    func makeFilterSettings(snapshot suppliedSnapshot: FeedPreferenceSnapshot?, localFilters: FeedFilterSettings? = nil) -> FeedTunerSettings {
        let preferences = suppliedSnapshot?.accountDID == userDID ? suppliedSnapshot : nil
        let feed = preferences?.feedViewPref
        let filters = localFilters ?? feedFilterSettings
        var settings = FeedTunerSettings(
            hideReplies: filters.hideReplies || (feed?.hideReplies ?? false),
            hideRepliesByUnfollowed: feed?.hideRepliesByUnfollowed ?? false,
            hideRepliesByLikeCount: feed?.hideRepliesByLikeCount,
            hideReposts: filters.hideReposts || (feed?.hideReposts ?? false),
            hideQuotePosts: filters.hideQuotePosts || (feed?.hideQuotePosts ?? false),
            hideNonPreferredLanguages: appSettings.hideNonPreferredLanguages || filters.isFilterEnabled(name: "Filter by Language"),
            preferredLanguages: appSettings.contentLanguages,
            mutedUsers: graphManager.muteCache,
            blockedUsers: graphManager.blockCache,
            hideLinks: filters.hideLinks,
            onlyTextPosts: filters.onlyTextPosts,
            onlyMediaPosts: filters.onlyMediaPosts,
            hiddenPosts: postHidingManager.hiddenPosts,
            currentUserDid: userDID
        )
        settings.mutedWords = preferences?.mutedWords ?? []
        settings.moderationPolicy = moderationPolicy
        return settings
    }

}

// MARK: - MLS Initialization Errors

enum MLSInitializationError: Error, LocalizedError {
    case noConversationManager

    var errorDescription: String? {
        switch self {
        case .noConversationManager:
            return "MLS conversation manager not available"
        }
    }
}

// MARK: - Prefetched Feed Cache

actor PrefetchedFeedCache {
    private var cache: [FetchType: (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)] = [:]

    func set(_ posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?, for fetchType: FetchType) {
        cache[fetchType] = (posts, cursor)
    }

    func get(for fetchType: FetchType) -> (posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?)? {
        return cache[fetchType]
    }

    func clear() {
        cache.removeAll()
    }
}

// Derived-access invalidation carries account identity only, never an age result.
extension Notification.Name {
    static let platformAgeAccessDidChange = Notification.Name("platformAgeAccessDidChange")
}

private extension AppState {
    func scopedStandardDefaultsKey(_ baseKey: String) -> String {
        AppSettingsModel.scopedKey(baseKey, accountDID: userDID)
    }
}
