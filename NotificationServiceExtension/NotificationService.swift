import UserNotifications
import os.log
import Foundation
import CatbirdMLSCore
import GRDB

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private let logger = Logger(subsystem: "blue.catbird.notification-service", category: "NotificationService")
    
    // MARK: - Profile Cache (shared via App Group UserDefaults)
    
    /// App Group suite name for shared storage
    private static let appGroupSuite = "group.blue.catbird.shared"
    
    /// Key prefix for profile cache entries
    private static let profileCacheKeyPrefix = "profile_cache_"
    
    /// Cached profile info for notification display (matches MLSProfileEnricher.SharedCachedProfile)
    struct CachedProfile: Codable {
        let did: String
        let handle: String
        let displayName: String?
        let avatarURL: String?
        let cachedAt: Date?  // Optional for backward compatibility
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        logger.info("📬 [NSE] didReceive called - processing push notification")

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
        
        // Log which fields are present/missing
        logger.info("📦 [NSE] Fields: ciphertext=\(ciphertext != nil), convo_id=\(convoId != nil), message_id=\(messageId != nil), recipient_did=\(recipientDid != nil)")
        
        guard let ciphertext = ciphertext,
              let convoId = convoId,
              let messageId = messageId,
              let recipientDid = recipientDid else {

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
        
        logger.info("✅ [NSE] All required fields present - convoId=\(convoId.prefix(16))..., messageId=\(messageId.prefix(16))..., recipientDid=\(recipientDid.prefix(24))...")

        // NSE YIELD: If the main app is active for this recipient, don't touch MLS/SQLCipher.
        // This avoids ratchet desync + lock contention during rapid switching.
        if !MLSAppActivityState.shouldNSEDecrypt(recipientUserDID: recipientDid) {
            logger.info("⏭️ [NSE] Main app active for recipient - skipping decryption")
            bestAttemptContent.title = "New Message"
            bestAttemptContent.body = "New Encrypted Message"
            contentHandler(bestAttemptContent)
            return
        }

        // HARD GATE: if we can't acquire the advisory lock immediately, assume the app is active.
        let lockAcquired = MLSAdvisoryLockCoordinator.shared.tryAcquireExclusiveLock(for: recipientDid)
        if !lockAcquired {
            logger.info("🔒 [NSE] Cannot acquire advisory lock - showing generic notification")
            bestAttemptContent.title = "New Message"
            bestAttemptContent.body = "New Encrypted Message"
            contentHandler(bestAttemptContent)
            return
        }
        defer {
            MLSAdvisoryLockCoordinator.shared.releaseExclusiveLock(for: recipientDid)
        }

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
            do {
                // OPTIMIZATION: Check if message is already cached (decrypted by main app)
                // This avoids expensive MLS decryption if the message was already processed
                if let cachedPlaintext = await MLSCoreContext.shared.getCachedPlaintext(messageID: messageId, userDid: recipientDid) {
                    self.logger.info("📦 [NSE] Cache HIT - message already decrypted, using cached content")
                    capturedBestAttemptContent.title = "New Message"
                    capturedBestAttemptContent.body = cachedPlaintext
                    capturedContentHandler(capturedBestAttemptContent)
                    return
                }
                self.logger.debug("📭 [NSE] Cache MISS - proceeding with decryption")
                
                // CRITICAL FIX: Ensure MLS context is for the correct recipient user
                // This handles account switching where the NSE may have stale context cached
                self.logger.info("🔄 [NSE] Ensuring MLS context for recipient: \(recipientDid.prefix(24))...")
                try await MLSCoreContext.shared.ensureContext(for: recipientDid)
                self.logger.info("✅ [NSE] MLS context verified for recipient")
                
                // Convert base64 ciphertext to Data
                guard let ciphertextData = Data(base64Encoded: ciphertext) else {
                    self.logger.error("❌ [NSE] Invalid base64 ciphertext - length=\(ciphertext.count), first32=\(String(ciphertext.prefix(32)))...")
                    capturedBestAttemptContent.title = "New Message"
                    capturedBestAttemptContent.body = "New Encrypted Message"
                    capturedContentHandler(capturedBestAttemptContent)
                    return
                }
                
                self.logger.info("📊 [NSE] Ciphertext decoded: \(ciphertextData.count) bytes")

                // Convert convoId to groupId (hex decode or utf8 fallback)
                let groupIdData: Data
                if let hexData = Data(hexEncoded: convoId) {
                    groupIdData = hexData
                    self.logger.info("🔢 [NSE] GroupId parsed as hex: \(hexData.count) bytes")
                } else {
                    groupIdData = Data(convoId.utf8)
                    self.logger.info("🔤 [NSE] GroupId parsed as UTF-8 fallback: \(groupIdData.count) bytes")
                }

                self.logger.info("🔓 [NSE] Starting decryption for message=\(messageId.prefix(16))..., user=\(recipientDid.prefix(24))...")

                // Use shared MLSCoreContext with EPHEMERAL access for notifications
                // This prevents database lock contention with the main app
                let decryptResult = try await MLSCoreContext.shared.decryptForNotification(
                    userDid: recipientDid,
                    groupId: groupIdData,
                    ciphertext: ciphertextData,
                    conversationID: convoId,
                    messageID: messageId
                )

                self.logger.info("✅ [NSE] Decryption SUCCESS - plaintext length=\(decryptResult.plaintext.count), sender=\(decryptResult.senderDID?.prefix(24) ?? "unknown")...")
                
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

            } catch {
                // Log detailed error information
                self.logger.error("❌ [NSE] Decryption FAILED: \(error.localizedDescription)")
                self.logger.error("❌ [NSE] Error type: \(String(describing: error))")
                
                // Try to extract more details from the error
                if let nsError = error as NSError? {
                    self.logger.error("❌ [NSE] NSError domain=\(nsError.domain), code=\(nsError.code)")
                    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                        self.logger.error("❌ [NSE] Underlying error: \(underlying.localizedDescription)")
                    }
                }
                
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
            // 3. Acquire advisory lock - POSIX-level coordination
            // 4. Close with TRUNCATE checkpoint - ensures clean WAL state
            // 5. Post stateChanged notification - tells app to reload
            //
            // ═══════════════════════════════════════════════════════════════════════════
            
            // Step 1: Post nseWillClose notification
            self.logger.info("📢 [NSE] Posting nseWillClose notification")
            MLSStateChangeNotifier.postNSEWillClose()
            
            // Step 2: Wait for app acknowledgment (with timeout)
            let acked = MLSStateChangeNotifier.waitForAppAcknowledgment(timeout: 1.5)
            if acked {
                self.logger.info("✅ [NSE] App acknowledged - waiting for connection release")
                // Give the app's connection a moment to fully close
                // The app calls releaseConnectionWithoutCheckpoint which takes ~50ms
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms safety buffer
            } else {
                self.logger.warning("⏱️ [NSE] App acknowledgment timeout - skipping close sequence")
                return
            }
            
            // Step 3: Acquire advisory lock for cross-process coordination
            self.logger.info("🔐 [NSE] Acquiring advisory lock for: \(recipientDid.prefix(20))...")
            let locked = MLSAdvisoryLockCoordinator.shared.acquireExclusiveLock(for: recipientDid, timeout: 2.0)
            guard locked else {
                self.logger.warning("⏱️ [NSE] Advisory lock timeout - skipping close sequence")
                return
            }
            defer { MLSAdvisoryLockCoordinator.shared.releaseExclusiveLock(for: recipientDid) }
            self.logger.info("🔐 [NSE] Advisory lock acquired")
            
            // Step 4: Close with TRUNCATE checkpoint (Phase 1 change in MLSGRDBManager)
            let closeSuccess = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: recipientDid, timeout: 2.0)
            if closeSuccess {
                self.logger.info("✅ [NSE] Database closed with TRUNCATE checkpoint")
            } else {
                self.logger.warning("⚠️ [NSE] Database close timed out - handles may persist until NSE terminates")
            }
            
            // Step 5: Post stateChanged notification - tells app to reload
            MLSStateChangeNotifier.postStateChanged()
            self.logger.info("📢 [NSE] Posted state change notification to main app")
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        logger.warning("⏱️ [NSE] serviceExtensionTimeWillExpire called - system is terminating extension")
        
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
            did.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? did
        }
        
        // CRITICAL: Check if this is a self-sent message AFTER decryption (E2EE safe)
        // We should NOT show notifications for messages we sent ourselves
        if let senderDid = canonicalSenderDid {
            let normalizedSender = senderDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedRecipient = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            if normalizedSender == normalizedRecipient {
                logger.info("🔇 [NSE] Self-sent message detected (sender == recipient) - suppressing notification")
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
                if let memberInfo = await getMemberInfo(senderDid: senderDid, convoId: convoId, recipientDid: recipientDid) {
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
        
        // Set body to the decrypted message
        content.body = decryptedText
        
        // Add userInfo for tap handling - allows app to navigate to correct conversation
        var userInfo = content.userInfo
        userInfo["type"] = "mls_message"
        userInfo["convo_id"] = convoId
        userInfo["recipient_did"] = recipientDid
        userInfo["message_id"] = messageId
        content.userInfo = userInfo
        
        // Try to attach sender's profile photo
        if let avatarURLString = senderAvatarURL,
           let avatarURL = URL(string: avatarURLString) {
            await attachProfilePhoto(to: content, from: avatarURL)
        }
        
        // Set category for notification actions if needed
        content.categoryIdentifier = "MLS_MESSAGE"
        
        // Set thread identifier for grouping notifications by conversation
        content.threadIdentifier = "mls-\(convoId)"
        
        logger.info("✅ [NSE] Rich notification configured - title: \(content.title), body length: \(content.body.count)")
        return true  // Show notification
    }
    
    /// Gets the sender DID from the stored message (after decryption)
    /// This is E2EE safe because sender identity is only available post-decryption
    /// from the cryptographically authenticated MLS credential
    private func getSenderFromMessage(messageId: String, recipientDid: String) async -> String? {
        do {
            let database = try await MLSGRDBManager.shared.getEphemeralDatabasePool(for: recipientDid)
            
            // Normalize the recipient DID for consistent lookup (DIDs are stored normalized)
            let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            let message = try await database.read { db in
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
            let database = try await MLSGRDBManager.shared.getEphemeralDatabasePool(for: recipientDid)
            
            // Normalize the recipient DID for consistent lookup (DIDs are stored normalized)
            let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            let conversation = try await database.read { db in
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
    private func getMemberInfo(senderDid: String, convoId: String, recipientDid: String) async -> (displayName: String?, handle: String?)? {
        do {
            let database = try await MLSGRDBManager.shared.getEphemeralDatabasePool(for: recipientDid)
            
            // Normalize the DID for consistent lookup (DIDs are stored normalized in the database)
            let normalizedSenderDid = senderDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            // Normalize the recipient DID for consistent scoping (tables are per-user)
            let normalizedRecipientDid = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            let member = try await database.read { db in
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
        logger.debug("🖼️ [NSE] Attempting to download profile photo: \(url.absoluteString.prefix(50))...")
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
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
