//
//  MLSTreeHashPinning.swift
//  Catbird
//
//  Tree hash pinning for MLS state verification.
//  Detects group state divergence between clients.
//

import CatbirdMLSCore
import Foundation
import GRDB
import OSLog

// MARK: - Divergence Detection Result

/// Result of a tree hash verification check
public enum MLSTreeHashVerificationResult: Sendable {
    /// Hash matches pinned value
    case verified
    
    /// No pinned hash exists for this epoch (first time seeing it)
    case firstObservation
    
    /// Hash doesn't match pinned value - potential divergence
    case divergence(expected: Data, received: Data)
}

// MARK: - Tree Hash Pinning Service

/// Service for tree hash pinning and state divergence detection
///
/// This actor:
/// - Pins tree hashes at each epoch transition
/// - Verifies received hashes against pinned values
/// - Detects and logs state divergence
/// - Provides audit trail for forensic analysis
public actor MLSTreeHashPinning {
    
    // MARK: - Properties
    
    private let database: MLSDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "blue.catbird", category: "MLSTreeHashPinning")
    
    /// Callback for divergence detection
    private var divergenceHandler: ((MLSTreeHashDivergence) async -> Void)?
    
    // MARK: - Initialization
    
    public init(database: MLSDatabase) {
        self.database = database
        logger.info("📌 MLSTreeHashPinning initialized")
    }
    
    /// Configure the divergence handler
    public func setDivergenceHandler(_ handler: @escaping (MLSTreeHashDivergence) async -> Void) {
        self.divergenceHandler = handler
    }
    
    // MARK: - Pinning Operations
    
    /// Pin a tree hash for an epoch
    /// - Parameters:
    ///   - conversationID: The conversation
    ///   - epoch: The epoch number
    ///   - treeHash: The tree hash to pin
    ///   - source: Source of the hash (e.g., "local_commit", "received_commit")
    public func pinTreeHash(
        conversationID: String,
        epoch: Int64,
        treeHash: Data,
        source: String = "local_commit"
    ) async throws {
        // Check if already pinned
        if let existing = try await getPinnedHash(for: conversationID, epoch: epoch) {
            // Already pinned - verify consistency
            if existing.treeHash != treeHash {
                logger.error("⚠️ Tree hash mismatch for pinned epoch \(epoch)!")
                let divergence = MLSTreeHashDivergence(
                    conversationID: conversationID,
                    epoch: epoch,
                    expectedHash: existing.treeHash,
                    receivedHash: treeHash,
                    source: source
                )
                await handleDivergence(divergence)
            }
            return
        }
        
        // Create new pin
        let pin = MLSTreeHashPinModel(
            conversationID: conversationID,
            epoch: epoch,
            treeHash: treeHash,
            source: source
        )
        
        try await database.write { db in
            try pin.insert(db)
        }
        
        logger.debug("📌 Pinned tree hash for epoch \(epoch): \(pin.treeHashShort)")
    }
    
    /// Verify a received tree hash against pinned value
    /// - Parameters:
    ///   - conversationID: The conversation
    ///   - epoch: The epoch number
    ///   - receivedHash: The hash to verify
    ///   - source: Source of the received hash
    /// - Returns: Verification result
    public func verifyTreeHash(
        conversationID: String,
        epoch: Int64,
        receivedHash: Data,
        source: String = "received_commit"
    ) async throws -> MLSTreeHashVerificationResult {
        guard let pinned = try await getPinnedHash(for: conversationID, epoch: epoch) else {
            // First time seeing this epoch - pin it
            try await pinTreeHash(
                conversationID: conversationID,
                epoch: epoch,
                treeHash: receivedHash,
                source: source
            )
            return .firstObservation
        }
        
        // Compare hashes
        if pinned.matches(receivedHash) {
            logger.debug("✅ Tree hash verified for epoch \(epoch)")
            return .verified
        } else {
            logger.error("⚠️ Tree hash divergence detected at epoch \(epoch)!")
            
            let divergence = MLSTreeHashDivergence(
                conversationID: conversationID,
                epoch: epoch,
                expectedHash: pinned.treeHash,
                receivedHash: receivedHash,
                source: source
            )
            
            await handleDivergence(divergence)
            
            return .divergence(expected: pinned.treeHash, received: receivedHash)
        }
    }
    
    /// Get the pinned hash for an epoch
    public func getPinnedHash(
        for conversationID: String,
        epoch: Int64
    ) async throws -> MLSTreeHashPinModel? {
        try await database.read { db in
            try MLSTreeHashPinModel
                .filter(Column("conversationID") == conversationID)
                .filter(Column("epoch") == epoch)
                .fetchOne(db)
        }
    }
    
    /// Get all pinned hashes for a conversation
    public func getAllPinnedHashes(
        for conversationID: String,
        limit: Int = 100
    ) async throws -> [MLSTreeHashPinModel] {
        try await database.read { db in
            try MLSTreeHashPinModel
                .filter(Column("conversationID") == conversationID)
                .order(Column("epoch").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    /// Mark a pin as verified (by external confirmation)
    public func markVerified(
        conversationID: String,
        epoch: Int64
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE MLSTreeHashPinModel 
                    SET verified = 1 
                    WHERE conversationID = ? AND epoch = ?
                    """,
                arguments: [conversationID, epoch]
            )
        }
        
        logger.debug("✅ Marked epoch \(epoch) as verified")
    }
    
    // MARK: - Audit Trail
    
    /// Log an epoch transition with tree hash verification
    public func logEpochTransition(
        conversationID: String,
        fromEpoch: Int64,
        toEpoch: Int64,
        treeHash: Data,
        source: String
    ) async throws {
        // Pin the new epoch's hash
        try await pinTreeHash(
            conversationID: conversationID,
            epoch: toEpoch,
            treeHash: treeHash,
            source: source
        )
        
        logger.info("""
            📋 Epoch transition logged:
               - Conversation: \(conversationID.prefix(8))...
               - \(fromEpoch) → \(toEpoch)
               - Tree hash: \(treeHash.prefix(8).map { String(format: "%02x", $0) }.joined())...
               - Source: \(source)
            """)
    }
    
    /// Check for any unverified pins (potential security concerns)
    public func getUnverifiedPins(
        for conversationID: String
    ) async throws -> [MLSTreeHashPinModel] {
        try await database.read { db in
            try MLSTreeHashPinModel
                .filter(Column("conversationID") == conversationID)
                .filter(Column("verified") == false)
                .order(Column("epoch").asc)
                .fetchAll(db)
        }
    }
    
    // MARK: - Cleanup
    
    /// Prune old pins to save storage (keep last N epochs)
    public func pruneOldPins(
        for conversationID: String,
        keepLastN: Int = 100
    ) async throws {
        let pins = try await getAllPinnedHashes(for: conversationID, limit: Int.max)
        
        guard pins.count > keepLastN else { return }
        
        let pinsToDelete = pins.dropFirst(keepLastN)
        
        try await database.write { db in
            for pin in pinsToDelete {
                try db.execute(
                    sql: "DELETE FROM MLSTreeHashPinModel WHERE pinID = ?",
                    arguments: [pin.pinID]
                )
            }
        }
        
        logger.debug("🗑️ Pruned \(pinsToDelete.count) old tree hash pins")
    }
    
    // MARK: - Private Helpers
    
    private func handleDivergence(_ divergence: MLSTreeHashDivergence) async {
        logger.error("""
            🚨 TREE HASH DIVERGENCE DETECTED:
               \(divergence.description)
               Source: \(divergence.source)
            """)
        
        // Record divergence in database for forensics
        do {
            try await database.write { db in
                let metadata = try JSONEncoder().encode([
                    "expected": divergence.expectedHash.base64EncodedString(),
                    "received": divergence.receivedHash.base64EncodedString()
                ])
                
                try db.execute(
                    sql: """
                        INSERT INTO MLSValidationAuditLog 
                        (id, conversationID, timestamp, operationType, credentialDID, epoch, decision, reason, metadata)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        divergence.conversationID,
                        divergence.detectedAt,
                        "tree_hash_verification",
                        nil,
                        divergence.epoch,
                        "divergence_detected",
                        divergence.description,
                        metadata
                    ]
                )
            }
        } catch {
            logger.error("Failed to record divergence: \(error.localizedDescription)")
        }
        
        // Notify handler
        if let handler = divergenceHandler {
            await handler(divergence)
        }
    }
}
