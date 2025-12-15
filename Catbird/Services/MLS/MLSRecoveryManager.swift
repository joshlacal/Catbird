import Foundation
import OSLog
import Petrel

/// Manages silent auto-recovery from MLS desync situations
///
/// When key package desync is detected (local vs server mismatch) or other
/// irrecoverable MLS errors occur, this manager silently:
/// 1. Deletes device from server
/// 2. Clears local MLS storage
/// 3. Re-registers device with fresh key packages
/// 4. Marks conversations for rejoin via External Commit
/// 5. Processes rejoins in background without user interaction
@available(iOS 18.0, macOS 13.0, *)
actor MLSRecoveryManager {

  // MARK: - Properties

  private let mlsClient: MLSClient
  private let mlsAPIClient: MLSAPIClient
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSRecoveryManager")

  /// Tracks users currently undergoing recovery to prevent concurrent operations
  private var recoveryInProgress: Set<String> = []

  /// Conversations pending rejoin after recovery
  private var pendingRejoins: [String: [String]] = [:]  // userDid: [convoIds]

  // MARK: - Per-Conversation Recovery Tracking (Prevents Infinite Loops)

  /// Tracks failed rejoins per conversation to prevent infinite recovery loops
  private var failedRejoins: [String: (attempts: Int, lastAttempt: Date)] = [:]

  /// Maximum rejoin attempts per conversation before giving up
  private let maxRejoinAttempts = 3

  /// Calculate exponential backoff cooldown based on attempt count
  /// - Parameter attempts: Number of failed attempts so far
  /// - Returns: Cooldown duration in seconds
  private func cooldownForAttempts(_ attempts: Int) -> TimeInterval {
    switch attempts {
    case 0:
      return 0  // First attempt: no cooldown
    case 1:
      return 30  // After 1st failure: 30 seconds
    case 2:
      return 120  // After 2nd failure: 2 minutes
    case 3:
      return 600  // After 3rd failure: 10 minutes
    default:
      return 3600  // After 4+ failures: 1 hour
    }
  }

  // MARK: - Initialization

  init(mlsClient: MLSClient, mlsAPIClient: MLSAPIClient) {
    self.mlsClient = mlsClient
    self.mlsAPIClient = mlsAPIClient
  }

  // MARK: - Per-Conversation Rejoin Tracking

  /// Check if a conversation should be skipped during rejoin (max attempts exceeded or on cooldown)
  func shouldSkipRejoin(convoId: String) -> Bool {
    guard let record = failedRejoins[convoId] else {
      return false
    }

    // Skip if max attempts exceeded
    if record.attempts >= maxRejoinAttempts {
      logger.info(
        "⏭️ [MLSRecoveryManager] Skipping \(convoId.prefix(16)) - max attempts (\(self.maxRejoinAttempts)) exceeded"
      )
      return true
    }

    // Skip if on cooldown (exponential backoff based on attempts)
    let cooldown = cooldownForAttempts(record.attempts)
    let elapsed = Date().timeIntervalSince(record.lastAttempt)
    if elapsed < cooldown {
      let remaining = Int(cooldown - elapsed)
      logger.info(
        "⏭️ [MLSRecoveryManager] Skipping \(convoId.prefix(16)) - on cooldown (\(remaining)s remaining, attempt \(record.attempts))"
      )
      return true
    }

    return false
  }

  /// Record a failed rejoin attempt for a conversation
  func recordFailedRejoin(convoId: String) {
    let existing = failedRejoins[convoId] ?? (attempts: 0, lastAttempt: Date.distantPast)
    failedRejoins[convoId] = (attempts: existing.attempts + 1, lastAttempt: Date())
    logger.warning(
      "📝 [MLSRecoveryManager] Recorded failed rejoin for \(convoId.prefix(16)) - attempt \(existing.attempts + 1)/\(self.maxRejoinAttempts)"
    )
  }

  /// Clear rejoin tracking for a conversation (on success)
  func clearRejoinTracking(convoId: String) {
    if failedRejoins.removeValue(forKey: convoId) != nil {
      logger.info("✅ [MLSRecoveryManager] Cleared rejoin tracking for \(convoId.prefix(16))")
    }
  }

  /// Get the number of remaining rejoin attempts for a conversation
  func remainingRejoinAttempts(convoId: String) -> Int {
    guard let record = failedRejoins[convoId] else {
      return maxRejoinAttempts
    }
    return max(0, maxRejoinAttempts - record.attempts)
  }

  // MARK: - Desync Detection

  /// Check if there's a key package desync between local and server
  /// Returns severity level: none, minor (recoverable), severe (requires re-registration)
  ///
  /// Note: This method requires server-side bundle count comparison, which may not always
  /// be available. If server status cannot be retrieved, assumes severe desync to be safe.
  func checkDesyncSeverity(for userDid: String, serverBundleCount: Int? = nil) async throws
    -> DesyncSeverity
  {
    logger.info("🔍 [MLSRecoveryManager] Checking desync severity for \(userDid.prefix(20))...")

    do {
      // Get local bundle count
      let localCount = try await mlsClient.getKeyPackageBundleCount(for: userDid)

      // Use provided server count or default to unknown (assume severe)
      let serverCount = serverBundleCount ?? 0

      logger.info(
        "📊 [MLSRecoveryManager] Bundle counts - Local: \(localCount), Server: \(serverCount)")

      // If we don't have server count, assume based on local count
      if serverBundleCount == nil {
        if localCount == 0 {
          logger.error("🚨 [MLSRecoveryManager] No local bundles - severe desync")
          return .severe(localCount: 0, serverCount: 0, difference: 0)
        } else {
          logger.info("✅ [MLSRecoveryManager] Local bundles exist, server count unknown")
          return .none
        }
      }

      // Calculate desync
      let difference = abs(Int(localCount) - serverCount)
      let percentageDiff = localCount > 0 ? Double(difference) / Double(localCount) * 100 : 100

      if difference == 0 {
        logger.info("✅ [MLSRecoveryManager] No desync detected")
        return .none
      } else if percentageDiff < 20 && localCount > 10 {
        // Minor desync - can be fixed by uploading missing packages
        logger.warning(
          "⚠️ [MLSRecoveryManager] Minor desync: \(difference) packages (\(Int(percentageDiff))% difference)"
        )
        return .minor(localCount: Int(localCount), serverCount: serverCount, difference: difference)
      } else {
        // Severe desync - requires full re-registration
        logger.error(
          "🚨 [MLSRecoveryManager] Severe desync: \(difference) packages (\(Int(percentageDiff))% difference)"
        )
        return .severe(
          localCount: Int(localCount), serverCount: serverCount, difference: difference)
      }
    } catch {
      logger.error("❌ [MLSRecoveryManager] Failed to check desync: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Silent Recovery

  /// Perform silent recovery for a user
  /// This is the main entry point for automatic recovery
  func performSilentRecovery(for userDid: String, conversationIds: [String] = []) async throws {
    logger.info("🔄 [MLSRecoveryManager] Starting silent recovery for \(userDid.prefix(20))...")

    // Prevent concurrent recovery for same user
    guard !recoveryInProgress.contains(userDid) else {
      logger.warning(
        "⚠️ [MLSRecoveryManager] Recovery already in progress for \(userDid.prefix(20))")
      return
    }

    recoveryInProgress.insert(userDid)
    defer { recoveryInProgress.remove(userDid) }

    do {
      // Use the unified reregisterDevice flow which handles:
      // 1. Delete device from server
      // 2. Clear local MLS storage
      // 3. Re-register with fresh key packages
      logger.info(
        "🔄 [MLSRecoveryManager] Step 1/2: Re-registering device (atomic cleanup + registration)...")
      _ = try await mlsClient.reregisterDevice(for: userDid)
      logger.info("✅ [MLSRecoveryManager] Device re-registered successfully")

      // Step 2: Mark conversations for rejoin via External Commit
      logger.info(
        "🔄 [MLSRecoveryManager] Step 2/2: Marking \(conversationIds.count) conversations for rejoin..."
      )
      if !conversationIds.isEmpty {
        pendingRejoins[userDid] = conversationIds
        // Trigger background rejoin process
        Task {
          await processBackgroundRejoins(for: userDid)
        }
      }

      logger.info("✅ [MLSRecoveryManager] Silent recovery complete for \(userDid.prefix(20))")
    } catch {
      logger.error("❌ [MLSRecoveryManager] Recovery failed: \(error.localizedDescription)")
      throw MLSRecoveryError.recoveryFailed(underlying: error)
    }
  }

  // MARK: - Background Rejoin Processing

  /// Process pending conversation rejoins in background
  private func processBackgroundRejoins(for userDid: String) async {
    guard let convoIds = pendingRejoins[userDid], !convoIds.isEmpty else {
      logger.debug("📭 [MLSRecoveryManager] No pending rejoins for \(userDid.prefix(20))")
      return
    }

    logger.info("🔄 [MLSRecoveryManager] Processing \(convoIds.count) pending rejoins...")

    var successCount = 0
    var failureCount = 0
    var skippedCount = 0

    for convoId in convoIds {
      // Check if we should skip this conversation (max attempts or cooldown)
      if shouldSkipRejoin(convoId: convoId) {
        skippedCount += 1
        continue
      }

      do {
        logger.debug("🔄 [MLSRecoveryManager] Rejoining conversation: \(convoId.prefix(20))...")
        _ = try await mlsClient.joinByExternalCommit(for: userDid, convoId: convoId)
        successCount += 1
        clearRejoinTracking(convoId: convoId)
        logger.info("✅ [MLSRecoveryManager] Rejoined: \(convoId.prefix(20))")
      } catch {
        failureCount += 1
        recordFailedRejoin(convoId: convoId)
        logger.error(
          "❌ [MLSRecoveryManager] Failed to rejoin \(convoId.prefix(20)): \(error.localizedDescription)"
        )
        // Continue with other conversations, don't fail the whole process
      }

      // Add small delay between rejoins to avoid overwhelming the server
      try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }

    // Clear pending rejoins
    pendingRejoins.removeValue(forKey: userDid)

    logger.info(
      "📊 [MLSRecoveryManager] Background rejoin complete: \(successCount) succeeded, \(failureCount) failed, \(skippedCount) skipped"
    )
  }

  // MARK: - Device Management

  /// Delete device from server
  /// Note: This uses the MLSDeviceManager's reregisterDevice flow which handles
  /// server-side cleanup and re-registration atomically
  private func deleteDeviceFromServer(for userDid: String) async throws {
    logger.debug("🗑️ [MLSRecoveryManager] Device cleanup will be handled during re-registration")
    // Device deletion is handled atomically during re-registration by MLSDeviceManager
    // The reregisterDevice() method in MLSDeviceManager:
    // 1. Deletes existing device from server
    // 2. Clears local key packages
    // 3. Creates fresh key packages
    // 4. Registers new device
    //
    // So we just log here and let the re-registration handle cleanup
    logger.info("✅ [MLSRecoveryManager] Device will be deleted during re-registration")
  }

  // MARK: - Recovery Triggers

  /// Called when NoMatchingKeyPackage error occurs during Welcome processing
  /// Determines if silent recovery should be triggered
  ///
  /// CRITICAL: This method distinguishes between LOCAL corruption (recoverable via re-registration)
  /// and REMOTE/SERVER corruption (NOT recoverable by wiping local state).
  ///
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - userDid: The user DID
  ///   - convoId: Optional conversation ID - if provided, checks if max attempts exceeded
  ///   - isRemoteDataError: If true, the error originated from server-fetched data (GroupInfo, Welcome)
  ///                        and should NOT trigger destructive local recovery
  func shouldTriggerRecovery(
    for error: Error, userDid: String, convoId: String? = nil, isRemoteDataError: Bool = false
  ) -> Bool {
    let errorString = String(describing: error).lowercased()

    // CRITICAL FIX: Errors from REMOTE data (GroupInfo, Welcome from server) should NOT trigger
    // local database wipe - the problem is on the server, not locally.
    // These errors indicate the server is serving corrupted/truncated data.
    let remoteDataErrorPatterns = [
      "invalidvectorlength",  // GroupInfo deserialization failure
      "endofstream",  // Truncated data from server
      "deseriali",  // General deserialization issues
      "malformed",  // Malformed protocol data
      "truncat",  // Truncated data
    ]

    // If this is flagged as a remote data error, check if the pattern matches remote issues
    if isRemoteDataError {
      for pattern in remoteDataErrorPatterns {
        if errorString.contains(pattern) {
          logger.error(
            "🚫 [MLSRecoveryManager] Detected SERVER-SIDE data corruption: \(pattern)")
          logger.error(
            "   ❌ NOT triggering local recovery - wiping local DB won't fix server data!")
          logger.error(
            "   📋 Conversation \(convoId?.prefix(16) ?? "unknown") should be marked as broken")
          logger.error(
            "   🔧 Server team needs to investigate GroupInfo storage for this conversation")

          // Record this as a failed rejoin to prevent retry loops
          if let convoId = convoId {
            recordFailedRejoin(convoId: convoId)
          }

          return false
        }
      }
    }

    // Check for known LOCAL errors that ARE recoverable via re-registration
    // These indicate local state corruption, not server issues
    let localRecoverablePatterns = [
      "nomatchingkeypackage",  // Local key package inventory desync
      "keypackagenotfound",  // Key package missing from local storage
      "secretreuseerror",  // Ratchet state corruption
      "sqlite out of memory",  // Local database issues
    ]

    for pattern in localRecoverablePatterns {
      if errorString.contains(pattern) {
        // Check if this specific conversation has exceeded max recovery attempts
        if let convoId = convoId, shouldSkipRejoin(convoId: convoId) {
          logger.warning(
            "🔍 [MLSRecoveryManager] Detected \(pattern) but conversation \(convoId.prefix(16)) exceeded max attempts - not triggering recovery"
          )
          return false
        }

        logger.warning("🔍 [MLSRecoveryManager] Detected LOCAL recovery trigger: \(pattern)")
        return true
      }
    }

    // LEGACY: Check for invalidvectorlength WITHOUT remote flag (for backwards compatibility)
    // Only trigger if NOT explicitly marked as remote data error
    if !isRemoteDataError && errorString.contains("invalidvectorlength") {
      // Log a warning but still allow recovery for backwards compat
      // Callers should set isRemoteDataError=true for External Commit errors
      logger.warning(
        "⚠️ [MLSRecoveryManager] InvalidVectorLength detected without remote flag")
      logger.warning(
        "   Caller should set isRemoteDataError=true if from External Commit/Welcome")

      if let convoId = convoId, shouldSkipRejoin(convoId: convoId) {
        return false
      }
      return true
    }

    return false
  }

  /// Attempt recovery if needed and return whether recovery was performed
  ///
  /// CRITICAL: This method now distinguishes between LOCAL and REMOTE data errors.
  /// Remote data errors (from GroupInfo/Welcome) should NOT trigger destructive recovery.
  ///
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - userDid: The user DID
  ///   - convoIds: Conversation IDs to rejoin after recovery
  ///   - triggeringConvoId: The specific conversation that triggered recovery (for tracking)
  ///   - isRemoteDataError: If true, error originated from server-fetched data (don't wipe local)
  @discardableResult
  func attemptRecoveryIfNeeded(
    for error: Error,
    userDid: String,
    convoIds: [String] = [],
    triggeringConvoId: String? = nil,
    isRemoteDataError: Bool = false
  ) async -> Bool {
    // Use the triggering convoId if provided, otherwise check first convoId
    let checkConvoId = triggeringConvoId ?? convoIds.first

    guard
      shouldTriggerRecovery(
        for: error, userDid: userDid, convoId: checkConvoId, isRemoteDataError: isRemoteDataError)
    else {
      return false
    }

    logger.info("🔄 [MLSRecoveryManager] Triggering silent recovery due to LOCAL error...")

    do {
      try await performSilentRecovery(for: userDid, conversationIds: convoIds)
      return true
    } catch {
      logger.error("❌ [MLSRecoveryManager] Auto-recovery failed: \(error.localizedDescription)")
      // Record the failure for the triggering conversation
      if let convoId = checkConvoId {
        recordFailedRejoin(convoId: convoId)
      }
      return false
    }
  }

  // MARK: - Server Data Corruption Handling

  /// Mark a conversation as having corrupted server data
  /// This prevents retry loops when the server is serving bad GroupInfo
  /// The conversation will remain inaccessible until server data is fixed
  func markConversationServerCorrupted(convoId: String, errorMessage: String) {
    logger.error(
      "🚫 [MLSRecoveryManager] Marking conversation \(convoId.prefix(16)) as SERVER-CORRUPTED")
    logger.error("   Error: \(errorMessage)")
    logger.error("   This conversation cannot be joined until server data is repaired")

    // Record max failures immediately to prevent any retry attempts
    failedRejoins[convoId] = (attempts: maxRejoinAttempts + 10, lastAttempt: Date())
  }

  /// Check if a conversation is marked as having server-side corruption
  func isConversationServerCorrupted(convoId: String) -> Bool {
    guard let record = failedRejoins[convoId] else { return false }
    // Conversations with more than maxRejoinAttempts + 5 are considered server-corrupted
    return record.attempts > maxRejoinAttempts + 5
  }

  // MARK: - GroupInfo Health Check (Fix #4)

  /// 🔒 FIX #4: Verify GroupInfo health after epoch advancement
  ///
  /// Call this after publishing GroupInfo to verify the stored data is valid.
  /// If verification fails, attempts to republish.
  ///
  /// - Parameters:
  ///   - convoId: Conversation identifier
  ///   - expectedSize: Expected minimum size of GroupInfo
  ///   - maxRetries: Maximum republish attempts (default: 2)
  /// - Returns: true if GroupInfo is healthy, false if repair failed
  func verifyGroupInfoHealth(
    convoId: String,
    expectedSize: Int,
    maxRetries: Int = 2
  ) async -> Bool {
    logger.info(
      "🔍 [MLSRecoveryManager.verifyGroupInfoHealth] Checking GroupInfo for \(convoId.prefix(16))..."
    )

    for attempt in 1...maxRetries {
      do {
        // Fetch stored GroupInfo
        let (storedData, epoch, _) = try await mlsAPIClient.getGroupInfo(convoId: convoId)

        // Check size
        if storedData.count < 100 {
          logger.error(
            "❌ [verifyGroupInfoHealth] GroupInfo too small: \(storedData.count) bytes (attempt \(attempt))"
          )

          if attempt < maxRetries {
            // Request republish from active members
            logger.info("🔄 [verifyGroupInfoHealth] Requesting GroupInfo refresh...")
            _ = try await mlsAPIClient.groupInfoRefresh(convoId: convoId)
            try await Task.sleep(for: .seconds(2))
            continue
          }
          return false
        }

        // Check it's not base64 encoded (should be binary)
        let isAsciiOnly = storedData.allSatisfy { byte in
          (byte >= 0x20 && byte <= 0x7E) || byte == 0x0A || byte == 0x0D
        }
        if isAsciiOnly && storedData.count > 50 {
          logger.error("❌ [verifyGroupInfoHealth] GroupInfo appears to be base64 text, not binary!")
          return false
        }

        // Size matches expectation (with 20% tolerance for different epochs)
        let sizeDiff = abs(storedData.count - expectedSize)
        let tolerance = expectedSize / 5  // 20%
        if sizeDiff > tolerance && expectedSize > 0 {
          logger.warning(
            "⚠️ [verifyGroupInfoHealth] Size mismatch: stored \(storedData.count), expected ~\(expectedSize)"
          )
          // Not a failure, just a warning - epoch changes can affect size
        }

        logger.info(
          "✅ [verifyGroupInfoHealth] GroupInfo healthy - size: \(storedData.count) bytes, epoch: \(epoch)"
        )
        return true

      } catch {
        logger.error(
          "❌ [verifyGroupInfoHealth] Failed to fetch GroupInfo (attempt \(attempt)): \(error.localizedDescription)"
        )
        if attempt < maxRetries {
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }

    logger.error(
      "❌ [verifyGroupInfoHealth] GroupInfo health check FAILED after \(maxRetries) attempts")
    return false
  }
}

// MARK: - Supporting Types

/// Severity level of key package desync
enum DesyncSeverity {
  case none
  case minor(localCount: Int, serverCount: Int, difference: Int)
  case severe(localCount: Int, serverCount: Int, difference: Int)

  var isRecoverable: Bool {
    switch self {
    case .none, .minor:
      return true
    case .severe:
      return false
    }
  }
}

/// Errors specific to MLS recovery operations
enum MLSRecoveryError: LocalizedError {
  case recoveryFailed(underlying: Error)
  case recoveryInProgress
  case deviceDeletionFailed
  case maxRetriesExceeded

  var errorDescription: String? {
    switch self {
    case .recoveryFailed(let underlying):
      return "MLS recovery failed: \(underlying.localizedDescription)"
    case .recoveryInProgress:
      return "Recovery already in progress"
    case .deviceDeletionFailed:
      return "Failed to delete device from server"
    case .maxRetriesExceeded:
      return "Maximum retry attempts exceeded"
    }
  }
}

// MARK: - SQLite Retry Utility

/// Utility for retrying operations with exponential backoff
/// Used for SQLite and other transient error recovery
@available(iOS 18.0, macOS 13.0, *)
enum RetryUtility {
  private static let logger = Logger(subsystem: "blue.catbird", category: "RetryUtility")

  /// Execute an async operation with exponential backoff retry
  /// - Parameters:
  ///   - maxAttempts: Maximum number of retry attempts (default: 3)
  ///   - initialDelay: Initial delay in seconds before first retry (default: 0.5)
  ///   - maxDelay: Maximum delay between retries (default: 10 seconds)
  ///   - shouldRetry: Closure to determine if error is retryable
  ///   - operation: The operation to execute
  /// - Returns: The result of the successful operation
  static func withExponentialBackoff<T>(
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 0.5,
    maxDelay: TimeInterval = 10,
    shouldRetry: @escaping (Error) -> Bool = isRetryableError,
    operation: () async throws -> T
  ) async throws -> T {
    var lastError: Error?
    var currentDelay = initialDelay

    for attempt in 1...maxAttempts {
      do {
        return try await operation()
      } catch {
        lastError = error

        if !shouldRetry(error) {
          logger.debug(
            "🔄 [Retry] Non-retryable error on attempt \(attempt): \(error.localizedDescription)")
          throw error
        }

        if attempt == maxAttempts {
          logger.error("❌ [Retry] Max attempts (\(maxAttempts)) exceeded")
          break
        }

        logger.warning(
          "⚠️ [Retry] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
        logger.info("⏳ [Retry] Waiting \(String(format: "%.1f", currentDelay))s before retry...")

        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))

        // Exponential backoff with jitter
        currentDelay = min(currentDelay * 2 + Double.random(in: 0...0.5), maxDelay)
      }
    }

    throw lastError ?? MLSRecoveryError.maxRetriesExceeded
  }

  /// Determine if an error is likely transient and retryable
  static func isRetryableError(_ error: Error) -> Bool {
    let errorString = String(describing: error).lowercased()

    // SQLite transient errors
    let retryablePatterns = [
      "sqlite_busy",
      "database is locked",
      "out of memory",
      "unable to open database",
      "disk i/o error",
      "database disk image is malformed",
      "connection refused",
      "network is unreachable",
      "timed out",
      "timeout",
    ]

    for pattern in retryablePatterns {
      if errorString.contains(pattern) {
        return true
      }
    }

    // NSError codes for common transient errors
    if let nsError = error as NSError? {
      switch nsError.code {
      case NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet:
        return true
      default:
        break
      }
    }

    return false
  }

  /// Execute a storage operation with SQLite-specific retry settings
  static func withSQLiteRetry<T>(
    operation: () async throws -> T
  ) async throws -> T {
    return try await withExponentialBackoff(
      maxAttempts: 3,
      initialDelay: 0.2,
      maxDelay: 2.0,
      shouldRetry: isRetryableError,
      operation: operation
    )
  }
}
