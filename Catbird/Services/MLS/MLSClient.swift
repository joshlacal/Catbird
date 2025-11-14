import Combine
import Foundation
import GRDB
import OSLog
import Petrel

#if os(iOS)
import UIKit
#endif

/// Configuration for MLS group forward secrecy and security settings
public struct MLSGroupConfiguration {
    /// Maximum number of past epochs to retain keys for.
    /// Set to 0 for best forward secrecy (no old epoch keys retained).
    /// Trade-off: Higher values allow decryption of older messages but reduce forward secrecy.
    public let maxPastEpochs: UInt32

    /// Number of out-of-order messages tolerated in sender ratchet.
    /// Higher values allow more message reordering but increase vulnerability window.
    public let outOfOrderTolerance: UInt32

    /// Maximum forward distance in sender ratchet generations.
    /// Limits how far ahead a sender can ratchet before synchronization required.
    public let maximumForwardDistance: UInt32

    /// Whether to use ciphertext wire format (true) or plaintext (false).
    /// Ciphertext provides better privacy by encrypting message metadata.
    /// NOTE: This is deprecated in favor of wireFormat
    public let useCiphertext: Bool

    /// Initialize MLS group configuration
    public init(
        maxPastEpochs: UInt32,
        outOfOrderTolerance: UInt32,
        maximumForwardDistance: UInt32,
        useCiphertext: Bool
    ) {
        self.maxPastEpochs = maxPastEpochs
        self.outOfOrderTolerance = outOfOrderTolerance
        self.maximumForwardDistance = maximumForwardDistance
        self.useCiphertext = useCiphertext
    }

    /// Default configuration with balanced security and reliability
    /// Changed from maxPastEpochs: 0 to 5 to handle network delays and message reordering
    public static let `default` = MLSGroupConfiguration(
        maxPastEpochs: 5, // Retain 5 past epochs to handle network delays
        outOfOrderTolerance: 10, // Reasonable out-of-order tolerance
        maximumForwardDistance: 2000, // Standard forward distance
        useCiphertext: true // Privacy by default (deprecated)
    )

    /// Configuration optimized for reliability over security
    /// Use when message delivery may be unreliable or out-of-order
    public static let reliable = MLSGroupConfiguration(
        maxPastEpochs: 3, // Keep 3 past epochs for late messages
        outOfOrderTolerance: 50, // Higher tolerance for reordering
        maximumForwardDistance: 5000, // Larger forward distance
        useCiphertext: true // Still maintain privacy (deprecated)
    )

    /// Convert to FFI GroupConfig type
    /// Note: useCiphertext and wireFormat are enforced at the Swift layer,
    /// not passed to the Rust FFI (which always uses ciphertext)
    public func toFFI() -> GroupConfig {
        return GroupConfig(
            maxPastEpochs: maxPastEpochs,
            outOfOrderTolerance: outOfOrderTolerance,
            maximumForwardDistance: maximumForwardDistance
        )
    }
}

/// Modern MLS wrapper using UniFFI bindings
/// This replaces the legacy C FFI approach with type-safe Swift APIs
class MLSClient {
    /// Shared singleton instance - MLS context must persist across app lifetime
    /// to maintain group state in memory and keychain persistence
    static let shared = MLSClient()

    /// Per-user MLS contexts to prevent state contamination
    private var contexts: [String: MlsContext] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.catbird", category: "MLSClient")
    private var cancellables = Set<AnyCancellable>()

    /// MLS API client for server operations (Phase 3/4)
    private var apiClient: MLSAPIClient?

    /// Device manager for multi-device support
    private var deviceManager: MLSDeviceManager?

    // MARK: - Initialization

    private init() {
        logger.info("🔐 MLSClient initialized with per-user context isolation")
        // setupLifecycleObservers() // FIXME: Lifecycle observers need to be aware of the current user
        logger.debug("📍 [MLSClient.init] Complete")
    }

    /// Configure the MLS API client (Phase 3/4)
    /// Must be called before using Welcome validation or bundle monitoring
    func configure(apiClient: MLSAPIClient, atProtoClient: ATProtoClient) {
        self.apiClient = apiClient
        self.deviceManager = MLSDeviceManager(apiClient: atProtoClient)
        logger.info("✅ MLSClient configured with API client for Phase 3/4 operations and device manager")
    }

