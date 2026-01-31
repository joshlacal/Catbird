import CatbirdMLSService
//
//  MLSMemberManagementViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/21/24.
//

import Foundation
import Petrel
import Observation
import OSLog
import Combine
import GRDB
import CatbirdMLSCore

/// ViewModel for managing members in an MLS conversation
@Observable
final class MLSMemberManagementViewModel {
    // MARK: - Properties

    /// Current conversation
    private(set) var conversation: BlueCatbirdMlsDefs.ConvoView?

    /// Members in the conversation (server or local)
    private(set) var members: [BlueCatbirdMlsDefs.MemberView] = []

    /// Grouped members by user DID (combines multiple devices per user)
    /// Sorted by join date (oldest first) with stable secondary sort by userDid
    var groupedMembers: [MLSGroupedMember] {
        // Group members by userDid (MLS tracks devices but UI should show users)
        let grouped = Dictionary(grouping: members) { member in
            member.userDid.description
        }

        return grouped.map { userDid, devices in
            MLSGroupedMember(
                userDid: userDid,
                devices: devices,
                isAdmin: devices.contains { $0.isAdmin },
                isCreator: devices.contains { member in
                    guard let conversation = conversation else { return false }
                    return member.did.description == conversation.creator.description
                },
                firstJoinedAt: devices.compactMap { $0.joinedAt.date }.min() ?? Date()
            )
        }.sorted { lhs, rhs in
            // Primary sort: by join date (oldest first)
            // Secondary sort: by userDid for stability when dates are equal
            if lhs.firstJoinedAt == rhs.firstJoinedAt {
                return lhs.userDid < rhs.userDid
            }
            return lhs.firstJoinedAt < rhs.firstJoinedAt
        }
    }

    /// Loading states
    private(set) var isLoadingMembers = false
    private(set) var isAddingMembers = false
    private(set) var isRemovingMember = false

    /// Error state
    private(set) var error: Error?

    /// Conversation ID
    let conversationId: String
    /// Current user DID (used for local DB lookups)
    private let currentUserDid: String

    /// Members to add (DIDs)
    private(set) var pendingMembers: [String] = []

