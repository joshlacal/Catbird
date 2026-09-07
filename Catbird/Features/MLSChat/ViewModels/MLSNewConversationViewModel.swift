import CatbirdMLSCore
//
//  MLSNewConversationViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/21/24.
//

import Foundation
import Petrel
import PetrelCatbird
import Observation
import OSLog
import Combine
import GRDB

/// ViewModel for creating a new MLS conversation
@Observable
final class MLSNewConversationViewModel {
    // MARK: - Properties

    /// Selected members (DIDs)
    var selectedMembers: [String] = []

    /// Conversation name
    var conversationName = ""

    /// Conversation description
    var conversationDescription = ""

    /// Selected cipher suite
    var selectedCipherSuite = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

    /// Loading state
    private(set) var isCreating = false

    /// Error state
    private(set) var error: Error?

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var searchGeneration = UUID()

    /// Search query for finding members
    var memberSearchQuery = "" {
        didSet {
            if memberSearchQuery != oldValue {
                let trimmed = memberSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let generation = UUID()
                searchGeneration = generation
                searchTask?.cancel()
                guard !trimmed.isEmpty else {
                    searchResults = []
                    isSearching = false
                    return
                }
                searchTask = Task { @MainActor in
                    await searchMembers(query: trimmed, generation: generation)
                }
            }
        }
    }

    /// Search results
    private(set) var searchResults: [String] = []

    /// Whether search is in progress
    private(set) var isSearching = false
    /// Available cipher suites
    let availableCipherSuites = [
        "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
        "MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448",
        "MLS_128_DHKEMP256_AES128GCM_SHA256_P256",
        "MLS_256_DHKEMP521_AES256GCM_SHA512_P521"
    ]

    /// Whether this is a 1:1 direct message (single participant)
    var isDirectMessage: Bool { selectedMembers.count == 1 }

    /// Validation state
    var isValid: Bool {
        let hasName = !conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMembers = !selectedMembers.isEmpty
        if isDirectMessage {
            return hasMembers
        }
        return hasName && hasMembers
    }

    // MARK: - Dependencies

    private let database: MLSDatabase
    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSNewConversationViewModel")

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()
    private let conversationCreatedSubject = PassthroughSubject<BlueCatbirdChatDefs.ConversationState, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

    /// Publisher for successful conversation creation
    var conversationCreatedPublisher: AnyPublisher<BlueCatbirdChatDefs.ConversationState, Never> {
        conversationCreatedSubject.eraseToAnyPublisher()
    }

    /// Publisher for errors
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(database: MLSDatabase, conversationManager: MLSConversationManager) {
        self.database = database
        self.conversationManager = conversationManager
        logger.debug("MLSNewConversationViewModel initialized")
    }

    // MARK: - Public Methods

    /// Create a new conversation
    @MainActor
    @discardableResult
    func createConversation(onProgress: (String) -> Void = { _ in }) async -> BlueCatbirdChatDefs.ConversationState? {
        guard isValid, !isCreating else {
            logger.warning("⚠️ createConversation called but validation failed - isValid: \(self.isValid), isCreating: \(self.isCreating)")
            
            // Provide user feedback about validation failure
            let validationErrors = validate()
            if !validationErrors.isEmpty {
                let errorMessage = validationErrors.joined(separator: "\n")
                self.error = NSError(domain: "MLSNewConversation", code: 400, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                errorSubject.send(self.error!)
            }
            return nil
        }

        isCreating = true
        error = nil
        defer { isCreating = false }
        let accountDID = conversationManager.userDid
        let membersSnapshot = selectedMembers
        let trimmedName = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = conversationDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = {
            accountDID != nil && self.conversationManager.userDid == accountDID
                && AppStateManager.shared.lifecycle.userDID == accountDID
                && !AppStateManager.shared.isTransitioning
        }
        guard !Task.isCancelled, isCurrent() else { return nil }

        logger.info("🟦 [MLSNewConversationViewModel.createConversation] START")
        logger.info("   - name: '\(self.conversationName)'")
        logger.info("   - description: '\(self.conversationDescription)'")
        logger.info("   - selectedMembers: \(self.selectedMembers.count) members")

        // Pre-invitation check: Ensure we have sufficient key packages
        do {
            try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.smartRefreshKeyPackages()
            }.value
            logger.info("📦 Pre-invitation key package check complete")
        } catch {
            logger.warning("⚠️ Pre-invitation key package check failed: \(error.localizedDescription)")
            // Continue anyway - the actual creation will fail if truly insufficient
        }

        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }

            logger.debug("📍 Converting \(self.selectedMembers.count) members to DIDs...")
            let memberDids = try membersSnapshot.map { try DID(didString: $0) }
            logger.info("✅ Converted \(memberDids.count) DIDs")

            logger.info("📍 Calling conversationManager.createGroup...")
            logger.info("   - initialMembers: \(memberDids.isEmpty ? "nil" : "\(memberDids.count) members")")
            logger.info("   - name: '\(trimmedName)'")

            // Use MLSConversationManager to create the group properly
            // This will create the MLS group locally, generate the real group ID,
            // and register it with the server
            let convoView = try await MLSConversationCreationRetry.run(
                isCurrent: isCurrent,
                retryAfter: {
                    guard membersSnapshot.count == 1,
                          membersSnapshot[0].lowercased() != accountDID?.lowercased() else { return nil }
                    return ($0 as? MLSConversationLifecycleError)?.retryAfter
                },
                onProgress: onProgress
            ) {
                try await Task.detached(priority: .userInitiated) {
                    try await self.conversationManager.createGroup(
                        initialMembers: memberDids.isEmpty ? nil : memberDids,
                        name: trimmedName,
                        description: trimmedDesc.isEmpty ? nil : trimmedDesc
                    )
                }.value
            }

