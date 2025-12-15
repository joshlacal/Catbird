//
//  MLSBugWorkarounds.swift
//  Catbird
//
//  Critical bug workarounds for known MLS client issues
//

import Foundation
import OSLog

/// Critical bug workarounds for known MLS client issues
///
/// This struct provides workarounds for three major MLS protocol bugs:
/// 1. **CannotDecryptOwnMessage**: Self-sent messages fail decryption due to FFI state issues
/// 2. **Epoch mismatch tolerance**: Messages arrive before local state has processed commits
/// 3. **SecretReuseError deduplication**: Duplicate messages cause ratchet key reuse errors
///
/// All methods are designed to be called during message processing to handle edge cases
/// that would otherwise cause message loss or decryption failures.
struct MLSBugWorkarounds: Sendable {

    // MARK: - Properties

    private static let logger = Logger(subsystem: "Catbird", category: "MLSBugWorkarounds")

    /// Maximum epoch distance to tolerate before rejecting message
    private static let maxEpochTolerance: Int64 = 1

    /// In-memory cache of processed message IDs to prevent SecretReuseError
    /// Thread-safe actor-based storage with TTL expiration
    private static let duplicateTracker = DuplicateMessageTracker()

    // MARK: - Epoch Mismatch Tolerance

    /// Handle epoch mismatch by fetching missing commits from server
    ///
    /// **Problem**: Messages can arrive out-of-order due to network conditions. A message
    /// at epoch N+1 may arrive before the commit that advances local state from N to N+1.
    /// This causes "epoch mismatch" errors and message loss.
    ///
    /// **Workaround**: If message epoch = local epoch + 1, fetch pending commits from server
    /// and process them to advance local state, then retry the message decryption.
    ///
    /// - Parameters:
    ///   - messageEpoch: Epoch number in the received message
    ///   - localEpoch: Current local epoch for the conversation
    ///   - conversationID: Conversation identifier
    ///   - apiClient: MLS API client for fetching commits
    ///   - conversationManager: Manager to process fetched commits
    /// - Throws: MLSConversationError if commit fetch/processing fails
    static func handleEpochMismatch(
        messageEpoch: UInt64,
        localEpoch: UInt64,
        conversationID: String,
        apiClient: MLSAPIClient?,
        conversationManager: MLSConversationManager?
    ) async throws {
        let epochDifference = Int64(messageEpoch) - Int64(localEpoch)

        // Only handle single-epoch mismatch (message is one epoch ahead)
        guard epochDifference == 1 else {
            if epochDifference > maxEpochTolerance {
                logger.error("❌ Epoch mismatch too large: message=\(messageEpoch), local=\(localEpoch), diff=\(epochDifference)")
                throw MLSConversationError.invalidEpoch("Message epoch \(messageEpoch) is \(epochDifference) ahead of local epoch \(localEpoch)")
            } else if epochDifference < 0 {
                logger.warning("⚠️ Late message arrival: message=\(messageEpoch), local=\(localEpoch)")
                // Message is from past epoch - may be deliverable from retained keys
                return
            } else {
                // epochDifference == 0, no mismatch
                return
            }
        }

        logger.warning("⚠️ Epoch mismatch tolerance triggered: message=\(messageEpoch), local=\(localEpoch)")
        logger.info("🔄 Fetching missing commits from server to advance epoch...")

        // Validate dependencies
        guard apiClient != nil else {
            logger.error("❌ MLSAPIClient not configured - cannot fetch commits")
            throw MLSConversationError.contextNotInitialized
        }

        guard let conversationManager = conversationManager else {
            logger.error("❌ MLSConversationManager not available - cannot process commits")
            throw MLSConversationError.contextNotInitialized
        }

        do {
            // Sync group state to fetch and process missing commits
            logger.debug("📡 Syncing group state for conversation \(conversationID) to advance from epoch \(localEpoch)")
            try await conversationManager.syncGroupState(for: conversationID)

            // Verify epoch after sync
            let updatedEpoch = try await conversationManager.getEpoch(convoId: conversationID)
            if updatedEpoch == messageEpoch {
                logger.info("✅ Epoch mismatch resolved: local epoch now matches message epoch \(messageEpoch)")
            } else if updatedEpoch > messageEpoch {
                logger.info("✅ Epoch mismatch resolved: local epoch \(updatedEpoch) now ahead of message epoch \(messageEpoch)")
            } else {
                logger.warning("⚠️ Epoch mismatch partially resolved: local=\(updatedEpoch), message=\(messageEpoch)")
            }

        } catch {
            logger.error("❌ Failed to handle epoch mismatch: \(error.localizedDescription)")
            throw MLSConversationError.syncFailed(error)
        }
    }

    // MARK: - Duplicate Message Detection

