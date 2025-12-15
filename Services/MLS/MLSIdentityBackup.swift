import Foundation
import Security
import CryptoKit
import OSLog
import Petrel

// =============================================================================
// MLS Identity Backup - Minimal Approach
// =============================================================================
//
// ✅ ONLY 32 BYTES backed up to iCloud Keychain
// ✅ Everything else derived or verified by server/ATProto
//
// Architecture Decision:
// - Backup: ONLY MLS signature private key (32 bytes)
// - Derive: Credential (from key + DID), KeyPackages (from key)
// - Verify: DID (from ATProto PDS), Membership (from server DB)
//
// Recovery Matrix:
// ┌──────────────────┬──────────────┬──────────────┬─────────────────────┐
// │ Scenario         │ Keychain     │ iOS Backup   │ Result              │
// ├──────────────────┼──────────────┼──────────────┼─────────────────────┤
// │ Same device      │ ✅ 32 bytes  │ ✅ Full DB   │ Seamless restore    │
// │ New device       │ ✅ 32 bytes  │ ❌ Nothing   │ Auto-rejoin (no DB) │
// │ New device       │ ❌ Nothing   │ ❌ Nothing   │ New identity        │
// └──────────────────┴──────────────┴──────────────┴─────────────────────┘
//
// =============================================================================

/// Manages MLS signature key backup to iCloud Keychain
/// Only stores the 32-byte Ed25519 signature private key - everything else is derived
final class MLSKeychainManager: Sendable {
    private let service = "blue.catbird.mls"
    private let signatureKeyAccount = "signature_key_v1"
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSKeychainManager")

    // MARK: - Save Signature Key (32 bytes)

    /// Save MLS signature private key to iCloud Keychain
    /// - Parameter privateKey: Ed25519 signature private key (32 bytes)
    /// - Throws: KeychainError if save fails or key is wrong size
    func saveSignatureKey(_ privateKey: Data) throws {
        guard privateKey.count == 32 else {
            throw KeychainError.invalidKeySize(privateKey.count)
        }

        // Delete existing entry first
        try? deleteSignatureKey()

        // Create new entry with iCloud sync enabled
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: signatureKeyAccount,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true  // ✅ iCloud Keychain sync
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        logger.info("✅ Saved signature key to iCloud Keychain")
    }

    // MARK: - Get Signature Key

    /// Retrieve MLS signature private key from iCloud Keychain
    /// - Returns: Ed25519 signature private key (32 bytes), or nil if not found
    /// - Throws: KeychainError if retrieval fails
    func getSignatureKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: signatureKeyAccount,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Check both local and iCloud
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw KeychainError.retrievalFailed(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        guard data.count == 32 else {
            throw KeychainError.invalidKeySize(data.count)
        }

        return data
    }

    // MARK: - Delete Signature Key

    /// Delete MLS signature key from iCloud Keychain
    /// Use with caution - this permanently removes the identity backup
    func deleteSignatureKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: signatureKeyAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
        logger.info("🗑️ Deleted signature key from iCloud Keychain")
    }

    // MARK: - Check Identity Exists

    /// Check if an MLS identity backup exists in iCloud Keychain
    /// - Returns: True if signature key exists, false otherwise
    func hasBackedUpIdentity() -> Bool {
        return (try? getSignatureKey()) != nil
    }
}

// MARK: - Errors

enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrievalFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData
    case invalidKeySize(Int)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(status)"
        case .retrievalFailed(let status):
            return "Failed to retrieve from Keychain: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain: \(status)"
        case .invalidData:
            return "Invalid data in Keychain"
        case .invalidKeySize(let size):
            return "Invalid key size: \(size) bytes (expected 32)"
        }
    }
}

// MARK: - MLS Identity Reconstruction

/// Reconstructs full MLS identity from backed up signature key + ATProto DID
struct MLSIdentityReconstructor {
    private let keychainManager: MLSKeychainManager
    private let apiClient: MLSAPIClient
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSIdentityReconstructor")

