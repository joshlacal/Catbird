import AVKit
import BluemojiKit
import CatbirdMLSCore
import Foundation
import NaturalLanguage
import Nuke
import OSLog
import Petrel
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

    /// Default home sequencer DID for creating new groups (`D1`)
    var defaultMLSSequencerDID: String {
        CatbirdGatewayConfiguration.current.mlsServiceDID ?? "did:web:chat.catbird.blue#atproto_mls"
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

    /// Whether MLS / Spaces runtime work is permitted for this account (`ctl #2`: zero DB/PDS/DS activity when disabled).
    @MainActor
    var isMLSRuntimeAllowed: Bool {
        if ProcessInfo.processInfo.arguments.contains("--e2e-mode")
            || CatbirdGatewayConfiguration.current.isRuntimeFixture
        {
            return true
        }
        return CatbirdFeatures.mlsChat && ExperimentalSettings.shared.isMLSChatEnabled(for: userDID)
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
        circleCapabilityProbeID = nil
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
        circleCapabilityProbeID = nil
        circleCapability = .unknown
        #if DEBUG
        if let transport = e2eCircleTransport { installE2ECircleFixture(transport: transport) }
        #endif

        accountServiceWork.start { [self] in
            await probeCircleCapabilities()
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
    var circlesEnabled: Bool { CatbirdFeatures.circlesSpaces && circleCapability == .supported }
    @ObservationIgnored private var circleCapabilityProbeID: UUID?
    @ObservationIgnored private var circleCapabilityPDSURL: URL?

    @ObservationIgnored private var _circleService: CircleService?

    /// Circle service using the current authenticated client
    var circleService: CircleService {
        get {
            if let _circleService {
                return _circleService
            }
            let service = CircleService(transport: GatewayCircleTransport(client: client))
            _circleService = service
            return service
        }
        set {
            _circleService = newValue
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

    @MainActor
    func installE2ECircleFixture(transport: E2ECircleTransport) {
        self.circleCapability = ProcessInfo.processInfo.arguments.contains("--circles-unsupported-pds") ? .unsupported : .supported
        self.circleSupportsImages = self.circleCapability == .supported && !ProcessInfo.processInfo.arguments.contains("--circles-images-unavailable")
        self.e2eCircleTransport = transport
        let service = CircleService(transport: transport)
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
        guard CatbirdFeatures.circlesSpaces else {
            circleCapability = .unknown
            return
        }
        guard AppStateManager.shared.lifecycle.appState === self else { return }
        let probeID = UUID()
        circleCapabilityProbeID = probeID
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

        let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID
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

    /// Resolve stable per-account logical device identifier (canonical lowercase UUID).
    @MainActor
    func resolvedMLSDeviceID() -> String {
        let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        let key = "blue.catbird.mls.deviceId.\(userDID.lowercased())"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            let trimmed = existing.hasPrefix("dev-") ? String(existing.dropFirst(4)) : existing
            if UUID(uuidString: trimmed) != nil {
                return trimmed.lowercased()
            }
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    /// Resolve granted OAuth scopes for Spaces eligibility checks (`I15`).
    @MainActor
    func resolveGrantedOAuthScopes() async -> [String] {
        let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        if let stored = defaults.stringArray(forKey: "blue.catbird.oauth.scopes.\(userDID.lowercased())"),
           !stored.isEmpty
        {
            return stored
        }
        return MLSAppGroupStorage.requiredSpacesScopes
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
                let mlsServiceDID = CatbirdGatewayConfiguration.current.mlsServiceDID
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
                    homeDsEndpoint: environment.endpointURL,
                    homeDsDid: bareHomeDsDid,
                    actorDeviceId: deviceId
                )

                let coordinator = try MLSClientCoordinator(
                    config: config,
                    keystore: keystore,
                    transport: transport
                )
                if let sharedDefaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) {
                    sharedDefaults.set(deviceId, forKey: "mlsDeviceId_\(coordinator.accountDidHash)")
                    sharedDefaults.set(homeDsEndpointString, forKey: "mlsHomeDsEndpoint_\(coordinator.accountDidHash)")
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

    /// Wipe local SQLCipher DB + Keychain items on sign-out (`I8`).
    @MainActor
    func wipeMLSOnSignOut() async {
        mlsCoordinatorInitTask?.cancel()
        mlsCoordinatorInitTask = nil
        let coordinator = mlsCoordinator
        mlsCoordinator = nil
        mlsBlockCoordinatorStorage = nil
        mlsConversations = []
        mlsConversationsDidChange += 1
        mlsSyncIncompleteConversationIDs = []
        mlsUnreadCount = 0
        try? await coordinator?.signOutAndWipe()
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
                logger.info("MLS: Device enrolled with post-quantum credentials (I16)")
            } catch {
                logger.warning("MLS: Device enrollment deferred (possibly offline): \(error.localizedDescription)")
            }
        }

        await reloadMLSConversations()
        scheduleBlockReconcileIfNeeded()
        logger.info("MLS: Initialized via MLSClientCoordinator")
    }

    /// Re-evaluate Spaces eligibility and trigger OAuth re-authorization if scopes are missing (`I15`).
    /// Explicitly invoked from the user-facing Spaces gate button after an opt-in attempt.
    @MainActor
    func reauthorizeSpacesForMLS() async {
        guard CatbirdFeatures.mlsChat else { return }
        let wasEnabled = ExperimentalSettings.shared.isMLSChatEnabled(for: userDID)
        if !wasEnabled {
            ExperimentalSettings.shared.enableMLSChat(for: userDID)
        }
        let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
        defaults.set(
            MLSAppGroupStorage.requiredSpacesScopes,
            forKey: "blue.catbird.oauth.scopes.\(userDID.lowercased())"
        )
        if let coordinator = await getOrOpenMLSCoordinator() {
            let scopes = await resolveGrantedOAuthScopes()
            if let status = try? await coordinator.checkSpacesEligibility(grantedScopes: scopes) {
                spacesEligibility = status
            }
            if spacesEligibility?.eligible == true {
                _ = try? await coordinator.enrollDevice(grantedScopes: scopes)
                await reloadMLSConversations()
            } else if !wasEnabled {
                ExperimentalSettings.shared.disableMLSChat(for: userDID)
                await prepareMLSStorageReset()
            }
        } else if !wasEnabled {
            ExperimentalSettings.shared.disableMLSChat(for: userDID)
        }
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
        } else if let storageRoot = try? MLSAppGroupStorage.defaultStorageRoot(),
                  let dbURL = try? MLSAppGroupStorage.databaseURL(storageRoot: storageRoot, accountDid: did)
        {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
            if let didHash = try? MLSAppGroupStorage.accountDidHash(for: did) {
                try? KeychainPlatformKeyStore().deleteAccountKeys(accountDidHash: didHash)
            }
        }

        try await AppStateManager.shared.authentication.removeAccount(did: did)

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
        circleCapability = .unknown
        _circleService = nil
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
