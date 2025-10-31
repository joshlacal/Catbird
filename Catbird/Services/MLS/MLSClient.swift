import Foundation
import OSLog
import Combine

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

    /// Default configuration with best security practices
    public static let `default` = MLSGroupConfiguration(
        maxPastEpochs: 0,              // Best forward secrecy - no old epochs
        outOfOrderTolerance: 10,       // Reasonable out-of-order tolerance
        maximumForwardDistance: 2000,  // Standard forward distance
        useCiphertext: true,           // Privacy by default (deprecated)
    )

    /// Configuration optimized for reliability over security
    /// Use when message delivery may be unreliable or out-of-order
    public static let reliable = MLSGroupConfiguration(
        maxPastEpochs: 3,              // Keep 3 past epochs for late messages
        outOfOrderTolerance: 50,       // Higher tolerance for reordering
        maximumForwardDistance: 5000,  // Larger forward distance
        useCiphertext: true,           // Still maintain privacy (deprecated)
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
    /// to maintain group state in memory and Core Data persistence
    static let shared = MLSClient()

    private let context: MlsContext
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.catbird", category: "MLSClient")
    private let storage = MLSStorage.shared

    /// Current user's DID - must be set before using persistence features
    private var currentUserDID: String?

    /// Cancellables for lifecycle observers
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        self.context = MlsContext()
        logger.info("🔐 MLSClient initialized with UniFFI (singleton)")
        setupLifecycleObservers()
        logger.debug("📍 [MLSClient.init] Complete")
    }

    // MARK: - Group Management

    /// Create a new MLS group
    /// - Parameters:
    ///   - identity: User identity (email or user ID)
    ///   - configuration: Forward secrecy and security configuration
    /// - Returns: Group ID as Data
    func createGroup(identity: String, configuration: MLSGroupConfiguration = .default) async throws -> Data {
        logger.info("📍 [MLSClient.createGroup] START - identity: \(identity), maxPastEpochs: \(configuration.maxPastEpochs), outOfOrder: \(configuration.outOfOrderTolerance), maxForward: \(configuration.maximumForwardDistance)")

        do {
            let identityBytes = Data(identity.utf8)
            logger.debug("📍 [MLSClient.createGroup] Identity bytes: \(identityBytes.count)")
            
            let result = try context.createGroup(identityBytes: identityBytes, config: configuration.toFFI())
            let groupId = result.groupId
            let groupIdHex = groupId.hexEncodedString()
            
            logger.info("✅ [MLSClient.createGroup] Group created - ID: \(groupIdHex.prefix(16))..., \(groupId.count) bytes")
            logger.debug("📍 [MLSClient.createGroup] Complete - returning groupId")
            return groupId
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.createGroup] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Join an existing group using a welcome message
    /// - Parameters:
    ///   - welcome: Serialized welcome message
    ///   - identity: User identity
    ///   - configuration: Forward secrecy and security configuration
    /// - Returns: Group ID that was joined
    func joinGroup(welcome: Data, identity: String, configuration: MLSGroupConfiguration = .default) async throws -> Data {
        logger.info("📍 [MLSClient.joinGroup] START - identity: \(identity), welcome size: \(welcome.count) bytes")
        logger.debug("📍 [MLSClient.joinGroup] Config - maxPastEpochs: \(configuration.maxPastEpochs)")

        do {
            let identityBytes = Data(identity.utf8)
            logger.debug("📍 [MLSClient.joinGroup] Processing welcome message...")
            
            let result = try context.processWelcome(welcomeBytes: welcome, identityBytes: identityBytes, config: configuration.toFFI())
            let groupId = result.groupId
            let groupIdHex = groupId.hexEncodedString()

            logger.info("✅ [MLSClient.joinGroup] Joined group - ID: \(groupIdHex.prefix(16))..., \(groupId.count) bytes")
            logger.debug("📍 [MLSClient.joinGroup] Complete")
            return groupId
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.joinGroup] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    // MARK: - Member Management
    
    /// Add members to an existing group
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - keyPackages: Array of serialized key packages
    /// - Returns: Commit and welcome messages for the update
    func addMembers(groupId: Data, keyPackages: [Data]) async throws -> AddMembersResult {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.addMembers] START - groupId: \(groupIdHex.prefix(16))..., keyPackages: \(keyPackages.count)")
        
        guard !keyPackages.isEmpty else {
            logger.error("❌ [MLSClient.addMembers] No key packages provided")
            throw MLSError.operationFailed
        }
        
        do {
            // Log each key package size
            for (idx, kp) in keyPackages.enumerated() {
                logger.debug("📍 [MLSClient.addMembers] KeyPackage[\(idx)]: \(kp.count) bytes")
            }
            
            // Convert key packages to KeyPackageData array
            let keyPackageData = keyPackages.map { kp in
                KeyPackageData(data: kp)
            }
            
            logger.debug("📍 [MLSClient.addMembers] Calling FFI addMembers...")
            let result = try context.addMembers(
                groupId: groupId,
                keyPackages: keyPackageData
            )
            
            logger.info("✅ [MLSClient.addMembers] Success - commit: \(result.commitData.count) bytes, welcome: \(result.welcomeData.count) bytes")
            logger.debug("📍 [MLSClient.addMembers] Complete")
            
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.addMembers] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    /// Remove a member from the group (not directly supported in current API)
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - memberIndex: Index of member to remove
    /// - Returns: Commit message for the update
    func removeMember(groupId: Data, memberIndex: UInt32) async throws -> Data {
        logger.info("Removing member at index \(memberIndex)")
        logger.error("Remove member not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }
    
    // MARK: - Message Encryption/Decryption
    
    /// Encrypt a message for the group
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - plaintext: Message to encrypt as Data
    /// - Returns: Encrypted message
    func encryptMessage(groupId: Data, plaintext: Data) async throws -> EncryptResult {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.encryptMessage] START - groupId: \(groupIdHex.prefix(16))..., plaintext: \(plaintext.count) bytes")
        
        do {
            logger.debug("📍 [MLSClient.encryptMessage] Calling FFI encryptMessage...")
            let result = try context.encryptMessage(
                groupId: groupId,
                plaintext: plaintext
            )
            
            logger.info("✅ [MLSClient.encryptMessage] Success - ciphertext: \(result.ciphertext.count) bytes")
            logger.debug("📍 [MLSClient.encryptMessage] Complete")
            
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.encryptMessage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    /// Decrypt a message from the group
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - ciphertext: Encrypted message
    /// - Returns: Decrypted message
    func decryptMessage(groupId: Data, ciphertext: Data) async throws -> DecryptResult {
        logger.debug("Decrypting message for group")
        
        do {
            let result = try context.decryptMessage(
                groupId: groupId,
                ciphertext: ciphertext
            )
            
            logger.debug("Message decrypted successfully")
            
            return result
        } catch let error as MlsError {
            logger.error("Decryption failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    // MARK: - Key Package Management
    
    /// Create a key package for this user
    /// - Parameter identity: User identity
    /// - Returns: Serialized key package
    func createKeyPackage(identity: String) async throws -> Data {
        logger.info("📍 [MLSClient.createKeyPackage] START - identity: \(identity)")
        
        do {
            let identityBytes = Data(identity.utf8)
            logger.debug("📍 [MLSClient.createKeyPackage] Calling FFI createKeyPackage...")
            
            let result = try context.createKeyPackage(identityBytes: identityBytes)
            
            logger.info("✅ [MLSClient.createKeyPackage] Success - \(result.keyPackageData.count) bytes")
            logger.debug("📍 [MLSClient.createKeyPackage] Complete")
            return result.keyPackageData
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.createKeyPackage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    /// Update key package for an existing group (not directly supported in current API)
    /// - Parameter groupId: Group identifier
    /// - Returns: Updated key package
    func updateKeyPackage(groupId: Data) async throws -> Data {
        logger.info("Updating key package for group")
        logger.error("Update key package not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }
    
    // MARK: - Group State
    
    /// Get the current epoch for a group
    /// - Parameter groupId: Group identifier
    /// - Returns: Current epoch number
    func getEpoch(groupId: Data) async throws -> UInt64 {
        do {
            let epoch = try context.getEpoch(groupId: groupId)
            return epoch
        } catch let error as MlsError {
            logger.error("Get epoch failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    /// Check if a group exists in local storage
    /// - Parameter groupId: Group identifier
    /// - Returns: true if group exists locally, false otherwise
    func groupExists(groupId: Data) -> Bool {
        return context.groupExists(groupId: groupId)
    }
    
    /// Get group info for external parties (not directly supported in current API)
    /// - Parameter groupId: Group identifier
    /// - Returns: Serialized group info
    func getGroupInfo(groupId: Data) async throws -> Data {
        logger.error("Get group info not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }
    
    /// Process a commit message
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - commitData: Serialized commit message
    /// - Returns: New epoch after processing commit
    func processCommit(groupId: Data, commitData: Data) async throws -> ProcessCommitResult {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.processCommit] START - groupId: \(groupIdHex.prefix(16))..., commit: \(commitData.count) bytes")

        do {
            logger.debug("📍 [MLSClient.processCommit] Calling FFI processCommit...")
            let result = try context.processCommit(
                groupId: groupId,
                commitData: commitData
            )

            logger.info("✅ [MLSClient.processCommit] Success - newEpoch: \(result.newEpoch), updateProposals: \(result.updateProposals.count)")
            logger.debug("📍 [MLSClient.processCommit] Complete")
            return result
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.processCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }
    
    /// Create a commit for pending proposals (not directly supported in current API)
    /// - Parameter groupId: Group identifier
    /// - Returns: Commit data
    func createCommit(groupId: Data) async throws -> Data {
        logger.info("Creating commit for group")
        logger.error("Create commit not yet implemented in UniFFI API")
        throw MLSError.operationFailed
    }

    /// Clear pending commit for a group
    /// This should be called when a commit is rejected by the delivery service
    /// to clean up pending state in OpenMLS and avoid inconsistencies
    /// - Parameter groupId: Group identifier
    func clearPendingCommit(groupId: Data) async throws {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.clearPendingCommit] START - groupId: \(groupIdHex.prefix(16))...")

        do {
            logger.debug("📍 [MLSClient.clearPendingCommit] Calling FFI clearPendingCommit...")
            try context.clearPendingCommit(groupId: groupId)
            logger.info("✅ [MLSClient.clearPendingCommit] Success")
            logger.debug("📍 [MLSClient.clearPendingCommit] Complete")
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.clearPendingCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Merge a pending commit after validation
    /// This should be called after the commit has been accepted by the delivery service
    /// - Parameter groupId: Group identifier
    /// - Returns: New epoch number after merging the commit
    func mergePendingCommit(groupId: Data) async throws -> UInt64 {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.mergePendingCommit] START - groupId: \(groupIdHex.prefix(16))...")

        do {
            logger.debug("📍 [MLSClient.mergePendingCommit] Calling FFI mergePendingCommit...")
            let newEpoch = try context.mergePendingCommit(groupId: groupId)
            logger.info("✅ [MLSClient.mergePendingCommit] Success - newEpoch: \(newEpoch)")
            logger.debug("📍 [MLSClient.mergePendingCommit] Complete")
            return newEpoch
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.mergePendingCommit] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Merge a staged commit after validation
    /// This should be called after validating incoming commits from other members
    /// - Parameter groupId: Group identifier
    /// - Returns: New epoch number after merging the commit
    func mergeStagedCommit(groupId: Data) async throws -> UInt64 {
        logger.info("Merging staged commit for group")

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
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - messageData: Message data to process
    /// - Returns: Processed content (application message, proposal, or staged commit)
    func processMessage(groupId: Data, messageData: Data) async throws -> ProcessedContent {
        let groupIdHex = groupId.hexEncodedString()
        logger.info("📍 [MLSClient.processMessage] START - groupId: \(groupIdHex.prefix(16))..., message: \(messageData.count) bytes")

        do {
            logger.debug("📍 [MLSClient.processMessage] Calling FFI processMessage...")
            let content = try context.processMessage(
                groupId: groupId,
                messageData: messageData
            )

            logger.info("✅ [MLSClient.processMessage] Success - content type: \(String(describing: content))")
            logger.debug("📍 [MLSClient.processMessage] Complete")
            return content
        } catch let error as MlsError {
            logger.error("❌ [MLSClient.processMessage] FAILED: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Store a validated proposal in the proposal queue
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - proposalRef: Reference to the proposal to store
    func storeProposal(groupId: Data, proposalRef: ProposalRef) async throws {
        logger.info("Storing proposal for group")

        do {
            try context.storeProposal(groupId: groupId, proposalRef: proposalRef)
            logger.info("Proposal stored successfully")
        } catch let error as MlsError {
            logger.error("Store proposal failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// List all pending proposals for a group
    /// - Parameter groupId: Group identifier
    /// - Returns: Array of proposal references
    func listPendingProposals(groupId: Data) async throws -> [ProposalRef] {
        logger.info("Listing pending proposals for group")

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
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - proposalRef: Reference to the proposal to remove
    func removeProposal(groupId: Data, proposalRef: ProposalRef) async throws {
        logger.info("Removing proposal from group")

        do {
            try context.removeProposal(groupId: groupId, proposalRef: proposalRef)
            logger.info("Proposal removed successfully")
        } catch let error as MlsError {
            logger.error("Remove proposal failed: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Commit all pending proposals that have been validated
    /// - Parameter groupId: Group identifier
    /// - Returns: Commit message data
    func commitPendingProposals(groupId: Data) async throws -> Data {
        logger.info("Committing pending proposals for group")

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

    /// Set the current user and load their MLS storage from Core Data
    ///
    /// This should be called after user authentication to restore their MLS groups
    /// and cryptographic state from persistent storage.
    ///
    /// - Parameter userDID: User's DID identifier
    /// - Throws: MLSError if storage load or deserialization fails
    func setUser(_ userDID: String) async throws {
        logger.info("Setting current user: \(userDID)")
        
        // If switching users, save current user's storage first
        if let currentDID = self.currentUserDID, currentDID != userDID {
            logger.info("Switching from user \(currentDID) to \(userDID)")
            do {
                try await saveStorage()
                logger.info("✅ Saved storage for previous user: \(currentDID)")
            } catch {
                logger.error("⚠️ Failed to save storage for previous user: \(error.localizedDescription)")
            }
        }
        
        self.currentUserDID = userDID

        // Load storage for the new user
        try await loadStorage()
    }

    /// Load MLS storage from Core Data and restore Rust FFI state
    ///
    /// Called automatically when setting the user. Can also be called manually
    /// to reload storage after app restart or background return.
    ///
    /// - Throws: MLSError if load or deserialization fails
    @MainActor
    func loadStorage() async throws {
        guard let userDID = currentUserDID else {
            logger.warning("No current user DID set - skipping storage load")
            return
        }

        logger.info("Loading MLS storage from Core Data for user: \(userDID)")

        guard let storageData = try storage.loadMLSStorageBlob(forUser: userDID) else {
            logger.info("No persisted storage found for user - starting fresh")
            return
        }

        logger.info("Deserializing \(storageData.count) bytes of storage...")

        do {
            try context.deserializeStorage(storageBytes: storageData)
            logger.info("✅ MLS storage loaded and deserialized successfully")
        } catch let error as MlsError {
            logger.error("❌ Failed to deserialize MLS storage: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Save MLS storage to Core Data for persistence
    ///
    /// This serializes the entire Rust FFI state (all groups, keys, secrets)
    /// and saves it to Core Data with encryption enabled.
    ///
    /// Called automatically on app lifecycle events (background, terminate).
    /// Can also be called manually after critical operations.
    ///
    /// - Throws: MLSError if serialization or save fails
    @MainActor
    func saveStorage() async throws {
        guard let userDID = currentUserDID else {
            logger.warning("No current user DID set - skipping storage save")
            return
        }

        logger.info("Saving MLS storage to Core Data for user: \(userDID)")

        do {
            let storageData = try context.serializeStorage()
            logger.info("Serialized \(storageData.count) bytes of storage")

            try storage.saveMLSStorageBlob(storageData, forUser: userDID)
            logger.info("✅ MLS storage saved to Core Data successfully")
        } catch let error as MlsError {
            logger.error("❌ Failed to serialize MLS storage: \(error.localizedDescription)")
            throw MLSError.operationFailed
        }
    }

    /// Setup lifecycle observers for automatic storage persistence
    ///
    /// Observes:
    /// - App entering background → save storage
    /// - App terminating → save storage
    /// - Scene phase changes → save on inactive/background
    private func setupLifecycleObservers() {
        #if os(iOS)
        // App lifecycle notifications
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await self?.saveStorage()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await self?.saveStorage()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await self?.saveStorage()
                }
            }
            .store(in: &cancellables)
        #endif

        logger.info("Lifecycle observers setup complete")
    }

    /// Clear all storage for the current user
    ///
    /// Used when logging out or clearing user data. This removes both
    /// the in-memory state and the persisted storage blob.
    ///
    /// - Throws: MLSError if deletion fails
    @MainActor
    func clearStorage() async throws {
        guard let userDID = currentUserDID else {
            logger.warning("No current user DID set - nothing to clear")
            return
        }

        logger.info("Clearing MLS storage for user: \(userDID)")

        // Delete from Core Data
        try storage.deleteMLSStorageBlob(forUser: userDID)

        // Reset current user
        currentUserDID = nil

        logger.info("✅ MLS storage cleared successfully")
    }
}


