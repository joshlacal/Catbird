//
//  MLSMessageValidator.swift
//  Catbird
//
//  Pre-processing validation for MLS messages to catch bugs before FFI decryption
//

import Foundation
import OSLog

/// Validation result for MLS messages
enum MessageValidationResult: Sendable {
  case valid
  case invalid(reason: String)

  var isValid: Bool {
    if case .valid = self {
      return true
    }
    return false
  }

  var failureReason: String? {
    if case .invalid(let reason) = self {
      return reason
    }
    return nil
  }
}

/// Pre-processing validator for MLS messages
/// Catches malformed messages before expensive FFI decryption
struct MLSMessageValidator: Sendable {

  // MARK: - Properties

  private static let logger = Logger(subsystem: "Catbird", category: "MLSMessageValidator")

  // Minimum ciphertext size for AES-128-GCM (16 bytes for tag + at least 1 byte payload)
  private static let minCiphertextLength = 17

  // Maximum reasonable epoch (prevent overflow attacks)
  private static let maxEpoch: Int64 = 1_000_000

  // Maximum reasonable sequence number per epoch
  private static let maxSequenceNumber: Int64 = 10_000_000

  // MARK: - Validation Methods

  /// Validate message structure before FFI processing
  /// - Parameters:
  ///   - epoch: Message epoch number
  ///   - sequenceNumber: Message sequence number within epoch
  ///   - ciphertextData: Encrypted message data
  ///   - localEpoch: Current local epoch for this conversation
  /// - Returns: Validation result
  static func validateMessageStructure(
    epoch: Int64,
    sequenceNumber: Int64,
    ciphertextData: Data,
    localEpoch: Int64
  ) -> MessageValidationResult {
    // Validate epoch bounds
    if epoch < 0 {
      logger.warning("⚠️ Invalid epoch: \(epoch) (negative)")
      return .invalid(reason: "Epoch cannot be negative")
    }

    if epoch > maxEpoch {
      logger.warning("⚠️ Invalid epoch: \(epoch) (exceeds maximum \(maxEpoch))")
      return .invalid(reason: "Epoch exceeds maximum allowed value")
    }

    // Validate sequence number bounds
    if sequenceNumber < 0 {
      logger.warning("⚠️ Invalid sequence number: \(sequenceNumber) (negative)")
      return .invalid(reason: "Sequence number cannot be negative")
    }

    if sequenceNumber > maxSequenceNumber {
      logger.warning("⚠️ Invalid sequence number: \(sequenceNumber) (exceeds maximum \(maxSequenceNumber))")
      return .invalid(reason: "Sequence number exceeds maximum allowed value")
    }

    // Validate ciphertext length
    if ciphertextData.count < minCiphertextLength {
      logger.warning("⚠️ Invalid ciphertext length: \(ciphertextData.count) bytes (minimum \(minCiphertextLength))")
      return .invalid(reason: "Ciphertext too short (minimum \(minCiphertextLength) bytes)")
    }

    // Validate epoch is not too far ahead of local state
    let epochDifference = epoch - localEpoch
    if epochDifference > 100 {
      logger.warning("⚠️ Message epoch \(epoch) is \(epochDifference) ahead of local epoch \(localEpoch)")
      return .invalid(reason: "Message epoch too far ahead (possible replay attack or missed commits)")
    }

    // Validate epoch is not behind local state
    if epoch < localEpoch {
      logger.info("ℹ️ Message epoch \(epoch) is behind local epoch \(localEpoch) (late delivery)")
      // Don't fail - this can happen with network delays, but log it
    }

    return .valid
  }

  /// Validate MLS message format structure
  /// - Parameter messageData: Raw message data from server
  /// - Returns: Validation result
  static func validateMLSMessageFormat(messageData: Data) -> MessageValidationResult {
    // Basic MLS message format validation
    // MLS messages have a specific wire format structure

    if messageData.isEmpty {
      logger.warning("⚠️ Empty message data")
      return .invalid(reason: "Message data is empty")
    }

    // MLS messages start with version and wire format type
    // Version is 1 byte, wire format is 1 byte
    if messageData.count < 2 {
      logger.warning("⚠️ Message too short for MLS header: \(messageData.count) bytes")
      return .invalid(reason: "Message data too short for MLS header")
    }

    let version = messageData[0]
    let wireFormat = messageData[1]

    // MLS 1.0 version byte should be 0x00 or 0x01
    if version > 0x01 {
      logger.warning("⚠️ Unknown MLS version: 0x\(String(format: "%02x", version))")
      return .invalid(reason: "Unknown MLS protocol version")
    }

    // Wire format should be one of the known types
    // 0x00 = reserved, 0x01 = PublicMessage, 0x02 = PrivateMessage, 0x03 = Welcome
    if wireFormat > 0x03 {
      logger.warning("⚠️ Unknown MLS wire format: 0x\(String(format: "%02x", wireFormat))")
      return .invalid(reason: "Unknown MLS wire format type")
    }

    return .valid
  }

  /// Compute message integrity hash for verification
  /// - Parameter messageData: Raw message data
  /// - Returns: SHA-256 hash of message data
  static func computeMessageHash(_ messageData: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    messageData.withUnsafeBytes { buffer in
      _ = CC_SHA256(buffer.baseAddress, CC_LONG(messageData.count), &hash)
    }
    return Data(hash)
  }

  /// Validate message hash matches expected value
  /// - Parameters:
  ///   - messageData: Raw message data
  ///   - expectedHash: Expected SHA-256 hash from server
  /// - Returns: Validation result
  static func validateMessageHash(messageData: Data, expectedHash: Data?) -> MessageValidationResult {
    guard let expectedHash = expectedHash else {
      // No hash provided by server - can't validate
      return .valid
    }

    let computedHash = computeMessageHash(messageData)

    if computedHash != expectedHash {
      logger.warning("⚠️ Message hash mismatch (possible corruption or tampering)")
      logger.debug("Expected: \(expectedHash.map { String(format: "%02x", $0) }.joined())")
      logger.debug("Computed: \(computedHash.map { String(format: "%02x", $0) }.joined())")
      return .invalid(reason: "Message integrity check failed (hash mismatch)")
    }

    return .valid
  }

  /// Check if message appears to be a duplicate
  /// - Parameters:
  ///   - messageID: Server message ID
  ///   - processedIDs: Set of recently processed message IDs
  /// - Returns: True if message appears to be a duplicate
  static func isDuplicateMessage(messageID: String, processedIDs: Set<String>) -> Bool {
    return processedIDs.contains(messageID)
  }
}

// MARK: - CommonCrypto Import

import CommonCrypto

private let CC_SHA256_DIGEST_LENGTH = Int(CommonCrypto.CC_SHA256_DIGEST_LENGTH)
