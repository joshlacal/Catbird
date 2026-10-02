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
    
    init(flowID: UUID = UUID(), uri: String, cid: String, name: String? = nil, creatorDID: String? = nil) {
        self.flowID = flowID
        self.uri = uri
        self.cid = cid
        self.name = name
        self.creatorDID = creatorDID
    }
    
    enum CodingKeys: String, CodingKey {
        case flowID
        case uri
        case cid
        case name
        case creatorDID
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.flowID = try container.decodeIfPresent(UUID.self, forKey: .flowID) ?? UUID()
        self.uri = try container.decode(String.self, forKey: .uri)
        self.cid = try container.decode(String.self, forKey: .cid)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.creatorDID = try container.decodeIfPresent(String.self, forKey: .creatorDID)
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

/// Manages pending starter pack onboarding context and post-auth finalization
@Observable
final class StarterPackOnboardingManager: @unchecked Sendable {
    static let shared = StarterPackOnboardingManager()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackOnboarding")
    private let storageKey = "blue.catbird.pendingStarterPackContext"
    private let defaults: UserDefaults
    
    private(set) var activeFlowID: UUID?
    private(set) var isFinalizing: Bool = false
    
    var pendingContext: StarterPackPendingContext? {
        didSet {
            saveToStorage()
        }
    }
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromStorage()
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
    }
    
    func clearPendingContext() {
        self.activeFlowID = nil
        self.pendingContext = nil
    }
    
    /// Finalizes starter pack join post-authentication by bulk following members and pinning feeds.
    /// Idempotent and recoverable: pendingContext is cleared only after every required mutation succeeds.
    @MainActor
    func finalizeStarterPackOnboarding(
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
        
        // 1. Fetch starter pack details
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
        
        // 2. Fetch all members from backing list (throw on pagination/HTTP failure)
        var memberItems: [AppBskyGraphDefs.ListItemView] = []
        if let listUri = packView.list?.uri {
            memberItems = try await StarterPackService.shared.fetchAllMembers(
                client: client,
                listUri: listUri
            )
        }
        
        // 3. Bulk follow members with via strong reference using StarterPackService (idempotent)
        var followedCount = 0
        if !memberItems.isEmpty {
            followedCount = try await StarterPackService.shared.followAll(
                client: client,
                members: memberItems,
                starterPack: packView,
                currentAccountDID: appState.userDID
            )
        }
        
        // 4. Pin feeds from the pack
        var pinnedFeedsCount = 0
        if let feeds = packView.feeds, !feeds.isEmpty {
            let prefs = try await appState.preferencesManager.getPreferences()
            var currentPinned = prefs.pinnedFeeds
            for feed in feeds {
                let feedURI = feed.uri.uriString()
                if !currentPinned.contains(feedURI) {
                    currentPinned.append(feedURI)
                    pinnedFeedsCount += 1
                }
            }
            if pinnedFeedsCount > 0 {
                try await appState.preferencesManager.setPinnedFeeds(currentPinned)
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
            if profile.joinedViaStarterPack == nil {
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
        
        // 6. Clear pending context ONLY after every required step has succeeded
        clearPendingContext()
        
        logger.info("Starter pack onboarding finalization completed: followed \(followedCount) members, pinned \(pinnedFeedsCount) feeds")
        return StarterPackFinalizationResult(
            followedCount: followedCount,
            pinnedFeedsCount: pinnedFeedsCount,
            updatedProfile: updatedProfile
        )
    }
}
