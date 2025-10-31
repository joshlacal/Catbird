//
//  MLSStorageIntegration.swift
//  Catbird
//
//  Integration example demonstrating MLS Storage usage
//

import Foundation
import CoreData
import Combine

/// Example integration showing how to use MLS Storage in the application
@MainActor
class MLSStorageIntegrationExample: ObservableObject {
    
    private let storage = MLSStorage.shared
    private let keychainManager = MLSKeychainManager.shared
    
    @Published var conversations: [MLSConversation] = []
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        setupReactiveUpdates()
    }
    
    // MARK: - Reactive Updates
    
    private func setupReactiveUpdates() {
        // Setup FetchedResultsController for automatic UI updates
        storage.setupConversationsFRC()
        
        // Subscribe to conversation updates
        storage.conversationsPublisher
            .sink { [weak self] _ in
                self?.conversations = self?.storage.conversations ?? []
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Example: Create New Group
    
    func createNewGroup(
        groupID: Data,
        title: String,
        memberDIDs: [String]
    ) async throws {
        let conversationID = UUID().uuidString
        
        // 1. Create conversation in Core Data
        let conversation = try storage.createConversation(
            conversationID: conversationID,
            groupID: groupID,
            epoch: 0,
            title: title
        )
        
        // 2. Generate and store cryptographic keys
        let signatureKey = try keychainManager.generateSecureRandomKey(length: 32)
        try keychainManager.storeSignatureKey(signatureKey, forConversationID: conversationID)
        
        let encryptionKey = try keychainManager.generateSecureRandomKey(length: 32)
        try keychainManager.storeEncryptionKey(encryptionKey, forConversationID: conversationID)
        
        // 3. Add members
        for (index, did) in memberDIDs.enumerated() {
            _ = try storage.createMember(
                memberID: UUID().uuidString,
                conversationID: conversationID,
                did: did,
                leafIndex: Int32(index)
            )
        }
        
        print("✅ Created group: \(title) with \(memberDIDs.count) members")
    }
    
    // MARK: - Example: Send Message
    
    func sendMessage(
        content: String,
        to conversationID: String,
        from senderDID: String
    ) async throws {
        // 1. Fetch conversation to get current epoch
        guard let conversation = try storage.fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }
        
        let currentEpoch = conversation.epoch
        
        // 2. Retrieve encryption key
        guard let encryptionKey = try keychainManager.retrieveEncryptionKey(
            forConversationID: conversationID
        ) else {
            throw KeychainError.retrieveFailed(errSecItemNotFound)
        }
        
        // 3. Encrypt content (simplified - actual MLS encryption would be used)
        let encryptedContent = Data(content.utf8) // Replace with actual MLS encryption
        
        // 4. Get next sequence number
        let messages = try storage.fetchMessages(forConversationID: conversationID)
        let nextSequence = Int64(messages.count + 1)
        
        // 5. Store message
        let message = try storage.createMessage(
            messageID: UUID().uuidString,
            conversationID: conversationID,
            senderID: senderDID,
            content: encryptedContent,
            contentType: "text",
            epoch: currentEpoch,
            sequenceNumber: nextSequence
        )
        
        // 6. Mark as sent (would be done after network confirmation)
        try storage.updateMessage(message, isSent: true)
        
        print("✅ Sent message in conversation: \(conversationID)")
    }
    
    // MARK: - Example: Receive Message
    
    func receiveMessage(
        messageID: String,
        conversationID: String,
        senderDID: String,
        encryptedContent: Data,
        epoch: Int64,
        sequence: Int64
    ) async throws {
        // 1. Retrieve decryption key
        guard let privateKey = try keychainManager.retrievePrivateKey(
            forConversationID: conversationID,
            epoch: epoch
        ) else {
            throw KeychainError.retrieveFailed(errSecItemNotFound)
        }
        
        // 2. Decrypt content (simplified - actual MLS decryption would be used)
        let decryptedContent = encryptedContent // Replace with actual MLS decryption
        
        // 3. Store message
        let message = try storage.createMessage(
            messageID: messageID,
            conversationID: conversationID,
            senderID: senderDID,
            content: decryptedContent,
            contentType: "text",
            epoch: epoch,
            sequenceNumber: sequence
        )
        
        // 4. Mark as delivered
        try storage.updateMessage(message, isDelivered: true)
        
        print("✅ Received message in conversation: \(conversationID)")
    }
    
    // MARK: - Example: Add Member
    
    func addMember(
        did: String,
        handle: String,
        to conversationID: String
    ) async throws {
        // 1. Fetch conversation
        guard let conversation = try storage.fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }
        
        // 2. Get current members to determine leaf index
        let currentMembers = try storage.fetchMembers(forConversationID: conversationID)
        let nextLeafIndex = Int32(currentMembers.count)
        
        // 3. Add member
        _ = try storage.createMember(
            memberID: UUID().uuidString,
            conversationID: conversationID,
            did: did,
            handle: handle,
            leafIndex: nextLeafIndex
        )
        
        // 4. Advance epoch and rotate keys
        let newEpoch = conversation.epoch + 1
        try storage.updateConversation(conversation, epoch: newEpoch)
        
        // Generate new epoch keys
        let newPrivateKey = try keychainManager.generateSecureRandomKey(length: 32)
        try keychainManager.storePrivateKey(
            newPrivateKey,
            forConversationID: conversationID,
            epoch: newEpoch
        )
        
        // Clean up old epoch keys (forward secrecy)
        try keychainManager.deletePrivateKeys(
            forConversationID: conversationID,
            beforeEpoch: newEpoch - 1 // Keep previous epoch for late messages
        )
        
        print("✅ Added member \(handle) to conversation: \(conversationID)")
    }
    
    // MARK: - Example: Remove Member
    
    func removeMember(
        memberID: String,
        from conversationID: String
    ) async throws {
        // 1. Fetch member
        guard let member = try storage.fetchMember(byID: memberID) else {
            throw MLSStorageError.memberNotFound(memberID)
        }
        
        // 2. Fetch conversation
        guard let conversation = try storage.fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }
        
        // 3. Mark member as inactive
        try storage.updateMember(member, isActive: false)
        
        // 4. Advance epoch and rotate keys
        let newEpoch = conversation.epoch + 1
        try storage.updateConversation(conversation, epoch: newEpoch)
        
        // Generate new epoch keys
        let newPrivateKey = try keychainManager.generateSecureRandomKey(length: 32)
        try keychainManager.storePrivateKey(
            newPrivateKey,
            forConversationID: conversationID,
            epoch: newEpoch
        )
        
        // Clean up old epoch keys
        try keychainManager.deletePrivateKeys(
            forConversationID: conversationID,
            beforeEpoch: newEpoch - 1
        )
        
        print("✅ Removed member from conversation: \(conversationID)")
    }
    
    // MARK: - Example: Generate Key Package
    
    func generateKeyPackage(for userDID: String) async throws -> String {
        // 1. Generate HPKE key pair
        let hpkePrivateKey = try keychainManager.generateSecureRandomKey(length: 32)
        let keyPackageID = UUID().uuidString
        
        // 2. Create key package data (simplified)
        let keyPackageData = Data("key_package_\(keyPackageID)".utf8)
        
        // 3. Store HPKE private key
        try keychainManager.storeHPKEPrivateKey(hpkePrivateKey, forKeyPackageID: keyPackageID)
        
        // 4. Store key package in Core Data
        let expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60) // 7 days
        _ = try storage.createKeyPackage(
            keyPackageID: keyPackageID,
            keyPackageData: keyPackageData,
            cipherSuite: 1,
            ownerDID: userDID,
            expiresAt: expiresAt
        )
        
        print("✅ Generated key package: \(keyPackageID)")
        return keyPackageID
    }
    
    // MARK: - Example: Use Key Package
    
    func useKeyPackage(
        keyPackageID: String,
        for conversationID: String
    ) async throws {
        // 1. Fetch key package
        guard let keyPackage = try storage.fetchKeyPackage(byID: keyPackageID) else {
            throw MLSStorageError.keyPackageNotFound(keyPackageID)
        }
        
        // 2. Verify not already used
        guard !keyPackage.isUsed else {
            throw NSError(domain: "MLSStorage", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Key package already used"
            ])
        }
        
        // 3. Mark as used
        try storage.markKeyPackageAsUsed(keyPackage, conversationID: conversationID)
        
        print("✅ Used key package: \(keyPackageID)")
    }
    
    // MARK: - Example: Cleanup
    
    func performMaintenance() async throws {
        // 1. Delete expired key packages
        try storage.deleteExpiredKeyPackages()
        
        // 2. Clean up old messages (example: older than 90 days)
        let conversations = try storage.fetchAllConversations()
        let cutoffDate = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        
        for conversation in conversations {
            guard let conversationID = conversation.conversationID else { continue }
            
            let messages = try storage.fetchMessages(forConversationID: conversationID)
            for message in messages {
                if let timestamp = message.timestamp, timestamp < cutoffDate {
                    try storage.deleteMessage(message)
                }
            }
        }
        
        print("✅ Maintenance completed")
    }
    
    // MARK: - Example: Migration
    
    func migrateFromLegacyStorage() async throws {
        let migration = MLSStorageMigration()
        
        // Check if migration needed
        guard !migration.isMigrationCompleted else {
            print("ℹ️ Migration already completed")
            return
        }
        
        print("🔄 Starting migration...")
        try await migration.migrateIfNeeded()
        print("✅ Migration completed successfully")
    }
}
