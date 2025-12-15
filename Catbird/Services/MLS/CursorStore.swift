//
//  CursorStore.swift
//  Catbird
//
//  Persistent cursor storage for MLS subscription resume
//  Supports resumable subscriptions per MLS_HYBRID_MESSAGING_PLAN.md
//

import Foundation
import SwiftData
import OSLog

/// Model for storing subscription cursors per conversation
@Model
final class ConversationCursor {
    @Attribute(.unique) var key: String
    var conversationId: String
    var currentUserDID: String
    var cursor: String
    var lastSeenAt: Date
    var eventType: String  // messageEvent, reactionEvent, etc.
    
    init(
        conversationId: String,
        currentUserDID: String,
        cursor: String,
        eventType: String = "messageEvent",
        lastSeenAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.currentUserDID = currentUserDID
        self.cursor = cursor
        self.eventType = eventType
        self.lastSeenAt = lastSeenAt
        self.key = Self.makeKey(
            conversationId: conversationId,
            currentUserDID: currentUserDID,
            eventType: eventType
        )
    }
    
    static func makeKey(conversationId: String, currentUserDID: String, eventType: String) -> String {
        "\(currentUserDID)|\(conversationId)|\(eventType)"
    }
}

/// Cursor store for managing subscription resume points
@MainActor
public final class CursorStore {
    
    // MARK: - Properties
    
    private let modelContext: ModelContext
    private let currentUserDID: String
    private let logger = Logger(subsystem: "blue.catbird.mls", category: "CursorStore")
    
    // MARK: - Initialization
    
    public init(modelContext: ModelContext, currentUserDID: String) {
        self.modelContext = modelContext
        self.currentUserDID = currentUserDID
        logger.info("CursorStore initialized")
    }
    
    private func key(for conversationId: String, eventType: String) -> String {
        ConversationCursor.makeKey(
            conversationId: conversationId,
            currentUserDID: currentUserDID,
            eventType: eventType
        )
    }
    
    // MARK: - Cursor Management
    
    /// Get the last seen cursor for a conversation
    /// - Parameters:
    ///   - conversationId: Conversation identifier
    ///   - eventType: Event type (default: messageEvent)
    /// - Returns: Cursor string if exists, nil otherwise
    public func getCursor(for conversationId: String, eventType: String = "messageEvent") throws -> String? {
        let cursorKey = key(for: conversationId, eventType: eventType)
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { cursor in
                cursor.key == cursorKey
            }
        )
        
        let cursors = try modelContext.fetch(descriptor)
        let cursor = cursors.first?.cursor
        
        if let cursor = cursor {
            logger.debug("Retrieved cursor for \(conversationId): \(cursor)")
        } else {
            logger.debug("No cursor found for \(conversationId)")
        }
        
        return cursor
    }
    
    /// Update the cursor for a conversation
    /// - Parameters:
    ///   - conversationId: Conversation identifier
    ///   - cursor: New cursor value (ULID format)
    ///   - eventType: Event type (default: messageEvent)
    public func updateCursor(for conversationId: String, cursor: String, eventType: String = "messageEvent") throws {
        let cursorKey = key(for: conversationId, eventType: eventType)
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { c in
                c.key == cursorKey
            }
        )
        
        let existing = try modelContext.fetch(descriptor).first
        
        if let existing = existing {
            // Update existing cursor
            existing.cursor = cursor
            existing.lastSeenAt = Date()
            logger.debug("Updated cursor for \(conversationId): \(cursor)")
        } else {
            // Insert new cursor
            let newCursor = ConversationCursor(
                conversationId: conversationId,
                currentUserDID: currentUserDID,
                cursor: cursor,
                eventType: eventType
            )
            modelContext.insert(newCursor)
            logger.debug("Inserted new cursor for \(conversationId): \(cursor)")
        }
        
        try modelContext.save()
    }
    
    /// Get the last seen timestamp for a conversation
    /// - Parameter conversationId: Conversation identifier
    /// - Returns: Last seen date if cursor exists, nil otherwise
    public func getLastSeenAt(for conversationId: String, eventType: String = "messageEvent") throws -> Date? {
        let cursorKey = key(for: conversationId, eventType: eventType)
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { cursor in
                cursor.key == cursorKey
            }
        )
        
        return try modelContext.fetch(descriptor).first?.lastSeenAt
    }
    
    /// Remove cursor for a conversation (e.g., when leaving)
    /// - Parameter conversationId: Conversation identifier
    public func removeCursor(for conversationId: String) throws {
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { cursor in
                cursor.conversationId == conversationId && cursor.currentUserDID == currentUserDID
            }
        )
        
        let cursors = try modelContext.fetch(descriptor)
        for cursor in cursors {
            modelContext.delete(cursor)
        }
        
        try modelContext.save()
        logger.info("Removed cursors for \(conversationId)")
    }
    
    /// Get all conversation IDs with stored cursors
    /// - Returns: Array of conversation IDs
    public func getAllConversationIds() throws -> [String] {
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { cursor in
                cursor.currentUserDID == currentUserDID
            },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        
        let cursors = try modelContext.fetch(descriptor)
        let ids = Set(cursors.map(\.conversationId))
        
        logger.debug("Found cursors for \(ids.count) conversations")
        return Array(ids)
    }
    
    /// Clean up old cursors (e.g., older than 30 days)
    /// - Parameter olderThan: Date threshold
    /// - Returns: Number of cursors deleted
    @discardableResult
    public func cleanupOldCursors(olderThan date: Date) throws -> Int {
        let descriptor = FetchDescriptor<ConversationCursor>(
            predicate: #Predicate { cursor in
                cursor.lastSeenAt < date && cursor.currentUserDID == currentUserDID
            }
        )
        
        let oldCursors = try modelContext.fetch(descriptor)
        let count = oldCursors.count
        
        for cursor in oldCursors {
            modelContext.delete(cursor)
        }
        
        try modelContext.save()
        logger.info("Cleaned up \(count) old cursors")
        
        return count
    }
    
    /// Update cursor with retry logic for transient failures
    /// - Parameters:
    ///   - conversationId: Conversation identifier
    ///   - cursor: New cursor value
    ///   - maxRetries: Maximum number of retry attempts
    public func updateCursorWithRetry(
        for conversationId: String,
        cursor: String,
        eventType: String = "messageEvent",
        maxRetries: Int = 3
    ) async throws {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                try updateCursor(for: conversationId, cursor: cursor, eventType: eventType)
                return
            } catch {
                lastError = error
                logger.warning("Cursor update attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    // Exponential backoff
                    let delay = Double(attempt) * 0.5
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        if let error = lastError {
            logger.error("Failed to update cursor after \(maxRetries) attempts")
            throw error
        }
    }
}

// MARK: - SwiftData Container Configuration

extension CursorStore {
    /// Create a ModelContainer configured for cursor storage
    /// - Parameter inMemory: If true, uses in-memory store (for testing)
    /// - Returns: Configured ModelContainer
    public static func createContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "mls-cursors",
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none  // Don't sync cursors to CloudKit
        )

        return try ModelContainer(for: ConversationCursor.self, configurations: configuration)
    }
}
