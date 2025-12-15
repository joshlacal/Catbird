import Foundation
import OSLog
import Petrel
import CatbirdMLSCore

/// Manages automatic synchronization of new devices to MLS conversations.
/// When a user registers a new device, this manager coordinates adding that device
/// to all conversations the user is a member of.
///
/// Flow:
/// 1. New device registers via blue.catbird.mls.registerDevice
/// 2. Server creates pending_device_additions for each conversation
/// 3. Server emits NewDeviceEvent via SSE to conversation members
/// 4. Online members receive event and attempt to claim the pending addition
/// 5. First claimer fetches key package and adds device via addMembers
/// 6. Claimer marks addition complete, or device self-joins via external commit
@available(iOS 18.0, macOS 13.0, *)
actor MLSDeviceSyncManager {

    // MARK: - Properties

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSDeviceSyncManager")
    private let apiClient: MLSAPIClient
    private let mlsClient: MLSClient

    /// Callback to add a device to a conversation (provided by MLSConversationManager)
    private var addDeviceHandler: ((String, String, Data) async throws -> Int)?

    /// Track pending additions we're currently processing to avoid duplicates
    private var processingAdditions: Set<String> = []

    /// Track additions we've recently completed to avoid re-processing
    private var recentlyCompletedAdditions: Set<String> = []
    private let completedAdditionsTTL: TimeInterval = 300 // 5 minutes

    /// Current user's DID for filtering (don't add our own devices)
    private var currentUserDid: String?

    /// Current device's UUID for filtering (skip adding THIS device, but add other devices of same user)
    private var currentDeviceUUID: String?

    /// Track failed additions for External Commit fallback
    private var failedAdditions: [String: FailedAddition] = [:]

    /// Fallback timers for External Commit triggering
    private var fallbackTimers: [String: Task<Void, Never>] = [:]
    private let fallbackTimeout: TimeInterval = 30

    /// Polling task for fallback synchronization
    private var pollingTask: Task<Void, Never>?
    private var isPollingEnabled: Bool = false

    // MARK: - Types

    /// Tracks a failed addition for potential External Commit fallback
    struct FailedAddition {
        let pendingId: String
        let deviceDid: String?
        let convoId: String
        let timestamp: Date
        let error: String
    }

    // MARK: - Initialization

    init(apiClient: MLSAPIClient, mlsClient: MLSClient) {
        self.apiClient = apiClient
        self.mlsClient = mlsClient
    }

    // MARK: - Configuration

    /// Configure the manager with the current user and device addition handler
    /// - Parameters:
    ///   - userDid: Current user's DID (base DID without device suffix, e.g., "did:plc:abc123")
    ///   - deviceUUID: Current device's UUID (to avoid adding THIS device to conversations)
    ///   - addDeviceHandler: Callback to add a device to a conversation
    ///                       Parameters: (convoId, deviceCredentialDid, keyPackageData) -> newEpoch
    func configure(
        userDid: String,
        deviceUUID: String? = nil,
        addDeviceHandler: @escaping (String, String, Data) async throws -> Int
    ) {
        self.currentUserDid = userDid
        self.currentDeviceUUID = deviceUUID
        self.addDeviceHandler = addDeviceHandler
        logger.info("MLSDeviceSyncManager configured for user: \(userDid.prefix(20)), device: \(deviceUUID ?? "unknown")")
    }

    // MARK: - SSE Event Handling

    /// Handle a new device event received via SSE
    /// This is called when another device in a conversation comes online
    /// - Parameter event: The new device event from the SSE stream
    func handleNewDeviceEvent(_ event: BlueCatbirdMlsStreamConvoEvents.NewDeviceEvent) async {
        let pendingId = event.pendingAdditionId

        logger.info("📱 [NewDeviceEvent] Received for convo=\(event.convoId), user=\(event.userDid), device=\(event.deviceId)")

        // Skip if this is our own device
        if let currentUser = currentUserDid, event.userDid.didString() == currentUser {
            // Check if this is a different device from current user
            // We should still add other devices from the same user
            logger.info("   New device belongs to current user - will attempt to add")
        }

        // Skip if already processing or recently completed
        if processingAdditions.contains(pendingId) {
            logger.debug("   Already processing this pending addition")
            return
        }

        if recentlyCompletedAdditions.contains(pendingId) {
            logger.debug("   Recently completed this pending addition")
            return
        }

        // Process the pending addition
        await processPendingAddition(pendingId: pendingId, convoId: event.convoId)
    }

    // MARK: - Pending Addition Processing

    /// Process a single pending device addition
    /// - Parameters:
    ///   - pendingId: The pending addition ID
    ///   - convoId: The conversation ID
    private func processPendingAddition(pendingId: String, convoId: String) async {
        guard let addDevice = addDeviceHandler else {
            logger.warning("⚠️ No addDeviceHandler configured - skipping pending addition")
            return
        }

        // Mark as processing
        processingAdditions.insert(pendingId)
        defer { processingAdditions.remove(pendingId) }

        logger.info("🔄 [ProcessPendingAddition] Attempting to claim: \(pendingId)")

        do {
            // Step 1: Claim the pending addition
            let claimResult = try await apiClient.claimPendingDeviceAddition(pendingAdditionId: pendingId)

            if !claimResult.claimed {
                // Check if this was a self-claim attempt (server returns no claimedBy + deviceCredentialDid matches our user)
                // When claimedBy is nil and we still have deviceCredentialDid, it's a self-claim
                if claimResult.claimedBy == nil && claimResult.deviceCredentialDid != nil {
                    let baseDid = extractBaseDid(from: claimResult.deviceCredentialDid!)
                    if baseDid == currentUserDid {
                        logger.info("   This is our own device addition - skipping (we can't add ourselves)")
                        markAsCompleted(pendingId)  // Mark locally so we don't retry
                        return
                    }
                }
                logger.info("   Another device already claimed this addition (claimed by: \(claimResult.claimedBy?.didString() ?? "unknown"))")
                return
            }

            guard let deviceDid = claimResult.deviceCredentialDid else {
                logger.warning("   Claimed addition has no deviceCredentialDid")
                return
            }

            // Check if this is THIS device (not just same user, but same device UUID)
            if isThisDevice(deviceCredentialDid: deviceDid) {
                logger.info("   Claimed addition is for THIS device - skipping (we can't add ourselves)")
                return
            }

            logger.info("✅ Claimed pending addition - deviceCredentialDid: \(deviceDid)")

            guard let keyPackageBase64 = claimResult.keyPackage?.keyPackage,
                  let keyPackageData = Data(base64Encoded: keyPackageBase64) else {
                logger.error("❌ Claim succeeded but no key package provided")
                await handleAdditionFailure(pendingId: pendingId, convoId: convoId, deviceDid: deviceDid, error: "No key package")
                return
            }

            // Step 2: Add the device to the conversation
            logger.info("🔵 Adding device to conversation \(convoId)...")

            let newEpoch: Int
            do {
                newEpoch = try await addDevice(convoId, deviceDid, keyPackageData)
                logger.info("✅ Device added successfully - newEpoch: \(newEpoch)")
            } catch {
                // addDevice failed AFTER successful claim - track for External Commit fallback
                logger.error("❌ addDevice failed after claim: \(error.localizedDescription)")
                await handleAdditionFailure(pendingId: pendingId, convoId: convoId, deviceDid: deviceDid, error: error.localizedDescription)
                return
            }

            // Step 3: Complete the pending addition with retry
            let completed = await completeWithRetry(pendingId: pendingId, newEpoch: newEpoch)

            if completed {
                logger.info("✅ Pending addition marked complete")
                markAsCompleted(pendingId)
                cancelFallbackTimer(for: pendingId)
            } else {
                logger.warning("⚠️ Failed to mark pending addition as complete after retries")
                // Still mark locally as done since the MLS operation succeeded
                markAsCompleted(pendingId)
            }

        } catch {
            logger.error("❌ Failed to process pending addition: \(error.localizedDescription)")
            // Claim failed - another device may handle it, or polling will retry
        }
    }

    // MARK: - Device DID Validation

    /// Check if a device credential DID refers to THIS device (the one we're running on)
    /// Device credential DID format: "did:plc:user#device-uuid"
    /// - Parameter deviceCredentialDid: The full device credential DID
    /// - Returns: true if this is THIS device, false if it's a different device (even if same user)
    private func isThisDevice(deviceCredentialDid: String) -> Bool {
        // If we don't have a device UUID configured, we can't make this determination
        // However, we should NOT assume it's THIS device - that would prevent adding
        // other devices of the same user. Instead, return false to allow processing.
        guard let currentDevice = currentDeviceUUID else {
            // Extract the device fragment from the credential DID
            // If there's no fragment (legacy single-device format), it's definitely not this device
            guard let hashIndex = deviceCredentialDid.firstIndex(of: "#") else {
                logger.debug("No device fragment in credential DID - not this device")
                return false
            }
            
            let deviceFragment = String(deviceCredentialDid[deviceCredentialDid.index(after: hashIndex)...])
            
            // Without currentDeviceUUID, we can't definitively identify THIS device
            // Log a warning but allow processing - better to attempt and fail than skip valid additions
            logger.warning("⚠️ Cannot determine if \(deviceFragment.prefix(8)) is THIS device (no deviceUUID configured)")
            logger.warning("   Configure MLSDeviceSyncManager with deviceUUID for accurate device detection")
            
            // Return false to allow the addition to proceed
            // The server will reject if we try to add ourselves (claim our own addition)
            return false
        }

        // Check if the device credential contains THIS device's UUID
        return deviceCredentialDid.contains(currentDevice)
    }

    /// Extract base user DID from a device credential DID
    /// "did:plc:abc123#device-uuid" -> "did:plc:abc123"
    private func extractBaseDid(from deviceCredentialDid: String) -> String {
        if let hashIndex = deviceCredentialDid.firstIndex(of: "#") {
            return String(deviceCredentialDid[..<hashIndex])
        }
        return deviceCredentialDid
    }

    // MARK: - Completion with Retry

    /// Complete a pending addition with exponential backoff retry
    /// - Parameters:
    ///   - pendingId: The pending addition ID
    ///   - newEpoch: The new epoch after adding the device
    ///   - maxRetries: Maximum number of retry attempts
    /// - Returns: true if completion succeeded, false otherwise
    private func completeWithRetry(pendingId: String, newEpoch: Int, maxRetries: Int = 3) async -> Bool {
        for attempt in 1...maxRetries {
            do {
                let completed = try await apiClient.completePendingDeviceAddition(
                    pendingAdditionId: pendingId,
                    newEpoch: newEpoch
                )
                if completed {
                    return true
                }
                logger.warning("   Completion returned false on attempt \(attempt)")
            } catch {
                logger.warning("   Completion attempt \(attempt) failed: \(error.localizedDescription)")
            }

            if attempt < maxRetries {
                // Exponential backoff: 100ms, 200ms, 400ms, ...
                let delayMs = UInt64(100 * (1 << (attempt - 1)))
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }
        return false
    }

    // MARK: - Failure Recovery

    /// Handle an addition failure - track locally and start fallback timer
    /// Since no `releasePendingDeviceAddition` API exists, we rely on:
    /// 1. Server-side claim timeout (will eventually release the claim)
    /// 2. External Commit fallback for the new device to self-join
    private func handleAdditionFailure(pendingId: String, convoId: String, deviceDid: String?, error: String) async {
        logger.warning("📛 [FailureRecovery] Addition failed for \(pendingId) - tracking for External Commit fallback")

        failedAdditions[convoId] = FailedAddition(
            pendingId: pendingId,
            deviceDid: deviceDid,
            convoId: convoId,
            timestamp: Date(),
            error: error
        )

        // Start fallback timer - after timeout, notify that External Commit may be needed
        startFallbackTimer(pendingId: pendingId, convoId: convoId)
    }

    /// Start a fallback timer that will trigger External Commit notification after timeout
    private func startFallbackTimer(pendingId: String, convoId: String) {
        // Cancel any existing timer for this pending addition
        fallbackTimers[pendingId]?.cancel()

        fallbackTimers[pendingId] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.fallbackTimeout ?? 30) * 1_000_000_000)

                guard let self = self else { return }

                // Check if the addition was completed by another means
                let wasCompleted = await self.recentlyCompletedAdditions.contains(pendingId)
                if !wasCompleted {
                    await self.notifyExternalCommitFallbackNeeded(convoId: convoId)
                }
            } catch {
                // Task was cancelled - no action needed
            }
        }
    }

    /// Cancel a fallback timer
    private func cancelFallbackTimer(for pendingId: String) {
        fallbackTimers[pendingId]?.cancel()
        fallbackTimers.removeValue(forKey: pendingId)
    }

    /// Notify that External Commit fallback may be needed for a conversation
    private func notifyExternalCommitFallbackNeeded(convoId: String) async {
        logger.info("📣 [FallbackNotification] External Commit may be needed for convo: \(convoId)")

        await MainActor.run {
            NotificationCenter.default.post(
                name: .mlsExternalCommitFallbackNeeded,
                object: nil,
                userInfo: ["convoId": convoId]
            )
        }
    }

    /// Mark a pending addition as recently completed
    private func markAsCompleted(_ pendingId: String) {
        recentlyCompletedAdditions.insert(pendingId)

        // Schedule cleanup after TTL
        Task {
            try? await Task.sleep(nanoseconds: UInt64(completedAdditionsTTL * 1_000_000_000))
            await self.removeFromCompleted(pendingId)
        }
    }

    private func removeFromCompleted(_ pendingId: String) {
        recentlyCompletedAdditions.remove(pendingId)
    }

    // MARK: - Polling Fallback

    /// Start polling for pending device additions (fallback for missed SSE events)
    /// - Parameter interval: Polling interval in seconds (default: 30)
    func startPolling(interval: TimeInterval = 30) {
        guard !isPollingEnabled else {
            logger.debug("Polling already enabled")
            return
        }

        isPollingEnabled = true
        logger.info("📊 Starting polling for pending device additions (interval: \(interval)s)")

        pollingTask = Task {
            while !Task.isCancelled && isPollingEnabled {
                await pollForPendingAdditions()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stop polling for pending device additions
    func stopPolling() {
        isPollingEnabled = false
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("📊 Stopped polling for pending device additions")
    }

    /// Poll the server for pending device additions
    private func pollForPendingAdditions() async {
        logger.debug("📊 Polling for pending device additions...")

        do {
            let pendingAdditions = try await apiClient.getPendingDeviceAdditions(limit: 50)

            if pendingAdditions.isEmpty {
                logger.debug("   No pending additions found")
                return
            }

            logger.info("📊 Found \(pendingAdditions.count) pending additions via polling")

            // Process each pending addition
            for addition in pendingAdditions {
                // Skip if already processing or completed
                if processingAdditions.contains(addition.id) ||
                   recentlyCompletedAdditions.contains(addition.id) {
                    continue
                }

                // Skip if not in pending status (already claimed by someone else)
                if addition.status != "pending" {
                    logger.debug("   Skipping \(addition.id) - status: \(addition.status)")
                    continue
                }

                await processPendingAddition(pendingId: addition.id, convoId: addition.convoId)
            }

        } catch {
            logger.error("❌ Polling failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual Trigger

    /// Manually trigger sync for a specific conversation
    /// Call this when joining a conversation to catch up on any pending device additions
    func syncConversation(_ convoId: String) async {
        logger.info("🔄 Manual sync triggered for conversation: \(convoId)")

        do {
            let pendingAdditions = try await apiClient.getPendingDeviceAdditions(
                convoIds: [convoId],
                limit: 50
            )

            for addition in pendingAdditions where addition.status == "pending" {
                if !processingAdditions.contains(addition.id) &&
                   !recentlyCompletedAdditions.contains(addition.id) {
                    await processPendingAddition(pendingId: addition.id, convoId: addition.convoId)
                }
            }

        } catch {
            logger.error("❌ Manual sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup

    /// Clean up resources
    func shutdown() {
        stopPolling()

        // Cancel all fallback timers
        for (_, timer) in fallbackTimers {
            timer.cancel()
        }
        fallbackTimers.removeAll()

        processingAdditions.removeAll()
        recentlyCompletedAdditions.removeAll()
        failedAdditions.removeAll()
        currentUserDid = nil
        currentDeviceUUID = nil
        addDeviceHandler = nil
        logger.info("MLSDeviceSyncManager shutdown complete")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when External Commit fallback may be needed for a conversation
    /// userInfo contains "convoId" key with the conversation ID
    static let mlsExternalCommitFallbackNeeded = Notification.Name("mlsExternalCommitFallbackNeeded")
}
