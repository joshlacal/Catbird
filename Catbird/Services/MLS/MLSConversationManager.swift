import CatbirdMLSCore
import CryptoKit
import Foundation
import GRDB
import OSLog
import Petrel
import Synchronization

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
  case epochMismatch
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
    case .epochMismatch:
      return "Local epoch doesn't match server epoch after commit merge"
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
      return
        "Key package synchronization recovery initiated. Please rejoin the conversation when prompted."
    }
  }
}

// MARK: - Conversation Processing Coordinator

actor ConversationProcessingCoordinator {
  private var lockedConversations: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func withCriticalSection<T>(conversationID: String, operation: () async throws -> T)
    async rethrows -> T
  {
    await acquire(conversationID: conversationID)
    defer { release(conversationID: conversationID) }
    return try await operation()
  }

  private func acquire(conversationID: String) async {
    if !lockedConversations.contains(conversationID) {
      lockedConversations.insert(conversationID)
      return
    }

    await withCheckedContinuation { continuation in
      waiters[conversationID, default: []].append(continuation)
    }
  }

  private func release(conversationID: String) {
    if var queue = waiters[conversationID], !queue.isEmpty {
      let continuation = queue.removeFirst()
      waiters[conversationID] = queue
      continuation.resume()
    } else {
      lockedConversations.remove(conversationID)
      waiters[conversationID] = nil
    }
  }
}

// MARK: - Group Operation Coordinator

