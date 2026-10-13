import Foundation
import OSLog
import Petrel
import SwiftUI

/// Represents a pending starter pack join context captured before or during sign-up
struct StarterPackPendingContext: Codable, Sendable, Equatable {
    let flowID: UUID
    let uri: String
    let cid: String
    let name: String?
    let creatorDID: String?
    let listUri: String?
    let feedUris: [String]?
    
    init(
        flowID: UUID = UUID(),
        uri: String,
        cid: String,
        name: String? = nil,
        creatorDID: String? = nil,
        listUri: String? = nil,
        feedUris: [String]? = nil
    ) {
        self.flowID = flowID
        self.uri = uri
        self.cid = cid
        self.name = name
        self.creatorDID = creatorDID
        self.listUri = listUri
        self.feedUris = feedUris
    }
    
    enum CodingKeys: String, CodingKey {
        case flowID
        case uri
        case cid
        case name
        case creatorDID
        case listUri
        case feedUris
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.flowID = try container.decodeIfPresent(UUID.self, forKey: .flowID) ?? UUID()
        self.uri = try container.decode(String.self, forKey: .uri)
        self.cid = try container.decode(String.self, forKey: .cid)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.creatorDID = try container.decodeIfPresent(String.self, forKey: .creatorDID)
        self.listUri = try container.decodeIfPresent(String.self, forKey: .listUri)
        self.feedUris = try container.decodeIfPresent([String].self, forKey: .feedUris)
    }
}

/// Result of finalising starter pack onboarding
struct StarterPackFinalizationResult: Sendable, Equatable {
    let followedCount: Int
    let pinnedFeedsCount: Int
    let updatedProfile: Bool
    
    init(followedCount: Int, pinnedFeedsCount: Int, updatedProfile: Bool) {
        self.followedCount = followedCount
        self.pinnedFeedsCount = pinnedFeedsCount
        self.updatedProfile = updatedProfile
    }
}

/// Manages pending starter pack onboarding context and post-auth finalization.
/// Main-actor isolated: finalization and the auth observer both change its state.
@MainActor
@Observable
final class StarterPackOnboardingManager {
    static let shared = StarterPackOnboardingManager()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackOnboarding")
    private let storageKey = "blue.catbird.pendingStarterPackContext"
    private let defaults: UserDefaults
    
    private(set) var activeFlowID: UUID?
    private(set) var isFinalizing: Bool = false
    private(set) var activeFinalizationTask: Task<StarterPackFinalizationResult, Error>?
    private(set) var storedResult: StarterPackFinalizationResult?
    private(set) var storedError: String?
    var pendingContext: StarterPackPendingContext? {
        didSet {
            saveToStorage()
        }
    }
    
