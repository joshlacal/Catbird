//
//  MLSKeychain.swift
//  Catbird
//
//  Secure storage for MLS cryptographic keys using iOS Keychain.
//  Implements hardware-backed security with optional Secure Enclave support.
//

import Foundation
import Security
import OSLog

/// Errors that can occur during Keychain operations
enum MLSKeychainError: Error {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData
    case secureEnclaveUnavailable
    
    var localizedDescription: String {
        switch self {
        case .storeFailed(let status):
            return "Failed to store key in Keychain (status: \(status))"
        case .retrieveFailed(let status):
            return "Failed to retrieve key from Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete key from Keychain (status: \(status))"
        case .invalidData:
            return "Invalid key data"
        case .secureEnclaveUnavailable:
            return "Secure Enclave not available on this device"
        }
    }
}

/// Secure storage manager for MLS signature keys
class MLSKeychain {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "blue.catbird", category: "MLSKeychain")
    
    // MARK: - Keychain Storage
    
    /// Store a signature key in the Keychain
    /// - Parameters:
    ///   - key: The key data to store
    ///   - identity: The identity (DID) associated with this key
    ///   - useSecureEnclave: Attempt to use Secure Enclave (if available)
    /// - Throws: MLSKeychainError if storage fails
    static func storeSignatureKey(
        _ key: Data,
        forIdentity identity: String,
        useSecureEnclave: Bool = false
    ) throws {
        guard !key.isEmpty else {
            throw MLSKeychainError.invalidData
        }
        
        let tag = "blue.catbird.mls.sig.\(identity)"
        
        // Delete existing key first
        try? deleteSignatureKey(forIdentity: identity)
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        
        // Attempt Secure Enclave storage if requested and available
        if useSecureEnclave {
            if isSecureEnclaveAvailable() {
                query[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
                query[kSecAttrIsPermanent as String] = true
            } else {
                // Fallback to regular Keychain
                logger.warning("Secure Enclave not available; using regular Keychain")
            }
        }
        
        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Existing item is blocking add; attempt update, then delete+add as fallback
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag
            ]

            let updateAttributes: [String: Any] = [
                kSecValueData as String: key,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            if updateStatus == errSecSuccess {
                logger.info("Updated existing MLS signature key after duplicate detection")
                return
            }

            logger.warning("Failed to update duplicate MLS signature key (status: \(updateStatus)); retrying delete+add")
            SecItemDelete(updateQuery as CFDictionary)
            let retryStatus = SecItemAdd(query as CFDictionary, nil)

            guard retryStatus == errSecSuccess else {
                throw MLSKeychainError.storeFailed(retryStatus)
            }

            logger.info("Rewrote MLS signature key after clearing duplicate")
            return
        }

        if status != errSecSuccess {
            throw MLSKeychainError.storeFailed(status)
        }
        
        logger.info("Stored MLS signature key for identity: \(identity, privacy: .private)")
    }
    
    /// Retrieve a signature key from the Keychain
    /// - Parameter identity: The identity (DID) associated with the key
    /// - Returns: The key data
    /// - Throws: MLSKeychainError if retrieval fails
    static func retrieveSignatureKey(forIdentity identity: String) throws -> Data {
        let tag = "blue.catbird.mls.sig.\(identity)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let keyData = result as? Data else {
            throw MLSKeychainError.retrieveFailed(status)
        }
        
        return keyData
    }
    
    /// Delete a signature key from the Keychain
    /// - Parameter identity: The identity (DID) associated with the key
    /// - Throws: MLSKeychainError if deletion fails
    static func deleteSignatureKey(forIdentity identity: String) throws {
        let tag = "blue.catbird.mls.sig.\(identity)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        // errSecItemNotFound is acceptable (key didn't exist)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSKeychainError.deleteFailed(status)
        }
    }
    
    /// Delete all MLS keys from the Keychain (e.g., on logout)
    static func deleteAllKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "blue.catbird.mls.sig."
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSKeychainError.deleteFailed(status)
        }
        
        logger.info("Deleted all MLS keys from Keychain")
    }
    
    // MARK: - Secure Enclave Detection
    
    /// Check if Secure Enclave is available on this device
    /// - Returns: true if Secure Enclave is available
    static func isSecureEnclaveAvailable() -> Bool {
        // Secure Enclave is available on iPhone 5s and later, iPad Air and later
        // Check by attempting to create a key with Secure Enclave flag
        
        let attributes: [String: Any] = [
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let _ = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            return false
        }
        
        return true
    }
    
    // MARK: - Group Key Storage
    
    /// Store a group's encryption key (for backup/restore scenarios)
    /// Note: In production MLS, group keys are derived and not directly stored.
    /// This is for future backup/restore functionality only.
    static func storeGroupKey(_ key: Data, forGroupId groupId: Data) throws {
        guard !key.isEmpty else {
            throw MLSKeychainError.invalidData
        }
        
        let groupIdHex = groupId.map { String(format: "%02x", $0) }.joined()
        let tag = "blue.catbird.mls.group.\(groupIdHex)"
        
        try? deleteGroupKey(forGroupId: groupId)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw MLSKeychainError.storeFailed(status)
        }
    }
    
    /// Retrieve a group's encryption key
    static func retrieveGroupKey(forGroupId groupId: Data) throws -> Data {
        let groupIdHex = groupId.map { String(format: "%02x", $0) }.joined()
        let tag = "blue.catbird.mls.group.\(groupIdHex)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let keyData = result as? Data else {
            throw MLSKeychainError.retrieveFailed(status)
        }
        
        return keyData
    }
    
    /// Delete a group's encryption key
    static func deleteGroupKey(forGroupId groupId: Data) throws {
        let groupIdHex = groupId.map { String(format: "%02x", $0) }.joined()
        let tag = "blue.catbird.mls.group.\(groupIdHex)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSKeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Testing Support

#if DEBUG
extension MLSKeychain {
    /// Test Keychain operations (development only)
    static func runTests() {
        logger.info("Testing MLSKeychain...")
        
        let testIdentity = "did:plc:test123"
        let testKey = Data(repeating: 0xAB, count: 32)
        
        do {
            // Test store
            try storeSignatureKey(testKey, forIdentity: testIdentity)
            logger.info("Store test passed")
            
            // Test retrieve
            let retrieved = try retrieveSignatureKey(forIdentity: testIdentity)
            assert(retrieved == testKey, "Retrieved key doesn't match")
            logger.info("Retrieve test passed")
            
            // Test delete
            try deleteSignatureKey(forIdentity: testIdentity)
            logger.info("Delete test passed")
            
            // Verify deletion
            do {
                _ = try retrieveSignatureKey(forIdentity: testIdentity)
                logger.error("Delete verification failed; key still exists")
            } catch {
                logger.info("Delete verification passed")
            }
            
            // Test Secure Enclave availability
            if isSecureEnclaveAvailable() {
                logger.info("Secure Enclave available")
            } else {
                logger.warning("Secure Enclave not available")
            }
            
            logger.info("All MLSKeychain tests passed")
            
        } catch {
            logger.error("Test failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
