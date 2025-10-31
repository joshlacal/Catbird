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

/// ViewModel for managing members in an MLS conversation
@Observable
final class MLSMemberManagementViewModel {
    // MARK: - Properties
    
    /// Current conversation
    private(set) var conversation: BlueCatbirdMlsDefs.ConvoView?
    
    /// Members in the conversation
    var members: [BlueCatbirdMlsDefs.MemberView] {
        conversation?.members ?? []
    }
    
    /// Loading states
    private(set) var isLoadingMembers = false
    private(set) var isAddingMembers = false
    private(set) var isRemovingMember = false
    
    /// Error state
    private(set) var error: Error?
    
    /// Conversation ID
    let conversationId: String
    
    /// Members to add
    private(set) var pendingMembers: [String] = []
    
    /// Search query for finding new members
    var memberSearchQuery = "" {
        didSet {
            if memberSearchQuery != oldValue {
                Task { await searchMembers() }
            }
        }
    }
    
    /// Search results
    private(set) var searchResults: [String] = []
    
    /// Whether search is in progress
    private(set) var isSearching = false
    
    // MARK: - Dependencies
    
    private let apiClient: MLSAPIClient
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
    
    init(conversationId: String, apiClient: MLSAPIClient) {
        self.conversationId = conversationId
        self.apiClient = apiClient
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
            // Get conversations and find the matching one
            let result = try await apiClient.getConversations(limit: 100)
            if let convo = result.convos.first(where: { $0.id == conversationId }) {
                conversation = convo
                conversationUpdatedSubject.send(convo)
                membersUpdatedSubject.send(convo.members)
                logger.debug("Loaded \(convo.members.count) members")
            } else {
                throw MLSError.conversationNotFound
            }
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load members: \(error.localizedDescription)")
        }
        
        isLoadingMembers = false
    }
    
    /// Add members to the conversation
    @MainActor
    func addMembers(_ memberDids: [String]) async {
        guard !isAddingMembers, !memberDids.isEmpty else { return }
        
        isAddingMembers = true
        error = nil
        
        do {
            let dids = try memberDids.map { try DID(didString: $0) }
            let (success, newEpoch) = try await apiClient.addMembers(
                convoId: conversationId,
                didList: dids
            )
            
            guard success else {
                throw MLSError.operationFailed
            }
            
            // Refetch conversation to get updated state
            let result = try await apiClient.getConversations(limit: 100)
            if let updatedConvo = result.convos.first(where: { $0.id == conversationId }) {
                conversation = updatedConvo
                conversationUpdatedSubject.send(updatedConvo)
                membersUpdatedSubject.send(updatedConvo.members)
            }
            
            // Clear pending members
            pendingMembers.removeAll()
            
            logger.debug("Added \(memberDids.count) members to conversation (new epoch: \(newEpoch))")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to add members: \(error.localizedDescription)")
        }
        
        isAddingMembers = false
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
        guard !memberSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        // Simulate search - in production, this would call an API
        // to search for users by DID or handle
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms delay
        
        // For now, validate DID format and add to results
        let query = memberSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.starts(with: "did:") {
            // Filter out existing members
            if !members.contains(where: { $0.did.description == query }) {
                searchResults = [query]
            } else {
                searchResults = []
            }
        } else {
            searchResults = []
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
