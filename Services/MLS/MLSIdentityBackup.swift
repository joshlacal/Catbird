import Foundation
import Security

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
    private let authManager: AuthManager
    private let mlsFFI: MLSFFI

    /// Restore or create MLS identity
    /// - Returns: Complete MLS identity ready for use
    /// - Throws: MLSError if restoration fails
    func restoreOrCreateIdentity() async throws -> MLSIdentity {
        // 1. Check if we have a backed up signature key
        if let signatureKey = try keychainManager.getSignatureKey() {
            // Have backup - restore identity
            return try await restoreIdentity(from: signatureKey)
        } else {
            // No backup - generate fresh identity
            return try await generateNewIdentity()
        }
    }

    /// Restore identity from backed up signature key
    private func restoreIdentity(from signatureKey: Data) async throws -> MLSIdentity {
        // 1. Get DID from ATProto auth (already verified by PDS)
        let did = try await authManager.getCurrentDID()

        // 2. Derive public key from private key
        let publicKey = try mlsFFI.derivePublicKey(from: signatureKey)

        // 3. Reconstruct credential (DID + public key)
        let credential = try mlsFFI.createBasicCredential(
            identity: did,
            signaturePublicKey: publicKey
        )

        // 4. Generate fresh KeyPackages (100 count)
        let keyPackages = try mlsFFI.generateKeyPackages(
            signatureKey: signatureKey,
            credential: credential,
            count: 100
        )

        // 5. Upload KeyPackages to server
        try await uploadKeyPackages(keyPackages, did: did)

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
        let did = try await authManager.getCurrentDID()

        // 2. Generate Ed25519 signature key pair
        let (privateKey, publicKey) = try mlsFFI.generateSignatureKeyPair()

        // 3. Create credential
        let credential = try mlsFFI.createBasicCredential(
            identity: did,
            signaturePublicKey: publicKey
        )

        // 4. Generate KeyPackages
        let keyPackages = try mlsFFI.generateKeyPackages(
            signatureKey: privateKey,
            credential: credential,
            count: 100
        )

        // 5. Upload KeyPackages to server
        try await uploadKeyPackages(keyPackages, did: did)

        // 6. Backup signature key to iCloud Keychain
        try keychainManager.saveSignatureKey(privateKey)

        return MLSIdentity(
            signaturePrivateKey: privateKey,
            signaturePublicKey: publicKey,
            credential: credential,
            did: did
        )
    }

    /// Upload KeyPackages to server
    private func uploadKeyPackages(_ packages: [KeyPackage], did: String) async throws {
        // TODO: Implement API call
        // POST /xrpc/blue.catbird.mls.publishKeyPackage
        fatalError("Not implemented - requires API client")
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
    private let mlsFFI: MLSFFI
    private let authManager: AuthManager

    init(
        keychainManager: MLSKeychainManager,
        apiClient: MLSAPIClient,
        mlsFFI: MLSFFI,
        authManager: AuthManager
    ) {
        self.keychainManager = keychainManager
        self.apiClient = apiClient
        self.mlsFFI = mlsFFI
        self.authManager = authManager
    }

    /// Ensure KeyPackage pool is sufficiently large
    /// Called: On app launch, after each KeyPackage consumption, daily background task
    func ensureKeyPackagePool() async throws {
        // 1. Get signature key from Keychain
        guard let signatureKey = try keychainManager.getSignatureKey() else {
            throw MLSError.noIdentityBackup
        }

        // 2. Get DID from ATProto auth
        let did = try await authManager.getCurrentDID()

        // 3. Check current pool size on server
        let stats = try await apiClient.getKeyPackageStats(did: did)

        if stats.availableCount < refreshThreshold {
            // 4. Derive public key and reconstruct credential
            let publicKey = try mlsFFI.derivePublicKey(from: signatureKey)
            let credential = try mlsFFI.createBasicCredential(
                identity: did,
                signaturePublicKey: publicKey
            )

            // 5. Generate new KeyPackages to replenish pool
            let packagesToGenerate = targetPoolSize - stats.availableCount
            let packages = try mlsFFI.generateKeyPackages(
                signatureKey: signatureKey,
                credential: credential,
                count: packagesToGenerate
            )

            // 6. Upload to server
            try await apiClient.uploadKeyPackages(packages)
        }
    }
}

// MARK: - Automatic Rejoin Coordinator

