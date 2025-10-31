import Foundation
import OSLog
import Petrel

/// Main coordinator for MLS conversation management
/// Handles group initialization, member management, encryption/decryption,
/// server synchronization, key package management, and epoch updates
@Observable
final class MLSConversationManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationManager")
    
    // MARK: - Dependencies

    private let apiClient: MLSAPIClient
    private let mlsClient: MLSClient
    private let storage: MLSStorage
    private let configuration: MLSConfiguration
    
    // MARK: - State
    
    /// Active conversations indexed by conversation ID
    private(set) var conversations: [String: BlueCatbirdMlsDefs.ConvoView] = [:]
    
    /// MLS group states indexed by group ID
    private var groupStates: [String: MLSGroupState] = [:]
    
    /// Pending operations queue
    private var pendingOperations: [MLSOperation] = []
    
    /// Observers for state changes
    private var observers: [MLSStateObserver] = []
    
    /// Current user's DID
    private var userDid: String?
    
    /// Sync status
    private(set) var isSyncing = false
    
    /// Initialization status
    private(set) var isInitialized = false

    /// Background cleanup task
    private var cleanupTask: Task<Void, Never>?
    
    /// Last time key packages were refreshed
    private var lastKeyPackageRefresh: Date?
    
    // MARK: - Configuration
    
    /// Default cipher suite for new groups
    let defaultCipherSuite: String = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
    
    /// Key package refresh interval (in seconds)
    let keyPackageRefreshInterval: TimeInterval = 86400 // 24 hours
    
    /// Maximum retry attempts for failed operations
    private let maxRetries = 3
    
    // MARK: - Initialization
    
    /// Initialize MLS Conversation Manager
    /// - Parameters:
    ///   - apiClient: MLS API client for server communication
    ///   - userDid: Current user's DID
    ///   - storage: MLS storage layer (defaults to shared instance)
    ///   - configuration: MLS configuration (defaults to standard config)
    init(
      apiClient: MLSAPIClient,
      userDid: String? = nil,
      storage: MLSStorage = .shared,
      configuration: MLSConfiguration = .default
    ) {
        self.apiClient = apiClient
        self.userDid = userDid
        self.mlsClient = MLSClient.shared  // Use singleton to persist groups
        self.storage = storage
        self.configuration = configuration

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
                try await mlsClient.setUser(userDid)
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

        // Upload initial key packages to server
        do {
            try await refreshKeyPackagesIfNeeded()
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
        
        logger.debug("📍 [MLSConversationManager.createGroup] Creating local group for user: \(userDid)")
        
        // Create MLS group locally with configured forward secrecy settings
        let groupId = try await mlsClient.createGroup(identity: userDid, configuration: configuration.groupConfiguration)
        let groupIdHex = groupId.hexEncodedString()
        logger.info("🔵 [MLSConversationManager.createGroup] Local group created: \(groupIdHex.prefix(16))...")
        
        // Fetch key packages for initial members if provided
        var welcomeDataArray: [Data] = []
        var commitData: Data?

        if let members = initialMembers, !members.isEmpty {
            logger.info("🔵 [MLSConversationManager.createGroup] Fetching key packages for \(members.count) members")
            let (keyPackages, _) = try await apiClient.getKeyPackages(dids: members)

            guard !keyPackages.isEmpty else {
                logger.error("❌ [MLSConversationManager.createGroup] No key packages available")
                throw MLSConversationError.missingKeyPackages(members.map { $0.description })
            }
            
            logger.info("🔵 [MLSConversationManager.createGroup] Got \(keyPackages.count) key packages")

            // Convert key packages from base64url to raw binary data
            let keyPackagesArray: [Data] = try keyPackages.map { kpRecord in
                logger.debug("📍 [MLSConversationManager.createGroup] Decoding key package for \(kpRecord.did)")
                guard let decoded = Data(base64URLEncoded: kpRecord.keyPackage) else {
                    logger.error("❌ [MLSConversationManager.createGroup] Failed to decode key package for \(kpRecord.did)")
                    throw MLSConversationError.invalidKeyPackage("Invalid base64url encoding")
                }
                logger.debug("📍 [MLSConversationManager.createGroup] Decoded: \(decoded.count) bytes")
                return decoded
            }

            logger.debug("📍 [MLSConversationManager.createGroup] Adding members via MLS...")

            // Add members to group via MLS crypto
            do {
                let addResult = try await mlsClient.addMembers(
                    groupId: groupId,
                    keyPackages: keyPackagesArray
                )

                commitData = addResult.commitData
                welcomeDataArray = [addResult.welcomeData]

                logger.info("✅ [MLSConversationManager.createGroup] Members added locally - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes")
            } catch {
                logger.error("❌ [MLSConversationManager.createGroup] MLS addMembers failed: \(error.localizedDescription)")
                throw MLSConversationError.operationFailed(error.localizedDescription)
            }
        }
        
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

        // Build Welcome message for initial members
        // MLS Protocol: OpenMLS generates ONE Welcome containing encrypted secrets for ALL members
        let welcomeMessage: String? = welcomeDataArray.isEmpty ? nil : welcomeDataArray[0].base64URLEncodedString()
        
        if let welcome = welcomeMessage, let members = initialMembers, !members.isEmpty {
            logger.info("📍 [MLSConversationManager.createGroup] Prepared Welcome message for \(members.count) members")
        }

        logger.info("🔵 [MLSConversationManager.createGroup] Creating conversation on server...")

        // Create conversation on server with proper error handling
        do {
            let convo = try await apiClient.createConversation(
                groupId: groupIdHex,
                cipherSuite: defaultCipherSuite,
                initialMembers: initialMembers,
                welcomeMessage: welcomeMessage,
                metadata: metadataInput
            )

            // Store conversation state
            conversations[convo.id] = convo
            groupStates[groupIdHex] = MLSGroupState(
                groupId: groupIdHex,
                convoId: convo.id,
                epoch: UInt64(convo.epoch),
                members: Set(convo.members.map { $0.did.description })
            )

            // Persist MLS state to Core Data immediately after group creation
            do {
                try await mlsClient.saveStorage()
                logger.info("✅ Persisted MLS state after group creation")
            } catch {
                logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
            }

            // Notify observers
            notifyObservers(.conversationCreated(convo))

            logger.info("✅ [MLSConversationManager.createGroup] COMPLETE - convoId: \(convo.id), epoch: \(convo.epoch)")
            return convo

        } catch {
            logger.error("❌ [MLSConversationManager.createGroup] Server creation failed: \(error.localizedDescription)")

            if initialMembers != nil && !initialMembers!.isEmpty {
                logger.debug("📍 [MLSConversationManager.createGroup] Cleaning up pending commit...")
                do {
                    try await mlsClient.clearPendingCommit(groupId: groupId)
                    logger.info("✅ [MLSConversationManager.createGroup] Cleared pending commit")
                } catch {
                    logger.error("❌ [MLSConversationManager.createGroup] Failed to clear pending commit: \(error.localizedDescription)")
                }
            }

            throw MLSConversationError.serverError(error)
        }
    }
    
    // MARK: - Base64 URL helpers
    private static func base64UrlNoPad(from data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64.replacingOccurrences(of: "+", with: "-")
                  .replacingOccurrences(of: "/", with: "_")
                  .replacingOccurrences(of: "=", with: "")
    }
    
    private static func decodeBase64URLSafe(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (str.count % 4)) % 4
        if padding > 0 { str.append(String(repeating: "=", count: padding)) }
        return Data(base64Encoded: str)
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
        self.conversations[convo.id] = convo
        groupStates[groupId] = MLSGroupState(
            groupId: groupId,
            convoId: convo.id,
            epoch: UInt64(convo.epoch),
            members: Set(convo.members.map { $0.did.description })
        )
        
        // Notify observers
        notifyObservers(.conversationJoined(convo))
        
        logger.info("Successfully joined conversation: \(convo.id)")
        return convo
    }
    
    // MARK: - Member Management
    
    /// Add members to an existing conversation
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - memberDids: DIDs of members to add
    func addMembers(convoId: String, memberDids: [String]) async throws {
        logger.info("🔵 [MLSConversationManager.addMembers] START - convoId: \(convoId), members: \(memberDids.count)")
        
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

        // Extract and decode key packages from base64url strings
        let keyPackages = keyPackagesResult.keyPackages
        let keyPackagesArray = try keyPackages.map { kpRef -> Data in
            guard let decoded = Data(base64URLEncoded: kpRef.keyPackage) else {
                logger.error("❌ [MLSConversationManager.addMembers] Failed to decode key package for \(kpRef.did)")
                throw MLSConversationError.invalidKeyPackage("Failed to decode key package for DID: \(kpRef.did)")
            }
            logger.debug("📍 [MLSConversationManager.addMembers] Decoded key package: \(decoded.count) bytes")
            return decoded
        }

        do {
            // 1. Create commit locally (staged, not merged)
            logger.info("🔵 [MLSConversationManager.addMembers] Step 1/4: Creating staged commit...")
            let addResult = try await mlsClient.addMembers(
                groupId: groupIdData,
                keyPackages: keyPackagesArray
            )
            logger.info("✅ [MLSConversationManager.addMembers] Staged commit created - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes")

            // 2. Send commit and welcome to server
            logger.info("🔵 [MLSConversationManager.addMembers] Step 2/4: Sending to server...")
            let commitBase64Url = Self.base64UrlNoPad(from: addResult.commitData)
            let welcomeMessage = Self.base64UrlNoPad(from: addResult.welcomeData)
            
            logger.info("📍 [MLSConversationManager.addMembers] Prepared Welcome message for \(dids.count) new members")

            let (success, newEpoch) = try await apiClient.addMembers(
                convoId: convoId,
                didList: dids,
                commit: commitBase64Url,
                welcomeMessage: welcomeMessage
            )

            guard success else {
                logger.warning("⚠️ [MLSConversationManager.addMembers] Server rejected commit, clearing...")
                try await mlsClient.clearPendingCommit(groupId: groupIdData)
                throw MLSConversationError.operationFailed("Server rejected member addition")
            }
            logger.info("✅ [MLSConversationManager.addMembers] Server accepted - newEpoch: \(newEpoch)")

            // 3. Server accepted - merge the pending commit
            logger.info("🔵 [MLSConversationManager.addMembers] Step 3/4: Merging pending commit...")
            let mergedEpoch = try await mlsClient.mergePendingCommit(groupId: groupIdData)
            logger.info("✅ [MLSConversationManager.addMembers] Merged - epoch: \(mergedEpoch)")

            // Verify epoch matches
            if mergedEpoch != newEpoch {
                logger.warning("⚠️ [MLSConversationManager.addMembers] Epoch mismatch: local=\(mergedEpoch), server=\(newEpoch)")
            }

            // 4. Update local state
            logger.info("🔵 [MLSConversationManager.addMembers] Step 4/4: Updating local state...")
            var updatedState = groupStates[convo.groupId] ?? groupState
            updatedState.epoch = UInt64(newEpoch)
            updatedState.members.formUnion(memberDids)
            groupStates[convo.groupId] = updatedState

            // Persist MLS state after adding members
            do {
                try await mlsClient.saveStorage()
                logger.info("✅ Persisted MLS state after adding members")
            } catch {
                logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
            }

            // Notify observers
            notifyObservers(.membersAdded(convoId, dids))
            notifyObservers(.epochUpdated(convoId, Int(newEpoch)))

            logger.info("✅ [MLSConversationManager.addMembers] COMPLETE - convoId: \(convoId), epoch: \(newEpoch), members: \(updatedState.members.count)")

        } catch {
            logger.error("❌ [MLSConversationManager.addMembers] Error, cleaning up: \(error.localizedDescription)")

            do {
                try await mlsClient.clearPendingCommit(groupId: groupIdData)
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
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt and send a message to a conversation
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - plaintext: Plain text message to encrypt
    ///   - embedType: Optional embed type ('tenor', 'bsky_post', 'link')
    ///   - embedUri: Optional embed URI
    /// - Returns: Sent message with messageId and timestamp
    func sendMessage(
        convoId: String,
        plaintext: String,
        embedType: String? = nil,
        embedUri: URI? = nil
    ) async throws -> (messageId: String, receivedAt: ATProtocolDate) {
        logger.info("🔵 [MLSConversationManager.sendMessage] START - convoId: \(convoId), text: \(plaintext.count) chars, embedType: \(embedType ?? "none")")
        let startTotal = Date()
        
        guard let convo = conversations[convoId] else {
            logger.error("❌ [MLSConversationManager.sendMessage] Conversation not found")
            throw MLSConversationError.conversationNotFound
        }
        
        guard let plaintextData = plaintext.data(using: .utf8) else {
            logger.error("❌ [MLSConversationManager.sendMessage] Invalid message encoding")
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
        let groupExists = mlsClient.groupExists(groupId: groupIdData)
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
        
        // Encrypt message locally
        let encryptStart = Date()
        logger.debug("📍 [MLSConversationManager.sendMessage] Encrypting message...")
        let ciphertext = try await encryptMessage(groupId: currentConvo.groupId, plaintext: plaintextData)
        let encryptMs = Int(Date().timeIntervalSince(encryptStart) * 1000)
        logger.info("✅ [MLSConversationManager.sendMessage] Encrypted in \(encryptMs)ms - ciphertext: \(ciphertext.count) bytes")
        
        // Send encrypted message directly to server
        do {
            let apiStart = Date()
            logger.debug("📍 [MLSConversationManager.sendMessage] Sending to server...")
            let (messageId, receivedAt) = try await apiClient.sendMessage(
                convoId: convoId,
                ciphertext: ciphertext,
                epoch: currentConvo.epoch,
                senderDid: did,
                embedType: embedType,
                embedUri: embedUri
            )
            
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
    /// - Returns: Decrypted plaintext string
    func decryptMessage(_ message: BlueCatbirdMlsDefs.MessageView) async throws -> String {
        logger.debug("Decrypting message: \(message.id)")
        
        guard let convo = conversations[message.convoId] else {
            throw MLSConversationError.conversationNotFound
        }
        
        // Get ciphertext directly from message (text-only PostgreSQL storage)
        let ciphertextData = message.ciphertext.data
        
        // Decrypt message locally
        let plaintext = try await decryptMessage(groupId: convo.groupId, ciphertext: ciphertextData)
        
        guard let plaintextString = String(data: plaintext, encoding: .utf8) else {
            throw MLSConversationError.decodingFailed
        }
        
        logger.debug("Successfully decrypted message: \(message.id)")
        return plaintextString
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
                let existingConvo = conversations[convo.id]
                conversations[convo.id] = convo

                // Check if we need to initialize the MLS group
                let needsGroupInit = groupStates[convo.groupId] == nil

                // Update group state metadata
                if groupStates[convo.groupId] == nil {
                    groupStates[convo.groupId] = MLSGroupState(
                        groupId: convo.groupId,
                        convoId: convo.id,
                        epoch: UInt64(convo.epoch),
                        members: Set(convo.members.map { $0.did.description })
                    )
                } else if var state = groupStates[convo.groupId] {
                    if state.epoch != convo.epoch {
                        state.epoch = UInt64(convo.epoch)
                        state.members = Set(convo.members.map { $0.did.description })
                        groupStates[convo.groupId] = state

                        // Notify epoch update
                        notifyObservers(.epochUpdated(convo.id, convo.epoch))
                    }
                }

                // Initialize MLS group if needed
                if needsGroupInit {
                    // Check if group exists locally via FFI
                    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
                        logger.error("Invalid group ID format for \(convo.id)")
                        continue
                    }
                    
                    let groupExists = mlsClient.groupExists(groupId: groupIdData)
                    
                    if !groupExists {
                        logger.info("Initializing MLS group for conversation: \(convo.id)")
                        do {
                            try await initializeGroupFromWelcome(convo: convo)
                            logger.info("Successfully initialized MLS group for conversation: \(convo.id)")
                        } catch {
                            logger.error("Failed to initialize MLS group for \(convo.id): \(error.localizedDescription)")
                            // Don't fail the entire sync - just log and continue
                        }
                    } else {
                        logger.debug("Group already exists locally for conversation: \(convo.id)")
                    }
                }

                // Notify if new conversation
                if existingConvo == nil {
                    notifyObservers(.conversationCreated(convo))
                }
            }
            
            // Notify sync complete
            notifyObservers(.syncCompleted(allConvos.count))
            
            logger.info("Successfully synced \(allConvos.count) conversations")
            
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            notifyObservers(.syncFailed(error))
            throw MLSConversationError.syncFailed(error)
        }
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
        let keyPackageData = try await mlsClient.createKeyPackage(identity: userDid)
        let keyPackageBase64Url = Self.base64UrlNoPad(from: keyPackageData)
        
        // Publish to server (returns empty response)
        do {
            // Server requires an explicit future expiration; default to 30 days if not provided
            let expiry = expiresAt ?? Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)
            try await apiClient.publishKeyPackage(
                keyPackage: keyPackageBase64Url,
                cipherSuite: defaultCipherSuite,
                expires: expiry
            )
            
            // Create a local reference (server doesn't return the package)
            let didObj = try DID(didString: userDid)
            let keyPackageRef = BlueCatbirdMlsDefs.KeyPackageRef(
                did: didObj,
                keyPackage: keyPackageBase64Url,
                cipherSuite: defaultCipherSuite
            )
            
            logger.info("Successfully published key package for: \(userDid)")
            return keyPackageRef
            
        } catch {
            logger.error("Failed to publish key package: \(error.localizedDescription)")
            throw MLSConversationError.serverError(error)
        }
    }
    
    /// Refresh key packages if needed
    func refreshKeyPackagesIfNeeded() async throws {
        logger.debug("Checking if key package refresh is needed")
        
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }
        
        // Fetch current key packages
        let userDidObj = try DID(didString: userDid)
        let result = try await apiClient.getKeyPackages(dids: [userDidObj])
        
        // KeyPackageRef doesn't have expiresAt, so always refresh if requested
        // This is a simplified approach - in production you may want to track expiry separately
        let needsRefresh = result.keyPackages.isEmpty || true
        
        if needsRefresh || result.keyPackages.isEmpty {
            logger.info("Key package refresh needed")
            let expiresAt = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60) // 30 days
            try await publishKeyPackage(expiresAt: expiresAt)
            lastKeyPackageRefresh = Date()
        } else {
            logger.debug("Key packages are up to date")
        }
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
            id: convo.id,
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
        // Convert hex-encoded groupId to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }
        
        // Process commit through MLS client
        let result = try await mlsClient.processCommit(groupId: groupIdData, commitData: commitData)
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
                try await storage.recordEpochKey(conversationID: state.convoId, epoch: Int64(epochInt))
                logger.debug("Recorded epoch key for cleanup tracking")

                // Clean up old epoch keys based on retention policy
                try await storage.deleteOldEpochKeys(
                  conversationID: state.convoId,
                  keepLast: configuration.maxPastEpochs
                )
                logger.debug("Cleaned up old epoch keys (keeping last \(self.configuration.maxPastEpochs))")
            } catch {
                logger.error("Failed to cleanup old epoch keys: \(error)")
            }

            // Persist MLS state after epoch change (critical for forward secrecy)
            do {
                try await mlsClient.saveStorage()
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
            try await storage.cleanupMessageKeys(olderThan: threshold)
            logger.debug("Cleaned up message keys older than \(threshold)")

            // Permanently delete marked epoch keys
            try await storage.deleteMarkedEpochKeys()
            logger.debug("Permanently deleted marked epoch keys")

            // Clean up expired key packages
            try await MainActor.run {
                try storage.deleteExpiredKeyPackages()
            }
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
        
        // groupId is hex-encoded, convert to Data
        guard let groupIdData = Data(hexEncoded: groupId) else {
            logger.error("Failed to decode hex groupId: \(groupId.prefix(20))...")
            throw MLSConversationError.invalidGroupId
        }
        
        logger.debug("Calling mlsClient.encryptMessage with groupIdData.count=\(groupIdData.count)")
        let encryptResult = try await mlsClient.encryptMessage(groupId: groupIdData, plaintext: plaintext)
        logger.debug("mlsClient.encryptMessage succeeded, ciphertext.count=\(encryptResult.ciphertext.count)")
        
        // Persist MLS state after encryption (sender ratchet advanced)
        do {
            try await mlsClient.saveStorage()
            logger.debug("✅ Persisted MLS state after message encryption")
        } catch {
            logger.error("⚠️ Failed to persist MLS state after encryption: \(error.localizedDescription)")
        }
        
        return encryptResult.ciphertext
    }
    
    /// Decrypt message using MLSClient with processMessage flow
    private func decryptMessage(groupId: String, ciphertext: Data) async throws -> Data {
        logger.info("Decrypting message for group \(groupId.prefix(8))...")

        guard let groupIdData = Data(hexEncoded: groupId) else {
            logger.error("Invalid group ID format")
            throw MLSConversationError.invalidGroupId
        }

        let ciphertextData = ciphertext

        do {
            // Use processMessage instead of decryptMessage to get content type
            let processedContent = try await mlsClient.processMessage(
                groupId: groupIdData,
                messageData: ciphertextData
            )

            // Handle different message types
            switch processedContent {
            case .applicationMessage(let plaintext):
                // Normal application message - return decrypted content
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
        let groupId = try await mlsClient.joinGroup(welcome: welcomeData, identity: identity, configuration: configuration.groupConfiguration)
        return groupId.hexEncodedString()
    }

    /// Ensure MLS group is initialized for a conversation
    /// This should be called when opening a conversation to ensure the user can send/receive messages
    /// - Parameter convoId: Conversation ID to initialize
    func ensureGroupInitialized(for convoId: String) async throws {
        guard let convo = conversations[convoId] else {
            logger.warning("Cannot initialize group: conversation \(convoId) not found")
            throw MLSConversationError.conversationNotFound
        }
        
        guard let groupIdData = Data(hexEncoded: convo.groupId) else {
            logger.error("Invalid groupId for conversation \(convoId)")
            throw MLSConversationError.invalidGroupId
        }
        
        // Check if group already exists locally
        if mlsClient.groupExists(groupId: groupIdData) {
            logger.debug("Group already initialized for conversation \(convoId)")
            return
        }
        
        logger.info("Initializing group for conversation \(convoId)...")
        try await initializeGroupFromWelcome(convo: convo)
    }

    /// Initialize MLS group from Welcome message fetched from server
    /// - Parameter convo: Conversation to initialize
    private func initializeGroupFromWelcome(convo: BlueCatbirdMlsDefs.ConvoView) async throws {
        guard let userDid = userDid else {
            throw MLSConversationError.noAuthentication
        }

        // Fetch Welcome message from server
        logger.info("📥 Fetching Welcome message for conversation: \(convo.id), user: \(userDid)")
        let welcomeBase64Url: String
        do {
            welcomeBase64Url = try await apiClient.getWelcome(convoId: convo.id)
        } catch let error as MLSAPIError {
            // Detailed error logging for API errors
            logger.error("❌ API error fetching Welcome message: \(error.localizedDescription)")
            
            // Check if user is the creator
            let isCreator = convo.creator.description == userDid
            
            if isCreator {
                // Creator lost local state - this conversation cannot be recovered
                logger.error("❌ No Welcome message for creator of \(convo.id) - local state was lost and cannot be recovered")
                logger.error("   The group was created on this device but the MLS state was not persisted.")
                logger.error("   This conversation will be read-only until a new group is created.")
                throw MLSConversationError.groupNotInitialized
            }
            
            // For members, check if it's a 410 Gone (already consumed) or 404 (not found)
            switch error {
            case .httpError(let statusCode, let message) where statusCode == 410:
                // Welcome was already consumed - this is expected after first join
                logger.warning("⚠️ Welcome message already consumed for \(convo.id) - group should already be initialized locally")
                logger.warning("   This indicates the local MLS state was not persisted after joining.")
                throw MLSConversationError.groupNotInitialized
            case .httpError(let statusCode, _) where statusCode == 404:
                logger.error("❌ Welcome message not found for \(convo.id) - server may have expired it")
                throw MLSConversationError.invalidWelcomeMessage
            default:
                logger.warning("No Welcome message available for member in \(convo.id). Error: \(error)")
                throw MLSConversationError.invalidWelcomeMessage
            }
        } catch {
            // Unknown error type
            logger.error("❌ Unexpected error fetching Welcome message: \(error)")
            
            let isCreator = convo.creator.description == userDid
            if isCreator {
                logger.error("No Welcome message for creator of \(convo.id) - cannot reconstruct without original state")
                throw MLSConversationError.groupNotInitialized
            }
            
            logger.warning("Failed to fetch Welcome message for \(convo.id): \(error.localizedDescription)")
            throw MLSConversationError.invalidWelcomeMessage
        }

        // Decode Welcome message from base64url
        guard let welcomeData = Data(base64URLEncoded: welcomeBase64Url) else {
            logger.error("Failed to decode Welcome message for \(convo.id)")
            throw MLSConversationError.invalidWelcomeMessage
        }

        logger.info("✅ Received Welcome message for conversation: \(convo.id), size: \(welcomeData.count) bytes")

        // Join the group using the Welcome message
        let joinedGroupId = try await processWelcome(welcomeData: welcomeData, identity: userDid)

        // Verify the group ID matches
        if joinedGroupId != convo.groupId {
            logger.error("Group ID mismatch: joined=\(joinedGroupId), expected=\(convo.groupId)")
            throw MLSConversationError.invalidGroupId
        }

        // Persist MLS state to Core Data immediately after joining group
        do {
            try await mlsClient.saveStorage()
            logger.info("✅ Persisted MLS state after joining group")
        } catch {
            logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
        }

        logger.info("✅ Successfully joined MLS group \(joinedGroupId) for conversation \(convo.id)")
    }

    // MARK: - Proposal Validation

    /// Handle incoming proposal by validating and optionally storing it
    /// - Parameters:
    ///   - groupId: Group identifier
    ///   - proposal: Proposal information
    ///   - proposalRef: Proposal reference for storage
    func handleProposal(groupId: String, proposal: ProposalInfo, proposalRef: ProposalRef) async throws {
        logger.info("Handling proposal for group \(groupId.prefix(8))...")

        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }

        switch proposal {
        case .add(let addInfo):
            if validateAddProposal(addInfo, groupId: groupId) {
                try await mlsClient.storeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.info("Accepted and stored add proposal")
            } else {
                try await mlsClient.removeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.warning("Rejected and removed add proposal for group \(groupId.prefix(8))...")
            }

        case .remove(let removeInfo):
            if validateRemoveProposal(removeInfo, groupId: groupId) {
                try await mlsClient.storeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.info("Accepted and stored remove proposal")
            } else {
                try await mlsClient.removeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.warning("Rejected and removed remove proposal for group \(groupId.prefix(8))...")
            }

        case .update(let updateInfo):
            if validateUpdateProposal(updateInfo, groupId: groupId) {
                try await mlsClient.storeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.info("Accepted and stored update proposal")
            } else {
                try await mlsClient.removeProposal(groupId: groupIdData, proposalRef: proposalRef)
                logger.warning("Rejected and removed update proposal for group \(groupId.prefix(8))...")
            }
        }
    }

    /// Validate and merge a staged commit
    /// - Parameters:
    ///   - groupId: Group identifier (hex-encoded)
    ///   - newEpoch: New epoch from the staged commit
    private func validateAndMergeStagedCommit(groupId: String, newEpoch: UInt64) async throws {
        logger.info("Validating staged commit for group \(groupId.prefix(8))...")

        guard let groupIdData = Data(hexEncoded: groupId) else {
            throw MLSConversationError.invalidGroupId
        }

        guard let state = groupStates[groupId] else {
            throw MLSConversationError.groupStateNotFound
        }

        // Validate epoch progression (must increment by exactly 1)
        guard newEpoch == state.epoch + 1 else {
            logger.error("Invalid epoch progression: current=\(state.epoch), new=\(newEpoch)")
            throw MLSConversationError.invalidEpoch("Epoch must increment by 1")
        }

        logger.info("Epoch validation passed, merging staged commit...")

        // Merge the staged commit
        let mergedEpoch = try await mlsClient.mergeStagedCommit(groupId: groupIdData)

        logger.info("Staged commit merged successfully, new epoch: \(mergedEpoch)")

        // Update local state
        handleEpochUpdate(convoId: state.convoId, newEpoch: mergedEpoch)
    }

    /// Validate an add proposal
    /// - Parameters:
    ///   - proposal: Add proposal information
    ///   - groupId: Group identifier
    /// - Returns: True if proposal is valid
    private func validateAddProposal(_ proposal: AddProposalInfo, groupId: String) -> Bool {
        logger.info("Validating add proposal")

        guard let identity = String(data: proposal.credential.identity, encoding: .utf8) else {
            logger.error("Invalid credential identity encoding")
            return false
        }

        if proposal.credential.credentialType != "Basic" {
            logger.error("Unsupported credential type: \(proposal.credential.credentialType)")
            return false
        }

        guard let state = groupStates[groupId] else {
            logger.error("Group state not found")
            return false
        }

        if state.members.contains(identity) {
            logger.warning("Member \(identity) already in group")
            return false
        }

        logger.info("Add proposal validated successfully for \(identity)")
        return true
    }

    /// Validate a remove proposal
    /// - Parameters:
    ///   - proposal: Remove proposal information
    ///   - groupId: Group identifier
    /// - Returns: True if proposal is valid
    private func validateRemoveProposal(_ proposal: RemoveProposalInfo, groupId: String) -> Bool {
        logger.info("Validating remove proposal for index \(proposal.removedIndex)")

        guard let state = groupStates[groupId] else {
            logger.error("Group state not found")
            return false
        }

        if state.members.isEmpty {
            logger.error("Cannot remove from empty group")
            return false
        }

        logger.info("Remove proposal validated successfully")
        return true
    }

    /// Validate an update proposal
    /// - Parameters:
    ///   - proposal: Update proposal information
    ///   - groupId: Group identifier
    /// - Returns: True if proposal is valid
    private func validateUpdateProposal(_ proposal: UpdateProposalInfo, groupId: String) -> Bool {
        logger.info("Validating update proposal for leaf index \(proposal.leafIndex)")

        guard let oldIdentity = String(data: proposal.oldCredential.identity, encoding: .utf8) else {
            logger.error("Invalid old credential identity encoding")
            return false
        }

        guard let newIdentity = String(data: proposal.newCredential.identity, encoding: .utf8) else {
            logger.error("Invalid new credential identity encoding")
            return false
        }

        guard let state = groupStates[groupId] else {
            logger.error("Group state not found")
            return false
        }

        if !state.members.contains(oldIdentity) {
            logger.warning("Member \(oldIdentity) not in group")
            return false
        }

        if proposal.newCredential.credentialType != "Basic" {
            logger.error("Unsupported new credential type: \(proposal.newCredential.credentialType)")
            return false
        }

        logger.info("Update proposal validated successfully: \(oldIdentity) -> \(newIdentity)")
        return true
    }

    /// Add invalid key package error
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
                return "Invalid epoch: \(message)"
            case .missingKeyPackages(let dids):
                return "Missing key packages for DIDs: \(dids.joined(separator: ", "))"
            case .operationFailed(let message):
                return "Operation failed: \(message)"
            case .mlsError(let message):
                return "MLS operation failed: \(message)"
            case .serverError(let error):
                return "Server error: \(error.localizedDescription)"
            case .syncFailed(let error):
                return "Sync failed: \(error.localizedDescription)"
            case .commitProcessingFailed(let epoch, let error):
                return "Failed to process commit for epoch \(epoch): \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Supporting Types

/// Group state information
struct MLSGroupState {
    var groupId: String
    var convoId: String
    var epoch: UInt64
    var members: Set<String>
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
            return "Conversation created: \(convo.id)"
        case .conversationJoined(let convo):
            return "Conversation joined: \(convo.id)"
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
