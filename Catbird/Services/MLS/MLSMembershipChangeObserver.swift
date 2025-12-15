//
//  MLSMembershipChangeObserver.swift
//  Catbird
//
//  Observes and surfaces MLS group membership changes to the UI.
//  Provides non-blocking notifications/toasts for member joins and departures.
//

import CatbirdMLSCore
import Foundation
import GRDB
import OSLog

// MARK: - Membership Change Types

/// Individual membership change event
public struct MLSMembershipChange: Sendable, Identifiable {
    public enum ChangeType: String, Sendable {
        case added
        case removed
        case updated
        case roleChanged
    }
    
    public let id: String
    public let type: ChangeType
    public let memberDID: String
    public let memberDisplayName: String?
    public let actorDID: String?
    public let actorDisplayName: String?
    public let epoch: Int64
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        type: ChangeType,
        memberDID: String,
        memberDisplayName: String? = nil,
        actorDID: String? = nil,
        actorDisplayName: String? = nil,
        epoch: Int64,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.memberDID = memberDID
        self.memberDisplayName = memberDisplayName
        self.actorDID = actorDID
        self.actorDisplayName = actorDisplayName
        self.epoch = epoch
        self.timestamp = timestamp
    }
    
    /// Human-readable description of the change
    public var description: String {
        let member = memberDisplayName ?? shortenDID(memberDID)
        
        switch type {
        case .added:
            if let actor = actorDisplayName ?? actorDID.map(shortenDID) {
                return "\(member) was added by \(actor)"
            }
            return "\(member) joined"
        case .removed:
            if let actor = actorDisplayName ?? actorDID.map(shortenDID) {
                return "\(member) was removed by \(actor)"
            }
            return "\(member) left"
        case .updated:
            return "\(member) updated their device"
        case .roleChanged:
            return "\(member)'s role was changed"
        }
    }
    
    private func shortenDID(_ did: String) -> String {
        if did.hasPrefix("did:plc:") {
            return String(did.dropFirst(8).prefix(8)) + "..."
        }
        return String(did.prefix(16)) + "..."
    }
}

/// Batch of membership changes for a single epoch transition
public struct MLSMembershipChangeBatch: Sendable, Identifiable {
    public let id: String
    public let conversationID: String
    public let fromEpoch: Int64
    public let toEpoch: Int64
    public let changes: [MLSMembershipChange]
    public let timestamp: Date
    
    public var hasChanges: Bool { !changes.isEmpty }
    
    /// Summary suitable for notification display
    public var notificationSummary: String {
        let added = changes.filter { $0.type == .added }
        let removed = changes.filter { $0.type == .removed }
        
        var parts: [String] = []
        
        if added.count == 1, let first = added.first {
            parts.append("\(first.memberDisplayName ?? "Someone") joined")
        } else if added.count > 1 {
            parts.append("\(added.count) people joined")
        }
        
        if removed.count == 1, let first = removed.first {
            parts.append("\(first.memberDisplayName ?? "Someone") left")
        } else if removed.count > 1 {
            parts.append("\(removed.count) people left")
        }
        
        return parts.joined(separator: " • ")
    }
    
    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        fromEpoch: Int64,
        toEpoch: Int64,
        changes: [MLSMembershipChange],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.fromEpoch = fromEpoch
        self.toEpoch = toEpoch
        self.changes = changes
        self.timestamp = timestamp
    }
}

// MARK: - Membership Change Observer

