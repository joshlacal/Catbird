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
        await client.setServiceDID(self.mlsServiceDID, for: "blue.catbird.mls")

        // All MLS requests go through PDS with atproto-proxy header
        // The PDS handles routing to the MLS service with proper authentication

        logger.debug("Configured MLS service DID: \(self.mlsServiceDID)")
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
    ///   - welcomeMessages: Welcome messages for initial members
    ///   - metadata: Optional conversation metadata (name, description, avatar)
    /// - Returns: Created conversation view
    func createConversation(
        groupId: String,
        cipherSuite: String,
        initialMembers: [DID]? = nil,
        welcomeMessage: String? = nil,
        metadata: BlueCatbirdMlsCreateConvo.MetadataInput? = nil
    ) async throws -> BlueCatbirdMlsDefs.ConvoView {
        logger.info("🌐 [MLSAPIClient.createConversation] START - groupId: \(groupId.prefix(16))..., members: \(initialMembers?.count ?? 0)")

        let input = BlueCatbirdMlsCreateConvo.Input(
            groupId: groupId,
            cipherSuite: cipherSuite,
            initialMembers: initialMembers,
            welcomeMessage: welcomeMessage,
            metadata: metadata
        )

        logger.debug("📍 [MLSAPIClient.createConversation] Calling API...")
        let (responseCode, output) = try await client.blue.catbird.mls.createConvo(input: input)

        guard responseCode == 200, let convoView = output else {
            logger.error("❌ [MLSAPIClient.createConversation] HTTP \(responseCode)")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to create conversation")
        }

        logger.info("✅ [MLSAPIClient.createConversation] SUCCESS - convoId: \(convoView.id), epoch: \(convoView.epoch)")
        return convoView
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
    ///   - commit: Optional base64url-encoded MLS Commit message
    ///   - welcomeMessages: Welcome messages for new members
    /// - Returns: Success status and new epoch number
    func addMembers(
        convoId: String,
        didList: [DID],
        commit: String? = nil,
        welcomeMessage: String? = nil
    ) async throws -> (success: Bool, newEpoch: Int) {
        logger.debug("Adding \(didList.count) members to conversation: \(convoId)")

        let input = BlueCatbirdMlsAddMembers.Input(
            convoId: convoId,
            didList: didList,
            commit: commit,
            welcomeMessage: welcomeMessage
        )
        
        let (responseCode, output) = try await client.blue.catbird.mls.addMembers(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to add members")
        }
        
        logger.debug("Added members to conversation: \(convoId), new epoch: \(output.newEpoch)")
        return (output.success, output.newEpoch)
    }
    
    // MARK: Messages
    
    /// Get messages from an MLS conversation using Petrel client
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - limit: Maximum number of messages to return (1-100, default: 50)
    ///   - sinceMessage: Message ID to fetch messages after (pagination cursor)
    /// - Returns: Tuple of messages array and optional next cursor
    func getMessages(
        convoId: String,
        limit: Int = 50,
        sinceMessage: String? = nil
    ) async throws -> (messages: [BlueCatbirdMlsDefs.MessageView], cursor: String?) {
        logger.debug("Fetching messages for conversation: \(convoId)")
        
        let input = BlueCatbirdMlsGetMessages.Parameters(
            convoId: convoId,
            limit: limit,
            sinceMessage: sinceMessage
        )
        
        let (responseCode, output) = try await client.blue.catbird.mls.getMessages(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch messages")
        }
        
        logger.debug("Fetched \(output.messages.count) messages")
        return (output.messages, output.cursor)
    }
    
    /// Send an encrypted message to an MLS conversation using Petrel client
    /// - Parameters:
    ///   - convoId: Conversation identifier
    ///   - ciphertext: MLS encrypted message ciphertext bytes
    ///   - epoch: MLS epoch number when message was encrypted
    ///   - senderDid: DID of the message sender
    ///   - embedType: Optional embed type (e.g., 'tenor', 'bsky_post', 'link')
    ///   - embedUri: Optional embed URI reference (Tenor URL, AT-URI for Bluesky posts)
    /// - Returns: Message ID and received timestamp
    func sendMessage(
        convoId: String,
        ciphertext: Data,
        epoch: Int,
        senderDid: DID,
        embedType: String? = nil,
        embedUri: URI? = nil
    ) async throws -> (messageId: String, receivedAt: ATProtocolDate) {
        let startTime = Date()
        logger.info("🌐 [MLSAPIClient.sendMessage] START - convoId: \(convoId), epoch: \(epoch), ciphertext: \(ciphertext.count) bytes, embedType: \(embedType ?? "none")")
        
        let input = BlueCatbirdMlsSendMessage.Input(
            convoId: convoId,
            ciphertext: Bytes(data: ciphertext),
            epoch: epoch,
            senderDid: senderDid,
            embedType: embedType,
            embedUri: embedUri
        )
        
        logger.debug("📍 [MLSAPIClient.sendMessage] Calling API...")
        let (responseCode, output) = try await client.blue.catbird.mls.sendMessage(input: input)
        
        guard responseCode == 200, let output = output else {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            logger.error("❌ [MLSAPIClient.sendMessage] HTTP \(responseCode) after \(ms)ms")
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to send message")
        }
        
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.info("✅ [MLSAPIClient.sendMessage] SUCCESS - msgId: \(output.messageId) in \(ms)ms")
        return (output.messageId, output.receivedAt)
    }
    
    // MARK: Key Packages
    
    /// Publish an MLS key package using Petrel client
    /// - Parameters:
    ///   - keyPackage: Base64-encoded MLS key package
    ///   - cipherSuite: Cipher suite of the key package (e.g., "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    ///   - expiresAt: Optional expiration timestamp
    /// - Returns: Success (empty response from server)
    func publishKeyPackage(
        keyPackage: String,
        cipherSuite: String,
        expiresAt: ATProtocolDate? = nil
    ) async throws {
        logger.debug("Publishing key package with cipher suite: \(cipherSuite)")
        
        let input = BlueCatbirdMlsPublishKeyPackage.Input(
            keyPackage: keyPackage,
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
        
        logger.info("✅ [MLSAPIClient.getKeyPackages] SUCCESS - \(output.keyPackages.count) packages, missing: \(output.missing?.count ?? 0)")
        return (output.keyPackages, output.missing)
    }

    /// Publish a key package to the server
    /// - Parameters:
    ///   - keyPackage: Base64url-encoded key package data
    ///   - cipherSuite: Cipher suite identifier
    ///   - expires: Expiration timestamp (max 90 days from now)
    func publishKeyPackage(
        keyPackage: String,
        cipherSuite: String,
        expires: Date
    ) async throws {
        logger.debug("Publishing key package with cipher suite: \(cipherSuite)")

        let input = BlueCatbirdMlsPublishKeyPackage.Input(
            keyPackage: keyPackage,
            cipherSuite: cipherSuite,
            expires: ATProtocolDate(date: expires)
        )

        let (responseCode, _) = try await client.blue.catbird.mls.publishKeyPackage(input: input)

        guard responseCode == 200 else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to publish key package")
        }

        logger.debug("Successfully published key package")
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
    /// - Returns: Base64url-encoded Welcome message data
    func getWelcome(convoId: String) async throws -> String {
        logger.debug("Fetching Welcome message for conversation: \(convoId)")

        let input = BlueCatbirdMlsGetWelcome.Parameters(convoId: convoId)

        let (responseCode, output) = try await client.blue.catbird.mls.getWelcome(input: input)

        guard responseCode == 200, let output = output else {
            throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch Welcome message")
        }

        logger.debug("Fetched Welcome message for \(convoId)")
        return output.welcome
    }

    // NOTE: Blob upload has been removed in the new text-only PostgreSQL architecture
    // Messages now support embeds via embedType and embedUri parameters
    // Supported embed types:
    //   - 'tenor': Tenor GIF URLs
    //   - 'bsky_post': Bluesky post AT-URIs
    //   - 'link': Generic web links
}

// MARK: - Error Types

/// MLS API error types
enum MLSAPIError: Error, LocalizedError {
    case noAuthentication
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case messageTooLarge
    case serverUnavailable
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .noAuthentication:
            return "Authentication required for MLS API requests"
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
        case .unknownError:
            return "Unknown MLS API error occurred"
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

// MARK: - MLSAPIClient SSE Event Stream Extension

extension MLSAPIClient {
    /// Stream real-time conversation events via Server-Sent Events (SSE)
    /// - Parameters:
    ///   - convoId: ID of the conversation to stream events for
    ///   - cursor: Optional cursor for resuming from last position
    /// - Returns: AsyncThrowingStream of conversation events
    func streamConvoEvents(convoId: String, cursor: String? = nil) async throws -> AsyncThrowingStream<BlueCatbirdMlsStreamConvoEvents.Output, Error> {
        let input = BlueCatbirdMlsStreamConvoEvents.Parameters(cursor: cursor, convoId: convoId)
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
