import CatbirdMLSCore
import Foundation
import GRDB
import Petrel
import UserNotifications
import os.log

class NotificationService: UNNotificationServiceExtension {

  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttemptContent: UNMutableNotificationContent?

  private let logger = Logger(
    subsystem: "blue.catbird.notification-service", category: "NotificationService")

  // MARK: - Database Manager (NSE-owned instance)
  // NSE runs in a separate process from main app - each process needs its own instance.
  // Cross-process coordination handled via advisory file locks in MLSGRDBManager.
  private let databaseManager = MLSGRDBManager()
  private var activeRecipientDID: String?
  private var isObservingAppStop = false

  // MARK: - Profile Cache (shared via App Group UserDefaults)

  /// App Group suite name for shared storage
  private static let appGroupSuite = "group.blue.catbird.shared"

  /// Key prefix for profile cache entries
  private static let profileCacheKeyPrefix = "profile_cache_"
  private static let mlsServiceDID = "did:web:mls.catbird.blue#atproto_mls"
  private static let mlsServiceNamespace = "blue.catbird.mls"

  /// Cached profile info for notification display (matches MLSProfileEnricher.SharedCachedProfile)
  struct CachedProfile: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: String?
    let cachedAt: Date?  // Optional for backward compatibility
  }

  deinit {
    stopObservingAppStop()
  }

  private func startObservingAppStop() {
    guard !isObservingAppStop else { return }
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(
      center,
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer = observer else { return }
        let service = Unmanaged<NotificationService>.fromOpaque(observer)
          .takeUnretainedValue()
        service.handleAppStopNotification()
      },
      kMLSNSEStopNotification,
      nil,
      .deliverImmediately
    )
    isObservingAppStop = true
    logger.info("🔔 [NSE] Observing app stop notifications")
  }

  private func stopObservingAppStop() {
    guard isObservingAppStop else { return }
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterRemoveObserver(
      center,
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(kMLSNSEStopNotification),

      nil
    )
    isObservingAppStop = false
  }

  private func handleAppStopNotification() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard let userDID = self.activeRecipientDID else {
        self.logger.info("🛑 [NSE] App stop received with no active recipient")
        return
      }

      self.logger.warning(
        "🛑 [NSE] App requested stop - releasing DB for \(userDID.prefix(24))...")
      await MLSCoreContext.shared.removeContext(for: userDID)
      let released = await self.databaseManager.releaseConnectionWithoutCheckpoint(
        for: userDID)
      if released {
        self.logger.info("✅ [NSE] Released DB for \(userDID.prefix(24))...")
      } else {
        self.logger.warning("⚠️ [NSE] Failed to release DB for \(userDID.prefix(24))...")
      }
      self.activeRecipientDID = nil
    }
  }

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

    logger.info("📬 [NSE] didReceive called - processing push notification")

    // Log FFI build ID for verification (should match main app)
    let ffiBuildId = getFfiBuildId()
    logger.info("🔧 [NSE-FFI] Build ID: \(ffiBuildId)")

    guard let bestAttemptContent = bestAttemptContent else {
      logger.error("❌ [NSE] Failed to create mutable content copy")
      return
    }

    let userInfo = request.content.userInfo

    // Log all received keys for debugging
    let keys = userInfo.keys.compactMap { $0 as? String }
    logger.info("📋 [NSE] Payload keys: \(keys.joined(separator: ", "))")

    // Check if this is an MLS message
    guard let type = userInfo["type"] as? String, type == "mls_message" else {
      let receivedType = userInfo["type"] as? String ?? "nil"
      logger.info("ℹ️ [NSE] Not an MLS message (type=\(receivedType)), delivering as-is")
      contentHandler(bestAttemptContent)
      return
    }

    logger.info("🔐 [NSE] MLS message detected, attempting decryption")
    startObservingAppStop()

    // Extract payload
    // We expect:
    // - ciphertext: Base64 encoded encrypted message
    // - convo_id: Conversation ID (usually hex encoded group ID)
    // - message_id: Unique message ID
    // - recipient_did: The DID of the user this message is for (CRITICAL for multi-account)
    // NOTE: sender_did is NOT included in push payload to preserve E2EE privacy
    // The sender is only revealed after decryption from the MLS credentials
    let ciphertext = userInfo["ciphertext"] as? String
    let convoId = userInfo["convo_id"] as? String
    let messageId = userInfo["message_id"] as? String
    let recipientDid = userInfo["recipient_did"] as? String

    // Extract sequence number from push payload (server-side enhancement)
    // NOTE: Server should include "seq" in push payload for message ordering
    // Fallback: if seq not present, we'll process anyway with a warning
    let sequenceNumber: Int64? = {
      if let seqStr = userInfo["seq"] as? String, let seq = Int64(seqStr) {
        return seq
      } else if let seqNum = userInfo["seq"] as? Int64 {
        return seqNum
      }
      return nil
    }()

    // Extract epoch from push payload (needed for message reconstruction)
    // NOTE: Server should include "epoch" in push payload alongside "seq"
    let epoch: Int64? = {
      if let epochStr = userInfo["epoch"] as? String, let ep = Int64(epochStr) {
        return ep
      } else if let epochNum = userInfo["epoch"] as? Int64 {
        return epochNum
      }
      return nil
    }()

    // Log which fields are present/missing
    logger.info(
      "📦 [NSE] Fields: ciphertext=\(ciphertext != nil), convo_id=\(convoId != nil), message_id=\(messageId != nil), recipient_did=\(recipientDid != nil), seq=\(sequenceNumber != nil ? String(sequenceNumber!) : "nil"), epoch=\(epoch != nil ? String(epoch!) : "nil")"
    )

    guard let ciphertext = ciphertext,
      let convoId = convoId,
      let messageId = messageId,
      let recipientDid = recipientDid
    else {

      var missing: [String] = []
      if ciphertext == nil { missing.append("ciphertext") }
      if convoId == nil { missing.append("convo_id") }
      if messageId == nil { missing.append("message_id") }
      if recipientDid == nil { missing.append("recipient_did") }

      logger.error("❌ [NSE] Missing required fields: \(missing.joined(separator: ", "))")
      bestAttemptContent.title = "New Message"
      bestAttemptContent.body = "New Encrypted Message"
      contentHandler(bestAttemptContent)
      return
    }

    logger.info(
      "✅ [NSE] All required fields present - convoId=\(convoId.prefix(16))..., messageId=\(messageId.prefix(16))..., recipientDid=\(recipientDid.prefix(24))..."
    )

    // ═══════════════════════════════════════════════════════════════════════════
    // CRITICAL FIX: Check for account switching FIRST, before any other checks
    // ═══════════════════════════════════════════════════════════════════════════
    // Account switching affects BOTH the old and new user. During the switch window,
    // the database may be in an inconsistent state, or we may have the wrong
    // encryption key loaded. Skip decryption entirely during this period.
    // ═══════════════════════════════════════════════════════════════════════════
    if MLSAppActivityState.isSwitchingAffecting(userDID: recipientDid) {
      logger.info(
        "⏭️ [NSE] Account switch in progress affecting recipient - skipping decryption")
      bestAttemptContent.title = "New Message"
      bestAttemptContent.body = "New Encrypted Message"
      contentHandler(bestAttemptContent)
      return
    }

    // NSE YIELD: If the main app is active for this recipient, don't touch MLS/SQLCipher.
    // This avoids ratchet desync + lock contention during rapid switching.
    if !MLSAppActivityState.shouldNSEDecrypt(recipientUserDID: recipientDid) {
      logger.info("⏭️ [NSE] Main app active for recipient - skipping decryption")
      bestAttemptContent.title = "New Message"
      bestAttemptContent.body = "New Encrypted Message"
      contentHandler(bestAttemptContent)
      return
    }

    // NSE YIELD: If the main app is shutting down (account switch in progress), skip decryption
    // This prevents database access during the critical shutdown window
    if MLSAppActivityState.isShuttingDown(for: recipientDid) {
      logger.info("⏭️ [NSE] Main app shutting down for recipient - skipping decryption")
      bestAttemptContent.title = "New Message"
      bestAttemptContent.body = "New Encrypted Message"
      contentHandler(bestAttemptContent)
      return
    }

    // NOTE: Advisory lock removed - SQLite WAL handles concurrent access.
    // Darwin notifications (MLSCrossProcess) coordinate cache invalidation across processes.

    // Decrypt using shared MLS core context
    // CRITICAL FIX: We must ensure the MLS context is for the correct recipient user.
    // After account switching, the NSE may have a stale context cached for a different user.
    // The ensureContext() method clears stale contexts and creates one for the recipient.
    //
    // IMPORTANT: We use Task.detached to avoid actor isolation issues, but we need to
    // ensure contentHandler is called even if decryption takes too long.
    let capturedContentHandler = contentHandler
    let capturedBestAttemptContent = bestAttemptContent

    Task { @MainActor in
      self.activeRecipientDID = recipientDid
      defer { self.activeRecipientDID = nil }

      // Cache-first (pre-lock): If the main app just decrypted the message, it may not
      // be persisted yet; avoid taking the lock and consuming MLS secrets unnecessarily.
      // Increase retries to 10 (2s total) to give Main App time to flush DB
      for attempt in 0..<10 {
        if await self.deliverCachedNotificationIfAvailable(
          content: capturedBestAttemptContent,
          contentHandler: capturedContentHandler,
          messageId: messageId,
          convoId: convoId,
          recipientDid: recipientDid,
          epoch: epoch,
          sequenceNumber: sequenceNumber
        ) {
          return
        }
        if attempt < 9 { try? await Task.sleep(nanoseconds: 200_000_000) }
      }

      // NOTE: Advisory lock removed (2026-02) - SQLite WAL handles concurrent access.
      // Darwin notifications (MLSCrossProcess) coordinate cache invalidation across processes.
      // No lock acquisition needed - WAL mode is designed for concurrent readers/writers.

      // Cross-process shutdown check: If main app signaled shutdown, skip decryption
      // This uses the shared App Group state
      if MLSAppActivityState.isShuttingDown(for: recipientDid) {
        self.logger.info(
          "⏭️ [NSE] Shutdown file detected for recipient - skipping decryption")
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)
        return
      }

      // Cache-first: If the message already exists in SQLCipher, avoid MLS decryption.
      if await self.deliverCachedNotificationIfAvailable(
        content: capturedBestAttemptContent,
        contentHandler: capturedContentHandler,
        messageId: messageId,
        convoId: convoId,
        recipientDid: recipientDid,
        epoch: epoch,
        sequenceNumber: sequenceNumber
      ) {
        return
      }

      // ═══════════════════════════════════════════════════════════════════════════
      // MESSAGE ORDERING CHECK: Ensure messages are processed in sequence order
      // ═══════════════════════════════════════════════════════════════════════════
      // If sequence number is available, check if we should buffer this message.
      // This prevents orphaned reactions and ensures messages are processed in order.
      // ═══════════════════════════════════════════════════════════════════════════
      if let seq = sequenceNumber {
        self.logger.info(
          "🔢 [NSE-SEQ] Checking message ordering: seq=\(seq), convo=\(convoId.prefix(16))..."
        )

        do {
          let shouldBuffer = try await self.shouldBufferMessage(
            messageID: messageId,
            conversationID: convoId,
            sequenceNumber: seq,
            recipientDid: recipientDid
          )

          if shouldBuffer {
            self.logger.info("📦 [NSE-SEQ] Message out of order - buffering: seq=\(seq)")

            // Buffer the message for later processing by the main app
            try await self.bufferMessageForLater(
              messageID: messageId,
              conversationID: convoId,
              sequenceNumber: seq,
              epoch: epoch ?? 0,  // Default to epoch 0 if not provided
              ciphertext: ciphertext,
              recipientDid: recipientDid
            )

            // Show generic notification (content will be revealed when processed in order)
            capturedBestAttemptContent.title = "New Message"
            capturedBestAttemptContent.body = "New Encrypted Message"
            capturedContentHandler(capturedBestAttemptContent)
            return
          }

          self.logger.info(
            "✅ [NSE-SEQ] Message in order - proceeding with decryption: seq=\(seq)")
        } catch {
          self.logger.warning(
            "⚠️ [NSE-SEQ] Ordering check failed: \(error.localizedDescription) - proceeding anyway"
          )
          // Fall through to decrypt - better to show content than fail silently
        }
      } else {
        self.logger.warning(
          "⚠️ [NSE-SEQ] No sequence number in push payload - server should include 'seq' field"
        )
        self.logger.info("   Proceeding with decryption (no ordering enforcement)")
        // Fall through to decrypt
      }

      do {
        self.logger.debug("📭 [NSE] Cache MISS - proceeding with decryption")

        // CRITICAL FIX: Ensure MLS context is for the correct recipient user
        // This handles account switching where the NSE may have stale context cached
        self.logger.info(
          "🔄 [NSE] Ensuring MLS context for recipient: \(recipientDid.prefix(24))...")
        try await MLSCoreContext.shared.ensureContext(for: recipientDid)
        self.logger.info("✅ [NSE] MLS context verified for recipient")

        // Convert base64 ciphertext to Data
        guard let ciphertextData = Data(base64Encoded: ciphertext) else {
          self.logger.error(
            "❌ [NSE] Invalid base64 ciphertext - length=\(ciphertext.count), first32=\(String(ciphertext.prefix(32)))..."
          )
          capturedBestAttemptContent.title = "New Message"
          capturedBestAttemptContent.body = "New Encrypted Message"
          capturedContentHandler(capturedBestAttemptContent)
          return
        }

        self.logger.info("📊 [NSE] Ciphertext decoded: \(ciphertextData.count) bytes")

        // Resolve groupId from conversation record or fallback to payload encoding.
        var groupResolution = await self.resolveGroupIdData(
          convoId: convoId,
          recipientDid: recipientDid
        )
        var groupIdData = groupResolution.data
        self.logger.info(
          "🔢 [NSE] GroupId resolved (\(groupResolution.source.rawValue)): \(groupIdData.count) bytes"
        )

        // If the group is missing, try to fetch/process Welcome before decrypting.
        if !(await MLSCoreContext.shared.groupExists(
          userDid: recipientDid, groupId: groupIdData))
        {
          self.logger.warning("🆕 [NSE] Group missing locally - attempting Welcome join")
          let joined = await self.ensureGroupStateForNotification(
            convoId: convoId,
            recipientDid: recipientDid,
            groupIdData: groupIdData
          )
          if !joined {
            self.logger.warning(
              "⚠️ [NSE] Welcome join failed or unavailable - showing placeholder")
            capturedBestAttemptContent.title = "New Message"
            capturedBestAttemptContent.body = "New Encrypted Message"
            capturedContentHandler(capturedBestAttemptContent)
            return
          }

          // Re-resolve groupId after Welcome in case convoId is not the MLS groupId.
          let updatedResolution = await self.resolveGroupIdData(
            convoId: convoId,
            recipientDid: recipientDid
          )
          if updatedResolution.data != groupIdData {
            groupResolution = updatedResolution
            groupIdData = updatedResolution.data
            self.logger.info(
              "🔢 [NSE] GroupId updated after Welcome (\(groupResolution.source.rawValue)): \(groupIdData.count) bytes"
            )
          }

          if !(await MLSCoreContext.shared.groupExists(
            userDid: recipientDid, groupId: groupIdData))
          {
            self.logger.warning(
              "⚠️ [NSE] Group still missing after Welcome - showing placeholder")
            capturedBestAttemptContent.title = "New Message"
            capturedBestAttemptContent.body = "New Encrypted Message"
            capturedContentHandler(capturedBestAttemptContent)
            return
          }
        }

        // Double-check cache immediately before decrypting.
        // The main app may have persisted plaintext while we were doing preflight work.
        if await self.deliverCachedNotificationIfAvailable(
          content: capturedBestAttemptContent,
          contentHandler: capturedContentHandler,
          messageId: messageId,
          convoId: convoId,
          recipientDid: recipientDid,
          epoch: epoch,
          sequenceNumber: sequenceNumber
        ) {
          return
        }

        self.logger.info(
          "🔓 [NSE] Starting decryption for message=\(messageId.prefix(16))..., user=\(recipientDid.prefix(24))..."
        )

        // Use shared MLSCoreContext with EPHEMERAL access for notifications
        // This prevents database lock contention with the main app
        let decryptResult = try await MLSCoreContext.shared.decryptForNotification(
          userDid: recipientDid,
          groupId: groupIdData,
          ciphertext: ciphertextData,
          conversationID: convoId,
          messageID: messageId,
          sequenceNumber: sequenceNumber  // Pass sequence number for ordering tracking
        )

        self.logger.info(
          "✅ [NSE] Decryption SUCCESS - plaintext length=\(decryptResult.plaintext.count), sender=\(decryptResult.senderDID?.prefix(24) ?? "unknown")..."
        )

        // ═══════════════════════════════════════════════════════════════════════════
        // CRITICAL FIX: Signal to foreground app that NSE advanced the ratchet
        // ═══════════════════════════════════════════════════════════════════════════
        // When the main app resumes, it should check this flag and reload MLS state
        // from disk before processing any messages. This prevents SecretReuseError.
        // ═══════════════════════════════════════════════════════════════════════════
        MLSAppActivityState.signalNSEProcessed(for: recipientDid)
        self.logger.info("📡 [NSE] Signaled foreground to reload MLS state")

        // Notify main app via Darwin notifications that we've made changes
        MLSCrossProcess.shared.notifyChanged()

        // ═══════════════════════════════════════════════════════════════════════════
        // 🛡️ READ-ONLY NSE (2024-12-24): Do not record epoch checkpoint
        //
        // Since the NSE is now read-only for the core database, it must NOT
        // update the epoch checkpoint. Ratchet advancement remains non-durable
        // in the NSE. The main app will handle durable epoch advancement.
        // ═══════════════════════════════════════════════════════════════════════════

        // Build rich notification with sender info and conversation context
        // This also checks for self-sent messages and returns false if we should suppress
        let shouldShow = await self.configureRichNotification(
          content: capturedBestAttemptContent,
          decryptedText: decryptResult.plaintext,
          senderDid: decryptResult.senderDID,
          convoId: convoId,
          recipientDid: recipientDid,
          messageId: messageId
        )

        if shouldShow {
          capturedContentHandler(capturedBestAttemptContent)
        } else {
          self.logger.info("🔇 [NSE] Notification suppressed (self-sent or filtered)")
          // Don't call contentHandler - this effectively cancels the notification
        }

      } catch let error as MLSError {
        // ═══════════════════════════════════════════════════════════════════════════
        // CRITICAL FIX (2024-12-20): Handle expected MLS errors gracefully
        // ═══════════════════════════════════════════════════════════════════════════
        //
        // SecretReuseSkipped: Message was already decrypted (by Main App or previous NSE run).
        //                     The decryption key has been consumed - this is NOT an error.
        //
        // CannotDecryptOwnMessage: MLS protocol prevents sender from decrypting own messages.
        //                          This happens when testing with two accounts on same device.
        //
        // ═══════════════════════════════════════════════════════════════════════════
        if case .secretReuseSkipped(let messageID) = error {
          self.logger.info(
            "ℹ️ [NSE] SecretReuseSkipped for message \(messageID) - already decrypted by Main App"
          )
          self.logger.info("   Checking cache after SecretReuseSkipped (with retries)")

          // Retry up to 10 times (2 seconds) for the main app to finish the transactions
          for attempt in 0..<10 {
            if await self.deliverCachedNotificationIfAvailable(
              content: capturedBestAttemptContent,
              contentHandler: capturedContentHandler,
              messageId: messageId,
              convoId: convoId,
              recipientDid: recipientDid,
              epoch: epoch,
              sequenceNumber: sequenceNumber
            ) {
              return
            }
            if attempt < 9 { try? await Task.sleep(nanoseconds: 200_000_000) }
          }

          self.logger.info(
            "   Cache miss after SecretReuseSkipped retries - showing fallback")
          capturedBestAttemptContent.title = "New Message"
          capturedBestAttemptContent.body = "New Encrypted Message"
          capturedContentHandler(capturedBestAttemptContent)
          return
        }

        // Check for CannotDecryptOwnMessage (sender == recipient on same device)
        let errorDesc = error.localizedDescription
        if errorDesc.contains("CannotDecryptOwnMessage") {
          self.logger.info(
            "ℹ️ [NSE] CannotDecryptOwnMessage - this is our own sent message")
          self.logger.info("   Suppressing notification for self-sent message")
          // Don't show notification for own messages - they're already visible in the UI
          return
        }

        // Other MLS errors - log and try cache before fallback
        self.logger.error("❌ [NSE] MLSError: \(error.localizedDescription)")
        self.logger.info("   Attempting cache lookup after MLS error...")
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        self.logger.info("   Cache miss after MLS error - showing fallback")
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)

      } catch is CancellationError {
        // Database access errors (shutdown in progress, drain timeout)
        // These are expected during account switching - try cache before fallback
        self.logger.info("ℹ️ [NSE] Database access cancelled - attempting cache lookup")
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)

      } catch let error as MLSGateError {
        self.logger.info(
          "ℹ️ [NSE] Database gate error: \(error.localizedDescription) - attempting cache lookup"
        )
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)

      } catch let error as MLSExclusiveAccessError {
        self.logger.info(
          "ℹ️ [NSE] Exclusive access error: \(error.localizedDescription) - attempting cache lookup"
        )
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)

      } catch let error as MLSSQLCipherError {
        self.logger.info(
          "ℹ️ [NSE] Database access error: \(error.localizedDescription) - attempting cache lookup"
        )
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)

      } catch let error {
        // Log detailed error information for non-MLS errors
        self.logger.error("❌ [NSE] Decryption FAILED: \(error.localizedDescription)")
        self.logger.error("❌ [NSE] Error type: \(String(describing: error))")

        // Check for SecretReuseError in the error description (for MlsError from FFI)
        let errorDesc = error.localizedDescription.lowercased()
        if errorDesc.contains("secretreuse") || errorDesc.contains("secret_reuse") {
          self.logger.info(
            "ℹ️ [NSE] SecretReuseError detected in FFI error - message already processed"
          )
          for attempt in 0..<5 {
            if await self.deliverCachedNotificationIfAvailable(
              content: capturedBestAttemptContent,
              contentHandler: capturedContentHandler,
              messageId: messageId,
              convoId: convoId,
              recipientDid: recipientDid,
              epoch: epoch,
              sequenceNumber: sequenceNumber
            ) {
              return
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 150_000_000) }
          }

          capturedBestAttemptContent.title = "New Message"
          capturedBestAttemptContent.body = "New Encrypted Message"
          capturedContentHandler(capturedBestAttemptContent)
          return
        }

        // Check for CannotDecryptOwnMessage (can come from FFI as well)
        if errorDesc.contains("cannotdecryptownmessage")
          || errorDesc.contains("own message")
        {
          self.logger.info("ℹ️ [NSE] CannotDecryptOwnMessage in FFI error - suppressing")
          return
        }

        // Try to extract more details from the error
        if let nsError = error as NSError? {
          self.logger.error("❌ [NSE] NSError domain=\(nsError.domain), code=\(nsError.code)")
          if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            self.logger.error("❌ [NSE] Underlying error: \(underlying.localizedDescription)")
          }
        }

        // Last resort: attempt cache lookup before showing fallback
        self.logger.info("   Attempting cache lookup after unknown error...")
        for attempt in 0..<3 {
          if await self.deliverCachedNotificationIfAvailable(
            content: capturedBestAttemptContent,
            contentHandler: capturedContentHandler,
            messageId: messageId,
            convoId: convoId,
            recipientDid: recipientDid,
            epoch: epoch,
            sequenceNumber: sequenceNumber
          ) {
            return
          }
          if attempt < 2 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        self.logger.info("   Cache miss after unknown error - showing fallback")
        capturedBestAttemptContent.title = "New Message"
        capturedBestAttemptContent.body = "New Encrypted Message"
        capturedContentHandler(capturedBestAttemptContent)
      }

      // ═══════════════════════════════════════════════════════════════════════════
      // PHASE 5-6: Enhanced NSE Close Sequence (2024-12)
      // ═══════════════════════════════════════════════════════════════════════════
      //
      // This implements a coordinated close sequence to prevent HMAC check failures
      // when the main app tries to open the database while NSE is closing:
      //
      // 1. Post nseWillClose notification - tells main app to release readers
      // 2. Wait for app acknowledgment (with timeout)
      // 3. Use MLSShutdownCoordinator for proper close sequence
      // 4. Post stateChanged notification - tells app to reload
      //
      // ═══════════════════════════════════════════════════════════════════════════

      // Step 1: Post nseWillClose notification
      self.logger.info("📢 [NSE] Posting nseWillClose notification")
      let token = MLSStateChangeNotifier.postNSEWillClose(userDID: recipientDid)

      // Step 2: Wait for app acknowledgment (with timeout)
      let acked = await MLSStateChangeNotifier.waitForAppAcknowledgment(
        userDID: recipientDid,
        token: token,
        timeout: .milliseconds(1500)
      )
      if acked {
        self.logger.info("✅ [NSE] App acknowledged - waiting for connection release")
        // Give the app's connection a moment to fully close
        // The app calls releaseConnectionWithoutCheckpoint which takes ~50ms
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms safety buffer
      } else {
        self.logger.warning("⏱️ [NSE] App acknowledgment timeout - skipping close sequence")
        return
      }

      // Step 3: Use MLSShutdownCoordinator for proper close sequence
      // This handles: FFI flush → WAL checkpoint → DB release (without 200ms delay for NSE)
      self.logger.info("🔐 [NSE] Using shutdown coordinator for clean close...")
      let result = await MLSShutdownCoordinator.shared.quickShutdownForNSE(
        for: recipientDid, databaseManager: databaseManager)
      switch result {
      case .success(let durationMs):
        self.logger.info("✅ [NSE] Quick shutdown complete in \(durationMs)ms")
      case .successWithWarnings(let durationMs, let warnings):
        self.logger.warning(
          "⚠️ [NSE] Quick shutdown in \(durationMs)ms with \(warnings.count) warning(s)")
      case .timedOut(let durationMs, let phase):
        self.logger.warning(
          "⏱️ [NSE] Quick shutdown timed out at \(phase.rawValue) after \(durationMs)ms")
      case .failed(let error):
        self.logger.error("❌ [NSE] Quick shutdown failed: \(error.localizedDescription)")
      }

      // Step 4: Post stateChanged notification - tells app to reload
      MLSStateChangeNotifier.postStateChanged()
      self.logger.info("📢 [NSE] Posted state change notification to main app")
    }
  }

  override func serviceExtensionTimeWillExpire() {
    logger.warning(
      "⏱️ [NSE] serviceExtensionTimeWillExpire called - system is terminating extension")

    // Called just before the extension will be terminated by the system.
    // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
    if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
      // If we haven't decrypted yet (body still shows placeholder), show fallback
      if bestAttemptContent.body.isEmpty || bestAttemptContent.body == "Decrypting..." {
        bestAttemptContent.title = "New Message"
        bestAttemptContent.body = "New Encrypted Message"
        logger.warning("⏱️ [NSE] Delivering fallback content - decryption did not complete in time")
      } else {
        logger.info("✅ [NSE] Delivering already-decrypted content on expiry")
      }
      contentHandler(bestAttemptContent)
    }
  }

  // MARK: - Cached Message Lookup

  private enum CachedNotificationSource: String {
    case messageId = "message_id"
    case order = "epoch/seq"
  }

  private struct CachedNotificationLookup {
    let messageId: String
    let conversationId: String
    let senderDid: String?
    let payloadText: String?
    let payloadExpired: Bool
    let processingState: String
    let processingError: String?
    let source: CachedNotificationSource
  }

  // MARK: - Group ID Resolution

  private enum GroupIdResolutionSource: String {
    case conversationRecord = "conversation_record"
    case payloadHex = "payload_hex"
    case payloadUtf8 = "payload_utf8"
  }

  private struct GroupIdResolution {
    let data: Data
    let source: GroupIdResolutionSource
  }

  private func resolveGroupIdData(
    convoId: String,
    recipientDid: String
  ) async -> GroupIdResolution {
    let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    do {
      if let conversation = try await databaseManager.nseRead(for: recipientDid) { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.conversationID == convoId)
          .filter(MLSConversationModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      } {
        return GroupIdResolution(data: conversation.groupID, source: .conversationRecord)
      }
    } catch {
      logger.warning("⚠️ [NSE] GroupId lookup failed: \(error.localizedDescription)")
    }

    if let hexData = Data(hexEncoded: convoId) {
      return GroupIdResolution(data: hexData, source: .payloadHex)
    }

    return GroupIdResolution(data: Data(convoId.utf8), source: .payloadUtf8)
  }

  private func lookupCachedNotification(
    messageId: String,
    conversationId: String,
    recipientDid: String,
    epoch: Int64?,
    sequenceNumber: Int64?
  ) async -> CachedNotificationLookup? {
    let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    do {
      return try await databaseManager.nseRead(for: recipientDid) { db in
        if let message =
          try MLSMessageModel
          .filter(MLSMessageModel.Columns.messageID == messageId)
          .filter(MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
        {
          let payloadText = message.payloadJSON.flatMap {
            String(data: $0, encoding: .utf8)
          }
          if payloadText == nil, let epoch = epoch, let sequenceNumber = sequenceNumber {
            if let orderedMessage =
              try MLSMessageModel
              .filter(MLSMessageModel.Columns.conversationID == conversationId)
              .filter(
                MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid
              )
              .filter(MLSMessageModel.Columns.epoch == epoch)
              .filter(MLSMessageModel.Columns.sequenceNumber == sequenceNumber)
              .fetchOne(db)
            {
              let orderedPayloadText = orderedMessage.payloadJSON.flatMap {
                String(data: $0, encoding: .utf8)
              }
              if orderedPayloadText != nil {
                return CachedNotificationLookup(
                  messageId: orderedMessage.messageID,
                  conversationId: orderedMessage.conversationID,
                  senderDid: orderedMessage.senderID,
                  payloadText: orderedPayloadText,
                  payloadExpired: orderedMessage.payloadExpired,
                  processingState: orderedMessage.processingState,
                  processingError: orderedMessage.processingError,
                  source: .order
                )
              }
            }
          }
          return CachedNotificationLookup(
            messageId: message.messageID,
            conversationId: message.conversationID,
            senderDid: message.senderID,
            payloadText: payloadText,
            payloadExpired: message.payloadExpired,
            processingState: message.processingState,
            processingError: message.processingError,
            source: .messageId
          )
        }

        if let epoch = epoch, let sequenceNumber = sequenceNumber {
          if let message =
            try MLSMessageModel
            .filter(MLSMessageModel.Columns.conversationID == conversationId)
            .filter(MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
            .filter(MLSMessageModel.Columns.epoch == epoch)
            .filter(MLSMessageModel.Columns.sequenceNumber == sequenceNumber)
            .fetchOne(db)
          {
            let payloadText = message.payloadJSON.flatMap {
              String(data: $0, encoding: .utf8)
            }
            return CachedNotificationLookup(
              messageId: message.messageID,
              conversationId: message.conversationID,
              senderDid: message.senderID,
              payloadText: payloadText,
              payloadExpired: message.payloadExpired,
              processingState: message.processingState,
              processingError: message.processingError,
              source: .order
            )
          }
        }

        return nil
      }
    } catch {
      logger.warning("⚠️ [NSE] Cache lookup failed: \(error.localizedDescription)")
      return nil
    }
  }

  private func deliverCachedNotificationIfAvailable(
    content: UNMutableNotificationContent,
    contentHandler: @escaping (UNNotificationContent) -> Void,
    messageId: String,
    convoId: String,
    recipientDid: String,
    epoch: Int64?,
    sequenceNumber: Int64?
  ) async -> Bool {
    guard
      let cached = await lookupCachedNotification(
        messageId: messageId,
        conversationId: convoId,
        recipientDid: recipientDid,
        epoch: epoch,
        sequenceNumber: sequenceNumber
      )
    else {
      return false
    }

    logger.info("📦 [NSE] Cache HIT (\(cached.source.rawValue)) - message already stored")

    if let payloadText = cached.payloadText, !payloadText.isEmpty {
      let shouldShow = await configureRichNotification(
        content: content,
        decryptedText: payloadText,
        senderDid: cached.senderDid,
        convoId: cached.conversationId,
        recipientDid: recipientDid,
        messageId: cached.messageId
      )

      if shouldShow {
        contentHandler(content)
      } else {
        logger.info("🔇 [NSE] Cached message suppressed (self-sent or filtered)")
      }
    } else {
      let payloadStatus = cached.payloadExpired ? "expired" : "missing"
      logger.info(
        "📦 [NSE] Cached message has no payload (\(payloadStatus)) - state=\(cached.processingState), error=\(cached.processingError ?? "nil")"
      )
      content.title = "New Message"
      content.body = "New Encrypted Message"
      contentHandler(content)
    }

    return true
  }

  // MARK: - Welcome Join (NSE)

  private enum NSEWelcomeError: LocalizedError {
    case httpError(statusCode: Int)
    case invalidResponse
    case invalidBase64

    var errorDescription: String? {
      switch self {
      case .httpError(let statusCode):
        return "HTTP \(statusCode)"
      case .invalidResponse:
        return "Invalid response"
      case .invalidBase64:
        return "Invalid base64"
      }
    }
  }

  private func ensureGroupStateForNotification(
    convoId: String,
    recipientDid: String,
    groupIdData: Data
  ) async -> Bool {
    let welcomeReady = await MLSWelcomeGate.shared.waitForWelcomeIfPending(
      for: convoId,
      userDID: recipientDid,
      timeout: .seconds(2)
    )
    if !welcomeReady {
      logger.info("⏱️ [NSE] Welcome gate timeout - proceeding with NSE join attempt")
    }

    if await MLSCoreContext.shared.groupExists(userDid: recipientDid, groupId: groupIdData) {
      logger.info("✅ [NSE] Group appeared after Welcome gate wait")
      return true
    }

    return await attemptWelcomeJoin(convoId: convoId, recipientDid: recipientDid)
  }

  private func attemptWelcomeJoin(
    convoId: String,
    recipientDid: String
  ) async -> Bool {
    await MLSWelcomeGate.shared.beginWelcomeProcessing(for: convoId, userDID: recipientDid)
    defer {
      Task {
        await MLSWelcomeGate.shared.completeWelcomeProcessing(
          for: convoId, userDID: recipientDid)
      }
    }

    guard let client = await createStandaloneClientForUser(recipientDid) else {
      logger.warning("⚠️ [NSE] Failed to create API client for Welcome fetch")
      return false
    }

    await client.setServiceDID(Self.mlsServiceDID, for: Self.mlsServiceNamespace)

    do {
      logger.info("📩 [NSE] Fetching Welcome message for group: \(convoId.prefix(16))...")
      let welcomeData = try await fetchWelcomeData(convoId: convoId, client: client)
      logger.info("📩 [NSE] Received Welcome message: \(welcomeData.count) bytes")

      try await MLSCoreContext.shared.ensureContext(for: recipientDid)
      let context = try await MLSCoreContext.shared.getContext(for: recipientDid)

      let identityBytes = Data(recipientDid.utf8)
      logger.info("🔐 [NSE] Processing Welcome message...")
      let welcomeResult = try context.processWelcome(
        welcomeBytes: welcomeData,
        identityBytes: identityBytes,
        config: nil
      )

      logger.info(
        "✅ [NSE] Successfully joined group via Welcome! GroupID: \(welcomeResult.groupId.hexEncodedString().prefix(16))..."
      )

      let groupIdHex = welcomeResult.groupId.hexEncodedString()
      do {
        try await databaseManager.nseWrite(for: recipientDid) { db in
          try MLSStorageHelpers.ensureConversationExistsSync(
            in: db,
            userDID: recipientDid,
            conversationID: convoId,
            groupID: groupIdHex
          )
        }
        logger.info("✅ [NSE] Created conversation record for new group (FK fix)")
      } catch {
        logger.warning(
          "⚠️ [NSE] Failed to pre-create conversation record: \(error.localizedDescription)"
        )
      }

      await confirmWelcome(convoId: convoId, client: client)
      return true
    } catch let error as NSEWelcomeError {
      if case .httpError(let statusCode) = error {
        if statusCode == 404 {
          logger.info("ℹ️ [NSE] No Welcome message available for group (404)")
        } else if statusCode == 410 {
          logger.info("ℹ️ [NSE] Welcome expired for group (410)")
        } else {
          logger.warning("⚠️ [NSE] Welcome fetch failed: HTTP \(statusCode)")
        }
      } else {
        logger.warning("⚠️ [NSE] Welcome fetch failed: \(error.localizedDescription)")
      }
      return false
    } catch let error as MlsError {
      switch error {
      case .NoMatchingKeyPackage(let msg):
        logger.warning(
          "⚠️ [NSE] NoMatchingKeyPackage - Welcome references unavailable key package: \(msg)"
        )
      case .WelcomeConsumed(let msg):
        logger.warning("⚠️ [NSE] Welcome consumed: \(msg)")
      default:
        logger.warning("⚠️ [NSE] Failed to process Welcome: \(error.localizedDescription)")
      }
      return false
    } catch {
      logger.warning("⚠️ [NSE] Failed to join group: \(error.localizedDescription)")
      return false
    }
  }

  private func fetchWelcomeData(
    convoId: String,
    client: ATProtoClient
  ) async throws -> Data {
    let input = BlueCatbirdMlsGetWelcome.Parameters(convoId: convoId)
    let (responseCode, output) = try await client.blue.catbird.mls.getWelcome(input: input)

    guard responseCode == 200, let output = output else {
      throw NSEWelcomeError.httpError(statusCode: responseCode)
    }

    guard let welcomeData = Data(base64Encoded: output.welcome) else {
      throw NSEWelcomeError.invalidBase64
    }

    return welcomeData
  }

  private func confirmWelcome(
    convoId: String,
    client: ATProtoClient
  ) async {
    let input = BlueCatbirdMlsConfirmWelcome.Input(
      convoId: convoId,
      success: true,
      errorDetails: nil
    )

    do {
      let (responseCode, _) = try await client.blue.catbird.mls.confirmWelcome(input: input)
      if responseCode == 200 {
        logger.info("✅ [NSE] Confirmed Welcome processing with server")
      } else {
        logger.warning("⚠️ [NSE] Welcome confirm returned HTTP \(responseCode)")
      }
    } catch {
      logger.warning(
        "⚠️ [NSE] Failed to confirm Welcome (non-critical): \(error.localizedDescription)")
    }
  }

  private func createStandaloneClientForUser(_ userDid: String) async -> ATProtoClient? {
    logger.info("🔐 [NSE] Creating standalone ATProtoClient for: \(userDid.prefix(24))...")

    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = MLSKeychainManager.resolvedAccessGroup(
        suffix: "blue.catbird.shared")
    #endif

    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )

    let client: ATProtoClient
    do {
      client = try await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: URL(string: "https://api.catbird.blue")!,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: "did:web:api.bsky.app#bsky_appview",
        bskyChatDID: "did:web:api.bsky.chat#bsky_chat",
        accessGroup: accessGroup
      )
    } catch {
      logger.error("❌ [NSE] Failed to create ATProtoClient: \(error.localizedDescription)")
      return nil
    }

    do {
      try await client.switchToAccount(did: userDid)
      logger.info("✅ [NSE] Standalone client switched to user: \(userDid.prefix(24))...")
      return client
    } catch {
      logger.error(
        "❌ [NSE] Failed to switch standalone client to user: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Message Ordering Helpers

  /// Check if message should be buffered due to out-of-order arrival
  /// - Returns: true if message should be buffered, false if it can be processed now
  private func shouldBufferMessage(
    messageID: String,
    conversationID: String,
    sequenceNumber: Int64,
    recipientDid: String
  ) async throws -> Bool {
    // Use NSE-optimized lightweight read (DatabaseQueue instead of DatabasePool)
    // This is critical for staying within NSE's ~24MB memory limit
    let lastProcessed = try await databaseManager.nseRead(for: recipientDid) { db in
      try MLSConversationSequenceState
        .filter(MLSConversationSequenceState.Columns.conversationID == conversationID)
        .filter(
          MLSConversationSequenceState.Columns.currentUserDID == recipientDid.lowercased()
        )
        .fetchOne(db)
    }

    if let state = lastProcessed {
      // If this message's seq is > lastProcessed + 1, we're missing messages
      if sequenceNumber > state.lastProcessedSeq + 1 {
        logger.info(
          "[NSE-SEQ] Gap detected: expecting seq=\(state.lastProcessedSeq + 1), got seq=\(sequenceNumber)"
        )
        return true  // Buffer this message
      }

      // If this message's seq <= lastProcessed, it's a duplicate
      if sequenceNumber <= state.lastProcessedSeq {
        logger.info(
          "[NSE-SEQ] Duplicate message: seq=\(sequenceNumber) already processed (lastProcessed=\(state.lastProcessedSeq))"
        )
        return true  // Buffer to prevent double-processing (will be deduplicated)
      }

      // seq == lastProcessed + 1: process now
      logger.debug(
        "[NSE-SEQ] Message in sequence: seq=\(sequenceNumber), lastProcessed=\(state.lastProcessedSeq)"
      )
      return false
    } else {
      // No sequence state yet - this is the first message
      logger.info("[NSE-SEQ] First message for conversation: seq=\(sequenceNumber)")
      return false  // Process it
    }
  }

  /// Buffer a message that arrived out of order for later processing by the main app
  private func bufferMessageForLater(
    messageID: String,
    conversationID: String,
    sequenceNumber: Int64,
    epoch: Int64,
    ciphertext: String,
    recipientDid: String
  ) async throws {
    // Create a minimal MessageView JSON representation for buffering
    // The main app will process this when it catches up
    let messageViewJSON: [String: Any] = [
      "id": messageID,
      "convoId": conversationID,
      "seq": sequenceNumber,
      "epoch": epoch,
      "ciphertext": ciphertext,
      // Note: senderDid and other metadata will be filled in by main app during processing
      "buffered_by": "nse",
      "buffered_at": ISO8601DateFormatter().string(from: Date()),
    ]

    guard let jsonData = try? JSONSerialization.data(withJSONObject: messageViewJSON) else {
      logger.error("[NSE-SEQ] Failed to serialize message view for buffering")
      throw NSError(
        domain: "NotificationService", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to serialize message view"])
    }

    // Create pending message model
    let pending = MLSPendingMessageModel(
      messageID: messageID,
      currentUserDID: recipientDid.lowercased(),
      conversationID: conversationID,
      sequenceNumber: sequenceNumber,
      epoch: epoch,
      messageViewJSON: jsonData,
      source: "nse"
    )

    // Use NSE-optimized lightweight write (DatabaseQueue instead of DatabasePool)
    try await databaseManager.nseWrite(for: recipientDid) { db in
      try pending.save(db, onConflict: .replace)
    }

    logger.info(
      "[NSE-SEQ] Buffered message \(messageID.prefix(16)) seq=\(sequenceNumber) epoch=\(epoch) for later processing"
    )
  }

  // MARK: - Rich Notification Configuration

  /// Configures the notification with sender info, conversation title, and profile photo
  /// The sender DID is retrieved from the decrypted message in the database (E2EE safe)
  /// - Returns: true if notification should be shown, false if it should be suppressed (e.g., self-sent)
  @discardableResult
  private func configureRichNotification(
    content: UNMutableNotificationContent,
    decryptedText: String,
    senderDid: String?,
    convoId: String,
    recipientDid: String,
    messageId: String
  ) async -> Bool {
    // Try to get conversation info from local database
    let conversationTitle = await getConversationTitle(convoId: convoId, recipientDid: recipientDid)

    // Prefer sender DID from decryption result, but fall back to the stored message record.
    // Some decryption paths may not surface senderDID even though it is written to the DB.
    var actualSenderDid = senderDid
    if actualSenderDid == nil {
      actualSenderDid = await getSenderFromMessage(messageId: messageId, recipientDid: recipientDid)
    }

    // Sender identities may include a device fragment (e.g. did:plc:...#device).
    // Our profile cache + member table are keyed by canonical DID.
    let canonicalSenderDid = actualSenderDid.map { did in
      did.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(
        String.init) ?? did
    }

    // CRITICAL: Check if this is a self-sent message AFTER decryption (E2EE safe)
    // We should NOT show notifications for messages we sent ourselves
    if let senderDid = canonicalSenderDid {
      let normalizedSender = senderDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let normalizedRecipient = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      if normalizedSender == normalizedRecipient {
        logger.info(
          "🔇 [NSE] Self-sent message detected (sender == recipient) - suppressing notification")
        return false  // Don't show notification
      }
    }

    // Try to get sender profile info from cache or members table
    var senderName: String? = nil
    var senderAvatarURL: String? = nil

    if let senderDid = canonicalSenderDid {
      if let profile = getCachedProfile(for: senderDid) {
        senderName = profile.displayName ?? profile.handle
        senderAvatarURL = profile.avatarURL
        logger.info("👤 [NSE] Found cached sender profile: \(senderName ?? "unknown")")
      } else {
        // Fallback: try to get from members table in MLS database
        if let memberInfo = await getMemberInfo(
          senderDid: senderDid, convoId: convoId, recipientDid: recipientDid)
        {
          senderName = memberInfo.displayName ?? memberInfo.handle
          logger.info("👤 [NSE] Found member info from database: \(senderName ?? "unknown")")
        }

        // Last resort: use shortened DID as identifier
        if senderName == nil {
          senderName = formatShortDID(senderDid)
          logger.info("👤 [NSE] Using shortened DID as sender name: \(senderName ?? "unknown")")
        }
      }
    }

    // Build notification title
    // Format: "Sender Name" or "Sender Name in Group Name"
    if let sender = senderName {
      if let convTitle = conversationTitle, !convTitle.isEmpty {
        content.title = "\(sender) in \(convTitle)"
      } else {
        content.title = sender
      }
    } else if let convTitle = conversationTitle, !convTitle.isEmpty {
      content.title = convTitle
    } else {
      content.title = "New Message"
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Parse MLS message payload to determine notification content
    // Encrypted reactions need special handling
    // ═══════════════════════════════════════════════════════════════════════════

    // Try to parse as MLSMessagePayload JSON first
    if let payloadData = decryptedText.data(using: .utf8),
      let payload = try? MLSMessagePayload.decodeFromJSON(payloadData)
    {

      switch payload.messageType {
      case .text:
        // Text message - use the text content
        if let text = payload.text, !text.isEmpty {
          content.body = text
        } else {
          content.body = "New Message"
        }
        logger.info("📝 [NSE] Text message notification")

      case .reaction:
        // Only show notifications for added reactions, suppress removed reactions
        if let reaction = payload.reaction {
          if reaction.action == .add {
            content.body = "Reacted with \(reaction.emoji)"
            logger.info("😀 [NSE] Reaction notification: \(reaction.emoji)")
          } else {
            // Removed reactions should not generate notifications
            logger.info("🔇 [NSE] Removed reaction - suppressing notification")
            return false
          }
        } else {
          // Malformed reaction payload - suppress
          logger.warning("⚠️ [NSE] Malformed reaction payload - suppressing")
          return false
        }

      case .readReceipt:
        // Read receipts should not generate notifications
        logger.info("📖 [NSE] Read receipt - suppressing notification")
        return false

      case .typing:
        // Typing indicators are disabled - suppress notification
        logger.info(
          "⌨️ [NSE] Typing indicator (disabled feature) - suppressing notification")
        return false

      case .adminRoster, .adminAction:
        // Admin actions - generic notification
        content.body = "Group settings updated"
        logger.info("👑 [NSE] Admin action notification")
      }
    } else {
      // Fallback: If not valid JSON payload, treat as plain text
      // This handles legacy messages or edge cases
      content.body = decryptedText
      logger.info("📄 [NSE] Plain text notification (legacy or fallback)")
    }

    // Add userInfo for tap handling - allows app to navigate to correct conversation
    var userInfo = content.userInfo
    userInfo["type"] = "mls_message"
    userInfo["convo_id"] = convoId
    userInfo["recipient_did"] = recipientDid
    userInfo["message_id"] = messageId
    content.userInfo = userInfo

    // Try to attach sender's profile photo
    if let avatarURLString = senderAvatarURL,
      let avatarURL = URL(string: avatarURLString)
    {
      await attachProfilePhoto(to: content, from: avatarURL)
    }

    // Set category for notification actions if needed
    content.categoryIdentifier = "MLS_MESSAGE"

    // Set thread identifier for grouping notifications by conversation
    content.threadIdentifier = "mls-\(convoId)"

    logger.info(
      "✅ [NSE] Rich notification configured - title: \(content.title), body length: \(content.body.count)"
    )
    return true  // Show notification
  }

  /// Gets the sender DID from the stored message (after decryption)
  /// This is E2EE safe because sender identity is only available post-decryption
  /// from the cryptographically authenticated MLS credential
  private func getSenderFromMessage(messageId: String, recipientDid: String) async -> String? {
    do {
      // Normalize the recipient DID for consistent lookup (DIDs are stored normalized)
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      // Use NSE-optimized lightweight read
      let message = try await databaseManager.nseRead(for: recipientDid) { db in
        try MLSMessageModel
          .filter(MLSMessageModel.Columns.messageID == messageId)
          .filter(MLSMessageModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      }

      if let senderID = message?.senderID, !senderID.isEmpty, senderID != "unknown" {
        logger.debug("👤 [NSE] Retrieved sender from message: \(senderID.prefix(24))...")
        return senderID
      }

      logger.debug("⚠️ [NSE] No sender found in message record")
      return nil

    } catch {
      logger.debug("⚠️ [NSE] Failed to get sender from message: \(error.localizedDescription)")
      return nil
    }
  }

  /// Gets the conversation title from local database
  private func getConversationTitle(convoId: String, recipientDid: String) async -> String? {
    do {
      // Normalize the recipient DID for consistent lookup (DIDs are stored normalized)
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      // Use NSE-optimized lightweight read
      let conversation = try await databaseManager.nseRead(for: recipientDid) { db in
        try MLSConversationModel
          .filter(MLSConversationModel.Columns.conversationID == convoId)
          .filter(MLSConversationModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      }

      if let title = conversation?.title, !title.isEmpty {
        logger.debug("📝 [NSE] Found conversation title: \(title)")
        return title
      }

      // If no title, this might be a DM - we could infer from members
      // but for now return nil to fall back to sender name
      logger.debug("📝 [NSE] No conversation title found")
      return nil

    } catch {
      logger.warning("⚠️ [NSE] Failed to get conversation title: \(error.localizedDescription)")
      return nil
    }
  }

  /// Gets member info from the MLS member table
  private func getMemberInfo(senderDid: String, convoId: String, recipientDid: String) async -> (
    displayName: String?, handle: String?
  )? {
    do {
      // Normalize the DID for consistent lookup (DIDs are stored normalized in the database)
      let normalizedSenderDid = senderDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      // Normalize the recipient DID for consistent scoping (tables are per-user)
      let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      // Use NSE-optimized lightweight read
      let member = try await databaseManager.nseRead(for: recipientDid) { db in
        try MLSMemberModel
          .filter(MLSMemberModel.Columns.did == normalizedSenderDid)
          .filter(MLSMemberModel.Columns.conversationID == convoId)
          .filter(MLSMemberModel.Columns.currentUserDID == normalizedRecipientDid)
          .fetchOne(db)
      }

      if let member = member {
        return (displayName: member.displayName, handle: member.handle)
      }

      return nil

    } catch {
      logger.debug("⚠️ [NSE] Failed to get member info: \(error.localizedDescription)")
      return nil
    }
  }

  /// Gets cached profile from App Group UserDefaults
  private func getCachedProfile(for did: String) -> CachedProfile? {
    guard let defaults = UserDefaults(suiteName: Self.appGroupSuite) else {
      return nil
    }

    let cacheKey = "\(Self.profileCacheKeyPrefix)\(did.lowercased())"

    guard let data = defaults.data(forKey: cacheKey) else {
      return nil
    }

    return try? JSONDecoder().decode(CachedProfile.self, from: data)
  }

  /// Downloads and attaches profile photo to the notification
  private func attachProfilePhoto(to content: UNMutableNotificationContent, from url: URL) async {
    logger.debug(
      "🖼️ [NSE] Attempting to download profile photo: \(url.absoluteString.prefix(50))...")

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      guard let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200
      else {
        logger.warning("⚠️ [NSE] Profile photo download failed - invalid response")
        return
      }

      // Determine file extension from MIME type
      let mimeType = httpResponse.mimeType ?? "image/jpeg"
      let fileExtension: String
      switch mimeType {
      case "image/png":
        fileExtension = "png"
      case "image/gif":
        fileExtension = "gif"
      default:
        fileExtension = "jpg"
      }

      // Write to temporary file
      let tempDir = FileManager.default.temporaryDirectory
      let fileName = "\(UUID().uuidString).\(fileExtension)"
      let fileURL = tempDir.appendingPathComponent(fileName)

      try data.write(to: fileURL)

      // Create attachment
      let attachment = try UNNotificationAttachment(
        identifier: "avatar",
        url: fileURL,
        options: [
          UNNotificationAttachmentOptionsTypeHintKey: mimeType
        ]
      )

      content.attachments = [attachment]
      logger.info("✅ [NSE] Profile photo attached successfully")

    } catch {
      logger.warning("⚠️ [NSE] Failed to attach profile photo: \(error.localizedDescription)")
    }
  }

  /// Format a DID for display when no profile info is available
  /// Extracts the last segment and shortens it for readability
  /// e.g., "did:plc:abc123xyz456" → "abc123..."
  private func formatShortDID(_ did: String) -> String? {
    let components = did.split(separator: ":")
    guard let lastPart = components.last else { return nil }

    // Take first 8 characters of the identifier
    let identifier = String(lastPart.prefix(8))
    return identifier.isEmpty ? nil : "\(identifier)..."
  }
}
