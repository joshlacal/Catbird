//
//  MLSConfiguration.swift
//  Catbird
//
//  MLS configuration for security and retention policies
//

import Foundation
import OSLog

/// Configuration for MLS security and key management
public struct MLSConfiguration {
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConfiguration")

  // MARK: - Forward Secrecy Configuration

  /// Maximum number of past epochs to retain for forward secrecy
  /// - 0: Delete immediately after epoch change (maximum forward secrecy)
  /// - 1-5: Retain recent epochs for late joiners or message delivery
  /// - Default: 2 (balance between security and usability)
  public let maxPastEpochs: Int

  /// Number of out-of-order messages tolerated in sender ratchet
  /// Higher values allow more message reordering but increase vulnerability window
  /// Default: 10
  public let outOfOrderTolerance: Int

  /// Maximum forward distance in sender ratchet generations
  /// Limits how far ahead a sender can ratchet before synchronization required
  /// Default: 2000
  public let maximumForwardDistance: Int

  /// Whether to use ciphertext wire format (true) or plaintext (false)
  /// Ciphertext provides better privacy by encrypting message metadata
  /// Default: true
  /// NOTE: Deprecated in favor of wireFormat
  public let useCiphertext: Bool

  /// Maximum age of message keys before cleanup
  /// Default: 30 days
  public let messageKeyRetentionDays: Int

  /// Enable automatic background cleanup of old keys
  /// Default: true
  public let enableAutomaticCleanup: Bool

  /// Interval for background cleanup task (in seconds)
  /// Default: 3600 (1 hour)
  public let cleanupInterval: TimeInterval

  // MARK: - Security Configuration

  /// Cipher suite for new groups
  public let defaultCipherSuite: String

  /// Key package refresh interval (in seconds)
  /// Default: 86400 (24 hours)
  public let keyPackageRefreshInterval: TimeInterval

  // MARK: - Initialization

  /// Initialize MLS configuration with custom values
  public init(
    maxPastEpochs: Int = 2,
    outOfOrderTolerance: Int = 10,
    maximumForwardDistance: Int = 2000,
    useCiphertext: Bool = true,
    messageKeyRetentionDays: Int = 30,
    enableAutomaticCleanup: Bool = true,
    cleanupInterval: TimeInterval = 3600,
    defaultCipherSuite: String = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    keyPackageRefreshInterval: TimeInterval = 86400
  ) {
    self.maxPastEpochs = max(0, maxPastEpochs)
    self.outOfOrderTolerance = max(1, outOfOrderTolerance)
    self.maximumForwardDistance = max(100, maximumForwardDistance)
    self.useCiphertext = useCiphertext
    self.messageKeyRetentionDays = max(1, messageKeyRetentionDays)
    self.enableAutomaticCleanup = enableAutomaticCleanup
    self.cleanupInterval = max(300, cleanupInterval)
    self.defaultCipherSuite = defaultCipherSuite
    self.keyPackageRefreshInterval = max(3600, keyPackageRefreshInterval)
  }

  /// Default configuration with balanced security and usability
  public static let `default` = MLSConfiguration()

  /// Maximum forward secrecy configuration
  /// Deletes key material immediately after use
  public static let maxForwardSecrecy = MLSConfiguration(
    maxPastEpochs: 0,
    outOfOrderTolerance: 5,
    maximumForwardDistance: 1000,
    useCiphertext: true,
    messageKeyRetentionDays: 7,
    enableAutomaticCleanup: true,
    cleanupInterval: 1800
  )

  /// Reliable configuration for unreliable network conditions
  /// Allows more out-of-order delivery and message reordering
  public static let reliable = MLSConfiguration(
    maxPastEpochs: 3,
    outOfOrderTolerance: 50,
    maximumForwardDistance: 5000,
    useCiphertext: true,
    messageKeyRetentionDays: 30,
    enableAutomaticCleanup: true,
    cleanupInterval: 3600
  )

  /// Relaxed configuration for development/testing
  public static let development = MLSConfiguration(
    maxPastEpochs: 5,
    outOfOrderTolerance: 100,
    maximumForwardDistance: 10000,
    useCiphertext: false,
    messageKeyRetentionDays: 90,
    enableAutomaticCleanup: false,
    cleanupInterval: 7200
  )

  // MARK: - Computed Properties

  /// Date threshold for message key cleanup
  public var messageKeyCleanupThreshold: Date {
    Calendar.current.date(
      byAdding: .day,
      value: -messageKeyRetentionDays,
      to: Date()
    ) ?? Date()
  }

  /// Convert to MLSGroupConfiguration for MLS client operations
  public var groupConfiguration: MLSGroupConfiguration {
    return MLSGroupConfiguration(
      maxPastEpochs: UInt32(maxPastEpochs),
      outOfOrderTolerance: UInt32(outOfOrderTolerance),
      maximumForwardDistance: UInt32(maximumForwardDistance),
      useCiphertext: useCiphertext
    )
  }

  // MARK: - Validation

  /// Validate configuration and log warnings for insecure settings
  public func validate() {
    if maxPastEpochs > 5 {
      logger.warning("maxPastEpochs set to \(self.maxPastEpochs), which may reduce forward secrecy")
    }

    if messageKeyRetentionDays > 90 {
      logger.warning("messageKeyRetentionDays set to \(self.messageKeyRetentionDays), which may increase storage usage")
    }

    if !enableAutomaticCleanup {
      logger.warning("Automatic cleanup is disabled - key material may accumulate")
    }

    logger.info("MLS Configuration validated: maxPastEpochs=\(self.maxPastEpochs), messageKeyRetention=\(self.messageKeyRetentionDays)d")
  }
}
