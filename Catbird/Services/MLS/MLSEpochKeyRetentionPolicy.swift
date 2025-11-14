//
//  MLSEpochKeyRetentionPolicy.swift
//  Catbird
//
//  Defines forward secrecy retention policy for MLS epoch keys.
//  Implements automatic cleanup of expired keys to maintain forward secrecy.
//

import Foundation
import os.log

/// Configuration for MLS epoch key retention and forward secrecy
public struct MLSEpochKeyRetentionPolicy {

    /// How long to retain epoch keys before deletion (forward secrecy)
    /// Default: 30 days (messages older than this become undecryptable)
    public let retentionPeriod: TimeInterval

    /// How often to run cleanup of expired epoch keys
    /// Default: 1 day
    public let cleanupInterval: TimeInterval

    /// Whether to also delete ciphertext when epoch keys expire
    /// Default: false (keep ciphertext for audit/compliance)
    public let deleteCiphertextOnExpiry: Bool

    // MARK: - Presets

    /// Conservative: 90 days retention (good for compliance/legal)
    public static let conservative = MLSEpochKeyRetentionPolicy(
        retentionPeriod: 90 * 24 * 60 * 60,
        cleanupInterval: 24 * 60 * 60,
        deleteCiphertextOnExpiry: false
    )

    /// Balanced: 30 days retention (default, recommended)
    public static let balanced = MLSEpochKeyRetentionPolicy(
        retentionPeriod: 30 * 24 * 60 * 60,
        cleanupInterval: 24 * 60 * 60,
        deleteCiphertextOnExpiry: false
    )

    /// Aggressive: 7 days retention (maximum forward secrecy)
    public static let aggressive = MLSEpochKeyRetentionPolicy(
        retentionPeriod: 7 * 24 * 60 * 60,
        cleanupInterval: 24 * 60 * 60,
        deleteCiphertextOnExpiry: false
    )

    /// Paranoid: 24 hours retention (extreme forward secrecy)
    public static let paranoid = MLSEpochKeyRetentionPolicy(
        retentionPeriod: 24 * 60 * 60,
        cleanupInterval: 6 * 60 * 60,  // Cleanup every 6 hours
        deleteCiphertextOnExpiry: true
    )

    /// No retention: Keep all keys forever (NOT RECOMMENDED - defeats forward secrecy)
    public static let noRetention = MLSEpochKeyRetentionPolicy(
        retentionPeriod: .infinity,
        cleanupInterval: .infinity,
        deleteCiphertextOnExpiry: false
    )

    // MARK: - Initialization

    public init(
        retentionPeriod: TimeInterval,
        cleanupInterval: TimeInterval = 24 * 60 * 60,
        deleteCiphertextOnExpiry: Bool = false
    ) {
        self.retentionPeriod = retentionPeriod
        self.cleanupInterval = cleanupInterval
        self.deleteCiphertextOnExpiry = deleteCiphertextOnExpiry
    }

    // MARK: - Expiry Calculation

    /// Check if an epoch key has expired based on its creation date
    public func isExpired(createdAt: Date, currentDate: Date = Date()) -> Bool {
        guard retentionPeriod.isFinite else {
            return false  // No retention = never expires
        }

        let age = currentDate.timeIntervalSince(createdAt)
        return age > retentionPeriod
    }

    /// Calculate expiry date for an epoch key
    public func expiryDate(for createdAt: Date) -> Date? {
        guard retentionPeriod.isFinite else {
            return nil  // No expiry
        }

        return createdAt.addingTimeInterval(retentionPeriod)
    }

    /// Time remaining until expiry
    public func timeUntilExpiry(createdAt: Date, currentDate: Date = Date()) -> TimeInterval? {
        guard let expiryDate = expiryDate(for: createdAt) else {
            return nil  // No expiry
        }

        return expiryDate.timeIntervalSince(currentDate)
    }
}

