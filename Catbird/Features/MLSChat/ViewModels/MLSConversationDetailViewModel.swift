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
import GRDB

/// Conversation initialization state
enum ConversationState: Sendable, Equatable {
    case loading
    case initializing(progress: String)
    case active
    case error(String)
}

/// ViewModel for managing a single MLS conversation's details and messages
@Observable
final class MLSConversationDetailViewModel: @unchecked Sendable {
    // MARK: - Properties

    /// Conversation initialization state
    private(set) var conversationState: ConversationState = .loading

    /// Current conversation
    private(set) var conversation: BlueCatbirdMlsDefs.ConvoView?

    /// Messages in the conversation
    private(set) var messages: [BlueCatbirdMlsDefs.MessageView] = []

    /// Optimistic messages (pending server confirmation)
    private(set) var optimisticMessages: [OptimisticMessage] = []

    /// Combined messages for display (optimistic + confirmed)
    var displayMessages: [DisplayMessage] {
      let optimistic = optimisticMessages.map { DisplayMessage.optimistic($0) }
      let confirmed = messages.map { DisplayMessage.confirmed($0) }
      return (optimistic + confirmed).sorted { $0.timestamp < $1.timestamp }
    }

    /// Loading states
    private(set) var isLoadingConversation = false
    private(set) var isLoadingMessages = false
    private(set) var isSendingMessage = false
    private(set) var isLeavingConversation = false

    /// Error state
    private(set) var error: Error?

    /// Pagination cursor for messages (sequence number)
    private var messagesCursor: Int?

    /// Whether there are more messages to load
    private(set) var hasMoreMessages = false

    /// Conversation ID
    let conversationId: String

    /// Draft message text
    var draftMessage = ""

    /// Whether user is typing (for typing indicators)
    private(set) var isTyping = false

    // MARK: - Dependencies

    private let database: DatabaseQueue
    let apiClient: MLSAPIClient // Internal for admin dashboard access
    let conversationManager: MLSConversationManager // Internal for admin features access
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

