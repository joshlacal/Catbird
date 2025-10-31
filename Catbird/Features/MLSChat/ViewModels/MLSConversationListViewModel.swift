//
//  MLSConversationListViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/21/24.
//

import Foundation
import Petrel
import Observation
import OSLog
import Combine

/// ViewModel for managing the list of MLS conversations
@Observable
final class MLSConversationListViewModel {
    // MARK: - Properties
    
    /// List of conversations
    private(set) var conversations: [BlueCatbirdMlsDefs.ConvoView] = []
    
    /// Loading state
    private(set) var isLoading = false
    
    /// Error state
    private(set) var error: Error?
    
    /// Pagination cursor
    private var cursor: String?
    
    /// Whether there are more conversations to load
    private(set) var hasMore = false
    
    /// Search query
    var searchQuery = "" {
        didSet {
            if searchQuery != oldValue {
                Task { await performSearch() }
            }
        }
    }
    
    /// Filtered conversations based on search
    var filteredConversations: [BlueCatbirdMlsDefs.ConvoView] {
        guard !searchQuery.isEmpty else { return conversations }
        let query = searchQuery.lowercased()
        return conversations.filter { convo in
            // Check conversation name
            if let name = convo.metadata?.name, name.lowercased().contains(query) {
                return true
            }
            // Check conversation description  
            if let description = convo.metadata?.description, description.lowercased().contains(query) {
                return true
            }
            // Check member DIDs
            return convo.members.contains { member in
                member.did.description.lowercased().contains(query)
            }
        }
    }
    
    // MARK: - Dependencies
    
    private let apiClient: MLSAPIClient
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationListViewModel")
    
    // MARK: - Combine
    
    private var cancellables = Set<AnyCancellable>()
    private let conversationsSubject = PassthroughSubject<[BlueCatbirdMlsDefs.ConvoView], Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()
    
    /// Publisher for conversation updates
    var conversationsPublisher: AnyPublisher<[BlueCatbirdMlsDefs.ConvoView], Never> {
        conversationsSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for errors
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    init(apiClient: MLSAPIClient) {
        self.apiClient = apiClient
        logger.debug("MLSConversationListViewModel initialized")
    }
    
    // MARK: - Public Methods
    
    /// Load conversations
    @MainActor
    func loadConversations() async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        do {
            let result = try await apiClient.getConversations(
                limit: 50,
                cursor: nil
            )
            
            conversations = result.convos
            cursor = result.cursor
            hasMore = result.cursor != nil
            
            conversationsSubject.send(conversations)
            logger.debug("Loaded \(self.conversations.count) conversations")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load conversations: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    /// Load more conversations (pagination)
    @MainActor
    func loadMoreConversations() async {
        guard !isLoading, hasMore, let cursor = cursor else { return }
        
        isLoading = true
        
        do {
            let result = try await apiClient.getConversations(
                limit: 50,
                cursor: cursor
            )
            
            conversations.append(contentsOf: result.convos)
            self.cursor = result.cursor
            hasMore = result.cursor != nil
            
            conversationsSubject.send(conversations)
            logger.debug("Loaded \(result.convos.count) more conversations")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load more conversations: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    /// Refresh conversations
    @MainActor
    func refresh() async {
        cursor = nil
        hasMore = false
        await loadConversations()
    }
    
    /// Delete a conversation locally (leave handled by MLSConversationDetailViewModel)
    @MainActor
    func deleteConversationLocally(conversationId: String) {
        conversations.removeAll { $0.id == conversationId }
        conversationsSubject.send(conversations)
        logger.debug("Removed conversation \(conversationId) from local list")
    }
    
    /// Update conversation after changes
    @MainActor
    func updateConversation(_ conversation: BlueCatbirdMlsDefs.ConvoView) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            conversationsSubject.send(conversations)
            logger.debug("Updated conversation \(conversation.id)")
        }
    }
    
    /// Add new conversation to the list
    @MainActor
    func addConversation(_ conversation: BlueCatbirdMlsDefs.ConvoView) {
        // Add to beginning of list (most recent)
        conversations.insert(conversation, at: 0)
        conversationsSubject.send(conversations)
        logger.debug("Added new conversation \(conversation.id)")
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func performSearch() async {
        // Search is currently local filtering
        // Could be extended to call API with search parameters
        logger.debug("Searching conversations with query: \(self.searchQuery)")
        conversationsSubject.send(filteredConversations)
    }
    
    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }
}
