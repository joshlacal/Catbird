//
//  MLSConversationDetailViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/21/24.
//

import Foundation
import Petrel
import Observation
import OSLog
import Combine

/// ViewModel for managing a single MLS conversation's details and messages
@Observable
final class MLSConversationDetailViewModel {
    // MARK: - Properties
    
    /// Current conversation
    private(set) var conversation: BlueCatbirdMlsDefs.ConvoView?
    
    /// Messages in the conversation
    private(set) var messages: [BlueCatbirdMlsDefs.MessageView] = []
    
    /// Loading states
    private(set) var isLoadingConversation = false
    private(set) var isLoadingMessages = false
    private(set) var isSendingMessage = false
    private(set) var isLeavingConversation = false
    
    /// Error state
    private(set) var error: Error?
    
    /// Pagination cursor for messages
    private var messagesCursor: String?
    
    /// Whether there are more messages to load
    private(set) var hasMoreMessages = false
    
    /// Conversation ID
    let conversationId: String
    
    /// Draft message text
    var draftMessage = ""
    
    /// Whether user is typing (for typing indicators)
    private(set) var isTyping = false
    
    // MARK: - Dependencies
    
    private let apiClient: MLSAPIClient
    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetailViewModel")
    
    // MARK: - Combine
    
    private var cancellables = Set<AnyCancellable>()
    private let messagesSubject = PassthroughSubject<[BlueCatbirdMlsDefs.MessageView], Never>()
    private let conversationSubject = PassthroughSubject<BlueCatbirdMlsDefs.ConvoView, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()
    private var typingTimer: Timer?
    
    /// Publisher for message updates
    var messagesPublisher: AnyPublisher<[BlueCatbirdMlsDefs.MessageView], Never> {
        messagesSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for conversation updates
    var conversationPublisher: AnyPublisher<BlueCatbirdMlsDefs.ConvoView, Never> {
        conversationSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for errors
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    init(conversationId: String, apiClient: MLSAPIClient, conversationManager: MLSConversationManager) {
        self.conversationId = conversationId
        self.apiClient = apiClient
        self.conversationManager = conversationManager
        logger.debug("MLSConversationDetailViewModel initialized for conversation: \(conversationId)")
    }
    
    // MARK: - Public Methods
    
    /// Load conversation details and initial messages
    @MainActor
    func loadConversation() async {
        guard !isLoadingConversation else { return }
        
        isLoadingConversation = true
        error = nil
        
        // Load conversation details and messages in parallel
        async let conversationTask = loadConversationDetails()
        async let messagesTask = loadMessages()
        
        await conversationTask
        await messagesTask
        
        isLoadingConversation = false
    }
    
    /// Load conversation details
    @MainActor
    private func loadConversationDetails() async {
        do {
            // Get conversations and find the matching one
            let result = try await apiClient.getConversations(limit: 100)
            if let convo = result.convos.first(where: { $0.id == conversationId }) {
                conversation = convo
                conversationSubject.send(convo)
                logger.debug("Loaded conversation details: \(self.conversationId)")
            } else {
                throw MLSError.conversationNotFound
            }
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load conversation details: \(error.localizedDescription)")
        }
    }
    
    /// Load messages for the conversation
    @MainActor
    func loadMessages() async {
        guard !isLoadingMessages else { return }
        
        isLoadingMessages = true
        
        do {
            let result = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceMessage: nil
            )
            
            messages = result.messages.reversed() // Reverse to show oldest first
            messagesCursor = result.cursor
            hasMoreMessages = result.cursor != nil
            
            messagesSubject.send(messages)
            logger.debug("Loaded \(self.messages.count) messages")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load messages: \(error.localizedDescription)")
        }
        
        isLoadingMessages = false
    }
    
    /// Load more messages (pagination)
    @MainActor
    func loadMoreMessages() async {
        guard !isLoadingMessages, hasMoreMessages, let cursor = messagesCursor else { return }
        
        isLoadingMessages = true
        
        do {
            let result = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceMessage: cursor
            )
            
            // Insert older messages at the beginning
            messages.insert(contentsOf: result.messages.reversed(), at: 0)
            messagesCursor = result.cursor
            hasMoreMessages = result.cursor != nil
            
            messagesSubject.send(messages)
            logger.debug("Loaded \(result.messages.count) more messages")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load more messages: \(error.localizedDescription)")
        }
        
        isLoadingMessages = false
    }
    
    /// Send a message
    @MainActor
    func sendMessage(_ plaintext: String, embedType: String? = nil, embedUri: URI? = nil) async {
        guard !isSendingMessage, !plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        isSendingMessage = true
        error = nil
        let startTime = Date()
        logger.debug("sendMessage start: len=\(plaintext.count), embedType=\(embedType ?? "none")")
        
        do {
            // Use MLSConversationManager for proper encryption
            let (messageId, receivedAt) = try await conversationManager.sendMessage(
                convoId: conversationId,
                plaintext: plaintext,
                embedType: embedType,
                embedUri: embedUri
            )
            
            // Reload messages to get the full message view
            await loadMessages()
            
            // Clear draft
            draftMessage = ""
            
            logger.debug("Sent message \(messageId) to conversation \(self.conversationId) in \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to send message after \(Int(Date().timeIntervalSince(startTime) * 1000))ms: \(error.localizedDescription)")
        }
        
        isSendingMessage = false
    }
    
    /// Leave the conversation
    @MainActor
    func leaveConversation() async throws {
        guard !isLeavingConversation else { return }
        
        isLeavingConversation = true
        error = nil
        
        do {
            _ = try await apiClient.leaveConversation(convoId: conversationId)
            logger.debug("Left conversation \(self.conversationId)")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to leave conversation: \(error.localizedDescription)")
            isLeavingConversation = false
            throw error
        }
        
        isLeavingConversation = false
    }
    
    /// Update typing status
    @MainActor
    func setTyping(_ typing: Bool) {
        isTyping = typing
        
        if typing {
            // Reset typing timer
            typingTimer?.invalidate()
            typingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.isTyping = false
                }
            }
        } else {
            typingTimer?.invalidate()
            typingTimer = nil
        }
    }
    
    /// Refresh conversation and messages
    @MainActor
    func refresh() async {
        messagesCursor = nil
        hasMoreMessages = false
        await loadConversation()
    }
    
    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }
    
    // MARK: - Deinitialization
    
    deinit {
        typingTimer?.invalidate()
        cancellables.forEach { $0.cancel() }
    }
}

// MARK: - Error Types