    /// Search query for finding new members
    var memberSearchQuery = "" {
        didSet {
            if memberSearchQuery != oldValue {
                searchTask?.cancel()
                searchTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        await searchMembers()
                    } catch {
                        // Task cancelled - ignore
                    }
                }
            }
        }
    }

    /// Search results
    private(set) var searchResults: [MLSParticipantViewModel] = []
    
    /// MLS opt-in status for search results (DID -> isOptedIn)
    private(set) var participantOptInStatus: [String: Bool] = [:]

    /// Whether search is in progress
    private(set) var isSearching = false

    /// Debounce task for search
    private var searchTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let database: MLSDatabase
    private let apiClient: MLSAPIClient
    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMemberManagementViewModel")

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()
    private let membersUpdatedSubject = PassthroughSubject<[BlueCatbirdMlsDefs.MemberView], Never>()
    private let conversationUpdatedSubject = PassthroughSubject<BlueCatbirdMlsDefs.ConvoView, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

    /// Publisher for member updates
    var membersUpdatedPublisher: AnyPublisher<[BlueCatbirdMlsDefs.MemberView], Never> {
        membersUpdatedSubject.eraseToAnyPublisher()
    }

    /// Publisher for conversation updates
    var conversationUpdatedPublisher: AnyPublisher<BlueCatbirdMlsDefs.ConvoView, Never> {
        conversationUpdatedSubject.eraseToAnyPublisher()
    }

    /// Publisher for errors
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(
        conversationId: String,
        currentUserDid: String,
        database: MLSDatabase,
        apiClient: MLSAPIClient,
        conversationManager: MLSConversationManager
    ) {
        self.conversationId = conversationId
        self.currentUserDid = currentUserDid
        self.database = database
        self.apiClient = apiClient
        self.conversationManager = conversationManager
        logger.debug("MLSMemberManagementViewModel initialized for conversation: \(conversationId)")
    }

    // MARK: - Public Methods

    /// Load conversation details and members
    @MainActor
    func loadMembers() async {
        guard !isLoadingMembers else { return }

        isLoadingMembers = true
        error = nil

        do {
            // First try to get conversation from manager cache (most efficient)
            if let cachedConvo = conversationManager.conversations[conversationId] {
                conversation = cachedConvo
                members = cachedConvo.members
                conversationUpdatedSubject.send(cachedConvo)
                membersUpdatedSubject.send(cachedConvo.members)
                logger.info("👥 Loaded \(cachedConvo.members.count) members from cache")
            } else {
                // Fallback: sync with server and retry
                logger.info("👥 Conversation not in cache, syncing with server for members...")
                try await Task.detached(priority: .userInitiated) {
                    try await self.conversationManager.syncWithServer()
                }.value

                if let syncedConvo = conversationManager.conversations[conversationId] {
                    conversation = syncedConvo
                    members = syncedConvo.members
                    conversationUpdatedSubject.send(syncedConvo)
                    membersUpdatedSubject.send(syncedConvo.members)
                    logger.info("✅ Loaded \(syncedConvo.members.count) members after sync")
                } else {
                    throw MLSError.conversationNotFound
                }
            }
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("❌ Failed to load members: \(error.localizedDescription)")
        }

        isLoadingMembers = false
    }

    /// Load members from local storage (in-memory cache already handled; this hits encrypted DB)
    @MainActor
    func loadMembersFromLocal() async {
        guard !isLoadingMembers else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }

        do {
            logger.info("💾 Loading members from encrypted DB for convo \(self.conversationId)")
            // Use MLSStorage helper method (avoids direct db.read on main thread)
            let localMembers = try await Task.detached(priority: .userInitiated) {
                try await MLSStorage.shared.fetchMembers(
                    conversationID: self.conversationId,
                    currentUserDID: self.currentUserDid,
                    database: self.database
                )
            }.value

            let converted = localMembers.compactMap { model -> BlueCatbirdMlsDefs.MemberView? in
                do {
                    let did = try DID(didString: model.did)
                    let userDid = try DID(didString: model.currentUserDID)
                    return BlueCatbirdMlsDefs.MemberView(
                        did: did,
                        userDid: userDid,
                        deviceId: nil,
                        deviceName: nil,
                        joinedAt: ATProtocolDate(date: model.addedAt),
                        isAdmin: model.role == .admin,
                        isModerator: model.role == .moderator,
                        promotedAt: nil,
                        promotedBy: nil,
                        leafIndex: model.leafIndex,
                        credential: nil
                    )
                } catch {
                    logger.error("⚠️ Failed to convert local member \(model.did): \(error.localizedDescription)")
                    return nil
                }
            }

            members = converted
            membersUpdatedSubject.send(converted)
            logger.info("💾 Loaded \(converted.count) members from encrypted DB fallback")
        } catch {
            logger.error("❌ Failed to load members from encrypted DB: \(error.localizedDescription)")
        }
    }

    /// Add members to the conversation
    @MainActor
    func addMembers(_ memberDids: [String]) async {
        guard !isAddingMembers, !memberDids.isEmpty else { return }

        isAddingMembers = true
        error = nil

        do {
            logger.info("➕ Adding \(memberDids.count) members to convo \(self.conversationId)")
            // Use ConversationManager to handle the complex MLS add flow (commits, epochs, etc.)
            try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.addMembers(convoId: self.conversationId, memberDids: memberDids)
            }.value

            // Refetch conversation to get updated state
            await loadMembers()

            // Clear pending members
            pendingMembers.removeAll()

            logger.debug("Added \(memberDids.count) members to conversation")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to add members: \(error.localizedDescription)")
        }

        isAddingMembers = false
    }

    /// Remove a member from the conversation
    @MainActor
    func removeMember(_ memberDid: String) async {
        guard !isRemovingMember else { return }

        isRemovingMember = true
        error = nil

        do {
            logger.info("🚮 Removing member \(memberDid) from convo \(self.conversationId)")
            let did = try DID(didString: memberDid)
            // Use ConversationManager/APIClient to remove member
            // Note: MLSConversationManager doesn't expose removeMember directly yet, so we use APIClient
            // Ideally MLSConversationManager should wrap this too for consistency
            let (success, _) = try await Task.detached(priority: .userInitiated) {
                try await self.apiClient.removeMember(convoId: self.conversationId, targetDid: did)
            }.value

            guard success else {
                throw MLSError.operationFailed
            }

            // Refetch conversation to get updated state
            await loadMembers()

            logger.debug("Removed member: \(memberDid)")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to remove member: \(error.localizedDescription)")
        }

        isRemovingMember = false
    }

    /// Promote a member to admin
    @MainActor
    func promoteMember(_ memberDid: String) async {
        error = nil
        do {
            logger.info("⭐️ Promoting member \(memberDid) to admin in convo \(self.conversationId)")
            try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.promoteAdmin(convoId: self.conversationId, memberDid: memberDid)
            }.value
            await loadMembers()
            logger.debug("Promoted member: \(memberDid)")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to promote member: \(error.localizedDescription)")
        }
    }

    /// Demote an admin to member
    @MainActor
    func demoteMember(_ memberDid: String) async {
        error = nil
        do {
            logger.info("⬇️ Demoting admin \(memberDid) in convo \(self.conversationId)")
            try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.demoteAdmin(convoId: self.conversationId, memberDid: memberDid)
            }.value
            await loadMembers()
            logger.debug("Demoted member: \(memberDid)")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to demote member: \(error.localizedDescription)")
        }
    }

    /// Add a pending member
    @MainActor
    func addPendingMember(_ did: String) {
        guard !pendingMembers.contains(did),
              !members.contains(where: { $0.did.description == did }) else {
            return
        }
        pendingMembers.append(did)
        logger.debug("Added pending member: \(did)")
    }

    /// Remove a pending member
    @MainActor
    func removePendingMember(_ did: String) {
        pendingMembers.removeAll { $0 == did }
        logger.debug("Removed pending member: \(did)")
    }

    /// Commit pending members (add them to the conversation)
    @MainActor
    func commitPendingMembers() async {
        guard !pendingMembers.isEmpty else { return }
        await addMembers(pendingMembers)
    }

    /// Search for members to add
    @MainActor
    private func searchMembers() async {
        let query = memberSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            participantOptInStatus = [:]
            return
        }

        isSearching = true

        do {
            // Use ATProtoClient to search for actors
            let input = AppBskyActorSearchActorsTypeahead.Parameters(
                term: query,
                limit: 20
            )

            let (_, response) = try await apiClient.client.app.bsky.actor.searchActorsTypeahead(input: input)

            if let actors = response?.actors {
                // Filter out existing members
                let existingDids = Set(members.map { $0.did.description })
                
                let results = actors
                    .filter { !existingDids.contains($0.did.didString()) }
                    .map { actor in
                        MLSParticipantViewModel(
                            id: actor.did.didString(),
                            handle: actor.handle.description,
                            displayName: actor.displayName,
                            avatarURL: actor.finalAvatarURL()
                        )
                    }
                
                // Check MLS opt-in status for all search results
                let dids = results.compactMap { try? DID(didString: $0.id) }
                if !dids.isEmpty {
                    do {
                        let statuses = try await apiClient.getOptInStatus(dids: dids)
                        for status in statuses {
                            participantOptInStatus[status.did.didString()] = status.optedIn
                        }
                        logger.info("Checked MLS opt-in status for \(statuses.count) users")
                    } catch {
                        logger.warning("Failed to check MLS opt-in status: \(error.localizedDescription)")
                        // Continue without opt-in status - will show warning on selection
                    }
                }
                
                self.searchResults = results
            } else {
                self.searchResults = []
            }
        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
            self.searchResults = []
        }

        isSearching = false
        logger.debug("Search completed with \(self.searchResults.count) results")
    }

    /// Get member display name
    func getMemberDisplayName(_ member: BlueCatbirdMlsDefs.MemberView) -> String {
        // In production, this would resolve the DID to a display name
        // For now, return the DID
        return member.did.description
    }

    /// Check if user can manage members (e.g., is creator)
    func canManageMembers(userDid: String) -> Bool {
        guard let conversation = conversation else { return false }
        return conversation.creator.description == userDid
    }

    /// Refresh members
    @MainActor
    func refresh() async {
        await loadMembers()
    }

    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }

    /// Clear search results
    @MainActor
    func clearSearch() {
        memberSearchQuery = ""
        searchResults = []
    }

    /// Validate member DID format
    func validateDid(_ did: String) -> Bool {
        return did.starts(with: "did:") && did.count > 4
    }
}
