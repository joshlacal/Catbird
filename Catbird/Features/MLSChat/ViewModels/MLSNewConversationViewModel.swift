//
//  MLSNewConversationViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/21/24.
//

import Foundation
import Petrel
import Observation
import OSLog
import Combine

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
    
    /// Search query for finding members
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
    
    /// Available cipher suites
    let availableCipherSuites = [
        "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
        "MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448",
        "MLS_128_DHKEMP256_AES128GCM_SHA256_P256",
        "MLS_256_DHKEMP521_AES256GCM_SHA512_P521"
    ]
    
    /// Validation state
    var isValid: Bool {
        !conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedMembers.isEmpty
    }
    
    // MARK: - Dependencies
    
    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSNewConversationViewModel")
    
    // MARK: - Combine
    
    private var cancellables = Set<AnyCancellable>()
    private let conversationCreatedSubject = PassthroughSubject<BlueCatbirdMlsDefs.ConvoView, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()
    
    /// Publisher for successful conversation creation
    var conversationCreatedPublisher: AnyPublisher<BlueCatbirdMlsDefs.ConvoView, Never> {
        conversationCreatedSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for errors
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    init(conversationManager: MLSConversationManager) {
        self.conversationManager = conversationManager
        logger.debug("MLSNewConversationViewModel initialized")
    }
    
    // MARK: - Public Methods
    
    /// Create a new conversation
    @MainActor
    func createConversation() async {
        guard isValid, !isCreating else { return }
        
        isCreating = true
        error = nil
        
        do {
            let trimmedName = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDesc = conversationDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let memberDids = try selectedMembers.map { try DID(didString: $0) }
            
            // Use MLSConversationManager to create the group properly
            // This will create the MLS group locally, generate the real group ID,
            // and register it with the server
            let convoView = try await conversationManager.createGroup(
                initialMembers: memberDids.isEmpty ? nil : memberDids,
                name: trimmedName,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc
            )
            
            conversationCreatedSubject.send(convoView)
            logger.debug("Created conversation: \(convoView.id)")
            
            // Reset form
            reset()
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to create conversation: \(error.localizedDescription)")
        }
        
        isCreating = false
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
            searchResults = [query]
        } else {
            searchResults = []
        }
        
        isSearching = false
        logger.debug("Search completed with \(self.searchResults.count) results")
    }
    
    /// Reset the form
    @MainActor
    func reset() {
        conversationName = ""
        conversationDescription = ""
        selectedMembers = []
        memberSearchQuery = ""
        searchResults = []
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
        
        if conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
