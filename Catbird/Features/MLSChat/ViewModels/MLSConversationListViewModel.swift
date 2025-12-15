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
import GRDB
import CatbirdMLSCore

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

    private let database: MLSDatabase
    private let apiClient: MLSAPIClient
    private weak var conversationManager: MLSConversationManager?
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationListViewModel")

    // MARK: - Observer

    private var stateObserver: MLSStateObserver?

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

    init(database: MLSDatabase, apiClient: MLSAPIClient, conversationManager: MLSConversationManager? = nil) {
        self.database = database
        self.apiClient = apiClient
        self.conversationManager = conversationManager
        logger.debug("MLSConversationListViewModel initialized")

        // Set up observer if conversation manager is provided
        if conversationManager != nil {
            setupObserver()
        }
    }

    deinit {
        // Remove observer on deallocation
        if let observer = stateObserver, let manager = conversationManager {
            manager.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    /// Load conversations
    @MainActor
    func loadConversations() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let result = try await Task.detached(priority: .userInitiated) { [apiClient] in
                try await apiClient.getConversations(
                    limit: 50,
                    cursor: nil
                )
            }.value

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
            let result = try await Task.detached(priority: .userInitiated) { [apiClient, cursor] in
                try await apiClient.getConversations(
                    limit: 50,
                    cursor: cursor
                )
            }.value

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
        conversations.removeAll { $0.groupId == conversationId }
        conversationsSubject.send(conversations)
        logger.debug("Removed conversation \(conversationId) from local list")
    }

    /// Update conversation after changes
    @MainActor
    func updateConversation(_ conversation: BlueCatbirdMlsDefs.ConvoView) {
        if let index = conversations.firstIndex(where: { $0.groupId == conversation.groupId }) {
            conversations[index] = conversation
            conversationsSubject.send(conversations)
            logger.debug("Updated conversation \(conversation.groupId)")
        }
    }

    /// Add new conversation to the list
    @MainActor
    func addConversation(_ conversation: BlueCatbirdMlsDefs.ConvoView) {
        // Add to beginning of list (most recent)
        conversations.insert(conversation, at: 0)
        conversationsSubject.send(conversations)
        logger.debug("Added new conversation \(conversation.groupId)")
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

    // MARK: - Observer Setup

    private func setupObserver() {
        stateObserver = MLSStateObserver { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                await self.handleStateEvent(event)
            }
        }

        if let observer = stateObserver {
            conversationManager?.addObserver(observer)
            logger.debug("Registered MLS state observer")
        }
    }

    @MainActor
    private func handleStateEvent(_ event: MLSStateEvent) async {
        switch event {
        case .membershipChanged(let convoId, let did, let action):
            logger.debug("Membership changed in \(convoId): \(did) - \(action.rawValue)")
            // Refresh the specific conversation to update member list
            await refreshSpecificConversation(convoId)

        case .epochUpdated(let convoId, let epoch):
            logger.debug("Epoch updated for \(convoId): \(epoch)")
            // Optionally refresh conversation to show updated state
            await refreshSpecificConversation(convoId)

        case .conversationCreated(let convo):
            // Add new conversation to the list
            addConversation(convo)

        case .conversationJoined(let convo):
            // Add joined conversation to the list
            addConversation(convo)

        default:
            // Ignore other events
            break
        }
    }

    @MainActor
    private func refreshSpecificConversation(_ convoId: String) async {
        // Refresh a specific conversation from the server
        do {
            let result = try await Task.detached(priority: .userInitiated) { [apiClient] in
                try await apiClient.getConversations(limit: 100, cursor: nil)
            }.value

            if let updatedConvo = result.convos.first(where: { $0.groupId == convoId }) {
                updateConversation(updatedConvo)
                logger.debug("Refreshed conversation \(convoId) after state change")
            }
        } catch {
            logger.error("Failed to refresh conversation \(convoId): \(error.localizedDescription)")
        }
    }
}