    @ObservationIgnored private var authObserverTask: Task<Void, Never>?
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromStorage()
        startAuthObservation()
    }
    
    deinit {
        authObserverTask?.cancel()
    }
    
    private func loadFromStorage() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(StarterPackPendingContext.self, from: data)
            self.pendingContext = decoded
            self.activeFlowID = decoded.flowID
            logger.debug("Loaded pending starter pack context: \(decoded.uri), flowID: \(decoded.flowID.uuidString)")
        } catch {
            logger.error("Failed to decode pending starter pack context: \(error)")
            defaults.removeObject(forKey: storageKey)
        }
    }
    
    private func saveToStorage() {
        if let pendingContext {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(pendingContext)
                defaults.set(data, forKey: storageKey)
                logger.debug("Saved pending starter pack context: \(pendingContext.uri)")
            } catch {
                logger.error("Failed to encode pending starter pack context: \(error)")
            }
        } else {
            defaults.removeObject(forKey: storageKey)
            logger.debug("Cleared pending starter pack context from storage")
        }
    }
    
    func setActiveFlowID(_ flowID: UUID?) {
        self.activeFlowID = flowID
    }
    
    func setPendingContext(_ context: StarterPackPendingContext) {
        self.activeFlowID = context.flowID
        self.pendingContext = context
        resetStoredState()
    }
    
    func clearPendingContext() {
        self.activeFlowID = nil
        self.pendingContext = nil
        resetStoredState()
    }
    
    func resetStoredState() {
        self.storedResult = nil
        self.storedError = nil
        self.activeFinalizationTask?.cancel()
        self.activeFinalizationTask = nil
    }
    
    /// Resets the stored result and cancels a running finalization whenever the signed-in
    /// account changes. `.shared` is often first used after launch has signed in, so the
    /// observer starts from the account signed in now, not from nil: otherwise the first
    /// sign-out (nil after nil) would keep the previous account's result and finalization.
    /// The current state is read and the stream subscribed together on the main actor, where
    /// AuthenticationManager.updateState runs, so no change falls between them.
    private func startAuthObservation() {
        let authentication = AppStateManager.shared.authentication
        let states = authentication.stateChanges
        let initialDID = authentication.state.userDID
        authObserverTask = Task { @MainActor [weak self] in
            var lastDID = initialDID
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                let currentDID = state.userDID
                if currentDID != lastDID {
                    lastDID = currentDID
                    self.resetStoredState()
                }
            }
        }
    }
    
    /// Finalizes starter pack join post-authentication by bulk following members and pinning feeds.
    /// Idempotent and recoverable: pendingContext is cleared only after every required mutation succeeds.
    @MainActor
    func finalizeStarterPackOnboarding(
        client: ATProtoClient,
        appState: AppState,
        context: StarterPackPendingContext
    ) async throws -> StarterPackFinalizationResult {
        // Reuse in-flight finalization task if one is already running for this flow
        if let existingTask = activeFinalizationTask, activeFlowID == context.flowID {
            return try await existingTask.value
        }
        
        let task = Task<StarterPackFinalizationResult, Error> { @MainActor in
            do {
                let result = try await self.performFinalization(client: client, appState: appState, context: context)
                self.storedResult = result
                self.storedError = nil
                self.activeFinalizationTask = nil
                return result
            } catch {
                self.storedError = error.localizedDescription
                self.activeFinalizationTask = nil
                throw error
            }
        }
        self.activeFinalizationTask = task
        return try await task.value
    }
    
    @MainActor
    private func performFinalization(
        client: ATProtoClient,
        appState: AppState,
        context: StarterPackPendingContext
    ) async throws -> StarterPackFinalizationResult {
        // 0. Validate that pending context and active flow token match to prevent stale/canceled context execution
        guard let currentPending = pendingContext, currentPending.flowID == context.flowID else {
            logger.warning("Stale or mismatched starter pack context flowID: \(context.flowID.uuidString), current: \(self.pendingContext?.flowID.uuidString ?? "none")")
            throw NSError(
                domain: "StarterPackOnboarding",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Starter pack onboarding context is stale or invalid"]
            )
        }
        
        guard !isFinalizing else {
            logger.warning("Starter pack onboarding finalization already in progress for flow: \(context.flowID.uuidString)")
            throw NSError(
                domain: "StarterPackOnboarding",
                code: 429,
                userInfo: [NSLocalizedDescriptionKey: "Starter pack onboarding is already in progress"]
            )
        }
        
        isFinalizing = true
        defer {
            isFinalizing = false
        }
        
        logger.info("Finalizing starter pack onboarding for pack: \(context.uri) (flow: \(context.flowID.uuidString))")
        
        guard let starterPackURI = try? ATProtocolURI(uriString: context.uri),
              let starterPackCID = try? CID.parse(context.cid) else {
            logger.error("Invalid starter pack URI or CID in pending context")
            throw NSError(
                domain: "StarterPackOnboarding",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid starter pack reference"]
            )
        }
        
        let strongRef = ComAtprotoRepoStrongRef(uri: starterPackURI, cid: starterPackCID)
        
        // 1 & 2: Fetch members and feed URIs (skip getStarterPack if listUri is already cached)
        var memberItems: [AppBskyGraphDefs.ListItemView] = []
        var feedURIs: [String] = []
        
        if let listUriStr = context.listUri, let listUri = try? ATProtocolURI(uriString: listUriStr) {
            memberItems = try await StarterPackService.shared.fetchAllMembers(
                client: client,
                listUri: listUri
            )
            feedURIs = context.feedUris ?? []
        } else {
            let getPackParams = AppBskyGraphGetStarterPack.Parameters(starterPack: starterPackURI)
            let (packCode, packData) = try await client.app.bsky.graph.getStarterPack(input: getPackParams)
            
            guard packCode == 200, let packView = packData?.starterPack else {
                logger.error("Failed to fetch starter pack details: HTTP \(packCode)")
                throw NSError(
                    domain: "StarterPackOnboarding",
                    code: packCode,
                    userInfo: [NSLocalizedDescriptionKey: "Starter pack unavailable (HTTP \(packCode))"]
                )
            }
            
            if let listUri = packView.list?.uri {
                memberItems = try await StarterPackService.shared.fetchAllMembers(
                    client: client,
                    listUri: listUri
                )
            }
            feedURIs = packView.feeds?.map { $0.uri.uriString() } ?? []
        }
        
        // 3. Overlap preference pin sync (not a repo write) with bulk follow repo operations
        async let pinFeedsTask: Int = {
            guard !feedURIs.isEmpty else { return 0 }
            let prefs = try await appState.preferencesManager.getPreferences()
            var currentPinned = prefs.pinnedFeeds
            var addedCount = 0
            for feedURI in feedURIs {
                if !currentPinned.contains(feedURI) {
                    currentPinned.append(feedURI)
                    addedCount += 1
                }
            }
            if addedCount > 0 {
                try await appState.preferencesManager.setPinnedFeeds(currentPinned)
            }
            return addedCount
        }()
        
        // 4. Bulk follow members with via strong reference using StarterPackService (idempotent)
        var followedCount = 0
        if !memberItems.isEmpty {
            let eligible = StarterPackService.shared.filterEligibleMembers(
                memberItems,
                currentAccountDID: appState.userDID
            )
            let dids = eligible.map { $0.subject.did }
            if !dids.isEmpty {
                followedCount = try await StarterPackService.shared.bulkFollow(
                    client: client,
                    dids: dids,
                    via: strongRef,
                    accountDID: appState.userDID
                )
            }
        }
        // 5. Update profile with joinedViaStarterPack
        var updatedProfile = false
        let getRecordParams = ComAtprotoRepoGetRecord.Parameters(
            repo: try ATIdentifier(string: appState.userDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self")
        )
        let (getRecordCode, getRecordOutput) = try await client.com.atproto.repo.getRecord(input: getRecordParams)
        
        if getRecordCode == 200, let existingRecord = getRecordOutput,
           let profile = existingRecord.value.decoded(AppBskyActorProfile.self) {
            // Attribution is public, so only stamp profiles created in this sign-up, never
            // an existing account that signed in from a starter pack link.
            let isNewProfile = profile.createdAt.map { Date().timeIntervalSince($0.date) < 24 * 60 * 60 } ?? false
            if profile.joinedViaStarterPack == nil, isNewProfile {
                let updated = AppBskyActorProfile(
                    displayName: profile.displayName,
                    description: profile.description,
                    pronouns: profile.pronouns,
                    website: profile.website,
                    avatar: profile.avatar,
                    banner: profile.banner,
                    labels: profile.labels,
                    joinedViaStarterPack: strongRef,
                    pinnedPost: profile.pinnedPost,
                    createdAt: profile.createdAt
                )
                let putRecordInput = ComAtprotoRepoPutRecord.Input(
                    repo: try ATIdentifier(string: appState.userDID),
                    collection: try NSID(nsidString: "app.bsky.actor.profile"),
                    rkey: try RecordKey(keyString: "self"),
                    record: ATProtocolValueContainer.knownType(updated),
                    swapRecord: existingRecord.cid
                )
                let (putCode, _) = try await client.com.atproto.repo.putRecord(input: putRecordInput)
                guard putCode >= 200 && putCode < 300 else {
                    logger.error("Failed to update profile joinedViaStarterPack: HTTP \(putCode)")
                    throw NSError(
                        domain: "StarterPackOnboarding",
                        code: putCode,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to update profile with starter pack attribution (HTTP \(putCode))"]
                    )
                }
            }
            updatedProfile = true
        } else if getRecordCode == 404 || getRecordOutput == nil {
            // Profile record does not exist yet (e.g. brand new account). Create it.
            let newProfile = AppBskyActorProfile(
                displayName: nil,
                description: nil,
                pronouns: nil,
                website: nil,
                avatar: nil,
                banner: nil,
                labels: nil,
                joinedViaStarterPack: strongRef,
                pinnedPost: nil,
                createdAt: ATProtocolDate(date: Date())
            )
            let putRecordInput = ComAtprotoRepoPutRecord.Input(
                repo: try ATIdentifier(string: appState.userDID),
                collection: try NSID(nsidString: "app.bsky.actor.profile"),
                rkey: try RecordKey(keyString: "self"),
                record: ATProtocolValueContainer.knownType(newProfile)
            )
            let (putCode, _) = try await client.com.atproto.repo.putRecord(input: putRecordInput)
            guard putCode >= 200 && putCode < 300 else {
                logger.error("Failed to create profile with joinedViaStarterPack: HTTP \(putCode)")
                throw NSError(
                    domain: "StarterPackOnboarding",
                    code: putCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create profile with starter pack attribution (HTTP \(putCode))"]
                )
            }
            updatedProfile = true
        } else {
            logger.error("Failed to fetch profile for starter pack update: HTTP \(getRecordCode)")
            throw NSError(
                domain: "StarterPackOnboarding",
                code: getRecordCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch profile record (HTTP \(getRecordCode))"]
            )
        }
        
        // 6. Wait for feed pinning before clearing pending context
        let pinnedFeedsCount = try await pinFeedsTask
        
        // 7. Clear pending context ONLY after every required step has succeeded
        clearPendingContext()
        logger.info("Starter pack onboarding finalization completed: followed \(followedCount) members, pinned \(pinnedFeedsCount) feeds")
        return StarterPackFinalizationResult(
            followedCount: followedCount,
            pinnedFeedsCount: pinnedFeedsCount,
            updatedProfile: updatedProfile
        )
    }
}