    /// Check if a message has already been processed to prevent SecretReuseError
    ///
    /// **Problem**: Network retries and server-side message fanout can deliver the same
    /// message multiple times. Attempting to decrypt a message twice with MLS causes
    /// "SecretReuseError" because the one-time decryption key was consumed on first attempt.
    ///
    /// **Workaround**: Track processed message IDs in memory with TTL expiration. If a
    /// message ID is seen again within the deduplication window, skip FFI decryption and
    /// retrieve the cached plaintext instead.
    ///
    /// - Parameters:
    ///   - messageID: Server-assigned message identifier
    ///   - conversationID: Conversation identifier (for scoped deduplication)
    /// - Returns: True if message has been processed recently, false otherwise
    static func isDuplicateMessage(
        messageID: String,
        conversationID: String
    ) async -> Bool {
        let isDuplicate = await duplicateTracker.hasProcessed(
            messageID: messageID,
            conversationID: conversationID
        )

        if isDuplicate {
            logger.warning("⚠️ Duplicate message detected: \(messageID) in conversation \(conversationID)")
            logger.debug("   Skipping FFI decryption to prevent SecretReuseError")
        }

        return isDuplicate
    }

    /// Mark a message as processed to prevent future duplicate decryption attempts
    ///
    /// Call this after successfully decrypting a message to register it in the
    /// deduplication tracker.
    ///
    /// - Parameters:
    ///   - messageID: Server-assigned message identifier
    ///   - conversationID: Conversation identifier
    static func markMessageProcessed(
        messageID: String,
        conversationID: String
    ) async {
        await duplicateTracker.markProcessed(
            messageID: messageID,
            conversationID: conversationID
        )

        logger.debug("✅ Marked message \(messageID) as processed in conversation \(conversationID)")
    }

    /// Clear duplicate tracking for a specific conversation
    ///
    /// Useful when clearing conversation history or during account transitions.
    ///
    /// - Parameter conversationID: Conversation identifier to clear
    static func clearDuplicateTracking(conversationID: String) async {
        await duplicateTracker.clearConversation(conversationID: conversationID)
        logger.info("🗑️ Cleared duplicate tracking for conversation \(conversationID)")
    }

    /// Clear all duplicate tracking (e.g., during logout)
    static func clearAllDuplicateTracking() async {
        await duplicateTracker.clearAll()
        logger.info("🗑️ Cleared all duplicate tracking")
    }
}

// MARK: - Duplicate Message Tracker

/// Thread-safe actor for tracking processed message IDs with TTL expiration
private actor DuplicateMessageTracker {

    /// Storage for processed message IDs: conversationID -> Set of (messageID, timestamp)
    private var processedMessages: [String: Set<ProcessedMessage>] = [:]

    /// Time-to-live for deduplication entries (5 minutes)
    /// Long enough to handle network retries, short enough to prevent unbounded growth
    private let ttl: TimeInterval = 300

    /// Maximum number of messages to track per conversation (prevent memory exhaustion)
    private let maxMessagesPerConversation = 1000

    /// Check if a message has been processed recently
    func hasProcessed(messageID: String, conversationID: String) -> Bool {
        // Clean expired entries for this conversation
        cleanExpiredMessages(conversationID: conversationID)

        guard let messages = processedMessages[conversationID] else {
            return false
        }

        return messages.contains { $0.messageID == messageID }
    }

    /// Mark a message as processed
    func markProcessed(messageID: String, conversationID: String) {
        let processed = ProcessedMessage(
            messageID: messageID,
            timestamp: Date()
        )

        processedMessages[conversationID, default: []].insert(processed)

        // Enforce size limit
        if let messages = processedMessages[conversationID], messages.count > maxMessagesPerConversation {
            // Remove oldest messages
            let sorted = messages.sorted { $0.timestamp < $1.timestamp }
            processedMessages[conversationID] = Set(sorted.suffix(maxMessagesPerConversation))
        }
    }

    /// Clear all messages for a specific conversation
    func clearConversation(conversationID: String) {
        processedMessages[conversationID] = nil
    }

    /// Clear all tracked messages
    func clearAll() {
        processedMessages.removeAll()
    }

    /// Remove expired messages from a conversation's tracking set
    private func cleanExpiredMessages(conversationID: String) {
        guard var messages = processedMessages[conversationID] else {
            return
        }

        let now = Date()
        messages = messages.filter { now.timeIntervalSince($0.timestamp) < ttl }

        if messages.isEmpty {
            processedMessages[conversationID] = nil
        } else {
            processedMessages[conversationID] = messages
        }
    }
}

/// Record of a processed message with timestamp for TTL expiration
private struct ProcessedMessage: Hashable, Sendable {
    let messageID: String
    let timestamp: Date

    func hash(into hasher: inout Hasher) {
        hasher.combine(messageID)
    }

    static func == (lhs: ProcessedMessage, rhs: ProcessedMessage) -> Bool {
        lhs.messageID == rhs.messageID
    }
}
