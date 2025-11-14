import Foundation
import OSLog
import Petrel

/// Environment configuration for MLS API
enum MLSEnvironment {
    case production
    case custom(serviceDID: String)
    
    var serviceDID: String {
        switch self {
        case .production:
            return "did:web:mls.catbird.blue#atproto_mls"
        case .custom(let did):
            return did
        }
    }
    
    var description: String {
        switch self {
        case .production:
            return "Production (mls.catbird.blue)"
        case .custom(let did):
            return "Custom (\(did))"
        }
    }
}

/// MLS API Client using Petrel ATProto client with BlueCatbirdMls* models
/// Properly configured with atproto-proxy header for MLS service routing
@Observable
final class MLSAPIClient {
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSAPIClient")
    
    // MARK: - Configuration
    
    /// ATProto client for MLS API calls
    private let client: ATProtoClient
    
    /// Current environment configuration
    private(set) var environment: MLSEnvironment
    
    /// MLS service DID for atproto-proxy header
    private(set) var mlsServiceDID: String
    
    /// Server health status
    private(set) var isHealthy: Bool = false
    
    /// Last health check timestamp
    private(set) var lastHealthCheck: Date?
    
    // MARK: - Initialization
    
    /// Initialize MLS API client with ATProtoClient and environment
    /// - Parameters:
    ///   - client: Configured ATProtoClient instance
    ///   - environment: MLS service environment (default: .production)
    init(
        client: ATProtoClient,
        environment: MLSEnvironment = .production
    ) async {
        self.client = client
        self.environment = environment
        self.mlsServiceDID = environment.serviceDID
        
        // Configure MLS service DID and atproto-proxy header
        await self.configureMLSService()
        
        logger.info("MLSAPIClient initialized with environment: \(environment.description)")
        logger.debug("MLS Service DID: \(self.mlsServiceDID)")
    }
    
    // MARK: - Configuration Management
    
    /// Configure MLS service DID and proxy headers
    private func configureMLSService() async {
        // Set the service DID for MLS namespace (blue.catbird.mls)
        // This enables atproto-proxy header routing through the PDS
        await client.setServiceDID(mlsServiceDID, for: "blue.catbird.mls")

        // All MLS requests go through PDS with atproto-proxy header
        // The PDS handles routing to the MLS service with proper authentication

        logger.debug("Configured MLS service DID: \(self.mlsServiceDID) for namespace blue.catbird.mls")
    }
    
    /// Switch to a different MLS environment
    /// - Parameter newEnvironment: The environment to switch to
    func switchEnvironment(_ newEnvironment: MLSEnvironment) async {
        environment = newEnvironment
        mlsServiceDID = newEnvironment.serviceDID
        isHealthy = false
        lastHealthCheck = nil
        
        // Reconfigure with new service DID
        await configureMLSService()
        
        logger.info("Switched to environment: \(newEnvironment.description)")
    }
    
    // MARK: - Authentication Validation

    /// Get the currently authenticated user's DID from the ATProto client
    /// - Returns: The authenticated user's DID, or nil if not authenticated
    func authenticatedUserDID() async -> String? {
        do {
            // The ATProtoClient session contains the authenticated user's DID
            // This is set during login and persists until logout
            return try await client.getDid()
        } catch {
            logger.warning("⚠️ Failed to fetch authenticated user DID: \(error.localizedDescription)")
            return nil
        }
    }

    /// Verify that the ATProto client is authenticated as the expected user
    /// - Parameter expectedDID: The DID that should be authenticated
    /// - Returns: True if authenticated as expected user, false otherwise
    func isAuthenticatedAs(_ expectedDID: String) async -> Bool {
        guard let currentDID = await authenticatedUserDID() else {
            logger.warning("⚠️ No authenticated user in ATProtoClient")
            return false
        }

        let matches = currentDID == expectedDID
        if !matches {
            logger.error("❌ Account mismatch: authenticated=\(currentDID), expected=\(expectedDID)")
        }
        return matches
    }

    /// Verify authentication and throw if mismatched (convenience for throwing contexts)
    /// - Parameter expectedDID: The DID that should be authenticated
    /// - Throws: MLSAPIError if authentication doesn't match
    func validateAuthentication(expectedDID: String) async throws {
        guard let currentDID = await authenticatedUserDID() else {
            logger.error("❌ No authenticated user in ATProtoClient")
            throw MLSAPIError.noAuthentication
        }

        guard currentDID == expectedDID else {
            logger.error("❌ Account mismatch: authenticated=\(currentDID), expected=\(expectedDID)")
            throw MLSAPIError.accountMismatch(authenticated: currentDID, expected: expectedDID)
        }

        logger.debug("✅ Validated authentication for \(expectedDID)")
    }

    // MARK: - Health Check