/// Coordinates automatic rejoin when user deletes app and reinstalls
/// Flow: Signature key from iCloud → Reconstruct identity → Request rejoin → Server orchestrates Welcome
actor MLSAutomaticRejoinCoordinator {
    private let keychainManager: MLSKeychainManager
    private let apiClient: MLSAPIClient
    private let storage: MLSStorage
    private let reconstructor: MLSIdentityReconstructor

    init(
        keychainManager: MLSKeychainManager,
        apiClient: MLSAPIClient,
        storage: MLSStorage,
        reconstructor: MLSIdentityReconstructor
    ) {
        self.keychainManager = keychainManager
        self.apiClient = apiClient
        self.storage = storage
        self.reconstructor = reconstructor
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
        let hasLocalState = try await storage.hasMLSState()

        if !hasLocalState {
            // Signature key exists but no local state = app was deleted
            try await recoverFromDeletion()
        }
    }

    /// Recover all conversations after app deletion
    private func recoverFromDeletion() async throws {
        // 1. Restore identity from signature key + DID
        let identity = try await reconstructor.restoreOrCreateIdentity()

        // 2. Get list of conversations we're members of (from server DB)
        let conversations = try await apiClient.getMyConversations(did: identity.did)

        // 3. For each conversation, request automatic rejoin
        for convo in conversations {
            do {
                try await requestAutomaticRejoin(
                    convoId: convo.id,
                    did: identity.did
                )
            } catch {
                // Log error but continue with other conversations
                print("Failed to rejoin conversation \(convo.id): \(error)")
            }
        }
    }

    /// Request automatic rejoin for a specific conversation
    /// Server will orchestrate Welcome delivery from any online member
    private func requestAutomaticRejoin(
        convoId: String,
        did: String
    ) async throws {
        // 1. Mark ourselves as needing rejoin in server DB
        try await apiClient.markNeedsRejoin(
            convoId: convoId,
            did: did
        )

        // 2. Poll for Welcome message (server orchestrates delivery)
        try await pollForWelcome(
            convoId: convoId,
            did: did,
            maxAttempts: 10,
            backoffSeconds: 0.5
        )
    }

    /// Poll for Welcome message with exponential backoff
    private func pollForWelcome(
        convoId: String,
        did: String,
        maxAttempts: Int,
        backoffSeconds: TimeInterval
    ) async throws {
        var attempt = 0
        var delay = backoffSeconds

        while attempt < maxAttempts {
            // Check for Welcome message
            if let welcome = try await apiClient.getWelcome(
                convoId: convoId,
                did: did
            ) {
                // Process Welcome and rejoin group
                try await processWelcome(
                    welcome: welcome,
                    convoId: convoId,
                    did: did
                )
                return
            }

            // Exponential backoff
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay *= 2
            attempt += 1
        }

        throw MLSError.rejoinTimeout
    }

    /// Process Welcome message and rejoin group
    private func processWelcome(
        welcome: WelcomeMessage,
        convoId: String,
        did: String
    ) async throws {
        // TODO: Implement using OpenMLS FFI
        // 1. Process Welcome to create new MLS group state
        // 2. Save group state to SQLCipher database
        // 3. Mark Welcome as consumed on server
        // 4. Start normal message flow
        fatalError("Not implemented - requires OpenMLS FFI integration")
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

    var errorDescription: String? {
        switch self {
        case .noIdentityBackup:
            return "No MLS identity found in iCloud Keychain"
        case .rejoinTimeout:
            return "Timeout waiting for automatic rejoin"
        case .invalidWelcome:
            return "Invalid Welcome message received"
        }
    }
}

// MARK: - Placeholder Types (to be implemented)

struct KeyPackage { }
struct WelcomeMessage { }
struct KeyPackageStats {
    let availableCount: Int
}
struct ConversationInfo {
    let id: String
}

// Placeholder protocol types
protocol MLSFFI {
    func derivePublicKey(from privateKey: Data) throws -> Data
    func createBasicCredential(identity: String, signaturePublicKey: Data) throws -> Data
    func generateKeyPackages(signatureKey: Data, credential: Data, count: Int) throws -> [KeyPackage]
    func generateSignatureKeyPair() throws -> (privateKey: Data, publicKey: Data)
}

protocol AuthManager {
    func getCurrentDID() async throws -> String
}

protocol MLSStorage {
    func hasMLSState() async throws -> Bool
}

// Placeholder API client (to be implemented)
final class MLSAPIClient {
    func getKeyPackageStats(did: String) async throws -> KeyPackageStats {
        fatalError("Not implemented")
    }

    func uploadKeyPackages(_ packages: [KeyPackage]) async throws {
        fatalError("Not implemented")
    }

    func getMyConversations(did: String) async throws -> [ConversationInfo] {
        fatalError("Not implemented")
    }

    func markNeedsRejoin(convoId: String, did: String) async throws {
        fatalError("Not implemented")
    }

    func getWelcome(convoId: String, did: String) async throws -> WelcomeMessage? {
        fatalError("Not implemented")
    }
}