    /// Ensure device is registered and get credential DID
    /// Must be called before creating key packages
    func ensureDeviceRegistered() async throws -> String {
        guard let deviceManager = deviceManager else {
            logger.error("❌ Device manager not configured - call configure() first")
            throw MLSError.configurationError
        }
        return try await deviceManager.ensureDeviceRegistered()
    }

    /// Get device info for key package uploads
    func getDeviceInfo() async -> (deviceId: String, credentialDid: String)? {
        return await deviceManager?.getDeviceInfo()
    }

    /// Get or create a context for a specific user.
    private func getContext(for userDID: String) -> MlsContext {
        if let existingContext = contexts[userDID] {
            logger.debug("♻️ Reusing existing MlsContext for user: \(userDID.prefix(20))...")
            return existingContext
        }

        let newContext = createContext()
        contexts[userDID] = newContext
        logger.info("🆕 Created new MlsContext for user: \(userDID.prefix(20))...")
        return newContext
    }

    /// Create a new MLS context
    private func createContext() -> MlsContext {
        let newContext = MlsContext()

        // Set up logging
        let mlsLogger = MLSLoggerImplementation()
        newContext.setLogger(logger: mlsLogger)

        // Set up epoch secret storage for forward secrecy with message history
        let epochStorage = MLSEpochSecretStorageBridge()
        do {
            try newContext.setEpochSecretStorage(storage: epochStorage)
            logger.info("✅ Configured epoch secret storage for historical message decryption")
        } catch {
            logger.error("❌ Failed to configure epoch secret storage: \(error.localizedDescription)")
        }

        return newContext
    }

    // MARK: - Group Management

