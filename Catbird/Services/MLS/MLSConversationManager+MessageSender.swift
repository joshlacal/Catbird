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

    // MLS state is automatically persisted to SQLite - no manual save needed
    logger.debug("✅ MLS state automatically persisted after message decryption")

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

}

#endif