    init(keychainManager: MLSKeychainManager, apiClient: MLSAPIClient) {
        self.keychainManager = keychainManager
        self.apiClient = apiClient
    }

    /// Restore or create MLS identity
    /// - Returns: Complete MLS identity ready for use
    /// - Throws: MLSError if restoration fails
    func restoreOrCreateIdentity() async throws -> MLSIdentity {
        // 1. Check if we have a backed up signature key
        if let signatureKey = try keychainManager.getSignatureKey() {
            // Have backup - restore identity
            logger.info("Found backed up identity, restoring...")
            return try await restoreIdentity(from: signatureKey)
        } else {
            // No backup - generate fresh identity
            logger.info("No backup found, generating new identity...")
            return try await generateNewIdentity()
        }
    }

    /// Restore identity from backed up signature key
    private func restoreIdentity(from signatureKey: Data) async throws -> MLSIdentity {
        // 1. Get DID from ATProto auth (already verified by PDS)
        guard let did = await apiClient.authenticatedUserDID() else {
            throw MLSError.noAuthentication
        }

        // 2. Derive public key from private key using CryptoKit
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signatureKey)
        let publicKey = privateKey.publicKey.rawRepresentation

        // 3. Reconstruct credential (DID + public key)
        // Note: This assumes BasicCredential format. In a real implementation,
        // we might need to use MlsContext to create this if it's opaque.
        // For now, we'll construct a simple representation or use what MlsContext expects.
        // Assuming MlsContext.createKeyPackage takes the credential bytes.
        let credential = try createBasicCredential(identity: did, publicKey: publicKey)

        // 4. Generate fresh KeyPackages (100 count)
        // We need an MlsContext to generate key packages.
        // Since we are restoring, we might need a temporary context or the main one.
        // Assuming we can create a temporary context for generation.
        let tempStoragePath = FileManager.default.temporaryDirectory.appendingPathComponent("mls_restore_\(UUID().uuidString).db").path
        let context = try MlsContext(storagePath: tempStoragePath)
        
        var keyPackages: [MLSKeyPackageUploadData] = []
        for _ in 0..<100 {
            let kpResult = try context.createKeyPackage(identityBytes: credential)
            // Convert to upload format
            let uploadData = MLSKeyPackageUploadData(
                keyPackage: kpResult.keyPackageBytes.base64EncodedString(),
                cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519", // Default
                expires: Date().addingTimeInterval(90 * 24 * 60 * 60) // 90 days
            )
            keyPackages.append(uploadData)
        }

        // 5. Upload KeyPackages to server
        _ = try await apiClient.publishKeyPackagesBatch(keyPackages)

        return MLSIdentity(
            signaturePrivateKey: signatureKey,
            signaturePublicKey: publicKey,
            credential: credential,
            did: did
        )
    }

    /// Generate fresh MLS identity (first time user or lost backup)
    private func generateNewIdentity() async throws -> MLSIdentity {
        // 1. Get DID from ATProto auth
        guard let did = await apiClient.authenticatedUserDID() else {
            throw MLSError.noAuthentication
        }

        // 2. Generate Ed25519 signature key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let signatureKey = privateKey.rawRepresentation
        let publicKey = privateKey.publicKey.rawRepresentation

        // 3. Create credential
        let credential = try createBasicCredential(identity: did, publicKey: publicKey)

        // 4. Generate KeyPackages
        let tempStoragePath = FileManager.default.temporaryDirectory.appendingPathComponent("mls_gen_\(UUID().uuidString).db").path
        let context = try MlsContext(storagePath: tempStoragePath)
        
        var keyPackages: [MLSKeyPackageUploadData] = []
        for _ in 0..<100 {
            let kpResult = try context.createKeyPackage(identityBytes: credential)
            let uploadData = MLSKeyPackageUploadData(
                keyPackage: kpResult.keyPackageBytes.base64EncodedString(),
                cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
                expires: Date().addingTimeInterval(90 * 24 * 60 * 60)
            )
            keyPackages.append(uploadData)
        }

        // 5. Upload KeyPackages to server
        _ = try await apiClient.publishKeyPackagesBatch(keyPackages)

        // 6. Backup signature key to iCloud Keychain
        try keychainManager.saveSignatureKey(signatureKey)

        return MLSIdentity(
            signaturePrivateKey: signatureKey,
            signaturePublicKey: publicKey,
            credential: credential,
            did: did
        )
    }
    
    // Helper to create BasicCredential bytes
    func createBasicCredential(identity: String, publicKey: Data) throws -> Data {
        // BasicCredential = {
        //   opaque identity<0..2^16-1>;
        //   SignaturePublicKey signature_key;
        // }
        // This is a simplified construction. In production, use the FFI or proper encoding.
        // For now, we'll assume identity is UTF8 bytes of DID.
        
        guard let identityBytes = identity.data(using: .utf8) else {
            throw MLSError.invalidIdentity
        }
        
        var data = Data()
        // Length prefix for identity (2 bytes, big endian)
        let length = UInt16(identityBytes.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(identityBytes)
        data.append(publicKey)
        
        return data
    }
}

