import Foundation
import OSLog
import Petrel
import CryptoKit
import GRDB

// MARK: - Type Definitions

/// Errors specific to MLS conversation operations
enum MLSConversationError: Error, LocalizedError {
    case invalidKeyPackage(String)
    case noAuthentication
    case contextNotInitialized
    case conversationNotFound
    case groupStateNotFound
    case groupNotInitialized
    case invalidWelcomeMessage
    case invalidIdentity
    case invalidGroupId
    case invalidMessage
    case invalidCiphertext
    case decodingFailed
    case decryptionFailed
    case invalidEpoch(String)
    case missingKeyPackages([String])
    case operationFailed(String)
    case mlsError(String)
    case serverError(Error)
    case syncFailed(Error)
    case commitProcessingFailed(Int, Error)
    case memberSyncFailed
    case conversationNotReady
    case duplicateSend
    case invalidCredential
    case keyPackageDesyncRecoveryInitiated

    var errorDescription: String? {
        switch self {
        case .invalidKeyPackage(let message):
            return "Invalid key package format: \(message)"
        case .noAuthentication:
            return "User authentication required"
        case .contextNotInitialized:
            return "MLS context not initialized"
        case .conversationNotFound:
            return "Conversation not found"
        case .groupStateNotFound:
            return "Group state not found"
        case .groupNotInitialized:
            return "MLS group not initialized locally"
        case .invalidWelcomeMessage:
            return "Invalid Welcome message format"
        case .invalidIdentity:
            return "Invalid user identity"
        case .invalidGroupId:
            return "Invalid group identifier"
        case .invalidMessage:
            return "Invalid message format"
        case .invalidCiphertext:
            return "Invalid ciphertext format"
        case .decodingFailed:
            return "Failed to decode message"
        case .decryptionFailed:
            return "Message decryption failed"
        case .invalidEpoch(let message):
            return "Epoch mismatch: \(message)"
        case .missingKeyPackages(let dids):
            return "Missing key packages for members: \(dids.joined(separator: ", "))"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        case .mlsError(let message):
            return "MLS protocol error: \(message)"
        case .serverError(let error):
            return "Server error: \(error.localizedDescription)"
        case .syncFailed(let error):
            return "Synchronization failed: \(error.localizedDescription)"
        case .commitProcessingFailed(let epoch, let error):
            return "Commit processing failed at epoch \(epoch): \(error.localizedDescription)"
        case .memberSyncFailed:
            return "Member synchronization with server failed"
        case .conversationNotReady:
            return "Conversation is not ready for messaging"
        case .duplicateSend:
            return "Duplicate message send detected"
        case .invalidCredential:
            return "Invalid MLS credential data"
        case .keyPackageDesyncRecoveryInitiated:
            return "Key package synchronization recovery initiated. Please rejoin the conversation when prompted."
        }
    }
}

/// MLS group state tracking
struct MLSGroupState {
    var groupId: String
    var convoId: String
    var epoch: UInt64
    var members: Set<String>
}

/// Key package with hash tracking for lifecycle management
struct KeyPackageWithHash {
    let data: Data
    let hash: String
    let did: DID
}

/// Prepared data for sending Welcome/commit to server
private struct PreparedInitialMembers {
    let commitData: Data
    let welcomeData: Data
    let hashEntries: [BlueCatbirdMlsCreateConvo.KeyPackageHashEntry]
}

/// Result returned after successfully creating a conversation on the server
private struct ServerConversationCreationResult {
    let convo: BlueCatbirdMlsDefs.ConvoView
    let commitData: Data?
    let welcomeData: Data?
}

/// Pending operation
struct MLSOperation {
    enum OperationType {
        case addMembers([String])
        case sendMessage(String)
        case sync
    }

    let id: UUID
    let type: OperationType
    let convoId: String?
    var retryCount: Int
    let createdAt: Date
}

/// State change observer
class MLSStateObserver {
    let id: UUID
    let onStateChange: (MLSStateEvent) -> Void

    init(id: UUID = UUID(), onStateChange: @escaping (MLSStateEvent) -> Void) {
        self.id = id
        self.onStateChange = onStateChange
    }
}

/// State change events
enum MLSStateEvent {
    case conversationCreated(BlueCatbirdMlsDefs.ConvoView)
    case conversationJoined(BlueCatbirdMlsDefs.ConvoView)
    case conversationLeft(String)
    case membersAdded(String, [DID])
    case messageSent(String, ATProtocolDate)
    case epochUpdated(String, Int)
    case syncCompleted(Int)
    case syncFailed(Error)

