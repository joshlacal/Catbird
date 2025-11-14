//
//  MLSStorage+EpochSecretStorage.swift
//  Catbird
//
//  Epoch secret storage bridge for MLS FFI
//

import Foundation
import os.log

/// Epoch secret storage implementation for MLS FFI callback
///
/// Bridges async MLSStorage methods to synchronous FFI callbacks using semaphores.
/// This is safe because:
/// 1. Database operations are quick (SQLCipher reads/writes)
/// 2. Rust FFI calls from background threads
/// 3. Semaphore prevents concurrent access issues
final class MLSEpochSecretStorageBridge: EpochSecretStorage {

  private let storage = MLSStorage.shared
  private let logger = Logger(subsystem: "com.catbird.mls", category: "EpochSecretStorage")

  func storeEpochSecret(conversationId: String, epoch: UInt64, secretData: Data) -> Bool {
    logger.debug("[EPOCH-STORAGE] storeEpochSecret called: conversation=\(conversationId), epoch=\(epoch), \(secretData.count) bytes")

    // Use semaphore to bridge async -> sync for FFI callback
    let semaphore = DispatchSemaphore(value: 0)
    var result = false

    Task {
      do {
        let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: await getUserDID())

        // ⭐ CRITICAL FIX: Ensure conversation exists BEFORE storing epoch secret
        // The Rust FFI passes groupIdHex as conversationId, so we use it for both fields
        try await storage.ensureConversationExists(
          conversationID: conversationId,  // Use groupIdHex from Rust FFI
          groupID: conversationId,          // Same value for groupID
          database: database
        )

        try await storage.saveEpochSecret(
          conversationID: conversationId,
          epoch: epoch,
          secretData: secretData,
          database: database
        )
        result = true
        logger.info("[EPOCH-STORAGE] ✅ Stored epoch secret successfully")
      } catch {
        logger.error("[EPOCH-STORAGE] ❌ Failed to store epoch secret: \(error.localizedDescription)")
        result = false
      }
      semaphore.signal()
    }

    semaphore.wait()
    return result
  }

  func getEpochSecret(conversationId: String, epoch: UInt64) -> Data? {
    logger.debug("[EPOCH-STORAGE] getEpochSecret called: conversation=\(conversationId), epoch=\(epoch)")

    // Use semaphore to bridge async -> sync for FFI callback
    let semaphore = DispatchSemaphore(value: 0)
    var secretData: Data?

    Task {
      do {
        let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: await getUserDID())
        secretData = try await storage.getEpochSecret(
          conversationID: conversationId,
          epoch: epoch,
          database: database
        )

        if let data = secretData {
          logger.info("[EPOCH-STORAGE] ✅ Retrieved epoch secret: \(data.count) bytes")
        } else {
          logger.debug("[EPOCH-STORAGE] No epoch secret found")
        }
      } catch {
        logger.error("[EPOCH-STORAGE] ❌ Failed to retrieve epoch secret: \(error.localizedDescription)")
        secretData = nil
      }
      semaphore.signal()
    }

    semaphore.wait()
    return secretData
  }

  func deleteEpochSecret(conversationId: String, epoch: UInt64) -> Bool {
    logger.debug("[EPOCH-STORAGE] deleteEpochSecret called: conversation=\(conversationId), epoch=\(epoch)")

    // Use semaphore to bridge async -> sync for FFI callback
    let semaphore = DispatchSemaphore(value: 0)
    var result = false

    Task {
      do {
        let database = try await MLSGRDBManager.shared.getDatabaseQueue(for: await getUserDID())
        try await storage.deleteEpochSecret(
          conversationID: conversationId,
          epoch: epoch,
          database: database
        )
        result = true
        logger.info("[EPOCH-STORAGE] ✅ Deleted epoch secret successfully")
      } catch {
        logger.error("[EPOCH-STORAGE] ❌ Failed to delete epoch secret: \(error.localizedDescription)")
        result = false
      }
      semaphore.signal()
    }

    semaphore.wait()
    return result
  }

  @MainActor
  private func getUserDID() async -> String {
    // During account transition, use empty string as fallback
    // The storage layer will handle authentication errors
    return AppStateManager.shared.lifecycle.appState?.userDID ?? ""
  }
}