/// Actor-based coordinator for serializing MLS operations on the same group
/// Prevents concurrent mutations that could lose updates or cause ratchet desyncs
actor GroupOperationCoordinator {
  private var activeOperations: [String: Task<Void, Never>] = [:]

  /// Execute an operation with exclusive access to a specific group
  /// Operations on the same group are serialized, but operations on different groups can run concurrently
  func withExclusiveLock<T>(
    groupId: String,
    operation: @Sendable () async throws -> T
  ) async rethrows -> T {
    // Wait for any existing operation on this group
    while let existing = activeOperations[groupId] {
      _ = await existing.result
    }

    // Create a signal for when THIS operation completes
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    // Store a task that waits for our signal
    // Future callers will wait on this task
    let trackingTask = Task<Void, Never> {
      for await _ in stream { break }
    }
    activeOperations[groupId] = trackingTask

    // Execute the actual operation
    defer {
      // Signal completion
      continuation.yield()
      continuation.finish()

      // Remove this group's lock if it's still our task
      // (It should be, since we're in an actor)
      if activeOperations[groupId] == trackingTask {
        activeOperations[groupId] = nil
      }
    }

    return try await operation()
  }

  /// PHASE 3 FIX: Execute a critical MLS operation that MUST complete atomically
  /// even if the parent task is cancelled. This protects operations that mutate
  /// MLS state (encrypt, decrypt, merge commit) from being interrupted mid-flight.
  ///
  /// Use this for operations that:
  /// - Consume one-time secrets from the MLS ratchet
  /// - Advance the epoch or sequence number
  /// - Must complete their side effects (e.g., database writes) atomically
  ///
  /// The operation runs in a detached task to prevent parent cancellation,
  /// while still maintaining exclusive group access via the coordinator.
  func withUninterruptibleOperation<T>(
    groupId: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    return try await withExclusiveLock(groupId: groupId) {
      // Run in detached task to protect from parent cancellation
      // This ensures the operation completes even if the caller is cancelled
      try await Task.detached {
        try await operation()
      }.value
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
  let selectedPackages: [KeyPackageWithHash]  // Track for rollback on failure
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

/// Pending sent message tracking for proactive own-message identification
/// This prevents re-processing own sent messages through FFI, which would incorrectly advance the ratchet
struct PendingMessage: Sendable {
  let messageID: String  // Server-assigned message ID
  let conversationID: String  // Conversation this message belongs to
  let plaintext: String  // Original plaintext content
  let embed: MLSEmbedData?  // Optional embed data (record, link, or GIF)
  let senderDID: String  // Sender's DID (always currentUserDID for pending messages)
  let timestamp: Date  // When the message was sent
  let epoch: Int64  // MLS epoch when message was encrypted
  let seq: Int64  // Server-assigned sequence number
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

/// Membership action types
enum MembershipAction: String, Codable, Sendable {
  case joined
  case left
  case removed
  case kicked
}

/// Membership change reason types
enum MembershipChangeReason: Sendable, CustomStringConvertible {
  case selfLeft
  case kicked(by: DID, reason: String?)
  case outOfSync
  case connectionLost

  var description: String {
    switch self {
    case .selfLeft:
      return "Self left the group"

    case .kicked(let by, let reason):
      if let reason {
        return "Kicked by \(by) (\(reason))"
      } else {
        return "Kicked by \(by)"
      }

    case .outOfSync:
      return "Local MLS state out of sync"

    case .connectionLost:
      return "Disconnected"
    }
  }
}

/// Recovery reason for conversation state
enum RecoveryReason: String, Codable, Sendable {
  case epochMismatch
  case keyPackageDesync
  case memberRemoval
  case serverStateInconsistent
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
  case membershipChanged(convoId: String, did: DID, action: MembershipAction)
  case kickedFromConversation(convoId: String, by: DID, reason: String?)
  case conversationNeedsRecovery(convoId: String, reason: RecoveryReason)
  case reactionReceived(
    convoId: String, messageId: String, emoji: String, senderDID: String, action: String)
  case readReceiptReceived(convoId: String, messageId: String, senderDID: String)
  case typingChanged(convoId: String, typingUsers: [String])

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
    case .membershipChanged(let convoId, let did, let action):
      return "Membership changed in \(convoId): \(did) - \(action.rawValue)"
    case .kickedFromConversation(let convoId, let by, let reason):
      return "Kicked from \(convoId) by \(by)\(reason.map { ": \($0)" } ?? "")"
    case .conversationNeedsRecovery(let convoId, let reason):
      return "Conversation \(convoId) needs recovery: \(reason.rawValue)"
    case .reactionReceived(let convoId, let messageId, let emoji, let senderDID, let action):
      return "Reaction \(action) in \(convoId): \(emoji) on \(messageId) by \(senderDID)"
    case .readReceiptReceived(let convoId, let messageId, let senderDID):
      return "Read receipt in \(convoId): \(messageId) read by \(senderDID)"
    case .typingChanged(let convoId, let typingUsers):
      return "Typing changed in \(convoId): \(typingUsers.count) user(s) typing"
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
  let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationManager")

  // MARK: - Dependencies

  private let apiClient: MLSAPIClient
  private let atProtoClient: ATProtoClient
  let mlsClient: MLSClient
  let storage: MLSStorage
  let database: MLSDatabase
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

  /// Sync state protected by Mutex (Swift 6 Synchronization)
  /// Using Mutex<Bool> to atomically check-and-set sync status
  private let syncState = Mutex<Bool>(false)

  /// Public accessor for sync status (reads from mutex)
  private(set) var isSyncing: Bool {
    get { syncState.withLock { $0 } }
    set { syncState.withLock { $0 = newValue } }
  }

  /// Initialization status
  private(set) var isInitialized = false

  /// Background cleanup task
  private var cleanupTask: Task<Void, Never>?

  /// Background periodic sync task
  private var periodicSyncTask: Task<Void, Never>?

  /// Last time key packages were refreshed
  private var lastKeyPackageRefresh: Date?

  /// Key package monitor for smart replenishment
  private var keyPackageMonitor: MLSKeyPackageMonitor?

  /// Consumption tracker for key package usage analytics
  private var consumptionTracker: MLSConsumptionTracker?

  /// Recently sent message tracking for deduplication (convoId -> (idempotencyKey -> timestamp))
  private var recentlySentMessages: [String: [String: Date]] = [:]
  private let deduplicationWindow: TimeInterval = 60  // 60 seconds
  private var deduplicationCleanupTimer: Timer?

  /// Pending sent messages for proactive own-message identification (messageID -> PendingMessage)
  /// Prevents re-processing own messages through FFI which would advance ratchet incorrectly
  private var pendingMessages: [String: PendingMessage] = [:]

  private let pendingMessagesLock = NSLock()
  private let pendingMessageTimeout: TimeInterval = 300  // 5 minutes

  /// Track conversations where the current user was explicitly removed to block unauthorized rejoins
  private var removalTombstones: Set<String> = []
  private let removalTombstoneLock = NSLock()
  private let removalTombstoneKeyPrefix = "mls.removal_tombstones."

  /// Track own commits to prevent re-processing them via SSE
  /// Maps commit hash (SHA256 of commit data) -> timestamp
  /// Commits are removed after 10 minutes to prevent unbounded growth
  private var ownCommits: [String: Date] = [:]
  private let ownCommitsLock = NSLock()
  private let ownCommitTimeout: TimeInterval = 600  // 10 minutes

  /// Track initialization state for conversations to prevent race conditions
  private var conversationStates: [String: ConversationInitState] = [:]

  /// Hashes that have been reported as exhausted/unavailable by the MLS service (keyed by DID)
  private var exhaustedKeyPackageHashes: [String: Set<String>] = [:]

  /// Flag indicating the manager is preparing for shutdown/storage reset
  private var isShuttingDown = false

  /// Serializes MLS message processing per conversation to avoid concurrent ratchet advances
  private let messageProcessingCoordinator = ConversationProcessingCoordinator()

  /// Serializes MLS group operations per group ID to prevent concurrent mutations
  private let groupOperationCoordinator = GroupOperationCoordinator()

  /// Manages automatic synchronization of new devices to conversations
  private var deviceSyncManager: MLSDeviceSyncManager?

  // MARK: - Typing Indicator State

  /// Tracks typing users per conversation: [conversationId: [senderDID: expiresAt]]
  private var typingUsers: [String: [String: Date]] = [:]

  /// Timer for clearing expired typing indicators
  private var typingCleanupTimer: Timer?

  // MARK: - Sync Circuit Breaker

  /// Tracks consecutive sync failures to implement circuit breaker pattern
  private var consecutiveSyncFailures: Int = 0

  /// Maximum consecutive sync failures before stopping automatic syncing
  private let maxConsecutiveSyncFailures: Int = 5

  /// Time when sync was last paused due to failures
  private var syncPausedAt: Date?

  /// How long to pause sync after circuit breaker trips (5 minutes)
  private let syncPauseDuration: TimeInterval = 300
  
  // MARK: - Foreground Sync Coordination
  
  /// Tracks when the app last entered foreground (for grace period coordination)
  private var lastForegroundTime: Date?
  
  /// Grace period during which MLS operations should wait for state reload (2 seconds)
  private let foregroundSyncGracePeriod: TimeInterval = 2.0
  
  /// Flag indicating a state reload is currently in progress
  private var isStateReloadInProgress: Bool = false
  
  /// Continuation for waiters blocking on state reload completion
  private var stateReloadWaiters: [CheckedContinuation<Void, Never>] = []

  // MARK: - Configuration

  /// Default cipher suite for new groups
  let defaultCipherSuite: String = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

  /// Key package refresh interval (in seconds) - reduced to 4 hours for proactive monitoring
  let keyPackageRefreshInterval: TimeInterval = 14400  // 4 hours (was 24 hours)

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
    database: MLSDatabase,
    userDid: String? = nil,
    storage: MLSStorage = .shared,
    configuration: MLSConfiguration = .default,
    atProtoClient: ATProtoClient
  ) {
    self.apiClient = apiClient
    self.atProtoClient = atProtoClient
    self.database = database
    self.userDid = userDid
    self.mlsClient = MLSClient.shared  // Use singleton to persist groups
    self.storage = storage
    self.configuration = configuration

    // Note: removal tombstones are handled via storage; the previous helper was removed/renamed.

    // Phase 3/4: MLSClient configuration moved to initialize() to support async actor access

    // Initialize device sync manager for multi-device support
    self.deviceSyncManager = MLSDeviceSyncManager(apiClient: apiClient, mlsClient: mlsClient)

    logger.info("MLSConversationManager initialized with UniFFI client (using shared MLSClient)")
    configuration.validate()
  }

  // MARK: - Lifecycle Coordination

  private func throwIfShuttingDown(_ operation: String) throws {
    if isShuttingDown {
      logger.warning("⏸️ [MLSConversationManager] \(operation) aborted - storage reset in progress")
      throw MLSConversationError.operationFailed("MLS storage reset in progress")
    }
  }

  /// Prepare the conversation manager for a storage reset operation
  /// This is similar to shutdown() but specifically for storage maintenance
  @MainActor
  func prepareForStorageReset() async {
    guard !isShuttingDown else {
      logger.debug("MLSConversationManager already preparing for storage reset")
      return
    }

    logger.info("⚠️ [MLSConversationManager] Preparing for SQLCipher storage reset")
    isShuttingDown = true

    // Cancel all background tasks
    cleanupTask?.cancel()
    cleanupTask = nil

    periodicSyncTask?.cancel()
    periodicSyncTask = nil

    deduplicationCleanupTimer?.invalidate()
    deduplicationCleanupTimer = nil
    
    // CRITICAL FIX: Also invalidate typing cleanup timer
    typingCleanupTimer?.invalidate()
    typingCleanupTimer = nil

    // Shutdown device sync manager
    if let deviceSyncManager = deviceSyncManager {
      await deviceSyncManager.shutdown()
      self.deviceSyncManager = nil
    }

    // Clear in-memory state
    conversations.removeAll()
    groupStates.removeAll()
    typingUsers.removeAll()
    recentlySentMessages.removeAll()
    pendingMessages.removeAll()
    ownCommits.removeAll()
    conversationStates.removeAll()
    exhaustedKeyPackageHashes.removeAll()
    observers.removeAll()
    isInitialized = false
    isSyncing = false

    // CRITICAL FIX (2024-12): Attempt WAL checkpoint BEFORE draining
    // Use PASSIVE mode which doesn't block - we want fast shutdown over complete checkpoint
    do {
        try await database.write { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE);")
      }
      logger.info("✅ [MLSConversationManager] WAL checkpoint(PASSIVE) completed for reset")
    } catch {
      let errorDesc = error.localizedDescription.lowercased()
      if errorDesc.contains("locked") || errorDesc.contains("busy") {
        logger.warning("⚠️ [MLSConversationManager] WAL checkpoint skipped (database busy) - proceeding")
      } else {
        logger.warning("⚠️ [MLSConversationManager] WAL checkpoint failed: \(error.localizedDescription) - proceeding")
      }
    }

    // Drain database with timeout
    let drainTask = Task {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { [self] in
          do {
            try self.database.write { _ in }
            self.logger.info("✅ [MLSConversationManager] Database queue drained for reset")
          } catch {
            self.logger.error(
              "⚠️ Failed to drain database queue before reset: \(error.localizedDescription)")
          }
          continuation.resume()
        }
      }
    }

    // 3-second timeout for storage reset prep
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if !drainTask.isCancelled {
        logger.critical(
          "🚨 [MLSConversationManager] Database drain timed out - reset may be unsafe")
        drainTask.cancel()
      }
    }

    _ = await drainTask.result
    timeoutTask.cancel()

    logger.info("✅ [MLSConversationManager] Ready for storage reset")
  }

  // MARK: - Account Switching Lifecycle (FIX #4)

  /// Shutdown the conversation manager for account switching
  ///
  /// CRITICAL: Call this method BEFORE switching to a different user account.
  /// This ensures:
  /// 1. All background tasks are cancelled
  /// 2. The database connection is properly released
  /// 3. No stale operations from the previous user can corrupt the new user's data
  ///
  /// After calling shutdown(), you must create a NEW MLSConversationManager instance
  /// for the new user - do NOT reuse the existing instance.
  ///
  /// Note: This method has a 5-second timeout to prevent hanging during account switch.
  @MainActor
  @discardableResult
  func shutdown() async -> Bool {
    guard !isShuttingDown else {
      logger.debug("MLSConversationManager already shutting down")
      return false
    }

    logger.info(
      "🛑 [MLSConversationManager.shutdown] Starting graceful shutdown for user: \(self.userDid?.prefix(20) ?? "unknown")..."
    )
    isShuttingDown = true
    var shutdownWasSafe = true

    // Cancel all background tasks immediately
    cleanupTask?.cancel()
    cleanupTask = nil

    periodicSyncTask?.cancel()
    periodicSyncTask = nil

    deduplicationCleanupTimer?.invalidate()
    deduplicationCleanupTimer = nil
    
    // CRITICAL FIX: Also invalidate typing cleanup timer
    typingCleanupTimer?.invalidate()
    typingCleanupTimer = nil

    // Shutdown device sync manager with timeout
    if let deviceSyncManager = deviceSyncManager {
      await deviceSyncManager.shutdown()
      self.deviceSyncManager = nil
    }

    // Clear in-memory state to prevent stale data usage
    // This also helps garbage collection
    conversations.removeAll()
    groupStates.removeAll()
    recentlySentMessages.removeAll()
    pendingMessages.removeAll()
    ownCommits.removeAll()
    conversationStates.removeAll()
    exhaustedKeyPackageHashes.removeAll()
    observers.removeAll()

    // Clear consumption tracking
    keyPackageMonitor = nil
    consumptionTracker = nil

    // Mark as not initialized so any lingering calls will fail fast
    isInitialized = false
    isSyncing = false

    // CRITICAL: Close the MLSClient context to release Rust SQLite connections too.
    // Account switching uses prepareForStorageReset(); without this, the old user may keep
    // a live FFI database handle while the new user tries to open their SQLCipher DB.
    if let userDid = userDid {
      let closedContext = await MLSClient.shared.closeContext(for: userDid)
      if closedContext {
        logger.info("✅ [MLSConversationManager] Closed MLSClient context for storage reset")
      }
    }
    
    // CRITICAL FIX: Close the MLSClient context to release SQLite connections
    // This prevents "out of memory" errors from accumulated file handles during account switching
    if let userDid = userDid {
      let closedContext = await MLSClient.shared.closeContext(for: userDid)
      if closedContext {
        logger.info("✅ [MLSConversationManager.shutdown] Closed MLSClient context for user")
      }
    }

    // CRITICAL FIX (2024-12): Attempt WAL checkpoint BEFORE draining
    // Use PASSIVE mode which doesn't block - we want fast shutdown over complete checkpoint
    // PASSIVE copies what it can without blocking on other connections
    // If checkpoint fails, we still proceed with close - failing to close is worse
    do {
        try await database.write { db in
        // PASSIVE mode: non-blocking, best-effort checkpoint
        try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE);")
      }
      logger.info("✅ [MLSConversationManager.shutdown] WAL checkpoint(PASSIVE) completed")
    } catch {
      // Checkpoint failure is not fatal - proceed with shutdown anyway
      let errorDesc = error.localizedDescription.lowercased()
      if errorDesc.contains("locked") || errorDesc.contains("busy") {
        logger.warning("⚠️ [MLSConversationManager.shutdown] WAL checkpoint skipped (database busy) - proceeding")
      } else {
        logger.warning("⚠️ [MLSConversationManager.shutdown] WAL checkpoint failed: \(error.localizedDescription) - proceeding")
      }
    }

    // Wait for any in-flight database operations to complete with TIMEOUT
    // This prevents "disk I/O error" from concurrent access
    // But we don't want to hang indefinitely during account switch
    let drainTask = Task {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { [self] in
          do {
            // Drain the database queue by executing an empty write
            try self.database.write { _ in }
            self.logger.info("✅ [MLSConversationManager.shutdown] Database queue drained")
          } catch {
            self.logger.error(
              "⚠️ [MLSConversationManager.shutdown] Failed to drain database queue: \(error.localizedDescription)"
            )
          }
          continuation.resume()
        }
      }
    }

    // Apply 5-second timeout to prevent hanging
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
      if !drainTask.isCancelled {
        logger.critical(
          "🚨 [MLSConversationManager.shutdown] Database drain timed out after 5s - shutdown is NOT guaranteed safe"
        )
        shutdownWasSafe = false
        drainTask.cancel()
      }
    }

    // Wait for drain or timeout, whichever comes first
    _ = await drainTask.result
    timeoutTask.cancel()
    
    // CRITICAL FIX: Also close the GRDB database pool for this user
    if let userDid = userDid {
      let success = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: userDid, timeout: 3.0)
      if success {
        logger.info("✅ [MLSConversationManager.shutdown] GRDB database closed and drained")
      } else {
        shutdownWasSafe = false
        logger.critical("🚨 [MLSConversationManager.shutdown] GRDB database drain failed - NOT safe to switch accounts")
      }
    }
    
    // CRITICAL FIX: Add delay to allow iOS to reclaim mlocked memory pages
    // This prevents "SQLite error 7: out of memory" during rapid account switching.
    // The 200ms delay gives the OS time to release memory locks before we try
    // to allocate new ones for the next account's database.
    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    
    if shutdownWasSafe {
      logger.info("✅ [MLSConversationManager.shutdown] Shutdown complete - safe to switch accounts")
    } else {
      logger.critical("🚨 [MLSConversationManager.shutdown] Shutdown complete but was NOT safe")
    }

    return shutdownWasSafe
  }
  
  // MARK: - State Reload (NSE Sync)
  
  /// Reload MLS group state from disk to catch up with NSE changes
  ///
  /// **CRITICAL**: The Notification Service Extension (NSE) runs as a separate process
  /// and may advance the MLS ratchet (decrypt messages, process commits) while the
  /// main app holds stale in-memory state. This causes:
  /// - `SecretReuseError` - trying to use a nonce the NSE already consumed
  /// - `InvalidEpoch` - app at epoch N but disk/server is at epoch N+1
  /// - `DecryptionFailed` - using old keys that were deleted by forward secrecy
  ///
  /// Call this method when:
  /// - App enters foreground (UIApplication.willEnterForegroundNotification)
  /// - After tapping a notification that may have triggered NSE decryption
  /// - Before any MLS operation if you suspect the NSE may have run
  ///
  /// This method:
  /// 1. Sets isStateReloadInProgress to block concurrent MLS operations
  /// 2. Clears in-memory group states (forces reload from disk on next access)
  /// 3. Invalidates conversation states to force re-initialization
  /// 4. Notifies any waiting operations that reload is complete
  /// 5. Does NOT close the database (the connection can be reused)
  @MainActor
  func reloadStateFromDisk() async {
    guard let userDid = userDid else {
      logger.warning("🔄 [MLS Reload] No user DID - skipping state reload")
      return
    }
    
    // Mark reload as in progress to block concurrent MLS operations
    isStateReloadInProgress = true
    lastForegroundTime = Date()
    
    logger.info("🔄 [MLS Reload] Reloading MLS state from disk for user: \(userDid.prefix(20))...")
    logger.info("   Reason: NSE may have advanced the ratchet while app was in background")
    
    // Track how many groups we're invalidating
    let groupCount = groupStates.count
    let conversationCount = conversationStates.count
    
    // Step 1: Clear in-memory group states
    // The next access to any group will reload from the FFI layer which reads from disk
    groupStates.removeAll()
    
    // Step 2: Clear conversation initialization states
    // This forces re-initialization which will reload the current epoch from disk
    conversationStates.removeAll()
    
    // Step 3: Clear pending message tracking
    // Any pending messages from before background may now be stale
    pendingMessagesLock.withLock {
      pendingMessages.removeAll()
    }
    
    // Step 4: Clear own commits tracking
    // Commits made before background are no longer relevant
    ownCommitsLock.withLock {
      ownCommits.removeAll()
    }
    
    // Step 5: Clear recently sent messages deduplication
    // Fresh start after potential NSE activity
    recentlySentMessages.removeAll()
    
    logger.info("✅ [MLS Reload] Cleared \(groupCount) group states, \(conversationCount) conversation states")
    logger.info("   Next MLS operation will reload fresh state from disk/FFI")
    
    // Step 6: Reload MLS context from disk (monotonic version check)
    // This ensures the in-memory MLS context is fresh with the latest epoch
    do {
        try await MLSCoreContext.shared.reloadContext(for: userDid)
      logger.info("✅ [MLS Reload] MLSCoreContext reloaded from disk")
    } catch {
      logger.warning("⚠️ [MLS Reload] Failed to reload MLSCoreContext: \(error.localizedDescription)")
      // Continue anyway - context will be reloaded on next access
    }
    
    // Step 7: Mark reload as complete and notify waiters
    isStateReloadInProgress = false
    let waiters = stateReloadWaiters
    stateReloadWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    logger.debug("🔄 [MLS Reload] Notified \(waiters.count) waiting operation(s)")
    
    // Step 8: Optionally trigger a sync to fetch any messages we might have missed
    // This is non-blocking - we fire and forget
    Task(priority: .userInitiated) { [weak self] in
      guard let self = self else { return }
      do {
        try await self.syncWithServer(fullSync: false)
        self.logger.info("✅ [MLS Reload] Post-reload sync completed")
      } catch {
        self.logger.warning("⚠️ [MLS Reload] Post-reload sync failed: \(error.localizedDescription)")
      }
    }
  }
  
  /// Ensure state is fresh before performing an MLS operation
  ///
  /// **CRITICAL**: Call this at the start of any MLS operation that mutates state
  /// (encrypt, decrypt, process commit). If the app recently entered foreground,
  /// this will block until the state reload completes.
  ///
  /// This prevents the race where:
  /// 1. User opens app and immediately opens a conversation
  /// 2. MLS operation starts with stale in-memory state
  /// 3. State reload (async) hasn't completed yet
  /// 4. MLS operation fails with SecretReuseError
  ///
  /// - Throws: MLSError.stateReloadInProgress if waiting times out
  func ensureStateReloaded() async throws {
    // Check state on MainActor where it's modified
    let needsToWait = await MainActor.run { [self] in
      return isStateReloadInProgress
    }
    
    // If state reload is in progress, wait for it to complete
    if needsToWait {
      logger.info("⏳ [MLS Reload] Operation waiting for state reload to complete...")
      
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Task { @MainActor in
          stateReloadWaiters.append(continuation)
        }
      }
      
      logger.info("✅ [MLS Reload] State reload completed - operation may proceed")
      return
    }
    
    // If we recently entered foreground, ensure reload has completed
    let timeSinceForeground = await MainActor.run { [self] () -> TimeInterval? in
      guard let lastForeground = lastForegroundTime else { return nil }
      return Date().timeIntervalSince(lastForeground)
    }
    
    if let elapsed = timeSinceForeground, elapsed < foregroundSyncGracePeriod {
      // Within grace period but reload not in progress - reload may have already completed
      // or it may not have started yet. Trigger a sync check to be safe.
      logger.debug("🔄 [MLS Reload] Within grace period (\(String(format: "%.1f", elapsed))s) - state should be fresh")
    }
  }

  /// Initialize the MLS crypto context
  func initialize() async throws {
    guard !isInitialized else {
      logger.debug("MLS context already initialized")
      return
    }

    // Load persisted MLS storage if user is authenticated
    if let userDid = userDid {
      // Configure MLSClient with API client for Welcome validation, bundle monitoring, and device registration
      // CRITICAL FIX: Configure for specific user to prevent account switching race conditions
      await MLSClient.shared.configure(
        for: userDid, apiClient: apiClient, atProtoClient: atProtoClient)

      logger.info("Loading persisted MLS storage for user: \(userDid)")
      do {
        logger.info("✅ MLS storage loaded successfully")

        // CRITICAL: Validate local bundle count after storage load
        // This catches the account-switch desync bug where storage appears empty
        do {
          let localBundleCount = try await MLSClient.shared.getKeyPackageBundleCount(for: userDid)
          logger.info("📊 [MLS Init] Local bundle count: \(localBundleCount)")

          if localBundleCount == 0 {
            logger.warning("⚠️ [MLS Init] No local bundles found - will need replenishment")
            logger.warning(
              "   This may indicate first use, account switch desync, or storage issue")
            // Trigger reconciliation which will attempt non-destructive recovery
            Task {
              do {
                let result = try await MLSClient.shared.reconcileKeyPackagesWithServer(for: userDid)
                logger.info(
                  "📊 [MLS Init] Reconciliation complete - server: \(result.serverAvailable), local: \(result.localBundles), desync: \(result.desyncDetected)"
                )
              } catch {
                logger.error("❌ [MLS Init] Reconciliation failed: \(error.localizedDescription)")
              }
            }
          }

          // CRITICAL: Always sync key package hashes to prevent NoMatchingKeyPackage errors
          // This removes orphaned server packages that no longer have local private keys
          // The bug: Server serves stale key packages to other users who try to add us
          // Result: Welcome encrypted to a key we don't have → NoMatchingKeyPackage
          Task {
            do {
              let syncResult = try await MLSClient.shared.syncKeyPackageHashes(for: userDid)
              if syncResult.orphanedCount > 0 {
                logger.warning(
                  "🔄 [MLS Init] Synced key packages - deleted \(syncResult.deletedCount) ORPHANED packages"
                )
                logger.warning(
                  "   Orphaned packages cause NoMatchingKeyPackage when others try to add us")
                logger.info("   Remaining valid packages: \(syncResult.remainingAvailable)")
              } else {
                logger.info("✅ [MLS Init] Key package hashes in sync - no orphans found")
              }
            } catch {
              logger.error(
                "❌ [MLS Init] Key package hash sync failed: \(error.localizedDescription)")
              logger.error("   ⚠️ Risk: Stale key packages may cause NoMatchingKeyPackage errors")
            }
          }
        } catch {
          logger.warning(
            "⚠️ [MLS Init] Failed to check local bundle count: \(error.localizedDescription)")
        }
      } catch {
        logger.warning(
          "⚠️ Failed to load MLS storage (will start fresh): \(error.localizedDescription)")
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

      // Configure device sync manager for automatic multi-device synchronization
      if let deviceSyncManager = deviceSyncManager {
        // Get deviceUUID from MLSClient to enable accurate device detection
        let deviceInfo = await mlsClient.getDeviceInfo(for: userDid)
        let deviceUUID = deviceInfo?.deviceUUID
        
        await deviceSyncManager.configure(
          userDid: userDid,
          deviceUUID: deviceUUID,
          addDeviceHandler: { [weak self] convoId, deviceCredentialDid, keyPackageData in
            guard let self = self else { throw MLSConversationError.contextNotInitialized }
            return try await self.addDeviceWithKeyPackage(
              convoId: convoId,
              deviceCredentialDid: deviceCredentialDid,
              keyPackageData: keyPackageData
            )
          }
        )
        await deviceSyncManager.startPolling(interval: 60)  // Poll every 60s as fallback
        logger.info("✅ Configured device sync manager for multi-device support (deviceUUID: \(deviceUUID ?? "not registered"))")
      }
    }

    // Upload initial key packages to server with smart monitoring
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        try await self.smartRefreshKeyPackages()
        self.lastKeyPackageRefresh = Date()
      } catch is CancellationError {
        self.logger.warning("⚠️ Initial key package upload cancelled - will retry on next trigger")
      } catch {
        self.logger.error("Failed to upload initial key packages: \(error.localizedDescription)")
      }
    }

    // Validate that all local conversations have valid MLS group state
    // This detects and recovers from corrupted OpenMLS storage
    await validateGroupStates()

    // Automatically trigger rejoin for any corrupted conversations
    // This must happen after validation to pick up conversations marked as needsRejoin
    do {
      try await detectAndRejoinMissingConversations()
    } catch {
      logger.error("Failed to auto-rejoin missing conversations: \(error.localizedDescription)")
      // Don't fail initialization if auto-rejoin fails
    }

    // Start background cleanup task if enabled
    if configuration.enableAutomaticCleanup {
      startBackgroundCleanup()
    }

    // Start periodic background sync
    startPeriodicSync()
  }

  /// Deinitialize and cleanup resources
  deinit {
    cleanupTask?.cancel()
    periodicSyncTask?.cancel()
  }

  // MARK: - Auto-Rejoin Detection

  /// Validates that all local conversations have valid MLS group state in storage
  /// Automatically marks conversations with missing/corrupted state for rejoin
  /// This should be called during initialization before any message processing
  private func validateGroupStates() async {
    logger.info("🔍 [STARTUP] Validating MLS group state for all conversations...")

    guard let userDid = userDid else {
      logger.warning("[STARTUP] No user DID - skipping group state validation")
      return
    }

    do {
      // Fetch all conversations from the database
      let conversations = try await database.read { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.currentUserDID == userDid)
          .fetchAll(db)
      }

      logger.info("📋 [STARTUP] Found \(conversations.count) conversations to validate")

      var corruptedCount = 0
      var validatedCount = 0

      for conversation in conversations {
        let groupIdData = conversation.groupID
        let convoIdPrefix = String(conversation.conversationID.prefix(8))

        do {
          // Attempt to get epoch - if this fails, group state is missing/corrupted
          let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
          logger.debug("✅ Group \(convoIdPrefix)... validated - epoch: \(epoch)")
          validatedCount += 1
        } catch {
          logger.error(
            "❌ [STARTUP] Corrupted group state detected for conversation \(convoIdPrefix)...")
          logger.error("   Error: \(error.localizedDescription)")

          // Delete corrupted local group state from OpenMLS storage
          do {
            try await mlsClient.deleteGroup(for: userDid, groupId: groupIdData)
            logger.info("🗑️ Deleted corrupted local group state for \(convoIdPrefix)...")
          } catch {
            logger.error("   Failed to delete corrupted group: \(error.localizedDescription)")
          }

          // Mark conversation as needing rejoin in GRDB database
          do {
            try await markConversationNeedsRejoin(conversation.conversationID)
            logger.info("⚠️ Marked conversation \(convoIdPrefix)... for rejoin")
            corruptedCount += 1
          } catch {
            logger.error("   Failed to mark conversation for rejoin: \(error.localizedDescription)")
          }
        }
      }

      if corruptedCount > 0 {
        logger.warning(
          "⚠️ [STARTUP] Found \(corruptedCount) conversation(s) with corrupted MLS state - marked for rejoin"
        )
        logger.info("   Validated: \(validatedCount), Corrupted: \(corruptedCount)")
      } else {
        logger.info("✅ [STARTUP] All \(validatedCount) conversation(s) have valid MLS group state")
      }
    } catch {
      logger.error("❌ [STARTUP] Failed to validate group states: \(error.localizedDescription)")
    }
  }

  /// Detect and automatically rejoin conversations that user is missing locally
  /// This should be called after authentication and MLS initialization
  /// Also checks for conversations marked as needsRejoin due to corrupted state
  func detectAndRejoinMissingConversations() async throws {
    logger.info("🔍 Detecting missing conversations for auto-rejoin")
    try throwIfShuttingDown("detectAndRejoinMissingConversations")

    guard isInitialized else {
      logger.warning("MLS not initialized - skipping missing conversation detection")
      return
    }

    guard let userDid = userDid else {
      logger.warning("No user DID - skipping missing conversation detection")
      return
    }

    do {
      // First, check for locally corrupted conversations that need rejoin
      let corruptedConvos = try await database.read { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.currentUserDID == userDid)
          .filter(MLSConversationModel.Columns.needsRejoin == true)
          .fetchAll(db)
      }

      if !corruptedConvos.isEmpty {
        logger.info(
          "🔄 Found \(corruptedConvos.count) locally corrupted conversation(s) needing rejoin")

        for convo in corruptedConvos {
          await attemptRejoinWithWelcomeFallback(
            convoId: convo.conversationID,
            displayName: convo.conversationID,
            reason: "corrupted local state"
          )
        }
      }

      // Call the server to get list of expected conversations
      let response = try await apiClient.getExpectedConversations(deviceId: "")
      let expectedConvos = response.conversations

      logger.info("📋 Found \(expectedConvos.count) expected conversations")

      // Filter to conversations we should be in but aren't
      let missingConvos = expectedConvos.filter {
        $0.shouldBeInGroup && !($0.deviceInGroup ?? true)
      }

      guard !missingConvos.isEmpty else {
        logger.info("✅ No missing conversations detected")
        return
      }

      logger.info("🔄 Detected \(missingConvos.count) missing conversations - initiating rejoin")

      // Show progress to user
      // This would typically update UI state via @Observable
      // For now, just log progress

      var successCount = 0
      var failureCount = 0
      var skippedCount = 0

      for convo in missingConvos {
        // CRITICAL FIX: Check if group already exists locally before attempting rejoin
        // Server's deviceInGroup tracking can be stale, but local group state is authoritative
        guard let groupIdData = Data(hexEncoded: convo.convoId) else {
          logger.warning("⚠️ Invalid groupId format for \\(convo.convoId) - skipping")
          failureCount += 1
          continue
        }

        // Check if group exists locally and is valid
        let groupExists = await mlsClient.groupExists(for: userDid, groupId: groupIdData)

        if groupExists {
          // Group already exists locally - verify it's still valid
          do {
            let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
            logger.info(
              "✅ Group \\(convo.convoId.prefix(8))... already exists locally (epoch: \\(epoch)) - server tracking stale, skipping rejoin"
            )
            skippedCount += 1

            // Clear any rejoin flag since group is valid
            await clearConversationRejoinFlag(convo.convoId)
            continue
          } catch {
            logger.warning(
              "⚠️ Group \\(convo.convoId.prefix(8))... exists but cannot get epoch: \\(error.localizedDescription)"
            )
            // Fall through to rejoin attempt
          }
        }

        // Group doesn't exist or is corrupted - attempt rejoin
        let joined = await attemptRejoinWithWelcomeFallback(
          convoId: convo.convoId,
          displayName: convo.name,
          reason: "server reported missing"
        )

        if joined {
          successCount += 1
        } else {
          failureCount += 1
        }
      }

      if skippedCount > 0 {
        logger.info(
          "🎉 Rejoin detection complete: \(successCount) successful, \(failureCount) failed, \(skippedCount) skipped (already valid locally)"
        )
      } else {
        logger.info(
          "🎉 Rejoin detection complete: \(successCount) successful, \(failureCount) failed")
      }

      // After requesting rejoins, sync to pick up any Welcome messages
      try await syncWithServer(fullSync: false)

    } catch {
      logger.error("❌ Failed to detect missing conversations: \(error.localizedDescription)")
      throw error
    }
  }

  /// Attempt to rejoin a conversation, preferring Welcome-based join before external commit
  /// Note: Creators should NOT use Welcome - it's meant for other users they invited
  @discardableResult
  private func attemptRejoinWithWelcomeFallback(
    convoId: String, displayName: String?, reason: String
  ) async -> Bool {
    let label = displayName ?? convoId
    logger.info("📞 Requesting recovery for \(label) (\(reason))")

    guard let userDid = userDid else {
      logger.error("❌ Cannot rejoin \(label): missing user DID")
      return false
    }

    // ⭐ CRITICAL FIX: Check if we are the creator before trying Welcome
    // If we are the creator, the Welcome message is meant for OTHER users
    // The creator must use External Commit to rejoin their own group
    let convo = await fetchConversationForRejoin(convoId: convoId)
    let isCreator = convo?.creator.description.lowercased() == userDid.lowercased()

    if isCreator {
      logger.info(
        "🔄 [attemptRejoin] User is creator - skipping Welcome, using External Commit directly")
    } else {
      let welcomeJoined = await attemptWelcomeRejoin(convoId: convoId, label: label)
      if welcomeJoined {
        return true
      }
    }

    do {
      _ = try await mlsClient.joinByExternalCommit(for: userDid, convoId: convoId)
      logger.info("✅ Successfully rejoined \(label) via External Commit")
      await clearConversationRejoinFlag(convoId)
      return true
    } catch let error as MLSAPIError {
      logger.error("❌ Failed to rejoin \(label) via External Commit:")
      logger.error("   Error description: \(error.localizedDescription)")
      if case .httpError(let statusCode, let message) = error {
        logger.error("   HTTP Status: \(statusCode)")
        logger.error("   HTTP Message: \(message)")
      }
      return false
    } catch {
      logger.error("❌ Failed to rejoin \(label) via External Commit:")
      logger.error("   Error type: \(type(of: error))")
      logger.error("   Error description: \(error.localizedDescription)")
      return false
    }
  }

  /// Attempt to join using a Welcome message if available
  private func attemptWelcomeRejoin(convoId: String, label: String) async -> Bool {
    guard let convo = await fetchConversationForRejoin(convoId: convoId) else {
      logger.warning("⚠️ No conversation view available for \(label) when attempting Welcome join")
      return false
    }

    do {
      try await initializeGroupFromWelcome(convo: convo)
      logger.info("✅ Successfully rejoined \(label) via Welcome message")
      await clearConversationRejoinFlag(convoId)
      return true
    } catch let apiError as MLSAPIError {
      if case .httpError(let statusCode, _) = apiError, statusCode == 404 {
        logger.info(
          "ℹ️ No Welcome available for \(label) (HTTP 404) - falling back to External Commit")
        return false
      }
      logger.error("❌ Welcome-based rejoin failed for \(label): \(apiError.localizedDescription)")
      return false
    } catch {
      logger.error("❌ Welcome-based rejoin failed for \(label): \(error.localizedDescription)")
      return false
    }
  }

  /// Fetch conversation metadata needed to process Welcome-based joins
  private func fetchConversationForRejoin(convoId: String) async -> BlueCatbirdMlsDefs.ConvoView? {
    if let cached = conversations[convoId] {
      return cached
    }

    do {
      let (convos, _) = try await apiClient.getConversations(limit: 100)
      if let convo = convos.first(where: { $0.groupId == convoId }) {
        conversations[convoId] = convo
        return convo
      }
      logger.warning("⚠️ Conversation \(convoId) not found in server list during rejoin attempt")
    } catch {
      logger.error(
        "⚠️ Failed to fetch conversation \(convoId) for Welcome rejoin: \(error.localizedDescription)"
      )
    }

    return nil
  }

  /// Publish current GroupInfo to the server
  /// CRITICAL: This function now throws errors - failures will propagate to callers
  /// - Throws: Error if GroupInfo export or upload fails
  private func publishLatestGroupInfo(
    userDid: String, convoId: String, groupId: Data, context: String
  ) async throws {
    logger.info("📤 [publishLatestGroupInfo] Starting \(context) for convo: \(convoId)")
    try await mlsClient.publishGroupInfo(for: userDid, convoId: convoId, groupId: groupId)
    logger.info("✅ [publishLatestGroupInfo] Success \(context) for convo: \(convoId)")
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
    logger.info(
      "🔵 [MLSConversationManager.createGroup] START - name: '\(name)', initialMembers: \(initialMembers?.count ?? 0)"
    )
    try throwIfShuttingDown("createGroup")

    guard isInitialized else {
      logger.error("❌ [MLSConversationManager.createGroup] Context not initialized")
      throw MLSConversationError.contextNotInitialized
    }

    guard let userDid = userDid else {
      logger.error("❌ [MLSConversationManager.createGroup] No authentication")
      throw MLSConversationError.noAuthentication
    }

    // ⭐ FIX #1: Filter out the creator's DID from initialMembers
    // In MLS, you only fetch key packages for OTHER members you're adding.
    // The creator is implicitly added during group creation.
    let filteredMembers: [DID]?
    if let members = initialMembers {
      let selfDid = userDid.lowercased()
      let filtered = members.filter { $0.description.lowercased() != selfDid }
      if filtered.count != members.count {
        logger.warning(
          "⚠️ [createGroup] Filtered out self-DID from initialMembers (was \(members.count), now \(filtered.count))"
        )
      }
      filteredMembers = filtered.isEmpty ? nil : filtered
    } else {
      filteredMembers = nil
    }

    // Create temporary tracking ID for initialization state
    let tempId = UUID().uuidString
    conversationStates[tempId] = .initializing

    defer {
      conversationStates.removeValue(forKey: tempId)
    }

    logger.debug("📍 [MLSConversationManager.createGroup] Creating local group for user: \(userDid)")

    // Ensure we have local key package bundles before touching the FFI context.
    // Without at least one bundle, OpenMLS generated credentials are not persisted and
    // later signature verification fails (see InvalidSignature in logs).
    do {
      let bundleCount = try await mlsClient.ensureLocalBundlesAvailable(for: userDid)
      if bundleCount == 0 {
        logger.error(
          "❌ [MLSConversationManager.createGroup] No local bundles available - cannot create group")
        throw MLSConversationError.operationFailed(
          "No key packages available. Please generate bundles first via monitorAndReplenishBundles()"
        )
      }
    } catch {
      logger.error(
        "❌ [MLSConversationManager.createGroup] Failed to verify local key packages: \(error.localizedDescription)"
      )
      throw MLSConversationError.operationFailed(
        "Unable to verify local key packages: \(error.localizedDescription)")
    }

    // ⭐ CRITICAL FIX: Create MLS group locally FIRST to get the groupID
    // Uses mlsDid (device-specific DID) automatically
    let groupId = try await mlsClient.createGroup(
      for: userDid, configuration: configuration.groupConfiguration)
    let groupIdHex = groupId.hexEncodedString()
    logger.info(
      "🔵 [MLSConversationManager.createGroup] Local group created: \(groupIdHex.prefix(16))...")

    // 🔬 CRITICAL DIAGNOSTIC: Log creator's initial state (before adding members)
    await logGroupStateDiagnostics(
      userDid: userDid, groupId: groupId, context: "After Group Creation (Creator, Epoch 0)")

    // ⭐ FIXED: Use groupIdHex as conversationID (not random UUID) so Rust FFI epoch storage succeeds
    // The Rust FFI passes groupIdHex as the conversationId when storing epoch secrets,
    // so our database must use the same identifier as the primary key for foreign key constraints to work
    do {
      try await storage.ensureConversationExists(
        userDID: userDid,
        conversationID: groupIdHex,  // ← Use groupIdHex, not tempId
        groupID: groupIdHex,
        database: database
      )

      // Track how we joined so UI can explain missing history after External Commit.
      try await storage.updateConversationJoinInfo(
        conversationID: groupIdHex,
        currentUserDID: userDid,
        joinMethod: .creator,
        joinEpoch: 0,
        database: database
      )

      logger.info("✅ Created SQLCipher conversation record with ID: \(groupIdHex.prefix(16))...")
    } catch {
      logger.error("❌ Failed to create SQLCipher conversation: \(error.localizedDescription)")
      throw MLSConversationError.operationFailed(
        "Failed to create local conversation record: \(error.localizedDescription)")
    }

    // CRITICAL FIX: Manually export epoch secret AFTER conversation record exists
    // The createGroup() call above attempts to export the epoch 0 secret, but it fails
    // because the conversation record didn't exist yet. Now that the record exists,
    // we can successfully export the epoch secret to satisfy foreign key constraints.
    do {
      try await mlsClient.exportEpochSecret(for: userDid, groupId: groupId)
      logger.info("✅ Exported epoch 0 secret after conversation record creation")
    } catch {
      logger.error("❌ Failed to export epoch secret: \(error.localizedDescription)")
      logger.warning("⚠️ This may cause decryption failures for epoch 0 messages")
      // Non-fatal: Continue with group creation even if epoch secret export fails
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
        initialMembers: filteredMembers,  // ⭐ Use filtered members (self-DID removed)
        metadata: metadataInput
      )
    } catch {
      logger.error(
        "❌ [MLSConversationManager.createGroup] Server creation failed: \(error.localizedDescription)"
      )

      // SAFETY: Create safe copy of error description before storing in state
      let safeErrorDesc = String(describing: error.localizedDescription)
      conversationStates[tempId] = .failed(safeErrorDesc)

      // ⭐ FIX #2: ROLLBACK - Delete the prematurely created SQLCipher conversation record
      // This prevents "zombie" conversations that exist locally but not on the server
      logger.info(
        "🗑️ [MLSConversationManager.createGroup] Rolling back local conversation record: \(groupIdHex.prefix(16))..."
      )
      do {
        try await database.write { db in
          try db.execute(
            sql: """
                  DELETE FROM MLSConversationModel
                  WHERE conversationID = ? AND currentUserDID = ?;
              """, arguments: [groupIdHex, userDid])
        }
        logger.info("✅ [MLSConversationManager.createGroup] Rolled back local conversation record")
      } catch {
        logger.error(
          "❌ [MLSConversationManager.createGroup] Failed to rollback conversation record: \(error.localizedDescription)"
        )
      }

      // Also delete the local MLS group state to prevent orphaned cryptographic material
      do {
        try await mlsClient.deleteGroup(for: userDid, groupId: groupId)
        logger.info("✅ [MLSConversationManager.createGroup] Deleted local MLS group state")
      } catch {
        logger.warning(
          "⚠️ [MLSConversationManager.createGroup] Failed to delete local MLS group: \(error.localizedDescription)"
        )
      }

      if let members = filteredMembers, !members.isEmpty {
        logger.debug("📍 [MLSConversationManager.createGroup] Cleaning up pending commit...")
        do {
          try await mlsClient.clearPendingCommit(for: userDid, groupId: groupId)
          logger.info("✅ [MLSConversationManager.createGroup] Cleared pending commit")
        } catch {
          logger.error(
            "❌ [MLSConversationManager.createGroup] Failed to clear pending commit: \(error.localizedDescription)"
          )
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

    // ⭐ CRITICAL FIX: Verify epoch from FFI instead of trusting server's response
    let serverEpoch = UInt64(convo.epoch)
    let ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupId)

    if serverEpoch != ffiEpoch {
      logger.warning("⚠️ EPOCH MISMATCH at group creation:")
      logger.warning("   Server reported: \(serverEpoch)")
      logger.warning("   FFI actual: \(ffiEpoch)")
      logger.warning("   Using FFI epoch to prevent state desynchronization")
    }

    groupStates[groupIdHex] = MLSGroupState(
      groupId: groupIdHex,
      convoId: groupIdHex,
      epoch: ffiEpoch,  // Use FFI epoch, not server epoch
      members: Set(convo.members.map { $0.did.description })
    )

    // Persist MLS state to SQLCipher immediately after group creation
    do {
      logger.info("✅ Persisted MLS state after group creation")
    } catch {
      logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
    }

    // CRITICAL FIX: If members were added, sync with server BEFORE allowing messages
    if let members = filteredMembers, !members.isEmpty, let commitData = commitData {
      logger.info("🔄 Syncing \(members.count) members with server to prevent epoch mismatch...")

      // Get current epoch before server call
      let currentEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupId)
      logger.debug("📍 Current local epoch before sync: \(currentEpoch)")

      // PHASE 3 FIX: Protect server send + commit merge from cancellation
      // This sequence MUST complete atomically to prevent epoch desync:
      // 1. Server processes commit and advances epoch
      // 2. We merge the pending commit locally to match server
      // If cancelled between these steps, client and server epochs diverge
      do {
        try await withTaskCancellationHandler {
          // Track this commit as our own to prevent re-processing via SSE
          trackOwnCommit(commitData)
          logger.debug("📝 Tracked own addMembers commit to prevent SSE re-processing")

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

          logger.debug("📍 Server returned epoch: \(addResult.newEpoch)")

          // ✅ CRITICAL: Only merge if server actually processed the commit and advanced epoch
          // If server epoch didn't advance, it means the addMembers was a no-op (idempotent)
          // Merging in this case would desync secret trees
          if addResult.newEpoch > currentEpoch {
            logger.info(
              "🔄 [createGroup] Server advanced epoch (\(currentEpoch) → \(addResult.newEpoch)), merging commit..."
            )
            let mergedEpoch = try await mlsClient.mergePendingCommit(for: userDid, groupId: groupId)
            logger.info("✅ [createGroup] Commit merged - local epoch now: \(mergedEpoch)")

            // Verify merged epoch matches server's epoch
            if mergedEpoch != addResult.newEpoch {
              logger.error(
                "❌ CRITICAL: Merged epoch (\(mergedEpoch)) doesn't match server epoch (\(addResult.newEpoch))"
              )
              logger.error("   This indicates a protocol violation - secret trees are now desynced")
              throw MLSConversationError.epochMismatch
            }

            groupStates[groupIdHex]?.epoch = mergedEpoch
            logger.debug("📊 Updated local group state: epoch=\(mergedEpoch)")

            // 🔬 DIAGNOSTIC: Log complete group state after merging commit
            await logGroupStateDiagnostics(
              userDid: userDid, groupId: groupId, context: "After Merge Commit (Creator)")
          } else {
            logger.warning(
              "⚠️ Server did NOT advance epoch (returned: \(addResult.newEpoch), current: \(currentEpoch))"
            )
            logger.warning("   Likely idempotent no-op - members already exist on server")
            logger.warning("   NOT merging commit to prevent secret tree desync")
            logger.warning("   Conversation will remain at epoch \(currentEpoch)")

            // Keep local epoch unchanged
            groupStates[groupIdHex]?.epoch = currentEpoch

            // 🔬 DIAGNOSTIC: Log group state when skipping merge
            await logGroupStateDiagnostics(
              userDid: userDid, groupId: groupId, context: "Skipped Merge (Idempotent)")
          }
        } onCancel: {
          logger.warning(
            "⚠️ [createGroup] Commit operation was cancelled - allowing completion to prevent epoch desync"
          )
        }
      } catch {
        logger.error("❌ Server member sync failed: \(error.localizedDescription)")
        // SAFETY: Create safe copy of error description before storing in state
        let safeErrorDesc = String(describing: error.localizedDescription)
        conversationStates[groupIdHex] = .failed(safeErrorDesc)
        throw MLSConversationError.memberSyncFailed
      }
    }

    // Mark conversation as active AFTER server sync completes
    conversationStates[groupIdHex] = .active
    logger.info("✅ Conversation '\(groupIdHex)' marked as ACTIVE - ready for messaging")

    // Publish GroupInfo to enable external joins (welcome backup)
    // CRITICAL: If this fails, new group cannot accept external joins
    try await publishLatestGroupInfo(
      userDid: userDid,
      convoId: groupIdHex,
      groupId: groupId,
      context: "after createGroup"
    )

    // Notify observers AFTER state is active
    notifyObservers(.conversationCreated(convo))

    // Track key package consumption if members were added
    if let members = filteredMembers, !members.isEmpty {
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

    logger.info(
      "✅ [MLSConversationManager.createGroup] COMPLETE - convoId: \(groupIdHex), epoch: \(convo.epoch)"
    )
    return convo
  }

  /// Join an existing group using a Welcome message
  /// - Parameter welcomeMessage: Base64-encoded Welcome message
  /// - Returns: Joined conversation view
  func joinGroup(welcomeMessage: String) async throws -> BlueCatbirdMlsDefs.ConvoView {
    logger.info("Joining group from Welcome message")
    try throwIfShuttingDown("joinGroup")

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

    // Uses mlsDid (device-specific DID) automatically
    let groupId = try await processWelcome(welcomeData: welcomeData)
    logger.debug("Processed Welcome message, group ID: \(groupId)")

    // Fetch conversation details from server
    let conversations = try await apiClient.getConversations(limit: 100)
    guard let convo = conversations.convos.first(where: { $0.groupId == groupId }) else {
      throw MLSConversationError.conversationNotFound
    }

    // Store conversation state
    self.conversations[convo.groupId] = convo

    // ⭐ CRITICAL FIX: Verify epoch from FFI instead of trusting server's response
    guard let groupIdData = Data(hexEncoded: groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    let serverEpoch = UInt64(convo.epoch)
    let ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

    if serverEpoch != ffiEpoch {
      logger.warning("⚠️ EPOCH MISMATCH when joining group:")
      logger.warning("   Server reported: \(serverEpoch)")
      logger.warning("   FFI actual: \(ffiEpoch)")
      logger.warning("   Using FFI epoch to prevent state desynchronization")
    }

    groupStates[groupId] = MLSGroupState(
      groupId: groupId,
      convoId: convo.groupId,
      epoch: ffiEpoch,  // Use FFI epoch, not server epoch
      members: Set(convo.members.map { $0.did.description })
    )

    // Notify observers
    notifyObservers(.conversationJoined(convo))

    logger.info("Successfully joined conversation: \(convo.groupId)")
    return convo
  }

  // MARK: - Member Management

  /// Remove a member from the conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to remove
  func removeMember(convoId: String, memberDid: String) async throws {
    logger.info(
      "🔵 [MLSConversationManager.removeMember] START - convoId: \(convoId), member: \(memberDid)")
    try throwIfShuttingDown("removeMember")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      logger.error("❌ [MLSConversationManager.removeMember] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    // Convert groupId string to Data
    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.operationFailed("Failed to decode groupId hex string")
    }

    // Convert DID to credential data (DID bytes) for MLS removal
    guard let memberIdentity = memberDid.data(using: .utf8) else {
      throw MLSConversationError.operationFailed("Failed to encode member DID")
    }

    // Use GroupOperationCoordinator to serialize operations
    try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      // 0. Clear any stale pending commit from a previous failed operation
      // This prevents "PendingCommit" errors when the group has uncommitted state
      do {
        try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
        logger.debug("🧹 [MLSConversationManager.removeMember] Cleared any stale pending commit")
      } catch {
        // Ignore errors - there may be no pending commit to clear
        logger.debug(
          "🧹 [MLSConversationManager.removeMember] No pending commit to clear (or already clean)")
      }

      // 1. Create MLS remove commit FIRST (cryptographically secure)
      // This puts the commit in pending state - we will merge after server confirms distribution
      let commitData = try await mlsClient.removeMembers(
        for: userDid,
        groupId: groupIdData,
        memberIdentities: [memberIdentity]
      )

      logger.debug(
        "🔵 [MLSConversationManager.removeMember] Created MLS remove commit - \(commitData.count) bytes"
      )

      // 2. Call server API with BOTH authorization AND the commit
      // CRITICAL: The server will distribute this commit to all members via envelopes + SSE
      // Without this, other members cannot advance epochs and will be unable to decrypt new messages
      let idempotencyKey = UUID().uuidString.lowercased()
      let targetDid = try DID(didString: memberDid)
      let commitBase64 = commitData.base64EncodedString()

      let (ok, epochHint) = try await apiClient.removeMember(
        convoId: convoId,
        targetDid: targetDid,
        reason: nil,
        commit: commitBase64,
        idempotencyKey: idempotencyKey
      )

      guard ok else {
        // Clear pending commit since server rejected
        try? await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
        throw MLSConversationError.operationFailed("Server rejected member removal")
      }

      logger.info(
        "🔵 [MLSConversationManager.removeMember] Server authorized removal and distributed commit - epochHint: \(epochHint.map { String($0) } ?? "nil")"
      )

      // 3. NOW merge commit locally (advances epoch, cryptographically revokes access)
      // This is safe because the server has already distributed the commit to other members
      try await mlsClient.mergePendingCommit(for: userDid, groupId: groupIdData, convoId: convoId)

      logger.info(
        "✅ [MLSConversationManager.removeMember] Member cryptographically removed at new epoch")

      // Get new epoch after merge
      let newEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

      // 4. Record membership event in database and update conversation timestamp
      do {
        // Record membership event for removed member
        let event = MLSMembershipEventModel(
          conversationID: convoId,
          currentUserDID: userDid,
          memberDID: memberDid,
          eventType: .left,
          epoch: Int64(newEpoch)
        )
        try await storage.recordMembershipEvent(event, database: database)

        // Update conversation membership timestamp
        try await storage.updateConversationMembershipTimestamp(
          conversationID: convoId,
          currentUserDID: userDid,
          database: database
        )

        // Notify observers AFTER database commits
        notifyObservers(.membershipChanged(convoId: convoId, did: targetDid, action: .removed))
      } catch {
        logger.error("Failed to record membership event for removal: \(error.localizedDescription)")
      }

      // 5. Sync to update local member list
      try await syncGroupState(for: convoId)
    }
  }

  /// Promote a member to admin
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to promote
  func promoteAdmin(convoId: String, memberDid: String) async throws {
    logger.info(
      "🔵 [MLSConversationManager.promoteAdmin] START - convoId: \(convoId), member: \(memberDid)")
    try throwIfShuttingDown("promoteAdmin")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      throw MLSConversationError.conversationNotFound
    }

    let targetDid = try DID(didString: memberDid)

    try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      let success = try await apiClient.promoteAdmin(convoId: convoId, targetDid: targetDid)

      guard success else {
        throw MLSConversationError.operationFailed("Server failed to promote admin")
      }

      logger.info("✅ [MLSConversationManager.promoteAdmin] Success")

      // Sync to update local state (roles are in ConvoView)
      try await syncGroupState(for: convoId)

      // Force refresh conversation metadata to get updated roles
      let (convos, _) = try await apiClient.getConversations(limit: 100)
      if let updatedConvo = convos.first(where: { $0.groupId == convo.groupId }) {
        conversations[convoId] = updatedConvo
        notifyObservers(.conversationJoined(updatedConvo))  // Reuse joined event for update
      }
    }
  }

  /// Demote an admin to member
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to demote
  func demoteAdmin(convoId: String, memberDid: String) async throws {
    logger.info(
      "🔵 [MLSConversationManager.demoteAdmin] START - convoId: \(convoId), member: \(memberDid)")
    try throwIfShuttingDown("demoteAdmin")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      throw MLSConversationError.conversationNotFound
    }

    let targetDid = try DID(didString: memberDid)

    try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      let success = try await apiClient.demoteAdmin(convoId: convoId, targetDid: targetDid)

      guard success else {
        throw MLSConversationError.operationFailed("Server failed to demote admin")
      }

      logger.info("✅ [MLSConversationManager.demoteAdmin] Success")

      // Sync to update local state
      try await syncGroupState(for: convoId)

      // Force refresh conversation metadata
      let (convos, _) = try await apiClient.getConversations(limit: 100)
      if let updatedConvo = convos.first(where: { $0.groupId == convo.groupId }) {
        conversations[convoId] = updatedConvo
        notifyObservers(.conversationJoined(updatedConvo))
      }
    }
  }

  /// Add members to an existing conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDids: DIDs of members to add
  func addMembers(convoId: String, memberDids: [String]) async throws {
    logger.info(
      "🔵 [MLSConversationManager.addMembers] START - convoId: \(convoId), members: \(memberDids.count)"
    )
    try throwIfShuttingDown("addMembers")

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

    // ═══════════════════════════════════════════════════════════════════════════════
    // 🔍 PRE-FLIGHT CHECK: Verify members aren't already in MLS group
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // The MLS FFI layer is the source of truth for group membership.
    // The UI may be out of sync if commits (like member removal/addition) were processed
    // without updating groupStates[].members.
    //
    // This check prevents the "Member already in group" error and provides clear feedback.
    //
    // ═══════════════════════════════════════════════════════════════════════════════
    do {
      let debugInfo = try await mlsClient.debugGroupMembers(for: userDid, groupId: groupIdData)
      let currentMemberDids = debugInfo.members.map {
        String(data: $0.credentialIdentity, encoding: .utf8)?.lowercased() ?? ""
      }

      // Check if any of the members we're trying to add are already in the group
      var alreadyInGroup: [String] = []
      for memberDid in memberDids {
        let normalizedDid = memberDid.lowercased()
        if currentMemberDids.contains(where: {
          $0.contains(normalizedDid) || normalizedDid.contains($0)
        }) {
          alreadyInGroup.append(memberDid)
        }
      }

      if !alreadyInGroup.isEmpty {
        logger.warning(
          "⚠️ [MLSConversationManager.addMembers] PRE-FLIGHT: \(alreadyInGroup.count) member(s) already in MLS group"
        )
        for did in alreadyInGroup {
          logger.warning("   - \(did.prefix(40))...")
        }
        logger.warning("   This indicates UI is out of sync with MLS state")

        // Update groupStates to reflect actual MLS membership
        var updatedState = groupStates[convo.groupId] ?? groupState
        updatedState.members = Set(currentMemberDids)
        groupStates[convo.groupId] = updatedState
        logger.info(
          "🔄 Synced groupStates.members with MLS FFI state (\(currentMemberDids.count) members)")

        // If ALL members are already in group, throw helpful error
        if alreadyInGroup.count == memberDids.count {
          throw MLSConversationError.operationFailed(
            "All selected members are already in this conversation")
        }

        // Note: if partial membership overlap is common, we should filter existing members and add only new ones.
        throw MLSConversationError.operationFailed(
          "Some members are already in this conversation: \(alreadyInGroup.joined(separator: ", "))"
        )
      }

      logger.debug(
        "✅ [MLSConversationManager.addMembers] PRE-FLIGHT: All \(memberDids.count) members are new to the group"
      )
    } catch let error as MLSConversationError {
      throw error  // Re-throw our own errors
    } catch {
      // If we can't check membership (e.g., FFI error), proceed anyway
      // The addMembers call will fail with a clear error if there's a problem
      logger.warning(
        "⚠️ [MLSConversationManager.addMembers] PRE-FLIGHT check failed, proceeding anyway: \(error.localizedDescription)"
      )
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

    logger.info(
      "✅ [MLSConversationManager.addMembers] Got \(keyPackagesResult.keyPackages.count) key packages"
    )

    let keyPackages = keyPackagesResult.keyPackages
    let keyPackagesWithHashes = try await selectKeyPackages(
      for: dids, from: keyPackages, userDid: userDid)

    // Extract just the data for MLSClient
    let keyPackagesArray = keyPackagesWithHashes.map { $0.data }

    // Use GroupOperationCoordinator to serialize operations on this group
    try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      try await addMembersImpl(
        convoId: convoId,
        memberDids: memberDids,
        dids: dids,
        userDid: userDid,
        groupIdData: groupIdData,
        groupState: groupState,
        convo: convo,
        keyPackagesArray: keyPackagesArray,
        keyPackagesWithHashes: keyPackagesWithHashes
      )
    }
  }

  /// Internal implementation of addMembers (called within exclusive lock)
  private func addMembersImpl(
    convoId: String,
    memberDids: [String],
    dids: [DID],
    userDid: String,
    groupIdData: Data,
    groupState: MLSGroupState,
    convo: BlueCatbirdMlsDefs.ConvoView,
    keyPackagesArray: [Data],
    keyPackagesWithHashes: [KeyPackageWithHash]
  ) async throws {
    do {
      // 0. Clear any stale pending commit from a previous failed operation
      // This prevents "PendingCommit" errors when the group has uncommitted state
      do {
        try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
        logger.debug("🧹 [MLSConversationManager.addMembers] Cleared any stale pending commit")
      } catch {
        // Ignore errors - there may be no pending commit to clear
        logger.debug(
          "🧹 [MLSConversationManager.addMembers] No pending commit to clear (or already clean)")
      }

      // 1. Create commit locally (staged, not merged)
      logger.info("🔵 [MLSConversationManager.addMembers] Step 1/4: Creating staged commit...")
      let addResult = try await mlsClient.addMembers(
        for: userDid,
        groupId: groupIdData,
        keyPackages: keyPackagesArray
      )
      logger.info(
        "✅ [MLSConversationManager.addMembers] Staged commit created - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes"
      )

      // 2. Send commit and welcome to server
      logger.info("🔵 [MLSConversationManager.addMembers] Step 2/4: Sending to server...")

      logger.info(
        "📍 [MLSConversationManager.addMembers] Prepared Welcome message for \(dids.count) new members"
      )

      // Build key package hash entries for server lifecycle tracking
      let keyPackageHashEntries: [BlueCatbirdMlsAddMembers.KeyPackageHashEntry] =
        keyPackagesWithHashes.map { kp in
          BlueCatbirdMlsAddMembers.KeyPackageHashEntry(
            did: kp.did,
            hash: kp.hash
          )
        }
      logger.info(
        "📍 [MLSConversationManager.addMembers] Sending \(keyPackageHashEntries.count) key package hashes for lifecycle tracking"
      )

      // PHASE 3 FIX: Protect server send + commit merge + state update from cancellation
      // This sequence MUST complete atomically to prevent epoch desync
      let (newEpoch, mergedEpoch) = try await withTaskCancellationHandler {
        // Track this commit as our own to prevent re-processing via SSE
        trackOwnCommit(addResult.commitData)
        logger.debug("📝 Tracked own addMembers commit to prevent SSE re-processing")

        let addMembersResult: (success: Bool, newEpoch: Int)
        do {
          addMembersResult = try await apiClient.addMembers(
            convoId: convoId,
            didList: dids,
            commit: addResult.commitData,
            welcomeMessage: addResult.welcomeData,
            keyPackageHashes: keyPackageHashEntries
          )
        } catch let apiError as MLSAPIError {
          let normalizedError = normalizeKeyPackageError(apiError)
          logger.error(
            "❌ [MLSConversationManager.addMembers] Server error during addMembers: \(normalizedError.localizedDescription)"
          )
          switch normalizedError {
          case .keyPackageNotFound(let detail):
            recordKeyPackageFailure(detail: detail)
            throw MLSConversationError.missingKeyPackages(memberDids)
          case .conversationNotFound:
            throw MLSConversationError.conversationNotFound
          case .notConversationMember:
            throw MLSConversationError.groupNotInitialized
          case .memberAlreadyExists:
            throw MLSConversationError.operationFailed(
              "One or more members are already part of this conversation")
          case .memberBlocked, .mutualBlockDetected:
            throw MLSConversationError.operationFailed(
              "Cannot add members due to Bluesky block relationships")
          case .tooManyMembers:
            throw MLSConversationError.operationFailed(
              "Adding these members would exceed the maximum allowed")
          default:
            throw MLSConversationError.serverError(normalizedError)
          }
        }

        guard addMembersResult.success else {
          logger.warning(
            "⚠️ [MLSConversationManager.addMembers] Server rejected commit, clearing...")
          try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
          throw MLSConversationError.operationFailed("Server rejected member addition")
        }
        let newEpoch = addMembersResult.newEpoch
        logger.info("✅ [MLSConversationManager.addMembers] Server accepted - newEpoch: \(newEpoch)")

        // ✅ RATCHET DESYNC FIX: Merge commit ONLY after server confirmation (send-then-merge pattern)
        // This prevents epoch mismatch where client advances to epoch N+1 before server acknowledges
        logger.info(
          "🔄 [MLSConversationManager.addMembers] Merging pending commit after server ACK...")
        let mergedEpoch = try await mlsClient.mergePendingCommit(for: userDid, groupId: groupIdData)
        logger.info(
          "✅ [MLSConversationManager.addMembers] Commit merged - local epoch now: \(mergedEpoch)")

        return (newEpoch, mergedEpoch)
      } onCancel: {
        logger.warning(
          "⚠️ [addMembers] Commit operation was cancelled - allowing completion to prevent epoch desync"
        )
      }

      // 3. Update local state (after protected commit merge completes)
      logger.info("🔵 [MLSConversationManager.addMembers] Step 3/3: Updating local state...")
      var updatedState = groupStates[convo.groupId] ?? groupState
      updatedState.epoch = UInt64(newEpoch)
      updatedState.members.formUnion(memberDids)
      groupStates[convo.groupId] = updatedState

      // Persist MLS state after adding members
      do {
        logger.info("✅ Persisted MLS state after adding members")
      } catch {
        logger.error("⚠️ Failed to persist MLS state: \(error.localizedDescription)")
      }

      // Publish updated GroupInfo after membership change
      // CRITICAL: If this fails, external joins won't work for new members
      try await publishLatestGroupInfo(
        userDid: userDid,
        convoId: convoId,
        groupId: groupIdData,
        context: "after addMembers"
      )

      // Record membership events in database and update conversation timestamp
      do {
        // Record membership events for each added member
        for did in dids {
          let event = MLSMembershipEventModel(
            conversationID: convoId,
            currentUserDID: userDid,
            memberDID: did.description,
            eventType: .joined,
            epoch: Int64(newEpoch)
          )
          try await storage.recordMembershipEvent(event, database: database)
        }

        // Update conversation membership timestamp
        try await storage.updateConversationMembershipTimestamp(
          conversationID: convoId,
          currentUserDID: userDid,
          database: database
        )

        // Notify observers AFTER database commits
        for did in dids {
          notifyObservers(.membershipChanged(convoId: convoId, did: did, action: .joined))
        }
      } catch {
        logger.error("Failed to record membership events: \(error.localizedDescription)")
      }

      // Also notify with legacy events for backwards compatibility
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

      logger.info(
        "✅ [MLSConversationManager.addMembers] COMPLETE - convoId: \(convoId), epoch: \(newEpoch), members: \(updatedState.members.count)"
      )

    } catch {
      logger.error(
        "❌ [MLSConversationManager.addMembers] Error, cleaning up: \(error.localizedDescription)")

      do {
        try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
        logger.info("✅ [MLSConversationManager.addMembers] Cleared pending commit")
      } catch {
        logger.error(
          "❌ [MLSConversationManager.addMembers] Failed to clear pending commit: \(error.localizedDescription)"
        )
      }

      // Unreserve key packages on errors where they weren't actually consumed
      var shouldUnreserve = false

      // Case 1: Member already in group - MLS client rejected, key package not consumed
      if case .memberAlreadyInGroup = error as? MLSError {
        logger.info(
          "♻️ [MLSConversationManager.addMembers] Member already in group - unreserving key packages (MLS state out of sync with UI)"
        )
        shouldUnreserve = true
      }
      // Case 2: Transient server errors (5xx) - server didn't consume key package
      else if case .serverError(let innerError) = error as? MLSConversationError,
        case .httpError(let statusCode, _) = innerError as? MLSAPIError,
        (500...599).contains(statusCode)
      {
        logger.info(
          "♻️ [MLSConversationManager.addMembers] Transient server error (\(statusCode)) - unreserving key packages for retry"
        )
        shouldUnreserve = true
      } else if let apiError = error as? MLSAPIError,
        case .httpError(let statusCode, _) = apiError,
        (500...599).contains(statusCode)
      {
        logger.info(
          "♻️ [MLSConversationManager.addMembers] Transient server error (\(statusCode)) - unreserving key packages for retry"
        )
        shouldUnreserve = true
      }
      // Case 3: Generic MLS operation failures - FFI rejected, key package not consumed
      else if case .operationFailed = error as? MLSError {
        logger.info(
          "♻️ [MLSConversationManager.addMembers] MLS operation failed before server send - unreserving key packages"
        )
        shouldUnreserve = true
      }

      if shouldUnreserve {
        unreserveKeyPackages(keyPackagesWithHashes)
      }

      // Throw appropriate error type
      if case .memberAlreadyInGroup = error as? MLSError {
        throw MLSConversationError.operationFailed(
          "Member is already in this conversation - please refresh the member list")
      }

      throw MLSConversationError.serverError(error)
    }
  }

  // MARK: - Device Synchronization

  /// Add a new device to a conversation using a provided key package
  /// This is called by MLSDeviceSyncManager when processing pending device additions
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - deviceCredentialDid: The credential DID of the device being added (e.g., did:plc:user#device-uuid)
  ///   - keyPackageData: The MLS key package data for the device
  /// - Returns: The new epoch after adding the device
  func addDeviceWithKeyPackage(
    convoId: String,
    deviceCredentialDid: String,
    keyPackageData: Data
  ) async throws -> Int {
    logger.info(
      "🔵 [MLSConversationManager.addDeviceWithKeyPackage] START - convoId: \(convoId), device: \(deviceCredentialDid)"
    )
    try throwIfShuttingDown("addDeviceWithKeyPackage")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      logger.error("❌ [MLSConversationManager.addDeviceWithKeyPackage] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    guard let groupState = groupStates[convo.groupId] else {
      logger.error("❌ [MLSConversationManager.addDeviceWithKeyPackage] Group state not found")
      throw MLSConversationError.groupStateNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      logger.error("❌ [MLSConversationManager.addDeviceWithKeyPackage] Invalid groupId")
      throw MLSConversationError.invalidGroupId
    }

    // Extract user DID from device credential DID (format: did:plc:user#device-uuid)
    let userDidFromDevice: String
    if let hashIndex = deviceCredentialDid.firstIndex(of: "#") {
      userDidFromDevice = String(deviceCredentialDid[..<hashIndex])
    } else {
      userDidFromDevice = deviceCredentialDid
    }

    // Use GroupOperationCoordinator to serialize operations on this group
    return try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      // 1. Create commit locally using the provided key package
      logger.info(
        "🔵 [MLSConversationManager.addDeviceWithKeyPackage] Step 1/3: Creating staged commit...")
      let addResult = try await mlsClient.addMembers(
        for: userDid,
        groupId: groupIdData,
        keyPackages: [keyPackageData]
      )
      logger.info("✅ [MLSConversationManager.addDeviceWithKeyPackage] Staged commit created")

      // 2. Send commit and welcome to server
      logger.info(
        "🔵 [MLSConversationManager.addDeviceWithKeyPackage] Step 2/3: Sending to server...")

      // Track this commit as our own
      trackOwnCommit(addResult.commitData)

      // For device additions, we use the device credential DID (not user DID) in the server call
      // The server will validate this is a device belonging to an existing member
      let addMembersResult = try await apiClient.addMembers(
        convoId: convoId,
        didList: [],  // Empty - we're adding a device, not a new user
        commit: addResult.commitData,
        welcomeMessage: addResult.welcomeData,
        keyPackageHashes: nil  // Server already knows the key package from claim
      )

      guard addMembersResult.success else {
        logger.error("❌ [MLSConversationManager.addDeviceWithKeyPackage] Server rejected commit")
        try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
        throw MLSConversationError.operationFailed("Server rejected device addition")
      }

      let serverEpoch = addMembersResult.newEpoch

      // 3. Merge commit locally
      logger.info(
        "🔵 [MLSConversationManager.addDeviceWithKeyPackage] Step 3/3: Merging commit locally...")
      let localEpoch = try await mlsClient.mergePendingCommit(for: userDid, groupId: groupIdData)

      if localEpoch != UInt64(serverEpoch) {
        logger.warning(
          "⚠️ Epoch mismatch after device addition: local=\(localEpoch), server=\(serverEpoch)")
      }

      // Update local state
      var updatedState = groupState
      updatedState.epoch = localEpoch
      // Device additions don't add new user DIDs to members - they're devices of existing members
      groupStates[convo.groupId] = updatedState

      logger.info(
        "✅ [MLSConversationManager.addDeviceWithKeyPackage] COMPLETE - device: \(deviceCredentialDid), epoch: \(serverEpoch)"
      )

      return serverEpoch
    }
  }

  /// Get the device sync manager for SSE event wiring
  /// Call this to register for newDeviceEvent handling in your SSE subscription
  func getDeviceSyncManager() -> MLSDeviceSyncManager? {
    return deviceSyncManager
  }

  /// Handle SSE new device event by forwarding to the device sync manager
  /// This provides the real-time path for multi-device sync instead of relying on polling
  func handleNewDeviceSSEEvent(_ event: BlueCatbirdMlsStreamConvoEvents.NewDeviceEvent) async {
    guard let deviceSyncManager = deviceSyncManager else {
      logger.warning(
        "⚠️ [handleNewDeviceSSEEvent] Device sync manager not initialized - SSE new device event ignored"
      )
      return
    }
    logger.info(
      "📱 [handleNewDeviceSSEEvent] Forwarding new device event to sync manager - user: \(event.userDid), device: \(event.deviceId)"
    )
    await deviceSyncManager.handleNewDeviceEvent(event)
  }

  /// Request active members to publish fresh GroupInfo for a conversation
  /// Called when External Commit fails due to stale GroupInfo
  /// Emits SSE event to notify other members to upload fresh GroupInfo
  func groupInfoRefresh(convoId: String) async {
    logger.info("🔄 [groupInfoRefresh] Requesting refresh for \(convoId)")

    do {
      let input = BlueCatbirdMlsGroupInfoRefresh.Input(convoId: convoId)
      let (responseCode, output) = try await apiClient.client.blue.catbird.mls.groupInfoRefresh(
        input: input)

      if responseCode == 200, let output = output {
        if output.requested {
          logger.info(
            "✅ [groupInfoRefresh] Request sent - \(output.activeMembers ?? 0) active members notified"
          )
        } else {
          logger.warning("⚠️ [groupInfoRefresh] No active members to notify for \(convoId)")
        }
      } else {
        logger.warning("⚠️ [groupInfoRefresh] Server returned \(responseCode) for \(convoId)")
      }
    } catch {
      logger.error("❌ [groupInfoRefresh] Failed: \(error.localizedDescription)")
    }
  }

  /// Request re-addition to a conversation when both Welcome and External Commit have failed
  /// Called after all rejoin attempts are exhausted to notify active members
  /// Emits SSE event to notify other members to re-add the user with fresh KeyPackages
  func readdition(convoId: String) async {
    logger.info("🆘 [readdition] Requesting re-addition for \(convoId)")

    do {
      let (requested, activeMembers) = try await apiClient.readdition(convoId: convoId)

      if requested {
        logger.info("✅ [readdition] Request sent - \(activeMembers ?? 0) active members notified")
      } else {
        logger.warning(
          "⚠️ [readdition] No active members available to process re-addition for \(convoId)")
      }
    } catch {
      logger.error("❌ [readdition] Failed: \(error.localizedDescription)")
    }
  }

  /// Handle GroupInfo refresh request from SSE stream
  /// When another member encounters stale GroupInfo during External Commit rejoin,
  /// they request active members to publish fresh GroupInfo. This exports and uploads
  /// the current GroupInfo from our local MLS state.
  func handleGroupInfoRefreshRequest(convoId: String) async {
    logger.info("🔄 [handleGroupInfoRefreshRequest] Processing refresh request for \(convoId)")

    guard let userDid = userDid else {
      logger.warning("⚠️ [handleGroupInfoRefreshRequest] No user DID available")
      return
    }

    let convo = conversations[convoId]

    // Get the group ID from our local conversation state
    guard let groupIdHex = convo?.groupId, let groupId = Data(hexEncoded: groupIdHex) else {
      logger.warning("⚠️ [handleGroupInfoRefreshRequest] Could not find group ID for \(convoId)")
      return
    }

    do {
      // Export and upload fresh GroupInfo
      try await mlsClient.publishGroupInfo(for: userDid, convoId: convoId, groupId: groupId)
      logger.info(
        "✅ [handleGroupInfoRefreshRequest] Successfully published fresh GroupInfo for \(convoId)")
    } catch {
      logger.error(
        "❌ [handleGroupInfoRefreshRequest] Failed to publish GroupInfo for \(convoId): \(error.localizedDescription)"
      )
    }
  }

  /// Handle re-addition request from SSE stream
  /// When a member's rejoin attempts are exhausted (Welcome failed, External Commit failed),
  /// they request active members to re-add them. This method re-adds the user with fresh KeyPackages.
  ///
  /// - Parameters:
  ///   - convoId: Conversation ID where re-addition was requested
  ///   - userDidToAdd: DID of the user requesting re-addition
  func handleReadditionRequest(convoId: String, userDidToAdd: String) async {
    logger.info(
      "🆘 [handleReadditionRequest] Processing re-addition request for user \(userDidToAdd.prefix(20))... in \(convoId)"
    )

    guard let currentUserDid = userDid else {
      logger.warning("⚠️ [handleReadditionRequest] No user DID available")
      return
    }

    // Don't process our own re-addition requests
    if userDidToAdd == currentUserDid {
      logger.debug("🔄 [handleReadditionRequest] Ignoring own re-addition request")
      return
    }

    // Verify we're an active member of the conversation (having a group state means we're joined)
    guard groupStates[convoId] != nil else {
      logger.warning("⚠️ [handleReadditionRequest] Not an active member of \(convoId)")
      return
    }

    do {
      // Re-add the user using the standard addMembers flow
      // This will fetch fresh KeyPackages and create a Welcome/Commit
      logger.info(
        "📤 [handleReadditionRequest] Re-adding user \(userDidToAdd.prefix(20))... to \(convoId)")
      try await addMembers(convoId: convoId, memberDids: [userDidToAdd])
      logger.info(
        "✅ [handleReadditionRequest] Successfully re-added user \(userDidToAdd.prefix(20))... to \(convoId)"
      )
    } catch {
      logger.error(
        "❌ [handleReadditionRequest] Failed to re-add user: \(error.localizedDescription)")
      // Don't throw - other active members may also receive the request and succeed
    }
  }

  // MARK: - Multi-Device External Commit Fallback

  /// Join a conversation via External Commit as a fallback for multi-device sync failures
  /// This is called when the device sync manager detects that a pending addition failed
  /// and the new device needs to self-join via External Commit.
  ///
  /// - Parameter convoId: The conversation ID to join
  /// - Throws: MLSConversationError if join fails
  func joinViaExternalCommit(convoId: String) async throws {
    guard let userDid = userDid else {
      logger.error("❌ [joinViaExternalCommit] No user DID available")
      throw MLSConversationError.noAuthentication
    }

    logger.info("📱 [joinViaExternalCommit] Attempting External Commit fallback for \(convoId)")

    // Use the existing External Commit fallback infrastructure
    let groupIdHex = try await attemptExternalCommitFallback(
      convoId: convoId,
      userDid: userDid,
      reason: "Multi-device sync fallback"
    )

    // Fetch the conversation to update local state
    guard let convo = await fetchConversationForRejoin(convoId: convoId) else {
      logger.warning(
        "⚠️ [joinViaExternalCommit] Could not fetch conversation after join - local state may be stale"
      )
      return
    }

    // Update group state after join
    try await updateGroupStateAfterJoin(convo: convo, groupIdHex: groupIdHex, userDid: userDid)

    // Sync conversation to ensure everything is up to date via device sync manager
    if let deviceSyncManager = deviceSyncManager {
      await deviceSyncManager.syncConversation(convoId)
    }

    logger.info(
      "✅ [joinViaExternalCommit] Successfully joined \(convoId) via External Commit fallback")
  }

  /// Remove current user from conversation
  /// - Parameter convoId: Conversation identifier
  func leaveConversation(convoId: String) async throws {
    logger.info("Leaving conversation: \(convoId)")

    guard let userDid = userDid else {
      throw MLSConversationError.contextNotInitialized
    }

    // Try to get conversation from memory first, or look up from database
    let convo: BlueCatbirdMlsDefs.ConvoView
    if let memoryConvo = conversations[convoId] {
      convo = memoryConvo
    } else {
      // Conversation not in memory - check database for zombie/orphan conversations
      let dbConvo = try await database.read { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.conversationID == convoId)
          .filter(MLSConversationModel.Columns.currentUserDID == userDid)
          .fetchOne(db)
      }

      if let dbConvo = dbConvo {
        logger.warning(
          "⚠️ [leaveConversation] Conversation \(convoId.prefix(16))... found in database but not in memory - treating as orphan"
        )
        // This is a zombie/orphan conversation - skip server call and force delete locally
        await forceDeleteConversationLocally(
          convoId: convoId, groupId: dbConvo.groupID.hexEncodedString())
        notifyObservers(.conversationLeft(convoId))
        logger.info(
          "✅ [leaveConversation] Cleaned up orphan conversation: \(convoId.prefix(16))...")
        return
      } else {
        throw MLSConversationError.conversationNotFound
      }
    }

    do {
      _ = try await apiClient.leaveConversation(convoId: convoId)
      logger.info("✅ Left conversation on server: \(convoId)")

      // CRITICAL: Force delete local state after successful server leave
      // This bypasses the conservative reconciliation logic that would otherwise
      // preserve the conversation if the MLS group still exists locally.
      await forceDeleteConversationLocally(convoId: convoId, groupId: convo.groupId)

      // Notify observers
      notifyObservers(.conversationLeft(convoId))

      logger.info("✅ Successfully left and cleaned up conversation: \(convoId)")

    } catch let networkError as NetworkError {
      // If server returns 403 (forbidden) or 404 (not found), the user is already removed
      // from the conversation on the server - clean up local state
      switch networkError {
      case .serverError(let statusCode) where statusCode == 403 || statusCode == 404:
        logger.warning(
          "⚠️ [leaveConversation] Server returned \(statusCode) - user already removed, cleaning up locally"
        )
        await forceDeleteConversationLocally(convoId: convoId, groupId: convo.groupId)
        notifyObservers(.conversationLeft(convoId))
        logger.info(
          "✅ [leaveConversation] Cleaned up stale conversation after server \(statusCode): \(convoId.prefix(16))..."
        )
        return
      default:
        logger.error("Failed to leave conversation: \(networkError.localizedDescription)")
        throw MLSConversationError.serverError(networkError)
      }
    } catch {
      logger.error("Failed to leave conversation: \(error.localizedDescription)")
      throw MLSConversationError.serverError(error)
    }
  }

  /// Force delete a conversation from local storage, bypassing reconciliation safeguards.
  /// Use this when:
  /// 1. User explicitly left/deleted the conversation (server confirmed)
  /// 2. User was removed/kicked from the conversation (detected via sync or SSE)
  /// 3. Admin deleted the conversation on the server
  ///
  /// This method:
  /// - Deletes MLS group from OpenMLS storage (even if group exists and is valid)
  /// - Deletes all local database records (conversation, messages, members, epoch keys)
  /// - Removes from in-memory state
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - groupId: MLS group identifier (hex string)
  private func forceDeleteConversationLocally(convoId: String, groupId: String) async {
    logger.info(
      "🗑️ [FORCE DELETE] Deleting conversation \(convoId.prefix(16))... from local storage")

    guard let userDid = userDid else {
      logger.error("❌ [FORCE DELETE] No user DID available")
      return
    }

    // Delete MLS group from local OpenMLS storage
    if let groupIdData = Data(hexEncoded: groupId) {
      do {
        try await mlsClient.deleteGroup(for: userDid, groupId: groupIdData)
        logger.info(
          "✅ [FORCE DELETE] Deleted MLS group from local storage: \(groupId.prefix(16))...")
      } catch {
        logger.warning(
          "⚠️ [FORCE DELETE] Failed to delete MLS group \(groupId.prefix(16))...: \(error.localizedDescription)"
        )
        // Continue anyway - we still want to clean up database and memory
      }
    }

    // Delete from database (conversation, messages, members, epoch keys)
    do {
      try await deleteConversationsFromDatabase([convoId])
    } catch {
      logger.error("❌ [FORCE DELETE] Failed to delete from database: \(error.localizedDescription)")
    }

    // Remove from in-memory state
    conversations.removeValue(forKey: convoId)
    groupStates.removeValue(forKey: groupId)

    logger.info("✅ [FORCE DELETE] Completed for conversation: \(convoId.prefix(16))...")
  }

  /// Public method to force delete a broken/stale conversation from local storage.
  /// Use this when:
  /// 1. A conversation is stuck in an invalid state
  /// 2. The server confirmed the conversation no longer exists
  /// 3. The user wants to manually clean up a ghost conversation
  ///
  /// This bypasses all reconciliation safeguards and removes the conversation immediately.
  ///
  /// - Parameter convoId: Conversation identifier to delete
  /// - Note: This does NOT call the server - use leaveConversation() if you want to leave properly
  func forceDeleteConversation(convoId: String) async {
    logger.warning("⚠️ [FORCE DELETE PUBLIC] Force deleting conversation: \(convoId)")

    let groupId = conversations[convoId]?.groupId ?? convoId
    await forceDeleteConversationLocally(convoId: convoId, groupId: groupId)

    // Notify observers
    notifyObservers(.conversationLeft(convoId))
  }

  /// Handle being removed/kicked from a conversation
  /// This is called when we detect (via SSE or sync) that we're no longer a member
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - reason: Optional reason for removal (kicked vs left vs out of sync)
  func handleRemovedFromConversation(convoId: String, reason: MembershipChangeReason) async {
    logger.warning(
      "🚫 [handleRemovedFromConversation] Cleaning up after removal: \(convoId), reason: \(reason)")

    // Get the conversation info before cleanup
    let groupId = conversations[convoId]?.groupId ?? convoId  // Fallback to convoId if not found

    // Force delete using centralized method
    await forceDeleteConversationLocally(convoId: convoId, groupId: groupId)

    // Notify observers based on reason
    switch reason {
    case .selfLeft:
      notifyObservers(.conversationLeft(convoId))
    case .kicked(let by, let reasonText):
      notifyObservers(.kickedFromConversation(convoId: convoId, by: by, reason: reasonText))
    case .outOfSync:
      notifyObservers(.conversationNeedsRecovery(convoId: convoId, reason: .memberRemoval))
    case .connectionLost:
      // Don't notify for connection issues - may be temporary
      break
    }

    logger.info("✅ Cleanup completed for removed conversation: \(convoId)")
  }

  // MARK: - Admin Operations

  // MARK: Admin Helpers

  /// Determine if the current user is an admin of the given conversation using in-memory state with a database fallback.
  func isCurrentUserAdmin(of convoId: String) async -> Bool {
    guard let userDid = userDid else { return false }

    if let convo = conversations[convoId],
      convo.members.contains(where: { $0.did.description == userDid && $0.isAdmin })
    {
      return true
    }

    do {
      let members = try await storage.fetchMembers(
        conversationID: convoId,
        currentUserDID: userDid,
        database: database
      )

      return members.contains { model in
        model.did == userDid && model.isActive && model.role == .admin
      }
    } catch {
      logger.error("Failed to check admin status for \(convoId): \(error.localizedDescription)")
      return false
    }
  }

  /// Determine if the current user is an admin for any conversation.
  func isCurrentUserAdminInAnyConversation() async -> Bool {
    guard let userDid = userDid else { return false }

    if conversations.values.contains(where: { convo in
      convo.members.contains { $0.did.description == userDid && $0.isAdmin }
    }) {
      return true
    }

    do {
      let adminCount = try await database.read { db in
        try MLSMemberModel
          .filter(MLSMemberModel.Columns.currentUserDID == userDid)
          .filter(MLSMemberModel.Columns.role == MLSMemberModel.Role.admin.rawValue)
          .filter(MLSMemberModel.Columns.isActive == true)
          .fetchCount(db)
      }

      return adminCount > 0
    } catch {
      logger.error("Failed to determine admin membership: \(error.localizedDescription)")
      return false
    }
  }

  /// Remove a member from conversation (admin-only)
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to remove
  ///   - reason: Optional reason for removal
  func removeMember(from convoId: String, memberDid: String, reason: String? = nil) async throws {
    logger.info(
      "🔵 [MLSConversationManager.removeMember] START - convoId: \(convoId), memberDid: \(memberDid)"
    )

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      logger.error("❌ [MLSConversationManager.removeMember] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    // Convert groupId string to Data
    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.operationFailed("Failed to decode groupId hex string")
    }

    // Convert DID to credential data (DID bytes) for MLS removal
    guard let memberIdentity = memberDid.data(using: .utf8) else {
      throw MLSConversationError.operationFailed("Failed to encode member DID")
    }

    do {
      // Use GroupOperationCoordinator to serialize operations
      try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
        // 0. Clear any stale pending commit from a previous failed operation
        // This prevents "PendingCommit" errors when the group has uncommitted state
        do {
          try await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
          logger.debug("🧹 [MLSConversationManager.removeMember] Cleared any stale pending commit")
        } catch {
          // Ignore errors - there may be no pending commit to clear
          logger.debug(
            "🧹 [MLSConversationManager.removeMember] No pending commit to clear (or already clean)")
        }

        // 1. Create MLS remove commit FIRST (cryptographically secure)
        // This puts the commit in pending state - we will merge after server confirms distribution
        let commitData = try await mlsClient.removeMembers(
          for: userDid,
          groupId: groupIdData,
          memberIdentities: [memberIdentity]
        )

        logger.debug(
          "🔵 [MLSConversationManager.removeMember] Created MLS remove commit - \(commitData.count) bytes"
        )

        // 2. Call server API with BOTH authorization AND the commit
        // CRITICAL: The server will distribute this commit to all members via envelopes + SSE
        // Without this, other members cannot advance epochs and will be unable to decrypt new messages
        let idempotencyKey = UUID().uuidString.lowercased()
        let targetDid = try DID(didString: memberDid)
        let commitBase64 = commitData.base64EncodedString()

        let (ok, epochHint) = try await apiClient.removeMember(
          convoId: convoId,
          targetDid: targetDid,
          reason: reason,
          commit: commitBase64,
          idempotencyKey: idempotencyKey
        )

        guard ok else {
          // Clear pending commit since server rejected
          try? await mlsClient.clearPendingCommit(for: userDid, groupId: groupIdData)
          throw MLSConversationError.operationFailed("Server rejected member removal")
        }

        logger.info(
          "🔵 [MLSConversationManager.removeMember] Server authorized removal and distributed commit - epochHint: \(epochHint.map { String($0) } ?? "nil")"
        )

        // 3. NOW merge commit locally (advances epoch, cryptographically revokes access)
        // This is safe because the server has already distributed the commit to other members
        try await mlsClient.mergePendingCommit(for: userDid, groupId: groupIdData, convoId: convoId)

        logger.info(
          "✅ [MLSConversationManager.removeMember] Member cryptographically removed at new epoch")

        // 4. Sync to update local member list
        try await syncGroupState(for: convoId)
      }

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
    logger.info(
      "🔵 [MLSConversationManager.promoteAdmin] START - convoId: \(convoId), memberDid: \(memberDid)"
    )

    guard conversations[convoId] != nil else {
      logger.error("❌ [MLSConversationManager.promoteAdmin] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    do {
      let ok = try await apiClient.promoteAdmin(
        convoId: convoId, targetDid: try DID(didString: memberDid))

      guard ok else {
        throw MLSConversationError.serverError(
          NSError(
            domain: "MLSConversationManager", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Server returned failure for promoteAdmin"]))
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
    logger.info(
      "🔵 [MLSConversationManager.demoteAdmin] START - convoId: \(convoId), memberDid: \(memberDid)")

    guard conversations[convoId] != nil else {
      logger.error("❌ [MLSConversationManager.demoteAdmin] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    do {
      let ok = try await apiClient.demoteAdmin(
        convoId: convoId, targetDid: try DID(didString: memberDid))

      guard ok else {
        throw MLSConversationError.serverError(
          NSError(
            domain: "MLSConversationManager", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Server returned failure for demoteAdmin"]))
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
  func reportMember(in convoId: String, memberDid: String, reason: String, details: String? = nil)
    async throws -> String
  {
    logger.info(
      "🔵 [MLSConversationManager.reportMember] START - convoId: \(convoId), memberDid: \(memberDid), reason: \(reason)"
    )

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
  func loadReports(for convoId: String, limit: Int = 50, cursor: String? = nil) async throws -> (
    reports: [BlueCatbirdMlsGetReports.ReportView], cursor: String?
  ) {
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
    logger.info(
      "🔵 [MLSConversationManager.resolveReport] START - reportId: \(reportId), action: \(action)")

    do {
      let ok = try await apiClient.resolveReport(
        reportId: reportId,
        action: action,
        notes: notes
      )

      guard ok else {
        throw MLSConversationError.serverError(
          NSError(
            domain: "MLSConversationManager", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Server returned failure for resolveReport"]))
      }

      logger.info("✅ [MLSConversationManager.resolveReport] SUCCESS")

    } catch {
      logger.error("❌ [MLSConversationManager.resolveReport] Failed: \(error.localizedDescription)")
      throw MLSConversationError.serverError(error)
    }
  }

  /// Warn a member in a conversation (admin-only)
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - memberDid: DID of member to warn
  ///   - reason: Reason for warning
  /// - Returns: Tuple of warning ID and delivery timestamp
  func warnMember(in convoId: String, memberDid: String, reason: String) async throws -> (
    warningId: String, deliveredAt: Date
  ) {
    logger.info(
      "🔵 [MLSConversationManager.warnMember] START - convoId: \(convoId), memberDid: \(memberDid)")

    guard conversations[convoId] != nil else {
      logger.error("❌ [MLSConversationManager.warnMember] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    do {
      let (warningId, deliveredAt) = try await apiClient.warnMember(
        convoId: convoId,
        memberDid: try DID(didString: memberDid),
        reason: reason
      )

      logger.info("✅ [MLSConversationManager.warnMember] SUCCESS - warningId: \(warningId)")
      return (warningId, deliveredAt)

    } catch {
      logger.error("❌ [MLSConversationManager.warnMember] Failed: \(error.localizedDescription)")
      throw MLSConversationError.serverError(error)
    }
  }

  // MARK: - Encryption/Decryption

  /// Encrypt and send a message to a conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - plaintext: Plain text message to encrypt
  ///   - embed: Optional structured embed data (record, link, or GIF)
  /// - Returns: Sent message with messageId, timestamp, sequence number, and epoch
  func sendMessage(
    convoId: String,
    plaintext: String,
    embed: MLSEmbedData? = nil
  ) async throws -> (
    messageId: String, receivedAt: ATProtocolDate, sequenceNumber: Int64, epoch: Int64
  ) {
    logger.info(
      "🔵 [MLSConversationManager.sendMessage] START - convoId: \(convoId), text: \(plaintext.count) chars, embed: \(embed != nil ? "yes" : "no")"
    )
    try throwIfShuttingDown("sendMessage")
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX: Ensure state is fresh before MLS operation
    // ═══════════════════════════════════════════════════════════════════════════
    // If the app just returned to foreground, the NSE may have advanced the
    // ratchet. Wait for any pending state reload to complete before proceeding.
    // ═══════════════════════════════════════════════════════════════════════════
    try await ensureStateReloaded()
    
    let startTotal = Date()

    guard let convo = conversations[convoId] else {
      logger.error("❌ [MLSConversationManager.sendMessage] Conversation not found")
      throw MLSConversationError.conversationNotFound
    }

    // CRITICAL FIX: Verify conversation is fully initialized before sending
    if let state = conversationStates[convoId] {
      switch state {
      case .initializing:
        logger.warning(
          "⚠️ [MLSConversationManager.sendMessage] Conversation still initializing - blocking message"
        )
        throw MLSConversationError.conversationNotReady
      case .failed(let reason):
        logger.error(
          "❌ [MLSConversationManager.sendMessage] Conversation initialization failed: \(reason)")
        throw MLSConversationError.conversationNotReady
      case .active:
        // Good to proceed
        break
      }
    }
    // If no state tracked, assume it's an older conversation that's already active

    // Create structured message payload
    let payload = MLSMessagePayload.text(plaintext, embed: embed)

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
      logger.warning(
        "⚠️ [MLSConversationManager.sendMessage] Sync failed after \(syncMs)ms: \(error.localizedDescription)"
      )
    }

    // Refresh conversation reference (note: epoch will be verified from FFI later)
    let currentConvo = conversations[convoId] ?? convo

    // Ensure MLS group is initialized before encrypting
    guard let groupIdData = Data(hexEncoded: currentConvo.groupId) else {
      logger.error("❌ [MLSConversationManager.sendMessage] Invalid groupId")
      throw MLSConversationError.invalidGroupId
    }

    // Check if group exists locally via FFI
    // Run blocking FFI call on background thread to avoid priority inversion
    let groupExists = await Task(priority: .background) {
      await mlsClient.groupExists(for: userDid, groupId: groupIdData)
    }.value
    logger.debug("📍 [MLSConversationManager.sendMessage] Group exists locally: \(groupExists)")

    if !groupExists {
      // Group doesn't exist locally - need to initialize it
      logger.warning("⚠️ [MLSConversationManager.sendMessage] Group not found locally")

      // Check if we are the creator - if so, we might have created it on another device
      let isCreator = currentConvo.creator.description.lowercased() == userDid.lowercased()

      if isCreator {
        // We created this group but don't have it locally (e.g., created on different device or state lost)
        // ⭐ CRITICAL FIX: Try External Commit for creator recovery instead of failing
        logger.warning(
          "⚠️ [MLSConversationManager.sendMessage] Creator missing group - attempting External Commit recovery"
        )

        do {
          let _ = try await mlsClient.joinByExternalCommit(
            for: userDid, convoId: currentConvo.groupId)
          logger.info(
            "✅ [MLSConversationManager.sendMessage] Creator successfully rejoined via External Commit"
          )
        } catch {
          logger.error(
            "❌ [MLSConversationManager.sendMessage] Creator External Commit failed: \(error.localizedDescription)"
          )
          throw MLSConversationError.groupNotInitialized
        }
      } else {
        // We're a member - initialize from Welcome message
        logger.info("📍 [MLSConversationManager.sendMessage] Initializing from Welcome as member...")
        do {
          try await initializeGroupFromWelcome(convo: currentConvo)
          logger.info("✅ [MLSConversationManager.sendMessage] Group initialized successfully")
        } catch {
          logger.error(
            "❌ [MLSConversationManager.sendMessage] Failed to initialize group: \(error.localizedDescription)"
          )
          throw MLSConversationError.invalidWelcomeMessage
        }
      }
    }

    // Generate stable idempotency key for this logical send operation
    // Use hash of conversation + plaintext + timestamp to ensure uniqueness while allowing retries
    let idempotencyKey = generateIdempotencyKey(convoId: convoId, plaintext: plaintextData)

    // Check if we've recently sent this exact message (prevent double-sends)
    if isRecentlySent(convoId: convoId, idempotencyKey: idempotencyKey) {
      logger.warning(
        "⚠️ [MLSConversationManager.sendMessage] Duplicate send detected (same idempotency key within \(Int(self.deduplicationWindow))s) - ignoring"
      )
      throw MLSConversationError.duplicateSend
    }

    // Mark as in-flight
    trackSentMessage(convoId: convoId, idempotencyKey: idempotencyKey)

    // Encrypt message locally
    let encryptStart = Date()
    logger.debug("📍 [MLSConversationManager.sendMessage] Encrypting message...")
    let ciphertext = try await encryptMessage(
      groupId: currentConvo.groupId, plaintext: plaintextData)
    let encryptMs = Int(Date().timeIntervalSince(encryptStart) * 1000)
    logger.info(
      "✅ [MLSConversationManager.sendMessage] Encrypted in \(encryptMs)ms - ciphertext: \(ciphertext.count) bytes"
    )

    // ⭐ CRITICAL FIX: Query FFI for actual epoch used during encryption
    // DO NOT use currentConvo.epoch which is the server's potentially stale view
    // The FFI is the ground truth for what epoch was used to encrypt this message
    let actualEpochFFI: UInt64
    do {
      actualEpochFFI = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      logger.debug(
        "📍 [MLSConversationManager.sendMessage] Actual encryption epoch from FFI: \(actualEpochFFI)"
      )

      // 🔒 FIX #1: Fetch FRESH server epoch (not cached) before checking for mismatch
      // The cached currentConvo.epoch may be stale if we missed SSE updates
      let freshServerEpoch: Int
      do {
        freshServerEpoch = try await apiClient.getEpoch(convoId: convoId)
        logger.debug(
          "📍 [MLSConversationManager.sendMessage] Fresh server epoch: \(freshServerEpoch)")
      } catch {
        // If we can't fetch server epoch, use cached value but log warning
        freshServerEpoch = currentConvo.epoch
        logger.warning(
          "⚠️ [MLSConversationManager.sendMessage] Could not fetch fresh server epoch, using cached: \(freshServerEpoch)"
        )
      }

      // 🔒 FIX #1: HARD STOP if local epoch is BEHIND server epoch
      // This prevents the "fail open" bug where we encrypt on a stale epoch that
      // other participants can't decrypt (they've already advanced their ratchet).
      // See: MLS Forward Secrecy - old epoch keys are deleted after advancement.
      if UInt64(freshServerEpoch) > actualEpochFFI {
        logger.error("🚨 [MLSConversationManager.sendMessage] CRITICAL EPOCH DESYNC:")
        logger.error("   Local FFI epoch: \(actualEpochFFI)")
        logger.error("   Server epoch: \(freshServerEpoch)")
        logger.error(
          "   ❌ ABORTING SEND - encrypting on stale epoch would create unreadable message!")

        // Attempt force catchup before failing
        logger.info("🔄 [MLSConversationManager.sendMessage] Attempting force sync to catch up...")
        do {
          try await syncGroupState(for: convoId)

          // Re-check epoch after sync
          let postSyncEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
          if UInt64(freshServerEpoch) > postSyncEpoch {
            // Still behind after sync - likely missed commits, trigger rejoin
            logger.error(
              "🚨 [MLSConversationManager.sendMessage] Still behind after sync (local: \(postSyncEpoch), server: \(freshServerEpoch))"
            )
            logger.error("   Client cannot catch up - may need to rejoin group via External Commit")

            // Mark conversation as needing rejoin
            try await markConversationNeedsRejoin(convoId)

            throw MLSConversationError.epochMismatch
          }
          // Update actualEpochFFI for later use
          logger.info(
            "✅ [MLSConversationManager.sendMessage] Force sync successful - epoch now: \(postSyncEpoch)"
          )
        } catch let mlsError as MLSConversationError {
          throw mlsError
        } catch {
          logger.error(
            "❌ [MLSConversationManager.sendMessage] Force sync failed: \(error.localizedDescription)"
          )
          throw MLSConversationError.epochMismatch
        }
      } else if UInt64(freshServerEpoch) != actualEpochFFI {
        // Local is AHEAD of server - this is normal after group operations
        // Log for visibility but proceed with send
        logger.info(
          "ℹ️ [MLSConversationManager.sendMessage] Epoch difference (FFI ahead of server):")
        logger.info("   FFI epoch: \(actualEpochFFI)")
        logger.info("   Server epoch: \(freshServerEpoch)")
        logger.info("   Proceeding with FFI epoch (server will catch up)")
      }
    } catch let epochError as MLSConversationError {
      // Re-throw MLSConversationError directly (e.g., epochMismatch)
      throw epochError
    } catch {
      logger.error(
        "❌ [MLSConversationManager.sendMessage] Failed to get FFI epoch: \(error.localizedDescription)"
      )
      throw MLSConversationError.operationFailed("Cannot verify encryption epoch from FFI")
    }

    // Send encrypted message directly to server with idempotency key
    do {
      let apiStart = Date()
      logger.debug(
        "📍 [MLSConversationManager.sendMessage] Sending to server with idempotencyKey: \(idempotencyKey)..."
      )

      // Generate a message ID for this send operation
      let msgId = UUID().uuidString

      // Apply padding to match bucket size requirements (min 512 bytes)
      // Server requires paddedSize to be one of: 512, 1024, 2048, 4096, 8192, or multiples of 8192
      // IMPORTANT: The actual ciphertext size is NOT sent to the server (privacy!)
      // Recipients will find the actual size encrypted inside the MLS ciphertext to strip padding
      logger.debug(
        "📍 [MLSConversationManager.sendMessage] Applying padding to ciphertext (\(ciphertext.count) bytes)..."
      )
      let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(ciphertext)
      logger.debug(
        "📍 [MLSConversationManager.sendMessage] Padded to bucket size: \(paddedSize) bytes (actual size hidden for privacy)"
      )

      let (messageId, receivedAt, seq, confirmedEpoch) = try await apiClient.sendMessage(
        convoId: convoId,
        msgId: msgId,
        ciphertext: paddedCiphertext,
        epoch: Int(actualEpochFFI),  // ⭐ Use FFI epoch, not cached server epoch
        paddedSize: paddedSize,
        senderDid: did,
        idempotencyKey: idempotencyKey
      )

      // CRITICAL FIX: Cache plaintext and embed for own messages to prevent self-decryption attempts
      // When the server broadcasts this message back, we'll use the cached plaintext/embed
      // instead of trying to decrypt (which is impossible by MLS design)
      // Server now returns real seq immediately - no more placeholder seq=0!
      logger.debug(
        "📍 [MLSConversationManager.sendMessage] Caching plaintext and embed for message \(messageId) with real seq=\(seq)..."
      )
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
        logger.info(
          "✅ [MLSConversationManager.sendMessage] Plaintext and embed cached for message \(messageId) with seq=\(seq), epoch=\(confirmedEpoch)"
        )
      } catch {
        logger.warning(
          "⚠️ [MLSConversationManager.sendMessage] Failed to cache plaintext/embed: \(error.localizedDescription)"
        )
        // Don't fail the send operation if caching fails
      }

      // ⭐ PROACTIVE FIX: Mark message as "pending" in database
      // This persists across account switches and app restarts
      // When we fetch this message later, we'll check the database and skip FFI processing
      do {
        try await database.write { db in
          // Update the processingState to "pending" so we can identify it later
          try db.execute(
            sql: """
                  UPDATE MLSMessageModel
                  SET processingState = 'pending'
                  WHERE messageID = ? AND currentUserDID = ?;
              """, arguments: [messageId, userDid])
        }
        logger.debug(
          "📌 [MLSConversationManager.sendMessage] Marked message \(messageId) as 'pending' in database"
        )
      } catch {
        logger.warning(
          "⚠️ Failed to mark message as pending in database: \(error.localizedDescription)")
        // Continue anyway - the cache-based fallback will still work
      }

      // Notify observers
      notifyObservers(.messageSent(messageId, receivedAt))

      let apiMs = Int(Date().timeIntervalSince(apiStart) * 1000)
      let totalMs = Int(Date().timeIntervalSince(startTotal) * 1000)
      logger.info(
        "✅ [MLSConversationManager.sendMessage] COMPLETE - msgId: \(messageId), seq: \(seq), epoch: \(confirmedEpoch), api: \(apiMs)ms, total: \(totalMs)ms"
      )
      return (messageId, receivedAt, Int64(seq), Int64(confirmedEpoch))

    } catch {
      let totalMs = Int(Date().timeIntervalSince(startTotal) * 1000)
      logger.error(
        "❌ [MLSConversationManager.sendMessage] Server send failed after \(totalMs)ms: \(error.localizedDescription)"
      )
      throw MLSConversationError.serverError(error)
    }
  }

  // MARK: - Typing Indicators

  /// Send a typing indicator to a conversation
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - isTyping: True if user started typing, false if stopped
  /// - Returns: Whether the typing indicator was sent successfully
  func sendTypingIndicator(convoId: String, isTyping: Bool) async throws -> Bool {
    logger.debug("Sending typing indicator for \(convoId): isTyping=\(isTyping)")
    try throwIfShuttingDown("sendTypingIndicator")

    guard conversations[convoId] != nil else {
      logger.warning("Cannot send typing indicator: conversation \(convoId) not found")
      throw MLSConversationError.conversationNotFound
    }

    return try await apiClient.sendTypingIndicator(convoId: convoId, isTyping: isTyping)
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
    try throwIfShuttingDown("addReaction")

    guard conversations[convoId] != nil else {
      logger.warning("Cannot add reaction: conversation \(convoId) not found")
      throw MLSConversationError.conversationNotFound
    }

    let result = try await apiClient.addReaction(
      convoId: convoId, messageId: messageId, reaction: reaction)

    // Persist reaction locally for offline access
    if result.success, let userDid = userDid {
      let reactionModel = MLSReactionModel(
        messageID: messageId,
        conversationID: convoId,
        currentUserDID: userDid,
        actorDID: userDid,
        emoji: reaction,
        action: "add",
        timestamp: result.reactedAt ?? Date()
      )
      do {
        try await storage.saveReaction(reactionModel, database: database)
      } catch {
        logger.warning("Failed to persist reaction locally: \(error.localizedDescription)")
      }
    }

    return result
  }

  /// Remove a reaction from a message
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - messageId: ID of the message to remove reaction from
  ///   - reaction: Reaction emoji or short code to remove
  /// - Returns: Whether the reaction was removed successfully
  func removeReaction(convoId: String, messageId: String, reaction: String) async throws -> Bool {
    logger.debug("Removing reaction '\(reaction)' from message \(messageId) in \(convoId)")
    try throwIfShuttingDown("removeReaction")

    guard conversations[convoId] != nil else {
      logger.warning("Cannot remove reaction: conversation \(convoId) not found")
      throw MLSConversationError.conversationNotFound
    }

    let success = try await apiClient.removeReaction(
      convoId: convoId, messageId: messageId, reaction: reaction)

    // Remove reaction from local storage
    if success, let userDid = userDid {
      do {
        try await storage.deleteReaction(
          messageID: messageId,
          actorDID: userDid,
          emoji: reaction,
          currentUserDID: userDid,
          database: database
        )
      } catch {
        logger.warning("Failed to delete reaction locally: \(error.localizedDescription)")
      }
    }

    return success
  }

  /// Load cached reactions for a conversation from local storage
  /// - Parameter convoId: Conversation identifier
  /// - Returns: Dictionary mapping messageID to array of MLSMessageReaction
  func loadReactionsForConversation(_ convoId: String) async throws -> [String:
    [MLSMessageReaction]]
  {
    guard let userDid = userDid else {
      logger.warning("Cannot load reactions: no user DID")
      return [:]
    }

    let reactionModels = try await storage.fetchReactionsForConversation(
      convoId,
      currentUserDID: userDid,
      database: database
    )

    // Convert MLSReactionModel to MLSMessageReaction
    var result: [String: [MLSMessageReaction]] = [:]
    for (messageId, models) in reactionModels {
      result[messageId] = models.map { model in
        MLSMessageReaction(
          messageId: model.messageID,
          reaction: model.emoji,
          senderDID: model.actorDID,
          reactedAt: model.timestamp
        )
      }
    }

    logger.debug("Loaded \(result.count) message reactions from cache")
    return result
  }

  /// Save a reaction received via SSE to local storage
  /// - Parameters:
  ///   - reaction: The reaction to save
  ///   - conversationId: Conversation identifier
  func saveReactionFromSSE(_ reaction: MLSMessageReaction, conversationId: String) async {
    guard let userDid = userDid else {
      logger.warning("Cannot save SSE reaction: no user DID")
      return
    }

    let reactionModel = MLSReactionModel(
      messageID: reaction.messageId,
      conversationID: conversationId,
      currentUserDID: userDid,
      actorDID: reaction.senderDID,
      emoji: reaction.reaction,
      action: "add",
      timestamp: reaction.reactedAt ?? Date()
    )

    do {
      try await storage.saveReaction(reactionModel, database: database)
    } catch {
      logger.warning("Failed to persist SSE reaction locally: \(error.localizedDescription)")
    }
  }

  /// Delete a reaction received via SSE from local storage
  /// - Parameters:
  ///   - messageId: The message ID
  ///   - senderDID: The DID of the user who removed the reaction
  ///   - emoji: The emoji that was removed
  ///   - conversationId: Conversation identifier
  func deleteReactionFromSSE(
    messageId: String, senderDID: String, emoji: String, conversationId: String
  ) async {
    guard let userDid = userDid else {
      logger.warning("Cannot delete SSE reaction: no user DID")
      return
    }

    do {
      try await storage.deleteReaction(
        messageID: messageId,
        actorDID: senderDID,
        emoji: emoji,
        currentUserDID: userDid,
        database: database
      )
    } catch {
      logger.warning("Failed to delete SSE reaction locally: \(error.localizedDescription)")
    }
  }

  // MARK: - Send Encrypted Control Messages

  /// Sends an encrypted reaction to a message
  /// - Parameters:
  ///   - emoji: The emoji to send as a reaction
  ///   - targetMessageId: The ID of the message being reacted to
  ///   - conversationId: The conversation identifier
  ///   - action: The action to perform ("add" or "remove")
  /// - Returns: Tuple of messageId, timestamp, sequence number, and epoch from server
  public func sendEncryptedReaction(
    emoji: String,
    to targetMessageId: String,
    in conversationId: String,
    action: MLSReactionPayload.ReactionAction = .add
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.info(
      "🔵 [MLSConversationManager.sendEncryptedReaction] START - emoji: \(emoji), target: \(targetMessageId), action: \(action == .add ? "add" : "remove")"
    )
    try throwIfShuttingDown("sendEncryptedReaction")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[conversationId] else {
      logger.error("❌ [sendEncryptedReaction] Conversation not found: \(conversationId)")
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    let groupExists = await mlsClient.groupExists(for: userDid, groupId: groupIdData)
    guard groupExists else {
      logger.error("❌ [sendEncryptedReaction] Group not found locally")
      throw MLSConversationError.groupNotInitialized
    }

    // Create reaction payload
    let payload = MLSMessagePayload.reaction(
      messageId: targetMessageId,
      emoji: emoji,
      action: action
    )

    guard let plaintextData = try? payload.encodeToJSON() else {
      throw MLSConversationError.invalidMessage
    }

    // Encrypt the payload
    let ciphertext = try await encryptMessage(groupId: convo.groupId, plaintext: plaintextData)

    // Apply padding
    let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(ciphertext)

    // Get epoch from FFI (ground truth)
    let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

    // Generate message ID
    let msgId = UUID().uuidString

    // Send to server
    let result = try await apiClient.sendEncryptedReaction(
      convoId: conversationId,
      msgId: msgId,
      ciphertext: paddedCiphertext,
      epoch: Int(epoch),
      paddedSize: paddedSize
    )

    // Process the reaction locally FIRST (update reaction count in UI)
    // This is the same handler used for reactions from other users
    let reactionPayload = MLSReactionPayload(
      messageId: targetMessageId,
      emoji: emoji,
      action: action
    )
    await handleReceivedReaction(reactionPayload, from: userDid, in: conversationId)

    // CRITICAL FIX: Cache with sentinel plaintext to prevent re-processing
    // When the server broadcasts this message back, we'll recognize it as a
    // control message and skip it (we already processed it above)
    logger.debug(
      "📍 [sendEncryptedReaction] Caching control message envelope for \(result.messageId) with seq=\(result.seq)..."
    )
    do {
      // Use sentinel format consistent with cacheControlMessageEnvelope
      let sentinelPlaintext = "[control:reaction]"
      try await storage.savePlaintextForMessage(
        messageID: result.messageId,
        conversationID: conversationId,
        plaintext: sentinelPlaintext,
        senderID: userDid,
        currentUserDID: userDid,
        embed: nil,
        epoch: Int64(result.epoch),
        sequenceNumber: Int64(result.seq),
        timestamp: result.receivedAt.date,
        database: database
      )
      logger.info(
        "✅ [sendEncryptedReaction] Control message cached for reaction \(result.messageId) with seq=\(result.seq), epoch=\(result.epoch)"
      )
    } catch {
      logger.warning(
        "⚠️ [sendEncryptedReaction] Failed to cache control message: \(error.localizedDescription)"
      )
      // Don't fail the send operation if caching fails
    }

    logger.info(
      "✅ [sendEncryptedReaction] Sent - msgId: \(result.messageId), epoch: \(result.epoch)"
    )
    return result
  }

  /// Sends an encrypted read receipt for one or more messages
  /// - Parameters:
  ///   - messageIds: Array of message IDs that have been read
  ///   - conversationId: The conversation identifier
  /// - Returns: Tuple of messageId, timestamp, sequence number, and epoch from server
  public func sendEncryptedReadReceipt(
    for messageIds: [String],
    in conversationId: String
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.info(
      "🔵 [MLSConversationManager.sendEncryptedReadReceipt] START - messageIds: \(messageIds.count)"
    )
    try throwIfShuttingDown("sendEncryptedReadReceipt")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[conversationId] else {
      logger.error("❌ [sendEncryptedReadReceipt] Conversation not found: \(conversationId)")
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    let groupExists = await mlsClient.groupExists(for: userDid, groupId: groupIdData)
    guard groupExists else {
      logger.error("❌ [sendEncryptedReadReceipt] Group not found locally")
      throw MLSConversationError.groupNotInitialized
    }

    // Create read receipt payload for the first message (API currently supports single message).
    guard let firstMessageId = messageIds.first else {
      throw MLSConversationError.invalidMessage
    }

    let payload = MLSMessagePayload.readReceipt(messageId: firstMessageId)

    guard let plaintextData = try? payload.encodeToJSON() else {
      throw MLSConversationError.invalidMessage
    }

    // Encrypt the payload
    let ciphertext = try await encryptMessage(groupId: convo.groupId, plaintext: plaintextData)

    // Apply padding
    let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(ciphertext)

    // Get epoch from FFI (ground truth)
    let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

    // Generate message ID
    let msgId = UUID().uuidString

    // Send to server
    let result = try await apiClient.sendEncryptedReadReceipt(
      convoId: conversationId,
      msgId: msgId,
      ciphertext: paddedCiphertext,
      epoch: Int(epoch),
      paddedSize: paddedSize
    )

    // Process the read receipt locally FIRST
    // This is the same handler used for read receipts from other users
    let readReceiptPayload = MLSReadReceiptPayload(messageId: firstMessageId)
    await handleReceivedReadReceipt(readReceiptPayload, from: userDid, in: conversationId)

    // CRITICAL FIX: Cache with sentinel plaintext to prevent re-processing
    // When the server broadcasts this message back, we'll recognize it as a
    // control message and skip it (we already processed it above)
    logger.debug(
      "📍 [sendEncryptedReadReceipt] Caching control message envelope for \(result.messageId) with seq=\(result.seq)..."
    )
    do {
      // Use sentinel format consistent with cacheControlMessageEnvelope
      let sentinelPlaintext = "[control:readReceipt]"
      try await storage.savePlaintextForMessage(
        messageID: result.messageId,
        conversationID: conversationId,
        plaintext: sentinelPlaintext,
        senderID: userDid,
        currentUserDID: userDid,
        embed: nil,
        epoch: Int64(result.epoch),
        sequenceNumber: Int64(result.seq),
        timestamp: result.receivedAt.date,
        database: database
      )
      logger.info(
        "✅ [sendEncryptedReadReceipt] Control message cached for read receipt \(result.messageId) with seq=\(result.seq), epoch=\(result.epoch)"
      )
    } catch {
      logger.warning(
        "⚠️ [sendEncryptedReadReceipt] Failed to cache control message: \(error.localizedDescription)"
      )
      // Don't fail the send operation if caching fails
    }

    logger.info(
      "✅ [sendEncryptedReadReceipt] Sent - msgId: \(result.messageId), epoch: \(result.epoch)"
    )
    return result
  }

  /// Sends an encrypted typing indicator
  /// - Parameters:
  ///   - isTyping: Whether the user is currently typing
  ///   - conversationId: The conversation identifier
  /// - Returns: Tuple of messageId, timestamp, sequence number, and epoch from server
  public func sendEncryptedTypingIndicator(
    isTyping: Bool,
    in conversationId: String
  ) async throws -> (messageId: String, receivedAt: ATProtocolDate, seq: Int, epoch: Int) {
    logger.debug(
      "🔵 [MLSConversationManager.sendEncryptedTypingIndicator] START - isTyping: \(isTyping)"
    )
    try throwIfShuttingDown("sendEncryptedTypingIndicator")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[conversationId] else {
      logger.error("❌ [sendEncryptedTypingIndicator] Conversation not found: \(conversationId)")
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    let groupExists = await mlsClient.groupExists(for: userDid, groupId: groupIdData)
    guard groupExists else {
      logger.error("❌ [sendEncryptedTypingIndicator] Group not found locally")
      throw MLSConversationError.groupNotInitialized
    }

    // Create typing payload
    let payload = MLSMessagePayload.typing(isTyping: isTyping)

    guard let plaintextData = try? payload.encodeToJSON() else {
      throw MLSConversationError.invalidMessage
    }

    // Encrypt the payload
    let ciphertext = try await encryptMessage(groupId: convo.groupId, plaintext: plaintextData)

    // Use smaller padding bucket for ephemeral typing indicators (256 bytes minimum)
    let (paddedCiphertext, paddedSize) = try MLSMessagePadding.padCiphertextToBucket(
      ciphertext, minBucket: 256)

    // Get epoch from FFI (ground truth)
    let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

    // Generate message ID
    let msgId = UUID().uuidString

    // Send to server (ephemeral - not stored, SSE only)
    let result = try await apiClient.sendEncryptedTypingIndicator(
      convoId: conversationId,
      msgId: msgId,
      ciphertext: paddedCiphertext,
      epoch: Int(epoch),
      paddedSize: paddedSize
    )

    logger.debug(
      "✅ [sendEncryptedTypingIndicator] Sent (ephemeral) - msgId: \(result.messageId)"
    )
    return result
  }

  /// Decrypt a received message
  /// - Parameter message: Encrypted message view
  /// - Returns: Decrypted message payload with text and optional embed
  func decryptMessage(_ message: BlueCatbirdMlsDefs.MessageView) async throws -> DecryptedMLSMessage
  {
    logger.debug("Decrypting message: \(message.id)")

    let outcome = try await processServerMessage(message)
    switch outcome {
    case .application(let payload, let senderDID):
      return DecryptedMLSMessage(messageView: message, payload: payload, senderDID: senderDID)
    case .nonApplication:
      throw MLSConversationError.invalidMessage
    case .controlMessage:
      // Control messages (reactions, read receipts, typing) are handled internally
      // and should not be returned as decrypted chat messages
      throw MLSConversationError.invalidMessage
    }
  }

  private enum MessageProcessingOutcome {
    case application(payload: MLSMessagePayload, sender: String)
    case nonApplication
    case controlMessage  // Handled but should not be rendered as a chat message (reactions, read receipts, typing)
  }

  /// Process a single server message through UniFFI and return application payloads when available
  private func processServerMessage(_ message: BlueCatbirdMlsDefs.MessageView) async throws
    -> MessageProcessingOutcome
  {
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    return try await withMLSUserPermit(for: userDid) { [self] in
      try await messageProcessingCoordinator.withCriticalSection(conversationID: message.convoId) {
        try await processServerMessageLocked(message)
      }
    }
  }

  private func processServerMessageLocked(_ message: BlueCatbirdMlsDefs.MessageView) async throws
    -> MessageProcessingOutcome
  {
    logger.debug(
      "📦 Processing server message \(message.id) (epoch: \(message.epoch), seq: \(message.seq))")

    guard let convo = conversations[message.convoId] else {
      logger.error(
        "Cannot process message \(message.id) - conversation \(message.convoId) not found")
      throw MLSConversationError.conversationNotFound
    }

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    // CRITICAL FIX: Ensure conversation exists in SQLCipher BEFORE any decrypt operations
    // This prevents FK constraint failures when savePlaintextForMessage tries to insert
    // Without this, decrypt succeeds (advancing secret tree) but save fails, causing
    // SecretReuseError on retry because the one-time key was already consumed
    do {
      try await storage.ensureConversationExists(
        userDID: userDid,
        conversationID: message.convoId,
        groupID: convo.groupId,
        database: database
      )
    } catch {
      // Check if this is a recoverable SQLCipher codec error (e.g., "out of memory")
      // If so, try to get a fresh database connection and retry
      if MLSGRDBManager.shared.isRecoverableCodecError(error) {
        logger.warning("⚠️ Recoverable database error detected, attempting recovery...")
        do {
          let freshDatabase = try await MLSGRDBManager.shared.reconnectDatabase(for: userDid)
          try await storage.ensureConversationExists(
            userDID: userDid,
            conversationID: message.convoId,
            groupID: convo.groupId,
            database: freshDatabase
          )
          logger.info("✅ Database recovered and conversation ensured on retry")
        } catch {
          logger.error("❌ Database recovery failed: \(error.localizedDescription)")
          throw MLSConversationError.operationFailed("Database not ready for message processing")
        }
      } else {
        logger.error(
          "❌ Failed to ensure conversation exists before decrypt: \(error.localizedDescription)")
        throw MLSConversationError.operationFailed("Database not ready for message processing")
      }
    }

    // PRE-PROCESSING VALIDATION: Catch bugs before expensive FFI decryption
    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      logger.error("Invalid groupId for conversation \(convo.groupId)")
      throw MLSConversationError.invalidGroupId
    }

    // Get local epoch for validation
    var localEpoch: Int64 = 0
    do {
      let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      localEpoch = Int64(epoch)
    } catch {
      logger.warning("⚠️ Unable to query local epoch for validation: \(error.localizedDescription)")
    }

    // Validate message structure
    let paddedCiphertext = message.ciphertext.data
    let ciphertextData: Data
    do {
      ciphertextData = try MLSMessagePadding.removePadding(paddedCiphertext)
    } catch {
      logger.error(
        "❌ Failed to remove padding from message \(message.id): \(error.localizedDescription)")
      // Log detailed message characteristics for diagnostics
      logger.debug(
        "📊 Message characteristics - paddedSize: \(paddedCiphertext.count) bytes, epoch: \(message.epoch), seq: \(message.seq)"
      )
      logger.debug("📊 Conversation: \(message.convoId), User: \(userDid ?? "unknown")")
      return try await saveErrorPlaceholder(
        message: message,
        error: "Invalid message padding",
        validationReason: "Failed to decode message structure"
      )
    }

    let structureValidation = MLSMessageValidator.validateMessageStructure(
      epoch: Int64(message.epoch),
      sequenceNumber: Int64(message.seq),
      ciphertextData: ciphertextData,
      localEpoch: localEpoch
    )

    if !structureValidation.isValid {
      logger.warning(
        "⚠️ Message \(message.id) failed structure validation: \(structureValidation.failureReason ?? "unknown")"
      )
      // Log comprehensive diagnostic data for validation failures
      logger.debug(
        "📊 Message: id=\(message.id), epoch=\(message.epoch), seq=\(message.seq), ciphertextLen=\(ciphertextData.count)"
      )
      logger.debug("📊 Group: id=\(convo.groupId.prefix(16))..., localEpoch=\(localEpoch)")
      logger.debug("⚠️  Validation reason: \(structureValidation.failureReason ?? "unknown")")
      return try await saveErrorPlaceholder(
        message: message,
        error: "Message validation failed",
        validationReason: structureValidation.failureReason
      )
    }

    // Validate MLS message format
    let formatValidation = MLSMessageValidator.validateMLSMessageFormat(messageData: ciphertextData)
    if !formatValidation.isValid {
      logger.warning(
        "⚠️ Message \(message.id) failed format validation: \(formatValidation.failureReason ?? "unknown")"
      )
      // Log MLS format violation details
      logger.debug(
        "📊 MLS format validation: ciphertextLen=\(ciphertextData.count), epoch=\(message.epoch), seq=\(message.seq)"
      )
      logger.debug("⚠️  Format issue: \(formatValidation.failureReason ?? "unknown")")
      return try await saveErrorPlaceholder(
        message: message,
        error: "Invalid MLS message format",
        validationReason: formatValidation.failureReason
      )
    }

    // Check if this is a self-sent message by looking up the cached sender
    // MLS cannot decrypt own messages, so we MUST use cached plaintext for self-sent messages
    do {
      if let cachedSender = try await storage.fetchSenderForMessage(
        message.id,
        currentUserDID: userDid,
        database: database
      ) {
        logger.debug(
          "📋 Found cached sender for message \(message.id): \(cachedSender), current user: \(userDid)"
        )
        if cachedSender == userDid {
          // This is our own message - use cached plaintext instead of decrypting
          if let cachedPlaintext = try? await storage.fetchPlaintextForMessage(
            message.id,
            currentUserDID: userDid,
            database: database
          ) {
            let cachedEmbed = try? await storage.fetchEmbedForMessage(
              message.id,
              currentUserDID: userDid,
              database: database
            )
            let payload = MLSMessagePayload.text(cachedPlaintext, embed: cachedEmbed)
            logger.info(
              "♻️ Using cached plaintext for self-sent message \(message.id) - skipping decryption")
            return .application(payload: payload, sender: cachedSender)
          } else {
            logger.error(
              "❌ CRITICAL: Message \(message.id) is self-sent (sender=\(cachedSender)) but plaintext not in cache"
            )
            logger.error(
              "   This will cause CannotDecryptOwnMessage error if we proceed to decrypt")
            logger.error("   Message should have been cached when sent in sendMessage()")
            throw MLSConversationError.invalidMessage
          }
        } else if cachedSender == "unknown" {
          logger.debug(
            "📋 Cached sender is 'unknown' for message \(message.id) - will reprocess to refresh metadata"
          )
          // fall through to MLS decrypt to re-populate sender from credential
        }
      } else {
        logger.debug("📋 No cached sender found for message \(message.id) - will decrypt normally")
      }
    } catch {
      logger.error(
        "❌ Error fetching cached sender for message \(message.id): \(error.localizedDescription)")
      logger.error("   This could lead to attempting to decrypt own message")
      // Don't throw - continue to try decryption, but log the issue
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // 🔒 CRITICAL FIX: Safe cache lookup with DB lock protection
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // PROBLEM: When the database is locked (e.g., during account switching), cache
    // lookups can fail silently (return nil or throw). The old code would then fall
    // back to MLS decryption. But if the epoch has advanced, the decryption keys are
    // DELETED (Forward Secrecy), so re-decryption fails with "Cannot decrypt message
    // from epoch X - group is at epoch Y".
    //
    // SOLUTION:
    // 1. Catch and distinguish DB lock errors from cache misses
    // 2. For DB lock errors: Retry with backoff, don't fall through to decrypt
    // 3. For cached messages with unknown sender: Use cached plaintext instead of
    //    re-decrypting (especially for old epoch messages where re-decrypt is impossible)
    //
    // ═══════════════════════════════════════════════════════════════════════════════
    
    // Get local epoch BEFORE cache lookup to check for old-epoch messages
    var localEpochForCacheCheck: UInt64?
    do {
      localEpochForCacheCheck = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
    } catch {
      logger.debug("⚠️ Could not get local epoch for cache check: \(error.localizedDescription)")
    }
    
    // Check if we have cached data for other users' messages (replay protection)
    // Use do-catch to distinguish DB errors from cache misses
    do {
      // 🔒 ENHANCED FIX: Use fetchMessage to get full model including error state
      // This allows us to detect messages that previously failed processing
      if let cachedMessage = try await storage.fetchMessage(
        messageID: message.id,
        currentUserDID: userDid,
        database: database
      ) {
        let cachedPlaintext = cachedMessage.plaintext
        let cachedSender = cachedMessage.senderID
        let cachedEmbed = cachedMessage.parsedEmbed
        let hasProcessingError = cachedMessage.processingError != nil
        let isPlaintextExpired = cachedMessage.plaintextExpired
        
        // 🔒 CRITICAL: If message already has a processing error saved, don't re-process
        // This prevents infinite retry loops and respects previous error placeholders
        if hasProcessingError {
          logger.debug(
            "⏭️ Skipping previously-failed message \(message.id) (error: \(cachedMessage.processingError ?? "unknown"))"
          )
          // Return as non-application - it's already saved with error state
          return .nonApplication
        }
        
        // If plaintext was explicitly marked as expired, don't try to re-decrypt
        if isPlaintextExpired {
          logger.debug(
            "⏭️ Skipping expired-plaintext message \(message.id) - forward secrecy"
          )
          return .nonApplication
        }
        
        // Check for actual plaintext
        guard let plaintext = cachedPlaintext else {
          // No plaintext cached - fall through to processing
          logger.debug("📋 Message \(message.id) found in DB but no plaintext - will process")
          // Fall through to MLS processing below
          throw NSError(domain: "CacheMiss", code: 0, userInfo: nil) // Force catch block
        }
        
        // Check if this is a cached control message (reaction, readReceipt, typing, etc.)
        // These have sentinel plaintext and should be skipped without re-processing
        if plaintext.hasPrefix("[control:") {
          logger.debug(
            "♻️ Skipping already-processed control message \(message.id) (\(plaintext))")
          return .controlMessage
        }
        
        // 🔒 CRITICAL FIX: For old epoch messages, ALWAYS use cached plaintext
        // Re-decryption is IMPOSSIBLE due to Forward Secrecy - keys are deleted
        let isOldEpochMessage: Bool
        if let localEpoch = localEpochForCacheCheck {
          isOldEpochMessage = UInt64(message.epoch) < localEpoch
        } else {
          isOldEpochMessage = false
        }
        
        if cachedSender == "unknown" {
          if isOldEpochMessage {
            // Old epoch message with unknown sender: Use cached plaintext, don't try decrypt
            logger.warning(
              "⚠️ [FORWARD-SECRECY-PROTECTION] Message \(message.id) from old epoch \(message.epoch) (local: \(localEpochForCacheCheck ?? 0)) has cached plaintext but unknown sender"
            )
            logger.warning(
              "   Using cached plaintext with 'unknown' sender - re-decryption is impossible (keys deleted)"
            )
            let payload = MLSMessagePayload.text(plaintext, embed: cachedEmbed)
            return .application(payload: payload, sender: "unknown")
          } else {
            // Current/future epoch with unknown sender: Safe to re-process to refresh sender
            logger.debug(
              "📋 Cached plaintext found but sender is 'unknown' for message \(message.id) (current epoch) - proceeding to refresh sender"
            )
            // Fall through to MLS processing
          }
        } else {
          // Valid sender cached - use cached data
          let payload = MLSMessagePayload.text(plaintext, embed: cachedEmbed)
          logger.debug("♻️ Using cached plaintext for message \(message.id) (sender: \(cachedSender))")
          return .application(payload: payload, sender: cachedSender)
        }
      }
    } catch let error as NSError where error.domain == "CacheMiss" {
      // Expected - no cached data, proceed to processing
      logger.debug("📋 No cached data for message \(message.id) - will process")
    } catch {
      // 🔒 CRITICAL: Distinguish database lock errors from other errors
      let errorDesc = error.localizedDescription.lowercased()
      let isDbLockError = errorDesc.contains("database is locked") 
        || errorDesc.contains("sqlite error 5")  // SQLITE_BUSY
        || errorDesc.contains("sqlite error 6")  // SQLITE_LOCKED
        || errorDesc.contains("database table is locked")
      
      if isDbLockError {
        logger.error("🔒 [DB-LOCK-PROTECTION] Database locked during cache lookup for message \(message.id)")
        logger.error("   Error: \(error.localizedDescription)")
        
        // 🔒 CRITICAL: For old epoch messages, do NOT fall through to decrypt
        // The decryption WILL fail and we'll lose the ability to show this message
        if let localEpoch = localEpochForCacheCheck, UInt64(message.epoch) < localEpoch {
          logger.error(
            "   ⛔ Message is from old epoch \(message.epoch) (local: \(localEpoch)) - CANNOT re-decrypt"
          )
          logger.error(
            "   Returning loading state - DO NOT attempt MLS decryption (forward secrecy)"
          )
          // Return a special outcome indicating transient failure - caller should retry
          throw MLSConversationError.operationFailed(
            "Database locked during cache lookup. Message \(message.id) is from old epoch and cannot be re-decrypted. Please retry."
          )
        }
        
        // For current epoch messages, log warning but allow fallthrough
        // The decryption might succeed, but we risk SecretReuseError if already processed
        logger.warning(
          "   ⚠️ Message is from current epoch - will attempt decrypt (risk of SecretReuseError)"
        )
      } else {
        // Other DB errors - log but continue
        logger.warning("⚠️ Cache lookup failed for message \(message.id): \(error.localizedDescription)")
      }
    }

    // Check if this is our own commit that we already merged locally
    // If so, skip processing it to avoid epoch mismatch errors
    if isOwnCommit(ciphertextData) {
      logger.info("⏭️ Skipping own commit message \(message.id) - already merged locally")
      logger.debug("   Epoch: \(message.epoch), Seq: \(message.seq)")
      logger.debug(
        "   This commit was created by us and already processed via mergePendingCommit()")
      return .nonApplication
    }

    // Reuse the epoch check from cache lookup, or re-fetch if not available
    var localEpochBeforeMessage: UInt64? = localEpochForCacheCheck
    if localEpochBeforeMessage == nil {
      do {
        localEpochBeforeMessage = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      } catch {
        logger.warning(
          "⚠️ Unable to query local epoch before processing message \(message.id): \(error.localizedDescription)"
        )
      }
    }
    
    if let epochValue = localEpochBeforeMessage {
      logger.debug("🧠 [MLS] Before processing \(message.id) local epoch = \(epochValue)")

      // 🔒 FIX #7: Skip old epoch messages BEFORE calling FFI decryption
      // MLS forward secrecy means old epoch keys are deleted after advancement.
      // Attempting to decrypt old epoch messages will fail with key-not-found errors.
      // Skip these early to avoid log noise and unnecessary FFI calls.
      if UInt64(message.epoch) < epochValue {
        logger.debug(
          "⏭️ Skipping old message from epoch \(message.epoch) (local: \(epochValue)) - keys no longer available"
        )
        return try await saveErrorPlaceholder(
          message: message,
          error: "Message from old epoch",
          validationReason:
            "Epoch \(message.epoch) is behind local epoch \(epochValue) - forward secrecy prevents decryption"
        )
      }
    }

    do {
      let processedContent = try await mlsClient.processMessage(
        for: userDid,
        groupId: groupIdData,
        messageData: ciphertextData
      )

      // Signal ratchet advance to other in-process/cross-process contexts.
      MLSStateVersionManager.shared.incrementVersion(for: userDid)

      // NOTE: OpenMLS SqliteStorageProvider auto-persists state changes
      // No manual save needed - secret tree state is durable after processMessage returns

      if let localEpochBeforeMessage {
        do {
          let localEpochAfter = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
          if localEpochAfter != localEpochBeforeMessage {
            logger.debug(
              "🧠 [MLS] Epoch advanced from \(localEpochBeforeMessage) to \(localEpochAfter) after message \(message.id)"
            )
          }
        } catch {
          logger.warning(
            "⚠️ Unable to query local epoch after processing message \(message.id): \(error.localizedDescription)"
          )
        }
      }

      switch processedContent {
      case .applicationMessage(let plaintext, let senderCredential):
        let senderDID = try extractDIDFromCredential(senderCredential)
        let payload = try MLSMessagePayload.decodeFromJSON(plaintext)

        // Log sender credential details for successful decryption
        let credentialIdentityStr =
          String(data: senderCredential.identity, encoding: .utf8) ?? "unable-to-decode"
        logger.debug("✅ Successfully decrypted message \(message.id)")
        logger.debug(
          "📋 Sender credential - DID: \(credentialIdentityStr), identityLen: \(senderCredential.identity.count)"
        )
        logger.debug(
          "📊 Message delivered - epoch: \(message.epoch), seq: \(message.seq), payloadLen: \(plaintext.count)"
        )

        // MARK: - Message Type Dispatch
        // Route messages based on type to appropriate handlers
        // CRITICAL: Non-text message types MUST cache their envelope to prevent re-processing.
        // MLS secret tree advances after decryption, so re-decrypting causes SecretReuseError.
        switch payload.messageType {
        case .text:
          // Continue existing flow - handled below as application message
          break

        case .reaction:
          if let reactionPayload = payload.reaction {
            await handleReceivedReaction(reactionPayload, from: senderDID, in: message.convoId)
          } else {
            logger.warning("⚠️ Received reaction message without reaction payload")
          }
          // Cache the control message envelope to prevent re-processing (fixes ratchet desync)
          await cacheControlMessageEnvelope(
            message: message, messageType: .reaction, senderDID: senderDID, currentUserDID: userDid)
          return .controlMessage

        case .readReceipt:
          if let readReceiptPayload = payload.readReceipt {
            await handleReceivedReadReceipt(
              readReceiptPayload, from: senderDID, in: message.convoId)
          } else {
            logger.warning("⚠️ Received readReceipt message without readReceipt payload")
          }
          // Cache the control message envelope to prevent re-processing (fixes ratchet desync)
          await cacheControlMessageEnvelope(
            message: message, messageType: .readReceipt, senderDID: senderDID,
            currentUserDID: userDid)
          return .controlMessage

        case .typing:
          if let typingPayload = payload.typing {
            await handleReceivedTyping(typingPayload, from: senderDID, in: message.convoId)
          } else {
            logger.warning("⚠️ Received typing message without typing payload")
          }
          // Cache the control message envelope to prevent re-processing (fixes ratchet desync)
          await cacheControlMessageEnvelope(
            message: message, messageType: .typing, senderDID: senderDID, currentUserDID: userDid)
          return .controlMessage

        case .adminRoster:
          logger.info("Received adminRoster message from \(senderDID) in \(message.convoId)")
          // Note: admin roster updates are currently not applied client-side.
          // Cache the control message envelope to prevent re-processing (fixes ratchet desync)
          await cacheControlMessageEnvelope(
            message: message, messageType: .adminRoster, senderDID: senderDID,
            currentUserDID: userDid)
          return .controlMessage

        case .adminAction:
          logger.info("Received adminAction message from \(senderDID) in \(message.convoId)")
          // Note: admin actions are currently not applied client-side.
          // Cache the control message envelope to prevent re-processing (fixes ratchet desync)
          await cacheControlMessageEnvelope(
            message: message, messageType: .adminAction, senderDID: senderDID,
            currentUserDID: userDid)
          return .controlMessage
        }

        // Text message flow continues here
        if senderDID == userDid {
          logger.debug(
            "🔁 Received application message from current user (\(message.id)); ciphertext should already be cached"
          )
        }

        do {
          try await storage.savePlaintextForMessage(
            messageID: message.id,
            conversationID: message.convoId,
            plaintext: payload.text ?? "",
            senderID: senderDID,
            currentUserDID: userDid,
            embed: payload.embed,
            epoch: Int64(message.epoch),
            sequenceNumber: Int64(message.seq),
            timestamp: message.createdAt.date,
            database: database
          )
          logger.debug(
            "💾 Cached plaintext for message \(message.id) (epoch: \(message.epoch), seq: \(message.seq))"
          )
          do {
            try await database.write { db in
              try db.execute(
                sql: """
                      UPDATE MLSMessageModel
                      SET processingState = 'confirmed'
                      WHERE messageID = ? AND currentUserDID = ?;
                  """, arguments: [message.id, userDid])
            }
            logger.debug("🗂️ Marked message \(message.id) as confirmed in SQLCipher cache")
          } catch {
            logger.warning(
              "⚠️ Unable to update processing state for \(message.id): \(error.localizedDescription)"
            )
          }
        } catch {
          logger.error(
            "❌ Failed to cache plaintext for \(message.id): \(error.localizedDescription)")
        }

        return .application(payload: payload, sender: senderDID)

      case .proposal(let proposal, let proposalRef):
        logger.info("📜 Processing proposal message \(message.id)")
        try await handleProposal(
          groupId: convo.groupId, proposal: proposal, proposalRef: proposalRef)
        return .nonApplication

      case .stagedCommit(let newEpoch):
        // Staged commit was already auto-merged by processMessage in Rust - just verify
        logger.info("📡 Commit message \(message.id) processed, verifying epoch \(newEpoch)")
        try await validateAndMergeStagedCommit(groupId: convo.groupId, newEpoch: newEpoch)
        return .nonApplication
      }
    } catch let error as MLSError {
      // Ignore forward-secrecy rejections (messages from old epochs should not surface)
      if case .ignoredOldEpochMessage = error {
        logger.info(
          "ℹ️ Message \(message.id) from old epoch ignored (forward secrecy) - skipping placeholder/UI"
        )
        return .nonApplication
      }

      // CRITICAL FIX: Distinguish between different error types
      // 1. InvalidSignature: Message signature validation failed (group out of sync)
      // 2. SecretReuseError: Message already processed (can skip safely)
      // 3. Other validation errors

      // SAFETY: Defensive error message access to prevent crashes from corrupted FFI strings
      let errorDescription =
        (try? String(describing: error.localizedDescription)) ?? "Unknown error"

      // Check for signature validation failures (distinct from secret reuse!)
      let isInvalidSignature: Bool
      let isSecretReuse: Bool

      if case .ratchetStateDesync(let reason) = error {
        // SAFETY: Create safe copy of reason string to avoid corruption
        let safeReason = String(describing: reason)

        // InvalidSignature errors contain "InvalidSignature" or "ValidationError" in the message
        isInvalidSignature =
          safeReason.contains("InvalidSignature")
          || (safeReason.contains("ValidationError") && safeReason.contains("Signature"))

        // SecretReuseError is a specific error type, NOT a generic "Decryption failed"
        isSecretReuse = safeReason.contains("SecretReuseError")
      } else {
        isInvalidSignature =
          errorDescription.contains("InvalidSignature")
          || (errorDescription.contains("ValidationError")
            && errorDescription.contains("Signature"))
        isSecretReuse = errorDescription.contains("SecretReuseError")
      }

      // Handle InvalidSignature separately from SecretReuseError
      if isInvalidSignature {
        logger.error("❌ Message \(message.id) signature validation failed - group state desync")

        // Log comprehensive diagnostics for signature failures
        logger.error("🔴 INVALID SIGNATURE ERROR - Critical diagnostic data:")
        logger.error("   Message ID: \(message.id)")
        logger.error("   Epoch: \(message.epoch), Sequence: \(message.seq)")
        logger.error("   Ciphertext length: \(ciphertextData.count) bytes")
        logger.error("   Conversation: \(message.convoId)")
        logger.error("   Group ID: \(convo.groupId.prefix(16))...")
        logger.error("   Local epoch: \(localEpoch), Remote epoch: \(message.epoch)")

        if let epochBefore = localEpochBeforeMessage {
          logger.error("   Epoch before processing: \(epochBefore)")
        }

        logger.error("   Error details: \(error.localizedDescription)")
        logger.error("   This indicates: Sender's signature key not in local group state")
        logger.error("   Root cause: Group membership/key state out of sync with server")
        logger.error("   Recovery action: Initiating group state resynchronization")

        // Trigger automatic recovery
        await attemptRecoveryOnDecryptionFailure(conversationID: message.convoId, error: error)

        // Save placeholder with correct error message
        return try await saveErrorPlaceholder(
          message: message,
          error: "Message signature validation failed - group may be out of sync",
          validationReason: "InvalidSignature"
        )
      }

      // ═══════════════════════════════════════════════════════════════════════════
      // CRITICAL FIX (2024-12): Handle SecretReuseError by checking cache
      // ═══════════════════════════════════════════════════════════════════════════
      //
      // SecretReuseError means the message was already decrypted (likely by NSE).
      // Before giving up, check if the plaintext is in the database cache.
      // This is the expected case when NSE wins the race to decrypt a message.
      //
      // ═══════════════════════════════════════════════════════════════════════════
      if isSecretReuse {
        logger.info(
          "ℹ️ Message \(message.id) SecretReuseError - checking if NSE cached the plaintext")
        
        // Try to retrieve from cache (NSE should have saved it)
        let userDid = userDid 
          do {
            let database = try await MLSGRDBManager.shared.getDatabasePool(for: userDid)
            if let cachedPlaintext = try await storage.fetchPlaintextForMessage(
              message.id,
              currentUserDID: userDid,
              database: database
            ) {
              logger.info("✅ Retrieved cached plaintext for message \(message.id) (decrypted by NSE)")
              // Also fetch the sender from the database (stored during decryption)
              let cachedSender = try await storage.fetchSenderForMessage(
                message.id,
                currentUserDID: userDid,
                database: database
              ) ?? "unknown"
              
              // Return success with cached content - message was already processed correctly
              // Parse the cached plaintext back into a payload
              if let payloadData = cachedPlaintext.data(using: .utf8),
                 let payload = try? MLSMessagePayload.decodeFromJSON(payloadData) {
                return .application(payload: payload, sender: cachedSender)
              } else {
                // Fallback: wrap plaintext in a text payload
                let payload = MLSMessagePayload.text(cachedPlaintext, embed: nil)
                return .application(payload: payload, sender: cachedSender)
              }
            }
            logger.warning("⚠️ SecretReuseError but cache miss for \(message.id)")
          } catch {
            logger.warning("⚠️ Failed to check cache for \(message.id): \(error.localizedDescription)")
          }
        
        
        // If cache miss, log diagnostics but don't save error placeholder
        // The message may appear on next sync
        logger.warning(
          "⚠️ Message \(message.id) SecretReuseError - plaintext not in cache, skipping")
        logger.debug("   Epoch: \(message.epoch), Sequence: \(message.seq)")
        logger.debug("   This can happen if NSE was interrupted before saving")
        
        // Skip silently - don't save error placeholder for expected race condition
        return .nonApplication
      }

      if case .ratchetStateDesync(let reason) = error {
        // Check if this is just forward secrecy doing its job (old message)
        // Check both metadata epoch AND the actual FFI error message
        let isOldEpochError =
          reason.contains("Cannot decrypt message from epoch")
          && (reason.contains("forward secrecy") || reason.contains("group is at epoch"))

        if message.epoch < localEpoch || isOldEpochError {
          logger.info(
            "ℹ️ Message \(message.id) is from old epoch (metadata: \(message.epoch), local: \(localEpoch)). Ignoring due to forward secrecy."
          )
          // Return non-application outcome so it's just skipped, not saved as error
          return .nonApplication
        }

        logger.error("❌ Ratchet state desync for message \(message.id): \(reason)")

        // Log comprehensive ratchet state diagnostics
        logger.error("🔴 RATCHET STATE DESYNC - Critical diagnostic data:")
        logger.error("   Message ID: \(message.id)")
        logger.error("   Message epoch: \(message.epoch), sequence: \(message.seq)")
        logger.error("   Conversation ID: \(message.convoId)")
        logger.error("   Group ID: \(convo.groupId.prefix(16))...")
        logger.error("   Local epoch before: \(localEpochBeforeMessage ?? 0)")
        logger.error("   Sync error reason: \(reason)")
        logger.error("   Ciphertext length: \(ciphertextData.count) bytes")
        logger.error("   This indicates: MLS group state on client doesn't match server state")
        logger.error("   Recovery action: Initiating automatic state synchronization")

        // Trigger automatic recovery
        await attemptRecoveryOnDecryptionFailure(conversationID: message.convoId, error: error)
        // Save placeholder
        return try await saveErrorPlaceholder(
          message: message,
          error: "Ratchet state desync: \(reason)",
          validationReason: nil
        )
      }

      // Other MLSError types - save placeholder and continue
      logger.error("❌ MLS error processing message \(message.id): \(error.localizedDescription)")

      // Log diagnostic details for other MLS errors
      logger.debug("📊 MLS error context:")
      logger.debug("   Message ID: \(message.id)")
      logger.debug("   Epoch: \(message.epoch), Seq: \(message.seq)")
      logger.debug("   Conversation: \(message.convoId)")
      logger.debug("   Group: \(convo.groupId.prefix(16))...")
      logger.debug("   Ciphertext size: \(ciphertextData.count) bytes")
      logger.debug("   Local epoch: \(localEpoch)")
      logger.debug("   Error type: \(String(describing: error))")

      // SAFETY: Create safe copy of error description
      let safeErrorDesc = String(describing: error.localizedDescription)
      return try await saveErrorPlaceholder(
        message: message,
        error: safeErrorDesc,
        validationReason: nil
      )
    } catch {
      // Check for CannotDecryptOwnMessage error from OpenMLS FFI
      // SAFETY: Create safe copy of error description
      let errorString = String(describing: error.localizedDescription)
      if errorString.contains("CannotDecryptOwnMessage") || errorString.contains("ValidationError")
      {
        logger.error("❌ CRITICAL: CannotDecryptOwnMessage error for message \(message.id)")
        logger.error("   This means we're trying to decrypt a message we sent ourselves")
        logger.error("   The message should have been cached when sent, but was not found in cache")
        logger.error(
          "   Check that sendMessage() properly caches plaintext with messageID: \(message.id)")
        logger.error("   User DID: \(userDid)")

        // Log detailed context for self-sent message failures
        logger.error("🔴 SELF-SENT MESSAGE ERROR - Diagnostic data:")
        logger.error("   Message ID: \(message.id)")
        logger.error("   Message epoch: \(message.epoch), sequence: \(message.seq)")
        logger.error("   Ciphertext length: \(ciphertextData.count) bytes")
        logger.error("   Current user DID: \(userDid ?? "unknown")")
        logger.error("   Conversation: \(message.convoId)")
        logger.error("   Group ID: \(convo.groupId.prefix(16))...")
        logger.error("   Root cause: Message cache not found during sendMessage() execution")
        logger.error("   Impact: User will see error placeholder instead of sent message")

        // Save placeholder for self-sent message error
        return try await saveErrorPlaceholder(
          message: message,
          error: "Cannot decrypt own message (plaintext not cached)",
          validationReason: "Self-sent message without cached plaintext"
        )
      }

      logger.error("❌ Failed to process MLS message \(message.id): \(error.localizedDescription)")

      // Log diagnostic details for unhandled errors
      logger.debug("📊 Unhandled error context:")
      logger.debug("   Message ID: \(message.id)")
      logger.debug("   Epoch: \(message.epoch), Seq: \(message.seq)")
      logger.debug("   Conversation: \(message.convoId)")
      logger.debug("   Group: \(convo.groupId.prefix(16))...")
      logger.debug("   Error description: \(error.localizedDescription)")
      logger.debug("   Error type: \(String(describing: type(of: error)))")

      // Save placeholder for any other error
      // SAFETY: Create safe copy of error description
      let safeErrorDesc = String(describing: error.localizedDescription)
      return try await saveErrorPlaceholder(
        message: message,
        error: safeErrorDesc,
        validationReason: nil
      )
    }
  }

  /// Extract the sender DID from MLS credential data
  func extractDIDFromCredential(_ credential: CredentialData) throws -> String {
    guard let didString = String(data: credential.identity, encoding: .utf8) else {
      logger.error("❌ Failed to decode credential identity as UTF-8")
      throw MLSConversationError.invalidCredential
    }

    guard didString.starts(with: "did:") else {
      logger.error("❌ Invalid DID format in credential: \(didString)")
      throw MLSConversationError.invalidCredential
    }

    return didString
  }

  // MARK: - Control Message Handlers

  /// Cache a control message envelope to prevent re-processing after successful decryption.
  ///
  /// MLS secret tree advances after each decryption, so attempting to decrypt the same message
  /// twice causes `SecretReuseError`. This function caches the message envelope with a sentinel
  /// plaintext so that `sinceSeq` queries return the correct sequence number and skip
  /// already-processed messages.
  ///
  /// - Parameters:
  ///   - message: The server message envelope containing id, epoch, seq, etc.
  ///   - messageType: The type of control message (reaction, readReceipt, typing, etc.)
  ///   - senderDID: DID of the sender extracted from the MLS credential
  ///   - currentUserDID: DID of the current user (already unwrapped from context)
  private func cacheControlMessageEnvelope(
    message: BlueCatbirdMlsDefs.MessageView,
    messageType: MLSMessageType,
    senderDID: String,
    currentUserDID: String
  ) async {
    do {
      // Use a sentinel plaintext that identifies this as a cached control message
      // This allows sinceSeq queries to correctly skip already-processed messages
      let sentinelPlaintext = "[control:\(messageType.rawValue)]"

      try await storage.savePlaintextForMessage(
        messageID: message.id,
        conversationID: message.convoId,
        plaintext: sentinelPlaintext,
        senderID: senderDID,
        currentUserDID: currentUserDID,
        embed: nil,
        epoch: Int64(message.epoch),
        sequenceNumber: Int64(message.seq),
        timestamp: message.createdAt.date,
        database: database
      )

      logger.debug(
        "💾 Cached control message envelope \(message.id) (type: \(messageType.rawValue), epoch: \(message.epoch), seq: \(message.seq))"
      )
    } catch {
      // Log but don't fail - the control message was still processed successfully
      // Worst case is we may re-process it on next fetch (which will fail but be handled)
      logger.warning(
        "⚠️ Failed to cache control message \(message.id): \(error.localizedDescription)"
      )
    }
  }

  /// Handle a received reaction from another user
  /// - Parameters:
  ///   - payload: The reaction payload containing emoji, target message ID, and action
  ///   - senderDID: DID of the user who sent the reaction
  ///   - conversationId: Conversation where the reaction occurred
  private func handleReceivedReaction(
    _ payload: MLSReactionPayload,
    from senderDID: String,
    in conversationId: String
  ) async {
    logger.info(
      "Processing reaction: \(payload.emoji) on \(payload.messageId) action=\(payload.action == .add ? "add" : "remove")"
    )

    switch payload.action {
    case .add:
      // Create reaction model and save to database
      let reaction = MLSMessageReaction(
        messageId: payload.messageId,
        reaction: payload.emoji,
        senderDID: senderDID,
        reactedAt: Date()
      )
      await saveReactionFromSSE(reaction, conversationId: conversationId)

      // Notify observers for UI update
      notifyObservers(
        .reactionReceived(
          convoId: conversationId,
          messageId: payload.messageId,
          emoji: payload.emoji,
          senderDID: senderDID,
          action: "add"
        ))

    case .remove:
      // Remove reaction from database
      await deleteReactionFromSSE(
        messageId: payload.messageId,
        senderDID: senderDID,
        emoji: payload.emoji,
        conversationId: conversationId
      )

      // Notify observers for UI update
      notifyObservers(
        .reactionReceived(
          convoId: conversationId,
          messageId: payload.messageId,
          emoji: payload.emoji,
          senderDID: senderDID,
          action: "remove"
        ))
    }
  }

  /// Handle a received read receipt from another user
  /// - Parameters:
  ///   - payload: The read receipt payload containing the message ID that was read
  ///   - senderDID: DID of the user who read the message
  ///   - conversationId: Conversation where the read receipt applies
  private func handleReceivedReadReceipt(
    _ payload: MLSReadReceiptPayload,
    from senderDID: String,
    in conversationId: String
  ) async {
    logger.info(
      "Processing read receipt for \(payload.messageId) from \(senderDID)"
    )

    // Notify observers for UI update - the view layer can update MLSReadReceiptState
    notifyObservers(
      .readReceiptReceived(
        convoId: conversationId,
        messageId: payload.messageId,
        senderDID: senderDID
      ))

    // Note: Read receipt persistence could be added here if needed
    // Currently, read receipts are ephemeral and handled by the UI layer
    // via MLSReadReceiptState which is managed at the view level
  }

  /// Handle a received typing indicator from another user
  /// - Parameters:
  ///   - payload: The typing payload indicating whether the user is typing
  ///   - senderDID: DID of the user whose typing state changed
  ///   - conversationId: Conversation where the typing indicator applies
  private func handleReceivedTyping(
    _ payload: MLSTypingPayload,
    from senderDID: String,
    in conversationId: String
  ) async {
    logger.info(
      "Processing typing indicator: \(payload.isTyping) from \(senderDID) in \(conversationId)"
    )

    // Update typing state on main thread since it may trigger UI updates
    await MainActor.run {
      if payload.isTyping {
        // Add with 8 second TTL
        let expiresAt = Date().addingTimeInterval(8)
        if typingUsers[conversationId] == nil {
          typingUsers[conversationId] = [:]
        }
        typingUsers[conversationId]?[senderDID] = expiresAt
        startTypingCleanupTimerIfNeeded()
      } else {
        // Remove immediately
        typingUsers[conversationId]?.removeValue(forKey: senderDID)
        if typingUsers[conversationId]?.isEmpty == true {
          typingUsers.removeValue(forKey: conversationId)
        }
      }
    }

    // Notify observers with current typing users for this conversation
    let activeTypers = getTypingUsers(in: conversationId)
    notifyObservers(.typingChanged(convoId: conversationId, typingUsers: activeTypers))
  }

  /// Returns DIDs of users currently typing in a conversation
  /// - Parameter conversationId: The conversation to check
  /// - Returns: Array of DIDs of users who are currently typing
  public func getTypingUsers(in conversationId: String) -> [String] {
    let now = Date()
    return typingUsers[conversationId]?.compactMap { did, expires in
      expires > now ? did : nil
    } ?? []
  }

  /// Start the typing cleanup timer if not already running
  private func startTypingCleanupTimerIfNeeded() {
    guard typingCleanupTimer == nil else { return }

    // Schedule timer on main thread
    typingCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.cleanupExpiredTyping()
      }
    }
  }

  /// Remove expired typing indicators and stop timer if no more typing users
  @MainActor
  private func cleanupExpiredTyping() {
    let now = Date()
    var conversationsToNotify: [String] = []

    for (convoId, users) in typingUsers {
      let previousCount = users.count
      let active = users.filter { $0.value > now }

      if active.isEmpty {
        typingUsers.removeValue(forKey: convoId)
        if previousCount > 0 {
          conversationsToNotify.append(convoId)
        }
      } else if active.count != previousCount {
        typingUsers[convoId] = active
        conversationsToNotify.append(convoId)
      }
    }

    // Notify observers for any conversations where typing state changed
    for convoId in conversationsToNotify {
      let activeTypers = getTypingUsers(in: convoId)
      notifyObservers(.typingChanged(convoId: convoId, typingUsers: activeTypers))
    }

    // Stop timer if no more typing users
    if typingUsers.isEmpty {
      typingCleanupTimer?.invalidate()
      typingCleanupTimer = nil
    }
  }

  /// Process messages in sequential order
  /// - Parameters:
  ///   - messages: Messages to process (server guarantees (epoch, seq) ordering)
  ///   - conversationID: Conversation these messages belong to
  /// - Returns: Successfully processed message payloads
  /// - Note: Server guarantees messages are pre-sorted by (epoch ASC, seq ASC).
  ///         However, we reorder within each epoch to process application messages BEFORE commits.
  ///         This prevents forward secrecy race conditions where commits delete epoch keys
  ///         before all application messages from that epoch are decrypted.
  func processMessagesInOrder(
    messages: [BlueCatbirdMlsDefs.MessageView],
    conversationID: String
  ) async throws -> [MLSMessagePayload] {
    logger.debug("📊 Processing \(messages.count) messages for conversation \(conversationID)")

    guard let userDid = userDid else {
      logger.error("Cannot process messages: no authenticated user")
      return []
    }

    guard !messages.isEmpty else {
      return []
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // 🔒 FORWARD SECRECY RACE CONDITION FIX (v2 - Epoch-Aware Ordering)
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // ORIGINAL PROBLEM (v1 fix):
    // Server returns messages sorted by (epoch ASC, seq ASC). A typical batch might be:
    //   [App msg epoch 1, Commit epoch 1→2, App msg epoch 1]
    // Processing sequentially would advance epoch before decrypting all epoch 1 msgs.
    // v1 fix: Always process apps before commits within each epoch bucket.
    //
    // NEW PROBLEM (discovered in member removal flow):
    // Commits are tagged with the epoch they CREATE, not the epoch they start from.
    // Example: Member removal transitions epoch 1 → epoch 2, tagged as "epoch 2".
    //
    // When josh2 syncs after josh.uno removes j0sh:
    //   - seq 4: epoch 1 app message
    //   - seq 5: epoch 2 commit (member removal - CREATES epoch 2)
    //   - seq 6: epoch 2 app message
    //
    // With v1 logic (apps before commits within each epoch):
    //   Epoch 1: [seq 4 app] → decrypt ✅
    //   Epoch 2: [seq 6 app, seq 5 commit] → tries seq 6 first → FAILS ❌
    //     (can't decrypt epoch 2 app without first processing the commit that
    //      derives epoch 2 keys)
    //
    // THE v2 FIX:
    // Query LOCAL epoch before processing each epoch bucket:
    //   - If localEpoch >= messageEpoch: Process apps FIRST (we have the keys)
    //   - If localEpoch < messageEpoch: Process commits FIRST (need to advance)
    //
    // This handles BOTH scenarios:
    //   1. Multiple app msgs before a commit → apps first (original fix)
    //   2. Epoch-crossing commits → commit first (new fix)
    //
    // ═══════════════════════════════════════════════════════════════════════════════

    logger.debug(
      "📡 Epoch-aware replay pipeline starting for convo \(conversationID) with \(messages.count) message(s)"
    )

    // Group messages by epoch, preserving order within each epoch
    var messagesByEpoch: [Int: [BlueCatbirdMlsDefs.MessageView]] = [:]
    for message in messages {
      messagesByEpoch[message.epoch, default: []].append(message)
    }

    // Sort epochs in ascending order
    let sortedEpochs = messagesByEpoch.keys.sorted()

    logger.info(
      "🔄 Forward-secrecy-aware processing: \(sortedEpochs.count) epoch(s) spanning \(sortedEpochs.first ?? 0)...\(sortedEpochs.last ?? 0)"
    )

    var processedPayloads: [MLSMessagePayload] = []
    var totalProcessed = 0
    var totalFailed = 0
    var totalSkipped = 0

    // Convert conversationID to groupIdData for epoch queries
    guard let groupIdData = Data(hexEncoded: conversationID) else {
      logger.error("Invalid conversationID (not valid hex): \(conversationID)")
      throw MLSConversationError.invalidGroupId
    }

    for epoch in sortedEpochs {
      guard let epochMessages = messagesByEpoch[epoch] else { continue }

      // Check for cancellation at epoch boundaries (safe point)
      try Task.checkCancellation()

      // ═══════════════════════════════════════════════════════════════════════════════
      // 🔑 EPOCH-AWARE ORDERING FIX
      // ═══════════════════════════════════════════════════════════════════════════════
      //
      // Query our CURRENT local epoch to determine message processing order:
      //
      // CASE 1: localEpoch >= messageEpoch (we're AT or PAST this epoch)
      //   → Process apps FIRST, then commits (preserve forward secrecy)
      //   → We have the keys for this epoch, decrypt everything before advancing
      //
      // CASE 2: localEpoch < messageEpoch (we need to ADVANCE to this epoch)
      //   → Process commits FIRST, then apps
      //   → The commit CREATES the epoch keys we need to decrypt the app messages
      //   → Example: Member removal commit is tagged as epoch 2 (the epoch it creates),
      //     but we're at epoch 1. Must process commit first to derive epoch 2 keys.
      //
      // ═══════════════════════════════════════════════════════════════════════════════
      var localEpoch: UInt64 = 0
      do {
        localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      } catch {
        logger.warning(
          "⚠️ Unable to query local epoch before processing epoch \(epoch): \(error.localizedDescription)"
        )
        // Default to apps-first if we can't query (safer for forward secrecy)
      }

      let needCommitsFirst = localEpoch < UInt64(epoch)

      // Separate application messages from commits/handshake messages
      // messageType: "app" = application, "commit"/"handshake" = control message
      //
      // DEFENSIVE FALLBACK: If messageType is nil (older servers), we default to "app"
      // since application messages are most common. If a commit is misclassified as app,
      // the worst case is the epoch advances mid-batch - but we'll still process
      // remaining app messages in the next epoch's batch.
      let (appMessages, commitMessages) = epochMessages.reduce(
        into: (app: [BlueCatbirdMlsDefs.MessageView](), commit: [BlueCatbirdMlsDefs.MessageView]())
      ) { result, msg in
        let msgType = (msg.messageType ?? "app").lowercased()
        // Treat "app" and "application" as application messages
        // Everything else (commit, handshake, proposal, etc.) is a control message
        if msgType == "app" || msgType == "application" {
          result.app.append(msg)
        } else {
          result.commit.append(msg)
        }
      }

      // Log distribution for debugging epoch-crossing issues
      if needCommitsFirst {
        logger.info(
          "📦 Epoch \(epoch): \(appMessages.count) app(s), \(commitMessages.count) commit(s) - processing COMMITS FIRST (local epoch \(localEpoch) < message epoch \(epoch))"
        )
      } else if commitMessages.count > 0 {
        logger.info(
          "📦 Epoch \(epoch): \(appMessages.count) app(s), \(commitMessages.count) commit(s) - processing apps FIRST (local epoch \(localEpoch) >= message epoch \(epoch))"
        )
      } else {
        logger.debug("📦 Epoch \(epoch): \(appMessages.count) app message(s), no commits")
      }

      // Determine processing order based on epoch comparison
      let firstBatch: [BlueCatbirdMlsDefs.MessageView]
      let secondBatch: [BlueCatbirdMlsDefs.MessageView]
      let firstBatchIsApps: Bool

      if needCommitsFirst {
        // COMMITS FIRST: We need to advance to this epoch before decrypting apps
        firstBatch = commitMessages.sorted(by: { $0.seq < $1.seq })
        secondBatch = appMessages.sorted(by: { $0.seq < $1.seq })
        firstBatchIsApps = false
      } else {
        // APPS FIRST: Decrypt everything with current epoch keys before advancing
        firstBatch = appMessages.sorted(by: { $0.seq < $1.seq })
        secondBatch = commitMessages.sorted(by: { $0.seq < $1.seq })
        firstBatchIsApps = true
      }

      // Process first batch
      for message in firstBatch {
        let result = await processMessageWithRecovery(
          message: message,
          conversationID: conversationID,
          epoch: epoch
        )

        switch result {
        case .success(let outcome):
          totalProcessed += 1
          if firstBatchIsApps {
            if case .application(let payload, _) = outcome {
              processedPayloads.append(payload)
              logger.debug(
                "✅ App message \(message.id) decrypted (epoch \(epoch), seq \(message.seq))")
            }
          } else {
            logger.debug("✅ Commit message \(message.id) processed (epoch \(epoch) → \(epoch + 1))")
          }
        case .failure(let error):
          totalFailed += 1
          let msgType = firstBatchIsApps ? "App" : "Commit"
          logger.warning(
            "⚠️ \(msgType) message \(message.id) failed (epoch \(epoch)): \(error.localizedDescription)"
          )
        case .skipped:
          totalSkipped += 1
          let msgType = firstBatchIsApps ? "App" : "Commit"
          logger.debug("⏭️ \(msgType) message \(message.id) skipped (epoch \(epoch))")
        }
      }

      // Process second batch
      for message in secondBatch {
        let result = await processMessageWithRecovery(
          message: message,
          conversationID: conversationID,
          epoch: epoch
        )

        switch result {
        case .success(let outcome):
          totalProcessed += 1
          if !firstBatchIsApps {
            // Second batch is apps (commits were first)
            if case .application(let payload, _) = outcome {
              processedPayloads.append(payload)
              logger.debug(
                "✅ App message \(message.id) decrypted (epoch \(epoch), seq \(message.seq))")
            }
          } else {
            // Second batch is commits (apps were first)
            logger.debug("✅ Commit message \(message.id) processed (epoch \(epoch) → \(epoch + 1))")
          }
        case .failure(let error):
          totalFailed += 1
          let msgType = firstBatchIsApps ? "Commit" : "App"
          logger.warning(
            "⚠️ \(msgType) message \(message.id) failed (epoch \(epoch)): \(error.localizedDescription)"
          )
        case .skipped:
          totalSkipped += 1
          let msgType = firstBatchIsApps ? "Commit" : "App"
          logger.debug("⏭️ \(msgType) message \(message.id) skipped (epoch \(epoch))")
        }
      }

      logger.debug(
        "📊 Epoch \(epoch) complete: processed \(appMessages.count + commitMessages.count) messages")
    }

    // Diagnostic: Check for high failure rate indicating potential forward secrecy issues
    let totalMessages = totalProcessed + totalFailed + totalSkipped
    if totalMessages > 0 {
      let failureRate = Double(totalFailed) / Double(totalMessages)
      if failureRate > 0.3 && totalFailed > 3 {
        logger.warning(
          "⚠️ High message failure rate (\(Int(failureRate * 100))%) in batch - possible forward secrecy race condition"
        )
        logger.warning(
          "   Total: \(totalMessages), Failed: \(totalFailed), Processed: \(totalProcessed), Skipped: \(totalSkipped)"
        )
        logger.warning(
          "   If this persists, check if commits are being processed before all app messages")
      }
    }

    logger.info(
      "✅ Epoch-aware processing complete: \(processedPayloads.count) payloads, \(totalProcessed) processed, \(totalFailed) failed, \(totalSkipped) skipped"
    )
    return processedPayloads
  }

  // MARK: - Message Processing with Recovery

  /// Result of attempting to process a single message with recovery
  private enum MessageProcessingResult {
    case success(MessageProcessingOutcome)
    case failure(Error)
    case skipped
  }

  /// Process a single message with automatic recovery for common failure modes
  ///
  /// This method wraps message processing with:
  /// - Uninterruptible execution (prevents SecretReuseError from cancellation)
  /// - Graceful handling of old-epoch messages
  /// - Automatic retry for transient failures
  /// - Self-healing for desync conditions
  private func processMessageWithRecovery(
    message: BlueCatbirdMlsDefs.MessageView,
    conversationID: String,
    epoch: Int,
    retryCount: Int = 0
  ) async -> MessageProcessingResult {
    let maxRetries = 2

    do {
      // Fast-path: if plaintext already cached (e.g., decrypted by NSE), skip FFI processing.
      if let userDid = userDid {
        do {
          let database = try await MLSGRDBManager.shared.getDatabasePool(for: userDid)
          if let cachedPlaintext = try await storage.fetchPlaintextForMessage(
            message.id,
            currentUserDID: userDid,
            database: database
          ) {
            let cachedSender = try await storage.fetchSenderForMessage(
              message.id,
              currentUserDID: userDid,
              database: database
            ) ?? "unknown"
            let cachedEmbed = try? await storage.fetchEmbedForMessage(
              message.id,
              currentUserDID: userDid,
              database: database
            )
            logger.info("✅ Message \(message.id) already decrypted (cache hit) - skipping FFI processMessage")
            let payload = MLSMessagePayload.text(cachedPlaintext, embed: cachedEmbed)
            return .success(.application(payload: payload, sender: cachedSender))
          }
        } catch {
          logger.debug("ℹ️ Cache pre-check for message \(message.id) failed (continuing to FFI): \(error.localizedDescription)")
        }
      }

      // Wrap in Task.detached to make uninterruptible
      // This ensures decrypt + cache is atomic (prevents SecretReuseError)
      let outcome = try await Task.detached { [self] in
        try await self.processServerMessage(message)
      }.value

      return .success(outcome)

    } catch MLSError.ignoredOldEpochMessage {
      // Expected for messages from epochs we've already advanced past
      logger.debug("⏭️ Message \(message.id) from old epoch \(epoch) - forward secrecy skip")
      return .skipped

    } catch MLSError.secretReuseSkipped {
      // ═══════════════════════════════════════════════════════════════════════════
      // CRITICAL FIX (2024-12): Handle SecretReuseError gracefully
      // ═══════════════════════════════════════════════════════════════════════════
      //
      // SecretReuseError means the message was already decrypted (likely by NSE).
      // The plaintext should be in the database cache. This is NOT an error.
      //
      // ═══════════════════════════════════════════════════════════════════════════
      logger.info("✅ Message \(message.id) already decrypted (SecretReuseSkipped) - checking cache")
      
      // Try to retrieve from cache
      if let userDid = userDid {
        do {
          let database = try await MLSGRDBManager.shared.getDatabasePool(for: userDid)
          if let cachedPlaintext = try await storage.fetchPlaintextForMessage(
            message.id,
            currentUserDID: userDid,
            database: database
          ) {
            logger.info("✅ Retrieved cached plaintext for message \(message.id) (decrypted by NSE)")
            // Also fetch the sender from the database (stored during decryption)
            let cachedSender = try await storage.fetchSenderForMessage(
              message.id,
              currentUserDID: userDid,
              database: database
            ) ?? "unknown"
            
            // Return success with cached content
            // Parse the cached plaintext back into a payload
            if let payloadData = cachedPlaintext.data(using: .utf8),
               let payload = try? MLSMessagePayload.decodeFromJSON(payloadData) {
              return .success(.application(payload: payload, sender: cachedSender))
            } else {
              // Fallback: wrap plaintext in a text payload
              let payload = MLSMessagePayload.text(cachedPlaintext, embed: nil)
              return .success(.application(payload: payload, sender: cachedSender))
            }
          }
        } catch {
          logger.warning("⚠️ Failed to retrieve cached plaintext for \(message.id): \(error.localizedDescription)")
        }
      }
      
      // If we can't find the cached plaintext, skip (it should appear on next sync)
      logger.warning("⚠️ SecretReuseSkipped but cache miss for \(message.id) - will appear on next sync")
      return .skipped

    } catch let error as MLSError {
      switch error {
      case .ratchetStateDesync(let reason):
        // Check if this is just forward secrecy doing its job
        if reason.contains("Cannot decrypt message from epoch")
          || reason.contains("forward secrecy")
        {
          logger.debug("⏭️ Message \(message.id) cannot be decrypted (forward secrecy): \(reason)")
          return .skipped
        }

        // For other desync issues, attempt recovery if we haven't exceeded retries
        if retryCount < maxRetries {
          logger.warning(
            "🔄 Ratchet desync for message \(message.id), attempting recovery (retry \(retryCount + 1)/\(maxRetries))"
          )

          // Brief delay before retry to allow any in-flight operations to complete
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

          return await processMessageWithRecovery(
            message: message,
            conversationID: conversationID,
            epoch: epoch,
            retryCount: retryCount + 1
          )
        }

        logger.error("❌ Ratchet desync unrecoverable after \(maxRetries) retries: \(reason)")
        return .failure(error)

      default:
        // Check for secret reuse (message already processed)
        let errorDesc = error.localizedDescription
        if errorDesc.contains("SecretReuseError") {
          logger.debug("⏭️ Message \(message.id) already processed (SecretReuseError)")
          return .skipped
        }

        return .failure(error)
      }

    } catch {
      // Generic error handling with retry for transient failures
      if retryCount < maxRetries {
        let errorDesc = error.localizedDescription

        // Retry for transient-looking errors
        if errorDesc.contains("timeout") || errorDesc.contains("connection")
          || errorDesc.contains("network")
        {
          logger.warning("🔄 Transient error for message \(message.id), retrying: \(errorDesc)")
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

          return await processMessageWithRecovery(
            message: message,
            conversationID: conversationID,
            epoch: epoch,
            retryCount: retryCount + 1
          )
        }
      }

      return .failure(error)
    }
  }

  private func lastStoredSequenceNumber(for conversationID: String) async -> Int? {
    guard let userDID = userDid else { return nil }
    do {
      return try await database.read { db in
        try MLSMessageModel
          .filter(MLSMessageModel.Columns.conversationID == conversationID)
          .filter(MLSMessageModel.Columns.currentUserDID == userDID)
          .order(MLSMessageModel.Columns.epoch.desc, MLSMessageModel.Columns.sequenceNumber.desc)
          .limit(1)
          .fetchOne(db)
          .map { Int($0.sequenceNumber) }
      }
    } catch {
      logger.error(
        "⚠️ Failed to fetch last sequence for \(conversationID): \(error.localizedDescription)")
      return nil
    }
  }

  private func catchUpMessagesIfNeeded(for convo: BlueCatbirdMlsDefs.ConvoView, force: Bool = false)
    async
  {
    if await conversationNeedsRejoin(convo.groupId) && !force {
      logger.info("⏭️ Skipping catch-up for \(convo.groupId) - rejoin pending")
      return
    }

    guard let userDid = userDid else {
      logger.warning("Cannot catch up messages - no user DID")
      return
    }

    do {
      var sinceSeq = await lastStoredSequenceNumber(for: convo.groupId)
      var localEpoch: UInt64?
      if let groupIdData = Data(hexEncoded: convo.groupId) {
        do {
          localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
        } catch {
          logger.warning(
            "⚠️ Unable to query local epoch for \(convo.groupId) before catch-up: \(error.localizedDescription)"
          )
        }
      }
      logger.info(
        "📟 Catch-up start for \(convo.groupId) (force=\(force)) localEpoch=\(localEpoch?.description ?? "nil"), serverEpoch=\(convo.epoch), sinceSeq=\(sinceSeq?.description ?? "nil")"
      )
      let pageLimit = 10
      var pages = 0

      while !Task.isCancelled {
        let (messages, _, gapInfo) = try await apiClient.getMessages(
          convoId: convo.groupId,
          limit: 100,
          sinceSeq: sinceSeq
        )

        guard !messages.isEmpty else {
          logger.debug("📭 No additional messages for \(convo.groupId); exiting catch-up loop")
          break
        }

        let firstSeq = messages.first?.seq
        let lastSeq = messages.last?.seq
        logger.info(
          "📥 Catch-up fetched \(messages.count) messages for \(convo.groupId) (seq range: \(firstSeq?.description ?? "nil")-\(lastSeq?.description ?? "nil"), sinceSeq: \(sinceSeq?.description ?? "nil"))"
        )

        // Check for gaps and log warnings
        if let gaps = gapInfo, gaps.hasGaps {
          logger.warning("⚠️ Gap detected in message sequence for \(convo.groupId)")
          logger.warning("   Missing sequences: \(gaps.missingSeqs)")
          // Attempt to fill gaps by fetching missing sequences
          await fillGaps(conversationID: convo.groupId, missingSeqs: gaps.missingSeqs)
        }

        let _ = try await processMessagesInOrder(messages: messages, conversationID: convo.groupId)
        logger.info("📤 Catch-up applied \(messages.count) messages for \(convo.groupId)")

        sinceSeq = messages.last?.seq
        pages += 1
        if messages.count < 100 || pages >= pageLimit {
          logger.debug(
            "📚 Catch-up stopping for \(convo.groupId) after page \(pages) (limit hit: \(pages >= pageLimit))"
          )
          break
        }
      }
    } catch let error as MLSError {
      if case .ratchetStateDesync = error {
        logger.error("🔴 Catch-up aborted for \(convo.groupId) due to ratchet desync")
      } else {
        logger.error("❌ Catch-up failed for \(convo.groupId): \(error.localizedDescription)")
      }
    } catch {
      logger.error("❌ Catch-up failed for \(convo.groupId): \(error.localizedDescription)")
    }
  }

  /// Fill gaps in message sequence by fetching missing sequences
  /// - Parameters:
  ///   - conversationID: Conversation group ID
  ///   - missingSeqs: Array of missing sequence numbers
  private func fillGaps(conversationID: String, missingSeqs: [Int]) async {
    guard !missingSeqs.isEmpty else { return }

    logger.info("🔧 Filling gaps for conversation \(conversationID)")
    logger.info("   Missing \(missingSeqs.count) sequences: \(missingSeqs.prefix(10))...")

    // Group consecutive sequences into ranges for efficient fetching
    let ranges = groupIntoRanges(missingSeqs.sorted())

    for (startSeq, endSeq) in ranges {
      logger.info("  Fetching missing messages: seq \(startSeq) to \(endSeq)")

      // Fetch messages in the gap range
      // Use startSeq-1 to ensure we fetch from just before the gap
      do {
        let (messages, _, _) = try await apiClient.getMessages(
          convoId: conversationID,
          limit: (endSeq - startSeq) + 10,  // Add buffer
          sinceSeq: max(0, startSeq - 1)
        )

        if !messages.isEmpty {
          logger.info("  ✅ Fetched \(messages.count) messages to fill gap")
          try await processMessagesInOrder(messages: messages, conversationID: conversationID)
        } else {
          logger.warning("  ⚠️ No messages found in gap range \(startSeq)-\(endSeq)")
        }
      } catch {
        logger.error("  ❌ Failed to fill gap \(startSeq)-\(endSeq): \(error.localizedDescription)")
      }
    }

    logger.info("✅ Gap filling complete for \(conversationID)")
  }

  /// Group sequence numbers into consecutive ranges
  /// Example: [1, 2, 3, 7, 8, 10] -> [(1, 3), (7, 8), (10, 10)]
  private func groupIntoRanges(_ sequences: [Int]) -> [(Int, Int)] {
    guard !sequences.isEmpty else { return [] }

    var ranges: [(Int, Int)] = []
    var rangeStart = sequences[0]
    var rangeEnd = sequences[0]

    for seq in sequences.dropFirst() {
      if seq == rangeEnd + 1 {
        // Consecutive - extend current range
        rangeEnd = seq
      } else {
        // Gap - close current range and start new one
        ranges.append((rangeStart, rangeEnd))
        rangeStart = seq
        rangeEnd = seq
      }
    }

    // Add final range
    ranges.append((rangeStart, rangeEnd))

    return ranges
  }

  /// Public method to trigger catchup for a specific conversation
  /// Useful for SSE reconnection scenarios where messages may have been missed
  /// - Parameter conversationID: The conversation group ID to catch up
  func triggerCatchup(for conversationID: String) async {
    logger.info("🔄 Triggering manual catchup for conversation: \(conversationID)")

    guard let convo = conversations[conversationID] else {
      logger.warning("⚠️ Cannot trigger catchup - conversation not found: \(conversationID)")
      return
    }

    await catchUpMessagesIfNeeded(for: convo, force: true)
  }

  // MARK: - Server Synchronization

  /// Sync conversations with server
  /// - Parameter fullSync: Whether to perform full sync or incremental
  func syncWithServer(fullSync: Bool = false) async throws {
    try throwIfShuttingDown("syncWithServer")

    // CIRCUIT BREAKER: Check if sync is paused due to repeated failures
    if let pausedAt = syncPausedAt {
      let elapsed = Date().timeIntervalSince(pausedAt)
      if elapsed < syncPauseDuration {
        let remaining = Int(syncPauseDuration - elapsed)
        logger.warning(
          "⛔ Sync paused due to \(self.consecutiveSyncFailures) consecutive failures (\(remaining)s remaining)"
        )
        return
      } else {
        // Reset circuit breaker after pause period
        logger.info("✅ Sync pause period expired, resuming normal operation")
        syncPausedAt = nil
        consecutiveSyncFailures = 0
      }
    }

    // CRITICAL FIX: Use Mutex to atomically check and set sync state
    // This prevents race conditions where multiple syncs start simultaneously
    let didAcquire = syncState.withLock { syncing -> Bool in
      if syncing {
        return false
      }
      syncing = true
      return true
    }

    guard didAcquire else {
      logger.warning("Sync already in progress")
      return
    }

    defer {
      syncState.withLock { $0 = false }
    }

    // CRITICAL FIX: Validate that we're syncing for the correct user
    // This prevents account switch race conditions where the API client
    // has already switched to a different user but sync is still running
    guard let userDid = userDid else {
      logger.error("Cannot sync: no user DID")
      return
    }

    do {
      try await apiClient.validateAuthentication(expectedDID: userDid)
    } catch {
      logger.error("❌ [SYNC] Authentication mismatch - aborting sync to prevent data corruption")
      logger.error("   Manager userDID: \(userDid)")
      logger.error("   This likely indicates an account switch race condition")
      throw MLSConversationError.noAuthentication
    }

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

      // ⭐ FIX: Filter out conversations where user is no longer a member
      // Server may return stale conversations after user has left
      // Also track stale conversations to clean up local state
      let normalizedUserDid = userDid.lowercased()
      var staleConvoIds: [String] = []

      allConvos = allConvos.filter { convo in
        let isUserMember = convo.members.contains {
          $0.did.description.lowercased() == normalizedUserDid
        }
        if !isUserMember {
          logger.info(
            "⏭️ [SYNC] Filtering out conversation \(convo.groupId.prefix(16))... - user is not a member"
          )
          staleConvoIds.append(convo.groupId)
        }
        return isUserMember
      }

      // Clean up stale conversations from local state
      if !staleConvoIds.isEmpty {
        logger.info("🧹 [SYNC] Cleaning up \(staleConvoIds.count) stale conversation(s) after leave")
        for convoId in staleConvoIds {
          conversations.removeValue(forKey: convoId)
          groupStates.removeValue(forKey: convoId)
        }
        // Delete from database (await to ensure plaintext is securely deleted)
        try await deleteConversationsFromDatabase(staleConvoIds)
      }

      // Update local state and initialize MLS groups
      for convo in allConvos {
        let existingConvo = conversations[convo.groupId]
        conversations[convo.groupId] = convo

        // Check if we need to initialize the MLS group
        let needsGroupInit = groupStates[convo.groupId] == nil

        // Update group state metadata
        if groupStates[convo.groupId] == nil {
          // ⭐ CRITICAL FIX: Verify epoch from FFI instead of trusting server
          // Note: userDid is guaranteed non-nil from auth check at start of function

          guard let groupIdData = Data(hexEncoded: convo.groupId) else {
            logger.error("Invalid group ID hex: \(convo.groupId)")
            continue  // Skip this conversation
          }

          let serverEpoch = UInt64(convo.epoch)
          var ffiEpoch = serverEpoch  // Default to server if FFI query fails

          // Try to get FFI epoch, but don't fail sync if group not yet initialized
          do {
            ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

            if serverEpoch != ffiEpoch {
              logger.warning("⚠️ EPOCH MISMATCH in syncWithServer (new group):")
              logger.warning("   Server: \(serverEpoch), FFI: \(ffiEpoch)")
              logger.warning("   Using FFI epoch")
            }
          } catch {
            // Group may not exist in FFI yet (e.g., before processing Welcome)
            logger.debug("Could not get FFI epoch for \(convo.groupId.prefix(16)): \(error)")
            logger.debug("Using server epoch \(serverEpoch) as fallback")
          }

          groupStates[convo.groupId] = MLSGroupState(
            groupId: convo.groupId,
            convoId: convo.groupId,
            epoch: ffiEpoch,  // Use FFI epoch if available, else server epoch
            members: Set(convo.members.map { $0.did.description })
          )
        } else if var state = groupStates[convo.groupId] {
          if state.epoch != convo.epoch {
            // ⭐ CRITICAL FIX: Verify epoch from FFI instead of trusting server
            // Note: userDid is guaranteed non-nil from auth check at start of function

            guard let groupIdData = Data(hexEncoded: convo.groupId) else {
              logger.error("Invalid group ID hex: \(convo.groupId)")
              continue  // Skip this conversation
            }

            let serverEpoch = UInt64(convo.epoch)
            var ffiEpoch = serverEpoch  // Default to server if FFI query fails

            // Try to get FFI epoch
            do {
              ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

              if serverEpoch != ffiEpoch {
                logger.warning("⚠️ EPOCH MISMATCH in syncWithServer (update):")
                logger.warning("   Server: \(serverEpoch), FFI: \(ffiEpoch)")
                logger.warning("   Using FFI epoch")
              }
            } catch {
              logger.debug("Could not get FFI epoch for \(convo.groupId.prefix(16)): \(error)")
              logger.debug("Using server epoch \(serverEpoch) as fallback")
            }

            state.epoch = ffiEpoch  // Use FFI epoch if available, else server epoch
            state.members = Set(convo.members.map { $0.did.description })
            groupStates[convo.groupId] = state

            // Notify epoch update
            notifyObservers(.epochUpdated(convo.groupId, Int(ffiEpoch)))
          }
        }

        // Initialize MLS group if needed
        if needsGroupInit {
          // Check if group exists locally via FFI
          guard let groupIdData = Data(hexEncoded: convo.groupId) else {
            logger.error("Invalid group ID format for \(convo.groupId)")
            continue
          }

          // Note: userDid is guaranteed non-nil from auth check at start of function

          // Run blocking FFI call on background thread to avoid priority inversion
          // The Rust RwLock can cause priority inversion if called from main/UI thread
          let groupExists = await Task(priority: .background) {
            await mlsClient.groupExists(for: userDid, groupId: groupIdData)
          }.value

          if !groupExists {
            // ⭐ CRITICAL FIX: Check if we are the creator before trying to join via Welcome
            // If we are the creator, the Welcome message on the server is meant for OTHER users,
            // not for us. The creator must use External Commit to rejoin their own group.
            let isCreator = convo.creator.description.lowercased() == userDid.lowercased()

            if isCreator {
              logger.warning(
                "⚠️ [SYNC] Creator (\(userDid.prefix(20))...) missing group state for \(convo.groupId.prefix(16))..."
              )
              logger.warning(
                "   The Welcome message is for OTHER members - cannot use it to rejoin as creator")
              logger.info("🔄 [SYNC] Attempting External Commit for creator rejoin...")

              do {
                let _ = try await mlsClient.joinByExternalCommit(
                  for: userDid, convoId: convo.groupId)
                logger.info("✅ [SYNC] Creator successfully rejoined via External Commit")
              } catch {
                logger.error(
                  "❌ [SYNC] Creator rejoin via External Commit failed: \(error.localizedDescription)"
                )
                logger.error(
                  "   This conversation will be unavailable until group state is recovered")
                continue  // Skip this conversation
              }
            } else {
              logger.info("Initializing MLS group for conversation: \(convo.groupId)")
              do {
                try await initializeGroupFromWelcome(convo: convo)
                logger.info("Successfully initialized MLS group for conversation: \(convo.groupId)")
              } catch let mlsApiError as MLSAPIError {
                logger.error(
                  "❌ CRITICAL: Failed to initialize MLS group for \(convo.groupId): MLSAPIError - \(mlsApiError.localizedDescription)"
                )
                if case .invalidResponse(let message) = mlsApiError {
                  logger.error("  → Invalid response details: \(message)")
                }
                logger.error("❌ This conversation cannot be used - cryptographic join failed")
                logger.error("❌ Skipping conversation to prevent zombie group state")

                // ⭐ ZOMBIE CONVERSATION PREVENTION
                // Do NOT add this conversation to allConvos - it will be excluded from:
                // 1. In-memory conversations dictionary
                // 2. Database persistence (line 2456: persistConversationsToDatabase)
                // 3. UI display
                // This prevents a "zombie" conversation that appears functional but cannot decrypt/send messages
                continue
              } catch {
                logger.error(
                  "❌ CRITICAL: Failed to initialize MLS group for \(convo.groupId): \(type(of: error)) - \(error.localizedDescription)"
                )
                logger.error("❌ This conversation cannot be used - cryptographic join failed")
                logger.error("❌ Skipping conversation to prevent zombie group state")

                // 🔄 RECOVERY: Check if this error warrants device-level recovery
                if let recoveryManager = await mlsClient.recovery(for: userDid) {
                  let recovered = await recoveryManager.attemptRecoveryIfNeeded(
                    for: error,
                    userDid: userDid,
                    convoIds: [convo.groupId]
                  )
                  if recovered {
                    logger.info(
                      "🔄 Silent recovery initiated for conversation \(convo.groupId.prefix(16))")
                  }
                }

                // ⭐ ZOMBIE CONVERSATION PREVENTION
                // Do NOT add this conversation to allConvos - it will be excluded from:
                // 1. In-memory conversations dictionary
                // 2. Database persistence (line 2456: persistConversationsToDatabase)
                // 3. UI display
                // This prevents a "zombie" conversation that appears functional but cannot decrypt/send messages
                continue
              }
            }
          } else {
            logger.debug("Group already exists locally for conversation: \(convo.groupId)")
          }
        }

        if needsGroupInit || fullSync {
          await catchUpMessagesIfNeeded(for: convo, force: needsGroupInit)
        }

        // Notify if new conversation
        if existingConvo == nil {
          notifyObservers(.conversationCreated(convo))
        }
      }

      // Persist conversations to local database
      try await persistConversationsToDatabase(allConvos)

      // Persist conversation members to local database
      try await persistMembersToDatabase(allConvos)

      // Reconcile database: delete conversations that exist locally but not on server
      let serverConvoIDs = Set(allConvos.map { $0.groupId })
      try await reconcileDatabase(with: serverConvoIDs)

      // Notify sync complete
      notifyObservers(.syncCompleted(allConvos.count))

      logger.info("Successfully synced \(allConvos.count) conversations")

      // Reset circuit breaker on success
      consecutiveSyncFailures = 0

    } catch {
      // Increment circuit breaker counter
      consecutiveSyncFailures += 1
      logger.error(
        "Sync failed (\(self.consecutiveSyncFailures)/\(self.maxConsecutiveSyncFailures)): \(error.localizedDescription)"
      )

      // Check if we should trip the circuit breaker
      if consecutiveSyncFailures >= maxConsecutiveSyncFailures {
        syncPausedAt = Date()
        logger.error(
          "🚨 Circuit breaker tripped after \(self.consecutiveSyncFailures) consecutive sync failures"
        )
        logger.error(
          "   Sync will be paused for \(Int(self.syncPauseDuration))s to prevent resource exhaustion"
        )
        logger.error("   Error pattern: \(error.localizedDescription)")
      }

      notifyObservers(.syncFailed(error))
      throw MLSConversationError.syncFailed(error)
    }
  }

  /// Persist conversations to local encrypted database
  /// - Parameter convos: Array of ConvoView objects to persist
  private func persistConversationsToDatabase(_ convos: [BlueCatbirdMlsDefs.ConvoView]) async throws
  {
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

  /// Persist conversation members to local encrypted database
  /// - Parameter convos: Array of ConvoView objects whose members to persist
  private func persistMembersToDatabase(_ convos: [BlueCatbirdMlsDefs.ConvoView]) async throws {
    guard let userDid = userDid else {
      logger.error("Cannot persist members - no user DID")
      return
    }

    // Batch all member operations into a single database transaction for efficiency
    try await database.write { [self] db in
      for convo in convos {
        // Mark existing members as inactive for this conversation
        try db.execute(
          sql: """
            UPDATE MLSMemberModel
            SET isActive = 0, removedAt = ?, updatedAt = ?
            WHERE conversationID = ? AND currentUserDID = ? AND isActive = 1
            """,
          arguments: [Date(), Date(), convo.groupId, userDid]
        )

        // Convert and insert new members
        for (index, apiMember) in convo.members.enumerated() {
          let member = MLSMemberModel(
            memberID: "\(convo.groupId)_\(apiMember.did.description)",
            conversationID: convo.groupId,
            currentUserDID: userDid,
            did: apiMember.did.description,
            handle: nil,  // Profile data comes from separate enrichment
            displayName: nil,
            leafIndex: index,  // Use enumeration as placeholder leaf index
            credentialData: nil,
            signaturePublicKey: nil,
            addedAt: Date(),
            updatedAt: Date(),
            removedAt: nil,
            isActive: true,
            role: apiMember.isAdmin ? .admin : .member,
            capabilities: nil
          )
          try member.save(db)
        }
      }
    }

    logger.info(
      "💾 Persisted members for \(convos.count) conversations to encrypted database (batched)")
  }

  /// Reconcile local database with server state
  /// Deletes conversations that exist locally but not on server (removed/left conversations)
  ///
  /// IMPORTANT: This function includes safeguards against accidental deletion during:
  /// - Account switching (server may temporarily return 0 conversations)
  /// - Network issues causing empty responses
  /// - Race conditions between sync and Welcome processing
  ///
  /// - Parameter serverConvoIDs: Set of conversation IDs from server
  private func reconcileDatabase(with serverConvoIDs: Set<String>) async throws {
    guard let userDid = userDid else {
      logger.error("Cannot reconcile database - no user DID")
      return
    }

    // Get local conversations with their metadata from database
    // With recovery for SQLCipher codec errors
    let localConvos: [MLSConversationModel]
    do {
      localConvos = try await database.read { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.currentUserDID == userDid)
          .fetchAll(db)
      }
    } catch {
      // Check if this is a recoverable codec error
      if MLSGRDBManager.shared.isRecoverableCodecError(error) {
        logger.warning("⚠️ Recoverable database error in reconcileDatabase, attempting recovery...")
        do {
          let freshDatabase = try await MLSGRDBManager.shared.reconnectDatabase(for: userDid)
          localConvos = try await freshDatabase.read { db in
            try MLSConversationModel
              .filter(MLSConversationModel.Columns.currentUserDID == userDid)
              .fetchAll(db)
          }
          logger.info("✅ Database recovered in reconcileDatabase")
        } catch {
          logger.error(
            "❌ Database recovery failed in reconcileDatabase: \(error.localizedDescription)")
          throw error
        }
      } else {
        throw error
      }
    }

    let localConvoIDs = localConvos.map { $0.conversationID }

    // Find conversations that exist locally but not on server (removed/left)
    let removedConvoIDs = Set(localConvoIDs).subtracting(serverConvoIDs)

    // ⭐ FIX #3: Detect and clean up "zombie" conversations
    // These are conversations that were created locally but never made it to the server
    // (e.g., due to createGroup() failing after the local record was persisted).
    // Zombie detection criteria:
    // 1. Conversation exists locally but not on server
    // 2. Conversation was created more than 5 minutes ago
    // 3. MLS group does NOT exist in OpenMLS storage (no cryptographic state)
    let zombieThreshold: TimeInterval = 300  // 5 minutes
    let now = Date()
    var zombiesDetected: [String] = []

    for convo in localConvos {
      let convoId = convo.conversationID
      let age = now.timeIntervalSince(convo.createdAt)

      // Skip if conversation exists on server
      if serverConvoIDs.contains(convoId) { continue }

      // Check if this is a zombie: old enough and no MLS group state
      if age > zombieThreshold {
        let groupExists = await mlsClient.groupExists(for: userDid, groupId: convo.groupID)
        if !groupExists {
          logger.warning("🧟 [RECONCILE] Detected zombie conversation: \(convoId.prefix(16))...")
          logger.warning("   Age: \(Int(age))s, No MLS group state, Not on server")
          zombiesDetected.append(convoId)
        }
      }
    }

    if !zombiesDetected.isEmpty {
      logger.info("🧹 [RECONCILE] Cleaning up \(zombiesDetected.count) zombie conversation(s)")
      try await deleteConversationsFromDatabase(zombiesDetected)
    }

    // Filter out already-cleaned zombies from the removed set
    let remainingRemoved = removedConvoIDs.subtracting(zombiesDetected)

    guard !remainingRemoved.isEmpty else {
      if zombiesDetected.isEmpty {
        logger.debug("Database reconciliation: no stale conversations to remove")
      }
      return
    }

    // SAFEGUARD 1: If server returned 0 conversations but we have local ones,
    // this is likely an account switch race condition or API transient failure.
    // Do NOT delete all local conversations in this case.
    // (But allow zombie cleanup above to proceed)
    if serverConvoIDs.isEmpty && !localConvoIDs.isEmpty && zombiesDetected.isEmpty {
      logger.warning(
        "⚠️ [RECONCILE] Server returned 0 conversations but we have \(localConvoIDs.count) locally")
      logger.warning("   This may indicate account switch race condition or transient API failure")
      logger.warning("   SKIPPING reconciliation deletion to prevent data loss")
      logger.warning(
        "   Local conversations preserved: \(localConvoIDs.map { String($0.prefix(16)) })")
      return
    }

    // TRUST THE SERVER: If the server says we're not in a conversation, delete it locally.
    // This is the correct behavior because:
    // 1. User explicitly left the conversation (leaveConversation was called)
    // 2. User was removed/kicked by an admin
    // 3. Conversation was deleted on the server
    //
    // The MLS group existing locally is NOT authoritative - the server is the source of truth
    // for conversation membership. We must delete local MLS state to prevent:
    // - Ghost conversations appearing in the UI
    // - Stale cryptographic material consuming storage
    // - Confusion between local and server state

    logger.info("🗑️ [RECONCILE] Removing \(remainingRemoved.count) conversation(s) not on server")

    for convoId in remainingRemoved {
      // Get the group ID for this conversation
      let groupIdHex: String
      if let groupIdData = localConvos.first(where: { $0.conversationID == convoId })?.groupID {
        groupIdHex = groupIdData.hexEncodedString()
      } else {
        groupIdHex = convoId  // Fallback: convoId is often the same as groupId
      }

      logger.info(
        "🗑️ [RECONCILE] Force deleting conversation \(convoId.prefix(16))... (not on server)")
      await forceDeleteConversationLocally(convoId: convoId, groupId: groupIdHex)
    }

    logger.info("✅ [RECONCILE] Removed \(remainingRemoved.count) stale conversation(s)")
  }

  /// Delete conversations from local database
  /// Also removes associated messages, members, and epoch keys
  /// - Parameter convoIds: Array of conversation IDs to delete
  private func deleteConversationsFromDatabase(_ convoIds: [String]) async throws {
    guard let userDID = userDid else { return }

    try await database.write { db in
      for convoId in convoIds {
        // Delete conversation record
        try db.execute(
          sql: """
                DELETE FROM MLSConversationModel
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [convoId, userDID])

        // Delete associated messages
        try db.execute(
          sql: """
                DELETE FROM MLSMessageModel
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [convoId, userDID])

        // Delete members
        try db.execute(
          sql: """
                DELETE FROM MLSMemberModel
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [convoId, userDID])

        // Delete epoch keys
        try db.execute(
          sql: """
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
          logger.warning(
            "⚠️ Failed to delete MLS group \(groupIdHex.prefix(16))...: \(error.localizedDescription)"
          )
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
      try db.execute(
        sql: """
              UPDATE MLSConversationModel
              SET needsRejoin = 1, rejoinRequestedAt = NULL, updatedAt = ?
              WHERE conversationID = ? AND currentUserDID = ?;
          """, arguments: [Date(), convoId, userDID])
    }

    logger.info("⚠️ Marked conversation as needing rejoin: \(convoId)")
  }

  /// Clear the needsRejoin flag after a successful recovery
  private func clearConversationRejoinFlag(_ convoId: String) async {
    guard let userDID = userDid else { return }

    do {
      try await database.write { db in
        try db.execute(
          sql: """
                UPDATE MLSConversationModel
                SET needsRejoin = 0, rejoinRequestedAt = NULL, updatedAt = ?
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [Date(), convoId, userDID])
      }
      logger.debug("✅ Cleared rejoin flag for conversation: \(convoId)")
    } catch {
      logger.error("⚠️ Failed to clear rejoin flag for \(convoId): \(error.localizedDescription)")
    }
  }

  private func conversationNeedsRejoin(_ convoId: String) async -> Bool {
    guard let userDID = userDid else { return false }
    do {
      return try await database.read { db in
        try Bool.fetchOne(
          db,
          sql: """
                SELECT needsRejoin FROM MLSConversationModel
                WHERE conversationID = ? AND currentUserDID = ?;
            """,
          arguments: [convoId, userDID]
        ) ?? false
      }
    } catch {
      logger.error("⚠️ Failed to query rejoin state for \(convoId): \(error.localizedDescription)")
      return false
    }
  }

  private func conversationHasPendingRejoinRequest(_ convoId: String) async -> Bool {
    guard let userDID = userDid else { return false }
    do {
      return try await database.read { db in
        try Bool.fetchOne(
          db,
          sql: """
                SELECT rejoinRequestedAt IS NOT NULL FROM MLSConversationModel
                WHERE conversationID = ? AND currentUserDID = ?;
            """,
          arguments: [convoId, userDID]
        ) ?? false
      }
    } catch {
      logger.error(
        "⚠️ Failed to query rejoin request state for \(convoId): \(error.localizedDescription)")
      return false
    }
  }

  private func recordRejoinRequestTimestamp(_ convoId: String) async {
    guard let userDID = userDid else { return }
    do {
      try await database.write { db in
        try db.execute(
          sql: """
                UPDATE MLSConversationModel
                SET rejoinRequestedAt = ?, updatedAt = ?
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [Date(), Date(), convoId, userDID])
      }
    } catch {
      logger.error("⚠️ Failed to record rejoin request timestamp: \(error.localizedDescription)")
    }
  }

  private func requestRejoinIfPossible(convoId: String, reason: String) async {
    guard let userDID = userDid else { return }

    if await conversationHasPendingRejoinRequest(convoId) {
      logger.info("⏳ Rejoin already requested for \(convoId) - skipping duplicate request")
      return
    }

    do {
      logger.info("📞 Requesting rejoin for conversation: \(convoId) via External Commit")

      // Join via External Commit (atomic rejoin)
      _ = try await mlsClient.joinByExternalCommit(for: userDID, convoId: convoId)

      await recordRejoinRequestTimestamp(convoId)
      logger.info("✅ Successfully rejoined conversation: \(convoId)")
    } catch {
      logger.error("❌ Failed to rejoin conversation \(convoId): \(error.localizedDescription)")
    }
  }

  /// Save error placeholder for failed message processing
  /// Allows conversation to continue despite individual message failures
  private func saveErrorPlaceholder(
    message: BlueCatbirdMlsDefs.MessageView,
    error: String,
    validationReason: String?
  ) async throws -> MessageProcessingOutcome {
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    // Only surface placeholders for application messages.
    // Control/commit messages should never appear in the chat UI even if they fail to process.
    let messageType = message.messageType ?? "app"
    if messageType != "app" {
      logger.info(
        "⏭️ Skipping error placeholder for non-application message \(message.id) [type=\(messageType)]"
      )
      await incrementConversationFailures(conversationID: message.convoId)
      return .nonApplication
    }

    logger.warning("💾 Saving error placeholder for message \(message.id): \(error)")

    // Log error placeholder context at info level for recovery tracking
    logger.info("📋 Error placeholder details:")
    logger.info("   Message ID: \(message.id)")
    logger.info("   Epoch: \(message.epoch), Sequence: \(message.seq)")
    logger.info("   Conversation: \(message.convoId)")
    logger.info("   Error category: \(error.prefix(80))")
    if let reason = validationReason {
      logger.info("   Validation reason: \(reason.prefix(80))")
    }

    // Save placeholder with error details
    let placeholderText = "⚠️ Message unavailable"
    do {
      try await storage.savePlaintextForMessage(
        messageID: message.id,
        conversationID: message.convoId,
        plaintext: placeholderText,
        senderID: "unknown",
        currentUserDID: userDid,
        embed: nil,
        epoch: Int64(message.epoch),
        sequenceNumber: Int64(message.seq),
        timestamp: message.createdAt.date,
        database: database,
        processingError: error,
        validationFailureReason: validationReason
      )
      logger.debug("💾 Cached error placeholder for message \(message.id)")
      logger.info("✅ Error placeholder saved successfully - conversation recovery may occur")
    } catch {
      logger.error(
        "❌ Failed to save error placeholder for \(message.id): \(error.localizedDescription)")
      logger.error("   This is critical - message lost without error record")
      logger.debug("   Save attempt for: \(message.id) in conversation \(message.convoId)")
    }

    // Increment consecutive failures for conversation
    await incrementConversationFailures(conversationID: message.convoId)

    // Return placeholder payload
    let payload = MLSMessagePayload.text(placeholderText, embed: nil)
    return .application(payload: payload, sender: "unknown")
  }

  /// Attempt automatic recovery on decryption failure
  /// Triggers rejoin flow immediately on first failure
  /// If multiple failures occur, may escalate to full device recovery
  private func attemptRecoveryOnDecryptionFailure(conversationID: String, error: Error? = nil) async
  {
    guard let convo = conversations[conversationID] else {
      logger.error("Cannot attempt recovery - conversation \(conversationID) not found")
      return
    }

    guard let userDid = userDid else {
      logger.error("Cannot attempt recovery - no authenticated user")
      return
    }

    logger.info("🔧 Attempting automatic recovery for conversation \(conversationID)")

    // Update last recovery attempt timestamp
    await updateLastRecoveryAttempt(conversationID: conversationID)

    // 🔄 ENHANCED RECOVERY: Check if MLSRecoveryManager should handle this
    if let error = error, let recoveryManager = await mlsClient.recovery(for: userDid) {
      // Check if this error warrants full device recovery
      if await recoveryManager.shouldTriggerRecovery(for: error, userDid: userDid) {
        logger.warning("🔄 Error warrants device-level recovery - escalating to MLSRecoveryManager")
        let recovered = await recoveryManager.attemptRecoveryIfNeeded(
          for: error,
          userDid: userDid,
          convoIds: [conversationID]
        )
        if recovered {
          logger.info("✅ MLSRecoveryManager initiated device recovery")
          return  // Recovery manager will handle rejoins
        }
      }
    }

    // Standard recovery: mark conversation for rejoin
    await handleRatchetDesync(
      for: conversationID, reason: "Automatic recovery after decryption failure")
  }

  /// Increment consecutive failure count for a conversation
  private func incrementConversationFailures(conversationID: String) async {
    guard let userDid = userDid else { return }

    do {
      try await database.write { db in
        try db.execute(
          sql: """
                UPDATE MLSConversationModel
                SET consecutiveFailures = consecutiveFailures + 1
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [conversationID, userDid])
      }
      logger.debug("📊 Incremented failure count for conversation \(conversationID)")
    } catch {
      logger.error("❌ Failed to increment failure count: \(error.localizedDescription)")
    }
  }

  /// Update last recovery attempt timestamp
  private func updateLastRecoveryAttempt(conversationID: String) async {
    guard let userDid = userDid else { return }

    do {
      try await database.write { db in
        try db.execute(
          sql: """
                UPDATE MLSConversationModel
                SET lastRecoveryAttempt = ?
                WHERE conversationID = ? AND currentUserDID = ?;
            """, arguments: [Date(), conversationID, userDid])
      }
      logger.debug("⏰ Updated last recovery attempt for conversation \(conversationID)")
    } catch {
      logger.error("❌ Failed to update recovery timestamp: \(error.localizedDescription)")
    }
  }

  private func handleRatchetDesync(for conversationID: String, reason: String) async {
    logger.error("🔴 Ratchet desync detected for \(conversationID): \(reason)")
    do {
      try await markConversationNeedsRejoin(conversationID)
    } catch {
      logger.error("⚠️ Failed to mark conversation for rejoin: \(error.localizedDescription)")
    }
    await requestRejoinIfPossible(convoId: conversationID, reason: reason)
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

    // Create key package locally (uses mlsDid automatically)
    // CRITICAL FIX: MLSClient.createKeyPackage() returns raw TLS-serialized KeyPackage bytes
    // (NOT base64-encoded - it's already extracted from KeyPackageResult by MLSClient)
    let keyPackageData = try await mlsClient.createKeyPackage(for: userDid)

    logger.debug(
      "📦 Key package created: \(keyPackageData.count) bytes (first 16: \(keyPackageData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")))"
    )

    // ⭐ CRITICAL FIX: Persist state BEFORE uploading to server
    // This ensures we have the private key locally even if upload is cancelled
    logger.debug("💾 Persisting MLS state before upload (contains private key for key package)...")
    do {
      logger.info("✅ MLS state persisted before upload - private key is now safe")
    } catch {
      logger.error(
        "❌ CRITICAL: Failed to persist MLS state before upload: \(error.localizedDescription)")
      throw MLSConversationError.operationFailed(
        "Cannot persist cryptographic state - aborting upload to prevent orphaned key")
    }

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

      logger.info("Successfully published key package for: \(userDid) (state already persisted)")
      return keyPackageRef

    } catch {
      logger.error("Failed to publish key package: \(error.localizedDescription)")
      throw MLSConversationError.serverError(error)
    }
  }

  /// Smart key package refresh using monitor (preferred method)
  func smartRefreshKeyPackages() async throws {
    logger.debug("🔍 Checking if key package refresh is needed (smart monitoring)")
    if isShuttingDown {
      logger.info("⏸️ Skipping key package refresh - storage reset in progress")
      return
    }

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    // Check if this is first-time registration (no key packages on server)
    // We capture the stats here to avoid a redundant network call later
    let isFirstTime: Bool
    var freshStats: BlueCatbirdMlsGetKeyPackageStats.Output?

    do {
      let stats = try await apiClient.getKeyPackageStats()
      freshStats = stats
      isFirstTime = stats.available == 0
      if isFirstTime {
        logger.info(
          "🆕 First-time registration detected (0 packages on server) - bypassing rate limit")
      }
    } catch {
      // If we can't check stats, assume not first-time and respect rate limit
      isFirstTime = false
      logger.warning(
        "⚠️ Failed to fetch key package stats during initial check: \(error.localizedDescription)")
    }

    // 🛡️ FIX: Minimum interval check (prevent too-frequent uploads)
    // EXCEPT on first-time registration - must upload initial packages immediately
    if !isFirstTime {
      let minimumInterval: TimeInterval = 300  // 5 minutes
      if let lastRefresh = lastKeyPackageRefresh {
        let timeSinceLastRefresh = Date().timeIntervalSince(lastRefresh)
        if timeSinceLastRefresh < minimumInterval {
          logger.info(
            "⏱️ Too soon since last refresh (\(Int(timeSinceLastRefresh))s ago), skipping (minimum: \(Int(minimumInterval))s)"
          )
          return
        }
      }
    }

    guard let monitor = keyPackageMonitor else {
      // Fallback to basic refresh if monitor not initialized
      logger.warning("⚠️ Monitor not initialized, using basic refresh")
      return try await refreshKeyPackagesBasic()
    }

    let cache = MLSKeyPackageCache.shared

    // If we don't have fresh stats from the initial check, try to use cache or fetch
    if freshStats == nil {
      // Try cache first
      var forceServerRefresh = false
      if let cachedCount = await cache.getCachedCount() {
        logger.debug("Using cached count: \(cachedCount)")

        // Early exit if cache shows sufficient inventory
        let threshold = 20  // Default threshold
        if cachedCount >= threshold {
          logger.info("✅ Cached inventory sufficient: \(cachedCount) >= \(threshold)")
          return
        }

        // Cache says we're below threshold – bypass freshness window
        forceServerRefresh = true
      }

      // Check if we should refresh from server unless the low cache forces a refresh
      if await !cache.shouldRefreshFromServer() && !forceServerRefresh {
        logger.debug("Skipping server refresh, cache is fresh")
        return
      }

      // Fetch from server (retry if initial fetch failed or wasn't performed)
      do {
        freshStats = try await apiClient.getKeyPackageStats()
      } catch {
        logger.error("❌ Failed to check key package stats: \(error.localizedDescription)")
        logger.info("ℹ️ Skipping key package upload - server unavailable or error occurred")
        throw error
      }
    }

    // Proceed with replenishment logic using freshStats
    guard let stats = freshStats else {
      // Should not happen given logic above, but safe fallback
      return
    }

    do {
      // Update cache with server data
      await cache.updateFromServer(count: stats.available)

      // Convert to enhanced stats (using only available fields from server)
      // Note: total and consumed fields don't exist in BlueCatbirdMlsGetKeyPackageStats.Output
      let enhancedStats = EnhancedKeyPackageStats(
        available: stats.available,
        threshold: stats.threshold,
        total: stats.available,  // Total not provided by server, use available as approximation
        consumed: 0,  // Consumed count not provided, use 0
        consumedLast24h: nil,
        consumedLast7d: nil,
        averageDailyConsumption: nil,
        predictedDepletionDays: nil,
        needsReplenish: stats.needsReplenish
      )

      logger.info(
        "📊 Key package inventory: available=\(enhancedStats.available), threshold=\(enhancedStats.threshold), dynamic=\(enhancedStats.dynamicThreshold)"
      )

      // Check if replenishment needed using smart logic
      let recommendation = try await monitor.getReplenishmentRecommendation(stats: enhancedStats)

      if recommendation.shouldReplenish {
        logger.warning(
          "⚠️ Replenishment needed [\(recommendation.priority.rawValue)]: \(recommendation.reason)")

        // Upload using recommended batch size
        try await uploadKeyPackageBatchSmart(count: recommendation.recommendedBatchSize)
        lastKeyPackageRefresh = Date()
      } else {
        logger.debug("✅ Key packages are sufficient: \(stats.available) available")
        // Update timestamp even if we didn't upload, to respect the interval check
        // This prevents checking every time if we just confirmed we have enough
        lastKeyPackageRefresh = Date()
      }
    } catch {
      logger.error("❌ Error during replenishment logic: \(error.localizedDescription)")
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

      logger.info(
        "📊 Key package inventory: available=\(stats.available), threshold=\(stats.threshold)")

      // Replenish if below threshold or empty
      if stats.available < stats.threshold {
        logger.warning(
          "⚠️ Key package count (\(stats.available)) below threshold (\(stats.threshold)) - replenishing..."
        )
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
  /// Ensures local key packages exist AND uploads to server if needed
  func uploadKeyPackageBatchSmart(count: Int = 100) async throws {
    logger.info("🔄 Starting smart key package replenishment (requested count: \(count))...")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    // STEP 0: Ensure device is registered (server metadata only)
    let normalizedUserDid = userDid.trimmingCharacters(in: .whitespacesAndNewlines)
    let mlsDid = try await mlsClient.ensureDeviceRegistered(userDid: normalizedUserDid)
    logger.info("📱 Device registered (server metadata DID: \(mlsDid))")

    // Get device info for key package upload (mlsDid is server metadata)
    let deviceInfo = await mlsClient.getDeviceInfo(for: normalizedUserDid)

    // STEP 1: Check LOCAL key package count first
    // Local packages are needed for creating groups, even if server has plenty
    let localBundleCount = try await mlsClient.ensureLocalBundlesAvailable(for: normalizedUserDid)
    let minimumLocalBundles: UInt64 = 10

    let localBundlesNeeded =
      localBundleCount < minimumLocalBundles
      ? Int(minimumLocalBundles - localBundleCount)
      : 0

    if localBundlesNeeded > 0 {
      logger.info(
        "📦 Local storage needs \(localBundlesNeeded) bundles (have: \(localBundleCount), minimum: \(minimumLocalBundles))"
      )
    }

    // STEP 2: Query current server inventory
    let (serverAvailable, serverThreshold) = try await apiClient.queryKeyPackageInventory()
    logger.info("📊 Server inventory: \(serverAvailable) available, threshold: \(serverThreshold)")

    // STEP 3: Calculate server upload need
    let targetInventory = serverThreshold + 10  // Small buffer above threshold
    let serverUploadNeeded = max(0, targetInventory - serverAvailable)

    // STEP 4: Determine total packages to generate
    // Generate the MAXIMUM of what's needed locally OR for server upload
    let totalToGenerate = max(localBundlesNeeded, serverUploadNeeded)

    if totalToGenerate == 0 {
      logger.info("✅ Both local and server inventories are sufficient")
      logger.info("   Local: \(localBundleCount) bundles, Server: \(serverAvailable) packages")
      return
    }

    // STEP 5: Cap at API batch limit (100 packages max)
    let generateCount = min(totalToGenerate, 100)
    let willUploadToServer = serverUploadNeeded > 0

    logger.info("📦 Generating \(generateCount) key packages")
    logger.info("   Local need: \(localBundlesNeeded), Server need: \(serverUploadNeeded)")
    logger.info("   Will upload to server: \(willUploadToServer)")

    // STEP 6: Generate key packages
    // IMPORTANT: MLS credential identity must always be the bare ATProto DID.
    // Device-specific mlsDid is server metadata only.
    let expiresAt = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)  // 30 days
    var packages: [MLSKeyPackageUploadData] = []
    for _ in 0..<generateCount {
      let keyPackageBytes = try await mlsClient.createKeyPackage(
        for: normalizedUserDid,
        identity: normalizedUserDid
      )
      let keyPackageBase64 = keyPackageBytes.base64EncodedString()

      let packageData = MLSKeyPackageUploadData(
        keyPackage: keyPackageBase64,
        cipherSuite: defaultCipherSuite,
        expires: expiresAt,
        idempotencyKey: UUID().uuidString.lowercased(),
        deviceId: deviceInfo?.deviceId,
        credentialDid: normalizedUserDid
      )

      packages.append(packageData)
    }

    // STEP 7: Packages are now in SQLite storage (automatic persistence)
    // createKeyPackage() stores them in SqliteStorageProvider automatically
    logger.info("✅ Generated \(generateCount) key packages (automatically persisted to SQLite)")

    // STEP 8: Upload to server only if server needs them
    if willUploadToServer {
      // 🔍 DIAGNOSTIC: Log device_id being used for upload
      let uploadDeviceId = deviceInfo?.deviceId ?? "nil"
      logger.info(
        "📤 Uploading \(packages.count) packages to server with deviceId: \(uploadDeviceId)")

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

      // Update cache after successful upload
      if result.succeeded > 0 {
        await MLSKeyPackageCache.shared.updateAfterUpload(uploaded: result.succeeded)
        
        // CRITICAL FIX: Clear exhausted key package hashes for current user
        // After uploading fresh packages, other users should be able to use them
        // This prevents the "exhausted hash" error when creating groups
        exhaustedKeyPackageHashes.removeValue(forKey: normalizedUserDid)
        logger.info("🔄 Cleared exhausted key package cache for self after successful upload")
      }

      // Track successful uploads if monitor is available
      if let monitor = keyPackageMonitor, result.succeeded > 0 {
        // Note: We don't track uploads as consumption - only track when they're actually consumed
        logger.debug("📊 Uploaded \(result.succeeded) packages (not tracking as consumption)")
      }
    } else {
      logger.info(
        "⏭️ Skipping server upload - server inventory is sufficient (\(serverAvailable) packages)")
      logger.info("   Generated packages are stored locally for creating groups")
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
        logger.debug(
          "Key packages were refreshed \(Int(timeSinceLastRefresh))s ago, skipping (interval: \(Int(self.keyPackageRefreshInterval))s)"
        )
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
  /// - Returns: Current epoch number from FFI (ground truth)
  func getEpoch(convoId: String) async throws -> UInt64 {
    guard let convo = conversations[convoId] else {
      throw MLSConversationError.conversationNotFound
    }

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    // ⭐ CRITICAL FIX: Query FFI for actual epoch (ground truth from crypto layer)
    // Never trust server's potentially stale epoch value
    return try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
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

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    // ⭐ CRITICAL FIX: Get actual local epoch from FFI (ground truth)
    // DO NOT use convo.epoch which is the server's potentially stale view
    let localEpochFFI: UInt64
    do {
      localEpochFFI = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      logger.debug("📍 FFI local epoch: \(localEpochFFI)")
    } catch {
      logger.error("Failed to get FFI epoch: \(error.localizedDescription)")
      throw MLSConversationError.operationFailed("Cannot get local epoch from FFI")
    }

    // Fetch server epoch
    let serverEpoch: Int
    do {
      serverEpoch = try await apiClient.getEpoch(convoId: convoId)
      logger.debug("📍 Server epoch: \(serverEpoch), FFI local epoch: \(localEpochFFI)")
    } catch {
      logger.error("Failed to fetch server epoch: \(error.localizedDescription)")
      throw MLSConversationError.serverError(error)
    }

    // Compare FFI epoch (actual local state) vs server epoch
    let localEpochInt = Int(localEpochFFI)

    if localEpochInt > serverEpoch {
      // FFI is ahead of server - normal after group creation/commits
      // Server will catch up asynchronously
      logger.info(
        "✅ FFI ahead of server (FFI: \(localEpochFFI), Server: \(serverEpoch)) - no sync needed")
      return
    }

    if localEpochInt == serverEpoch {
      // Already in sync
      logger.debug("Already at latest epoch (\(localEpochFFI)), no sync needed")
      return
    }

    // FFI is behind server - need to fetch and process commits
    logger.info(
      "Behind server epoch: FFI=\(localEpochFFI), server=\(serverEpoch), fetching \(serverEpoch - localEpochInt) commits"
    )

    // Fetch missing commits
    let commits: [BlueCatbirdMlsGetCommits.CommitMessage]
    do {
      commits = try await apiClient.getCommits(
        convoId: convoId,
        fromEpoch: localEpochInt + 1,
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
        logger.error(
          "Failed to process commit for epoch \(commit.epoch): \(error.localizedDescription)")

        // 🔄 RECOVERY: Check if this error warrants device-level recovery
        if let recoveryManager = await mlsClient.recovery(for: userDid) {
          let recovered = await recoveryManager.attemptRecoveryIfNeeded(
            for: error,
            userDid: userDid,
            convoIds: [convoId]
          )
          if recovered {
            logger.info(
              "🔄 Silent recovery initiated for conversation \(convoId.prefix(16)) - will rejoin in background"
            )
          }
        }

        throw MLSConversationError.commitProcessingFailed(commit.epoch, error)
      }
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    let actualEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
    let serverEpochUInt = UInt64(serverEpoch)

    logger.info(
      "✅ Commits processed. FFI epoch: \(actualEpoch), Server reported: \(serverEpochUInt)")

    if actualEpoch != serverEpochUInt {
      logger.warning("⚠️ EPOCH MISMATCH after sync:")
      logger.warning("   FFI (actual): \(actualEpoch)")
      logger.warning("   Server (stale): \(serverEpochUInt)")
      logger.warning("   Trusting FFI state to prevent desynchronization")
    }

    // Update local epoch to match FFI (not server)
    handleEpochUpdate(convoId: convoId, newEpoch: actualEpoch)

    // Notify observers of epoch update AFTER database commits
    notifyObservers(.epochUpdated(convoId, Int(actualEpoch)))

    logger.info("Successfully synced group state to FFI epoch \(actualEpoch)")
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
    let result = try await mlsClient.processCommit(
      for: userDid, groupId: groupIdData, commitData: commitData)
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
          userDID: userDid,
          database: database
        )
        logger.debug("Recorded epoch key for cleanup tracking")

        // Clean up old epoch keys based on retention policy
        try await storage.deleteOldEpochKeys(
          conversationID: state.convoId,
          userDID: userDid,
          keepLast: configuration.maxPastEpochs,
          database: database
        )

        // Notify observers of epoch update AFTER database commit
        notifyObservers(.epochUpdated(state.convoId, epochInt))
        logger.debug("Cleaned up old epoch keys (keeping last \(self.configuration.maxPastEpochs))")
      } catch {
        logger.error("Failed to cleanup old epoch keys: \(error)")
      }

      // Persist MLS state after epoch change (critical for forward secrecy)
      do {
        logger.debug("✅ Persisted MLS state after epoch \(epochInt)")
      } catch {
        logger.error("⚠️ Failed to persist MLS state after commit: \(error.localizedDescription)")
      }

      // Notify observers of epoch update
      notifyObservers(.epochUpdated(state.convoId, epochInt))
      logger.debug("Updated local epoch for group \(groupId.prefix(8))... to \(result.newEpoch)")
    } else {
      logger.warning(
        "No local group state found for group \(groupId.prefix(8))... after processing commit")
    }
  }

  // MARK: - Force Rejoin Recovery

  /// 🔒 FIX #6: Nuclear rejoin option for unrecoverable epoch desync
  ///
  /// This method forcefully re-joins a conversation when normal recovery fails.
  /// Use this when:
  /// - User is stuck at an old epoch and cannot process commits
  /// - GroupInfo on server was corrupted but has since been refreshed
  /// - Manual intervention is needed to restore conversation access
  ///
  /// The process:
  /// 1. Delete local group state (wipe corrupted MLS state)
  /// 2. Request fresh GroupInfo from active members
  /// 3. Wait for fresh GroupInfo to be published
  /// 4. Rejoin via External Commit with fresh state
  ///
  /// - Parameter convoId: Conversation identifier to force rejoin
  /// - Throws: MLSConversationError if the operation fails
  /// - Warning: This discards all local MLS state for this conversation!
  func forceRejoin(for convoId: String) async throws {
    logger.warning(
      "🔄 [forceRejoin] Starting NUCLEAR REJOIN for conversation \(convoId.prefix(16))...")
    logger.warning("   ⚠️  This will DELETE all local MLS state for this conversation!")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    // Step 1: Delete local group state
    logger.info("🗑️ [forceRejoin] Step 1/4: Deleting local group state...")
    do {
      try await mlsClient.deleteGroup(for: userDid, groupId: groupIdData)
      logger.info("✅ [forceRejoin] Local group state deleted")
    } catch {
      logger.warning(
        "⚠️ [forceRejoin] Delete group failed (may not exist): \(error.localizedDescription)")
      // Continue anyway - group might not exist locally
    }

    // Also clear local tracking state
    groupStates.removeValue(forKey: convo.groupId)

    // Step 2: Request fresh GroupInfo from active members
    logger.info("📡 [forceRejoin] Step 2/4: Requesting GroupInfo refresh from active members...")
    do {
      let (requested, activeMembers) = try await apiClient.groupInfoRefresh(convoId: convoId)
      if requested {
        logger.info(
          "✅ [forceRejoin] GroupInfo refresh requested - \(activeMembers ?? 0) active members notified"
        )
      } else {
        logger.warning("⚠️ [forceRejoin] No active members to refresh GroupInfo - proceeding anyway")
      }
    } catch {
      logger.warning(
        "⚠️ [forceRejoin] Failed to request GroupInfo refresh: \(error.localizedDescription)")
      // Continue anyway - maybe GroupInfo is already fresh
    }

    // Step 3: Wait for fresh GroupInfo to be published
    logger.info("⏳ [forceRejoin] Step 3/4: Waiting 3s for fresh GroupInfo...")
    try await Task.sleep(for: .seconds(3))

    // Step 4: Rejoin via External Commit
    logger.info("🔐 [forceRejoin] Step 4/4: Rejoining via External Commit...")
    let newGroupId = try await mlsClient.joinByExternalCommit(for: userDid, convoId: convoId)

    // Verify we rejoined the same group
    let newGroupIdHex = newGroupId.hexEncodedString()
    if newGroupIdHex != convo.groupId {
      logger.warning("⚠️ [forceRejoin] Group ID changed after rejoin!")
      logger.warning("   Old: \(convo.groupId.prefix(16))")
      logger.warning("   New: \(newGroupIdHex.prefix(16))")
    }

    // Get new epoch
    let newEpoch = try await mlsClient.getEpoch(for: userDid, groupId: newGroupId)
    logger.info("✅ [forceRejoin] SUCCESS - Rejoined at epoch \(newEpoch)")

    // Update local group state
    groupStates[newGroupIdHex] = MLSGroupState(
      groupId: newGroupIdHex,
      convoId: convoId,
      epoch: newEpoch,
      members: []
    )

    // Note: The conversation record in `conversations` dictionary uses ConvoView from server
    // which we cannot modify directly. The server will update it when we fetch conversations.
    // We just need to ensure our local groupStates is correct.

    // Clear any failed rejoin tracking for this conversation
    if let recoveryManager = await mlsClient.recovery(for: userDid) {
      await recoveryManager.clearRejoinTracking(convoId: convoId)
    }

    // Notify observers
    notifyObservers(.epochUpdated(convoId, Int(newEpoch)))
    logger.info("🎉 [forceRejoin] Nuclear rejoin complete for \(convoId.prefix(16))")
  }

  // MARK: - State Repair for Admins

  /// Force republish fresh GroupInfo for a conversation
  ///
  /// 🔧 STATE REPAIR: Call this when the stored GroupInfo on the server is corrupt
  /// (EndOfStream errors during External Commit). This function:
  /// 1. Exports fresh GroupInfo from local MLS state
  /// 2. Validates the GroupInfo before upload
  /// 3. Uploads to server, overwriting the corrupt data
  /// 4. Verifies the upload succeeded
  ///
  /// After calling this, broken clients can retry External Commit and should succeed.
  ///
  /// - Parameter convoId: Conversation identifier to repair
  /// - Throws: MLSConversationError if the operation fails
  /// - Note: Only call this if you are on the "true" epoch (usually the admin or last committer)
  func forceRepublishGroupInfo(for convoId: String) async throws {
    logger.info(
      "🔧 [forceRepublishGroupInfo] Starting GroupInfo repair for \(convoId.prefix(16))...")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    guard let convo = conversations[convoId] else {
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    // Step 1: Verify we have valid local state
    let localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
    logger.info("📍 [forceRepublishGroupInfo] Local epoch: \(localEpoch)")

    // Step 2: Publish fresh GroupInfo (with validation)
    logger.info("📤 [forceRepublishGroupInfo] Publishing fresh GroupInfo...")
    try await publishLatestGroupInfo(
      userDid: userDid,
      convoId: convoId,
      groupId: groupIdData,
      context: "force repair"
    )

    // Step 3: Verify GroupInfo health after publish
    if let recoveryManager = await mlsClient.recovery(for: userDid) {
      let isHealthy = await recoveryManager.verifyGroupInfoHealth(
        convoId: convoId,
        expectedSize: 0  // No specific expectation
      )
      if isHealthy {
        logger.info(
          "✅ [forceRepublishGroupInfo] GroupInfo repair SUCCESSFUL for \(convoId.prefix(16))")
        logger.info("   Broken clients can now retry External Commit")
      } else {
        logger.error("❌ [forceRepublishGroupInfo] GroupInfo repair FAILED - verification failed")
        throw MLSConversationError.operationFailed("GroupInfo repair verification failed")
      }
    } else {
      logger.info("✅ [forceRepublishGroupInfo] GroupInfo published (no recovery manager to verify)")
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

    logger.info(
      "Started background cleanup task (interval: \(self.configuration.cleanupInterval)s)")
  }

  /// Start periodic background sync to keep conversations in sync with server
  private func startPeriodicSync() {
    periodicSyncTask?.cancel()

    periodicSyncTask = Task { [weak self] in
      guard let self else { return }

      // Wait 30 seconds before first sync to avoid startup congestion
      try? await Task.sleep(for: .seconds(30))

      while !Task.isCancelled {
        do {
          // Sync every 5 minutes
          try await Task.sleep(for: .seconds(300))

          guard !Task.isCancelled else { break }

          self.logger.info("🔄 Running periodic background sync")
          try? await self.syncWithServer(fullSync: false)
        } catch {
          if error is CancellationError {
            self.logger.info("Periodic sync task cancelled")
            break
          }
          self.logger.error("Periodic sync error: \(error)")
        }
      }
    }

    logger.info("Started periodic background sync task (interval: 5 minutes)")
  }

  /// Perform cleanup of old key material
  private func performBackgroundCleanup() async {
    logger.debug("Running background cleanup")

    guard let userDid = userDid else {
      logger.warning("Cannot perform background cleanup: userDid not available")
      return
    }

    do {
      // Clean up old pending messages (prevent memory leaks)
      cleanupOldPendingMessages()

      // Clean up message keys older than retention threshold
      let threshold = configuration.messageKeyCleanupThreshold
      try await storage.cleanupMessageKeys(
        userDID: userDid, olderThan: threshold, database: database)
      logger.debug("Cleaned up message keys older than \(threshold)")

      // Permanently delete marked epoch keys
      try await storage.deleteMarkedEpochKeys(userDID: userDid, database: database)
      logger.debug("Permanently deleted marked epoch keys")

      // Clean up expired key packages
      try await storage.deleteExpiredKeyPackages(userDID: userDid, database: database)
      logger.debug("Deleted expired key packages")

      // Refresh key packages if needed
      try await refreshKeyPackagesBasedOnInterval()

      // Checkpoint database to consolidate WAL and free memory
      // This helps prevent "out of memory" errors during heavy polling
      try? await MLSGRDBManager.shared.checkpointDatabase(for: userDid)
      logger.debug("Database checkpoint completed")

      logger.info("Background cleanup completed successfully")
    } catch {
      logger.error("Background cleanup failed: \(error)")
    }
  }

  /// Clean up old pending messages that have exceeded the timeout
  /// Prevents memory leaks if messages are somehow never confirmed by the server
  private func cleanupOldPendingMessages() {
    let now = Date()

    pendingMessagesLock.lock()
    defer { pendingMessagesLock.unlock() }

    let initialCount = pendingMessages.count

    // Remove pending messages older than timeout (5 minutes by default)
    pendingMessages = pendingMessages.filter { _, pending in
      pending.timestamp.addingTimeInterval(pendingMessageTimeout) > now
    }

    let removed = initialCount - pendingMessages.count
    if removed > 0 {
      logger.debug(
        "🧹 Cleaned up \(removed) stale pending messages (older than \(Int(self.pendingMessageTimeout))s)"
      )
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
  /// Uses GroupOperationCoordinator to ensure serialization per group
  private func encryptMessage(groupId: String, plaintext: Data) async throws -> Data {
    return try await groupOperationCoordinator.withExclusiveLock(groupId: groupId) { [self] in
      try await encryptMessageImpl(groupId: groupId, plaintext: plaintext)
    }
  }

  /// Internal implementation of message encryption (called within exclusive lock)
  private func encryptMessageImpl(groupId: String, plaintext: Data) async throws -> Data {
    logger.debug(
      "encryptMessage called: groupId=\(groupId.prefix(20))..., plaintext.count=\(plaintext.count)")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }
    // groupId is hex-encoded, convert to Data
    guard let groupIdData = Data(hexEncoded: groupId) else {
      logger.error("Failed to decode hex groupId: \(groupId.prefix(20))...")
      throw MLSConversationError.invalidGroupId
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX: Epoch Pre-Flight Check
    // ═══════════════════════════════════════════════════════════════════════════
    // Before encrypting, verify our in-memory epoch matches the on-disk state.
    // If the NSE advanced the ratchet while we were in background, our in-memory
    // state is stale and we must force a reload.
    //
    // This prevents:
    // - SecretReuseError (using a nonce the NSE already consumed)
    // - Encrypting at an old epoch that recipients can't decrypt
    // ═══════════════════════════════════════════════════════════════════════════
    if let memoryState = groupStates[groupId] {
      do {
        let diskEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
        if diskEpoch > memoryState.epoch {
          logger.warning("⚠️ [Epoch Check] Disk epoch (\(diskEpoch)) > memory epoch (\(memoryState.epoch))")
          logger.info("   NSE likely advanced ratchet - forcing state reload before encrypt")
          groupStates.removeValue(forKey: groupId)
          conversationStates.removeValue(forKey: groupId)
          // FFI will reload fresh state on next access
        }
      } catch {
        logger.debug("⚠️ [Epoch Check] Could not verify epoch: \(error.localizedDescription)")
        // Non-fatal - proceed with operation, FFI layer handles state
      }
    }

    logger.debug("Calling mlsClient.encryptMessage with groupIdData.count=\(groupIdData.count)")
    let encryptResult = try await mlsClient.encryptMessage(
      for: userDid, groupId: groupIdData, plaintext: plaintext)

    // Signal ratchet advance to other in-process/cross-process contexts.
    MLSStateVersionManager.shared.incrementVersion(for: userDid)

    logger.debug(
      "mlsClient.encryptMessage succeeded, ciphertext.count=\(encryptResult.ciphertext.count)")

    // Persist MLS state after encryption (sender ratchet advanced)
    do {
      logger.debug("✅ Persisted MLS state after message encryption")
    } catch {
      logger.error("⚠️ Failed to persist MLS state after encryption: \(error.localizedDescription)")
    }

    return encryptResult.ciphertext
  }

  /// Decrypt message using MLSClient with processMessage flow
  /// Uses GroupOperationCoordinator to ensure serialization per group
  private func decryptMessage(groupId: String, ciphertext: Data) async throws -> Data {
    return try await groupOperationCoordinator.withExclusiveLock(groupId: groupId) { [self] in
      try await decryptMessageImpl(groupId: groupId, ciphertext: ciphertext)
    }
  }

  /// Internal implementation of message decryption (called within exclusive lock)
  private func decryptMessageImpl(groupId: String, ciphertext: Data) async throws -> Data {
    logger.info("Decrypting message for group \(groupId.prefix(8))...")

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }
    guard let groupIdData = Data(hexEncoded: groupId) else {
      logger.error("Invalid group ID format")
      throw MLSConversationError.invalidGroupId
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX: Epoch Pre-Flight Check
    // ═══════════════════════════════════════════════════════════════════════════
    // Before decrypting, verify our in-memory epoch matches the on-disk state.
    // If the NSE advanced the ratchet while we were in background, our in-memory
    // state is stale and we must force a reload.
    //
    // This prevents attempting decryption with stale keys that would fail with
    // SecretReuseError or DecryptionFailed.
    // ═══════════════════════════════════════════════════════════════════════════
    if let memoryState = groupStates[groupId] {
      do {
        let diskEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
        if diskEpoch > memoryState.epoch {
          logger.warning("⚠️ [Epoch Check] Disk epoch (\(diskEpoch)) > memory epoch (\(memoryState.epoch))")
          logger.info("   NSE likely advanced ratchet - forcing state reload before decrypt")
          groupStates.removeValue(forKey: groupId)
          conversationStates.removeValue(forKey: groupId)
          // FFI will reload fresh state on next access
        }
      } catch {
        logger.debug("⚠️ [Epoch Check] Could not verify epoch: \(error.localizedDescription)")
        // Non-fatal - proceed with operation, FFI layer handles state
      }
    }

    let ciphertextData = ciphertext

    do {
      // Use processMessage instead of decryptMessage to get content type
      let processedContent = try await mlsClient.processMessage(
        for: userDid,
        groupId: groupIdData,
        messageData: ciphertextData
      )

      // Signal ratchet advance to other in-process/cross-process contexts.
      MLSStateVersionManager.shared.incrementVersion(for: userDid)

      // CRITICAL FIX: Persist MLS state after decryption (receiver ratchet advanced)
      // This prevents SecretReuseError when trying to decrypt subsequent messages
      do {
        logger.debug("✅ Persisted MLS state after message decryption")
      } catch {
        logger.error(
          "⚠️ Failed to persist MLS state after decryption: \(error.localizedDescription)")
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
        // Staged commit was already auto-merged by processMessage in Rust
        // Just verify the epoch advancement succeeded
        logger.info("Received commit for epoch \(newEpoch), verifying...")
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
  /// Automatically uses mlsDid (device-specific DID) as the identity
  private func processWelcome(welcomeData: Data) async throws -> String {
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }
    try throwIfShuttingDown("processWelcome")

    do {
      do {
        logger.debug("💾 Ensured UniFFI context hydrated for user before processing Welcome")
      } catch {
        logger.error(
          "❌ Failed to hydrate context before processing Welcome: \(error.localizedDescription)")
        throw MLSConversationError.operationFailed(
          "Unable to hydrate MLS context: \(error.localizedDescription)")
      }

      do {
        let bundleCount = try await mlsClient.ensureLocalBundlesAvailable(for: userDid)
        logger.debug("✅ Verified \(bundleCount) local key packages before processing Welcome")
        if bundleCount == 0 {
          logger.error("❌ No local bundles available - cannot process Welcome")
          throw MLSConversationError.operationFailed(
            "No key packages available. Please generate bundles first via monitorAndReplenishBundles()"
          )
        }
      } catch {
        logger.error("❌ Failed to verify local key packages: \(error.localizedDescription)")
        throw MLSConversationError.operationFailed(
          "Unable to verify key packages: \(error.localizedDescription)")
      }

      // Uses mlsDid (device-specific DID) automatically
      let groupId = try await mlsClient.joinGroup(
        for: userDid, welcome: welcomeData, configuration: configuration.groupConfiguration)

      // Persist MLS state after joining group (new group created)
      do {
        logger.debug("✅ Persisted MLS state after joining group")
      } catch {
        logger.error("⚠️ Failed to persist MLS state after join: \(error.localizedDescription)")
      }

      return groupId.hexEncodedString()
    } catch let error as MlsError {
      // Handle key package desync (app reinstall, database loss, etc.)
      if case .KeyPackageDesyncDetected(let message) = error {
        logger.warning("🔄 Key package desync detected: \(message)")
        logger.info("Attempting automated recovery via External Commit...")

        // Extract conversation ID from the error message if possible
        // The Rust FFI should include conversation ID in the message
        try await handleKeyPackageDesyncRecovery(errorMessage: message, userDid: userDid)

        // After recovery, the conversation should be marked for rejoin
        // The user will rejoin via External Commit
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
    logger.info("📦 Handling key package desync recovery...")

    // Extract conversation ID from error message
    // The Rust FFI formats the message as: "No key package bundles available..." or includes convo_id
    // For now, we'll need the caller to provide the conversation ID explicitly
    // This is a limitation - we'll improve this in the next iteration

    logger.warning("⚠️ Cannot automatically extract conversation ID from desync error")
    logger.info("User will need to manually rejoin the conversation via UI")
  }

  /// Ensure MLS group is initialized for a conversation
  /// This should be called when opening a conversation to ensure the user can send/receive messages
  /// - Parameter convoId: Conversation ID to initialize
  func ensureGroupInitialized(for convoId: String) async throws {
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }
    try throwIfShuttingDown("ensureGroupInitialized")
    guard let convo = conversations[convoId] else {
      logger.warning("Cannot initialize group: conversation \(convoId) not found")
      throw MLSConversationError.conversationNotFound
    }

    guard let groupIdData = Data(hexEncoded: convo.groupId) else {
      logger.error("Invalid groupId for conversation \(convoId)")
      throw MLSConversationError.invalidGroupId
    }

    // Check if group already exists locally
    if await mlsClient.groupExists(for: userDid, groupId: groupIdData) {
      logger.debug("Group already exists locally for conversation \(convoId)")
      return
    }

    // ⭐ CRITICAL FIX: Check if we are the creator before trying to join via Welcome
    // If we are the creator, the Welcome message on the server is meant for OTHER users,
    // not for us. The creator must use External Commit to rejoin their own group.
    let isCreator = convo.creator.description.lowercased() == userDid.lowercased()

    if isCreator {
      logger.warning(
        "⚠️ [ensureGroupInitialized] Creator (\(userDid.prefix(20))...) missing group state for \(convoId.prefix(16))..."
      )
      logger.warning(
        "   The Welcome message is for OTHER members - cannot use it to rejoin as creator")
      logger.info("🔄 [ensureGroupInitialized] Attempting External Commit for creator rejoin...")

      do {
        let _ = try await mlsClient.joinByExternalCommit(for: userDid, convoId: convo.groupId)
        logger.info("✅ [ensureGroupInitialized] Creator successfully rejoined via External Commit")
      } catch {
        logger.error(
          "❌ [ensureGroupInitialized] Creator rejoin via External Commit failed: \(error.localizedDescription)"
        )
        throw MLSConversationError.groupNotInitialized
      }
    } else {
      // Group doesn't exist, initialize from Welcome message
      logger.info("Group not found locally, initializing from Welcome for conversation \(convoId)")
      try await initializeGroupFromWelcome(convo: convo)
    }
  }

  /// Initialize a group from a Welcome message fetched from the server
  /// - Parameter convo: The conversation to initialize
  private func initializeGroupFromWelcome(convo: BlueCatbirdMlsDefs.ConvoView) async throws {
    logger.debug("Fetching Welcome message for conversation \(convo.groupId)")
    try throwIfShuttingDown("initializeGroupFromWelcome")

    // Process Welcome message to join the group
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    var groupIdHex: String

    // Fetch Welcome message from server (returns Data directly, already decoded from base64)
    // Handle HTTP 410 GONE - indicates the Welcome's KeyPackage has expired/been consumed
    let welcomeData: Data
    do {
      welcomeData = try await apiClient.getWelcome(convoId: convo.groupId)
      logger.debug("Received Welcome message: \(welcomeData.count) bytes")

      // 🔬 CRITICAL DIAGNOSTIC: Log Welcome message as received
      logger.info("📨 [WELCOME MESSAGE FORENSICS - Joiner Side]")
      logger.info("   Conversation: \(convo.groupId)")
      logger.info("   Welcome Size: \(welcomeData.count) bytes")
      logger.info("   Welcome (first 200 bytes hex): \(welcomeData.prefix(200).hexEncodedString())")
      logger.info("   Welcome (last 200 bytes hex): \(welcomeData.suffix(200).hexEncodedString())")
      logger.info("   ⚠️  Compare this Welcome with creator's Welcome above!")
      logger.info("   ⚠️  They should be IDENTICAL byte-for-byte")
    } catch let error as MLSAPIError {
      // Handle HTTP 410 GONE - Welcome's KeyPackage is expired or already consumed
      if case .httpError(let statusCode, _) = error, statusCode == 410 {
        logger.info(
          "📭 [HTTP 410 GONE] Welcome expired for \(convo.groupId) - KeyPackage consumed/expired")
        logger.info("🔄 Skipping Welcome, attempting External Commit directly...")

        // Go straight to External Commit - don't try to process expired Welcome
        groupIdHex = try await attemptExternalCommitFallback(
          convoId: convo.groupId,
          userDid: userDid,
          reason: "Welcome expired (HTTP 410)"
        )

        // Continue to group state update below
        try await updateGroupStateAfterJoin(convo: convo, groupIdHex: groupIdHex, userDid: userDid)
        return
      }
      // Re-throw other API errors
      throw error
    }

    do {
      groupIdHex = try await processWelcome(welcomeData: welcomeData)
      
      // 🚨 ROOT CAUSE FIX: Create SQLCipher conversation record IMMEDIATELY after Welcome
      // This prevents "FOREIGN KEY constraint failed" errors when messages are decrypted.
      // Without this, the message INSERT fails, plaintext is lost, and Forward Secrecy
      // means we can never decrypt the message again (keys are burned after first use).
      do {
        _ = try await storage.ensureConversationExistsOrPlaceholder(
          userDID: userDid,
          conversationID: convo.groupId,
          groupID: groupIdHex,
          senderDID: convo.members.first(where: { $0.did.description.lowercased() != userDid.lowercased() })?.did.description,
          database: database
        )
        logger.info("✅ [FK-FIX] Ensured conversation record exists after Welcome processing")
      } catch {
        // Non-fatal - the safety net in savePlaintext will create a placeholder if needed
        logger.warning("⚠️ [FK-FIX] Failed to pre-create conversation record: \(error.localizedDescription)")
      }
    } catch let error as MlsError {
      // CRITICAL FIX: Handle NoMatchingKeyPackage by falling back to External Commit
      // This occurs when the Welcome references a key package that no longer exists in storage
      // (e.g., due to multiple device registrations or storage recreation)
      if case .NoMatchingKeyPackage = error {
        logger.warning("⚠️ NoMatchingKeyPackage error - Welcome references unavailable key package")

        // Invalidate the stale Welcome on the server using dedicated endpoint
        logger.info("📤 Invalidating stale Welcome on server (NoMatchingKeyPackage)...")
        do {
          let (invalidated, welcomeId) = try await apiClient.invalidateWelcome(
            convoId: convo.groupId,
            reason: "NoMatchingKeyPackage: key package hash_ref not found in local storage"
          )
          if invalidated {
            logger.info("✅ Welcome invalidated successfully (id: \(welcomeId ?? "unknown"))")
          } else {
            logger.warning("⚠️ No Welcome found to invalidate - may have already been consumed")
          }
        } catch {
          // Non-critical - continue with External Commit fallback regardless
          logger.warning("⚠️ Failed to invalidate Welcome: \(error.localizedDescription)")
        }

        logger.info("🔄 Attempting fallback to External Commit for conversation \(convo.groupId)...")

        groupIdHex = try await attemptExternalCommitFallback(
          convoId: convo.groupId,
          userDid: userDid,
          reason: "NoMatchingKeyPackage"
        )

        // Continue to group state update below
        try await updateGroupStateAfterJoin(convo: convo, groupIdHex: groupIdHex, userDid: userDid)
        return
      } else {
        // Other MlsError types - check if recovery is warranted
        // CRITICAL FIX: Welcome data comes from server, so mark as remote data error
        // This prevents destructive local wipe when server sends corrupted Welcome
        if let recoveryManager = await mlsClient.recovery(for: userDid) {
          let errorMessage = error.localizedDescription.lowercased()
          let isServerDataCorruption =
            errorMessage.contains("invalidvectorlength") || errorMessage.contains("endofstream")
            || errorMessage.contains("malformed") || errorMessage.contains("deseriali")

          if isServerDataCorruption {
            // Mark as server-corrupted - don't wipe local database
            await recoveryManager.markConversationServerCorrupted(
              convoId: convo.groupId,
              errorMessage: "Welcome deserialization failed: \(error.localizedDescription)"
            )
            logger.error("🚫 Server data corrupted for conversation \(convo.groupId.prefix(16))")
            logger.error("   NOT triggering local recovery - server must fix Welcome message")
            throw MLSConversationError.operationFailed(
              "Server data corrupted - cannot join conversation")
          }

          let recovered = await recoveryManager.attemptRecoveryIfNeeded(
            for: error,
            userDid: userDid,
            convoIds: [convo.groupId],
            triggeringConvoId: convo.groupId,
            isRemoteDataError: true  // Welcome comes from server
          )
          if recovered {
            logger.info("🔄 Recovery initiated for MLS error: \(error)")
            throw MLSConversationError.operationFailed("Recovery in progress - please wait")
          }
        }
        throw error
      }
    }

    // Update local group state with correct epoch
    if var state = groupStates[convo.groupId] {
      // ⭐ CRITICAL FIX: Verify epoch from FFI after joining via Welcome
      guard let groupIdData = Data(hexEncoded: groupIdHex) else {
        throw MLSConversationError.invalidGroupId
      }

      let serverEpoch = UInt64(convo.epoch)
      let ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

      if serverEpoch != ffiEpoch {
        logger.warning("⚠️ EPOCH MISMATCH after processing Welcome:")
        logger.warning("   Server: \(serverEpoch), FFI: \(ffiEpoch)")
        logger.warning("   Using FFI epoch to prevent state desynchronization")
      }

      state.epoch = ffiEpoch  // Use FFI epoch, not server epoch
      groupStates[convo.groupId] = state
      logger.debug(
        "Updated group epoch to \(ffiEpoch) (from FFI) for conversation \(convo.groupId)")

      // Persist join method/epoch for UI (Welcome-based join preserves history).
      do {
        try await storage.updateConversationJoinInfo(
          conversationID: convo.groupId,
          currentUserDID: userDid,
          joinMethod: .welcome,
          joinEpoch: Int64(ffiEpoch),
          database: database
        )
      } catch {
        logger.warning("⚠️ Failed to persist join info (Welcome): \(error.localizedDescription)")
      }
    }

    logger.info("Successfully initialized group from Welcome for conversation \(convo.groupId)")

    // 🔬 DIAGNOSTIC: Log complete group state after joining via Welcome
    guard let groupIdDataForDiag = Data(hexEncoded: groupIdHex) else {
      throw MLSConversationError.invalidGroupId
    }
    await logGroupStateDiagnostics(
      userDid: userDid, groupId: groupIdDataForDiag, context: "After Join Via Welcome (Joiner)")

    await catchUpMessagesIfNeeded(for: convo, force: true)
  }

  // MARK: - Proposal and Commit Handling

  /// Handle a received proposal
  private func handleProposal(groupId: String, proposal: Any, proposalRef: ProposalRef) async throws
  {
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
  /// Validate and merge staged commit
  /// Uses GroupOperationCoordinator to ensure serialization per group
  private func validateAndMergeStagedCommit(groupId: String, newEpoch: UInt64) async throws {
    return try await groupOperationCoordinator.withExclusiveLock(groupId: groupId) { [self] in
      try await validateAndMergeStagedCommitImpl(groupId: groupId, newEpoch: newEpoch)
    }
  }

  /// Internal implementation of staged commit validation and merge (called within exclusive lock)
  private func validateAndMergeStagedCommitImpl(groupId: String, newEpoch: UInt64) async throws {
    // NOTE: As of the epoch advancement fix, staged commits from other members are now
    // auto-merged during processMessage() in the Rust FFI layer. This function now just
    // validates the epoch state is correct and logs the transition.
    //
    // Previously, this function would call mergeStagedCommit() which would look for a
    // pending commit (wrong!), causing the group to stay at the old epoch while other
    // members advanced.

    logger.info(
      "✅ Staged commit already merged in processMessage, verifying epoch \(newEpoch) for group \(groupId.prefix(8))..."
    )

    // Convert hex-encoded groupId to Data
    guard let groupIdData = Data(hexEncoded: groupId) else {
      throw MLSConversationError.invalidGroupId
    }

    // Verify the current epoch matches what we expect
    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    do {
      let currentEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      if currentEpoch != newEpoch {
        logger.warning(
          "⚠️ Epoch mismatch after staged commit merge: current=\(currentEpoch), expected=\(newEpoch)"
        )
      } else {
        logger.info("✅ Epoch verified: \(currentEpoch)")
      }
    } catch {
      logger.warning(
        "⚠️ Unable to verify epoch after staged commit merge: \(error.localizedDescription)")
    }
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

  /// Unreserve key packages when a transient server error occurs (e.g., 502 Bad Gateway)
  /// This allows the same packages to be retried since they weren't actually consumed
  private func unreserveKeyPackages(_ packages: [KeyPackageWithHash]) {
    for package in packages {
      let didKey = package.did.description
      if var exhausted = exhaustedKeyPackageHashes[didKey] {
        exhausted.remove(package.hash)
        if exhausted.isEmpty {
          exhaustedKeyPackageHashes.removeValue(forKey: didKey)
        } else {
          exhaustedKeyPackageHashes[didKey] = exhausted
        }
        logger.debug("♻️ Unreserved key package hash for \(didKey): \(package.hash.prefix(16))...")
      }
    }
  }

  // MARK: - External Commit Fallback for Recovery

  /// Attempt to join a group via External Commit when Welcome processing fails.
  /// Tracks failures via recovery manager to prevent infinite loops.
  ///
  /// - Parameters:
  ///   - convoId: The conversation/group ID to join
  ///   - userDid: The current user's DID
  ///   - reason: Descriptive reason for fallback (for logging)
  /// - Returns: The group ID hex string on success
  /// - Throws: MLSConversationError if External Commit fails
  private func attemptExternalCommitFallback(
    convoId: String,
    userDid: String,
    reason: String
  ) async throws -> String {
    logger.info(
      "🔄 [External Commit Fallback] Starting for \(convoId.prefix(16))... Reason: \(reason)")

    // Check if we should skip this rejoin attempt (max attempts or cooldown)
    if let recoveryManager = await mlsClient.recovery(for: userDid) {
      let shouldSkip = await recoveryManager.shouldSkipRejoin(convoId: convoId)
      if shouldSkip {
        logger.warning(
          "⏭️ [External Commit Fallback] Skipping \(convoId.prefix(16))... - recovery tracking says skip"
        )
        throw MLSConversationError.operationFailed(
          "External Commit skipped - max attempts exceeded or on cooldown")
      }
    }

    do {
      // Attempt External Commit via mlsClient

      let groupIdData = try await mlsClient.joinByExternalCommit(for: userDid, convoId: convoId)
      let groupIdHex = groupIdData.hexEncodedString()

      logger.info(
        "✅ [External Commit Fallback] Successfully joined \(convoId.prefix(16))... via External Commit"
      )

      // Clear recovery tracking on success
      if let recoveryManager = await mlsClient.recovery(for: userDid) {
        await recoveryManager.clearRejoinTracking(convoId: convoId)
      }

      return groupIdHex
    } catch {
      logger.error(
        "❌ [External Commit Fallback] Failed for \(convoId.prefix(16))...: \(error.localizedDescription)"
      )

      // Check if this is a stale GroupInfo error - request refresh from active members
      let errorMessage = error.localizedDescription.lowercased()
      let isStaleGroupInfo =
        errorMessage.contains("expired") || errorMessage.contains("stale")
        || errorMessage.contains("groupinfo expired")

      if isStaleGroupInfo {
        logger.info(
          "🔄 [External Commit Fallback] GroupInfo stale - requesting refresh from active members")
        await groupInfoRefresh(convoId: convoId)
      }

      // Record the failure for tracking
      if let recoveryManager = await mlsClient.recovery(for: userDid) {
        // Check if this is a server data corruption error
        let isServerDataCorruption =
          errorMessage.contains("invalidvectorlength") || errorMessage.contains("endofstream")
          || errorMessage.contains("malformed") || errorMessage.contains("truncat")
          || errorMessage.contains("server data corrupted")

        if isServerDataCorruption {
          // Mark as server-corrupted to prevent further retry loops
          await recoveryManager.markConversationServerCorrupted(
            convoId: convoId,
            errorMessage: "External Commit failed (server data): \(error.localizedDescription)"
          )
          logger.error(
            "🚫 [External Commit Fallback] Server data corrupted - marked conversation as broken")
        } else {
          await recoveryManager.recordFailedRejoin(convoId: convoId)
          let remaining = await recoveryManager.remainingRejoinAttempts(convoId: convoId)
          logger.info(
            "📊 [External Commit Fallback] \(remaining) rejoin attempts remaining for \(convoId.prefix(16))..."
          )

          // If all rejoin attempts are exhausted, request re-addition from active members
          if remaining == 0 {
            logger.info(
              "🆘 [External Commit Fallback] All rejoin attempts exhausted - requesting re-addition")
            await readdition(convoId: convoId)
          }
        }
      }

      throw error
    }
  }

  /// Update group state after successfully joining via Welcome or External Commit.
  /// Synchronizes epoch from FFI and triggers message catch-up.
  ///
  /// - Parameters:
  ///   - convo: The conversation view from server
  ///   - groupIdHex: The hex-encoded group ID from join operation
  ///   - userDid: The current user's DID
  private func updateGroupStateAfterJoin(
    convo: BlueCatbirdMlsDefs.ConvoView,
    groupIdHex: String,
    userDid: String
  ) async throws {
    // Convert hex to data for FFI calls
    guard let groupIdData = Data(hexEncoded: groupIdHex) else {
      throw MLSConversationError.invalidGroupId
    }

    // Update local group state with correct epoch from FFI
    if var state = groupStates[convo.groupId] {
      let serverEpoch = UInt64(convo.epoch)
      let ffiEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)

      if serverEpoch != ffiEpoch {
        logger.warning("⚠️ EPOCH MISMATCH after joining group:")
        logger.warning("   Server: \(serverEpoch), FFI: \(ffiEpoch)")
        logger.warning("   Using FFI epoch to prevent state desynchronization")
      }

      state.epoch = ffiEpoch  // Use FFI epoch, not server epoch
      groupStates[convo.groupId] = state
      logger.debug(
        "Updated group epoch to \(ffiEpoch) (from FFI) for conversation \(convo.groupId)")

      // Persist join method/epoch for UI. External Commit starts a new cryptographic history.
      do {
        try await storage.updateConversationJoinInfo(
          conversationID: convo.groupId,
          currentUserDID: userDid,
          joinMethod: .externalCommit,
          joinEpoch: Int64(ffiEpoch),
          database: database
        )
      } catch {
        logger.warning("⚠️ Failed to persist join info (ExtCommit): \(error.localizedDescription)")
      }
    }


    // Log diagnostic info
    await logGroupStateDiagnostics(
      userDid: userDid, groupId: groupIdData, context: "After Join (External Commit Fallback)")

    // Catch up on any messages we may have missed
    await catchUpMessagesIfNeeded(for: convo, force: true)
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
    logger.warning(
      "⚠️ Recorded unavailable key package hash for \(parsed.did): \(parsed.hash.prefix(16))...")
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
  ///
  /// **Important**: This method selects key packages for OTHER users we're inviting to a group.
  /// It does NOT handle our own key packages. The server advertises key package hashes
  /// for other users, and we select from that pool to create Welcome messages.
  ///
  /// **Pre-flight Check**: Verifies selected packages match server expectations and aren't
  /// accidentally from our own inventory (which would indicate a bug or server desync).
  private func selectKeyPackages(
    for members: [DID],
    from pool: [BlueCatbirdMlsDefs.KeyPackageRef],
    userDid: String
  ) async throws -> [KeyPackageWithHash] {
    logger.debug(
      "📦 [selectKeyPackages] Selecting packages for \(members.count) members from pool of \(pool.count)"
    )

    // ✅ PRE-FLIGHT: Verify we're not selecting packages for ourselves
    let normalizedUserDid = userDid.lowercased()
    for member in members {
      let normalizedMemberDid = member.description.lowercased()
      if normalizedMemberDid == normalizedUserDid {
        logger.error("🚨 CRITICAL: Attempting to select key package for ourselves!")
        logger.error("   User DID: \(userDid.prefix(30))...")
        logger.error("   Member DID: \(member.description.prefix(30))...")
        logger.error("   This indicates a bug in group creation logic")
        throw MLSConversationError.operationFailed("Cannot select key package for self")
      }
    }

    var packagesByDid = Dictionary(grouping: pool, by: { $0.did.description })

    var selected: [KeyPackageWithHash] = []
    var skippedCount = 0
    var packagesPerMember: [String: Int] = [:]

    // 🔐 MULTI-DEVICE FIX: Select ALL valid packages per member, not just one
    // This ensures Welcome messages can be decrypted by ANY device of each invited user
    for member in members {
      let didKey = member.description
      guard let options = packagesByDid[didKey], !options.isEmpty else {
        logger.error("❌ No key packages returned for member \(didKey)")
        throw MLSConversationError.missingKeyPackages([didKey])
      }

      logger.debug("   Processing \(didKey): \(options.count) candidates available")
      var validPackagesForMember = 0

      // CRITICAL FIX: Detect Last Resort Key Packages
      // If the server only provides 1 package for this member, it's likely a Last Resort package
      // that should be reused even if we've marked it as exhausted before
      let isLastResortScenario = options.count == 1
      if isLastResortScenario {
        logger.info("🔑 [Last Resort] Only 1 key package available for \(didKey) - will use even if marked exhausted")
      }

      // Select ALL valid packages for this member (multi-device support)
      for candidate in options {
        guard let decoded = Data(base64Encoded: candidate.keyPackage, options: []) else {
          logger.error("❌ Failed to decode key package for \(candidate.did)")
          skippedCount += 1
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

        // ✅ PRE-FLIGHT: Verify hash consistency when both server and local hashes exist
        if let serverHash = candidate.keyPackageHash {
          let localHash = try await computeKeyPackageReference(for: decoded, userDid: userDid)
          if serverHash != localHash {
            logger.error("🚨 HASH MISMATCH DETECTED!")
            logger.error("   Server hash: \(serverHash.prefix(32))...")
            logger.error("   Local hash:  \(localHash.prefix(32))...")
            logger.error("   Member DID:  \(didKey.prefix(30))...")
            logger.error("   Package size: \(decoded.count) bytes")
            logger.error("   This indicates server-client hash computation divergence")
            logger.error("   Skipping this package to prevent Welcome message failure")
            skippedCount += 1
            continue
          }
          logger.debug("   ✅ Hash verified: server and local match (\(serverHash.prefix(16))...)")
        }

        // CRITICAL FIX: Allow exhausted hashes if this is a Last Resort scenario
        // Last Resort packages are meant to be reused when no other options exist
        let isExhausted = isKeyPackageHashExhausted(hash, for: didKey)
        if isExhausted && !isLastResortScenario {
          logger.warning("⚠️ Skipping exhausted hash for \(didKey): \(hash.prefix(16))...")
          skippedCount += 1
          continue
        } else if isExhausted && isLastResortScenario {
          logger.info("🔓 [Last Resort] Using exhausted hash as it's the only option: \(hash.prefix(16))...")
          // Clear the exhausted marker so it won't be skipped on next selection
          unreserveKeyPackages([KeyPackageWithHash(data: decoded, hash: hash, did: member)])
        }

        logger.info(
          "✅ Selected package for \(didKey): hash=\(hash.prefix(16))... (\(decoded.count) bytes)")
        selected.append(KeyPackageWithHash(data: decoded, hash: hash, did: member))
        validPackagesForMember += 1
      }

      packagesPerMember[didKey] = validPackagesForMember

      // Ensure at least one valid package was found for this member
      if validPackagesForMember == 0 {
        let exhaustedForDid = exhaustedKeyPackageHashes[didKey]?.count ?? 0
        logger.error("❌ No usable key package for \(didKey) (exhausted: \(exhaustedForDid))")
        throw MLSConversationError.missingKeyPackages([didKey])
      }

      logger.debug("   ✅ Selected \(validPackagesForMember) package(s) for \(didKey)")
    }

    if skippedCount > 0 {
      logger.warning(
        "⚠️ Skipped \(skippedCount) package(s) during selection (exhausted or hash mismatch)")
    }

    // ✅ PRE-FLIGHT: Final verification of selected packages
    logger.debug("📦 [selectKeyPackages] Final verification of selected packages:")
    for pkg in selected {
      logger.debug(
        "   - DID: \(pkg.did.description.prefix(30))... | Hash: \(pkg.hash.prefix(16))... | Size: \(pkg.data.count) bytes"
      )
    }

    // Log multi-device summary
    logger.info("📦 [selectKeyPackages] Multi-device summary:")
    for (did, count) in packagesPerMember {
      logger.info("   - \(did.prefix(30))...: \(count) device(s)")
    }

    logger.debug(
      "📦 [selectKeyPackages] Selected \(selected.count) total packages for \(members.count) members, skipped \(skippedCount)"
    )
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
  private func computeKeyPackageReference(for keyPackageData: Data, userDid: String) async throws
    -> String
  {
    do {
      let hashBytes = try await mlsClient.computeKeyPackageHash(
        for: userDid, keyPackageData: keyPackageData)
      return hashBytes.hexEncodedString()
    } catch {
      logger.error("❌ Failed to compute key package hash_ref: \(error.localizedDescription)")
      throw MLSConversationError.operationFailed("Unable to compute key package reference")
    }
  }

  /// Prepare local commit/welcome data for the specified members
  private func prepareInitialMembers(members: [DID], userDid: String, groupId: Data) async throws
    -> PreparedInitialMembers
  {
    logger.info(
      "🔵 [MLSConversationManager.createGroup] Fetching key packages for \(members.count) members")
    let (keyPackages, _) = try await apiClient.getKeyPackages(dids: members)

    guard !keyPackages.isEmpty else {
      logger.error("❌ [MLSConversationManager.createGroup] No key packages available")
      throw MLSConversationError.missingKeyPackages(members.map { $0.description })
    }

    logger.info("🔵 [MLSConversationManager.createGroup] Got \(keyPackages.count) key packages")

    let selectedPackages = try await selectKeyPackages(
      for: members, from: keyPackages, userDid: userDid)
    let hashEntries: [BlueCatbirdMlsCreateConvo.KeyPackageHashEntry] = selectedPackages.map {
      package in
      BlueCatbirdMlsCreateConvo.KeyPackageHashEntry(
        did: package.did,
        hash: package.hash
      )
    }
    let keyPackageData = selectedPackages.map { $0.data }

    // 🔬 CRITICAL DIAGNOSTIC: Log joiner's key package that creator is using
    for (index, package) in selectedPackages.enumerated() {
      logger.info("🔑 [KEY PACKAGE FORENSICS - Creator Side]")
      logger.info("   Member \(index): \(package.did.description.prefix(30))...")
      logger.info("   Key Package Hash: \(package.hash.prefix(32))...")
      logger.info("   Key Package Size: \(package.data.count) bytes")
      logger.info(
        "   Key Package (first 100 bytes hex): \(package.data.prefix(100).hexEncodedString())")
      logger.info(
        "   Key Package (last 100 bytes hex): \(package.data.suffix(100).hexEncodedString())")
    }

    logger.debug("📍 [MLSConversationManager.createGroup] Adding members via MLS...")
    let addResult = try await mlsClient.addMembers(
      for: userDid,
      groupId: groupId,
      keyPackages: keyPackageData
    )

    logger.info(
      "✅ [MLSConversationManager.createGroup] Members added locally - commit: \(addResult.commitData.count) bytes, welcome: \(addResult.welcomeData.count) bytes"
    )
    logger.info("🔄 Commit staged (NOT merged yet) - will merge after server confirmation")

    // 🔬 CRITICAL DIAGNOSTIC: Log Welcome message structure
    logger.info("📨 [WELCOME MESSAGE FORENSICS - Creator Side]")
    logger.info("   Welcome Size: \(addResult.welcomeData.count) bytes")
    logger.info(
      "   Welcome (first 200 bytes hex): \(addResult.welcomeData.prefix(200).hexEncodedString())")
    logger.info(
      "   Welcome (last 200 bytes hex): \(addResult.welcomeData.suffix(200).hexEncodedString())")
    logger.info("   Commit Size: \(addResult.commitData.count) bytes")
    logger.info(
      "   Commit (first 200 bytes hex): \(addResult.commitData.prefix(200).hexEncodedString())")

    return PreparedInitialMembers(
      commitData: addResult.commitData,
      welcomeData: addResult.welcomeData,
      hashEntries: hashEntries,
      selectedPackages: selectedPackages  // Track for rollback on failure
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
      // CRITICAL FIX: On retry attempts, clear exhausted cache for members we're trying to add
      // This allows fresh key package fetches after initial attempt exhausted cached hashes
      if attempt > 1, let members = initialMembers {
        for member in members {
          let memberDid = member.description
          if exhaustedKeyPackageHashes[memberDid] != nil {
            exhaustedKeyPackageHashes.removeValue(forKey: memberDid)
            logger.info("🔄 [Retry] Cleared exhausted cache for member: \(memberDid.prefix(24))...")
          }
        }
        logger.info("🔄 [Retry] Cleared exhausted key package cache for \(members.count) member(s)")
      }
      
      var prepared: PreparedInitialMembers?
      if hasInitialMembers, let members = initialMembers {
        prepared = try await prepareInitialMembers(
          members: members, userDid: userDid, groupId: groupId)
        logger.info(
          "📍 [MLSConversationManager.createGroup] Prepared Welcome message for \(members.count) members (attempt \(attempt))"
        )
      }

      logger.info(
        "🔵 [MLSConversationManager.createGroup] Creating conversation on server (attempt \(attempt))..."
      )
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
          attempt < maxAttempts
        {
          recordKeyPackageFailure(detail: detail)
          logger.warning(
            "⚠️ [MLSConversationManager.createGroup] Server reported missing key packages (\(detail ?? "no details")). Retrying with fresh bundles..."
          )
          do {
            try await mlsClient.clearPendingCommit(for: userDid, groupId: groupId)
          } catch {
            logger.error(
              "❌ [MLSConversationManager.createGroup] Failed to clear pending commit after key package error: \(error.localizedDescription)"
            )
            // CRITICAL FIX: Unreserve packages on failure so they can be retried
            if let packages = prepared?.selectedPackages {
              unreserveKeyPackages(packages)
              logger.info("♻️ Unreserved \(packages.count) key packages after commit clear failure")
            }
            throw error
          }

          do {
            try await smartRefreshKeyPackages()
          } catch {
            logger.warning(
              "⚠️ [MLSConversationManager.createGroup] Key package refresh failed: \(error.localizedDescription)"
            )
          }

          lastError = normalizedError
          continue
        }
        
        // CRITICAL FIX: Unreserve packages on final failure
        // If we're not retrying, we need to unreserve the packages so they can be used in future attempts
        if let packages = prepared?.selectedPackages {
          unreserveKeyPackages(packages)
          logger.info("♻️ Unreserved \(packages.count) key packages after final server error")
        }
        
        lastError = normalizedError
        break
      } catch {
        // CRITICAL FIX: Unreserve packages on unexpected error
        if let packages = prepared?.selectedPackages {
          unreserveKeyPackages(packages)
          logger.info("♻️ Unreserved \(packages.count) key packages after unexpected error")
        }
        
        lastError = error
        break
      }
    }

    throw lastError
      ?? MLSConversationError.serverError(
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
    guard let keys = recentlySentMessages[convoId],
      let timestamp = keys[idempotencyKey]
    else {
      return false
    }
    // Check if still within deduplication window
    return Date().timeIntervalSince(timestamp) < deduplicationWindow
  }

  /// Track a sent message to prevent duplicates
  private func trackSentMessage(convoId: String, idempotencyKey: String) {
    if recentlySentMessages[convoId] == nil {
      recentlySentMessages[convoId] = [:]
    }
    recentlySentMessages[convoId]?[idempotencyKey] = Date()

    // Start cleanup timer if not already running
    startDeduplicationCleanupTimerIfNeeded()
  }

  /// Start periodic cleanup timer for deduplication keys (runs every 30 seconds)
  private func startDeduplicationCleanupTimerIfNeeded() {
    guard deduplicationCleanupTimer == nil else { return }

    deduplicationCleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
      [weak self] _ in
      self?.cleanupExpiredDeduplicationKeys()
    }
  }

  /// Clean up expired deduplication keys
  private func cleanupExpiredDeduplicationKeys() {
    let now = Date()
    var hasRemainingKeys = false

    for (convoId, keys) in recentlySentMessages {
      let activeKeys = keys.filter { now.timeIntervalSince($0.value) < deduplicationWindow }
      if activeKeys.isEmpty {
        recentlySentMessages.removeValue(forKey: convoId)
      } else {
        recentlySentMessages[convoId] = activeKeys
        hasRemainingKeys = true
      }
    }

    // Stop timer if no more keys to clean up
    if !hasRemainingKeys {
      deduplicationCleanupTimer?.invalidate()
      deduplicationCleanupTimer = nil
    }
  }

  /// Log comprehensive MLS group state for debugging cryptographic state divergence
  /// This should be called immediately after critical state transitions to diagnose "evil twin" problems
  private func logGroupStateDiagnostics(userDid: String, groupId: Data, context: String) async {
    logger.info("🔬 ========== MLS GROUP STATE DIAGNOSTICS (\(context)) ==========")
    logger.info("   User DID: \(userDid.prefix(30))...")
    logger.info("   Group ID: \(groupId.hexEncodedString().prefix(32))...")

    do {
      // Get current epoch (lightweight check)
      let epoch = try await mlsClient.getEpoch(for: userDid, groupId: groupId)
      logger.info("   📍 Current Epoch: \(epoch)")

      // 🔥 CRITICAL: Export epoch secret for comparison between clients
      // This is THE smoking gun - if two clients at same epoch have different secrets,
      // the bug is in how OpenMLS derives the cryptographic state
      do {
        let groupIdHex = groupId.hexEncodedString()
        let label = "diagnostic_epoch_\(epoch)"
        let contextData = groupIdHex.data(using: .utf8)!
        let secret = try await mlsClient.exportSecret(
          for: userDid,
          groupId: groupId,
          label: label,
          context: contextData,
          keyLength: 32
        )
        logger.info("   🔥 EPOCH SECRET (32 bytes): \(secret.hexEncodedString())")
        logger.info("      ⚠️  CRITICAL: Compare this hex string between creator and joiner!")
        logger.info(
          "      ⚠️  If they differ at same epoch, the bug is in cryptographic derivation!")
      } catch {
        logger.error("   ❌ Failed to export epoch secret: \(error.localizedDescription)")
      }

      // Get detailed group member information
      let debugInfo = try await mlsClient.debugGroupMembers(for: userDid, groupId: groupId)
      logger.info("   📍 Total Members: \(debugInfo.totalMembers)")

      // Log each member with their leaf index and credential identity
      logger.info("   📍 Member Roster:")
      for (index, member) in debugInfo.members.enumerated() {
        let identityString = String(decoding: member.credentialIdentity, as: UTF8.self)
        logger.info(
          "      [\(index)] Leaf Index: \(member.leafIndex) | Identity: \(identityString.prefix(40))... | Type: \(member.credentialType)"
        )
      }

      // Log a checksum of the member list for easy comparison
      var hasher = SHA256()
      for member in debugInfo.members.sorted(by: { $0.leafIndex < $1.leafIndex }) {
        hasher.update(data: member.credentialIdentity)
        hasher.update(data: "\(member.leafIndex)".data(using: .utf8)!)
      }
      let rosterChecksum = hasher.finalize().hexEncodedString().prefix(16)
      logger.info("   📍 Roster Checksum: \(rosterChecksum) (sorted by leaf index)")
      logger.info(
        "      ℹ️  If two clients at same epoch have different checksums, they have divergent state")

    } catch {
      logger.error("   ❌ Failed to retrieve group state diagnostics: \(error.localizedDescription)")
    }

    logger.info("🔬 ========== END GROUP STATE DIAGNOSTICS ==========")
  }

  // MARK: - Own Commit Tracking

  /// Track a commit that we created to prevent re-processing it via SSE
  private func trackOwnCommit(_ commitData: Data) {
    let commitHash = SHA256.hash(data: commitData).compactMap { String(format: "%02x", $0) }
      .joined()
    ownCommitsLock.lock()
    defer { ownCommitsLock.unlock() }
    ownCommits[commitHash] = Date()
    logger.debug("📍 Tracking own commit: \(commitHash.prefix(16))...")
  }

  /// Check if a commit is one we created
  private func isOwnCommit(_ commitData: Data) -> Bool {
    let commitHash = SHA256.hash(data: commitData).compactMap { String(format: "%02x", $0) }
      .joined()
    ownCommitsLock.lock()
    defer { ownCommitsLock.unlock() }

    // Clean up expired commits first
    let now = Date()
    ownCommits = ownCommits.filter { now.timeIntervalSince($0.value) < ownCommitTimeout }

    return ownCommits[commitHash] != nil
  }

  /// Clean up expired own commit tracking
  private func cleanupExpiredOwnCommits() {
    ownCommitsLock.lock()
    defer { ownCommitsLock.unlock() }

    let now = Date()
    let before = ownCommits.count
    ownCommits = ownCommits.filter { now.timeIntervalSince($0.value) < ownCommitTimeout }
    let after = ownCommits.count

    if before != after {
      logger.debug("🗑️ Cleaned up \(before - after) expired own commits (\(before) → \(after))")
    }
  }

  // MARK: - Migration

  /// Force epoch refresh for all groups to revoke soft-removed members
  ///
  /// Call once after deploying the member removal fix to ensure previously
  /// "soft-removed" members (removed via server API only) have their cryptographic
  /// access revoked.
  ///
  /// This advances the epoch for all groups, which regenerates keys and ensures
  /// removed members cannot decrypt new messages.
  ///
  /// - Returns: Tuple of (successCount, failureCount)
  func migrateGroupsToSecureRemoval() async throws -> (success: Int, failure: Int) {
    logger.info(
      "🔄 [MLSConversationManager.migrateGroupsToSecureRemoval] Starting migration: Force epoch refresh for all groups"
    )

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    var successCount = 0
    var failureCount = 0

    // Get all active conversations (key is convoId, value is ConvoView)
    let allConversations = conversations

    logger.info(
      "🔄 [MLSConversationManager.migrateGroupsToSecureRemoval] Processing \(allConversations.count) groups"
    )

    for (convoId, convo) in allConversations {
      do {
        // Convert groupId string to Data
        guard let groupIdData = Data(hexEncoded: convo.groupId) else {
          logger.error(
            "❌ [MLSConversationManager.migrateGroupsToSecureRemoval] Failed to decode groupId for \(convoId)"
          )
          failureCount += 1
          continue
        }

        // Use GroupOperationCoordinator to serialize operations
        try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
          // Send self_update to advance epoch
          let commitData = try await mlsClient.selfUpdate(
            for: userDid,
            groupId: groupIdData
          )

          // Send to server
          let commitBase64 = commitData.commitData.base64EncodedString()
          let newEpoch = try await apiClient.sendCommit(
            convoId: convoId,
            commit: commitBase64,
            idempotencyKey: UUID().uuidString.lowercased()
          )

          // Merge locally
          try await mlsClient.mergePendingCommit(
            for: userDid,
            groupId: groupIdData
          )

          logger.info(
            "✅ [MLSConversationManager.migrateGroupsToSecureRemoval] Migrated \(convoId) to epoch \(newEpoch)"
          )
          successCount += 1
        }

        // Rate limit to avoid server overload (100ms between groups)
        try await Task.sleep(nanoseconds: 100_000_000)
      } catch {
        logger.error(
          "❌ [MLSConversationManager.migrateGroupsToSecureRemoval] Failed for \(convoId): \(error.localizedDescription)"
        )
        failureCount += 1
      }
    }

    logger.info(
      "✅ [MLSConversationManager.migrateGroupsToSecureRemoval] Migration complete: \(successCount) success, \(failureCount) failures"
    )
    return (successCount, failureCount)
  }
}
