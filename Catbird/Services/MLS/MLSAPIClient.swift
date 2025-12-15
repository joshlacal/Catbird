import CatbirdMLSCore
import CryptoKit
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
  let client: ATProtoClient

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

    // Note: A dedicated health endpoint would be more efficient, but listing
    // conversations with limit=1 works as a connectivity check
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
    logger.info(
      "🌐 [MLSAPIClient.getConversations] START - limit: \(limit), cursor: \(cursor ?? "none")")

    let input = BlueCatbirdMlsGetConvos.Parameters(
      limit: limit,
      cursor: cursor
    )

    logger.debug("📍 [MLSAPIClient.getConversations] Calling API...")
    let (responseCode, output) = try await client.blue.catbird.mls.getConvos(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.getConversations] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to fetch conversations")
    }

    logger.info(
      "✅ [MLSAPIClient.getConversations] SUCCESS - \(output.conversations.count) conversations, nextCursor: \(output.cursor ?? "none")"
    )
    return (output.conversations, output.cursor)
  }

  // MARK: - Chat Requests (Request Mailbox)

  /// Get the count of pending MLS chat requests for badge display.
  func getChatRequestCount() async throws -> BlueCatbirdMlsGetRequestCount.Output {
    logger.info("🌐 [MLSAPIClient.getChatRequestCount] START")

    let (responseCode, output) = try await client.blue.catbird.mls.getRequestCount()

    guard (200...299).contains(responseCode), let output else {
      logger.error("❌ [MLSAPIClient.getChatRequestCount] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to fetch chat request count")
    }

    logger.info(
      "✅ [MLSAPIClient.getChatRequestCount] SUCCESS - pendingCount: \(output.pendingCount)")
    return output
  }

  /// List MLS chat requests received by the authenticated user.
  func listChatRequests(
    limit: Int = 50,
    cursor: String? = nil,
    status: String? = nil
  ) async throws -> (requests: [BlueCatbirdMlsListChatRequests.ChatRequest], cursor: String?) {
    logger.info(
      "🌐 [MLSAPIClient.listChatRequests] START - limit: \(limit), cursor: \(cursor ?? "none"), status: \(status ?? "default")"
    )

    let input = BlueCatbirdMlsListChatRequests.Parameters(
      cursor: cursor,
      limit: limit,
      status: status
    )

    let (responseCode, output) = try await client.blue.catbird.mls.listChatRequests(input: input)

    guard (200...299).contains(responseCode), let output else {
      logger.error("❌ [MLSAPIClient.listChatRequests] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to list chat requests")
    }

    logger.info(
      "✅ [MLSAPIClient.listChatRequests] SUCCESS - \(output.requests.count) requests, nextCursor: \(output.cursor ?? "none")"
    )
    return (output.requests, output.cursor)
  }

  /// Accept a pending MLS chat request.
  func acceptChatRequest(
    requestId: String,
    welcomeData: Data? = nil
  ) async throws -> BlueCatbirdMlsAcceptChatRequest.Output {
    logger.info("🌐 [MLSAPIClient.acceptChatRequest] START - requestId: \(requestId)")

    let input = BlueCatbirdMlsAcceptChatRequest.Input(
      requestId: requestId,
      welcomeData: welcomeData.map { Bytes(data: $0) }
    )

    let (responseCode, output) = try await client.blue.catbird.mls.acceptChatRequest(input: input)

    guard (200...299).contains(responseCode), let output else {
      logger.error("❌ [MLSAPIClient.acceptChatRequest] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to accept chat request")
    }

    logger.info("✅ [MLSAPIClient.acceptChatRequest] SUCCESS - convoId: \(output.convoId)")
    return output
  }

  /// Decline a pending MLS chat request.
  func declineChatRequest(
    requestId: String,
    reportReason: String? = nil,
    reportDetails: String? = nil
  ) async throws -> Bool {
    logger.info("🌐 [MLSAPIClient.declineChatRequest] START - requestId: \(requestId)")

    let input = BlueCatbirdMlsDeclineChatRequest.Input(
      requestId: requestId,
      reportReason: reportReason,
      reportDetails: reportDetails
    )

    let (responseCode, output) = try await client.blue.catbird.mls.declineChatRequest(input: input)

    guard (200...299).contains(responseCode), let output else {
      logger.error("❌ [MLSAPIClient.declineChatRequest] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to decline chat request")
    }

    logger.info("✅ [MLSAPIClient.declineChatRequest] SUCCESS")
    return output.success
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
    logger.info(
      "🌐 [MLSAPIClient.createConversation] START - groupId: \(groupId.prefix(16))..., members: \(initialMembers?.count ?? 0), hashes: \(keyPackageHashes?.count ?? 0), idempotencyKey: \(idemKey)"
    )

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
        logger.error(
          "❌ [MLSAPIClient.createConversation] HTTP \(responseCode) - no structured error caught")
        throw MLSAPIError.httpError(
          statusCode: responseCode, message: "Failed to create conversation")
      }

      logger.info(
        "✅ [MLSAPIClient.createConversation] SUCCESS - convoId: \(convoView.groupId), epoch: \(convoView.epoch)"
      )
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
    logger.debug(
      "Adding \(didList.count) members to conversation: \(convoId), hashes: \(keyPackageHashes?.count ?? 0), idempotencyKey: \(idemKey)"
    )

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
      logger.error(
        "❌ [MLSAPIClient.addMembers] Lexicon error: \(error.error.errorName) - \(error.message ?? "no details")"
      )
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
  ) async throws -> (
    messages: [BlueCatbirdMlsDefs.MessageView], lastSeq: Int?,
    gapInfo: BlueCatbirdMlsGetMessages.GapInfo?
  ) {
    logger.debug(
      "Fetching messages for conversation: \(convoId), sinceSeq: \(sinceSeq?.description ?? "nil")")

    let input = BlueCatbirdMlsGetMessages.Parameters(
      convoId: convoId,
      limit: limit,
      sinceSeq: sinceSeq
    )

    let (responseCode, output) = try await client.blue.catbird.mls.getMessages(input: input)

    guard responseCode == 200, let output = output else {
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to fetch messages")
    }

    logger.debug(
      "Fetched \(output.messages.count) messages, lastSeq: \(output.lastSeq?.description ?? "nil"), hasGaps: \(output.gapInfo?.hasGaps.description ?? "false")"
    )
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
    logger.info(
      "🌐 [MLSAPIClient.sendMessage] START - convoId: \(convoId), msgId: \(msgId), epoch: \(epoch), ciphertext: \(ciphertext.count) bytes, paddedSize: \(paddedSize) (actual size hidden), idempotencyKey: \(idemKey)"
    )

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
    logger.info(
      "✅ [MLSAPIClient.sendMessage] SUCCESS - msgId: \(output.messageId), seq: \(output.seq), epoch: \(output.epoch) in \(ms)ms"
    )
    return (output.messageId, output.receivedAt, output.seq, output.epoch)
  }

  /// Mark messages as read in a conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - messageId: Optional message ID to mark as read. If nil, marks all messages as read.
  /// - Returns: The timestamp when messages were marked as read
  func updateRead(convoId: String, messageId: String? = nil) async throws -> Date {
    logger.debug(
      "Marking messages as read for conversation: \(convoId), messageId: \(messageId ?? "all")")

    let input = BlueCatbirdMlsUpdateRead.Input(
      convoId: convoId,
      messageId: messageId
    )

    let (responseCode, output) = try await client.blue.catbird.mls.updateRead(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to update read status for \(convoId): HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to update read status")
    }

    logger.debug("✅ Updated read status for \(convoId)")
    return output.readAt.date
  }

  // MARK: - Typing Indicators

  /// Send a typing indicator to a conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - isTyping: True if user started typing, false if stopped
  /// - Returns: Whether the typing indicator was sent successfully
  func sendTypingIndicator(convoId: String, isTyping: Bool) async throws -> Bool {
    logger.debug("Sending typing indicator for \(convoId): isTyping=\(isTyping)")

    let input = BlueCatbirdMlsSendTypingIndicator.Input(
      convoId: convoId,
      isTyping: isTyping
    )

    let (responseCode, output) = try await client.blue.catbird.mls.sendTypingIndicator(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to send typing indicator for \(convoId): HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to send typing indicator")
    }

    logger.debug("✅ Typing indicator sent for \(convoId)")
    return output.success
  }

  // MARK: - Reactions

  /// Add a reaction (emoji) to a message
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - messageId: ID of the message to react to
  ///   - reaction: Reaction emoji or short code
  /// - Returns: Tuple of success and optional timestamp when the reaction was recorded
  func addReaction(convoId: String, messageId: String, reaction: String) async throws -> (
    success: Bool, reactedAt: Date?
  ) {
    logger.debug("Adding reaction '\(reaction)' to message \(messageId) in \(convoId)")

    let input = BlueCatbirdMlsAddReaction.Input(
      convoId: convoId,
      messageId: messageId,
      reaction: reaction
    )

    let (responseCode, output) = try await client.blue.catbird.mls.addReaction(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to add reaction for \(messageId): HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to add reaction")
    }

    logger.debug("✅ Reaction added to \(messageId)")
    return (output.success, output.reactedAt?.date)
  }

  /// Remove a reaction from a message
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - messageId: ID of the message to remove reaction from
  ///   - reaction: Reaction emoji or short code to remove
  /// - Returns: Whether the reaction was removed successfully
  func removeReaction(convoId: String, messageId: String, reaction: String) async throws -> Bool {
    logger.debug("Removing reaction '\(reaction)' from message \(messageId) in \(convoId)")

    let input = BlueCatbirdMlsRemoveReaction.Input(
      convoId: convoId,
      messageId: messageId,
      reaction: reaction
    )

    let (responseCode, output) = try await client.blue.catbird.mls.removeReaction(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to remove reaction for \(messageId): HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to remove reaction")
    }

    logger.debug("✅ Reaction removed from \(messageId)")
    return output.success
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
    logger.debug(
      "Publishing key package with cipher suite: \(cipherSuite), \(keyPackage.count) bytes, idempotencyKey: \(idemKey)"
    )

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
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to publish key package")
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
    logger.info(
      "🌐 [MLSAPIClient.getKeyPackages] START - dids: \(dids.count), cipherSuite: \(cipherSuite ?? "omitted")"
    )

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
        logger.warning(
          "⚠️ [MLSAPIClient.getKeyPackages] Duplicate key package payload detected for DID: \(kp.did)"
        )
        return false
      }

      seenPackages.insert(signature)
      return true
    }

    let duplicateCount = output.keyPackages.count - dedupedPackages.count
    if duplicateCount > 0 {
      logger.warning(
        "⚠️ [MLSAPIClient.getKeyPackages] Removed \(duplicateCount) duplicate payload(s); retained \(dedupedPackages.count)"
      )
    }

    logger.info(
      "✅ [MLSAPIClient.getKeyPackages] SUCCESS - \(dedupedPackages.count) unique packages after deduplication, missing: \(output.missing?.count ?? 0)"
    )
    return (dedupedPackages, output.missing)
  }

  // MARK: Epoch Synchronization

  /// Get GroupInfo for external commit with retry logic
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - maxRetries: Maximum number of retry attempts (default 3)
  /// - Returns: Tuple of groupInfo bytes, epoch, and expiresAt
  func getGroupInfo(convoId: String, maxRetries: Int = 3) async throws -> (
    groupInfo: Data, epoch: Int, expiresAt: Date?
  ) {
    logger.info("📥 [MLSAPIClient.getGroupInfo] START - convoId: \(convoId)")

    let input = BlueCatbirdMlsGetGroupInfo.Parameters(convoId: convoId)
    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        let (responseCode, output) = try await client.blue.catbird.mls.getGroupInfo(input: input)

        // Check for transient server errors that warrant retry
        let isTransient = [502, 503, 504].contains(responseCode)
        if isTransient && attempt < maxRetries {
          let delay = TimeInterval(attempt)
          logger.warning(
            "⚠️ [MLSAPIClient.getGroupInfo] Transient error \(responseCode) on attempt \(attempt), retrying in \(delay)s..."
          )
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        }

        guard responseCode == 200, let output = output else {
          logger.error("❌ [MLSAPIClient.getGroupInfo] HTTP \(responseCode) on attempt \(attempt)")
          throw MLSAPIError.httpError(
            statusCode: responseCode,
            message: "Failed to fetch GroupInfo after \(attempt) attempt(s)")
        }

        guard let groupInfoData = Data(base64Encoded: output.groupInfo) else {
          logger.error("❌ [MLSAPIClient.getGroupInfo] Invalid base64 in GroupInfo for \(convoId)")
          throw MLSAPIError.invalidResponse(message: "Invalid base64 in GroupInfo")
        }

        // Validate minimum size
        guard groupInfoData.count >= Self.minGroupInfoSize else {
          logger.error(
            "❌ [MLSAPIClient.getGroupInfo] GroupInfo too small: \(groupInfoData.count) bytes (minimum \(Self.minGroupInfoSize))"
          )
          throw MLSAPIError.invalidResponse(
            message: "Server returned truncated GroupInfo: \(groupInfoData.count) bytes")
        }

        // 🔒 FIX #5: Log SHA-256 checksum for debugging data corruption
        // Compare this with upload checksum to identify where corruption occurs
        let downloadChecksum = SHA256.hash(data: groupInfoData).compactMap {
          String(format: "%02x", $0)
        }.joined().prefix(16)
        logger.info(
          "📥 [MLSAPIClient.getGroupInfo] Download checksum (first 16 chars): \(downloadChecksum)")

        let expiresAt = output.expiresAt.map { $0.date }

        logger.info(
          "✅ [MLSAPIClient.getGroupInfo] Success on attempt \(attempt) - epoch: \(output.epoch), size: \(groupInfoData.count) bytes"
        )
        return (groupInfoData, Int(output.epoch), expiresAt)

      } catch let error as MLSAPIError {
        throw error  // Don't retry our own errors
      } catch {
        lastError = error
        if attempt < maxRetries {
          let delay = TimeInterval(attempt)
          logger.warning(
            "⚠️ [MLSAPIClient.getGroupInfo] Error on attempt \(attempt): \(error.localizedDescription), retrying in \(delay)s..."
          )
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } else {
          logger.error(
            "❌ [MLSAPIClient.getGroupInfo] All \(maxRetries) attempts failed for \(convoId)")
        }
      }
    }

    throw lastError
      ?? MLSAPIError.httpError(statusCode: 500, message: "All \(maxRetries) retry attempts failed")
  }

  /// Minimum valid GroupInfo size in bytes
  private static let minGroupInfoSize = 100

  /// Update GroupInfo for a conversation with retry logic and post-upload verification
  ///
  /// CRITICAL: This method now verifies the upload by fetching the stored data back.
  /// This catches network truncation issues where partial data is stored on the server.
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - groupInfo: Serialized GroupInfo bytes
  ///   - epoch: The epoch this GroupInfo corresponds to
  ///   - maxRetries: Maximum number of retry attempts (default 3)
  ///   - verifyUpload: If true (default), fetches stored data to verify integrity
  func updateGroupInfo(
    convoId: String, groupInfo: Data, epoch: Int, maxRetries: Int = 3, verifyUpload: Bool = true
  ) async throws {
    logger.info(
      "📤 [MLSAPIClient.updateGroupInfo] START - convoId: \(convoId), epoch: \(epoch), size: \(groupInfo.count) bytes"
    )

    // Pre-validation: Ensure GroupInfo meets minimum size
    guard groupInfo.count >= Self.minGroupInfoSize else {
      logger.error(
        "❌ [MLSAPIClient.updateGroupInfo] GroupInfo too small: \(groupInfo.count) bytes (minimum \(Self.minGroupInfoSize))"
      )
      throw MLSAPIError.invalidResponse(
        message:
          "GroupInfo too small: \(groupInfo.count) bytes (minimum \(Self.minGroupInfoSize) required)"
      )
    }

    // 🔒 FIX #5: Log SHA-256 checksum for debugging data corruption
    // This helps identify if corruption happens during encoding, transport, or storage
    let uploadChecksum = SHA256.hash(data: groupInfo).compactMap { String(format: "%02x", $0) }
      .joined().prefix(16)
    logger.info(
      "📤 [MLSAPIClient.updateGroupInfo] Upload checksum (first 16 chars): \(uploadChecksum)")

    let groupInfoBase64 = groupInfo.base64EncodedString()
    let input = BlueCatbirdMlsUpdateGroupInfo.Input(
      convoId: convoId,
      groupInfo: groupInfoBase64,
      epoch: epoch
    )

    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        let (responseCode, _) = try await client.blue.catbird.mls.updateGroupInfo(input: input)

        if responseCode == 200 {
          logger.info(
            "✅ [MLSAPIClient.updateGroupInfo] Upload succeeded on attempt \(attempt) for \(convoId)"
          )

          // CRITICAL: Verify the upload by fetching back and comparing size
          if verifyUpload {
            do {
              let (storedData, storedEpoch, _) = try await getGroupInfo(
                convoId: convoId, maxRetries: 2)

              // Verify epoch matches
              if storedEpoch != epoch {
                logger.error(
                  "❌ [MLSAPIClient.updateGroupInfo] VERIFICATION FAILED: Epoch mismatch!")
                logger.error("   Uploaded epoch: \(epoch), Server epoch: \(storedEpoch)")
                // This could be a race condition - another member advanced the epoch
                // Log but don't fail since the newer GroupInfo is probably fine
                logger.warning(
                  "⚠️ [MLSAPIClient.updateGroupInfo] Epoch advanced during upload - another member may have committed"
                )
              }

              // Verify size matches (critical for detecting truncation)
              if storedData.count != groupInfo.count {
                logger.error("❌ [MLSAPIClient.updateGroupInfo] VERIFICATION FAILED: Size mismatch!")
                logger.error(
                  "   Uploaded: \(groupInfo.count) bytes, Server stored: \(storedData.count) bytes")
                logger.error(
                  "   🚨 DATA CORRUPTION DETECTED - Server stored truncated/different data!")

                if attempt < maxRetries {
                  logger.info(
                    "🔄 [MLSAPIClient.updateGroupInfo] Retrying upload due to size mismatch...")
                  try await Task.sleep(nanoseconds: UInt64(1_000_000_000))  // 1 second
                  continue
                }

                throw MLSAPIError.invalidResponse(
                  message:
                    "GroupInfo verification failed: uploaded \(groupInfo.count) bytes but server stored \(storedData.count) bytes"
                )
              }

              // Verify content matches (compare first and last 32 bytes to avoid full comparison)
              let uploadPrefix = groupInfo.prefix(32)
              let storedPrefix = storedData.prefix(32)
              let uploadSuffix = groupInfo.suffix(32)
              let storedSuffix = storedData.suffix(32)

              if uploadPrefix != storedPrefix || uploadSuffix != storedSuffix {
                logger.error(
                  "❌ [MLSAPIClient.updateGroupInfo] VERIFICATION FAILED: Content mismatch!")
                logger.error(
                  "   Prefix match: \(uploadPrefix == storedPrefix), Suffix match: \(uploadSuffix == storedSuffix)"
                )

                if attempt < maxRetries {
                  logger.info(
                    "🔄 [MLSAPIClient.updateGroupInfo] Retrying upload due to content mismatch...")
                  try await Task.sleep(nanoseconds: UInt64(1_000_000_000))
                  continue
                }

                throw MLSAPIError.invalidResponse(
                  message:
                    "GroupInfo verification failed: server stored different content than uploaded"
                )
              }

              logger.info(
                "✅ [MLSAPIClient.updateGroupInfo] Verification PASSED - size: \(storedData.count) bytes, epoch: \(storedEpoch)"
              )

            } catch let verifyError as MLSAPIError {
              // If verification fetch fails, log but don't fail the whole operation
              // The upload itself succeeded
              logger.warning(
                "⚠️ [MLSAPIClient.updateGroupInfo] Verification fetch failed: \(verifyError.localizedDescription)"
              )
              logger.warning("   Upload succeeded but could not verify - proceeding anyway")
            }
          }

          return
        }

        // Check for transient server errors that warrant retry
        let isTransient = [502, 503, 504].contains(responseCode)
        if isTransient && attempt < maxRetries {
          let delay = TimeInterval(attempt)  // 1s, 2s, 3s exponential backoff
          logger.warning(
            "⚠️ [MLSAPIClient.updateGroupInfo] Transient error \(responseCode) on attempt \(attempt), retrying in \(delay)s..."
          )
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        }

        // Non-transient error or max retries reached
        logger.error("❌ [MLSAPIClient.updateGroupInfo] HTTP \(responseCode) on attempt \(attempt)")
        throw MLSAPIError.httpError(
          statusCode: responseCode,
          message: "Failed to update GroupInfo after \(attempt) attempt(s)")
      } catch let error as MLSAPIError {
        throw error  // Don't retry our own errors
      } catch {
        lastError = error
        if attempt < maxRetries {
          let delay = TimeInterval(attempt)
          logger.warning(
            "⚠️ [MLSAPIClient.updateGroupInfo] Error on attempt \(attempt): \(error.localizedDescription), retrying in \(delay)s..."
          )
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } else {
          logger.error(
            "❌ [MLSAPIClient.updateGroupInfo] All \(maxRetries) attempts failed for \(convoId)")
        }
      }
    }

    throw lastError
      ?? MLSAPIError.httpError(statusCode: 500, message: "All \(maxRetries) retry attempts failed")
  }

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
    logger.debug(
      "Fetching commits for \(convoId) from epoch \(fromEpoch) to \(toEpoch?.description ?? "current")"
    )

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
      logger.error("❌ Failed to fetch Welcome message for \(convoId): HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to fetch Welcome message")
    }

    // Decode base64 String from ATProto $bytes field to Data
    guard let welcomeData = Data(base64Encoded: output.welcome) else {
      logger.error(
        "❌ Invalid base64 in Welcome message for \(convoId): received string with \(output.welcome.count) characters, prefix: \(output.welcome.prefix(50))"
      )
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
            logger.warning(
              "⚠️ [confirmWelcome] Transient error \(responseCode) on attempt \(attempt)/\(maxRetries), retrying..."
            )

            // Exponential backoff: 1s, 2s, 4s
            let delay = TimeInterval(1 << (attempt - 1))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            continue
          }

          logger.error(
            "❌ [confirmWelcome] Failed with HTTP \(responseCode) on attempt \(attempt)/\(maxRetries)"
          )
          throw MLSAPIError.httpError(
            statusCode: responseCode, message: "confirmWelcome failed with HTTP \(responseCode)")
        }

        logger.info("✅ [confirmWelcome] SUCCESS - confirmation sent after \(attempt) attempt(s)")
        return

      } catch let error as MLSAPIError {
        logger.error(
          "❌ [confirmWelcome] MLSAPIError on attempt \(attempt)/\(maxRetries): \(error.localizedDescription)"
        )
        lastError = error

        // If it's a non-retryable error, throw immediately
        if case .httpError(let statusCode, _) = error {
          let isTransient = statusCode == 502 || statusCode == 503 || statusCode == 504
          if !isTransient || attempt >= maxRetries {
            logger.error("❌ [confirmWelcome] Non-retryable or exhausted retries - throwing error")
            throw error
          }
          logger.warning(
            "⚠️ [confirmWelcome] Transient error \(statusCode), retrying after backoff...")
          let delay = TimeInterval(1 << (attempt - 1))
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } else {
          logger.error("❌ [confirmWelcome] Non-HTTP error - throwing immediately")
          throw error
        }
      } catch {
        logger.error(
          "❌ [confirmWelcome] Unknown error on attempt \(attempt)/\(maxRetries): \(error.localizedDescription)"
        )
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
      logger.error(
        "❌ [confirmWelcome] FAILED after \(maxRetries) attempts - last error: \(error.localizedDescription)"
      )
      throw error
    }
  }

  /// Process an external commit (e.g. for rejoining or self-update)
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - externalCommit: Serialized MLS External Commit data
  ///   - groupInfo: Optional serialized GroupInfo data (for atomic update)
  ///   - idempotencyKey: Optional client-generated UUID
  /// - Returns: Success status and new epoch (0 if not provided by server)
  func processExternalCommit(
    convoId: String,
    externalCommit: Data,
    groupInfo: Data? = nil,
    idempotencyKey: String? = nil
  ) async throws -> (success: Bool, newEpoch: Int) {
    let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
    logger.info(
      "🌐 [MLSAPIClient.processExternalCommit] START - convoId: \(convoId), commit: \(externalCommit.count) bytes, idempotencyKey: \(idemKey)"
    )

    let commitBase64 = externalCommit.base64EncodedString()
    let groupInfoBase64 = groupInfo?.base64EncodedString()

    let input = BlueCatbirdMlsProcessExternalCommit.Input(
      convoId: convoId,
      externalCommit: commitBase64,
      idempotencyKey: idemKey,
      groupInfo: groupInfoBase64
    )

    let (responseCode, output) = try await client.blue.catbird.mls.processExternalCommit(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.processExternalCommit] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to process external commit")
    }

    // Handle optional epoch (older servers may not return it)
    let newEpoch = output.epoch ?? 0
    if output.epoch == nil {
      logger.warning("⚠️ [MLSAPIClient.processExternalCommit] Server did not return epoch - using 0")
    }
    
    logger.info("✅ [MLSAPIClient.processExternalCommit] SUCCESS - newEpoch: \(newEpoch)")
    return (true, newEpoch)
  }

  /// Get list of expected conversations for auto-rejoin detection
  /// - Parameter deviceId: Optional device ID to check (defaults to current device from auth)
  /// - Returns: List of conversations user should be in but may be missing locally
  func getExpectedConversations(
    deviceId: String? = nil
  ) async throws -> BlueCatbirdMlsGetExpectedConversations.Output {
    logger.info("📤 [getExpectedConversations] Fetching expected conversations")

    let input = BlueCatbirdMlsGetExpectedConversations.Parameters(deviceId: deviceId)

    let (responseCode, output) = try await client.blue.catbird.mls.getExpectedConversations(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [getExpectedConversations] Failed with HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "getExpectedConversations failed")
    }

    logger.info(
      "✅ [getExpectedConversations] SUCCESS - found \(output.conversations.count) conversations")
    return output
  }

  // MARK: - Recovery Operations

  /// Invalidate a Welcome message that cannot be processed
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - reason: Reason for invalidation (e.g., "NoMatchingKeyPackage")
  /// - Returns: Tuple of (invalidated: Bool, welcomeId: String?)
  /// - Note: Used when Welcome processing fails and client needs to fall back to External Commit
  func invalidateWelcome(
    convoId: String,
    reason: String
  ) async throws -> (invalidated: Bool, welcomeId: String?) {
    logger.info("📤 [invalidateWelcome] START - convoId: \(convoId), reason: \(reason)")

    let input = BlueCatbirdMlsInvalidateWelcome.Input(
      convoId: convoId,
      reason: reason
    )

    let (responseCode, output) = try await client.blue.catbird.mls.invalidateWelcome(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [invalidateWelcome] Failed with HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "invalidateWelcome failed with HTTP \(responseCode)")
    }

    if output.invalidated {
      logger.info(
        "✅ [invalidateWelcome] SUCCESS - Welcome invalidated, welcomeId: \(output.welcomeId ?? "nil")"
      )
    } else {
      logger.warning("⚠️ [invalidateWelcome] No Welcome found to invalidate")
    }

    return (output.invalidated, output.welcomeId)
  }

  /// Request re-addition to a conversation when both Welcome and External Commit have failed
  /// - Parameter convoId: Conversation identifier
  /// - Returns: Tuple of (requested: Bool, activeMembers: Int?)
  /// - Note: This emits an SSE event to active members who can re-add the user
  func readdition(
    convoId: String
  ) async throws -> (requested: Bool, activeMembers: Int?) {
    logger.info("📤 [readdition] START - convoId: \(convoId)")

    let input = BlueCatbirdMlsReaddition.Input(convoId: convoId)

    let (responseCode, output) = try await client.blue.catbird.mls.readdition(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [readdition] Failed with HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "readdition failed with HTTP \(responseCode)")
    }

    if output.requested {
      logger.info(
        "✅ [readdition] SUCCESS - request sent to \(output.activeMembers ?? 0) active members")
    } else {
      logger.warning("⚠️ [readdition] No active members to notify")
    }

    return (output.requested, output.activeMembers)
  }

  /// Request active members to publish fresh GroupInfo for a conversation
  /// - Parameter convoId: Conversation identifier
  /// - Returns: Tuple of (requested: Bool, activeMembers: Int?)
  /// - Note: Used when GroupInfo is expired and External Commit cannot proceed
  func groupInfoRefresh(
    convoId: String
  ) async throws -> (requested: Bool, activeMembers: Int?) {
    logger.info("📤 [groupInfoRefresh] START - convoId: \(convoId)")

    let input = BlueCatbirdMlsGroupInfoRefresh.Input(convoId: convoId)

    let (responseCode, output) = try await client.blue.catbird.mls.groupInfoRefresh(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [groupInfoRefresh] Failed with HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "groupInfoRefresh failed with HTTP \(responseCode)")
    }

    if output.requested {
      logger.info(
        "✅ [groupInfoRefresh] SUCCESS - request sent to \(output.activeMembers ?? 0) active members"
      )
    } else {
      logger.warning("⚠️ [groupInfoRefresh] No active members to notify")
    }

    return (output.requested, output.activeMembers)
  }

  // MARK: - Admin Operations

  /// Remove a member from conversation (admin-only operation)
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - targetDid: DID of member to remove
  ///   - reason: Optional reason for removal
  ///   - commit: Base64-encoded MLS commit message (REQUIRED for epoch sync)
  ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
  /// - Returns: Success status and epoch hint (if provided by server)
  func removeMember(
    convoId: String,
    targetDid: DID,
    reason: String? = nil,
    commit: String? = nil,
    idempotencyKey: String? = nil
  ) async throws -> (ok: Bool, epochHint: Int?) {
    let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
    logger.info(
      "🌐 [MLSAPIClient.removeMember] START - convoId: \(convoId), targetDid: \(targetDid), commit: \(commit != nil ? "\(commit!.count) chars" : "nil"), idempotencyKey: \(idemKey)"
    )

    let input = BlueCatbirdMlsRemoveMember.Input(
      convoId: convoId,
      targetDid: targetDid,
      idempotencyKey: idemKey,
      reason: reason,
      commit: commit
    )

    let (responseCode, output) = try await client.blue.catbird.mls.removeMember(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.removeMember] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to remove member")
    }

    logger.info(
      "✅ [MLSAPIClient.removeMember] SUCCESS - epochHint: \(output.epochHint.map { String($0) } ?? "nil")"
    )
    return (output.ok, output.epochHint)
  }

  /// Send a generic MLS commit (e.g., self-update) to advance epoch
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - commit: Serialized MLS commit data
  ///   - idempotencyKey: Optional client-generated UUID for idempotent retries (auto-generated if nil)
  /// - Returns: New epoch after processing commit
  /// - Note: This is used for self-updates and other commits that don't add/remove members
  func sendCommit(
    convoId: String,
    commit: String,
    idempotencyKey: String? = nil
  ) async throws -> UInt64 {
    let idemKey = idempotencyKey ?? UUID().uuidString.lowercased()
    logger.info(
      "🌐 [MLSAPIClient.sendCommit] START - convoId: \(convoId), commit: \(commit.count) bytes, idempotencyKey: \(idemKey)"
    )

    // Use addMembers endpoint with no new members for generic commits
    // The server should handle commits without didList as pure update commits
    let input = BlueCatbirdMlsAddMembers.Input(
      convoId: convoId,
      idempotencyKey: idemKey,
      didList: [],  // Empty list = no new members, just epoch advancement
      commit: commit,
      welcomeMessage: nil,
      keyPackageHashes: nil
    )

    do {
      let (responseCode, output) = try await client.blue.catbird.mls.addMembers(input: input)

      guard responseCode == 200, let output = output else {
        throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to send commit")
      }

      logger.info("✅ [MLSAPIClient.sendCommit] SUCCESS - newEpoch: \(output.newEpoch)")
      return UInt64(output.newEpoch)
    } catch let error as ATProtoError<BlueCatbirdMlsAddMembers.Error> {
      logger.error(
        "❌ [MLSAPIClient.sendCommit] Lexicon error: \(error.error.errorName) - \(error.message ?? "no details")"
      )
      throw MLSAPIError(from: error)
    }
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
    logger.info(
      "🌐 [MLSAPIClient.promoteAdmin] START - convoId: \(convoId), targetDid: \(targetDid), idempotencyKey: \(idemKey)"
    )

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
    logger.info(
      "🌐 [MLSAPIClient.demoteAdmin] START - convoId: \(convoId), targetDid: \(targetDid), idempotencyKey: \(idemKey)"
    )

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
    logger.info(
      "🌐 [MLSAPIClient.reportMember] START - convoId: \(convoId), targetDid: \(targetDid), reason: \(reason), idempotencyKey: \(idemKey)"
    )

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
    logger.info(
      "🌐 [MLSAPIClient.resolveReport] START - reportId: \(reportId), action: \(action), idempotencyKey: \(idemKey)"
    )

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

  /// Warn a member in a conversation (admin-only)
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to warn
  ///   - reason: Reason for warning (max 500 characters)
  ///   - expiresAt: Optional expiration time for warning
  /// - Returns: Tuple of warning ID and delivery timestamp
  func warnMember(
    convoId: String,
    memberDid: DID,
    reason: String,
    expiresAt: Date? = nil
  ) async throws -> (warningId: String, deliveredAt: Date) {
    logger.info(
      "🌐 [MLSAPIClient.warnMember] START - convoId: \(convoId), memberDid: \(memberDid), reason: \(reason.prefix(50))..."
    )

    let input = BlueCatbirdMlsWarnMember.Input(
      convoId: convoId,
      memberDid: memberDid,
      reason: reason,
      expiresAt: expiresAt.map { ATProtocolDate(date: $0) }
    )

    let (responseCode, output) = try await client.blue.catbird.mls.warnMember(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.warnMember] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to warn member")
    }

    logger.info("✅ [MLSAPIClient.warnMember] SUCCESS - warningId: \(output.warningId)")
    return (output.warningId, output.deliveredAt.date)
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
  func getBlockStatus(convoId: String) async throws -> [BlueCatbirdMlsCheckBlocks.BlockRelationship]
  {
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
    logger.info(
      "🌐 [MLSAPIClient.handleBlockChange] START - blockerDid: \(blockerDid), blockedDid: \(blockedDid), action: \(action)"
    )

    let input = BlueCatbirdMlsHandleBlockChange.Input(
      blockerDid: blockerDid,
      blockedDid: blockedDid,
      action: action,
      blockUri: nil
    )

    let (responseCode, output) = try await client.blue.catbird.mls.handleBlockChange(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.handleBlockChange] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to handle block change")
    }

    logger.info(
      "✅ [MLSAPIClient.handleBlockChange] SUCCESS - \(output.affectedConvos.count) conversations affected"
    )
    return output.affectedConvos
  }

  // MARK: - Push Notifications

  /// Register or update a device push token for APNs
  /// - Parameters:
  ///   - deviceId: Unique identifier for the device
  ///   - pushToken: Hex-encoded APNs device token
  ///   - deviceName: Human-readable device name
  ///   - platform: Platform identifier (e.g., "ios")
  /// - Returns: Success status
  func registerDeviceToken(
    deviceId: String,
    pushToken: String,
    deviceName: String,
    platform: String = "ios"
  ) async throws -> Bool {
    logger.info(
      "🌐 [MLSAPIClient.registerDeviceToken] START - deviceId: \(deviceId), platform: \(platform), deviceName: \(deviceName)"
    )

    let input = BlueCatbirdMlsRegisterDeviceToken.Input(
      deviceId: deviceId,
      pushToken: pushToken,
      deviceName: deviceName,
      platform: platform
    )

    if let jsonData = try? JSONEncoder().encode(input),
      let jsonString = String(data: jsonData, encoding: .utf8)
    {
      logger.debug("📝 [MLSAPIClient.registerDeviceToken] Payload: \(jsonString)")
    }

    let (responseCode, output) = try await client.blue.catbird.mls.registerDeviceToken(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.registerDeviceToken] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to register device token")
    }

    logger.info("✅ [MLSAPIClient.registerDeviceToken] SUCCESS")
    return output.success
  }

  /// Remove a device push token
  /// - Parameter deviceId: Unique identifier for the device
  /// - Returns: Success status
  func unregisterDeviceToken(deviceId: String) async throws -> Bool {
    logger.info("🌐 [MLSAPIClient.unregisterDeviceToken] START - deviceId: \(deviceId)")

    let input = BlueCatbirdMlsUnregisterDeviceToken.Input(deviceId: deviceId)

    let (responseCode, output) = try await client.blue.catbird.mls.unregisterDeviceToken(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.unregisterDeviceToken] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to unregister device token")
    }

    logger.info("✅ [MLSAPIClient.unregisterDeviceToken] SUCCESS")
    return output.success
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
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to get key package stats")
    }

    logger.info(
      "✅ [MLSAPIClient.getKeyPackageStats] SUCCESS - available: \(output.available), threshold: \(output.threshold)"
    )
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
    logger.info(
      "🌐 [MLSAPIClient.getKeyPackageStatus] START - limit: \(limit), cursor: \(cursor ?? "none")")

    let input = BlueCatbirdMlsGetKeyPackageStatus.Parameters(
      limit: limit,
      cursor: cursor
    )

    let (responseCode, output) = try await client.blue.catbird.mls.getKeyPackageStatus(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.getKeyPackageStatus] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to get key package status")
    }

    logger.info(
      "✅ [MLSAPIClient.getKeyPackageStatus] SUCCESS - available: \(output.available)/\(output.totalUploaded), consumed: \(output.consumed), reserved: \(output.reserved ?? 0)"
    )
    return output
  }

  // MARK: - Key Package Synchronization (NoMatchingKeyPackage Prevention)

  /// Synchronize key packages between client and server to prevent NoMatchingKeyPackage errors
  ///
  /// This is the primary method to prevent the NoMatchingKeyPackage bug:
  /// - Compares local key package hashes against server-side available packages
  /// - Deletes any "orphaned" server packages that no longer have local private keys
  /// - Returns sync status including deleted orphan count
  ///
  /// MULTI-DEVICE SUPPORT:
  /// deviceId is REQUIRED. Only syncs key packages belonging to that specific device.
  /// This prevents Device A from accidentally deleting Device B's packages.
  ///
  /// Should be called:
  /// - On app launch after device registration
  /// - After account switch
  /// - When recovering from storage corruption
  ///
  /// - Parameters:
  ///   - localHashes: SHA256 hex hashes of key packages in local storage
  ///   - deviceId: Device ID (REQUIRED) - the deviceId returned from registerDevice
  /// - Returns: Tuple of (serverHashes, orphanedCount, deletedCount, orphanedHashes, remainingAvailable)
  func syncKeyPackages(localHashes: [String], deviceId: String) async throws -> (
    serverHashes: [String],
    orphanedCount: Int,
    deletedCount: Int,
    orphanedHashes: [String],
    remainingAvailable: Int
  ) {
    logger.info(
      "🔄 [MLSAPIClient.syncKeyPackages] START - localHashes: \(localHashes.count), deviceId: \(deviceId)"
    )

    let input = BlueCatbirdMlsSyncKeyPackages.Input(
      localHashes: localHashes,
      deviceId: deviceId
    )

    let (responseCode, output) = try await client.blue.catbird.mls.syncKeyPackages(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.syncKeyPackages] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "syncKeyPackages failed")
    }

    let serverHashes = output.serverHashes
    let orphanedCount = output.orphanedCount
    let deletedCount = output.deletedCount
    let orphanedHashes = output.orphanedHashes ?? []
    let remainingAvailable = output.remainingAvailable ?? serverHashes.count

    logger.info("✅ [MLSAPIClient.syncKeyPackages] SUCCESS")
    logger.info("   - Device: \(deviceId)")
    logger.info("   - Orphaned: \(orphanedCount)")
    logger.info("   - Deleted: \(deletedCount)")
    logger.info("   - Remaining: \(remainingAvailable)")

    return (serverHashes, orphanedCount, deletedCount, orphanedHashes, remainingAvailable)
  }

  /// Query current key package inventory from server (simplified wrapper for upload logic)
  /// - Returns: Tuple of (available packages on server, replenishment threshold)
  /// - Throws: MLSAPIError if query fails
  func queryKeyPackageInventory() async throws -> (available: Int, threshold: Int) {
    logger.info("🔍 [MLSAPIClient.queryInventory] Querying server key package inventory")

    let stats = try await getKeyPackageStats()
    let available = stats.available
    let threshold = stats.threshold

    logger.info(
      "📊 [MLSAPIClient.queryInventory] Server inventory - available: \(available), threshold: \(threshold)"
    )
    return (available, threshold)
  }

  /// Publish multiple key packages in a single batch request (preferred over individual uploads)
  /// - Parameter packages: Array of key package data to upload (max 100 per batch)
  /// - Returns: Batch result with success/failure counts
  func publishKeyPackagesBatch(_ packages: [MLSKeyPackageUploadData]) async throws
    -> KeyPackageBatchResult
  {
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
  private func publishKeyPackagesBatchDirect(_ packages: [MLSKeyPackageUploadData]) async throws
    -> KeyPackageBatchResult
  {
    logger.info(
      "🌐 [MLSAPIClient.publishKeyPackagesBatchDirect] Using real batch endpoint - count: \(packages.count)"
    )

    // Convert custom types to generated types
    let keyPackageItems = packages.map { pkg in
      BlueCatbirdMlsPublishKeyPackages.KeyPackageItem(
        keyPackage: pkg.keyPackage,
        cipherSuite: pkg.cipherSuite,
        expires: pkg.expires.map { ATProtocolDate(date: $0) }
          ?? ATProtocolDate(date: Date().addingTimeInterval(90 * 24 * 60 * 60)),
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

    logger.info(
      "✅ [MLSAPIClient.publishKeyPackagesBatchDirect] SUCCESS - succeeded: \(output.succeeded), failed: \(output.failed)"
    )
    return KeyPackageBatchResult(succeeded: output.succeeded, failed: output.failed, errors: errors)
  }

  /// Fallback: Upload packages individually with concurrent batching
  private func publishKeyPackagesFallback(_ packages: [MLSKeyPackageUploadData]) async throws
    -> KeyPackageBatchResult
  {
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

    logger.info(
      "✅ [MLSAPIClient.publishKeyPackagesBatch] COMPLETE - succeeded: \(succeeded), failed: \(failed)"
    )

    return KeyPackageBatchResult(
      succeeded: succeeded, failed: failed, errors: errors.isEmpty ? nil : errors)
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

  // MARK: - Opt-In Management

  /// Opt in to MLS chat
  /// - Parameter deviceId: Optional device identifier for this opt-in
  /// - Returns: Tuple containing opt-in status and timestamp
  func optIn(deviceId: String? = nil) async throws -> (optedIn: Bool, optedInAt: Date) {
    logger.info("🌐 [MLSAPIClient.optIn] START")

    let input = BlueCatbirdMlsOptIn.Input(deviceId: deviceId)
    let (responseCode, output) = try await client.blue.catbird.mls.optIn(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.optIn] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to opt in")
    }

    logger.info("✅ [MLSAPIClient.optIn] SUCCESS")
    return (output.optedIn, output.optedInAt.date)
  }

  /// Opt out of MLS chat
  /// - Returns: True if successfully opted out
  func optOut() async throws -> Bool {
    logger.info("🌐 [MLSAPIClient.optOut] START")

    let (responseCode, output) = try await client.blue.catbird.mls.optOut()

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.optOut] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to opt out")
    }

    logger.info("✅ [MLSAPIClient.optOut] SUCCESS - \(output.success)")
    return output.success
  }

  /// Get opt-in status for multiple users
  /// - Parameter dids: Array of DIDs to check (max 100)
  /// - Returns: Array of opt-in status records
  func getOptInStatus(dids: [DID]) async throws -> [(did: String, optedIn: Bool, optedInAt: Date?)]
  {
    logger.info("🌐 [MLSAPIClient.getOptInStatus] START - dids: \(dids.count)")

    guard dids.count <= 100 else {
      logger.error("❌ [MLSAPIClient.getOptInStatus] Too many DIDs")
      throw MLSAPIError.invalidBatchSize
    }

    let input = BlueCatbirdMlsGetOptInStatus.Parameters(dids: dids)
    let (responseCode, output) = try await client.blue.catbird.mls.getOptInStatus(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.getOptInStatus] HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to get opt-in status")
    }

    let results = output.statuses.map { status -> (did: String, optedIn: Bool, optedInAt: Date?) in
      (status.did.description, status.optedIn, status.optedInAt?.date)
    }

    logger.info("✅ [MLSAPIClient.getOptInStatus] SUCCESS - returned \(results.count) statuses")
    return results
  }

  // MARK: - Multi-Device Sync

  /// Get pending device additions for conversations where new devices need to be added
  /// - Parameters:
  ///   - convoIds: Optional array of conversation IDs to filter (max 50)
  ///   - limit: Maximum number of pending additions to return (1-100, default: 50)
  /// - Returns: Array of pending device additions
  func getPendingDeviceAdditions(
    convoIds: [String]? = nil,
    limit: Int = 50
  ) async throws -> [BlueCatbirdMlsGetPendingDeviceAdditions.PendingDeviceAddition] {
    logger.info(
      "🌐 [MLSAPIClient.getPendingDeviceAdditions] START - convoIds: \(convoIds?.count ?? 0), limit: \(limit)"
    )

    let input = BlueCatbirdMlsGetPendingDeviceAdditions.Parameters(
      convoIds: convoIds,
      limit: limit
    )

    let (responseCode, output) = try await client.blue.catbird.mls.getPendingDeviceAdditions(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.getPendingDeviceAdditions] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to get pending device additions")
    }

    logger.info(
      "✅ [MLSAPIClient.getPendingDeviceAdditions] SUCCESS - \(output.pendingAdditions.count) pending additions"
    )
    return output.pendingAdditions
  }

  /// Claim a pending device addition to indicate this device will add the new device
  /// - Parameter pendingAdditionId: The ID of the pending addition to claim
  /// - Returns: Claim result with key package if successful
  func claimPendingDeviceAddition(
    pendingAdditionId: String
  ) async throws -> BlueCatbirdMlsClaimPendingDeviceAddition.Output {
    logger.info(
      "🌐 [MLSAPIClient.claimPendingDeviceAddition] START - pendingAdditionId: \(pendingAdditionId)"
    )

    let input = BlueCatbirdMlsClaimPendingDeviceAddition.Input(
      pendingAdditionId: pendingAdditionId
    )

    let (responseCode, output) = try await client.blue.catbird.mls.claimPendingDeviceAddition(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.claimPendingDeviceAddition] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to claim pending device addition")
    }

    logger.info(
      "✅ [MLSAPIClient.claimPendingDeviceAddition] SUCCESS - claimed: \(output.claimed), convoId: \(output.convoId.debugDescription)"
    )
    return output
  }

  /// Complete a pending device addition after successfully adding the device via addMembers
  /// - Parameters:
  ///   - pendingAdditionId: The ID of the pending addition to complete
  ///   - newEpoch: The new epoch after the addMembers operation
  /// - Returns: Success status
  func completePendingDeviceAddition(
    pendingAdditionId: String,
    newEpoch: Int
  ) async throws -> Bool {
    logger.info(
      "🌐 [MLSAPIClient.completePendingDeviceAddition] START - pendingAdditionId: \(pendingAdditionId), newEpoch: \(newEpoch)"
    )

    let input = BlueCatbirdMlsCompletePendingDeviceAddition.Input(
      pendingAdditionId: pendingAdditionId,
      newEpoch: newEpoch
    )

    let (responseCode, output) = try await client.blue.catbird.mls.completePendingDeviceAddition(
      input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ [MLSAPIClient.completePendingDeviceAddition] HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to complete pending device addition")
    }

    logger.info("✅ [MLSAPIClient.completePendingDeviceAddition] SUCCESS")
    return output.success
  }

  // NOTE: Text-only PostgreSQL architecture (no CloudKit/R2 dependencies)
  // Message embeds are now fully encrypted within the ciphertext payload
  // Supported embed types (encrypted in MLSMessagePayload):
  //   - recordEmbed: Bluesky post quote embeds (AT-URI references)
  //   - linkEmbed: External link previews
  //   - gifEmbed: Tenor GIF embeds (MP4 format)
  // See blue.catbird.mls.message.defs#payloadView for encrypted structure

  // MARK: - Encrypted E2EE Control Messages
  // These methods send encrypted payloads for reactions, read receipts, and typing indicators
  // All use sendMessage with delivery hints (persistent/ephemeral) per the greenfield E2EE design
  // See blue.catbird.mls.message.defs for payload schemas

  /// Send an encrypted reaction via MLS application message
  ///
  /// The reaction payload is encrypted end-to-end. The server only sees:
  /// - `delivery: "persistent"` hint (for storage/replay)
  /// - Opaque ciphertext bytes
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - msgId: Client-generated ULID for this reaction message
  ///   - ciphertext: MLS-encrypted `MLSMessagePayload` with `messageType: "reaction"`
  ///   - epoch: MLS epoch when encrypted
  ///   - paddedSize: Padded ciphertext size bucket
  /// - Returns: Server response with messageId, receivedAt, seq, epoch
  func sendEncryptedReaction(
    convoId: String,
    msgId: String,
    ciphertext: Data,
    epoch: Int,
    paddedSize: Int
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.debug("Sending encrypted reaction for convoId: \(convoId)")

    let input = BlueCatbirdMlsSendMessage.Input(
      convoId: convoId,
      msgId: msgId,
      ciphertext: Bytes(data: ciphertext),
      epoch: epoch,
      paddedSize: paddedSize,
      delivery: "persistent"  // Reactions persist for offline sync
    )

    let (responseCode, output) = try await client.blue.catbird.mls.sendMessage(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to send encrypted reaction: HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to send reaction")
    }

    logger.debug("✅ Encrypted reaction sent: msgId=\(output.messageId), seq=\(output.seq)")
    return (output.messageId, output.receivedAt, output.seq, output.epoch)
  }

  /// Send an encrypted read receipt via MLS application message
  ///
  /// The read receipt payload is encrypted end-to-end. The server only sees:
  /// - `delivery: "persistent"` hint (for storage/replay)
  /// - Opaque ciphertext bytes
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - msgId: Client-generated ULID for this read receipt message
  ///   - ciphertext: MLS-encrypted `MLSMessagePayload` with `messageType: "readReceipt"`
  ///   - epoch: MLS epoch when encrypted
  ///   - paddedSize: Padded ciphertext size bucket
  /// - Returns: Server response with messageId, receivedAt, seq, epoch
  func sendEncryptedReadReceipt(
    convoId: String,
    msgId: String,
    ciphertext: Data,
    epoch: Int,
    paddedSize: Int
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.debug("Sending encrypted read receipt for convoId: \(convoId)")

    let input = BlueCatbirdMlsSendMessage.Input(
      convoId: convoId,
      msgId: msgId,
      ciphertext: Bytes(data: ciphertext),
      epoch: epoch,
      paddedSize: paddedSize,
      delivery: "persistent"  // Read receipts persist for offline sync
    )

    let (responseCode, output) = try await client.blue.catbird.mls.sendMessage(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to send encrypted read receipt: HTTP \(responseCode)")
      throw MLSAPIError.httpError(statusCode: responseCode, message: "Failed to send read receipt")
    }

    logger.debug("✅ Encrypted read receipt sent: msgId=\(output.messageId)")
    return (output.messageId, output.receivedAt, output.seq, output.epoch)
  }

  /// Send an encrypted typing indicator via MLS application message (ephemeral)
  ///
  /// The typing payload is encrypted end-to-end. The server only sees:
  /// - `delivery: "ephemeral"` hint (SSE-only, not stored)
  /// - Opaque ciphertext bytes
  ///
  /// Per RFC 9420, typing indicators use MLS PrivateMessage framing without epoch advancement.
  /// They consume the per-sender application ratchet but don't trigger commits.
  ///
  /// Throttling recommendations:
  /// - Debounce: send "start" after 500-1000ms of activity
  /// - Refresh: at most every 6-10s while still typing
  /// - Stop: send on 5s idle or when message is sent
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - msgId: Client-generated ULID for this typing message
  ///   - ciphertext: MLS-encrypted `MLSMessagePayload` with `messageType: "typing"`
  ///   - epoch: MLS epoch when encrypted
  ///   - paddedSize: Padded ciphertext size bucket (recommend padding to 512 for all typing)
  /// - Returns: Server response with messageId, receivedAt, seq (always 0 for ephemeral), epoch
  func sendEncryptedTypingIndicator(
    convoId: String,
    msgId: String,
    ciphertext: Data,
    epoch: Int,
    paddedSize: Int
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.debug("Sending encrypted typing indicator for convoId: \(convoId)")

    let input = BlueCatbirdMlsSendMessage.Input(
      convoId: convoId,
      msgId: msgId,
      ciphertext: Bytes(data: ciphertext),
      epoch: epoch,
      paddedSize: paddedSize,
      delivery: "ephemeral"  // Typing indicators are SSE-only, not persisted
    )

    let (responseCode, output) = try await client.blue.catbird.mls.sendMessage(input: input)

    guard responseCode == 200, let output = output else {
      logger.error("❌ Failed to send encrypted typing indicator: HTTP \(responseCode)")
      throw MLSAPIError.httpError(
        statusCode: responseCode, message: "Failed to send typing indicator")
    }

    logger.debug("✅ Encrypted typing indicator sent (ephemeral): msgId=\(output.messageId)")
    return (output.messageId, output.receivedAt, output.seq, output.epoch)
  }
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
    case .invalidResponse(let message):
      return "Invalid response from MLS API: \(message)"
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

extension MLSAPIError {
  fileprivate init(from error: ATProtoError<BlueCatbirdMlsCreateConvo.Error>) {
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

  fileprivate init(from error: ATProtoError<BlueCatbirdMlsAddMembers.Error>) {
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
  func streamConvoEvents(convoId: String, cursor: String? = nil) async throws
    -> AsyncThrowingStream<BlueCatbirdMlsStreamConvoEvents.Output, Error>
  {
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