    /// Perform health check to verify MLS service connectivity
    /// - Returns: True if service is healthy and reachable
    @discardableResult
    func checkHealth() async -> Bool {
        logger.debug("Performing health check for \(self.environment.description)")

        // TODO: Implement health check via ATProto client once available
        // For now, we'll check if we can list conversations as a proxy
        do {
            _ = try await getConversations(limit: 1)
            isHealthy = true
            lastHealthCheck = Date()
            logger.info("Health check passed")
            return true
        } catch {
            isHealthy = false
            lastHealthCheck = Date()
            logger.warning("Health check failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - API Endpoints (using Petrel BlueCatbirdMls* models)
    
    // MARK: Conversations
    
    /// Get conversations for the authenticated user using Petrel client
    /// - Parameters:
    ///   - limit: Maximum number of conversations to return (1-100, default: 50)
    ///   - cursor: Pagination cursor from previous response
    /// - Returns: Tuple of conversations array and optional next cursor
    func getConversations(
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> (convos: [BlueCatbirdMlsDefs.ConvoView], cursor: String?) {
        logger.info("🌐 [MLSAPIClient.getConversations] START - limit: \(limit), cursor: \(cursor ?? "none")")
        
        let input = BlueCatbirdMlsGetConvos.Parameters(
            limit: limit,
            cursor: cursor
        )
        
        logger.debug("📍 [MLSAPIClient.getConversations] Calling API...")
        let (responseCode, output) = try await client.blue.catbird.mls.getConvos(input: input)
        
        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getConversations] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch conversations")
        }
        
        logger.info("✅ [MLSAPIClient.getConversations] SUCCESS - \(output.conversations.count) conversations, nextCursor: \(output.cursor ?? "none")")
        return (output.conversations, output.cursor)
    }
    
    /// Create a new MLS conversation using Petrel client
    /// - Parameters:
    ///   - cipherSuite: MLS cipher suite to use (e.g., "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    ///   - initialMembers: DIDs of initial members to add
    ///   - welcomeMessage: Welcome message data for initial members
    ///   - metadata: Optional conversation metadata (name, description, avatar)
    ///   - keyPackageHashes: Optional array of key package hashes identifying which key packages were used
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Created conversation view
    func createConversation(
        groupId: String,
        cipherSuite: String,
        initialMembers: [DID]? = nil,
        welcomeMessage: Data? = nil,
        metadata: BlueCatbirdMlsCreateConvo.MetadataInput? = nil,
        keyPackageHashes: [BlueCatbirdMlsCreateConvo.KeyPackageHashEntry]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> BlueCatbirdMlsDefs.ConvoView {
        // Generate idempotency key if not provided
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.createConversation] START - groupId: \(groupId.prefix(16))..., members: \(initialMembers?.count ?? 0), hashes: \(keyPackageHashes?.count ?? 0), idempotencyKey: \(idemKey)")

        // Encode Data to base64 String for ATProto $bytes field
        let welcomeBase64 = welcomeMessage?.base64EncodedString()

        let input = BlueCatbirdMlsCreateConvo.Input(
            groupId: groupId,
            idempotencyKey: idemKey,
            cipherSuite: cipherSuite,
            initialMembers: initialMembers,
            welcomeMessage: welcomeBase64,
            keyPackageHashes: keyPackageHashes,
            metadata: metadata
        )

        logger.debug("📍 [MLSAPIClient.createConversation] Request payload:")
        logger.debug("  - groupId: \(groupId)")
        logger.debug("  - cipherSuite: \(cipherSuite)")
        logger.debug("  - initialMembers: \(initialMembers?.map { $0 } ?? [])")
        logger.debug("  - welcomeMessage length: \(welcomeBase64?.count ?? 0) chars")
        if let welcome = welcomeBase64 {
            logger.debug("  - welcomeMessage prefix: \(String(welcome.prefix(50)))...")
        }
        logger.debug("  - metadata: \(metadata != nil ? "present" : "nil")")
        logger.debug("  - keyPackageHashes: \(keyPackageHashes?.count ?? 0) items")
        if let hashes = keyPackageHashes {
            for (idx, hash) in hashes.enumerated() {
                logger.debug("    [\(idx)] did: \(hash.did), hash: \(hash.hash.prefix(16))...")
            }
        }

        logger.debug("📍 [MLSAPIClient.createConversation] Calling API...")
        do {
            let (responseCode, output) = try await client.blue.catbird.mls.createConvo(input: input)

            guard responseCode == 200, let convoView = output else {
                logger.error("❌ [MLSAPIClient.createConversation] HTTP \(responseCode) - no structured error caught")
                throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to create conversation")
            }

            logger.info("✅ [MLSAPIClient.createConversation] SUCCESS - convoId: \(convoView.groupId), epoch: \(convoView.epoch)")
            return convoView
        } catch let error as ATProtoError<BlueCatbirdMlsCreateConvo.Error> {
            // Structured error from server - now properly parsed with fixed enum!
            logger.error("❌ [MLSAPIClient.createConversation] Structured error: \(error.error.errorName)")
            logger.error("   Message: \(error.message ?? "no message")")
            logger.error("   Status code: \(error.statusCode)")

            // Log specific details for KeyPackageNotFound errors
            if case .keyPackageNotFound = error.error {
                logger.warning("⚠️ KeyPackageNotFound detected - hash may be exhausted or invalid")
                if let msg = error.message {
                    logger.debug("   Server details: \(msg)")
                }
            }

            throw MLSAPIError(from: error)
        } catch {
            // Catch-all for other errors (network, etc.)
            logger.error("❌ [MLSAPIClient.createConversation] Unexpected error: \(error)")
            logger.error("   Error type: \(type(of: error))")
            throw error
        }
    }
    
    /// Leave an MLS conversation using Petrel client
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Success status and new epoch number
    func leaveConversation(convoId: String) async throws -> (success: Bool, newEpoch: Int) {
        logger.debug("Leaving conversation: \(convoId)")
        
        let input = BlueCatbirdMlsLeaveConvo.Input(convoId: convoId)
        let (responseCode, output) = try await client.blue.catbird.mls.leaveConvo(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to leave conversation")
        }
        
        logger.debug("Left conversation: \(convoId)")
        return (output.success, output.newEpoch)
    }
    
    // MARK: Members
    
    /// Add members to an existing MLS conversation using Petrel client
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - didList: Array of member DIDs to add
    ///   - commit: MLS Commit message data
    ///   - welcomeMessage: Welcome message data for new members
    ///   - keyPackageHashes: Optional array of key package hashes identifying which key packages were used
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success status and new epoch number
    func addMembers(
        convoId: String,
        didList: [DID],
        commit: Data? = nil,
        welcomeMessage: Data? = nil,
        keyPackageHashes: [BlueCatbirdMlsAddMembers.KeyPackageHashEntry]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> (success: Bool, newEpoch: Int) {
        // Generate idempotency key if not provided
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.debug("Adding \(didList.count) members to conversation: \(convoId), hashes: \(keyPackageHashes?.count ?? 0), idempotencyKey: \(idemKey)")

        // Encode Data to base64 String for ATProto $bytes fields
        let commitBase64 = commit?.base64EncodedString()
        let welcomeBase64 = welcomeMessage?.base64EncodedString()

        let input = BlueCatbirdMlsAddMembers.Input(
            convoId: convoId,
            idempotencyKey: idemKey,
            didList: didList,
            commit: commitBase64,
            welcomeMessage: welcomeBase64,
            keyPackageHashes: keyPackageHashes
        )
        
        do {
            let (responseCode, output) = try await client.blue.catbird.mls.addMembers(input: input)
            
            guard responseCode == 200, let output = output else {
                throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to add members")
            }
            
            logger.debug("Added members to conversation: \(convoId), new epoch: \(output.newEpoch)")
            return (output.success, output.newEpoch)
        } catch let error as ATProtoError<BlueCatbirdMlsAddMembers.Error> {
            logger.error("❌ [MLSAPIClient.addMembers] Lexicon error: \(error.error.errorName) - \(error.message ?? "no details")")
            throw MLSAPIError(from: error)
        }
    }
    
    // MARK: Messages
    
    /// Get messages from an MLS conversation using Petrel client
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - limit: Maximum number of messages to return (1-100, default: 50)
    ///   - sinceSeq: Sequence number to fetch messages after (pagination cursor). Messages with seq > sinceSeq are returned.
    /// - Returns: Tuple of messages array (guaranteed sorted by epoch ASC, seq ASC), optional lastSeq, and optional gapInfo
    /// - Note: Server GUARANTEES messages are pre-sorted by (epoch ASC, seq ASC). No client-side sorting needed.
    func getMessages(
        convoId: String,
        limit: Int = 50,
        sinceSeq: Int? = nil
    ) async throws -> (messages: [BlueCatbirdMlsDefs.MessageView], lastSeq: Int?, gapInfo: BlueCatbirdMlsGetMessages.GapInfo?) {
        logger.debug("Fetching messages for conversation: \(convoId), sinceSeq: \(sinceSeq?.description ?? "nil")")

        let input = BlueCatbirdMlsGetMessages.Parameters(
            convoId: convoId,
            limit: limit,
            sinceSeq: sinceSeq
        )

        let (responseCode, output) = try await client.blue.catbird.mls.getMessages(input: input)

        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch messages")
        }

        logger.debug("Fetched \(output.messages.count) messages, lastSeq: \(output.lastSeq?.description ?? "nil"), hasGaps: \(output.gapInfo?.hasGaps.description ?? "false")")
        return (output.messages, output.lastSeq, output.gapInfo)
    }
    
    /// Send an encrypted message to an MLS conversation using Petrel client
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - msgId: Message identifier (client-generated)
    ///   - ciphertext: MLS encrypted message ciphertext bytes (MUST be padded to paddedSize, actual size encrypted inside)
    ///   - epoch: MLS epoch number when message was encrypted
    ///   - paddedSize: Padded ciphertext size (bucket size: 512, 1024, 2048, 4096, 8192, or multiples of 8192)
    ///   - senderDid: DID of the message sender
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Tuple of messageId, receivedAt timestamp, server-assigned seq, and echoed epoch
    /// - Note: For metadata privacy, only paddedSize is sent. Actual message size is encrypted inside the MLS ciphertext.
    ///         Server now returns real seq and epoch for immediate cache updates (no placeholder seq=0).
    func sendMessage(
        convoId: String,
        msgId: String,
        ciphertext: Data,
        epoch: Int,
        paddedSize: Int,
        senderDid: DID,
        idempotencyKey: String? = nil
    ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
        let startTime = Date()
        // Generate idempotency key if not provided
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.sendMessage] START - convoId: \(convoId), msgId: \(msgId), epoch: \(epoch), ciphertext: \(ciphertext.count) bytes, paddedSize: \(paddedSize) (actual size hidden), idempotencyKey: \(idemKey)")

        let input = BlueCatbirdMlsSendMessage.Input(
            convoId: convoId,
            msgId: msgId,
            idempotencyKey: idemKey,
            ciphertext: Bytes(data: ciphertext),
            epoch: epoch,
            paddedSize: paddedSize
        )

        logger.debug("📍 [MLSAPIClient.sendMessage] Calling API...")
        let (responseCode, output) = try await client.blue.catbird.mls.sendMessage(input: input)

        guard responseCode == 200, let output = output else {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            logger.error("❌ [MLSAPIClient.sendMessage] HTTP \(responseCode) after \(ms)ms")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to send message")
        }

        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.info("✅ [MLSAPIClient.sendMessage] SUCCESS - msgId: \(output.messageId), seq: \(output.seq), epoch: \(output.epoch) in \(ms)ms")
        return (output.messageId, output.receivedAt, output.seq, output.epoch)
    }
    
    // MARK: Key Packages
    
    /// Publish an MLS key package using Petrel client
    /// - Parameters:
    ///   - keyPackage: Base64-encoded MLS key package
    ///   - cipherSuite: Cipher suite of the key package (e.g., "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    ///   - expiresAt: Optional expiration timestamp
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success (empty response from server)
    func publishKeyPackage(
        keyPackage: Data,
        cipherSuite: String,
        expiresAt: ATProtocolDate? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        // Generate idempotency key if not provided
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.debug("Publishing key package with cipher suite: \(cipherSuite), \(keyPackage.count) bytes, idempotencyKey: \(idemKey)")

        // Encode Data to base64 String for ATProto $bytes field
        let keyPackageBase64 = keyPackage.base64EncodedString()

        let input = BlueCatbirdMlsPublishKeyPackage.Input(
            keyPackage: keyPackageBase64,
            idempotencyKey: idemKey,
            cipherSuite: cipherSuite,
            expires: expiresAt
        )

        let (responseCode, _) = try await client.blue.catbird.mls.publishKeyPackage(input: input)

        guard responseCode == 200 else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to publish key package")
        }

        logger.debug("Published key package successfully")
    }
    
