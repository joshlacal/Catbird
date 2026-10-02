import AVKit
import BluemojiKit
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

    /// URL handling for deep links
    @ObservationIgnored private(set) var urlHandler: URLHandler


    /// Current sanitized platform age signal from on-device regulatory checking
    var platformAgeSignal: PlatformAgeSignal = .none

    /// Regulatory checker for on-device platform regulatory preflight
    @ObservationIgnored let regulatoryChecker: any AgeRegulatoryChecking

    /// NUX announcement presenter
    @ObservationIgnored private(set) var nuxPresenter: NuxAnnouncementPresenter
    /// Shared renderer for inline Bluemoji custom emoji (verify + forge + cache).
    @ObservationIgnored let bluemojiRenderer = BluemojiRenderer()

    /// User preference settings
    var isAdultContentEnabled: Bool = false

    /// Used to track which tab was tapped twice to trigger scroll to top
    /// NOTE: This needs to be observable so UIKit controllers can react to it
    var tabTappedAgain: Int?

    /// Current user's profile data for optimistic updates
    @ObservationIgnored var currentUserProfile: AppBskyActorDefs.ProfileViewBasic?

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
    @MainActor @ObservationIgnored lazy var feedLibraryActions = FeedLibraryActions(appState: self)

    /// Feed feedback manager for custom feed interactions
    @ObservationIgnored let feedFeedbackManager = FeedFeedbackManager()

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

    /// Public access to theme manager
    var themeManager: ThemeManager {
        _themeManager
    }

    /// Public access to font manager
    var fontManager: FontManager {
        _fontManager
    }

    /// Navigation manager for handling navigation
    @ObservationIgnored let navigationManager = AppNavigationManager()

    /// Pending search request to be handled by the dedicated search tab
    @ObservationIgnored var pendingSearchRequest: SearchRequest?

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

    /// Unread count for the Messages tab badge
    var totalMessagesUnreadCount: Int {
        chatUnreadCount
    }

    /// Chat manager for handling Bluesky chat operations
    @ObservationIgnored let chatManager: ChatManager

    /// Heartbeat manager for chat push notification liveness
    @ObservationIgnored let chatHeartbeatManager = ChatHeartbeatManager()

    /// Network monitor for tracking connectivity status
    @ObservationIgnored let networkMonitor = NetworkMonitor()

    /// Onboarding manager for tracking user onboarding progress
    @ObservationIgnored let onboardingManager = OnboardingManager()

    // MARK: - Feed State

    /// Cache of prefetched feeds by type
    @ObservationIgnored private let prefetchedFeedCache = PrefetchedFeedCache()

    /// Flag to track if AuthManager initialization is complete
    @ObservationIgnored private var isAuthManagerInitialized = false

    // For task cancellation when needed
    @ObservationIgnored private var backgroundPollingTask: Task<Void, Never>?

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


    @MainActor
    init(
        userDID: String,
        client: ATProtoClient,
        regulatoryChecker: any AgeRegulatoryChecking = AppleAgeRangeAdapter.shared
    ) {
        self.userDID = userDID
        self.client = client
        self.regulatoryChecker = regulatoryChecker
        logger.info("AppState initializing for account: \(userDID)")
        appSettings.configure(accountDID: userDID)

        urlHandler = URLHandler()
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

        // Initialize post hiding manager (preferences manager will be set after auth)
        postHidingManager = PostHidingManager()

        // Initialize chat manager with authenticated client
        chatManager = ChatManager(client: client, appState: nil)


        onboardingManager.configure(accountDID: userDID)
        nuxPresenter.configure(with: self)
        urlHandler.configure(with: self)
        urlHandler.externalIntentPresenter.flushPendingIntent(with: self)
        // Load user settings
        if let storedContentSetting = AppSettingsModel.boolValue(
            for: "isAdultContentEnabled",
            accountDID: userDID,
            defaults: sharedDefaults
        ) {
            isAdultContentEnabled = storedContentSetting
        }

        // Configure notification manager with app state reference (skip for FaultOrdering)
        notificationManager.configure(with: self)

        // Initialize blocked-author identity hydrator now that `self` is fully
        // initialized (its fetcher closure captures `self` weakly).
        blockedAuthorHydrator = makeBlockedAuthorHydrator()

        // NOTE: Auth state observation removed in new architecture
        // Client is passed in already authenticated, no need to observe state changes
        // Managers are initialized with the client in init

        // Set up circular references after initialization
        postManager.updateAppState(self)
        composerDraftManager.updateAppState(self)
        chatManager.updateAppState(self)

        // Apply initial theme settings immediately from UserDefaults
        // This ensures proper theme is applied even before SwiftData is fully initialized
        appSettings.applyInitialThemeSettings(to: _themeManager)

        // Apply initial font settings immediately from UserDefaults
        appSettings.applyInitialFontSettings(to: _fontManager)

        // Set up theme/font change observation on main actor
        Task { @MainActor in
            setupThemeAndFontObservation()
        }

        // Passive on-device regulatory preflight without network calls or user prompts
        Task { @MainActor [weak self] in
            guard let self else { return }
            let signal = await self.regulatoryChecker.preflight()
            self.platformAgeSignal = signal
        }
        // NOTE: Settings observation is set up later in initializePreferencesManager
        // to avoid duplicate observers

        logger.debug("AppState initialization complete")
    }

    deinit {
        // Clean up notification observers
        NotificationCenter.default.removeObserver(self)
        backgroundPollingTask?.cancel()
    }

    /// Cleanup method called when this AppState is evicted from cache
    /// This cancels long-running tasks and releases resources without deallocating the object
    @MainActor
    func cleanup() {
        logger.info("🧹 Cleaning up AppState for user: \(self.userDID)")

        platformAgeSignal = .none

        // Cancel long-running tasks
        backgroundPollingTask?.cancel()
        backgroundPollingTask = nil

        // Stop the list poller AND every per-conversation message poller; a
        // surviving message poll loop retains self and keeps polling with the
        // evicted account's stale client.
        chatManager.stopAllPolling()

        logger.debug("AppState cleanup complete")
    }

    // MARK: - Background Polling

    private func startBackgroundPolling() {
        backgroundPollingTask = Task(priority: .background) {
            while !Task.isCancelled {
                await withTaskGroup(of: Void.self) { group in
                    // Prune old feed models
                    group.addTask {
                        FeedModelContainer.shared.pruneOldModels(olderThan: 1800)
                    }

                    // Refresh preferences
                    group.addTask {
                        if await self.isAuthenticated {
                            do {
                                try await self.preferencesManager.fetchPreferences(forceRefresh: true)
                                await MainActor.run {
                                    self.nuxPresenter.evaluateAndPresentIfNeeded(
                                        isWelcomeShowing: self.onboardingManager.showWelcomeSheet
                                    )
                                }
                            } catch {
                                self.logger.error(
                                    "Error during periodic preferences refresh: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                }

                // Wait for 5 minutes before the next poll
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    // MARK: - App Initialization

    @MainActor
    func initialize() async {
        logger.info("🚀 Starting AppState.initialize() for user: \(self.userDID)")

        // Normal initialization path
        // Configure Nuke image pipeline with GIF support
        configureImagePipeline()

        configureURLHandler()

        // NOTE: Auth initialization removed - client is already authenticated and passed in init
        // All managers were initialized with the client in init

        // Update manager client references (should already be set from init, but ensure consistency)
        logger.info("Updating manager clients for authenticated user")

        postManager.updateClient(client)
        preferencesManager.updateClient(client)
        await notificationManager.updateClient(client)
        graphManager = GraphManager(atProtoClient: client)
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(client)
        listManager.updateAppState(self)

        chatManager.updateAppState(self)
        await chatManager.updateClient(client)
        updateChatUnreadCount()

        // Setup other components as needed (skip for FaultOrdering)
        startBackgroundPolling()
        setupNotifications()
        setupChatObservers()

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
            Task {
                // Load current user profile for optimistic updates
                await self.loadCurrentUserProfile(did: userDID)

                await AppStateManager.shared.authentication.refreshAvailableAccounts()

                // Synchronize server preferences with app settings
                do {
                    try await preferencesManager.fetchPreferences(forceRefresh: true)
                    try await preferencesManager.syncPreferencesWithAppSettings(self)
                    logger.info("Successfully synchronized server preferences with app settings")
                } catch {
                    logger.error("Failed to synchronize preferences: \(error.localizedDescription)")
                }

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
        isTransitioningAccounts = true
        platformAgeSignal = .none

        Task { @MainActor [weak self] in
            guard let self else { return }
            let signal = await self.regulatoryChecker.preflight()
            self.platformAgeSignal = signal
        }
        // Clear old prefetched data and any shadowed interactions
        await prefetchedFeedCache.clear()
        await postShadowManager.clearAll()

        // Update client references in all managers before kicking off parallel refresh work
        postManager.updateClient(client)
        preferencesManager.updateClient(client)
        await notificationManager.updateClient(client)

        chatManager.updateAppState(self) // Wire AppState reference to ChatManager
        await chatManager.updateClient(client) // Update ChatManager client

        // `ChatManager.updateClient` only clears + reloads when its own last-known
        // DID differs from the freshly-fetched one. For a CACHED account being
        // resumed here, those are always the same DID (it's this account's own
        // ChatManager instance from its last active session) — so that internal
        // check is always a no-op in this exact context, and neither of the two
        // downstream UI triggers cover the gap either: ChatTabView is torn down
        // and recreated by its `.id(appState.userDID)` fence rather than mutated
        // in place, so its `.onChange(of: appState.userDID)` refresh never fires;
        // and its `onAppear` only refreshes when `acceptedConversations.isEmpty`,
        // which is false here (stale-but-present data from last time). Without an
        // explicit unconditional refresh, the Messages tab shows whatever was
        // cached from this account's last active session — stale threads, wrong
        // avatars, missed messages — until the next background poll tick or a
        // manual pull-to-refresh.
        await chatManager.loadConversations(refresh: true)
        updateChatUnreadCount() // Update chat unread count

        // Client is non-optional now, so we can use it directly
        graphManager = GraphManager(atProtoClient: client)
        // Fresh hydrator (empty cache) so the previous account's blocked-author
        // identities never leak into this one.
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(client)
        listManager.updateAppState(self)

        // Run the heavyweight refresh in the background to keep the UI responsive
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPostSwitchRefreshWork()
        }

        // Drop the transition overlay quickly; refresh work continues in the background
        isTransitioningAccounts = false
    }

    @MainActor
    private func runPostSwitchRefreshWork() async {
        async let preferencesTask: Void = refreshPreferencesAfterAccountSwitch()
        async let profileTask: Void = loadCurrentUserProfile(did: userDID)

        // Pre-warm following feed without blocking the main transition
        Task(priority: .userInitiated) { [weak self] in
            await self?.prewarmFollowingFeed()
        }

        // Trigger explicit feed data load for all active feeds
        // This ensures that even if we preserved cache, we check for new content
        // and that the UI has data to show if the cache was empty.
        Task(priority: .userInitiated) {
            await FeedStateStore.shared.triggerPostAuthenticationFeedLoad()
        }

        await preferencesTask
        await profileTask
    }

    @MainActor
    private func refreshPreferencesAfterAccountSwitch() async {
        do {
            try await preferencesManager.fetchPreferences(forceRefresh: true)
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

    /// Pre-warms the Following feed for the new account to enable smooth crossfade
    @MainActor
    private func prewarmFollowingFeed() async {
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

    // MARK: - User Settings

    /// Toggles adult content setting
    func toggleAdultContent() {
        isAdultContentEnabled.toggle()
        sharedDefaults.set(isAdultContentEnabled, forKey: scopedSharedDefaultsKey("isAdultContentEnabled"))
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

    // MARK: - User Profile Methods

    /// Load the current user's profile for optimistic updates
    @MainActor
    private func loadCurrentUserProfile(did: String) async {
        guard let client = atProtoClient else {
            logger.error("❌ Cannot load profile - atProtoClient is nil")
            return
        }

        do {
            let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: ATIdentifier(string: did))
            )

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

    @MainActor
    func configureURLHandler() {
        urlHandler.navigateAction = { [weak self] destination, tabIndex in
            self?.navigationManager.navigate(to: destination, in: tabIndex)
        }
    }

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
        preferencesManager.configure(accountDID: userDID)
        preferencesManager.setModelContext(modelContext)
        appSettings.initialize(with: modelContext, accountDID: userDID)
        logger.debug("Initialized PreferencesManager and AppSettings with ModelContext")

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
        ) { [weak self] _ in
            guard let self = self else { return }

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
                guard let self = self else { return }

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

                // Trigger SwiftUI updates
                self.themeDidChange += 1
                self.fontDidChange += 1

                // Update URL handler with new browser preference
                self.urlHandler.useInAppBrowser = self.appSettings.useInAppBrowser

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
    private func setupNotifications() {
        // Set the notification manager as the delegate for UNUserNotificationCenter
        UNUserNotificationCenter.current().delegate = notificationManager

        // Ensure widget has initial data - force update after a delay to allow app to fully initialize
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self = self else { return }
            self.notificationManager.updateWidgetUnreadCount(self.notificationManager.unreadCount)
            self.logger.info(
                "Initializing widget data at app startup with count: \(self.notificationManager.unreadCount)"
            )
        }

        // Configure notification manager with app state reference for navigation
        notificationManager.configure(with: self)

        // Check current notification status
        Task {
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
                Task { [weak self] in
                    await self?.notificationManager.checkUnreadNotifications()
                }
            }
        #elseif os(macOS)
            NotificationCenter.default.addObserver(
                forName: NSApplication.willBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.notificationManager.checkUnreadNotifications()
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

    /// Setup chat observers and background polling for unread messages
    private func setupChatObservers() {
        // Set up callback for when chat unread count changes
        chatManager.onUnreadCountChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateChatUnreadCount()
            }
        }

        // Keep chat polling alive even when the chat tab isn't visible.
        // ChatManager owns the single listConvos poll loop (with rate-limit
        // backoff); each tick drives the unread badge here.
        chatManager.onConversationsPolled = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, case .authenticated = self.authState else { return }
                self.updateChatUnreadCount()
            }
        }
        chatManager.startConversationsPolling()

        // Update chat unread count initially
        Task { @MainActor in
            updateChatUnreadCount()
        }

        // Also update when app comes to foreground
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
                guard let self = self else { return }
                self.chatManager.startConversationsPolling()
                await self.chatManager.loadConversations(refresh: true)
                self.updateChatUnreadCount()
            }
        }
    }

    @objc private func handleNotificationsMarkedAsSeen() {
        notificationManager.updateUnreadCountAfterSeen()
    }

    /// Syncs notification-related user data with the server
    func syncNotificationData() async {
        await notificationManager.syncAllUserData()
    }

    // MARK: - Authentication Methods (for backward compatibility)

    /// Logs out the current user (delegates to AppStateManager's authentication manager)
    @MainActor
    func handleLogout() async throws {
        logger.info("Logout requested - delegating to AppStateManager")

        // Clear preferences before logging out
        await preferencesManager.clearAllPreferences()
        logger.info("User preferences cleared during logout")

        // Perform the actual logout via AppStateManager
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

        try await AppStateManager.shared.authentication.removeAccount(did: did)

        // Check if we still have any accounts
        if isAuthenticated {
            await refreshAfterAccountSwitch()
        }
    }

    /// Updates the client reference when reusing a cached AppState or after E2E re-login
    /// This ensures all managers use the current authenticated client, not a stale one
    /// CRITICAL: Must be called when transitioning to a cached AppState to prevent API failures
    @MainActor
    func updateClient(_ newClient: ATProtoClient) {
        logger.info("Updating AppState client reference for user: \(self.userDID)")
        client = newClient

        // Update all managers that hold client references
        postManager.updateClient(newClient)
        preferencesManager.updateClient(newClient)
        graphManager = GraphManager(atProtoClient: newClient)
        // Token refresh / re-login: fresh hydrator so stale-token failures don't
        // poison the identity cache for the (unchanged) account.
        blockedAuthorHydrator = makeBlockedAuthorHydrator()
        listManager.updateClient(newClient)
        // Update notification manager (async operation)
        Task {
            await notificationManager.updateClient(newClient)
        }

        // Update chat manager (async operation)
        Task {
            await chatManager.updateClient(newClient)
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

    // MARK: - Post Composer Presentation

    /// Present the post composer for creating a new post, reply, or quote post
    @MainActor
    func presentPostComposer(
        parentPost: AppBskyFeedDefs.PostView? = nil,
        quotedPost: AppBskyFeedDefs.PostView? = nil
    ) {
        presentPostComposer(initialText: nil, parentPost: parentPost, quotedPost: quotedPost)
    }

    /// Present the post composer with optional prefilled initial text, preserving reply or quote context
    @MainActor
    func presentPostComposer(
        initialText: String?,
        parentPost: AppBskyFeedDefs.PostView? = nil,
        quotedPost: AppBskyFeedDefs.PostView? = nil
    ) {
        // Track quote interaction for feed feedback
        if let quotedPost = quotedPost {
            feedFeedbackManager.trackQuote(postURI: quotedPost.uri)
        }

        // Create the UIKit-backed post composer view with either a parent post (for reply) or quoted post
        let composerView = PostComposerViewUIKit(
            parentPost: parentPost,
            quotedPost: quotedPost,
            initialText: initialText,
            appState: self
        )
        .applyAppStateEnvironment(self)

        #if os(iOS)
            // Create a UIHostingController for the SwiftUI view
            let hostingController = UIHostingController(rootView: composerView)

            // Configure presentation style
            hostingController.modalPresentationStyle = .formSheet
            // Allow swipe-to-dismiss to enable draft auto-persist on dismiss
            hostingController.isModalInPresentation = false

            // Present the composer using the appropriate window system
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(hostingController, animated: true)
            }
        #elseif os(macOS)
            // On macOS, present as a new window
            let hostingController = NSHostingController(rootView: composerView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Post"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 400))
            window.center()
            window.makeKeyAndOrderFront(nil)
        #endif
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

    // MARK: - Content Filtering Helper

    /// Build FeedTunerSettings from current user preferences
    /// This ensures consistent filtering across feeds, threads, profiles, and search
    @MainActor
    func buildFilterSettings() async -> FeedTunerSettings {
        // Get current user DID (AppState represents single account)
        let currentUserDid = userDID

        // Get moderation preferences from PreferencesManager
        var contentLabelPrefs: [ContentLabelPreference] = []
        var adultContentEnabled = false
        var preferredLanguages: [String] = []
        var feedViewPref: FeedViewPreference?

        let preferences = try? await preferencesManager.getPreferences()
        contentLabelPrefs = preferences?.contentLabelPrefs ?? []
        adultContentEnabled = preferences?.adultContentEnabled ?? false
        preferredLanguages = preferences?.contentLanguages ?? ["en"]
        feedViewPref = preferences?.feedViewPref

        // Get muted and blocked users from GraphManager
        let mutedUsers = graphManager.muteCache
        let blockedUsers = graphManager.blockCache

        // Get feed filter settings (quick filters - these override server prefs)
        let hideRepliesQuick = feedFilterSettings.hideReplies
        let hideRepostsQuick = feedFilterSettings.hideReposts
        let hideQuotePostsQuick = feedFilterSettings.hideQuotePosts
        let hideLinks = feedFilterSettings.hideLinks
        let onlyTextPosts = feedFilterSettings.onlyTextPosts
        let onlyMediaPosts = feedFilterSettings.onlyMediaPosts

        // Get hidden posts from PostHidingManager
        let hiddenPosts = postHidingManager.hiddenPosts

        // Build settings - combine quick filters with server-synced preferences
        return FeedTunerSettings(
            hideReplies: hideRepliesQuick || (feedViewPref?.hideReplies ?? false),
            hideRepliesByUnfollowed: feedViewPref?.hideRepliesByUnfollowed ?? false,
            hideRepliesByLikeCount: feedViewPref?.hideRepliesByLikeCount,
            hideReposts: hideRepostsQuick || (feedViewPref?.hideReposts ?? false),
            hideQuotePosts: hideQuotePostsQuick || (feedViewPref?.hideQuotePosts ?? false),
            hideNonPreferredLanguages: !preferredLanguages.isEmpty && preferredLanguages != ["en"],
            preferredLanguages: preferredLanguages,
            mutedUsers: mutedUsers,
            blockedUsers: blockedUsers,
            hideLinks: hideLinks,
            onlyTextPosts: onlyTextPosts,
            onlyMediaPosts: onlyMediaPosts,
            contentLabelPreferences: contentLabelPrefs,
            hideAdultContent: !adultContentEnabled,
            hiddenPosts: hiddenPosts,
            currentUserDid: currentUserDid
        )
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

private extension AppState {
    var sharedDefaults: UserDefaults {
        AppSettingsModel.sharedDefaults()
    }

    func scopedSharedDefaultsKey(_ baseKey: String) -> String {
        AppSettingsModel.scopedKey(baseKey, accountDID: userDID)
    }
}