            guard MLSConversationIdentityBoundary.isCanonicalStableID(convoView.conversationId) else {
                throw MLSConversationIdentityBoundary.Error.invalidStableID(convoView.conversationId)
            }

            logger.info("✅ [MLSNewConversationViewModel.createConversation] SUCCESS - conversationId: \(convoView.conversationId)")

            conversationCreatedSubject.send(convoView)
            logger.debug("Created conversation: \(convoView.conversationId)")

            // Reset form
            reset()
            isCreating = false
            logger.info("🟦 [MLSNewConversationViewModel.createConversation] COMPLETE (isCreating = false)")
            return convoView
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), isCurrent() else { return nil }
            self.error = error
            errorSubject.send(error)
            logger.error("❌ [MLSNewConversationViewModel.createConversation] FAILED: \(error.localizedDescription)")
        }

        isCreating = false
        logger.info("🟦 [MLSNewConversationViewModel.createConversation] COMPLETE (isCreating = false)")
        return nil
    }

    /// Add a member to the conversation
    @MainActor
    func addMember(_ did: String) {
        guard !selectedMembers.contains(did) else { return }
        selectedMembers.append(did)
        logger.debug("Added member: \(did)")
    }

    /// Remove a member from the conversation
    @MainActor
    func removeMember(_ did: String) {
        selectedMembers.removeAll { $0 == did }
        logger.debug("Removed member: \(did)")
    }

    /// Toggle member selection
    @MainActor
    func toggleMember(_ did: String) {
        if selectedMembers.contains(did) {
            removeMember(did)
        } else {
            addMember(did)
        }
    }

    /// Search for members
    @MainActor
    private func searchMembers(query: String, generation: UUID) async {
        let accountDID = conversationManager.userDid
        guard !Task.isCancelled, searchGeneration == generation, !query.isEmpty, conversationManager.userDid == accountDID else { return }

        isSearching = true
        defer {
            if searchGeneration == generation && conversationManager.userDid == accountDID {
                isSearching = false
            }
        }

        // 1. If query is already a DID, validate and return immediately (keeps test/DID compatibility)
        if query.starts(with: "did:") {
            if searchGeneration == generation && conversationManager.userDid == accountDID {
                searchResults = [query]
            }
            logger.debug("Search completed with exact DID: \(query)")
            return
        }

        // 2. Perform live handle/actor typeahead and exact lookup if ATProto client available
        let client = conversationManager.atProtoClient
        let cleanQuery = query.hasPrefix("@") ? String(query.dropFirst()) : query
        let isExactCandidate = cleanQuery.contains(".") || cleanQuery.hasPrefix("did:")

        do {
            async let typeaheadTask: Result<(Int, AppBskyActorSearchActorsTypeahead.Output?), Error> = {
                do {
                    let params = AppBskyActorSearchActorsTypeahead.Parameters(q: cleanQuery, limit: 20)
                    let res = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
                    return .success(res)
                } catch {
                    return .failure(error)
                }
            }()

            async let exactProfileTask: AppBskyActorDefs.ProfileViewDetailed? = {
                guard isExactCandidate else { return nil }
                do {
                    let (code, profile) = try await client.app.bsky.actor.getProfile(
                        input: .init(actor: try ATIdentifier(string: cleanQuery))
                    )
                    return (200..<300).contains(code) ? profile : nil
                } catch {
                    return nil
                }
            }()

            let typeaheadResult = await typeaheadTask
            let exactProfile = await exactProfileTask
            guard !Task.isCancelled, searchGeneration == generation, conversationManager.userDid == accountDID else { return }

            var didList: [String] = []
            if let exact = exactProfile {
                didList.append(exact.did.didString())
            }

            if case .success(let (code, response)) = typeaheadResult, (200..<300).contains(code), let actors = response?.actors {
                for actor in actors {
                    let did = actor.did.didString()
                    if !didList.contains(did) {
                        didList.append(did)
                    }
                }
            }

            if searchGeneration == generation && conversationManager.userDid == accountDID {
                searchResults = didList
            }
            logger.debug("Search completed with \(self.searchResults.count) results")
        } catch {
            guard !Task.isCancelled, searchGeneration == generation, conversationManager.userDid == accountDID else { return }
            logger.debug("Live search unavailable, falling back to empty results")
            if searchGeneration == generation && conversationManager.userDid == accountDID {
                searchResults = []
            }
        }
    }

    /// Reset the form
    @MainActor
    func reset() {
        searchTask?.cancel()
        conversationName = ""
        conversationDescription = ""
        selectedMembers = []
        memberSearchQuery = ""
        searchResults = []
        isSearching = false
        error = nil
        logger.debug("Form reset")
    }

    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }

    /// Validate form data
    func validate() -> [String] {
        var errors: [String] = []

        if !isDirectMessage && conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Conversation name is required")
        }

        if selectedMembers.isEmpty {
            errors.append("At least one member is required")
        }

        for did in selectedMembers {
            if !did.starts(with: "did:") {
                errors.append("Invalid DID format: \(did)")
            }
        }

        return errors
    }
}
