import Foundation
import Petrel

#if os(iOS)

extension MLSConversationManager {
  /// Decrypt message and extract sender from MLS protocol
  /// Returns tuple of (plaintext, senderDID)
  func decryptMessageWithSender(groupId: String, ciphertext: Data) async throws -> (Data, String) {
    logger.info("Decrypting message with sender extraction for group \(groupId.prefix(8))...")

    guard let groupIdData = Data(hexEncoded: groupId) else {
      logger.error("Invalid group ID format")
      throw MLSConversationError.invalidGroupId
    }

    guard let userDid = userDid else {
      throw MLSConversationError.noAuthentication
    }

    // Process the message (this advances the ratchet)
    let processedContent = try await mlsClient.processMessage(
      for: userDid,
      groupId: groupIdData,
      messageData: ciphertext
    )

    // CRITICAL FIX: Persist MLS state after decryption (receiver ratchet advanced)
    do {
      try await mlsClient.saveStorage(for: userDid)
      logger.debug("✅ Persisted MLS state after message decryption")
    } catch {
      logger.error("⚠️ Failed to persist MLS state after decryption: \(error.localizedDescription)")
    }

    // Extract plaintext and sender from processed content
    switch processedContent {
    case .applicationMessage(let plaintext, let senderCredential):
      // Extract sender DID from MLS credential
      let senderDID = try extractDIDFromCredential(senderCredential)

      logger.info("Decrypted application message (\(plaintext.count) bytes) from \(senderDID)")
      return (plaintext, senderDID)

    case .proposal, .stagedCommit:
      // Proposals and commits don't have plaintext content
      // Return empty data with unknown sender
      return (Data(), "unknown")
    }
  }

  /// Extract DID from MLS credential data
  private func extractDIDFromCredential(_ credential: CredentialData) throws -> String {
    // The identity field contains the DID as UTF-8 bytes
    guard let didString = String(data: credential.identity, encoding: .utf8) else {
      logger.error("❌ Failed to decode credential identity as UTF-8")
      throw MLSConversationError.invalidCredential
    }

    // Validate it's a proper DID format
    guard didString.starts(with: "did:") else {
      logger.error("❌ Invalid DID format in credential: \(didString)")
      throw MLSConversationError.invalidCredential
    }

    return didString
  }
}

#endif