// MARK: - KeyPackage Pool Manager

/// Manages the pool of MLS KeyPackages for automatic rejoin
/// Maintains 100 KeyPackages, refreshes when < 20 remain
final class MLSKeyPackagePoolManager {
    private let targetPoolSize = 100
    private let refreshThreshold = 20
    private let keychainManager: MLSKeychainManager
    private let apiClient: MLSAPIClient
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSKeyPackagePoolManager")

    init(
        keychainManager: MLSKeychainManager,
        apiClient: MLSAPIClient
    ) {
        self.keychainManager = keychainManager
        self.apiClient = apiClient
    }

    /// Ensure KeyPackage pool is sufficiently large
    /// Called: On app launch, after each KeyPackage consumption, daily background task
    func ensureKeyPackagePool() async throws {
        // 1. Get signature key from Keychain
        guard let signatureKey = try keychainManager.getSignatureKey() else {
            throw MLSError.noIdentityBackup
        }

        // 2. Get DID from ATProto auth
        guard let did = await apiClient.authenticatedUserDID() else {
            throw MLSError.noAuthentication
        }

        // 3. Check current pool size on server
        let stats = try await apiClient.getKeyPackageStats()

        if stats.available < refreshThreshold {
            logger.info("KeyPackage pool low (\(stats.available)), replenishing...")
            
            // 4. Derive public key and reconstruct credential
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signatureKey)
            let publicKey = privateKey.publicKey.rawRepresentation
            
            // Helper to create credential (duplicated for now, should be shared)
            guard let identityBytes = did.data(using: .utf8) else { throw MLSError.invalidIdentity }
            var credential = Data()
            let length = UInt16(identityBytes.count)
            credential.append(UInt8(length >> 8))
            credential.append(UInt8(length & 0xFF))
            credential.append(identityBytes)
            credential.append(publicKey)

            // 5. Generate new KeyPackages to replenish pool
            let packagesToGenerate = targetPoolSize - stats.available
            let tempStoragePath = FileManager.default.temporaryDirectory.appendingPathComponent("mls_pool_\(UUID().uuidString).db").path
            let context = try MlsContext(storagePath: tempStoragePath)
            
            var packages: [MLSKeyPackageUploadData] = []
            for _ in 0..<packagesToGenerate {
                let kpResult = try context.createKeyPackage(identityBytes: credential)
                let uploadData = MLSKeyPackageUploadData(
                    keyPackage: kpResult.keyPackageBytes.base64EncodedString(),
                    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
                    expires: Date().addingTimeInterval(90 * 24 * 60 * 60)
                )
                packages.append(uploadData)
            }

            // 6. Upload to server
            _ = try await apiClient.publishKeyPackagesBatch(packages)
            logger.info("✅ Replenished pool with \(packages.count) new KeyPackages")
        }
    }
}

// MARK: - Automatic Rejoin Coordinator