    init(
        conversationId: String,
        database: DatabaseQueue,
        apiClient: MLSAPIClient,
        conversationManager: MLSConversationManager
    ) {
        self.conversationId = conversationId
        self.database = database
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
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadConversationDetails() }
            group.addTask { await self.loadMessages() }
        }

        isLoadingConversation = false
    }

    /// Load conversation details
    @MainActor
    private func loadConversationDetails() async {
        do {
            // Get conversations and find the matching one
            let result = try await apiClient.getConversations(limit: 100)
            if let convo = result.convos.first(where: { $0.groupId == conversationId }) {
                conversation = convo
                conversationSubject.send(convo)
                logger.debug("Loaded conversation details: \(self.conversationId)")

                // Mark as active once loaded (older conversations are already initialized)
                conversationState = .active
            } else {
                throw MLSError.conversationNotFound
            }
        } catch {
            self.error = error
            errorSubject.send(error)
            conversationState = .error(error.localizedDescription)
            logger.error("Failed to load conversation details: \(error.localizedDescription)")
        }
    }

    /// Load messages for the conversation
    @MainActor
    func loadMessages() async {
        guard !isLoadingMessages else { return }

        isLoadingMessages = true

        do {
            let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceSeq: nil
            )

            // Server guarantees messages are already sorted by (epoch ASC, seq ASC)
            // No need to reverse - server returns in correct chronological order
            messages = messageViews
            messagesCursor = lastSeq
            hasMoreMessages = lastSeq != nil

            // Log gap information if present
            if let gaps = gapInfo, gaps.hasGaps {
                logger.warning("⚠️ Detected \(gaps.missingSeqs.count) missing messages: \(gaps.missingSeqs)")
            }

            messagesSubject.send(messages)

            // Remove any optimistic messages that are now confirmed
            removeDuplicateOptimisticMessages()

            logger.debug("Loaded \(self.messages.count) messages, lastSeq: \(lastSeq?.description ?? "nil")")
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
        guard !isLoadingMessages, hasMoreMessages, let sinceSeq = messagesCursor else { return }

        isLoadingMessages = true

        do {
            let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceSeq: sinceSeq
            )

            // Server returns messages in (epoch ASC, seq ASC) order
            // Append newer messages to the end
            messages.append(contentsOf: messageViews)
            messagesCursor = lastSeq
            hasMoreMessages = lastSeq != nil

            // Log gap information if present
            if let gaps = gapInfo, gaps.hasGaps {
                logger.warning("⚠️ Detected \(gaps.missingSeqs.count) missing messages: \(gaps.missingSeqs)")
            }

            messagesSubject.send(messages)

            // Remove any optimistic messages that are now confirmed
            removeDuplicateOptimisticMessages()

            logger.debug("Loaded \(messageViews.count) more messages, lastSeq: \(lastSeq?.description ?? "nil")")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to load more messages: \(error.localizedDescription)")
        }

        isLoadingMessages = false
    }

    /// Send a message
    @MainActor
    func sendMessage(_ plaintext: String, embed: MLSEmbedData? = nil) async {
        guard !isSendingMessage, !plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Block if conversation not active
        guard case .active = conversationState else {
            logger.warning("⚠️ Cannot send message: conversation not active (state: \(String(describing: self.conversationState)))")
            return
        }

        // Get current user DID from conversation manager
        guard let senderDID = conversationManager.currentUserDID else {
            logger.error("Cannot send message: no current user DID")
            return
        }

        // Create optimistic message immediately
        let optimisticMessage = OptimisticMessage(
            conversationId: conversationId,
            text: plaintext,
            embed: embed,
            senderDID: senderDID
        )
        optimisticMessages.append(optimisticMessage)

        isSendingMessage = true
        error = nil
        let startTime = Date()
        logger.debug("sendMessage start: len=\(plaintext.count), embed=\(embed != nil ? "yes" : "no")")

        do {
            // Use MLSConversationManager for proper encryption
            let (messageId, _) = try await conversationManager.sendMessage(
                convoId: conversationId,
                plaintext: plaintext,
                embed: embed
            )

            // Remove optimistic message
            optimisticMessages.removeAll { $0.id == optimisticMessage.id }

            // Reload messages to get the full message view
            await loadMessages()

            // Clear draft
            draftMessage = ""

            logger.debug("Sent message \(messageId) to conversation \(self.conversationId) in \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
        } catch {
            // Mark optimistic message as failed
            if let index = optimisticMessages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                optimisticMessages[index].state = .failed(error.localizedDescription)
            }

            self.error = error
            errorSubject.send(error)
            logger.error("Failed to send message after \(Int(Date().timeIntervalSince(startTime) * 1000))ms: \(error.localizedDescription)")
        }

        isSendingMessage = false
    }

    /// Update conversation state from external events (e.g., during creation)
    @MainActor
    func updateConversationState(_ newState: ConversationState) {
        conversationState = newState
        logger.debug("Conversation state updated to: \(String(describing: newState))")
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

    /// Retry sending a failed message
    @MainActor
    func retryMessage(_ optimisticId: UUID) async {
        guard let index = optimisticMessages.firstIndex(where: { $0.id == optimisticId }),
              case .failed = optimisticMessages[index].state else {
            logger.warning("Cannot retry message: not found or not in failed state")
            return
        }

        let message = optimisticMessages[index]

        // Update state to sending
        optimisticMessages[index].state = .sending

        // Attempt to send again
        let startTime = Date()
        logger.debug("Retrying message: len=\(message.text.count)")

        do {
            let (messageId, _) = try await conversationManager.sendMessage(
                convoId: conversationId,
                plaintext: message.text,
                embed: message.embed
            )

            // Remove optimistic message on success
            optimisticMessages.removeAll { $0.id == optimisticId }

            // Reload messages
            await loadMessages()

            logger.debug("Retry successful for message \(messageId) in \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
        } catch {
            // Mark as failed again
            if let idx = optimisticMessages.firstIndex(where: { $0.id == optimisticId }) {
                optimisticMessages[idx].state = .failed(error.localizedDescription)
            }

            self.error = error
            errorSubject.send(error)
            logger.error("Retry failed after \(Int(Date().timeIntervalSince(startTime) * 1000))ms: \(error.localizedDescription)")
        }
    }

    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }

    /// Remove duplicate optimistic messages that match server messages
    /// Note: MessageView only contains encrypted ciphertext. Deduplication
    /// happens when we remove optimistic messages after successful send (line 260)
    /// or when messages are loaded from cache/server and display is refreshed.
    @MainActor
    private func removeDuplicateOptimisticMessages() {
        // MessageView doesn't contain plaintext - deduplication happens via messageId matching
        // when messages are successfully sent (see sendMessage and retryMessage functions)
        // This function is kept for potential future enhancements with cache-based matching
    }

    // MARK: - Deinitialization

    deinit {
        typingTimer?.invalidate()
        cancellables.forEach { $0.cancel() }
    }
}

// MARK: - Error Types