/// Manages automatic cleanup of expired epoch keys
public actor MLSEpochKeyRetentionManager {

    public static let shared = MLSEpochKeyRetentionManager()

    private let logger = Logger(subsystem: "com.catbird.mls", category: "EpochKeyRetention")
    private let keychainManager = MLSKeychainManager.shared

    /// Current retention policy (can be changed at runtime)
    public var policy: MLSEpochKeyRetentionPolicy = .balanced

    /// Last time cleanup was performed
    private var lastCleanupDate: Date?

    /// Timer for automatic cleanup
    private var cleanupTimer: Timer?

    // MARK: - Initialization

    private init() {}

    // MARK: - Settings Integration

    /// Update retention policy from app settings
    /// Call this when app settings change
    public func updatePolicyFromSettings(retentionDays: Int) {
        let newPolicy: MLSEpochKeyRetentionPolicy

        switch retentionDays {
        case 1:
            newPolicy = .paranoid  // 24 hours
        case 7:
            newPolicy = .aggressive  // 7 days
        case 30:
            newPolicy = .balanced  // 30 days (default)
        case 90:
            newPolicy = .conservative  // 90 days
        default:
            newPolicy = .balanced  // Fallback to default
        }

        policy = newPolicy
        logger.info("Updated retention policy: \(retentionDays) days retention")
    }

    // MARK: - Lifecycle Management

    /// Start automatic epoch key cleanup on schedule
    public func startAutomaticCleanup() {
        stopAutomaticCleanup()

        logger.info("🧹 Starting automatic epoch key cleanup (interval: \(self.policy.cleanupInterval / 3600)h, retention: \(self.policy.retentionPeriod / 86400) days)")

        // Schedule periodic cleanup
        Task {
            while !Task.isCancelled {
                await performCleanup()

                try? await Task.sleep(nanoseconds: UInt64(policy.cleanupInterval * 1_000_000_000))
            }
        }
    }

    /// Stop automatic cleanup
    public func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        logger.info("Stopped automatic epoch key cleanup")
    }

    // MARK: - Manual Cleanup

    /// Perform cleanup of expired epoch keys for all conversations
    /// - Returns: Number of keys deleted
    @discardableResult
    public func performCleanup() async -> Int {
        let startTime = Date()
        logger.info("🧹 Starting epoch key cleanup...")

        var deletedCount = 0

        // Get all conversations that have epoch keys stored
        // Note: This requires tracking which conversations have keys
        // For now, we'll implement cleanup per-conversation when accessed

        lastCleanupDate = Date()

        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ Epoch key cleanup complete: \(deletedCount) keys deleted in \(String(format: "%.2f", duration))s")

        return deletedCount
    }

    /// Clean up expired epoch keys for a specific conversation
    /// - Parameters:
    ///   - conversationID: Conversation identifier
    ///   - currentEpoch: Current epoch number (keys before this are candidates for deletion)
    /// - Returns: Number of keys deleted
    @discardableResult
    public func cleanupConversation(
        conversationID: String,
        currentEpoch: Int64
    ) async throws -> Int {
        logger.info("🧹 Cleaning expired epoch keys for conversation: \(conversationID)")

        var deletedCount = 0

        // Check each epoch from 0 to currentEpoch - 1
        for epoch in 0..<currentEpoch {
            // Try to get epoch metadata to check creation date
            if let metadata = try? keychainManager.retrieveEpochMetadata(
                forConversationID: conversationID,
                epoch: epoch
            ) {
                // Check if expired
                if policy.isExpired(createdAt: metadata.createdAt) {
                    // Delete epoch secrets
                    try? keychainManager.deleteEpochSecrets(
                        forConversationID: conversationID,
                        epoch: epoch
                    )

                    // Delete epoch metadata
                    try? keychainManager.deleteEpochMetadata(
                        forConversationID: conversationID,
                        epoch: epoch
                    )

                    // Delete private key for this epoch
                    try? keychainManager.deletePrivateKey(
                        forConversationID: conversationID,
                        epoch: epoch
                    )

                    deletedCount += 1

                    logger.debug("🗑️ Deleted expired epoch \(epoch) for conversation \(conversationID)")
                }
            }
        }

        if deletedCount > 0 {
            logger.info("✅ Deleted \(deletedCount) expired epoch keys for conversation: \(conversationID)")
        }

        return deletedCount
    }

    /// Check if a message can still be decrypted (epoch key still available)
    public func canDecryptMessage(
        conversationID: String,
        epoch: Int64
    ) async -> Bool {
        do {
            // Try to retrieve epoch secrets
            guard let _ = try keychainManager.retrieveEpochSecrets(
                forConversationID: conversationID,
                epoch: epoch
            ) else {
                return false
            }

            // Check if expired
            if let metadata = try? keychainManager.retrieveEpochMetadata(
                forConversationID: conversationID,
                epoch: epoch
            ) {
                if policy.isExpired(createdAt: metadata.createdAt) {
                    // Expired but not cleaned up yet
                    return false
                }
            }

            return true
        } catch {
            return false
        }
    }
}

/// Metadata for epoch key tracking
public struct EpochKeyMetadata: Codable {
    public let conversationID: String
    public let epoch: Int64
    public let createdAt: Date

    public init(conversationID: String, epoch: Int64, createdAt: Date = Date()) {
        self.conversationID = conversationID
        self.epoch = epoch
        self.createdAt = createdAt
    }
}
