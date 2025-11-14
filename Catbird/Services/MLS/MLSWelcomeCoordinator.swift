//
//  MLSWelcomeCoordinator.swift
//  Catbird
//
//  Created for managing concurrent Welcome message processing
//

import Foundation
import OSLog

/// Actor that coordinates Welcome message processing to prevent concurrent processing
/// of the same conversation, which would cause OpenMLS key package consumption errors.
actor MLSWelcomeCoordinator {
  private var processingConversations: Set<String> = []
  private let logger = Logger(subsystem: "Catbird", category: "MLSWelcomeCoordinator")

  /// Maximum number of attempts to acquire processing lock before timing out
  private let maxWaitAttempts = 30

  /// Duration to wait between retry attempts (100ms)
  private let retryDelayNanoseconds: UInt64 = 100_000_000

  /// Acquire exclusive lock for processing a conversation's Welcome message.
  ///
  /// This method implements a wait-and-retry strategy when another task is already
  /// processing the same conversation. It will wait up to 3 seconds (30 attempts × 100ms)
  /// before timing out.
  ///
  /// - Parameter conversationId: The unique identifier of the conversation
  /// - Throws: `MLSError.welcomeProcessingTimeout` if unable to acquire lock within timeout period
  func acquireProcessingLock(conversationId: String) async throws {
    var attempts = 0

    // Wait loop: retry if conversation is already being processed
    while processingConversations.contains(conversationId) {
      attempts += 1

      if attempts >= maxWaitAttempts {
        logger.error("❌ Timeout waiting for Welcome processing lock on conversation \(conversationId) after \(attempts) attempts")
        throw MLSError.welcomeProcessingTimeout(
          message: "Timed out waiting for Welcome processing of conversation \(conversationId)"
        )
      }

      logger.info("⏳ Conversation \(conversationId) already being processed, waiting... (attempt \(attempts)/\(self.maxWaitAttempts))")

      // Wait 100ms before retrying
      try await Task.sleep(nanoseconds: retryDelayNanoseconds)
    }

    // Acquire lock by inserting conversation ID
    processingConversations.insert(conversationId)
    logger.info("🔒 Acquired Welcome processing lock for conversation \(conversationId)")
  }

  /// Release the processing lock for a conversation.
  ///
  /// This should be called when Welcome processing completes, whether successful or failed.
  /// Use a `defer` block to ensure this is always called.
  ///
  /// - Parameter conversationId: The unique identifier of the conversation
  func releaseProcessingLock(conversationId: String) {
    let wasRemoved = processingConversations.remove(conversationId) != nil

    if wasRemoved {
      logger.info("🔓 Released Welcome processing lock for conversation \(conversationId)")
    } else {
      logger.warning("⚠️ Attempted to release lock for conversation \(conversationId) but it wasn't in processing set")
    }
  }

  /// Check if a conversation is currently being processed.
  ///
  /// This is primarily for debugging and monitoring purposes.
  ///
  /// - Parameter conversationId: The unique identifier of the conversation
  /// - Returns: `true` if the conversation is currently being processed, `false` otherwise
  func isProcessing(conversationId: String) -> Bool {
    return processingConversations.contains(conversationId)
  }

  /// Get the current number of conversations being processed.
  ///
  /// This is primarily for debugging and monitoring purposes.
  ///
  /// - Returns: The count of conversations currently being processed
  func processingCount() -> Int {
    return processingConversations.count
  }
}