    /// Get key packages for one or more DIDs using Petrel client
    /// - Parameters:
    ///   - dids: Array of DIDs to fetch key packages for
    ///   - cipherSuite: Optional filter by cipher suite (e.g., "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    /// - Returns: Tuple of available key packages and missing DIDs
    func getKeyPackages(
        dids: [DID],
        cipherSuite: String? = nil
    ) async throws -> (keyPackages: [BlueCatbirdMlsDefs.KeyPackageRef], missing: [DID]?) {
        logger.info("🌐 [MLSAPIClient.getKeyPackages] START - dids: \(dids.count), cipherSuite: \(cipherSuite ?? "omitted")")
        
        let input = BlueCatbirdMlsGetKeyPackages.Parameters(
            dids: dids,
            cipherSuite: cipherSuite
        )
        
        logger.debug("📍 [MLSAPIClient.getKeyPackages] Calling API...")
        let (responseCode, output) = try await client.blue.catbird.mls.getKeyPackages(input: input)
        
        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getKeyPackages] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch key packages")
        }

        // 🛡️ Deduplicate identical key package payloads (same DID + identical bundle)
        var seenPackages = Set<String>()
        let dedupedPackages = output.keyPackages.filter { kp in
            let signature = "\(kp.did.description)#\(kp.keyPackage)"
            if seenPackages.contains(signature) {
                logger.warning("⚠️ [MLSAPIClient.getKeyPackages] Duplicate key package payload detected for DID: \(kp.did)")
                return false
            }

            seenPackages.insert(signature)
            return true
        }

        let duplicateCount = output.keyPackages.count - dedupedPackages.count
        if duplicateCount > 0 {
            logger.warning("⚠️ [MLSAPIClient.getKeyPackages] Removed \(duplicateCount) duplicate payload(s); retained \(dedupedPackages.count)")
        }

        logger.info("✅ [MLSAPIClient.getKeyPackages] SUCCESS - \(dedupedPackages.count) unique packages after deduplication, missing: \(output.missing?.count ?? 0)")
        return (dedupedPackages, output.missing)
    }

    // MARK: Epoch Synchronization
    
    /// Get the current epoch for a conversation
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Current epoch number
    func getEpoch(convoId: String) async throws -> Int {
        logger.debug("Fetching epoch for conversation: \(convoId)")
        
        let input = BlueCatbirdMlsGetEpoch.Parameters(convoId: convoId)
        
        let (responseCode, output) = try await client.blue.catbird.mls.getEpoch(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch epoch")
        }
        
        logger.debug("Current epoch for \(convoId): \(output.currentEpoch)")
        return output.currentEpoch
    }
    
    /// Get commit messages within an epoch range
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - fromEpoch: Starting epoch (inclusive)
    ///   - toEpoch: Ending epoch (inclusive), defaults to current epoch if nil
    /// - Returns: Array of commit messages
    func getCommits(
        convoId: String,
        fromEpoch: Int,
        toEpoch: Int? = nil
    ) async throws -> [BlueCatbirdMlsGetCommits.CommitMessage] {
        logger.debug("Fetching commits for \(convoId) from epoch \(fromEpoch) to \(toEpoch?.description ?? "current")")

        let input = BlueCatbirdMlsGetCommits.Parameters(
            convoId: convoId,
            fromEpoch: fromEpoch,
            toEpoch: toEpoch
        )

        let (responseCode, output) = try await client.blue.catbird.mls.getCommits(input: input)

        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch commits")
        }

        logger.debug("Fetched \(output.commits.count) commits")
        return output.commits
    }

    /// Get Welcome message for joining a conversation
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Welcome message data
    func getWelcome(convoId: String) async throws -> Data {
        logger.debug("Fetching Welcome message for conversation: \(convoId)")

        let input = BlueCatbirdMlsGetWelcome.Parameters(convoId: convoId)

        let (responseCode, output) = try await client.blue.catbird.mls.getWelcome(input: input)

        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch Welcome message")
        }

        // Decode base64 String from ATProto $bytes field to Data
        guard let welcomeData = Data(base64Encoded: output.welcome) else {
            throw MLSAPIError.invalidResponse(message: "Invalid base64 in welcome message")
        }

        logger.debug("Fetched Welcome message for \(convoId), \(welcomeData.count) bytes")
        return welcomeData
    }

    /// Confirm successful or failed processing of Welcome message (two-phase commit)
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - success: Whether Welcome was processed successfully
    ///   - errorMessage: Optional error details if success=false
    ///   - maxRetries: Maximum number of retries for transient errors (default: 3)
    func confirmWelcome(
        convoId: String,
        success: Bool,
        errorMessage: String? = nil,
        maxRetries: Int = 3
    ) async throws {
        logger.info("📤 [confirmWelcome] START - convoId: \(convoId), success: \(success)")
        if let error = errorMessage {
            logger.debug("   Error details: \(error)")
        }

        let input = BlueCatbirdMlsConfirmWelcome.Input(
            convoId: convoId,
            success: success,
            errorDetails: errorMessage
        )

        // CRITICAL FIX: Retry on transient errors (502, 503, 504)
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            logger.debug("📡 [confirmWelcome] Attempt \(attempt)/\(maxRetries) - calling server...")
            
            do {
                let (responseCode, _) = try await client.blue.catbird.mls.confirmWelcome(input: input)
                
                logger.debug("📡 [confirmWelcome] Server response: HTTP \(responseCode)")
                
                guard responseCode == 200 else {
                    // Check if this is a transient error worth retrying
                    let isTransient = responseCode == 502 || responseCode == 503 || responseCode == 504
                    
                    if isTransient && attempt < maxRetries {
                        logger.warning("⚠️ [confirmWelcome] Transient error \(responseCode) on attempt \(attempt)/\(maxRetries), retrying...")
                        
                        // Exponential backoff: 1s, 2s, 4s
                        let delay = TimeInterval(1 << (attempt - 1))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    
                    logger.error("❌ [confirmWelcome] Failed with HTTP \(responseCode) on attempt \(attempt)/\(maxRetries)")
                    throw MLSAPIError.httpError(statusCode: responseCode, message: "confirmWelcome failed with HTTP \(responseCode)")
                }
                
                logger.info("✅ [confirmWelcome] SUCCESS - confirmation sent after \(attempt) attempt(s)")
                return
                
            } catch let error as MLSAPIError {
                logger.error("❌ [confirmWelcome] MLSAPIError on attempt \(attempt)/\(maxRetries): \(error.localizedDescription)")
                lastError = error
                
                // If it's a non-retryable error, throw immediately
                if case .httpError(let statusCode, _) = error {
                    let isTransient = statusCode == 502 || statusCode == 503 || statusCode == 504
                    if !isTransient || attempt >= maxRetries {
                        logger.error("❌ [confirmWelcome] Non-retryable or exhausted retries - throwing error")
                        throw error
                    }
                    logger.warning("⚠️ [confirmWelcome] Transient error \(statusCode), retrying after backoff...")
                    let delay = TimeInterval(1 << (attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    logger.error("❌ [confirmWelcome] Non-HTTP error - throwing immediately")
                    throw error
                }
            } catch {
                logger.error("❌ [confirmWelcome] Unknown error on attempt \(attempt)/\(maxRetries): \(error.localizedDescription)")
                logger.error("   Error type: \(type(of: error))")
                lastError = error
                
                // Network errors might be transient, retry
                if attempt < maxRetries {
                    logger.warning("⚠️ [confirmWelcome] Network/unknown error, retrying after backoff...")
                    let delay = TimeInterval(1 << (attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    logger.error("❌ [confirmWelcome] Exhausted all retry attempts - throwing error")
                    throw error
                }
            }
        }
        
        // If we exhausted all retries, throw the last error
        if let error = lastError {
            logger.error("❌ [confirmWelcome] FAILED after \(maxRetries) attempts - last error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Request to rejoin an MLS conversation after local state loss
    /// - Parameters:
    ///   - convoId: Conversation identifier to rejoin
    ///   - keyPackageData: Fresh MLS KeyPackage data for re-adding to the group
    ///   - reason: Optional reason for rejoin request
    /// - Returns: Request ID and pending status
    func requestRejoin(
        convoId: String,
        keyPackageData: Data,
        reason: String? = nil
    ) async throws -> (requestId: String, pending: Bool) {
        logger.info("📤 [requestRejoin] Requesting rejoin for conversation: \(convoId)")

        // Encode KeyPackage as base64url (no padding)
        let keyPackageBase64 = keyPackageData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let input = BlueCatbirdMlsRequestRejoin.Input(
            convoId: convoId,
            keyPackage: keyPackageBase64,
            reason: reason
        )

        let (responseCode, output) = try await client.blue.catbird.mls.requestRejoin(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [requestRejoin] Failed with HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "requestRejoin failed")
        }

        logger.info("✅ [requestRejoin] SUCCESS - requestId: \(output.requestId), pending: \(output.pending)")
        return (requestId: output.requestId, pending: output.pending)
    }

    // MARK: - Admin Operations

    /// Remove a member from conversation (admin-only operation)
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - targetDid: DID of member to remove
    ///   - reason: Optional reason for removal
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success status and epoch hint
    func removeMember(
        convoId: String,
        targetDid: DID,
        reason: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> (ok: Bool, epochHint: Int) {
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.removeMember] START - convoId: \(convoId), targetDid: \(targetDid), idempotencyKey: \(idemKey)")

        let input = BlueCatbirdMlsRemoveMember.Input(
            convoId: convoId,
            targetDid: targetDid,
            idempotencyKey: idemKey,
            reason: reason
        )

        let (responseCode, output) = try await client.blue.catbird.mls.removeMember(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.removeMember] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to remove member")
        }

        logger.info("✅ [MLSAPIClient.removeMember] SUCCESS - epochHint: \(output.epochHint)")
        return (output.ok, output.epochHint)
    }

    /// Promote a member to admin status
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - targetDid: DID of member to promote
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success status
    func promoteAdmin(
        convoId: String,
        targetDid: DID,
        idempotencyKey: String? = nil
    ) async throws -> Bool {
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.promoteAdmin] START - convoId: \(convoId), targetDid: \(targetDid), idempotencyKey: \(idemKey)")

        let input = BlueCatbirdMlsPromoteAdmin.Input(
            convoId: convoId,
            targetDid: targetDid
        )

        let (responseCode, output) = try await client.blue.catbird.mls.promoteAdmin(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.promoteAdmin] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to promote admin")
        }

        logger.info("✅ [MLSAPIClient.promoteAdmin] SUCCESS")
        return output.ok
    }

    /// Demote an admin to regular member status
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - targetDid: DID of admin to demote
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success status
    func demoteAdmin(
        convoId: String,
        targetDid: DID,
        idempotencyKey: String? = nil
    ) async throws -> Bool {
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.demoteAdmin] START - convoId: \(convoId), targetDid: \(targetDid), idempotencyKey: \(idemKey)")

        let input = BlueCatbirdMlsDemoteAdmin.Input(
            convoId: convoId,
            targetDid: targetDid
        )

        let (responseCode, output) = try await client.blue.catbird.mls.demoteAdmin(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.demoteAdmin] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to demote admin")
        }

        logger.info("✅ [MLSAPIClient.demoteAdmin] SUCCESS")
        return output.ok
    }

    // MARK: - Moderation

    /// Report a member for ToS violations
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - targetDid: DID of member to report
    ///   - reason: Reason for report (e.g., "harassment", "spam", "inappropriate")
    ///   - details: Optional additional details about the report
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Report ID
    func reportMember(
        convoId: String,
        targetDid: DID,
        reason: String,
        details: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> String {
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.reportMember] START - convoId: \(convoId), targetDid: \(targetDid), reason: \(reason), idempotencyKey: \(idemKey)")

        // Encode details as encrypted content using Bytes
        let detailsData = (details ?? "").data(using: .utf8) ?? Data()
        let encryptedContent = Bytes(data: detailsData)

        let input = BlueCatbirdMlsReportMember.Input(
            convoId: convoId,
            reportedDid: targetDid,
            category: reason,
            encryptedContent: encryptedContent,
            messageIds: nil
        )

        let (responseCode, output) = try await client.blue.catbird.mls.reportMember(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.reportMember] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to report member")
        }

        logger.info("✅ [MLSAPIClient.reportMember] SUCCESS - reportId: \(output.reportId)")
        return output.reportId
    }

    /// Get moderation reports for a conversation (admin-only)
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - limit: Maximum number of reports to return (1-100, default: 50)
    ///   - cursor: Pagination cursor from previous response
    /// - Returns: Tuple of reports array and optional next cursor
    func getReports(
        convoId: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> (reports: [BlueCatbirdMlsGetReports.ReportView], cursor: String?) {
        logger.info("🌐 [MLSAPIClient.getReports] START - convoId: \(convoId), limit: \(limit)")

        let input = BlueCatbirdMlsGetReports.Parameters(
            convoId: convoId,
            status: nil,
            limit: limit
        )

        let (responseCode, output) = try await client.blue.catbird.mls.getReports(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getReports] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch reports")
        }

        logger.info("✅ [MLSAPIClient.getReports] SUCCESS - \(output.reports.count) reports")
        return (output.reports, nil)
    }

    /// Resolve a moderation report (admin-only)
    /// - Parameters:
    ///   - reportId: Report identifier
    ///   - action: Action taken (e.g., "removed", "warned", "dismissed")
    ///   - notes: Optional notes about the resolution
    ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
    /// - Returns: Success status
    func resolveReport(
        reportId: String,
        action: String,
        notes: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Bool {
        let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
        logger.info("🌐 [MLSAPIClient.resolveReport] START - reportId: \(reportId), action: \(action), idempotencyKey: \(idemKey)")

        let input = BlueCatbirdMlsResolveReport.Input(
            reportId: reportId,
            action: action,
            notes: notes
        )

        let (responseCode, output) = try await client.blue.catbird.mls.resolveReport(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.resolveReport] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to resolve report")
        }

        logger.info("✅ [MLSAPIClient.resolveReport] SUCCESS")
        return output.ok
    }

    // MARK: - Blocking

    /// Check block relationships between users before creating conversations
    /// - Parameter dids: Array of DIDs to check for blocks
    /// - Returns: Block relationship information
    func checkBlocks(dids: [DID]) async throws -> BlueCatbirdMlsCheckBlocks.Output {
        logger.info("🌐 [MLSAPIClient.checkBlocks] START - dids: \(dids.count)")

        let input = BlueCatbirdMlsCheckBlocks.Parameters(dids: dids)

        let (responseCode, output) = try await client.blue.catbird.mls.checkBlocks(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.checkBlocks] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to check blocks")
        }

        logger.info("✅ [MLSAPIClient.checkBlocks] SUCCESS - \(output.blocks.count) blocks found")
        return output
    }

    /// Get block status for members in a conversation
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Array of block statuses
    func getBlockStatus(convoId: String) async throws -> [BlueCatbirdMlsCheckBlocks.BlockRelationship] {
        logger.info("🌐 [MLSAPIClient.getBlockStatus] START - convoId: \(convoId)")

        let input = BlueCatbirdMlsGetBlockStatus.Parameters(convoId: convoId)

        let (responseCode, output) = try await client.blue.catbird.mls.getBlockStatus(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getBlockStatus] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to get block status")
        }

        logger.info("✅ [MLSAPIClient.getBlockStatus] SUCCESS - \(output.blocks.count) blocks")
        return output.blocks
    }

    /// Handle block/unblock change from Bluesky, updating conversations automatically
    /// - Parameters:
    ///   - blockedDid: DID that was blocked or unblocked
    ///   - isBlocked: Whether the user is now blocked (true) or unblocked (false)
    /// - Returns: Array of affected conversation IDs
    func handleBlockChange(
        blockerDid: DID,
        blockedDid: DID,
        action: String
    ) async throws -> [BlueCatbirdMlsHandleBlockChange.AffectedConvo] {
        logger.info("🌐 [MLSAPIClient.handleBlockChange] START - blockerDid: \(blockerDid), blockedDid: \(blockedDid), action: \(action)")

        let input = BlueCatbirdMlsHandleBlockChange.Input(
            blockerDid: blockerDid,
            blockedDid: blockedDid,
            action: action,
            blockUri: nil
        )

        let (responseCode, output) = try await client.blue.catbird.mls.handleBlockChange(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.handleBlockChange] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to handle block change")
        }

        logger.info("✅ [MLSAPIClient.handleBlockChange] SUCCESS - \(output.affectedConvos.count) conversations affected")
        return output.affectedConvos
    }

    // MARK: - Analytics

    /// Get key package statistics for monitoring inventory health
    /// - Returns: Key package usage statistics
    func getKeyPackageStats() async throws -> BlueCatbirdMlsGetKeyPackageStats.Output {
        logger.info("🌐 [MLSAPIClient.getKeyPackageStats] START")

        let input = BlueCatbirdMlsGetKeyPackageStats.Parameters()

        let (responseCode, output) = try await client.blue.catbird.mls.getKeyPackageStats(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getKeyPackageStats] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to get key package stats")
        }

        logger.info("✅ [MLSAPIClient.getKeyPackageStats] SUCCESS - available: \(output.available), threshold: \(output.threshold)")
        return output
    }

    /// Get detailed key package status including consumption history (Phase 3)
    /// - Parameters:
    ///   - limit: Maximum number of consumed packages to return in history (1-100, default: 20)
    ///   - cursor: Pagination cursor from previous response
    /// - Returns: Key package status with available/consumed counts and history
    func getKeyPackageStatus(
        limit: Int = 20,
        cursor: String? = nil
    ) async throws -> BlueCatbirdMlsGetKeyPackageStatus.Output {
        logger.info("🌐 [MLSAPIClient.getKeyPackageStatus] START - limit: \(limit), cursor: \(cursor ?? "none")")

        let input = BlueCatbirdMlsGetKeyPackageStatus.Parameters(
            limit: limit,
            cursor: cursor
        )

        let (responseCode, output) = try await client.blue.catbird.mls.getKeyPackageStatus(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getKeyPackageStatus] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to get key package status")
        }

        logger.info("✅ [MLSAPIClient.getKeyPackageStatus] SUCCESS - available: \(output.available)/\(output.totalUploaded), consumed: \(output.consumed), reserved: \(output.reserved ?? 0)")
        return output
    }

    /// Query current key package inventory from server (simplified wrapper for upload logic)
    /// - Returns: Tuple of (available packages on server, replenishment threshold)
    /// - Throws: MLSAPIError if query fails
    func queryKeyPackageInventory() async throws -> (available: Int, threshold: Int) {
        logger.info("🔍 [MLSAPIClient.queryInventory] Querying server key package inventory")

        let stats = try await getKeyPackageStats()
        let available = stats.available
        let threshold = stats.threshold

        logger.info("📊 [MLSAPIClient.queryInventory] Server inventory - available: \(available), threshold: \(threshold)")
        return (available, threshold)
    }

    /// Publish multiple key packages in a single batch request (preferred over individual uploads)
    /// - Parameter packages: Array of key package data to upload (max 100 per batch)
    /// - Returns: Batch result with success/failure counts
    func publishKeyPackagesBatch(_ packages: [MLSKeyPackageUploadData]) async throws -> KeyPackageBatchResult {
        logger.info("🌐 [MLSAPIClient.publishKeyPackagesBatch] START - count: \(packages.count)")

        // Validate batch size
        guard packages.count <= 100 else {
            logger.error("❌ Batch size \(packages.count) exceeds maximum of 100")
            throw MLSAPIError.invalidBatchSize
        }

        // Use the real batch endpoint
        return try await publishKeyPackagesBatchDirect(packages)
    }

    /// Direct batch upload using blue.catbird.mls.publishKeyPackages endpoint
    private func publishKeyPackagesBatchDirect(_ packages: [MLSKeyPackageUploadData]) async throws -> KeyPackageBatchResult {
        logger.info("🌐 [MLSAPIClient.publishKeyPackagesBatchDirect] Using real batch endpoint - count: \(packages.count)")

        // Convert custom types to generated types
        let keyPackageItems = packages.map { pkg in
            BlueCatbirdMlsPublishKeyPackages.KeyPackageItem(
                keyPackage: pkg.keyPackage,
                cipherSuite: pkg.cipherSuite,
                expires: pkg.expires.map { ATProtocolDate(date: $0) } ?? ATProtocolDate(date: Date().addingTimeInterval(90 * 24 * 60 * 60)),
                idempotencyKey: pkg.idempotencyKey
            )
        }

        let input = BlueCatbirdMlsPublishKeyPackages.Input(keyPackages: keyPackageItems)

        let (responseCode, output) = try await client.blue.catbird.mls.publishKeyPackages(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.publishKeyPackagesBatchDirect] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Batch upload failed")
        }

        // Convert generated types back to custom result type
        let errors = output.errors?.map { genError in
            BatchUploadError(index: genError.index, error: genError.error)
        }

        logger.info("✅ [MLSAPIClient.publishKeyPackagesBatchDirect] SUCCESS - succeeded: \(output.succeeded), failed: \(output.failed)")
        return KeyPackageBatchResult(succeeded: output.succeeded, failed: output.failed, errors: errors)
    }

    /// Fallback: Upload packages individually with concurrent batching
    private func publishKeyPackagesFallback(_ packages: [MLSKeyPackageUploadData]) async throws -> KeyPackageBatchResult {
        var succeeded = 0
        var failed = 0
        var errors: [BatchUploadError] = []

        // Upload in concurrent batches of 5 to avoid overwhelming the server
        let batchSize = 5

        for batchIndex in stride(from: 0, to: packages.count, by: batchSize) {
            let endIndex = min(batchIndex + batchSize, packages.count)
            let batch = Array(packages[batchIndex..<endIndex])

            await withTaskGroup(of: (index: Int, success: Bool, error: String?).self) { group in
                for (offset, package) in batch.enumerated() {
                    let globalIndex = batchIndex + offset
                    group.addTask {
                        do {
                            // Decode base64 back to Data for existing publishKeyPackage method
                            guard let keyPackageData = Data(base64Encoded: package.keyPackage) else {
                                return (globalIndex, false, "Invalid base64 encoding")
                            }

                            try await self.publishKeyPackage(
                                keyPackage: keyPackageData,
                                cipherSuite: package.cipherSuite,
                                expiresAt: package.expires.map { ATProtocolDate(date: $0) },
                                idempotencyKey: package.idempotencyKey
                            )

                            return (globalIndex, true, nil)
                        } catch {
                            return (globalIndex, false, error.localizedDescription)
                        }
                    }
                }

                for await result in group {
                    if result.success {
                        succeeded += 1
                    } else {
                        failed += 1
                        if let errorMsg = result.error {
                            errors.append(BatchUploadError(index: result.index, error: errorMsg))
                        }
                    }
                }
            }

            // Small delay between batches to avoid rate limiting
            if endIndex < packages.count {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        logger.info("✅ [MLSAPIClient.publishKeyPackagesBatch] COMPLETE - succeeded: \(succeeded), failed: \(failed)")

        return KeyPackageBatchResult(succeeded: succeeded, failed: failed, errors: errors.isEmpty ? nil : errors)
    }

    /// Get admin statistics for a conversation (admin-only)
    /// - Parameter convoId: Conversation identifier
    /// - Returns: Admin statistics including member counts, message activity, and moderation metrics
    func getAdminStats(convoId: String) async throws -> BlueCatbirdMlsGetAdminStats.Output {
        logger.info("🌐 [MLSAPIClient.getAdminStats] START - convoId: \(convoId)")

        let input = BlueCatbirdMlsGetAdminStats.Parameters(convoId: convoId)

        let (responseCode, output) = try await client.blue.catbird.mls.getAdminStats(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ [MLSAPIClient.getAdminStats] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to get admin stats")
        }

        logger.info("✅ [MLSAPIClient.getAdminStats] SUCCESS")
        return output
    }

    // NOTE: Text-only PostgreSQL architecture (no CloudKit/R2 dependencies)
    // Message embeds are now fully encrypted within the ciphertext payload
    // Supported embed types (encrypted in MLSMessagePayload):
    //   - recordEmbed: Bluesky post quote embeds (AT-URI references)
    //   - linkEmbed: External link previews
    //   - gifEmbed: Tenor GIF embeds (MP4 format)
    // See blue.catbird.mls.message.defs#payloadView for encrypted structure
}

// MARK: - Error Types

/// MLS API error types
enum MLSAPIError: Error, LocalizedError {
    case noAuthentication
    case accountMismatch(authenticated: String, expected: String)
    case invalidResponse(message: String = "Invalid response")
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case messageTooLarge
    case serverUnavailable
    case methodNotImplemented
    case invalidBatchSize
    case unknownError
    case keyPackageNotFound(detail: String?)
    case invalidCipherSuite(detail: String?)
    case tooManyMembers(detail: String?)
    case mutualBlockDetected(detail: String?)
    case conversationNotFound(detail: String?)
    case notConversationMember(detail: String?)
    case memberAlreadyExists(detail: String?)
    case memberBlocked(detail: String?)

    var errorDescription: String? {
        switch self {
        case .noAuthentication:
            return "Authentication required for MLS API requests"
        case .accountMismatch(let authenticated, let expected):
            return "Account mismatch: authenticated as \(authenticated) but expected \(expected)"
        case .invalidResponse:
            return "Invalid response from MLS API"
        case .httpError(let statusCode, let message):
            return "MLS API error (HTTP \(statusCode)): \(message)"
        case .decodingError(let error):
            return "Failed to decode MLS API response: \(error.localizedDescription)"
        case .messageTooLarge:
            return "Message ciphertext exceeds maximum size of 10MB"
        case .serverUnavailable:
            return "MLS server is unavailable or not responding"
        case .methodNotImplemented:
            return "Method not implemented by server (requires server update)"
        case .invalidBatchSize:
            return "Batch size exceeds maximum of 100 key packages"
        case .unknownError:
            return "Unknown MLS API error occurred"
        case .keyPackageNotFound(let detail):
            return detail ?? "Referenced key package was not available on the server"
        case .invalidCipherSuite(let detail):
            return detail ?? "The MLS cipher suite is not supported by the server"
        case .tooManyMembers(let detail):
            return detail ?? "Adding these members would exceed the maximum allowed"
        case .mutualBlockDetected(let detail):
            return detail ?? "Members cannot be added due to Bluesky block relationships"
        case .conversationNotFound(let detail):
            return detail ?? "Conversation not found on server"
        case .notConversationMember(let detail):
            return detail ?? "Caller is not a member of this conversation"
        case .memberAlreadyExists(let detail):
            return detail ?? "One or more members are already part of the conversation"
        case .memberBlocked(let detail):
            return detail ?? "Cannot add user who is blocked or has blocked an existing member"
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .serverUnavailable:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500
        default:
            return false
        }
    }
}

private extension MLSAPIError {
    init(from error: ATProtoError<BlueCatbirdMlsCreateConvo.Error>) {
        let detail = error.message
        switch error.error {
        case .keyPackageNotFound:
            self = .keyPackageNotFound(detail: detail)
        case .invalidCipherSuite:
            self = .invalidCipherSuite(detail: detail)
        case .tooManyMembers:
            self = .tooManyMembers(detail: detail)
        case .mutualBlockDetected:
            self = .mutualBlockDetected(detail: detail)
        }
    }

    init(from error: ATProtoError<BlueCatbirdMlsAddMembers.Error>) {
        let detail = error.message
        switch error.error {
        case .convoNotFound:
            self = .conversationNotFound(detail: detail)
        case .notMember:
            self = .notConversationMember(detail: detail)
        case .keyPackageNotFound:
            self = .keyPackageNotFound(detail: detail)
        case .alreadyMember:
            self = .memberAlreadyExists(detail: detail)
        case .tooManyMembers:
            self = .tooManyMembers(detail: detail)
        case .blockedByMember:
            self = .memberBlocked(detail: detail)
        }
    }
}

// MARK: - MLSAPIClient SSE Event Stream Extension

extension MLSAPIClient {
    /// Stream real-time conversation events via Server-Sent Events (SSE)
    /// - Parameters:
    ///   - convoId: ID of the conversation to stream events for
    ///   - cursor: Optional cursor for resuming from last position
    /// - Returns: AsyncThrowingStream of conversation events
    func streamConvoEvents(convoId: String, cursor: String? = nil) async throws -> AsyncThrowingStream<BlueCatbirdMlsStreamConvoEvents.Output, Error> {
        let input = BlueCatbirdMlsStreamConvoEvents.Parameters(cursor: cursor, convoId: convoId)

        // Petrel now returns AsyncThrowingStream directly for SSE endpoints
        return try await self.client.blue.catbird.mls.streamConvoEvents(input: input)
    }
}

// NOTE: All model types now use BlueCatbirdMls* models from Petrel package
// Updated for text-only PostgreSQL architecture (no CloudKit/R2 dependencies):
// - BlueCatbirdMlsDefs.ConvoView: Conversation with MLS group info
// - BlueCatbirdMlsDefs.MessageView: Encrypted message with optional embeds (Tenor, Bluesky)
// - BlueCatbirdMlsDefs.MemberView: Conversation member with MLS credentials
// - BlueCatbirdMlsDefs.KeyPackageRef: MLS key package for adding members
// - BlueCatbirdMlsDefs.ConvoMetadata: Conversation name and description (no avatar)
// - Removed: ExternalAsset, BlobRef, avatar fields (text-only system)
