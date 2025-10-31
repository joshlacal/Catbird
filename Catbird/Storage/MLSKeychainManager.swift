//
//  MLSKeychainManager.swift
//  Catbird
//
//  Secure Keychain storage for MLS cryptographic materials
//

import Foundation
import Security
import os.log

/// Manages secure storage of MLS cryptographic materials in Keychain
public class MLSKeychainManager {
    
    // MARK: - Singleton
    
    public static let shared = MLSKeychainManager()
    
    private let logger = Logger(subsystem: "com.catbird.mls", category: "MLSKeychainManager")
    
    // MARK: - Keychain Keys
    
    private enum KeychainKey {
        case groupState(conversationID: String)
        case privateKey(conversationID: String, epoch: Int64)
        case signatureKey(conversationID: String)
        case encryptionKey(conversationID: String)
        case epochSecrets(conversationID: String, epoch: Int64)
        case hpkePrivateKey(keyPackageID: String)
        case currentEpoch(conversationID: String)
        
        var key: String {
            switch self {
            case .groupState(let id):
                return "mls.groupstate.\(id)"
            case .privateKey(let id, let epoch):
                return "mls.privatekey.\(id).epoch.\(epoch)"
            case .signatureKey(let id):
                return "mls.signaturekey.\(id)"
            case .encryptionKey(let id):
                return "mls.encryptionkey.\(id)"
            case .epochSecrets(let id, let epoch):
                return "mls.epochsecrets.\(id).epoch.\(epoch)"
            case .hpkePrivateKey(let id):
                return "mls.hpke.privatekey.\(id)"
            case .currentEpoch(let id):
                return "mls.currentepoch.\(id)"
            }
        }
        
        var accessGroup: String {
            "com.catbird.mls.keychain"
        }
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Group State Management
    
    /// Store encrypted group state for a conversation
    public func storeGroupState(_ data: Data, forConversationID conversationID: String) throws {
        let key = KeychainKey.groupState(conversationID: conversationID)
        try store(data, forKey: key.key, accessible: kSecAttrAccessibleAfterFirstUnlock)
        logger.info("Stored group state for conversation: \(conversationID)")
    }
    