/// Observes MLS group membership changes and surfaces them to the UI
///
/// This actor:
/// - Detects membership changes by comparing roster snapshots
/// - Creates MLSMembershipChange events for each detected change
/// - Surfaces changes via non-blocking notifications/toasts
/// - Records changes in the audit log
public actor MLSMembershipChangeObserver {
    
    // MARK: - Properties
    
    private let database: MLSDatabase
    private let currentUserDID: String
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "blue.catbird", category: "MLSMembershipChangeObserver")
    
    /// Callback for surfacing membership changes to the UI
    private var changeHandler: ((MLSMembershipChangeBatch) async -> Void)?
    
    /// Profile lookup function (DID -> display name)
    private var profileLookup: ((String) async -> String?)?
    
    // MARK: - Initialization
    
    public init(database: MLSDatabase, currentUserDID: String) {
        self.database = database
        self.currentUserDID = currentUserDID
        logger.info("👥 MLSMembershipChangeObserver initialized")
    }
    
    /// Configure the change handler for UI notifications
    public func setChangeHandler(_ handler: @escaping (MLSMembershipChangeBatch) async -> Void) {
        self.changeHandler = handler
    }
    
    /// Configure the profile lookup function
    public func setProfileLookup(_ lookup: @escaping (String) async -> String?) {
        self.profileLookup = lookup
    }
    
    // MARK: - Change Detection
    
    /// Detect membership changes between two epochs
    /// - Parameters:
    ///   - conversationID: The conversation to check
    ///   - oldEpoch: Previous epoch number
    ///   - newEpoch: Current epoch number
    ///   - newMembers: Current member list (from FFI)
    ///   - actorDID: DID of the actor who triggered the change (if known)
    /// - Returns: Batch of detected changes, or nil if no changes
    public func detectChanges(
        conversationID: String,
        oldEpoch: Int64,
        newEpoch: Int64,
        newMembers: [String],
        actorDID: String? = nil
    ) async throws -> MLSMembershipChangeBatch? {
        logger.debug("🔍 Detecting changes for \(conversationID.prefix(8))... epoch \(oldEpoch) → \(newEpoch)")
        
        // Fetch previous roster snapshot
        let previousSnapshot = try await fetchRosterSnapshot(for: conversationID, epoch: oldEpoch)
        let previousMembers = Set(previousSnapshot?.memberDIDs ?? [])
        let currentMembers = Set(newMembers)
        
        // Calculate diff
        let addedDIDs = currentMembers.subtracting(previousMembers)
        let removedDIDs = previousMembers.subtracting(currentMembers)
        
        // No changes
        if addedDIDs.isEmpty && removedDIDs.isEmpty {
            logger.debug("   No membership changes detected")
            return nil
        }
        
        // Build change events
        var changes: [MLSMembershipChange] = []
        
        for did in addedDIDs {
            let displayName = await profileLookup?(did)
            changes.append(MLSMembershipChange(
                type: .added,
                memberDID: did,
                memberDisplayName: displayName,
                actorDID: actorDID,
                epoch: newEpoch
            ))
        }
        
        for did in removedDIDs {
            let displayName = await profileLookup?(did)
            changes.append(MLSMembershipChange(
                type: .removed,
                memberDID: did,
                memberDisplayName: displayName,
                actorDID: actorDID,
                epoch: newEpoch
            ))
        }
        
        let batch = MLSMembershipChangeBatch(
            conversationID: conversationID,
            fromEpoch: oldEpoch,
            toEpoch: newEpoch,
            changes: changes
        )
        
        logger.info("👥 Detected \(changes.count) membership changes: \(batch.notificationSummary)")
        
        return batch
    }
    
    /// Process and surface membership changes after a commit merge
    /// - Parameters:
    ///   - conversationID: The conversation that changed
    ///   - oldEpoch: Previous epoch
    ///   - newEpoch: New epoch after commit
    ///   - newMembers: Current member list from FFI
    ///   - treeHash: Tree hash for the new epoch (for pinning)
    ///   - actorDID: DID of the commit author (if known)
    public func processEpochTransition(
        conversationID: String,
        oldEpoch: Int64,
        newEpoch: Int64,
        newMembers: [String],
        treeHash: Data?,
        actorDID: String? = nil
    ) async throws {
        // 1. Detect changes
        guard let batch = try await detectChanges(
            conversationID: conversationID,
            oldEpoch: oldEpoch,
            newEpoch: newEpoch,
            newMembers: newMembers,
            actorDID: actorDID
        ) else {
            // No membership changes, but still save roster snapshot
            try await saveRosterSnapshot(
                conversationID: conversationID,
                epoch: newEpoch,
                members: newMembers,
                treeHash: treeHash
            )
            return
        }
        
        // 2. Save roster snapshot
        try await saveRosterSnapshot(
            conversationID: conversationID,
            epoch: newEpoch,
            members: newMembers,
            treeHash: treeHash
        )
        
        // 3. Record membership events
        try await recordMembershipEvents(batch)
        
        // 4. Surface changes via UI callback
        if let handler = changeHandler {
            await handler(batch)
        }
    }
    
    // MARK: - Roster Snapshot Management
    
    private func fetchRosterSnapshot(for conversationID: String, epoch: Int64) async throws -> MLSRosterSnapshotModel? {
        try await database.read { db in
            try MLSRosterSnapshotModel
                .filter(Column("conversationID") == conversationID)
                .filter(Column("epoch") == epoch)
                .fetchOne(db)
        }
    }
    
    private func saveRosterSnapshot(
        conversationID: String,
        epoch: Int64,
        members: [String],
        treeHash: Data?
    ) async throws {
        // Get previous snapshot ID for chain
        let previousSnapshot = try await database.read { db in
            try MLSRosterSnapshotModel
                .filter(Column("conversationID") == conversationID)
                .order(Column("epoch").desc)
                .fetchOne(db)
        }
        
        let snapshot = MLSRosterSnapshotModel(
            conversationID: conversationID,
            epoch: epoch,
            memberDIDs: members,
            treeHash: treeHash,
            previousSnapshotID: previousSnapshot?.snapshotID
        )
        
        try await database.write { db in
            try snapshot.insert(db)
        }
        
        logger.debug("💾 Saved roster snapshot for epoch \(epoch) with \(members.count) members")
    }
    
    private func recordMembershipEvents(_ batch: MLSMembershipChangeBatch) async throws {
        try await database.write { db in
            for change in batch.changes {
                let eventType: MLSMembershipEventModel.EventType
                switch change.type {
                case .added: eventType = .joined
                case .removed: eventType = .left
                case .updated: eventType = .deviceAdded
                case .roleChanged: eventType = .roleChanged
                }
                
                let event = MLSMembershipEventModel(
                    id: change.id,
                    conversationID: batch.conversationID,
                    currentUserDID: currentUserDID,
                    memberDID: change.memberDID,
                    eventType: eventType,
                    timestamp: change.timestamp,
                    actorDID: change.actorDID,
                    epoch: change.epoch,
                    metadata: nil
                )
                
                try event.insert(db)
            }
        }
        
        logger.debug("📝 Recorded \(batch.changes.count) membership events")
    }
    
    // MARK: - History Queries
    
    /// Get recent membership changes for a conversation
    public func getRecentChanges(
        for conversationID: String,
        limit: Int = 50
    ) async throws -> [MLSMembershipEventModel] {
        try await database.read { db in
            try MLSMembershipEventModel
                .filter(Column("conversationID") == conversationID)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    /// Get roster at a specific epoch
    public func getRoster(
        for conversationID: String,
        at epoch: Int64
    ) async throws -> [String]? {
        let snapshot = try await fetchRosterSnapshot(for: conversationID, epoch: epoch)
        return snapshot?.memberDIDs
    }
}