    /// Create a new MLS group
    func createGroup(for userDID: String, identity: String, configuration: MLSGroupConfiguration = .default) async throws -> Data {
        logger.info("📍 [MLSClient.createGroup] START - user: \(userDID), identity: \(identity)")
        let context = getContext(for: userDID)
        do {
            let identityBytes = Data(identity.utf8)
            let result = try context.createGroup(identityBytes: identityBytes, config: configuration.toFFI())
            logger.info("✅ [MLSClient.createGroup] Group created - ID: \(result.groupId.hexEncodedString().prefix(16))")
            return result.groupId
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.createGroup] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Join an existing group using a welcome message
    func joinGroup(for userDID: String, welcome: Data, identity: String, configuration: MLSGroupConfiguration = .default) async throws -> Data {
        logger.info("📍 [MLSClient.joinGroup] START - user: \(userDID), identity: \(identity), welcome size: \(welcome.count) bytes")

        // Phase 3 validation now occurs on the sender before the Welcome is uploaded.
        // Recipients proceed directly to processing since the server has already approved the Welcome.
        let context = getContext(for: userDID)
        do {
            let identityBytes = Data(identity.utf8)
            let result = try context.processWelcome(welcomeBytes: welcome, identityBytes: identityBytes, config: configuration.toFFI())
            logger.info("✅ [MLSClient.joinGroup] Joined group - ID: \(result.groupId.hexEncodedString().prefix(16))")
            return result.groupId
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.joinGroup] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    // MARK: - Member Management

    /// Add members to an existing group
    func addMembers(for userDID: String, groupId: Data, keyPackages: [Data]) async throws -> AddMembersResult {
        logger.info("📍 [MLSClient.addMembers] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16)), keyPackages: \(keyPackages.count)")
        let context = getContext(for: userDID)
        guard !keyPackages.isEmpty else {
            logger.error("❌ [MLSClient.addMembers] No key packages provided")
            throw MLSError.operationFailed
        }
        do {
            let keyPackageData = keyPackages.map { KeyPackageData(data: $0) }
            let result = try context.addMembers(groupId: groupId, keyPackages: keyPackageData)
            logger.info("✅ [MLSClient.addMembers] Success - commit: \(result.commitData.count) bytes, welcome: \(result.welcomeData.count) bytes")
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.addMembers] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Remove a member from the group
    func removeMember(for userDID: String, groupId: Data, memberIndex: UInt32) async throws -> Data {
        logger.error("Remove member not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }

    /// Delete a group from MLS storage
    func deleteGroup(for userDID: String, groupId: Data) async throws {
        logger.info("📍 [MLSClient.deleteGroup] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16))")
        let context = getContext(for: userDID)
        do {
            try context.deleteGroup(groupId: groupId)
            logger.info("✅ [MLSClient.deleteGroup] Successfully deleted group")
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.deleteGroup] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    // MARK: - Message Encryption/Decryption

    /// Encrypt a message for the group
    func encryptMessage(for userDID: String, groupId: Data, plaintext: Data) async throws -> EncryptResult {
        logger.info("📍 [MLSClient.encryptMessage] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16)), plaintext: \(plaintext.count) bytes")
        let context = getContext(for: userDID)
        do {
            let result = try context.encryptMessage(groupId: groupId, plaintext: plaintext)
            logger.info("✅ [MLSClient.encryptMessage] Success - ciphertext: \(result.ciphertext.count) bytes")
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.encryptMessage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Decrypt a message from the group
    func decryptMessage(for userDID: String, groupId: Data, ciphertext: Data, conversationID: String, messageID: String) async throws -> DecryptResult {
        logger.info("📍 [MLSClient.decryptMessage] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16)), messageID: \(messageID)")
        let context = getContext(for: userDID)
        do {
            let result = try context.decryptMessage(groupId: groupId, ciphertext: ciphertext)
            logger.info("✅ Decrypted \(result.plaintext.count) bytes")
            do {
                let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: userDID)
                let payload = try? MLSMessagePayload.decodeFromJSON(result.plaintext)
                let plaintextString = payload?.text ?? String(decoding: result.plaintext, as: UTF8.self)
                let embedData = payload?.embed
                let embedDataJSON = embedData.flatMap { try? $0.toJSONData() }
                try await MLSStorageHelpers.savePlaintext(
                    in: database,
                    messageID: messageID,
                    plaintext: plaintextString,
                    embedDataJSON: embedDataJSON,
                    epoch: 0,
                    sequenceNumber: 0
                )
                logger.info("💾 CRITICAL: Plaintext cached for message: \(messageID)")
            } catch {
                logger.error("🚨 CRITICAL: Failed to cache plaintext - message permanently lost! Error: \(error.localizedDescription)")
            }
            return result
        } catch let error as MlsError {
            logger.error("❌ Decryption failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    // MARK: - Key Package Management

    /// Create a key package for this user
    func createKeyPackage(for userDID: String, identity: String) async throws -> Data {
        logger.info("📍 [MLSClient.createKeyPackage] START - user: \(userDID), identity: \(identity)")
        let context = getContext(for: userDID)
        do {
            let identityBytes = Data(identity.utf8)
            let result = try context.createKeyPackage(identityBytes: identityBytes)
            logger.info("✅ [MLSClient.createKeyPackage] Success - \(result.keyPackageData.count) bytes")
            return result.keyPackageData
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.createKeyPackage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Compute the hash reference for a key package
    func computeKeyPackageHash(for userDID: String, keyPackageData: Data) async throws -> Data {
        logger.debug("📍 [MLSClient.computeKeyPackageHash] Computing hash for \(keyPackageData.count) bytes")
        let context = getContext(for: userDID)
        do {
            let hashBytes = try context.computeKeyPackageHash(keyPackageBytes: keyPackageData)
            logger.debug("✅ [MLSClient.computeKeyPackageHash] Hash:  \(hashBytes.hexEncodedString())")
            return hashBytes
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.computeKeyPackageHash] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Update key package for an existing group
    func updateKeyPackage(for userDID: String, groupId: Data) async throws -> Data {
        logger.error("Update key package not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }

    // MARK: - Group State

    /// Get the current epoch for a group
    func getEpoch(for userDID: String, groupId: Data) async throws -> UInt64 {
        let context = getContext(for: userDID)
        do {
            return try context.getEpoch(groupId: groupId)
        } catch let error as MlsError {
            logger.error("Get epoch failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Check if a group exists in local storage
    func groupExists(for userDID: String, groupId: Data) -> Bool {
        let context = getContext(for: userDID)
        return context.groupExists(groupId: groupId)
    }

    /// Get group info for external parties
    func getGroupInfo(for userDID: String, groupId: Data) async throws -> Data {
        logger.error("Get group info not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }

    /// Process a commit message
    func processCommit(for userDID: String, groupId: Data, commitData: Data) async throws -> ProcessCommitResult {
        logger.info("📍 [MLSClient.processCommit] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16)), commit: \(commitData.count) bytes")
        let context = getContext(for: userDID)
        do {
            let result = try context.processCommit(groupId: groupId, commitData: commitData)
            logger.info("✅ [MLSClient.processCommit] Success - newEpoch: \(result.newEpoch), updateProposals: \(result.updateProposals.count)")
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.processCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Create a commit for pending proposals
    func createCommit(for userDID: String, groupId: Data) async throws -> Data {
        logger.error("Create commit not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }

    /// Clear pending commit for a group
    func clearPendingCommit(for userDID: String, groupId: Data) async throws {
        logger.info("📍 [MLSClient.clearPendingCommit] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16))")
        let context = getContext(for: userDID)
        do {
            try context.clearPendingCommit(groupId: groupId)
            logger.info("✅ [MLSClient.clearPendingCommit] Success")
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.clearPendingCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Merge a pending commit after validation
    func mergePendingCommit(for userDID: String, groupId: Data) async throws -> UInt64 {
        logger.info("📍 [MLSClient.mergePendingCommit] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16))")
        let context = getContext(for: userDID)
        do {
            let newEpoch = try context.mergePendingCommit(groupId: groupId)
            logger.info("✅ [MLSClient.mergePendingCommit] Success - newEpoch: \(newEpoch)")
            return newEpoch
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.mergePendingCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Merge a staged commit after validation
    func mergeStagedCommit(for userDID: String, groupId: Data) async throws -> UInt64 {
        let context = getContext(for: userDID)
        do {
            let newEpoch = try context.mergeStagedCommit(groupId: groupId)
            logger.info("Staged commit merged, new epoch: \(newEpoch)")
            return newEpoch
        } catch let error as MlsError {
            logger.error("Merge staged commit failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    // MARK: - Proposal Inspection and Management

    /// Process a message and return detailed information about its content
    func processMessage(for userDID: String, groupId: Data, messageData: Data) async throws -> ProcessedContent {
        logger.info("📍 [MLSClient.processMessage] START - user: \(userDID), groupId: \(groupId.hexEncodedString().prefix(16)), message: \(messageData.count) bytes")
        let context = getContext(for: userDID)
        do {
            let content = try context.processMessage(groupId: groupId, messageData: messageData)
            logger.info("✅ [MLSClient.processMessage] Success - content type: \(String(describing: content))")
            return content
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.processMessage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Store a validated proposal in the proposal queue
    func storeProposal(for userDID: String, groupId: Data, proposalRef: ProposalRef) async throws {
        let context = getContext(for: userDID)
        do {
            try context.storeProposal(groupId: groupId, proposalRef: proposalRef)
            logger.info("Proposal stored successfully")
        } catch let error as MlsError {
            logger.error("Store proposal failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// List all pending proposals for a group
    func listPendingProposals(for userDID: String, groupId: Data) async throws -> [ProposalRef] {
        let context = getContext(for: userDID)
        do {
            let proposals = try context.listPendingProposals(groupId: groupId)
            logger.info("Found \(proposals.count) pending proposals")
            return proposals
        } catch let error as MlsError {
            logger.error("List proposals failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Remove a proposal from the proposal queue
    func removeProposal(for userDID: String, groupId: Data, proposalRef: ProposalRef) async throws {
        let context = getContext(for: userDID)
        do {
            try context.removeProposal(groupId: groupId, proposalRef: proposalRef)
            logger.info("Proposal removed successfully")
        } catch let error as MlsError {
            logger.error("Remove proposal failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Commit all pending proposals that have been validated
    func commitPendingProposals(for userDID: String, groupId: Data) async throws -> Data {
        let context = getContext(for: userDID)
        do {
            let commitData = try context.commitPendingProposals(groupId: groupId)
            logger.info("Pending proposals committed successfully")
            return commitData
        } catch let error as MlsError {
            logger.error("Commit proposals failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    // MARK: - Persistence

    /// Load MLS storage from encrypted GRDB and restore Rust FFI state
    func loadStorage(for userDID: String) async throws {
        logger.info("🔐 Loading MLS storage from encrypted database for user: \(userDID.prefix(20))...")
        let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: userDID)
        let storageData = try await database.read { db in
            try Data.fetchOne(db, sql: """
                SELECT blobData FROM MLSStorageBlobModel
                WHERE blobType = ? AND currentUserDID = ?
                ORDER BY updatedAt DESC LIMIT 1;
            """, arguments: [MLSStorageBlobModel.BlobType.ffiState, userDID])
        }

        guard let storageData else {
            logger.info("No persisted storage found for user - starting fresh")
            return
        }

        logger.info("Deserializing \(storageData.count) bytes into context for user: \(userDID.prefix(20))...")
        let context = getContext(for: userDID)
        do {
            try context.deserializeStorage(storageBytes: storageData)
            logger.info("✅ MLS storage loaded and deserialized into per-user context")

            // CRITICAL FIX: Check if key package bundles were restored
            // If cache is empty, we need to create local bundles even if server has plenty
            // This ensures we can decrypt Welcome messages on THIS device
            try await ensureLocalKeyPackageBundles(for: userDID, context: context)
        } catch let error as MlsError {
            logger.error("❌ Failed to deserialize MLS storage: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Ensure local key package bundles exist after deserialization
    /// Creates bundles locally if cache is empty, regardless of server inventory
    private func ensureLocalKeyPackageBundles(for userDID: String, context: MlsContext) async throws {
        // Phase 2 improvement: Direct bundle count query (no JSON parsing needed)
        let bundleCount: UInt64
        do {
            bundleCount = try context.getKeyPackageBundleCount()
            logger.debug("📊 Detected \(bundleCount) key package bundles in cache (using direct FFI query)")
        } catch {
            logger.error("❌ Failed to query bundle count: \(error.localizedDescription)")
            logger.debug("   Falling back to JSON parsing method...")
            // Fallback to JSON parsing if FFI query fails (backward compatibility)
            let testStorage = try context.serializeStorage()
            bundleCount = UInt64(try extractBundleCount(from: testStorage))
            logger.debug("📊 Detected \(bundleCount) bundles via JSON parsing (storage size: \(testStorage.count) bytes)")
        }

        // If no bundles detected, force create minimum bundles for Welcome message processing
        if bundleCount == 0 {
            logger.warning("⚠️ No key package bundles detected after deserialization - force creating \(self.minLocalBundles) bundles")
            logger.info("🔧 Creating \(self.minLocalBundles) local key package bundles for Welcome message processing")

            for i in 0..<minLocalBundles {
                do {
                    let keyPackageBytes = try await createKeyPackage(for: userDID, identity: userDID)
                    logger.debug("✅ Created local bundle \(i+1)/\(self.minLocalBundles) (\(keyPackageBytes.count) bytes)")
                } catch {
                    logger.error("❌ Failed to create local bundle \(i+1): \(error.localizedDescription)")
                    throw error
                }
            }

            logger.info("✅ Force-created \(self.minLocalBundles) local key package bundles - Welcome messages can now be processed")
        } else {
            logger.debug("✅ Found \(bundleCount) key package bundles in cache - Welcome processing ready")
        }
    }

    /// Extract bundle count from serialized MLS storage JSON (fallback method)
    /// Parses the SerializedState JSON to count key_package_bundles array length
    /// Note: This is a fallback for Phase 1 compatibility. Phase 2+ uses getKeyPackageBundleCount() FFI.
    private func extractBundleCount(from storageData: Data) throws -> Int {
        struct SerializedState: Decodable {
            let key_package_bundles: [KeyPackageBundleRef]

            struct KeyPackageBundleRef: Decodable {
                // We only care about count, so minimal structure is fine
            }
        }

        do {
            let decoder = JSONDecoder()
            let state = try decoder.decode(SerializedState.self, from: storageData)
            return state.key_package_bundles.count
        } catch {
            logger.error("❌ Failed to parse serialized storage JSON: \(error.localizedDescription)")
            logger.debug("   Falling back to assuming 0 bundles due to parse error")
            // If we can't parse, assume no bundles (conservative approach)
            return 0
        }
    }

    /// Minimum number of local bundles to maintain for Welcome message processing
    private let minLocalBundles = 5

    /// Phase 4: Proactive monitoring configuration
    private let minimumAvailableBundles = 10  // Trigger replenishment when below this
    private let targetBundleCount = 25         // Replenish to this count
    private let batchUploadSize = 5            // Upload bundles in batches of this size

    /// Phase 4: Monitor and automatically replenish key package bundles
    /// Proactively checks server inventory and uploads bundles when running low
    /// - Parameter userDID: User DID to monitor bundles for
    /// - Returns: Tuple of (available bundles on server, bundles uploaded)
    func monitorAndReplenishBundles(for userDID: String) async throws -> (available: Int, uploaded: Int) {
        guard let apiClient = self.apiClient else {
            logger.error("❌ [Phase 4] API client not configured - cannot monitor bundles")
            throw MLSError.operationFailed
        }

        logger.info("🔍 [Phase 4] Starting proactive bundle monitoring for user: \(userDID.prefix(20))...")

        // Query server bundle status (Phase 3 endpoint)
        let status = try await apiClient.getKeyPackageStatus()

        logger.info("📊 [Phase 4] Server bundle status:")
        logger.debug("   - Total uploaded: \(status.totalUploaded)")
        logger.debug("   - Available: \(status.available)")
        logger.debug("   - Consumed: \(status.consumed)")
        logger.debug("   - Reserved: \(String(describing:status.reserved))")

        // Check if replenishment is needed
        if status.available >= minimumAvailableBundles {
            logger.info("✅ [Phase 4] Sufficient bundles available (\(status.available)) - no action needed")
            return (available: status.available, uploaded: 0)
        }

        // Calculate how many bundles to upload
        let neededCount = targetBundleCount - status.available
        logger.warning("⚠️ [Phase 4] Low bundle count! Available: \(status.available), minimum: \(self.minimumAvailableBundles)")
        logger.info("🔧 [Phase 4] Replenishing \(neededCount) bundles to reach target of \(self.targetBundleCount)")

        // Create and upload bundles in batches
        var uploadedCount = 0
        let context = getContext(for: userDID)

        for batchIndex in stride(from: 0, to: neededCount, by: batchUploadSize) {
            let batchCount = min(batchUploadSize, neededCount - batchIndex)
            logger.debug("📦 [Phase 4] Creating batch \(batchIndex/self.batchUploadSize + 1) - \(batchCount) bundles")

            var batchPackages: [MLSKeyPackageUploadData] = []

            for i in 0..<batchCount {
                do {
                    let keyPackageBytes = try await createKeyPackage(for: userDID, identity: userDID)
                    let base64Package = keyPackageBytes.base64EncodedString()
                    let idempotencyKey = UUID().uuidString.lowercased()

                    batchPackages.append(MLSKeyPackageUploadData(
                        keyPackage: base64Package,
                        cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
                        expires: Date().addingTimeInterval(90 * 24 * 60 * 60), // 90 days
                        idempotencyKey: idempotencyKey
                    ))

                    logger.debug("   ✅ Created bundle \(batchIndex + i + 1)/\(neededCount)")
                } catch {
                    logger.error("   ❌ Failed to create bundle \(batchIndex + i + 1): \(error.localizedDescription)")
                    throw error
                }
            }

            // Upload batch to server
            do {
                let result = try await apiClient.publishKeyPackagesBatch(batchPackages)
                logger.debug("   📤 Batch upload complete - succeeded: \(result.succeeded), failed: \(result.failed)")

                if let errors = result.errors, !errors.isEmpty {
                    logger.warning("   ⚠️ Some uploads failed:")
                    for error in errors {
                        logger.debug("      - Index \(error.index): \(error.error)")
                    }
                }

                uploadedCount += result.succeeded
            } catch {
                logger.error("   ❌ Batch upload failed: \(error.localizedDescription)")
                throw error
            }

            // Small delay between batches to avoid overwhelming server
            if batchIndex + batchUploadSize < neededCount {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        logger.info("✅ [Phase 4] Replenishment complete - uploaded \(uploadedCount) bundles")
        logger.info("📊 [Phase 4] New server bundle count: \(status.available + uploadedCount)")

        return (available: status.available + uploadedCount, uploaded: uploadedCount)
    }

    /// Phase 4: Diagnostic logging for bundle lifecycle
    /// Logs comprehensive bundle state for debugging
    func logBundleDiagnostics(for userDID: String) async throws {
        guard let apiClient = self.apiClient else {
            logger.error("❌ [Phase 4] API client not configured - cannot run diagnostics")
            throw MLSError.operationFailed
        }

        logger.info("🔬 [Phase 4] Bundle Diagnostics for user: \(userDID.prefix(20))")

        // Local bundle count (Phase 2 FFI query)
        let context = getContext(for: userDID)
        let localCount: UInt64
        do {
            localCount = try context.getKeyPackageBundleCount()
            logger.info("   📍 Local bundles in cache: \(localCount)")
        } catch {
            logger.warning("   ⚠️ Failed to query local bundles: \(error.localizedDescription)")
            throw error
        }

        // Server bundle status (Phase 3 endpoint)
        do {
            let status = try await apiClient.getKeyPackageStatus(limit: 5)
            logger.info("   📍 Server bundle status:")
            logger.info("      - Total uploaded: \(status.totalUploaded)")
            logger.info("      - Available: \(status.available)")
            logger.info("      - Consumed: \(status.consumed)")
            logger.info("      - Reserved: \(status.reserved ?? 0)")

            if let consumedPackages = status.consumedPackages, !consumedPackages.isEmpty {
                logger.debug("   📜 Recent consumption history (last \(consumedPackages.count)):")
                for pkg in consumedPackages {
                    logger.debug("      - Hash: \(pkg.keyPackageHash.prefix(16))... | Consumed: \(pkg.consumedAt.date) | Group: \(pkg.usedInGroup ?? "unknown")")
                }
            }

            // Warning thresholds
            if status.available < minimumAvailableBundles {
                logger.warning("   ⚠️ ALERT: Available bundles (\(status.available)) below minimum threshold (\(self.minimumAvailableBundles))")
                logger.warning("      ACTION REQUIRED: Call monitorAndReplenishBundles() to replenish")
            }

            if status.available == 0 {
                logger.error("   🚨 CRITICAL: No bundles available! Cannot process Welcome messages!")
            }
        } catch {
            logger.error("   ❌ Failed to query server status: \(error.localizedDescription)")
            throw error
        }

        logger.info("✅ [Phase 4] Diagnostics complete")
    }

    /// Save MLS storage to encrypted GRDB for persistence
    func saveStorage(for userDID: String) async throws {
        logger.info("🔐 Saving MLS storage for user: \(userDID.prefix(20))...")
        let context = getContext(for: userDID)
        do {
            let storageData = try context.serializeStorage()
            logger.info("Serialized \(storageData.count) bytes from per-user context")
            let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: userDID)
            try await database.write { db in
                let blobID = "ffi_state_\(userDID.prefix(20))_\(UUID().uuidString)"
                let now = Date()
                try db.execute(sql: """
                    INSERT OR REPLACE INTO MLSStorageBlobModel (
                        blobID, currentUserDID, blobType, blobData, mimeType, size, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, arguments: [
                    blobID, userDID, MLSStorageBlobModel.BlobType.ffiState,
                    storageData, "application/octet-stream", storageData.count, now, now
                ])
            }
            logger.info("✅ MLS storage saved to encrypted database for user: \(userDID.prefix(20))...")
        } catch let error as MlsError {
            logger.error("❌ Failed to serialize MLS storage: \(error.localizedDescription)")
            throw MLSError.operationFailed
        } catch {
            logger.error("❌ Failed to save MLS storage: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Setup lifecycle observers for automatic storage persistence
    private func setupLifecycleObservers() {
        // FIXME: This needs to be re-thought. We don't have a single "current user" here.
        // The AuthManager or a similar higher-level component should be responsible for
        // saving storage for the active user on lifecycle events.
    }

    /// Clear all MLS storage for a specific user
    public func clearStorage(for userDID: String) async throws {
        logger.info("🔐 Clearing MLS storage for user: \(userDID)")
        contexts.removeValue(forKey: userDID)
        try await MLSGRDBManager.shared.deleteDatabase(for: userDID)
        logger.info("✅ MLS storage cleared for \(userDID)")
    }
}