    var description: String {
        switch self {
        case .conversationCreated(let convo):
            return "Conversation created: \(convo.groupId)"
        case .conversationJoined(let convo):
            return "Conversation joined: \(convo.groupId)"
        case .conversationLeft(let id):
            return "Conversation left: \(id)"
        case .membersAdded(let convoId, let members):
            return "Members added to \(convoId): \(members.count)"
        case .messageSent(let msgId, _):
            return "Message sent: \(msgId)"
        case .epochUpdated(let convoId, let epoch):
            return "Epoch updated for \(convoId): \(epoch)"
        case .syncCompleted(let count):
            return "Sync completed: \(count) conversations"
        case .syncFailed(let error):
            return "Sync failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Conversation Manager

/// Tracks conversation initialization state to prevent race conditions
private enum ConversationInitState: Sendable {
    case initializing
    case active
    case failed(String)
}

/// Main coordinator for MLS conversation management
/// Handles group initialization, member management, encryption/decryption,
/// server synchronization, key package management, and epoch updates
@Observable
final class MLSConversationManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationManager")
    
    // MARK: - Dependencies

    private let apiClient: MLSAPIClient
    let mlsClient: MLSClient  
    private let storage: MLSStorage
    private let database: DatabaseQueue
    private let configuration: MLSConfiguration
    
    // MARK: - State
    
    /// Active conversations indexed by conversation ID
    private(set) var conversations: [String: BlueCatbirdMlsDefs.ConvoView] = [:]
    
    /// MLS group states indexed by group ID
    private var groupStates: [String: MLSGroupState] = [:]
    
    /// Pending operations queue
    // Pending operations queue (MLSOperation type not defined - removed)
    
    /// Observers for state changes
    private var observers: [MLSStateObserver] = []
    
    /// Current user's DID
    private(set) var userDid: String?

    /// Public accessor for current user DID (for optimistic UI)
    var currentUserDID: String? {
      userDid
    }

    /// Sync status
    private(set) var isSyncing = false
    
    /// Initialization status
    private(set) var isInitialized = false

    /// Background cleanup task
    private var cleanupTask: Task<Void, Never>?
    
    /// Last time key packages were refreshed
    private var lastKeyPackageRefresh: Date?

    /// Key package monitor for smart replenishment
    private var keyPackageMonitor: MLSKeyPackageMonitor?

    /// Consumption tracker for key package usage analytics
    private var consumptionTracker: MLSConsumptionTracker?

    /// Recently sent message tracking for deduplication (convoId -> Set of idempotency keys)
    private var recentlySentMessages: [String: Set<String>] = [:]
    private let deduplicationWindow: TimeInterval = 60 // 60 seconds

    /// Track initialization state for conversations to prevent race conditions
    private var conversationStates: [String: ConversationInitState] = [:]

    /// Hashes that have been reported as exhausted/unavailable by the MLS service (keyed by DID)
    private var exhaustedKeyPackageHashes: [String: Set<String>] = [:]

    // MARK: - Configuration

    /// Default cipher suite for new groups
    let defaultCipherSuite: String = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

    /// Key package refresh interval (in seconds) - reduced to 4 hours for proactive monitoring
    let keyPackageRefreshInterval: TimeInterval = 14400 // 4 hours (was 24 hours)
    
    /// Maximum retry attempts for failed operations
    private let maxRetries = 3
    
    // MARK: - Initialization
    
    /// Initialize MLS Conversation Manager
    /// - Parameters:
    ///   - apiClient: MLS API client for server communication
    ///   - database: GRDB database queue for MLS storage
    ///   - userDid: Current user's DID
    ///   - storage: MLS storage layer (defaults to shared instance)
    ///   - configuration: MLS configuration (defaults to standard config)
    ///   - atProtoClient: ATProtoClient for device registration
    init(
      apiClient: MLSAPIClient,
      database: DatabaseQueue,
      userDid: String? = nil,
      storage: MLSStorage = .shared,
      configuration: MLSConfiguration = .default,
      atProtoClient: ATProtoClient
    ) {
        self.apiClient = apiClient
        self.database = database
        self.userDid = userDid
        self.mlsClient = MLSClient.shared  // Use singleton to persist groups
        self.storage = storage
        self.configuration = configuration

        // Phase 3/4: Configure MLSClient with API client for Welcome validation, bundle monitoring, and device registration
        MLSClient.shared.configure(apiClient: apiClient, atProtoClient: atProtoClient)

        logger.info("MLSConversationManager initialized with UniFFI client (using shared MLSClient)")
        configuration.validate()
    }

    /// Initialize the MLS crypto context
    func initialize() async throws {
        guard !isInitialized else {
            logger.debug("MLS context already initialized")
            return
        }

        // Load persisted MLS storage if user is authenticated
        if let userDid = userDid {
            logger.info("Loading persisted MLS storage for user: \(userDid)")
            do {
                try await mlsClient.loadStorage(for: userDid)
                logger.info("✅ MLS storage loaded successfully")
            } catch {
                logger.warning("⚠️ Failed to load MLS storage (will start fresh): \(error.localizedDescription)")
                // Don't fail initialization - user might be new or storage might be empty
            }
        } else {
            logger.warning("No user DID provided - MLS storage will not be persisted")
        }

        logger.info("MLS context initialized successfully")
        isInitialized = true

        // Initialize consumption tracking and monitoring
        if let userDid = userDid {
            consumptionTracker = MLSConsumptionTracker(userDID: userDid)
            keyPackageMonitor = MLSKeyPackageMonitor(
                userDID: userDid,
                consumptionTracker: consumptionTracker
            )
            logger.info("✅ Initialized smart key package monitoring")
        }

        // Upload initial key packages to server with smart monitoring
        do {
            try await smartRefreshKeyPackages()
            lastKeyPackageRefresh = Date()
        } catch {
            logger.error("Failed to upload initial key packages: \(error.localizedDescription)")
            // Don't fail initialization if key package upload fails
        }

        // Start background cleanup task if enabled
        if configuration.enableAutomaticCleanup {
            startBackgroundCleanup()
        }
    }

    /// Deinitialize and cleanup resources
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - Group Initialization
    
    /// Create a new MLS group/conversation
    /// - Parameters:
    ///   - initialMembers: DIDs of initial members to add (optional)
    ///   - name: Conversation name
    ///   - description: Conversation description (optional)
    ///   - avatarUrl: Avatar URL (optional)
    /// - Returns: Created conversation view
    func createGroup(
        initialMembers: [DID]? = nil,
        name: String,
        description: String? = nil,
        avatarUrl: String? = nil
    ) async throws -> BlueCatbirdMlsDefs.ConvoView {
        logger.info("🔵 [MLSConversationManager.createGroup] START - name: '\(name)', initialMembers: \(initialMembers?.count ?? 0)")

        guard isInitialized else {
            logger.error("❌ [MLSConversationManager.createGroup] Context not initialized")
            throw MLSConversationError.contextNotInitialized
        }

        guard let userDid = userDid else {
            logger.error("❌ [MLSConversationManager.createGroup] No authentication")
            throw MLSConversationError.noAuthentication
        }

        // Create temporary tracking ID for initialization state
        let tempId = UUID().uuidString
        conversationStates[tempId] = .initializing

        defer {
            conversationStates.removeValue(forKey: tempId)
        }

        logger.debug("📍 [MLSConversationManager.createGroup] Creating local group for user: \(userDid)")

        // ⭐ CRITICAL FIX: Create MLS group locally FIRST to get the groupID
        let groupId = try await mlsClient.createGroup(for: userDid, identity: userDid, configuration: configuration.groupConfiguration)
        let groupIdHex = groupId.hexEncodedString()
        logger.info("🔵 [MLSConversationManager.createGroup] Local group created: \(groupIdHex.prefix(16))...")

        // ⭐ FIXED: Use groupIdHex as conversationID (not random UUID) so Rust FFI epoch storage succeeds
        // The Rust FFI passes groupIdHex as the conversationId when storing epoch secrets,
        // so our database must use the same identifier as the primary key for foreign key constraints to work
        do {
            try await storage.ensureConversationExists(
                conversationID: groupIdHex,  // ← Use groupIdHex, not tempId
                groupID: groupIdHex,
                database: database
            )
            logger.info("✅ Created SQLCipher conversation record with ID: \(groupIdHex.prefix(16))...")
        } catch {
            logger.error("❌ Failed to create SQLCipher conversation: \(error.localizedDescription)")
            throw MLSConversationError.operationFailed("Failed to create local conversation record: \(error.localizedDescription)")
        }
        
        var welcomeDataArray: [Data] = []
        var commitData: Data?
        
        // Build metadata for conversation
        let metadataInput: BlueCatbirdMlsCreateConvo.MetadataInput?
        if !name.isEmpty || description != nil {
            metadataInput = BlueCatbirdMlsCreateConvo.MetadataInput(
                name: name.isEmpty ? nil : name,
                description: description
            )
        } else {
            metadataInput = nil
        }

        // Create conversation on server (handles key package retries internally)
        let creationResult: ServerConversationCreationResult
        do {
            creationResult = try await createConversationOnServer(
                userDid: userDid,
                groupId: groupId,
                groupIdHex: groupIdHex,
                initialMembers: initialMembers,
                metadata: metadataInput
            )
        } catch {
            logger.error("❌ [MLSConversationManager.createGroup] Server creation failed: \(error.localizedDescription)")

            conversationStates[tempId] = .failed(error.localizedDescription)

            if let members = initialMembers, !members.isEmpty {
                logger.debug("📍 [MLSConversationManager.createGroup] Cleaning up pending commit...")
                do {
                    try await mlsClient.clearPendingCommit(for: userDid, groupId: groupId)
                    logger.info("✅ [MLSConversationManager.createGroup] Cleared pending commit")
                } catch {
                    logger.error("❌ [MLSConversationManager.createGroup] Failed to clear pending commit: \(error.localizedDescription)")
                }
            }

            throw MLSConversationError.serverError(error)
        }

        if let welcomeData = creationResult.welcomeData {
            welcomeDataArray = [welcomeData]
        }
        commitData = creationResult.commitData
        let convo = creationResult.convo

        // GREENFIELD: Server uses groupId as canonical ID (no migration, no fallbacks)
        logger.info("✅ Conversation created: \(groupIdHex.prefix(16))...")

        // Store conversation state using groupId as canonical ID
        conversations[groupIdHex] = convo
        groupStates[groupIdHex] = MLSGroupState(
            groupId: groupIdHex,
            convoId: groupIdHex,
            epoch: UInt64(convo.epoch),
            members: Set(convo.members.map { $0.did.description })
        )

        // Persist MLS state to SQLCipher immediately after group creation
        do {
            try await mlsClient.saveStorage(for: userDid)
            logger.info("✅ Persisted MLS state after group creation")
        } catch {
            logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
        }

        // CRITICAL FIX: If members were added, sync with server BEFORE allowing messages
        if let members = initialMembers, !members.isEmpty, let commitData = commitData {
            logger.info("🔄 Syncing \(members.count) members with server to prevent epoch mismatch...")

            do {
                let addResult = try await apiClient.addMembers(
                    convoId: groupIdHex,
                    didList: members,
                    commit: commitData,
                    welcomeMessage: welcomeDataArray.first
                )

                guard addResult.success else {
                    logger.error("❌ Server member sync failed - success=false")
                    conversationStates[groupIdHex] = .failed("Member sync failed")
                    throw MLSConversationError.memberSyncFailed
                }

                logger.info("✅ Server synchronized at epoch \(addResult.newEpoch)")
                groupStates[groupIdHex]?.epoch = UInt64(addResult.newEpoch)
                logger.debug("📊 Updated local group state: epoch=\(addResult.newEpoch)")
            } catch {
                logger.error("❌ Server member sync failed: \(error.localizedDescription)")
                conversationStates[groupIdHex] = .failed(error.localizedDescription)
                throw MLSConversationError.memberSyncFailed
            }
        }

        // Mark conversation as active AFTER server sync completes
        conversationStates[groupIdHex] = .active
        logger.info("✅ Conversation '\(groupIdHex)' marked as ACTIVE - ready for messaging")

        // Notify observers AFTER state is active
        notifyObservers(.conversationCreated(convo))

        // Track key package consumption if members were added
        if let members = initialMembers, !members.isEmpty {
            Task {
                do {
                    try await keyPackageMonitor?.trackConsumption(
                        count: members.count,
                        operation: .createConversation,
                        context: "Created group '\(name)' with \(members.count) initial members"
                    )
                    logger.info("📊 Tracked consumption: \(members.count) packages for group creation")

                    // Proactive refresh check after consumption
                    try await smartRefreshKeyPackages()
                } catch {
                    logger.warning("⚠️ Failed to track consumption or refresh: \(error.localizedDescription)")
                }
            }
        }

        logger.info("✅ [MLSConversationManager.createGroup] COMPLETE - convoId: \(groupIdHex), epoch: \(convo.epoch)")
        return convo
    }
    
    
    /// Join an existing group using a Welcome message
    /// - Parameter welcomeMessage: Base64-encoded Welcome message
    /// - Returns: Joined conversation view
    func joinGroup(welcomeMessage: String) async throws -> BlueCatbirdMlsDefs.ConvoView {
        logger.info("Joining group from Welcome message")
        
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        
        guard isInitialized else {
            throw MLSConversationError.contextNotInitialized
        }
        
        // Decode and process Welcome message
        guard let welcomeData = Data(base64Encoded: welcomeMessage) else {
            throw MLSConversationError.invalidWelcomeMessage
        }
        
        let groupId = try await processWelcome(welcomeData: welcomeData, identity: userDid)
        logger.debug("Processed Welcome message, group ID: \(groupId)")
        
        // Fetch conversation details from server
        let conversations = try await apiClient.getConversations(limit: 100)
        guard let convo = conversations.convos.first(where: { $0.groupId == groupId }) else {
            throw MLSConversationError.conversationNotFound
        }
        
        // Store conversation state
        self.conversations[convo.groupId] = convo
        groupStates[groupId] = MLSGroupState(
            groupId: groupId,
            convoId: convo.groupId,
            epoch: UInt64(convo.epoch),
            members: Set(convo.members.map { $0.did.description })
        )
        
        // Notify observers
        notifyObservers(.conversationJoined(convo))
        
        logger.info("Successfully joined conversation: \(convo.groupId)")
        return convo
    }
    
    // MARK: - Member Management
    
    /// Add members to an existing conversation
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDids: DIDs of members to add
    func addMembers(convoId: String, memberDids: [String]) async throws {
        logger.info("🔵 [MLSConversationManager.addMembers] START - convoId: \(convoId), members: \(memberDids.count)")
        
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        guard let convo = conversations[convoId] else {
            logger.error("❌ [MLSConversationManager.addMembers] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }
        
        guard let groupState = groupStates[convo.groupId] else {
            logger.error("❌ [MLSConversationManager.addMembers] Group state not found")
            throw MLSConversationError.groupStateNotFound
        }
        
        guard let groupIdData = Data(hexEncoded: convo.groupId) else {
            logger.error("❌ [MLSConversationManager.addMembers] Invalid groupId")
            throw MLSConversationError.invalidGroupId
        }

        // Convert String DIDs to DID type
        let dids = try memberDids.map { try DID(didString: $0) }
        logger.debug("📍 [MLSConversationManager.addMembers] Converted \(dids.count) DIDs")

        // Fetch key packages for new members
        logger.debug("📍 [MLSConversationManager.addMembers] Fetching key packages...")
        let keyPackagesResult = try await apiClient.getKeyPackages(dids: dids)

        if let missing = keyPackagesResult.missing, !missing.isEmpty {
            logger.warning("⚠️ [MLSConversationManager.addMembers] Missing key packages: \(missing)")
            throw MLSConversationError.missingKeyPackages(missing.map { $0.description })
        }
        
        logger.info("✅ [MLSConversationManager.addMembers] Got \(keyPackagesResult.keyPackages.count) key packages")

        let keyPackages = keyPackagesResult.keyPackages
        let keyPackagesWithHashes = try await selectKeyPackages(for: dids, from: keyPackages, userDid: userDid)

        // Extract just the data for MLSClient
        let keyPackagesArray = keyPackagesWithHashes.map { $0.data }

        do {
            // 1. Create commit locally (staged, not merged)
            logger.info("🔵 [MLSConversationManager.addMembers] Step 1/4: Creating staged commit...")
            let addResult = try await mlsClient.addMembers(
                for: userDid,
                groupId: groupIdData,
                keyPackages: keyPackagesArray
            )
            logger.info("✅ [MLSConversationManager.addMembers] Staged commit created - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes")

            // 2. Send commit and welcome to server
            logger.info("🔵 [MLSConversationManager.addMembers] Step 2/4: Sending to server...")

            logger.info("📍 [MLSConversationManager.addMembers] Prepared Welcome message for \(dids.count) new members")

            // Build key package hash entries for server lifecycle tracking
            let keyPackageHashEntries: [BlueCatbirdMlsAddMembers.KeyPackageHashEntry] = keyPackagesWithHashes.map { kp in
                BlueCatbirdMlsAddMembers.KeyPackageHashEntry(
                    did: kp.did,
                    hash: kp.hash
                )
            }
            logger.info("📍 [MLSConversationManager.addMembers] Sending \(keyPackageHashEntries.count) key package hashes for lifecycle tracking")

            let addMembersResult: (success: Bool, newEpoch: Int)
            do {
                addMembersResult = try await apiClient.addMembers(
                    convoId: convoId,
                    didList: dids,
                    commit: addResult.commitData,
                    welcomeMessage: addResult.welcomeData,
                    keyPackageHashes: keyPackageHashEntries  // ✅ Now tracked!
                )
            } catch let apiError as MLSAPIError {
                let normalizedError = normalizeKeyPackageError(apiError)
                logger.error("❌ [MLSConversationManager.addMembers] Server error during addMembers: \(normalizedError.localizedDescription)")
                switch normalizedError {
                case .keyPackageNotFound(let detail):
                    recordKeyPackageFailure(detail: detail)
                    throw MLSConversationError.missingKeyPackages(memberDids)
                case .conversationNotFound:
                    throw MLSConversationError.conversationNotFound
                case .notConversationMember:
                    throw MLSConversationError.groupNotInitialized
                case .memberAlreadyExists:
                    throw MLSConversationError.operationFailed("One or more members are already part of this conversation")
                case .memberBlocked, .mutualBlockDetected:
                    throw MLSConversationError.operationFailed("Cannot add members due to Bluesky block relationships")
                case .tooManyMembers:
                    throw MLSConversationError.operationFailed("Adding these members would exceed the maximum allowed")
                default:
                    throw MLSConversationError.serverError(normalizedError)
                }
            }

            guard addMembersResult.success else {
                logger.warning("⚠️ [MLSConversationManager.addMembers] Server rejected commit, clearing...")
                try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
                throw MLSConversationError.operationFailed("Server rejected member addition")
            }
            let newEpoch = addMembersResult.newEpoch
            logger.info("✅ [MLSConversationManager.addMembers] Server accepted - newEpoch: \(newEpoch)")

            // Note: MLSClient.addMembers() now auto-merges the commit (merge-then-send pattern)
            // The group was already advanced before sending to server, ensuring Welcome has secrets
            logger.info("✅ [MLSConversationManager.addMembers] Local group already at epoch \(newEpoch) (auto-merged)")

            // 3. Update local state
            logger.info("🔵 [MLSConversationManager.addMembers] Step 3/3: Updating local state...")
            var updatedState = groupStates[convo.groupId] ?? groupState
            updatedState.epoch = UInt64(newEpoch)
            updatedState.members.formUnion(memberDids)
            groupStates[convo.groupId] = updatedState

            // Persist MLS state after adding members
            do {
                try await mlsClient.saveStorage(for: userDid)
                logger.info("✅ Persisted MLS state after adding members")
            } catch {
                logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
            }

            // Notify observers
            notifyObservers(.membersAdded(convoId, dids))
            notifyObservers(.epochUpdated(convoId, Int(newEpoch)))

            // Track key package consumption
            Task {
                do {
                    try await keyPackageMonitor?.trackConsumption(
                        count: memberDids.count,
                        operation: .addMembers,
                        context: "Added \(memberDids.count) members to conversation \(convoId)"
                    )
                    logger.info("📊 Tracked consumption: \(memberDids.count) packages for adding members")

                    // Proactive refresh check after consumption
                    try await smartRefreshKeyPackages()
                } catch {
                    logger.warning("⚠️ Failed to track consumption or refresh: \(error.localizedDescription)")
                }
            }

            logger.info("✅ [MLSConversationManager.addMembers] COMPLETE - convoId: \(convoId), epoch: \(newEpoch), members: \(updatedState.members.count)")

        } catch {
            logger.error("❌ [MLSConversationManager.addMembers] Error, cleaning up: \(error.localizedDescription)")

            do {
                try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
                logger.info("✅ [MLSConversationManager.addMembers] Cleared pending commit")
            } catch {
                logger.error("❌ [MLSConversationManager.addMembers] Failed to clear pending commit: \(error.localizedDescription)")
            }

            throw MLSConversationError.serverError(error)
        }
    }
    
    /// Remove current user from conversation
    /// - Parameter convoId: Conversation identifier
    func leaveConversation(convoId: String) async throws {
        logger.info("Leaving conversation: \(convoId)")

        guard let convo = conversations[convoId] else {
            throw MLSConversationError.conversationNotFound
        }

        do {
            _ = try await apiClient.leaveConversation(convoId: convoId)

            // Remove from local state
            conversations.removeValue(forKey: convoId)
            groupStates.removeValue(forKey: convo.groupId)

            // Notify observers
            notifyObservers(.conversationLeft(convoId))

            logger.info("Successfully left conversation: \(convoId)")

        } catch {
            logger.error("Failed to leave conversation: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    // MARK: - Admin Operations

    /// Remove a member from conversation (admin-only)
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDid: DID of member to remove
    ///   - reason: Optional reason for removal
    func removeMember(from convoId: String, memberDid: String, reason: String? = nil) async throws {
        logger.info("🔵 [MLSConversationManager.removeMember] START - convoId: \(convoId), memberDid: \(memberDid)")

        guard conversations[convoId] != nil else {
            logger.error("❌ [MLSConversationManager.removeMember] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        do {
            let (ok, epochHint) = try await apiClient.removeMember(
                convoId: convoId,
                targetDid: try DID(didString: memberDid),
                reason: reason
            )

            guard ok else {
                throw MLSConversationError.serverError(NSError(domain: "MLSConversationManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned failure for removeMember"]))
            }

            logger.info("✅ [MLSConversationManager.removeMember] SUCCESS - epochHint: \(epochHint)")

            // Refresh conversation state to update member list
            try await syncGroupState(for: convoId)

        } catch {
            logger.error("❌ [MLSConversationManager.removeMember] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    /// Promote a member to admin status
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDid: DID of member to promote
    func promoteAdmin(in convoId: String, memberDid: String) async throws {
        logger.info("🔵 [MLSConversationManager.promoteAdmin] START - convoId: \(convoId), memberDid: \(memberDid)")

        guard conversations[convoId] != nil else {
            logger.error("❌ [MLSConversationManager.promoteAdmin] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        do {
            let ok = try await apiClient.promoteAdmin(convoId: convoId, targetDid: try DID(didString: memberDid))

            guard ok else {
                throw MLSConversationError.serverError(NSError(domain: "MLSConversationManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned failure for promoteAdmin"]))
            }

            logger.info("✅ [MLSConversationManager.promoteAdmin] SUCCESS")

            // Refresh conversation state to update admin roster
            try await syncGroupState(for: convoId)

        } catch {
            logger.error("❌ [MLSConversationManager.promoteAdmin] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    /// Demote an admin to regular member status
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDid: DID of admin to demote
    func demoteAdmin(in convoId: String, memberDid: String) async throws {
        logger.info("🔵 [MLSConversationManager.demoteAdmin] START - convoId: \(convoId), memberDid: \(memberDid)")

        guard conversations[convoId] != nil else {
            logger.error("❌ [MLSConversationManager.demoteAdmin] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        do {
            let ok = try await apiClient.demoteAdmin(convoId: convoId, targetDid: try DID(didString: memberDid))

            guard ok else {
                throw MLSConversationError.serverError(NSError(domain: "MLSConversationManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned failure for demoteAdmin"]))
            }

            logger.info("✅ [MLSConversationManager.demoteAdmin] SUCCESS")

            // Refresh conversation state to update admin roster
            try await syncGroupState(for: convoId)

        } catch {
            logger.error("❌ [MLSConversationManager.demoteAdmin] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    // MARK: - Moderation

    /// Report a member for ToS violations
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDid: DID of member to report
    ///   - reason: Reason for report (e.g., "harassment", "spam", "inappropriate")
    ///   - details: Optional additional details about the report
    func reportMember(in convoId: String, memberDid: String, reason: String, details: String? = nil) async throws -> String {
        logger.info("🔵 [MLSConversationManager.reportMember] START - convoId: \(convoId), memberDid: \(memberDid), reason: \(reason)")

        guard conversations[convoId] != nil else {
            logger.error("❌ [MLSConversationManager.reportMember] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        do {
            let reportId = try await apiClient.reportMember(
                convoId: convoId,
                targetDid: try DID(didString: memberDid),
                reason: reason,
                details: details
            )

            logger.info("✅ [MLSConversationManager.reportMember] SUCCESS - reportId: \(reportId)")
            return reportId

        } catch {
            logger.error("❌ [MLSConversationManager.reportMember] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    /// Load moderation reports for a conversation (admin-only)
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - limit: Maximum number of reports to return
    ///   - cursor: Pagination cursor
    /// - Returns: Tuple of reports and optional next cursor
    func loadReports(for convoId: String, limit: Int = 50, cursor: String? = nil) async throws -> (reports: [BlueCatbirdMlsGetReports.ReportView], cursor: String?) {
        logger.info("🔵 [MLSConversationManager.loadReports] START - convoId: \(convoId)")

        guard conversations[convoId] != nil else {
            logger.error("❌ [MLSConversationManager.loadReports] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        do {
            let (reports, nextCursor) = try await apiClient.getReports(
                convoId: convoId,
                limit: limit,
                cursor: cursor
            )

            logger.info("✅ [MLSConversationManager.loadReports] SUCCESS - \(reports.count) reports")
            return (reports, nextCursor)

        } catch {
            logger.error("❌ [MLSConversationManager.loadReports] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    /// Resolve a moderation report (admin-only)
    /// - Parameters:
    ///   - reportId: Report identifier
    ///   - action: Action taken (e.g., "removed", "warned", "dismissed")
    ///   - notes: Optional notes about the resolution
    func resolveReport(_ reportId: String, action: String, notes: String? = nil) async throws {
        logger.info("🔵 [MLSConversationManager.resolveReport] START - reportId: \(reportId), action: \(action)")

        do {
            let ok = try await apiClient.resolveReport(
                reportId: reportId,
                action: action,
                notes: notes
            )

            guard ok else {
                throw MLSConversationError.serverError(NSError(domain: "MLSConversationManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned failure for resolveReport"]))
            }

            logger.info("✅ [MLSConversationManager.resolveReport] SUCCESS")

        } catch {
            logger.error("❌ [MLSConversationManager.resolveReport] Failed: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }

    // MARK: - Encryption/Decryption
    
    /// Encrypt and send a message to a conversation
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - plaintext: Plain text message to encrypt
    ///   - embed: Optional structured embed data (record, link, or GIF)
    /// - Returns: Sent message with messageId and timestamp
    func sendMessage(
        convoId: String,
        plaintext: String,
        embed: MLSEmbedData? = nil
    ) async throws -> (messageId: String, receivedAt: ATProtocolDate) {
        logger.info("🔵 [MLSConversationManager.sendMessage] START - convoId: \(convoId), text: \(plaintext.count) chars, embed: \(embed != nil ? "yes" : "no")")
        let startTotal = Date()

        guard let convo = conversations[convoId] else {
            logger.error("❌ [MLSConversationManager.sendMessage] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }

        // CRITICAL FIX: Verify conversation is fully initialized before sending
        if let state = conversationStates[convoId] {
            switch state {
            case .initializing:
                logger.warning("⚠️ [MLSConversationManager.sendMessage] Conversation still initializing - blocking message")
                throw MLSConversationError.conversationNotReady
            case .failed(let reason):
                logger.error("❌ [MLSConversationManager.sendMessage] Conversation initialization failed: \(reason)")
                throw MLSConversationError.conversationNotReady
            case .active:
                // Good to proceed
                break
            }
        }
        // If no state tracked, assume it's an older conversation that's already active

        // Create structured message payload
        let payload = MLSMessagePayload(text: plaintext, embed: embed)

        // Encode payload to JSON
        guard let plaintextData = try? payload.encodeToJSON() else {
            logger.error("❌ [MLSConversationManager.sendMessage] Failed to encode message payload")
            throw MLSConversationError.invalidMessage
        }
        
        guard let userDid = userDid, let did = try? DID(didString: userDid) else {
            logger.error("❌ [MLSConversationManager.sendMessage] No authentication")
            throw MLSConversationError.noAuthentication
        }
        
        // Sync group state before sending to ensure we're at the correct epoch
        let syncStart = Date()
        logger.debug("📍 [MLSConversationManager.sendMessage] Syncing group state...")
        do {
            try await syncGroupState(for: convoId)
            let syncMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            logger.info("✅ [MLSConversationManager.sendMessage] Group synced in \(syncMs)ms")
        } catch {
            let syncMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            logger.warning("⚠️ [MLSConversationManager.sendMessage] Sync failed after \(syncMs)ms: \(error.localizedDescription)")
        }
        
        // Refresh conversation to get updated epoch after sync
        let currentConvo = conversations[convoId] ?? convo
        logger.debug("📍 [MLSConversationManager.sendMessage] Current epoch: \(currentConvo.epoch)")
        
        // Ensure MLS group is initialized before encrypting
        guard let groupIdData = Data(hexEncoded: currentConvo.groupId) else {
            logger.error("❌ [MLSConversationManager.sendMessage] Invalid groupId")
            throw MLSConversationError.invalidGroupId
        }
        
        // Check if group exists locally via FFI
        // Run blocking FFI call on background thread to avoid priority inversion
        let groupExists = await Task(priority: .background) {
            mlsClient.groupExists(for: userDid, groupId: groupIdData)
        }.value
        logger.debug("📍 [MLSConversationManager.sendMessage] Group exists locally: \(groupExists)")
        
        if !groupExists {
            // Group doesn't exist locally - need to initialize it
            logger.warning("⚠️ [MLSConversationManager.sendMessage] Group not found locally")
            
            // Check if we are the creator - if so, we might have created it on another device
            let isCreator = currentConvo.creator.description == userDid
            
            if isCreator {
                // We created this group but don't have it locally (e.g., created on different device)
                logger.error("❌ [MLSConversationManager.sendMessage] Creator missing group - cannot reconstruct creator's group without original state")
                throw MLSConversationError.groupNotInitialized
            }
            
            // We're a member - initialize from Welcome message
            logger.info("📍 [MLSConversationManager.sendMessage] Initializing from Welcome as member...")
            do {
                try await initializeGroupFromWelcome(convo: currentConvo)
                logger.info("✅ [MLSConversationManager.sendMessage] Group initialized successfully")
            } catch {
                logger.error("❌ [MLSConversationManager.sendMessage] Failed to initialize group: \(error.localizedDescription)")
                throw MLSConversationError.invalidWelcomeMessage
            }
        }
        
        // Generate stable idempotency key for this logical send operation
        // Use hash of conversation + plaintext + timestamp to ensure uniqueness while allowing retries
        let idempotencyKey = generateIdempotencyKey(convoId: convoId, plaintext: plaintextData)
        
        // Check if we've recently sent this exact message (prevent double-sends)
        if isRecentlySent(convoId: convoId, idempotencyKey: idempotencyKey) {
            logger.warning("⚠️ [MLSConversationManager.sendMessage] Duplicate send detected (same idempotency key within \(Int(self.deduplicationWindow))s) - ignoring")
            throw MLSConversationError.duplicateSend
        }
        
        // Mark as in-flight
        trackSentMessage(convoId: convoId, idempotencyKey: idempotencyKey)
        
        // Encrypt message locally
        let encryptStart = Date()
        logger.debug("📍 [MLSConversationManager.sendMessage] Encrypting message...")
        let ciphertext = try await encryptMessage(groupId: currentConvo.groupId, plaintext: plaintextData)
        let encryptMs = Int(Date().timeIntervalSince(encryptStart) * 1000)
        logger.info("✅ [MLSConversationManager.sendMessage] Encrypted in \(encryptMs)ms - ciphertext: \(ciphertext.count) bytes")
        
        // Send encrypted message directly to server with idempotency key
        do {
            let apiStart = Date()
            logger.debug("📍 [MLSConversationManager.sendMessage] Sending to server with idempotencyKey: \(idempotencyKey)...")

            // Generate a message ID for this send operation
            let msgId = UUID().uuidString

            // Apply padding to match bucket size requirements (min 512 bytes)
            // Server requires paddedSize to be one of: 512, 1024, 2048, 4096, 8192, or multiples of 8192
            // IMPORTANT: The actual ciphertext size is NOT sent to the server (privacy!)
            // Recipients will find the actual size encrypted inside the MLS ciphertext to strip padding
            logger.debug("📍 [MLSConversationManager.sendMessage] Applying padding to ciphertext (\(ciphertext.count) bytes)...")
            let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(ciphertext)
            logger.debug("📍 [MLSConversationManager.sendMessage] Padded to bucket size: \(paddedSize) bytes (actual size hidden for privacy)")

            let (messageId, receivedAt, seq, confirmedEpoch) = try await apiClient.sendMessage(
                convoId: convoId,
                msgId: msgId,
                ciphertext: paddedCiphertext,
                epoch: currentConvo.epoch,
                paddedSize: paddedSize,
                senderDid: did,
                idempotencyKey: idempotencyKey
            )

            // CRITICAL FIX: Cache plaintext and embed for own messages to prevent self-decryption attempts
            // When the server broadcasts this message back, we'll use the cached plaintext/embed
            // instead of trying to decrypt (which is impossible by MLS design)
            // Server now returns real seq immediately - no more placeholder seq=0!
            logger.debug("📍 [MLSConversationManager.sendMessage] Caching plaintext and embed for message \(messageId) with real seq=\(seq)...")
            do {
                try await storage.savePlaintextForMessage(
                    messageID: messageId,
                    conversationID: convoId,
                    plaintext: plaintext,  // Store the original plaintext
                    senderID: userDid,
                    currentUserDID: userDid,
                    embed: embed,  // Store the embed data if present
                    epoch: Int64(confirmedEpoch),  // Confirmed MLS epoch from server
                    sequenceNumber: Int64(seq),  // Real server-assigned sequence number
                    timestamp: receivedAt.date,  // Server timestamp
                    database: database
                )
                logger.info("✅ [MLSConversationManager.sendMessage] Plaintext and embed cached for message \(messageId) with seq=\(seq), epoch=\(confirmedEpoch)")
            } catch {
                logger.warning("⚠️ [MLSConversationManager.sendMessage] Failed to cache plaintext/embed: \(error.localizedDescription)")
                // Don't fail the send operation if caching fails
            }

            // Notify observers
            notifyObservers(.messageSent(messageId, receivedAt))

            let apiMs = Int(Date().timeIntervalSince(apiStart) * 1000)
            let totalMs = Int(Date().timeIntervalSince(startTotal) * 1000)
            logger.info("✅ [MLSConversationManager.sendMessage] COMPLETE - msgId: \(messageId), api: \(apiMs)ms, total: \(totalMs)ms")
            return (messageId, receivedAt)

        } catch {
            let totalMs = Int(Date().timeIntervalSince(startTotal) * 1000)
            logger.error("❌ [MLSConversationManager.sendMessage] Server send failed after \(totalMs)ms: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }
    
    /// Decrypt a received message
    /// - Parameter message: Encrypted message view
    /// - Returns: Decrypted message payload with text and optional embed
    func decryptMessage(_ message: BlueCatbirdMlsDefs.MessageView) async throws -> DecryptedMLSMessage {
        logger.debug("Decrypting message: \(message.id)")

        guard let convo = conversations[message.convoId] else {
            throw MLSConversationError.conversationNotFound
        }

        guard let userDid = userDid else {
            throw MLSError.operationFailed
        }

        // 🔒 CRITICAL: Check cache BEFORE attempting decryption
        // MLS forward secrecy means each message can only be decrypted ONCE per MLS state
        // Attempting to decrypt the same message twice → SecretReuseError
        // This enables:
        // 1. Multiple conversation loads without re-decryption
        // 2. Multi-user support (each user caches their own decrypted copy)
        // 3. Idempotent processMessagesInOrder() (safe to call multiple times)
        if let cachedPlaintext = try? await storage.fetchPlaintextForMessage(
            message.id,
            currentUserDID: userDid,
            database: database
        ),
           let cachedSenderDID = try? await storage.fetchSenderForMessage(
            message.id,
            currentUserDID: userDid,
            database: database
        ) {
            let cachedEmbed = try? await storage.fetchEmbedForMessage(
                message.id,
                currentUserDID: userDid,
                database: database
            )
            logger.debug("✅ Using cached plaintext for message \(message.id) (skipping decryption)")
            let payload = MLSMessagePayload(text: cachedPlaintext, embed: cachedEmbed)
            return DecryptedMLSMessage(messageView: message, payload: payload, senderDID: cachedSenderDID)
        }

        // Not cached - decrypt from server ciphertext
        logger.debug("📥 No cache found - decrypting message \(message.id) from server")

        // Get padded ciphertext from server (includes length prefix + padding)
        let paddedCiphertext = message.ciphertext.data

        // Strip padding to get actual MLS ciphertext
        // Server stores padded data for metadata privacy, but MLS needs the actual ciphertext
        logger.debug("🔓 Stripping padding from \(paddedCiphertext.count) bytes...")
        let ciphertextData = try MLSMessagePadding.removePadding(paddedCiphertext)
        logger.debug("✅ Unpadded to \(ciphertextData.count) bytes (actual MLS ciphertext)")

        // Decrypt message locally and extract sender from MLS credential
        let (plaintext, senderDID) = try await decryptMessageWithSender(groupId: convo.groupId, ciphertext: ciphertextData)

        // Decode JSON payload (no fallback - clean schema only)
        let payload = try MLSMessagePayload.decodeFromJSON(plaintext)

        logger.debug("Successfully decrypted message: \(message.id), sender: \(senderDID), hasEmbed: \(payload.embed != nil)")

        // 🚨 CRITICAL FIX: Cache plaintext for received messages
        // MLS has forward secrecy - messages can only be decrypted ONCE
        // We must save the plaintext immediately or it's lost forever
        logger.debug("💾 Caching plaintext for received message: \(message.id)")
        do {
            try await storage.savePlaintextForMessage(
                messageID: message.id,
                conversationID: message.convoId,
                plaintext: payload.text,
                senderID: senderDID,
                currentUserDID: userDid,
                embed: payload.embed,
                epoch: Int64(message.epoch),
                sequenceNumber: Int64(message.seq),
                timestamp: message.createdAt.date,
                database: database
            )
            logger.info("✅ Cached plaintext for received message: \(message.id) (epoch: \(message.epoch), seq: \(message.seq), sender: \(senderDID))")
        } catch {
            logger.error("🚨 CRITICAL: Failed to cache plaintext for message \(message.id): \(error.localizedDescription)")
            // Still return payload but log error for investigation
            // This is critical because without the cache, message will be unreadable on app restart
        }

        return DecryptedMLSMessage(messageView: message, payload: payload, senderDID: senderDID)
    }

    /// Process messages in sequential order
    /// - Parameters:
    ///   - messages: Messages to process (server guarantees (epoch, seq) ordering)
    ///   - conversationID: Conversation these messages belong to
    /// - Returns: Successfully processed message payloads
    /// - Note: Server now guarantees messages are pre-sorted by (epoch ASC, seq ASC).
    ///         No client-side sorting or buffering needed.
    func processMessagesInOrder(
        messages: [BlueCatbirdMlsDefs.MessageView],
        conversationID: String
    ) async throws -> [MLSMessagePayload] {
        logger.debug("📊 Processing \(messages.count) messages for conversation \(conversationID)")

        var processedPayloads: [MLSMessagePayload] = []

        // Server guarantees messages are already sorted by (epoch ASC, seq ASC)
        // Process sequentially in order received
        for message in messages {
            do {
                let decryptedMessage = try await decryptMessage(message)
                processedPayloads.append(decryptedMessage.payload)
                logger.debug("✅ Processed message \(message.id) (epoch: \(message.epoch), seq: \(message.seq))")
            } catch {
                // Check if this is an epoch mismatch (forward secrecy preventing old message decryption)
                let errorMessage = error.localizedDescription
                if errorMessage.contains("epoch") && errorMessage.contains("forward secrecy") {
                    logger.warning("⏭️ Skipping message \(message.id) from old epoch \(message.epoch) - cannot decrypt due to MLS forward secrecy")
                } else {
                    logger.error("❌ Failed to process message \(message.id): \(errorMessage)")
                }
                // Continue processing other messages even if one fails
                // MLS state should still advance for successfully decrypted messages
            }
        }

        logger.info("✅ Processed \(processedPayloads.count)/\(messages.count) messages")
        return processedPayloads
    }

    // MARK: - Server Synchronization
    
    /// Sync conversations with server
    /// - Parameter fullSync: Whether to perform full sync or incremental
    func syncWithServer(fullSync: Bool = false) async throws {
        guard !isSyncing else {
            logger.warning("Sync already in progress")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        logger.info("Starting server sync (full: \(fullSync))")
        
        do {
            // Fetch conversations from server
            var allConvos: [BlueCatbirdMlsDefs.ConvoView] = []
            var cursor: String?
            
            repeat {
                let result = try await apiClient.getConversations(limit: 100, cursor: cursor)
                allConvos.append(contentsOf: result.convos)
                cursor = result.cursor
            } while cursor != nil
            
            // Update local state and initialize MLS groups
            for convo in allConvos {
                let existingConvo = conversations[convo.groupId]
                conversations[convo.groupId] = convo

                // Check if we need to initialize the MLS group
                let needsGroupInit = groupStates[convo.groupId] == nil

                // Update group state metadata
                if groupStates[convo.groupId] == nil {
                    groupStates[convo.groupId] = MLSGroupState(
                        groupId: convo.groupId,
                        convoId: convo.groupId,
                        epoch: UInt64(convo.epoch),
                        members: Set(convo.members.map { $0.did.description })
                    )
                } else if var state = groupStates[convo.groupId] {
                    if state.epoch != convo.epoch {
                        state.epoch = UInt64(convo.epoch)
                        state.members = Set(convo.members.map { $0.did.description })
                        groupStates[convo.groupId] = state

                        // Notify epoch update
                        notifyObservers(.epochUpdated(convo.groupId, convo.epoch))
                    }
                }

                // Initialize MLS group if needed
                if needsGroupInit {
                    // Check if group exists locally via FFI
                    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
                        logger.error("Invalid group ID format for \(convo.groupId)")
                        continue
                    }

                    guard let userDid = userDid else {
                        logger.error("Cannot check group existence without user DID")
                        continue
                    }

                    // Run blocking FFI call on background thread to avoid priority inversion
                    // The Rust RwLock can cause priority inversion if called from main/UI thread
                    let groupExists = await Task(priority: .background) {
                        mlsClient.groupExists(for: userDid, groupId: groupIdData)
                    }.value

                    if !groupExists {
                        logger.info("Initializing MLS group for conversation: \(convo.groupId)")
                        do {
                            try await initializeGroupFromWelcome(convo: convo)
                            logger.info("Successfully initialized MLS group for conversation: \(convo.groupId)")
                        } catch {
                            logger.error("Failed to initialize MLS group for \(convo.groupId): \(error.localizedDescription)")
                            // Don't fail the entire sync - just log and continue
                        }
                    } else {
                        logger.debug("Group already exists locally for conversation: \(convo.groupId)")
                    }
                }

                // Notify if new conversation
                if existingConvo == nil {
                    notifyObservers(.conversationCreated(convo))
                }
            }

            // Persist conversations to local database
            try await persistConversationsToDatabase(allConvos)

            // Reconcile database: delete conversations that exist locally but not on server
            let serverConvoIDs = Set(allConvos.map { $0.groupId })
            try await reconcileDatabase(with: serverConvoIDs)

            // Notify sync complete
            notifyObservers(.syncCompleted(allConvos.count))

            logger.info("Successfully synced \(allConvos.count) conversations")
            
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            notifyObservers(.syncFailed(error))
            throw MLSConversationError.syncFailed(error)
        }
    }

    /// Persist conversations to local encrypted database
    /// - Parameter convos: Array of ConvoView objects to persist
    private func persistConversationsToDatabase(_ convos: [BlueCatbirdMlsDefs.ConvoView]) async throws {
        guard let userDid = userDid else {
            logger.error("Cannot persist conversations - no user DID")
            return
        }

        try await database.write { db in
            for convo in convos {
                // Convert group ID hex string to Data
                guard let groupIdData = Data(hexEncoded: convo.groupId) else {
                    self.logger.error("Invalid group ID format for conversation \(convo.groupId)")
                    continue
                }

                // Extract metadata for title
                let title = convo.metadata?.name

                // Create MLSConversationModel
                let model = MLSConversationModel(
                    conversationID: convo.groupId,
                    currentUserDID: userDid,
                    groupID: groupIdData,
                    epoch: Int64(convo.epoch),
                    title: title,
                    avatarURL: nil,
                    createdAt: convo.createdAt.date,
                    updatedAt: Date(),
                    lastMessageAt: convo.lastMessageAt?.date,
                    isActive: true
                )

                // Insert or update conversation in database
                try model.save(db)
            }
        }

        logger.info("💾 Persisted \(convos.count) conversations to encrypted database")
    }

    /// Reconcile local database with server state
    /// Deletes conversations that exist locally but not on server (removed/left conversations)
    /// - Parameter serverConvoIDs: Set of conversation IDs from server
    private func reconcileDatabase(with serverConvoIDs: Set<String>) async throws {
        guard let userDid = userDid else {
            logger.error("Cannot reconcile database - no user DID")
            return
        }

        // Get local conversation IDs from database
        let localConvoIDs = try await database.read { db in
            try MLSConversationModel
                .filter(MLSConversationModel.Columns.currentUserDID == userDid)
                .fetchAll(db)
                .map { $0.conversationID }
        }

        // Find conversations that exist locally but not on server (removed/left)
        let removedConvoIDs = Set(localConvoIDs).subtracting(serverConvoIDs)

        if !removedConvoIDs.isEmpty {
            logger.info("🗑️ Removing \(removedConvoIDs.count) conversations no longer on server: \(removedConvoIDs)")
            try await deleteConversationsFromDatabase(Array(removedConvoIDs))
        } else {
            logger.debug("Database reconciliation: no stale conversations to remove")
        }
    }

    /// Delete conversations from local database
    /// Also removes associated messages, members, and epoch keys
    /// - Parameter convoIds: Array of conversation IDs to delete
    private func deleteConversationsFromDatabase(_ convoIds: [String]) async throws {
        guard let userDID = userDid else { return }

        try await database.write { db in
            for convoId in convoIds {
                // Delete conversation record
                try db.execute(sql: """
                    DELETE FROM MLSConversationModel
                    WHERE conversationID = ? AND currentUserDID = ?;
                """, arguments: [convoId, userDID])

                // Delete associated messages
                try db.execute(sql: """
                    DELETE FROM MLSMessageModel
                    WHERE conversationID = ? AND currentUserDID = ?;
                """, arguments: [convoId, userDID])

                // Delete members
                try db.execute(sql: """
                    DELETE FROM MLSMemberModel
                    WHERE conversationID = ? AND currentUserDID = ?;
                """, arguments: [convoId, userDID])

                // Delete epoch keys
                try db.execute(sql: """
                    DELETE FROM MLSEpochKeyModel
                    WHERE conversationID = ? AND currentUserDID = ?;
                """, arguments: [convoId, userDID])

                logger.debug("Deleted conversation from database: \(convoId)")
            }
        }

        // Remove from in-memory state (after database transaction completes)
        for convoId in convoIds {
            // Capture group ID before removing conversation
            let groupId = conversations[convoId]?.groupId

            // Delete MLS group from OpenMLS storage
            if let groupIdHex = groupId, let groupIdData = Data(hexEncoded: groupIdHex) {
                do {
                    try await mlsClient.deleteGroup(for: userDID, groupId: groupIdData)
                    logger.info("✅ Deleted MLS group from storage: \(groupIdHex.prefix(16))...")
                } catch {
                    logger.warning("⚠️ Failed to delete MLS group \(groupIdHex.prefix(16))...: \(error.localizedDescription)")
                    // Continue anyway - group will be removed from memory state
                }
            }

            // Remove conversation
            conversations.removeValue(forKey: convoId)

            // Also remove group state if this was the only conversation using that group
            if let groupId = groupId {
                let groupStillInUse = conversations.values.contains(where: { $0.groupId == groupId })
                if !groupStillInUse {
                    groupStates.removeValue(forKey: groupId)
                    logger.debug("Removed group state for: \(groupId)")
                }
            }
        }

        logger.info("💾 Deleted \(convoIds.count) conversations from encrypted database")
    }

    /// Mark a conversation as needing rejoin after state loss
    /// This is called when we cannot initialize a group due to missing Welcome message
    /// - Parameter convoId: Conversation ID that needs rejoin
    private func markConversationNeedsRejoin(_ convoId: String) async throws {
        guard let userDID = userDid else {
            logger.error("Cannot mark conversation as needing rejoin - no user DID")
            return
        }

        try await database.write { db in
            try db.execute(sql: """
                UPDATE MLSConversationModel
                SET needsRejoin = 1, rejoinRequestedAt = NULL, updatedAt = ?
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [Date(), convoId, userDID])
        }

        logger.info("⚠️ Marked conversation as needing rejoin: \(convoId)")
    }

    // MARK: - Key Package Management
    
    /// Publish a new key package for the current user
    /// - Parameter expiresAt: Optional expiration date (defaults to 30 days)
    /// - Returns: Published key package reference
    @discardableResult
    func publishKeyPackage(expiresAt: Date? = nil) async throws -> BlueCatbirdMlsDefs.KeyPackageRef {
        logger.info("Publishing key package")
        
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        
        guard isInitialized else {
            throw MLSConversationError.contextNotInitialized
        }
        
        // Create key package locally
        // CRITICAL FIX: MLSClient.createKeyPackage() returns raw TLS-serialized KeyPackage bytes
        // (NOT base64-encoded - it's already extracted from KeyPackageResult by MLSClient)
        let keyPackageData = try await mlsClient.createKeyPackage(for: userDid, identity: userDid)

        logger.debug("📦 Key package created: \(keyPackageData.count) bytes (first 16: \(keyPackageData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")))")

        // Publish to server (returns empty response)
        do {
            // Server requires an explicit future expiration; default to 30 days if not provided
            let expiry = expiresAt ?? Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)

            // Send raw TLS bytes directly to server (no base64 encoding/decoding needed)
            try await apiClient.publishKeyPackage(
                keyPackage: keyPackageData,
                cipherSuite: defaultCipherSuite,
                expiresAt: ATProtocolDate(date: expiry)
            )
            
            // Create a local reference (server doesn't return the package)
            let didObj = try DID(didString: userDid)
            let keyPackageRef = BlueCatbirdMlsDefs.KeyPackageRef(
                did: didObj,
                keyPackage: keyPackageData.base64EncodedString(),
                keyPackageHash: nil,  // Server will compute and return this in getKeyPackages
                cipherSuite: defaultCipherSuite
            )
            
            logger.info("Successfully published key package for: \(userDid)")
            return keyPackageRef
            
        } catch {
            logger.error("Failed to publish key package: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }
    
    /// Smart key package refresh using monitor (preferred method)
    func smartRefreshKeyPackages() async throws {
        logger.debug("🔍 Checking if key package refresh is needed (smart monitoring)")

        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        // 🛡️ FIX: Minimum interval check (prevent too-frequent uploads)
        let minimumInterval: TimeInterval = 300 // 5 minutes
        if let lastRefresh = lastKeyPackageRefresh {
            let timeSinceLastRefresh = Date().timeIntervalSince(lastRefresh)
            if timeSinceLastRefresh < minimumInterval {
                logger.info("⏱️ Too soon since last refresh (\(Int(timeSinceLastRefresh))s ago), skipping (minimum: \(Int(minimumInterval))s)")
                return
            }
        }

        guard let monitor = keyPackageMonitor else {
            // Fallback to basic refresh if monitor not initialized
            logger.warning("⚠️ Monitor not initialized, using basic refresh")
            return try await refreshKeyPackagesBasic()
        }

        // Try to get server-side key package inventory
        do {
            let basicStats = try await apiClient.getKeyPackageStats()

            // Convert to enhanced stats (using only available fields from server)
            // Note: total and consumed fields don't exist in BlueCatbirdMlsGetKeyPackageStats.Output
            let stats = EnhancedKeyPackageStats(
                available: basicStats.available,
                threshold: basicStats.threshold,
                total: basicStats.available,  // Total not provided by server, use available as approximation
                consumed: 0,  // Consumed count not provided, use 0
                consumedLast24h: nil,
                consumedLast7d: nil,
                averageDailyConsumption: nil,
                predictedDepletionDays: nil,
                needsReplenish: basicStats.needsReplenish
            )

            logger.info("📊 Key package inventory: available=\(stats.available), threshold=\(stats.threshold), dynamic=\(stats.dynamicThreshold)")

            // Check if replenishment needed using smart logic
            let recommendation = try await monitor.getReplenishmentRecommendation(stats: stats)

            if recommendation.shouldReplenish {
                logger.warning("⚠️ Replenishment needed [\(recommendation.priority.rawValue)]: \(recommendation.reason)")

                // Upload using recommended batch size
                try await uploadKeyPackageBatchSmart(count: recommendation.recommendedBatchSize)
                lastKeyPackageRefresh = Date()
            } else {
                logger.debug("✅ Key packages are sufficient: \(stats.available) available")
            }
        } catch {
            // 🛡️ FIX: Don't upload blindly on error - uploadKeyPackageBatchSmart() now queries inventory first
            // If server is truly unavailable, the upload method will fail too (no blind uploads)
            logger.error("❌ Failed to check key package stats: \(error.localizedDescription)")
            logger.info("ℹ️ Skipping key package upload - server unavailable or error occurred")
            // Re-throw to let caller handle (e.g., exponential backoff, retry later)
            throw error
        }
    }

    /// Basic refresh without smart monitoring (fallback/legacy)
    func refreshKeyPackagesBasic() async throws {
        logger.debug("Checking if key package refresh is needed (basic mode)")

        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        // Try to check server-side key package inventory
        do {
            let stats = try await apiClient.getKeyPackageStats()

            logger.info("📊 Key package inventory: available=\(stats.available), threshold=\(stats.threshold)")

            // Replenish if below threshold or empty
            if stats.available < stats.threshold {
                logger.warning("⚠️ Key package count (\(stats.available)) below threshold (\(stats.threshold)) - replenishing...")
                let neededCount = max(100 - stats.available, 0)
                try await uploadKeyPackageBatchSmart(count: neededCount)
                lastKeyPackageRefresh = Date()
            } else {
                logger.debug("✅ Key packages are sufficient: \(stats.available) available")
            }
        } catch {
            // 🛡️ FIX: Don't upload blindly on error - uploadKeyPackageBatchSmart() now queries inventory first
            // If server is truly unavailable, the upload method will fail too (no blind uploads)
            logger.error("❌ Failed to check key package stats: \(error.localizedDescription)")
            logger.info("ℹ️ Skipping key package upload - server unavailable or error occurred")
            // Re-throw to let caller handle (e.g., exponential backoff, retry later)
            throw error
        }
    }

    /// Legacy method for backward compatibility
    func refreshKeyPackagesIfNeeded() async throws {
        try await smartRefreshKeyPackages()
    }

    /// Smart batch upload using batch API (preferred method)
    /// Now includes server inventory check BEFORE generating packages
    func uploadKeyPackageBatchSmart(count: Int = 100) async throws {
        logger.info("🔄 Starting smart key package upload (requested count: \(count))...")

        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        // STEP 0: Ensure device is registered and get credential DID
        let credentialDid = try await mlsClient.ensureDeviceRegistered()
        logger.info("📱 Device registered with credentialDid: \(credentialDid)")

        // Get device info for key package upload
        let deviceInfo = await mlsClient.getDeviceInfo()

        // STEP 1: Query current server inventory BEFORE generating packages
        let (serverAvailable, serverThreshold) = try await apiClient.queryKeyPackageInventory()
        logger.info("📊 Server inventory: \(serverAvailable) available, threshold: \(serverThreshold)")

        // STEP 2: Calculate actual need
        let targetInventory = serverThreshold + 10 // Small buffer above threshold
        let actualNeed = max(0, targetInventory - serverAvailable)

        // STEP 3: Early exit if server has plenty
        if actualNeed == 0 {
            logger.info("✅ Server inventory sufficient (\(serverAvailable) packages >= target \(targetInventory)), skipping upload")
            return
        }

        // STEP 4: Cap at API batch limit (100 packages max)
        let uploadCount = min(actualNeed, 100)
        logger.info("📦 Will upload \(uploadCount) packages (need: \(actualNeed), cap: 100)")

        // STEP 5: Generate only the packages we actually need using credentialDid
        let expiresAt = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60) // 30 days
        var packages: [MLSKeyPackageUploadData] = []
        for _ in 0..<uploadCount {
            // Use credentialDid as the identity for key package creation
            let keyPackageBytes = try await mlsClient.createKeyPackage(for: userDid, identity: credentialDid)
            let keyPackageBase64 = keyPackageBytes.base64EncodedString()

            let packageData = MLSKeyPackageUploadData(
                keyPackage: keyPackageBase64,
                cipherSuite: defaultCipherSuite,
                expires: expiresAt,
                idempotencyKey: UUID().uuidString.lowercased(),
                deviceId: deviceInfo?.deviceId,
                credentialDid: credentialDid
            )

            packages.append(packageData)
        }

        // STEP 6: Upload using batch API
        let result = try await apiClient.publishKeyPackagesBatch(packages)

        logger.info("✅ Batch upload complete: \(result.succeeded) succeeded, \(result.failed) failed")

        if result.failed > 0 {
            logger.warning("⚠️ \(result.failed) key packages failed to upload")

            if let errors = result.errors {
                for error in errors.prefix(5) {  // Log first 5 errors
                    logger.error("  Package #\(error.index): \(error.error)")
                }
            }
        }

        // Track successful uploads if monitor is available
        if let monitor = keyPackageMonitor, result.succeeded > 0 {
            // Note: We don't track uploads as consumption - only track when they're actually consumed
            logger.debug("📊 Uploaded \(result.succeeded) packages (not tracking as consumption)")
        }
    }

    /// Legacy batch upload method for backward compatibility
    func uploadKeyPackageBatch(count: Int = 100) async throws {
        try await uploadKeyPackageBatchSmart(count: count)
    }
    
    /// Refresh key packages based on time interval
    private func refreshKeyPackagesBasedOnInterval() async throws {
        logger.debug("Checking if key package refresh is needed based on interval")
        
        // Check if enough time has passed since last refresh
        if let lastRefresh = lastKeyPackageRefresh {
            let timeSinceLastRefresh = Date().timeIntervalSince(lastRefresh)
            if timeSinceLastRefresh < keyPackageRefreshInterval {
                logger.debug("Key packages were refreshed \(Int(timeSinceLastRefresh))s ago, skipping (interval: \(Int(self.keyPackageRefreshInterval))s)")
                return
            }
        }
        
        // Refresh needed
        logger.info("Refreshing key packages based on interval")
        try await refreshKeyPackagesIfNeeded()
        lastKeyPackageRefresh = Date()
    }
    
    // MARK: - Epoch Management
    
    /// Get current epoch for a conversation
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Current epoch number
    func getEpoch(convoId: String) throws -> UInt64 {
        guard let convo = conversations[convoId] else {
            throw MLSConversationError.conversationNotFound
        }
        
        return UInt64(convo.epoch)
    }
    
    /// Handle epoch update from server
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - newEpoch: New epoch number
    func handleEpochUpdate(convoId: String, newEpoch: UInt64) {
        logger.info("Handling epoch update for conversation: \(convoId), new epoch: \(newEpoch)")
        
        let epochInt = Int(clamping: newEpoch)
        
        guard var convo = conversations[convoId] else {
            logger.warning("Conversation not found for epoch update: \(convoId)")
            return
        }
        
        // Update conversation epoch
        let updatedConvo = BlueCatbirdMlsDefs.ConvoView(
            groupId: convo.groupId,
            creator: convo.creator,
            members: convo.members,
            epoch: epochInt,
            cipherSuite: convo.cipherSuite,
            createdAt: convo.createdAt,
            lastMessageAt: convo.lastMessageAt,
            metadata: convo.metadata
        )
        conversations[convoId] = updatedConvo
        
        // Update group state
        if var state = groupStates[convo.groupId] {
            state.epoch = newEpoch
            groupStates[convo.groupId] = state
        }
        
        // Notify observers
        notifyObservers(.epochUpdated(convoId, epochInt))
    }
    
    /// Synchronize group state by fetching and processing missing commits
    /// - Parameter convoId: Conversation identifier
    /// - Throws: MLSConversationError if sync fails
    func syncGroupState(for convoId: String) async throws {
        logger.info("Syncing group state for conversation: \(convoId)")
        
        guard let convo = conversations[convoId] else {
            throw MLSConversationError.conversationNotFound
        }
        
        // Get local epoch (current conversation state)
        let localEpoch = convo.epoch
        
        // Fetch server epoch
        let serverEpoch: Int
        do {
            serverEpoch = try await apiClient.getEpoch(convoId: convoId)
            logger.debug("Server epoch: \(serverEpoch), Local epoch: \(localEpoch)")
        } catch {
            logger.error("Failed to fetch server epoch: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
        
        // Check if we're behind
        guard localEpoch < serverEpoch else {
            logger.debug("Already at latest epoch (\(localEpoch)), no sync needed")
            return
        }
        
        logger.info("Behind server epoch: local=\(localEpoch), server=\(serverEpoch), fetching \(serverEpoch - localEpoch) commits")
        
        // Fetch missing commits
        let commits: [BlueCatbirdMlsGetCommits.CommitMessage]
        do {
            commits = try await apiClient.getCommits(
                convoId: convoId,
                fromEpoch: localEpoch + 1,
                toEpoch: serverEpoch
            )
            logger.debug("Fetched \(commits.count) commits to process")
        } catch {
            logger.error("Failed to fetch commits: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
        
        // Process each commit through OpenMLS
        for commit in commits {
            do {
                logger.debug("Processing commit for epoch \(commit.epoch)")
                
                // Get commit ciphertext data
                let commitData = commit.commitData.data
                
                // Process commit through MLS crypto layer
                // This will update the group state internally
                try await processCommit(groupId: convo.groupId, commitData: commitData)
                
                logger.debug("Successfully processed commit for epoch \(commit.epoch)")
            } catch {
                logger.error("Failed to process commit for epoch \(commit.epoch): \(error.localizedDescription)")
                throw MLSConversationError.commitProcessingFailed(commit.epoch, error)
            }
        }
        
        // Update local epoch to match server
        let serverEpochUInt = UInt64(serverEpoch)
        handleEpochUpdate(convoId: convoId, newEpoch: serverEpochUInt)

        logger.info("Successfully synced group state to epoch \(serverEpochUInt)")
    }
    
    /// Process a commit message through OpenMLS
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - commitData: Raw commit message data
    private func processCommit(groupId: String, commitData: Data) async throws {
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        // Convert hex-encoded groupId to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }
        
        // Process commit through MLS client
        let result = try await mlsClient.processCommit(for: userDid, groupId: groupIdData, commitData: commitData)
        logger.info("Processed commit: new epoch \(result.newEpoch)")
        let epochInt = Int(clamping: result.newEpoch)

        // Update local group state with new epoch
        if var state = groupStates[groupId] {
            state.epoch = result.newEpoch
            groupStates[groupId] = state

            // Persist epoch to keychain
            do {
                try MLSKeychainManager.shared.storeCurrentEpoch(epochInt, forConversationID: state.convoId)
                logger.debug("Persisted epoch \(epochInt) to keychain for conversation \(state.convoId)")
            } catch {
                logger.error("Failed to persist epoch to keychain: \(error)")
            }

            // Record new epoch in storage for cleanup tracking
            do {
                try await storage.recordEpochKey(
                  conversationID: state.convoId,
                  epoch: Int64(epochInt),
                  database: database
                )
                logger.debug("Recorded epoch key for cleanup tracking")

                // Clean up old epoch keys based on retention policy
                try await storage.deleteOldEpochKeys(
                  conversationID: state.convoId,
                  keepLast: configuration.maxPastEpochs,
                  database: database
                )
                logger.debug("Cleaned up old epoch keys (keeping last \(self.configuration.maxPastEpochs))")
            } catch {
                logger.error("Failed to cleanup old epoch keys: \(error)")
            }

            // Persist MLS state after epoch change (critical for forward secrecy)
            do {
                try await mlsClient.saveStorage(for: userDid)
                logger.debug("✅ Persisted MLS state after epoch \(epochInt)")
            } catch {
                logger.error("⚠️ Failed to persist MLS state after commit: \(error.localizedDescription)")
            }

            // Notify observers of epoch update
            notifyObservers(.epochUpdated(state.convoId, epochInt))
            logger.debug("Updated local epoch for group \(groupId.prefix(8))... to \(result.newEpoch)")
        } else {
            logger.warning("No local group state found for group \(groupId.prefix(8))... after processing commit")
        }
    }
    
    // MARK: - Background Cleanup

    /// Start background cleanup task for old key material
    private func startBackgroundCleanup() {
        cleanupTask?.cancel()

        cleanupTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(self.configuration.cleanupInterval))

                    guard !Task.isCancelled else { break }

                    await self.performBackgroundCleanup()
                } catch {
                    if error is CancellationError {
                        self.logger.info("Background cleanup task cancelled")
                        break
                    }
                    self.logger.error("Background cleanup error: \(error)")
                }
            }
        }

        logger.info("Started background cleanup task (interval: \(self.configuration.cleanupInterval)s)")
    }

    /// Perform cleanup of old key material
    private func performBackgroundCleanup() async {
        logger.debug("Running background cleanup")

        do {
            // Clean up message keys older than retention threshold
            let threshold = configuration.messageKeyCleanupThreshold
            try await storage.cleanupMessageKeys(olderThan: threshold, database: database)
            logger.debug("Cleaned up message keys older than \(threshold)")

            // Permanently delete marked epoch keys
            try await storage.deleteMarkedEpochKeys(database: database)
            logger.debug("Permanently deleted marked epoch keys")

            // Clean up expired key packages
            try await storage.deleteExpiredKeyPackages(database: database)
            logger.debug("Deleted expired key packages")
            
            // Refresh key packages if needed
            try await refreshKeyPackagesBasedOnInterval()

            logger.info("Background cleanup completed successfully")
        } catch {
            logger.error("Background cleanup failed: \(error)")
        }
    }

    // MARK: - Observer Pattern

    /// Add a state change observer
    /// - Parameter observer: Observer to add
    func addObserver(_ observer: MLSStateObserver) {
        observers.append(observer)
        logger.debug("Added state observer")
    }
    
    /// Remove a state change observer
    /// - Parameter observer: Observer to remove
    func removeObserver(_ observer: MLSStateObserver) {
        observers.removeAll { $0.id == observer.id }
        logger.debug("Removed state observer")
    }
    
    /// Notify all observers of a state change
    private func notifyObservers(_ event: MLSStateEvent) {
        logger.debug("Notifying observers of event: \(event.description)")
        for observer in observers {
            observer.onStateChange(event)
        }
    }
    
    // MARK: - MLS Crypto Operations (using MLSClient)
    
    /// Encrypt message using MLSClient
    private func encryptMessage(groupId: String, plaintext: Data) async throws -> Data {
        logger.debug("encryptMessage called: groupId=\(groupId.prefix(20))..., plaintext.count=\(plaintext.count)")
        
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        // groupId is hex-encoded, convert to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            logger.error("Failed to decode hex groupId: \(groupId.prefix(20))...")
            throw MLSConversationError.invalidGroupId
        }
        
        logger.debug("Calling mlsClient.encryptMessage with groupIdData.count=\(groupIdData.count)")
        let encryptResult = try await mlsClient.encryptMessage(for: userDid, groupId: groupIdData, plaintext: plaintext)
        logger.debug("mlsClient.encryptMessage succeeded, ciphertext.count=\(encryptResult.ciphertext.count)")
        
        // Persist MLS state after encryption (sender ratchet advanced)
        do {
            try await mlsClient.saveStorage(for: userDid)
            logger.debug("✅ Persisted MLS state after message encryption")
        } catch {
            logger.error("⚠️ Failed to persist MLS state after encryption: \(error.localizedDescription)")
        }
        
        return encryptResult.ciphertext
    }
    
    /// Decrypt message using MLSClient with processMessage flow
    private func decryptMessage(groupId: String, ciphertext: Data) async throws -> Data {
        logger.info("Decrypting message for group \(groupId.prefix(8))...")

        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        guard let groupIdData = Data(hexEncoded: groupId) else {
            logger.error("Invalid group ID format")
            throw MLSConversationError.invalidGroupId
        }

        let ciphertextData = ciphertext

        do {
            // Use processMessage instead of decryptMessage to get content type
            let processedContent = try await mlsClient.processMessage(
                for: userDid,
                groupId: groupIdData,
                messageData: ciphertextData
            )

            // CRITICAL FIX: Persist MLS state after decryption (receiver ratchet advanced)
            // This prevents SecretReuseError when trying to decrypt subsequent messages
            do {
                try await mlsClient.saveStorage(for: userDid)
                logger.debug("✅ Persisted MLS state after message decryption")
            } catch {
                logger.error("⚠️ Failed to persist MLS state after decryption: \(error.localizedDescription)")
                // Don't fail the decryption - state loss is recoverable via resync
            }

            // Handle different message types
            switch processedContent {
            case .applicationMessage(let plaintext, _):
                // Normal application message - return decrypted content (sender ignored here)
                logger.info("Decrypted application message (\(plaintext.count) bytes)")
                return plaintext

            case .proposal(let proposal, let proposalRef):
                // Received a proposal - validate and queue it
                logger.info("Received proposal, validating...")
                try await handleProposal(groupId: groupId, proposal: proposal, proposalRef: proposalRef)

                // Return empty data for proposals (no plaintext content)
                return Data()

            case .stagedCommit(let newEpoch):
                // Received a commit - validate before merging
                logger.info("Received commit for epoch \(newEpoch), validating...")
                try await validateAndMergeStagedCommit(groupId: groupId, newEpoch: newEpoch)

                // Return empty data for commits (no plaintext content)
                return Data()
            }
        } catch let error as MlsError {
            logger.error("Message processing failed: \(error.localizedDescription)")
            throw MLSConversationError.decryptionFailed
        } catch {
            logger.error("Unexpected error during message processing: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Process Welcome message using MLSClient
    private func processWelcome(welcomeData: Data, identity: String) async throws -> String {
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        do {
            let groupId = try await mlsClient.joinGroup(for: userDid, welcome: welcomeData, identity: identity, configuration: configuration.groupConfiguration)

            // Persist MLS state after joining group (new group created)
            do {
                try await mlsClient.saveStorage(for: userDid)
                logger.debug("✅ Persisted MLS state after joining group")
            } catch {
                logger.error("⚠️ Failed to persist MLS state after join: \(error.localizedDescription)")
            }

            return groupId.hexEncodedString()
        } catch let error as MlsError {
            // Handle key package desync (app reinstall, database loss, etc.)
            if case .KeyPackageDesyncDetected(let message) = error {
                logger.warning("🔄 Key package desync detected: \(message)")
                logger.info("Attempting automated recovery via requestRejoin...")

                // Extract conversation ID from the error message if possible
                // The Rust FFI should include conversation ID in the message
                try await handleKeyPackageDesyncRecovery(errorMessage: message, userDid: userDid)

                // After recovery, the conversation should be marked for rejoin
                // The server will re-add this device once an admin approves the rejoin request
                throw MLSConversationError.keyPackageDesyncRecoveryInitiated
            }

            // Re-throw other MlsErrors
            throw error
        }
    }

    /// Handle key package desync recovery by requesting rejoin
    /// - Parameters:
    ///   - errorMessage: Error message from FFI containing conversation details
    ///   - userDid: User DID for key package generation
    private func handleKeyPackageDesyncRecovery(errorMessage: String, userDid: String) async throws {
        logger.info("📦 Generating fresh key package for recovery...")

        // Generate a fresh key package
        let keyPackageData = try await mlsClient.createKeyPackage(for: userDid, identity: userDid)

        // Extract conversation ID from error message
        // The Rust FFI formats the message as: "No key package bundles available..." or includes convo_id
        // For now, we'll need the caller to provide the conversation ID explicitly
        // This is a limitation - we'll improve this in the next iteration

        logger.warning("⚠️ Cannot automatically extract conversation ID from desync error")
        logger.info("User will need to manually rejoin the conversation via UI")

        // Store the recovery key package for later use
        // When user taps "Rejoin" in UI, we'll call requestRejoin with this key package
        // For now, we just log and throw - the UI layer will handle the recovery flow
    }

    /// Ensure MLS group is initialized for a conversation
    /// This should be called when opening a conversation to ensure the user can send/receive messages
    /// - Parameter convoId: Conversation ID to initialize
    func ensureGroupInitialized(for convoId: String) async throws {
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        guard let convo = conversations[convoId] else {
            logger.warning("Cannot initialize group: conversation \(convoId) not found")
            throw MLSConversationError.conversationNotFound
        }

        guard let groupIdData = Data(hexEncoded: convo.groupId) else {
            logger.error("Invalid groupId for conversation \(convoId)")
            throw MLSConversationError.invalidGroupId
        }

        // Check if group already exists locally
        if mlsClient.groupExists(for: userDid, groupId: groupIdData) {
            logger.debug("Group already exists locally for conversation \(convoId)")
            return
        }

        // Group doesn't exist, initialize from Welcome message
        logger.info("Group not found locally, initializing from Welcome for conversation \(convoId)")
        try await initializeGroupFromWelcome(convo: convo)
    }

    /// Initialize a group from a Welcome message fetched from the server
    /// - Parameter convo: The conversation to initialize
    private func initializeGroupFromWelcome(convo: BlueCatbirdMlsDefs.ConvoView) async throws {
        logger.debug("Fetching Welcome message for conversation \(convo.groupId)")

        // Fetch Welcome message from server (returns Data directly, already decoded from base64)
        let welcomeData = try await apiClient.getWelcome(convoId: convo.groupId)
        logger.debug("Received Welcome message: \(welcomeData.count) bytes")

        // Process Welcome message to join the group
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        do {
            let groupId = try await mlsClient.joinGroup(
                for: userDid,
                welcome: welcomeData,
                identity: userDid,
                configuration: configuration.groupConfiguration
            )

            // Persist MLS state after joining group
            do {
                try await mlsClient.saveStorage(for: userDid)
                logger.info("✅ Persisted MLS state after joining group via Welcome")
            } catch {
                logger.error("⚠️ Failed to persist MLS state after join: \(error.localizedDescription)")
            }

            // Update local group state with correct epoch
            if var state = groupStates[convo.groupId] {
                state.epoch = UInt64(convo.epoch)
                groupStates[convo.groupId] = state
                logger.debug("Updated group epoch to \(convo.epoch) for conversation \(convo.groupId)")
            }

            logger.info("Successfully initialized group from Welcome for conversation \(convo.groupId)")
        } catch let error as MlsError {
            // Handle key package desync (app reinstall, database loss, etc.)
            if case .KeyPackageDesyncDetected(let message) = error {
                logger.warning("🔄 Key package desync detected for \(convo.groupId): \(message)")
                logger.info("Initiating recovery flow for conversation \(convo.groupId)...")

                // Generate fresh key package and request rejoin
                try await handleKeyPackageDesyncRecovery(errorMessage: message, userDid: userDid)

                // Throw specific error so UI can show rejoin option
                throw MLSConversationError.keyPackageDesyncRecoveryInitiated
            }

            // Re-throw other MlsErrors
            throw error
        }
    }

    // MARK: - Proposal and Commit Handling

    /// Handle a received proposal
    private func handleProposal(groupId: String, proposal: Any, proposalRef: ProposalRef) async throws {
        logger.info("Handling proposal for group \(groupId.prefix(8))...")

        // Convert hex-encoded groupId to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }

        // Validate and store the proposal
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        try await mlsClient.storeProposal(for: userDid, groupId: groupIdData, proposalRef: proposalRef)
        logger.info("Proposal stored successfully")
    }
    
    /// Validate and merge a staged commit
    private func validateAndMergeStagedCommit(groupId: String, newEpoch: UInt64) async throws {
        logger.info("Validating and merging staged commit for group \(groupId.prefix(8))...")
        
        // Convert hex-encoded groupId to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }
        
        // Merge the staged commit
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        let mergedEpoch = try await mlsClient.mergeStagedCommit(for: userDid, groupId: groupIdData)
        
        if mergedEpoch != newEpoch {
            logger.warning("Epoch mismatch after merging staged commit: local=\(mergedEpoch), expected=\(newEpoch)")
        }
        
        logger.info("Staged commit merged, new epoch: \(mergedEpoch)")
    }

    // MARK: - Private Helpers

    /// Mark a key package hash as exhausted for a specific DID
    private func markKeyPackageHashExhausted(hash: String, for did: String) {
        var exhausted = exhaustedKeyPackageHashes[did, default: []]
        exhausted.insert(hash)
        exhaustedKeyPackageHashes[did] = exhausted
        logger.debug("📛 Marked key package hash exhausted for \(did): \(hash.prefix(16))...")
    }

    /// Check whether a given key package hash has already been marked as exhausted for the DID
    private func isKeyPackageHashExhausted(_ hash: String, for did: String) -> Bool {
        exhaustedKeyPackageHashes[did]?.contains(hash) ?? false
    }

    /// Reserve selected key packages to prevent reuse before the server processes them
    private func reserveKeyPackages(_ packages: [KeyPackageWithHash]) {
        for package in packages {
            markKeyPackageHashExhausted(hash: package.hash, for: package.did.description)
        }
    }

    /// Parse server error detail and record the exhausted hash so future attempts skip it
    private func recordKeyPackageFailure(detail: String?) {
        guard let detail, let parsed = parseKeyPackageErrorDetail(detail) else { return }
        markKeyPackageHashExhausted(hash: parsed.hash, for: parsed.did)
        logger.warning("⚠️ Recorded unavailable key package hash for \(parsed.did): \(parsed.hash.prefix(16))...")
    }

    /// Extract DID/hash pair from the structured error detail string
    private func parseKeyPackageErrorDetail(_ detail: String) -> (did: String, hash: String)? {
        guard let hashRange = detail.range(of: "hash=") else { return nil }

        let hashToken = detail[hashRange.upperBound...]
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init)

        let didPrefix = detail[..<hashRange.lowerBound]
        guard let didRange = didPrefix.range(of: "did:") else { return nil }
        var didValue = String(didPrefix[didRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let separatorIndex = didValue.firstIndex(of: " ") {
            didValue = String(didValue[..<separatorIndex])
        }
        didValue = didValue.trimmingCharacters(in: CharacterSet(charactersIn: ":"))

        guard let hashValue = hashToken else { return nil }
        return (did: didValue, hash: hashValue)
    }

    /// Select usable key packages for the requested members, skipping hashes we've exhausted
    private func selectKeyPackages(
        for members: [DID],
        from pool: [BlueCatbirdMlsDefs.KeyPackageRef],
        userDid: String
    ) async throws -> [KeyPackageWithHash] {
        logger.debug("📦 [selectKeyPackages] Selecting packages for \(members.count) members from pool of \(pool.count)")

        var packagesByDid = Dictionary(grouping: pool, by: { $0.did.description })
            .mapValues { Array($0.shuffled()) }

        var selected: [KeyPackageWithHash] = []
        var skippedCount = 0

        for member in members {
            let didKey = member.description
            guard var options = packagesByDid[didKey], !options.isEmpty else {
                logger.error("❌ No key packages returned for member \(didKey)")
                throw MLSConversationError.missingKeyPackages([didKey])
            }

            logger.debug("   Selecting for \(didKey): \(options.count) candidates available")

            var chosenPackage: KeyPackageWithHash?
            while !options.isEmpty {
                let candidate = options.removeFirst()
                guard let decoded = Data(base64Encoded: candidate.keyPackage, options: []) else {
                    logger.error("❌ Failed to decode key package for \(candidate.did)")
                    continue
                }

                // Prefer server-provided hash for consistency, compute locally if unavailable
                let hash: String
                if let serverHash = candidate.keyPackageHash {
                    hash = serverHash
                    logger.debug("   Using server-provided hash: \(hash.prefix(16))...")
                } else {
                    hash = try await computeKeyPackageReference(for: decoded, userDid: userDid)
                    logger.debug("   Computed local hash (server didn't provide): \(hash.prefix(16))...")
                }

                if isKeyPackageHashExhausted(hash, for: didKey) {
                    logger.warning("⚠️ Skipping exhausted hash for \(didKey): \(hash.prefix(16))...")
                    skippedCount += 1
                    continue
                }

                logger.info("✅ Selected package for \(didKey): hash=\(hash.prefix(16))... (\(decoded.count) bytes)")
                chosenPackage = KeyPackageWithHash(data: decoded, hash: hash, did: member)
                break
            }

            packagesByDid[didKey] = options

            guard let finalPackage = chosenPackage else {
                let exhaustedForDid = exhaustedKeyPackageHashes[didKey]?.count ?? 0
                logger.error("❌ No usable key package for \(didKey) (exhausted: \(exhaustedForDid))")
                throw MLSConversationError.missingKeyPackages([didKey])
            }

            selected.append(finalPackage)
        }

        if skippedCount > 0 {
            logger.warning("⚠️ Skipped \(skippedCount) exhausted key package(s) during selection")
        }

        logger.debug("📦 [selectKeyPackages] Selected \(selected.count) packages, skipped \(skippedCount) exhausted")
        reserveKeyPackages(selected)
        return selected
    }

    /// Normalize HTTP conflict responses into structured key package errors for retry logic
    private func normalizeKeyPackageError(_ error: MLSAPIError) -> MLSAPIError {
        if case .httpError(let statusCode, let message) = error, statusCode == 409 {
            logger.warning("⚠️ Server reported HTTP 409 conflict, normalizing to keyPackageNotFound")
            return .keyPackageNotFound(detail: message)
        }
        return error
    }

    /// Compute the MLS-defined key package reference (hash_ref)
    /// - Parameters:
    ///   - keyPackageData: Raw key package bytes
    ///   - userDid: Authenticated user context for MLS client
    /// - Returns: Hex-encoded hash matching server expectations
    private func computeKeyPackageReference(for keyPackageData: Data, userDid: String) async throws -> String {
        do {
            let hashBytes = try await mlsClient.computeKeyPackageHash(for: userDid, keyPackageData: keyPackageData)
            return hashBytes.hexEncodedString()
        } catch {
            logger.error("❌ Failed to compute key package hash_ref: \(error.localizedDescription)")
            throw MLSConversationError.operationFailed("Unable to compute key package reference")
        }
    }

    /// Prepare local commit/welcome data for the specified members
    private func prepareInitialMembers(members: [DID], userDid: String, groupId: Data) async throws -> PreparedInitialMembers {
        logger.info("🔵 [MLSConversationManager.createGroup] Fetching key packages for \(members.count) members")
        let (keyPackages, _) = try await apiClient.getKeyPackages(dids: members)

        guard !keyPackages.isEmpty else {
            logger.error("❌ [MLSConversationManager.createGroup] No key packages available")
            throw MLSConversationError.missingKeyPackages(members.map { $0.description })
        }

        logger.info("🔵 [MLSConversationManager.createGroup] Got \(keyPackages.count) key packages")

        let selectedPackages = try await selectKeyPackages(for: members, from: keyPackages, userDid: userDid)
        let hashEntries: [BlueCatbirdMlsCreateConvo.KeyPackageHashEntry] = selectedPackages.map { package in
            BlueCatbirdMlsCreateConvo.KeyPackageHashEntry(
                did: package.did,
                hash: package.hash
            )
        }
        let keyPackageData = selectedPackages.map { $0.data }

        logger.debug("📍 [MLSConversationManager.createGroup] Adding members via MLS...")
        let addResult = try await mlsClient.addMembers(
            for: userDid,
            groupId: groupId,
            keyPackages: keyPackageData
        )

        logger.info("✅ [MLSConversationManager.createGroup] Members added locally - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes")
        logger.info("✅ Group automatically advanced to epoch 1 (auto-merged after addMembers)")

        return PreparedInitialMembers(
            commitData: addResult.commitData,
            welcomeData: addResult.welcomeData,
            hashEntries: hashEntries
        )
    }

    /// Create the conversation on the server, retrying once if key packages are rejected
    private func createConversationOnServer(
        userDid: String,
        groupId: Data,
        groupIdHex: String,
        initialMembers: [DID]?,
        metadata: BlueCatbirdMlsCreateConvo.MetadataInput?
    ) async throws -> ServerConversationCreationResult {
        let hasInitialMembers = initialMembers?.isEmpty == false
        let maxAttempts = hasInitialMembers ? 2 : 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            var prepared: PreparedInitialMembers?
            if hasInitialMembers, let members = initialMembers {
                prepared = try await prepareInitialMembers(members: members, userDid: userDid, groupId: groupId)
                logger.info("📍 [MLSConversationManager.createGroup] Prepared Welcome message for \(members.count) members (attempt \(attempt))")
            }

            logger.info("🔵 [MLSConversationManager.createGroup] Creating conversation on server (attempt \(attempt))...")
            do {
                let convo = try await apiClient.createConversation(
                    groupId: groupIdHex,
                    cipherSuite: defaultCipherSuite,
                    initialMembers: initialMembers,
                    welcomeMessage: prepared?.welcomeData,
                    metadata: metadata,
                    keyPackageHashes: prepared?.hashEntries
                )

                return ServerConversationCreationResult(
                    convo: convo,
                    commitData: prepared?.commitData,
                    welcomeData: prepared?.welcomeData
                )
            } catch let error as MLSAPIError {
                let normalizedError = normalizeKeyPackageError(error)

                if hasInitialMembers,
                   case .keyPackageNotFound(let detail) = normalizedError,
                   attempt < maxAttempts {
                    recordKeyPackageFailure(detail: detail)
                    logger.warning("⚠️ [MLSConversationManager.createGroup] Server reported missing key packages (\(detail ?? "no details")). Retrying with fresh bundles...")
                    do {
                        try await mlsClient.clearPendingCommit(for: userDid, groupId: groupId)
                    } catch {
                        logger.error("❌ [MLSConversationManager.createGroup] Failed to clear pending commit after key package error: \(error.localizedDescription)")
                        throw error
                    }

                    do {
                        try await smartRefreshKeyPackages()
                    } catch {
                        logger.warning("⚠️ [MLSConversationManager.createGroup] Key package refresh failed: \(error.localizedDescription)")
                    }

                    lastError = normalizedError
                    continue
                }
                lastError = normalizedError
                break
            } catch {
                lastError = error
                break
            }
        }

        throw lastError ?? MLSConversationError.serverError(
            MLSAPIError.httpError(statusCode: 400, message: "Failed to create conversation")
        )
    }

    /// Generate a stable idempotency key for a message
    private func generateIdempotencyKey(convoId: String, plaintext: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: convoId.data(using: .utf8)!)
        hasher.update(data: plaintext)
        
        // Add a timestamp component to ensure uniqueness for identical messages sent at different times
        let timestamp = Date().timeIntervalSince1970
        hasher.update(data: "\(timestamp)".data(using: .utf8)!)
        
        return hasher.finalize().hexEncodedString()
    }

    /// Check if a message with the same idempotency key was recently sent
    private func isRecentlySent(convoId: String, idempotencyKey: String) -> Bool {
        return recentlySentMessages[convoId]?.contains(idempotencyKey) ?? false
    }

    /// Track a sent message to prevent duplicates
    private func trackSentMessage(convoId: String, idempotencyKey: String) {
        if recentlySentMessages[convoId] == nil {
            recentlySentMessages[convoId] = []
        }
        recentlySentMessages[convoId]?.insert(idempotencyKey)
        
        // Clean up old idempotency keys after the deduplication window
        DispatchQueue.main.asyncAfter(deadline: .now() + deduplicationWindow) { [weak self] in
            self?.recentlySentMessages[convoId]?.remove(idempotencyKey)
        }
    }
}
