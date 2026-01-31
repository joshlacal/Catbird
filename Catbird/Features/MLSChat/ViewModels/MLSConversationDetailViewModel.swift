import CatbirdMLSService
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
import CatbirdMLSCore

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
      // Sort by (epoch, sequenceNumber) for correct MLS message ordering
      // Prevents messages from appearing out of order during epoch transitions
      return (optimistic + confirmed).sorted {
        if $0.epoch != $1.epoch {
          return $0.epoch < $1.epoch
        }
        return $0.sequenceNumber < $1.sequenceNumber
      }
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

    // MARK: - Dependencies

    private let database: MLSDatabase
    let apiClient: MLSAPIClient // Internal for admin dashboard access
    let conversationManager: MLSConversationManager // Internal for admin features access
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetailViewModel")

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()
    private let messagesSubject = PassthroughSubject<[BlueCatbirdMlsDefs.MessageView], Never>()
    private let conversationSubject = PassthroughSubject<BlueCatbirdMlsDefs.ConvoView, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

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
        database: MLSDatabase,
        apiClient: MLSAPIClient,
        conversationManager: MLSConversationManager
    ) {
        self.conversationId = conversationId
        self.database = database
        self.apiClient = apiClient
        self.conversationManager = conversationManager
        logger.debug("MLSConversationDetailViewModel initialized for conversation: \(conversationId)")
        
        setupNotificationObservers()
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

        // Mark all messages as read when conversation is opened
        await markMessagesAsRead()

        isLoadingConversation = false
    }

    /// Mark all messages in this conversation as read
    @MainActor
    func markMessagesAsRead() async {
        guard let currentUserDID = conversationManager.currentUserDID else { return }
        do {
            let count = try await MLSStorageHelpers.markAllMessagesAsRead(
                in: database,
                conversationID: conversationId,
                currentUserDID: currentUserDID
            )
            if count > 0 {
                logger.debug("Marked \(count) messages as read in conversation \(self.conversationId)")
            }
        } catch {
            logger.error("Failed to mark messages as read: \(error.localizedDescription)")
        }
    }

    /// Load conversation details
    @MainActor
    private func loadConversationDetails() async {
        do {
            // First try to get conversation from manager cache (most efficient)
            if let cachedConvo = conversationManager.conversations[conversationId] {
                conversation = cachedConvo
                conversationSubject.send(cachedConvo)
                logger.debug("🔍 [MEMBER_MGMT] Loaded conversation details from cache: \(self.conversationId), members count: \(cachedConvo.members.count)")
                conversationState = .active
            } else {
                // Fallback: sync with server and retry
                logger.debug("Conversation not in cache, syncing with server...")

                // Move database operations off main thread to prevent priority inversion
                let expectedGen = MLSCoordinationAwareTask.captureGeneration()
                try MLSCoordinationAwareTask.validateGeneration(expectedGen)

                let manager = conversationManager
                try await Task.detached(priority: .userInitiated) {
                    try await manager.syncWithServer()
                }.value

                try MLSCoordinationAwareTask.validateGeneration(expectedGen)

                if let syncedConvo = conversationManager.conversations[conversationId] {
                    conversation = syncedConvo
                    conversationSubject.send(syncedConvo)
                    logger.debug("🔍 [MEMBER_MGMT] Loaded conversation details after sync: \(self.conversationId), members count: \(syncedConvo.members.count)")
                    conversationState = .active
                } else {
                    throw MLSError.conversationNotFound
                }
            }
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            logger.info("loadConversationDetails cancelled (account switch)")
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
            let expectedGen = MLSCoordinationAwareTask.captureGeneration()
            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceSeq: nil
            )

            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

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
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            logger.info("loadMessages cancelled (account switch)")
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
            let expectedGen = MLSCoordinationAwareTask.captureGeneration()
            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceSeq: sinceSeq
            )

            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

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
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            logger.info("loadMoreMessages cancelled (account switch)")
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
            let expectedGen = MLSCoordinationAwareTask.captureGeneration()
            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            // CRITICAL: Move FFI work OFF main thread to prevent UI blocking
            // Capture values for detached task
            let convoId = conversationId
            let manager = conversationManager

            // Run encryption and send OFF main thread
            let messageId = try await Task.detached(priority: .userInitiated) {
                let (msgId, _, _, _) = try await manager.sendMessage(
                    convoId: convoId,
                    plaintext: plaintext,
                    embed: embed
                )
                return msgId
            }.value

            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            // Back on @MainActor for UI updates
            // Remove optimistic message
            optimisticMessages.removeAll { $0.id == optimisticMessage.id }

            // Reload messages to get the full message view
            await loadMessages()

            // Clear draft
            draftMessage = ""

            logger.debug("Sent message \(messageId) to conversation \(self.conversationId) in \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            // Account switched mid-send; don't surface as failure.
            optimisticMessages.removeAll { $0.id == optimisticMessage.id }
            logger.info("sendMessage cancelled (account switch)")
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
            let expectedGen = MLSCoordinationAwareTask.captureGeneration()
            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            // Use the conversation manager to properly clean up MLS group and database
            try await conversationManager.leaveConversation(convoId: conversationId)

            try MLSCoordinationAwareTask.validateGeneration(expectedGen)
            logger.debug("Left conversation \(self.conversationId)")
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            logger.info("leaveConversation cancelled (account switch)")
        } catch {
            self.error = error
            errorSubject.send(error)
            logger.error("Failed to leave conversation: \(error.localizedDescription)")
            isLeavingConversation = false
            throw error
        }

        isLeavingConversation = false
    }

    // Typing indicator functionality has been removed.

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
            let expectedGen = MLSCoordinationAwareTask.captureGeneration()
            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            // CRITICAL: Move FFI work OFF main thread to prevent UI blocking
            // Capture values for detached task
            let convoId = conversationId
            let manager = conversationManager

            // Run encryption and send OFF main thread
            let messageId = try await Task.detached(priority: .userInitiated) {
                let (msgId, _, _, _) = try await manager.sendMessage(
                    convoId: convoId,
                    plaintext: message.text,
                    embed: message.embed
                )
                return msgId
            }.value

            try MLSCoordinationAwareTask.validateGeneration(expectedGen)

            // Back on @MainActor for UI updates
            // Remove optimistic message on success
            optimisticMessages.removeAll { $0.id == optimisticId }

            // Reload messages
            await loadMessages()

            logger.debug("Retry successful for message \(messageId) in \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
        } catch is MLSCoordinationAwareTask.GenerationStaleError {
            logger.info("retryMessage cancelled (account switch)")
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
        // Simple deduplication: if we have confirmed messages, we can check if any optimistic messages
        // are redundant. But without a shared ID, it's hard.
        // However, `sendMessage` handles the removal on success.
        // This method is kept as a hook for potential specific checks.
    }

    // MARK: - Notification Handling

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: Notification.Name("MLSMessageSaved"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleMessageSaved(notification)
            }
            .store(in: &cancellables)
    }

    private func handleMessageSaved(_ notification: Notification) {
        // Verify this notification is for our conversation
        guard let userInfo = notification.userInfo,
            let savedConvoId = userInfo["conversationID"] as? String,
            savedConvoId == self.conversationId
        else {
            return
        }

        // Log receipt
        if let messageId = userInfo["messageID"] as? String {
            logger.debug(
                "📩 [Realtime] Received message saved notification for msg \(messageId) in \(savedConvoId)"
            )
        }

        // Trigger reload to fetch the new message from API (which now has it, or we have it locally and API should return it?)
        // Note: API client mimics server behavior. If we saved it locally (via NSE/SSE),
        // the API client might not know about it if it's purely remote.
        // BUT `MLSAPIClient` usually interacts with the same backend/store.
        // If `apiClient` hits the network, we assume the server pushed it to us (SSE) AND we saved it.
        // So server has it.
        Task {
            await self.loadMessages()
        }
    }


    // MARK: - Deinitialization

    deinit {
        cancellables.forEach { $0.cancel() }
    }
}

// MARK: - Error Types