    /// Retrieve encrypted group state for a conversation
    public func retrieveGroupState(forConversationID conversationID: String) throws -> Data? {
        let key = KeychainKey.groupState(conversationID: conversationID)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete group state for a conversation
    public func deleteGroupState(forConversationID conversationID: String) throws {
        let key = KeychainKey.groupState(conversationID: conversationID)
        try delete(forKey: key.key)
        logger.info("Deleted group state for conversation: \(conversationID)")
    }
    
    // MARK: - Epoch Management
    
    /// Store current epoch for a conversation
    public func storeCurrentEpoch(_ epoch: Int, forConversationID conversationID: String) throws {
        let epochData = withUnsafeBytes(of: Int64(epoch)) { Data($0) }
        let key = KeychainKey.currentEpoch(conversationID: conversationID)
        try store(epochData, forKey: key.key, accessible: kSecAttrAccessibleAfterFirstUnlock)
        logger.debug("Stored current epoch \(epoch) for conversation: \(conversationID)")
    }
    
    /// Retrieve current epoch for a conversation
    public func retrieveCurrentEpoch(forConversationID conversationID: String) throws -> Int? {
        let key = KeychainKey.currentEpoch(conversationID: conversationID)
        guard let data = try retrieve(forKey: key.key) else {
            return nil
        }
        
        guard data.count == MemoryLayout<Int64>.size else {
            logger.error("Invalid epoch data size for conversation: \(conversationID)")
            return nil
        }
        
        let epoch = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        return Int(epoch)
    }
    
    /// Delete stored epoch for a conversation
    public func deleteCurrentEpoch(forConversationID conversationID: String) throws {
        let key = KeychainKey.currentEpoch(conversationID: conversationID)
        try delete(forKey: key.key)
        logger.debug("Deleted current epoch for conversation: \(conversationID)")
    }
    
    // MARK: - Private Key Management
    
    /// Store private key for a specific epoch
    public func storePrivateKey(
        _ key: Data,
        forConversationID conversationID: String,
        epoch: Int64
    ) throws {
        let keychainKey = KeychainKey.privateKey(conversationID: conversationID, epoch: epoch)
        try store(key, forKey: keychainKey.key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        logger.info("Stored private key for conversation: \(conversationID), epoch: \(epoch)")
    }
    
    /// Retrieve private key for a specific epoch
    public func retrievePrivateKey(
        forConversationID conversationID: String,
        epoch: Int64
    ) throws -> Data? {
        let key = KeychainKey.privateKey(conversationID: conversationID, epoch: epoch)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete private key for a specific epoch
    public func deletePrivateKey(
        forConversationID conversationID: String,
        epoch: Int64
    ) throws {
        let key = KeychainKey.privateKey(conversationID: conversationID, epoch: epoch)
        try delete(forKey: key.key)
        logger.debug("Deleted private key for conversation: \(conversationID), epoch: \(epoch)")
    }
    
    /// Delete all private keys for epochs before the specified epoch
    public func deletePrivateKeys(
        forConversationID conversationID: String,
        beforeEpoch epoch: Int64
    ) throws {
        // Keychain doesn't support range queries, so we need to track epochs separately
        // For now, we'll delete keys one by one for known epochs
        for oldEpoch in 0..<epoch {
            try? deletePrivateKey(forConversationID: conversationID, epoch: oldEpoch)
        }
        logger.info("Deleted private keys before epoch \(epoch) for conversation: \(conversationID)")
    }
    
    // MARK: - Signature Key Management
    
    /// Store signature private key for a conversation
    public func storeSignatureKey(_ key: Data, forConversationID conversationID: String) throws {
        let keychainKey = KeychainKey.signatureKey(conversationID: conversationID)
        try store(key, forKey: keychainKey.key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        logger.info("Stored signature key for conversation: \(conversationID)")
    }
    
    /// Retrieve signature private key for a conversation
    public func retrieveSignatureKey(forConversationID conversationID: String) throws -> Data? {
        let key = KeychainKey.signatureKey(conversationID: conversationID)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete signature key for a conversation
    public func deleteSignatureKey(forConversationID conversationID: String) throws {
        let key = KeychainKey.signatureKey(conversationID: conversationID)
        try delete(forKey: key.key)
        logger.info("Deleted signature key for conversation: \(conversationID)")
    }
    
    // MARK: - Encryption Key Management
    
    /// Store encryption key for a conversation
    public func storeEncryptionKey(_ key: Data, forConversationID conversationID: String) throws {
        let keychainKey = KeychainKey.encryptionKey(conversationID: conversationID)
        try store(key, forKey: keychainKey.key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        logger.info("Stored encryption key for conversation: \(conversationID)")
    }
    
    /// Retrieve encryption key for a conversation
    public func retrieveEncryptionKey(forConversationID conversationID: String) throws -> Data? {
        let key = KeychainKey.encryptionKey(conversationID: conversationID)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete encryption key for a conversation
    public func deleteEncryptionKey(forConversationID conversationID: String) throws {
        let key = KeychainKey.encryptionKey(conversationID: conversationID)
        try delete(forKey: key.key)
        logger.info("Deleted encryption key for conversation: \(conversationID)")
    }
    
    // MARK: - Epoch Secrets Management
    
    /// Store epoch secrets (application secrets, exporter secrets, etc.)
    public func storeEpochSecrets(
        _ secrets: Data,
        forConversationID conversationID: String,
        epoch: Int64
    ) throws {
        let key = KeychainKey.epochSecrets(conversationID: conversationID, epoch: epoch)
        try store(secrets, forKey: key.key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        logger.info("Stored epoch secrets for conversation: \(conversationID), epoch: \(epoch)")
    }
    
    /// Retrieve epoch secrets
    public func retrieveEpochSecrets(
        forConversationID conversationID: String,
        epoch: Int64
    ) throws -> Data? {
        let key = KeychainKey.epochSecrets(conversationID: conversationID, epoch: epoch)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete epoch secrets
    public func deleteEpochSecrets(
        forConversationID conversationID: String,
        epoch: Int64
    ) throws {
        let key = KeychainKey.epochSecrets(conversationID: conversationID, epoch: epoch)
        try delete(forKey: key.key)
        logger.debug("Deleted epoch secrets for conversation: \(conversationID), epoch: \(epoch)")
    }
    
    // MARK: - HPKE Key Management
    
    /// Store HPKE private key for a key package
    public func storeHPKEPrivateKey(_ key: Data, forKeyPackageID keyPackageID: String) throws {
        let keychainKey = KeychainKey.hpkePrivateKey(keyPackageID: keyPackageID)
        try store(key, forKey: keychainKey.key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        logger.info("Stored HPKE private key for key package: \(keyPackageID)")
    }
    
    /// Retrieve HPKE private key for a key package
    public func retrieveHPKEPrivateKey(forKeyPackageID keyPackageID: String) throws -> Data? {
        let key = KeychainKey.hpkePrivateKey(keyPackageID: keyPackageID)
        return try retrieve(forKey: key.key)
    }
    
    /// Delete HPKE private key for a key package
    public func deleteHPKEPrivateKey(forKeyPackageID keyPackageID: String) throws {
        let key = KeychainKey.hpkePrivateKey(keyPackageID: keyPackageID)
        try delete(forKey: key.key)
        logger.info("Deleted HPKE private key for key package: \(keyPackageID)")
    }
    
    // MARK: - Batch Operations
    
    /// Delete all keys associated with a conversation
    public func deleteAllKeys(forConversationID conversationID: String) throws {
        try deleteGroupState(forConversationID: conversationID)
        try deleteSignatureKey(forConversationID: conversationID)
        try deleteEncryptionKey(forConversationID: conversationID)
        try deleteCurrentEpoch(forConversationID: conversationID)
        
        // Delete epoch-specific keys (attempt for reasonable range)
        for epoch in 0...1000 {
            try? deletePrivateKey(forConversationID: conversationID, epoch: Int64(epoch))
            try? deleteEpochSecrets(forConversationID: conversationID, epoch: Int64(epoch))
        }
        
        logger.info("Deleted all keys for conversation: \(conversationID)")
    }
    
    // MARK: - Core Keychain Operations
    
    private func store(
        _ data: Data,
        forKey key: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) throws {
        // Delete existing item first
        try? delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.catbird.mls",
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: false
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("Failed to store keychain item: \(key), status: \(status)")
            throw KeychainError.storeFailed(status)
        }
    }
    
    private func retrieve(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.catbird.mls",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            logger.error("Failed to retrieve keychain item: \(key), status: \(status)")
            throw KeychainError.retrieveFailed(status)
        }
        
        return result as? Data
    }
    
    private func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.catbird.mls"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete keychain item: \(key), status: \(status)")
            throw KeychainError.deleteFailed(status)
        }
    }
    
    // MARK: - Key Rotation Support
    
    /// Store archived key for recovery purposes
    public func archiveKey(
        _ key: Data,
        type: String,
        conversationID: String,
        epoch: Int64
    ) throws {
        let archiveKey = "mls.archive.\(type).\(conversationID).epoch.\(epoch)"
        try store(key, forKey: archiveKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
        logger.info("Archived \(type) key for conversation: \(conversationID), epoch: \(epoch)")
    }
    
    /// Retrieve archived key
    public func retrieveArchivedKey(
        type: String,
        conversationID: String,
        epoch: Int64
    ) throws -> Data? {
        let archiveKey = "mls.archive.\(type).\(conversationID).epoch.\(epoch)"
        return try retrieve(forKey: archiveKey)
    }
    
    // MARK: - Security Utilities
    
    /// Generate a secure random key
    public func generateSecureRandomKey(length: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        
        guard status == errSecSuccess else {
            throw KeychainError.randomGenerationFailed(status)
        }
        
        return Data(bytes)
    }
    
    /// Verify keychain accessibility
    public func verifyKeychainAccess() throws {
        let testKey = "mls.test.access"
        let testData = Data("test".utf8)
        
        try store(testData, forKey: testKey)
        
        guard let retrieved = try retrieve(forKey: testKey),
              retrieved == testData else {
            throw KeychainError.accessVerificationFailed
        }
        
        try delete(forKey: testKey)
        logger.info("Keychain access verified successfully")
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case randomGenerationFailed(OSStatus)
    case accessVerificationFailed
    
    public var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Failed to store item in keychain: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve item from keychain: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete item from keychain: \(status)"
        case .randomGenerationFailed(let status):
            return "Failed to generate random data: \(status)"
        case .accessVerificationFailed:
            return "Keychain access verification failed"
        }
    }
}