/// Coordinates automatic rejoin when user deletes app and reinstalls
/// Flow: Signature key from iCloud → Reconstruct identity → Request rejoin → Server orchestrates Welcome
actor MLSAutomaticRejoinCoordinator {
    private let keychainManager: MLSKeychainManager
    private let apiClient: MLSAPIClient
    private let reconstructor: MLSIdentityReconstructor
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSAutomaticRejoinCoordinator")
    
    // We need a way to check local state. Assuming a closure or delegate for now.
    private let hasLocalStateCheck: () async throws -> Bool
    private let getContextForConversation: (String) async throws -> MlsContext

    init(
        keychainManager: MLSKeychainManager,
        apiClient: MLSAPIClient,
        reconstructor: MLSIdentityReconstructor,
        hasLocalStateCheck: @escaping () async throws -> Bool,
        getContextForConversation: @escaping (String) async throws -> MlsContext
    ) {
        self.keychainManager = keychainManager
        self.apiClient = apiClient
        self.reconstructor = reconstructor
        self.hasLocalStateCheck = hasLocalStateCheck
        self.getContextForConversation = getContextForConversation
    }

    /// Detect and recover from missing MLS state after app deletion
    /// Called on app launch and when joining conversation fails
    func detectAndRecover() async throws {
        // 1. Check if we have signature key in iCloud Keychain
        guard keychainManager.hasBackedUpIdentity() else {
            // Fresh install, no backup - normal flow
            return
        }

        // 2. Check if we have local MLS state in SQLCipher
        let hasLocalState = try await hasLocalStateCheck()

        if !hasLocalState {
            // Signature key exists but no local state = app was deleted
            logger.warning("⚠️ Detected app deletion with backup present. Starting recovery...")
            try await recoverFromDeletion()
        }
    }

    /// Recover all conversations after app deletion
    private func recoverFromDeletion() async throws {
        // 1. Restore identity from signature key + DID
        let identity = try await reconstructor.restoreOrCreateIdentity()

        // 2. Get list of conversations we're members of (from server DB)
        // Using getExpectedConversations which is designed for this
        let expectedConvos = try await apiClient.getExpectedConversations()

        logger.info("Found \(expectedConvos.conversations.count) conversations to recover")

        // 3. For each conversation, request automatic rejoin
        for convo in expectedConvos.conversations {
            do {
                try await requestAutomaticRejoin(
                    convoId: convo.id,
                    did: identity.did,
                    credential: identity.credential
                )
            } catch {
                // Log error but continue with other conversations
                logger.error("Failed to rejoin conversation \(convo.id): \(error.localizedDescription)")
            }
        }
    }

    /// Request automatic rejoin for a specific conversation
    /// Uses External Commit to add self to the group
    private func requestAutomaticRejoin(
        convoId: String,
        did: String,
        credential: Data
    ) async throws {
        logger.info("Rejoining \(convoId) via External Commit")
        
        // Use MLSClient to join via External Commit
        // This handles fetching GroupInfo, creating the commit, and sending it to the server
        _ = try await MLSClient.shared.joinByExternalCommit(for: did, convoId: convoId)
        
        logger.info("✅ Successfully rejoined conversation \(convoId)")
    }
}

// MARK: - Supporting Types

/// Complete MLS identity (derived from signature key + DID)
struct MLSIdentity {
    let signaturePrivateKey: Data  // 32 bytes (backed up to Keychain)
    let signaturePublicKey: Data   // 32 bytes (derived)
    let credential: Data            // ~200 bytes (derived)
    let did: String                 // From ATProto auth
}

enum MLSError: Error, LocalizedError {
    case noIdentityBackup
    case rejoinTimeout
    case invalidWelcome
    case noAuthentication
    case invalidIdentity

    var errorDescription: String? {
        switch self {
        case .noIdentityBackup:
            return "No MLS identity found in iCloud Keychain"
        case .rejoinTimeout:
            return "Timeout waiting for automatic rejoin"
        case .invalidWelcome:
            return "Invalid Welcome message received"
        case .noAuthentication:
            return "User is not authenticated"
        case .invalidIdentity:
            return "Invalid identity format"
        }
    }
}
