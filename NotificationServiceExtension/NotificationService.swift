import UserNotifications
import os.log
import Foundation
import CatbirdMLSCore

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private let logger = Logger(subsystem: "blue.catbird.notification-service", category: "NotificationService")

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
        // - sender_did: The DID of the message sender (used to detect self-sent messages)
        let ciphertext = userInfo["ciphertext"] as? String
        let convoId = userInfo["convo_id"] as? String
        let messageId = userInfo["message_id"] as? String
        let recipientDid = userInfo["recipient_did"] as? String
        let senderDid = userInfo["sender_did"] as? String
        
        // Log which fields are present/missing
        logger.info("📦 [NSE] Fields: ciphertext=\(ciphertext != nil), convo_id=\(convoId != nil), message_id=\(messageId != nil), recipient_did=\(recipientDid != nil), sender_did=\(senderDid != nil)")
        
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

        // CRITICAL: Check if this is a self-sent message
        // We should NOT show notifications for messages we sent ourselves
        // Compare sender_did with recipient_did (normalized to lowercase for case-insensitive comparison)
        if let senderDid = senderDid {
            let normalizedSender = senderDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedRecipient = recipientDid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            if normalizedSender == normalizedRecipient {
                logger.info("🔇 [NSE] Self-sent message detected (sender == recipient) - suppressing notification")
                // Don't show notification for self-sent messages
                // The main app will display these when it syncs
                return
            }
            logger.debug("👤 [NSE] Message from other user: sender=\(senderDid.prefix(24))...")
        } else {
            logger.debug("⚠️ [NSE] No sender_did in payload - cannot check for self-sent")
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

                // Use shared MLSCoreContext - decrypts AND saves with proper epoch/sequence metadata
                let decryptedText = try await MLSCoreContext.shared.decryptAndStore(
                    userDid: recipientDid,
                    groupId: groupIdData,
                    ciphertext: ciphertextData,
                    conversationID: convoId,
                    messageID: messageId
                )

                self.logger.info("✅ [NSE] Decryption SUCCESS - plaintext length=\(decryptedText.count)")
                
                capturedBestAttemptContent.title = "New Message"
                capturedBestAttemptContent.body = decryptedText

                capturedContentHandler(capturedBestAttemptContent)

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
}
