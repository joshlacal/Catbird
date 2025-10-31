//
//  MLSStorageMigration.swift
//  Catbird
//
//  Handles migration from existing storage to MLS Core Data model
//

import Foundation
import CoreData
import os.log

/// Manages migration from legacy storage systems to MLS Core Data
public class MLSStorageMigration {
    
    private let storage: MLSStorage
    private let keychainManager: MLSKeychainManager
    private let logger = Logger(subsystem: "com.catbird.mls", category: "MLSStorageMigration")
    
    // MARK: - Initialization
    
    public init(
        storage: MLSStorage = .shared,
        keychainManager: MLSKeychainManager = .shared
    ) {
        self.storage = storage
        self.keychainManager = keychainManager
    }
    
    // MARK: - Migration Status
    
    private let migrationStatusKey = "com.catbird.mls.migration.completed"
    
    public var isMigrationCompleted: Bool {
        UserDefaults.standard.bool(forKey: migrationStatusKey)
    }
    
    public func markMigrationCompleted() {
        UserDefaults.standard.set(true, forKey: migrationStatusKey)
        logger.info("Migration marked as completed")
    }
    
    // MARK: - Migration Entry Point
    
    @MainActor
    public func migrateIfNeeded() async throws {
        guard !isMigrationCompleted else {
            logger.info("Migration already completed, skipping")
            return
        }
        
        logger.info("Starting MLS storage migration")
        
        do {
            try await performMigration()
            markMigrationCompleted()
            logger.info("Migration completed successfully")
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Migration Implementation
    
    @MainActor
    private func performMigration() async throws {
        // Step 1: Check for legacy data sources
        let legacyData = try await detectLegacyData()
        
        guard !legacyData.isEmpty else {
            logger.info("No legacy data found to migrate")
            return
        }
        
        logger.info("Found \(legacyData.count) legacy data sources to migrate")
        
        // Step 2: Migrate each data source
        for (source, data) in legacyData {
            try await migrateLegacyDataSource(source: source, data: data)
        }
        
        // Step 3: Verify migration
        try await verifyMigration()
        
        // Step 4: Clean up legacy data (optional, commented out for safety)
        // try await cleanupLegacyData()
    }
    
    // MARK: - Legacy Data Detection
    
    private func detectLegacyData() async throws -> [(String, [String: Any])] {
        var legacySources: [(String, [String: Any])] = []
        
        // Check UserDefaults for legacy conversation data
        if let legacyConversations = UserDefaults.standard.dictionary(forKey: "legacy.mls.conversations") {
            legacySources.append(("conversations", legacyConversations))
        }
        
        // Check for legacy file-based storage
        if let legacyFiles = try? await detectLegacyFiles() {
            legacySources.append(("files", legacyFiles))
        }
        
        return legacySources
    }
    
    private func detectLegacyFiles() async throws -> [String: Any] {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        
        let mlsDirectory = documentsURL.appendingPathComponent("MLS", isDirectory: true)
        
        guard fileManager.fileExists(atPath: mlsDirectory.path) else {
            return [:]
        }
        
        var legacyFiles: [String: Any] = [:]
        let contents = try fileManager.contentsOfDirectory(
            at: mlsDirectory,
            includingPropertiesForKeys: nil
        )
        
        for fileURL in contents {
            if fileURL.pathExtension == "json" {
                let data = try Data(contentsOf: fileURL)
                if let json = try? JSONSerialization.jsonObject(with: data) {
                    legacyFiles[fileURL.lastPathComponent] = json
                }
            }
        }
        
        return legacyFiles
    }
    
    // MARK: - Migration by Data Source
    
    @MainActor
    private func migrateLegacyDataSource(source: String, data: [String: Any]) async throws {
        logger.info("Migrating legacy data source: \(source)")
        
        switch source {
        case "conversations":
            try await migrateConversations(from: data)
        case "files":
            try await migrateFiles(from: data)
        default:
            logger.warning("Unknown legacy data source: \(source)")
        }
    }
    
    @MainActor
    private func migrateConversations(from data: [String: Any]) async throws {
        for (conversationID, conversationData) in data {
            guard let convDict = conversationData as? [String: Any] else {
                continue
            }
            
            // Extract conversation properties
            let groupIDString = convDict["groupID"] as? String ?? ""
            let groupID = Data(base64Encoded: groupIDString) ?? Data()
            let epoch = convDict["epoch"] as? Int64 ?? 0
            let title = convDict["title"] as? String
            
            // Create or update conversation
            let conversation: MLSConversation
            if let existing = try storage.fetchConversation(byID: conversationID) {
                conversation = existing
                try storage.updateConversation(
                    existing,
                    epoch: epoch,
                    title: title
                )
            } else {
                conversation = try storage.createConversation(
                    conversationID: conversationID,
                    groupID: groupID,
                    epoch: epoch,
                    title: title
                )
            }
            
            // Migrate members
            if let members = convDict["members"] as? [[String: Any]] {
                try await migrateMembers(members, toConversationID: conversationID)
            }
            
            // Migrate messages
            if let messages = convDict["messages"] as? [[String: Any]] {
                try await migrateMessages(messages, toConversationID: conversationID)
            }
            
            logger.info("Migrated conversation: \(conversationID)")
        }
    }
    
    @MainActor
    private func migrateMembers(_ members: [[String: Any]], toConversationID conversationID: String) async throws {
        for memberDict in members {
            let memberID = memberDict["id"] as? String ?? UUID().uuidString
            let did = memberDict["did"] as? String ?? ""
            let handle = memberDict["handle"] as? String
            let displayName = memberDict["displayName"] as? String
            let leafIndex = memberDict["leafIndex"] as? Int32 ?? 0
            
            // Check if member already exists
            if let _ = try storage.fetchMember(byID: memberID) {
                continue
            }
            
            _ = try storage.createMember(
                memberID: memberID,
                conversationID: conversationID,
                did: did,
                handle: handle,
                displayName: displayName,
                leafIndex: leafIndex
            )
        }
    }
    
    @MainActor
    private func migrateMessages(_ messages: [[String: Any]], toConversationID conversationID: String) async throws {
        for messageDict in messages {
            let messageID = messageDict["id"] as? String ?? UUID().uuidString
            let senderID = messageDict["sender"] as? String ?? ""
            let contentString = messageDict["content"] as? String ?? ""
            let content = Data(contentString.utf8)
            let contentType = messageDict["type"] as? String ?? "text"
            let epoch = messageDict["epoch"] as? Int64 ?? 0
            let sequenceNumber = messageDict["sequence"] as? Int64 ?? 0
            
            // Check if message already exists
            if let _ = try storage.fetchMessage(byID: messageID) {
                continue
            }
            
            _ = try storage.createMessage(
                messageID: messageID,
                conversationID: conversationID,
                senderID: senderID,
                content: content,
                contentType: contentType,
                epoch: epoch,
                sequenceNumber: sequenceNumber
            )
        }
    }
    
    @MainActor
    private func migrateFiles(from data: [String: Any]) async throws {
        for (filename, fileData) in data {
            logger.info("Processing legacy file: \(filename)")
            
            // Process based on file type
            if filename.contains("conversation") {
                if let convDict = fileData as? [String: Any] {
                    try await migrateConversations(from: [filename: convDict])
                }
            }
        }
    }
    
    // MARK: - Verification
    
    @MainActor
    private func verifyMigration() async throws {
        logger.info("Verifying migration...")
        
        // Verify conversations were migrated
        let conversations = try storage.fetchAllConversations(activeOnly: false)
        logger.info("Verified \(conversations.count) conversations migrated")
        
        // Verify keychain access
        try keychainManager.verifyKeychainAccess()
        
        logger.info("Migration verification completed")
    }
    
    // MARK: - Cleanup (Use with caution)
    
    private func cleanupLegacyData() async throws {
        logger.warning("Cleaning up legacy data...")
        
        // Remove UserDefaults keys
        UserDefaults.standard.removeObject(forKey: "legacy.mls.conversations")
        
        // Remove legacy files
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        
        let mlsDirectory = documentsURL.appendingPathComponent("MLS", isDirectory: true)
        
        if fileManager.fileExists(atPath: mlsDirectory.path) {
            try fileManager.removeItem(at: mlsDirectory)
        }
        
        logger.info("Legacy data cleanup completed")
    }
    
    // MARK: - Rollback Support
    
    public func rollbackMigration() async throws {
        logger.warning("Rolling back migration...")
        
        // Delete all migrated data from Core Data
        let conversations = try await storage.fetchAllConversations(activeOnly: false)
        for conversation in conversations {
            try await storage.deleteConversation(conversation)
        }
        
        // Clear migration status
        UserDefaults.standard.removeObject(forKey: migrationStatusKey)
        
        logger.info("Migration rollback completed")
    }
}
