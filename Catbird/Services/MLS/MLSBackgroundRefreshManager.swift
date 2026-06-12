//
//  MLSBackgroundRefreshManager.swift
//  Catbird
//
//  Created by Claude Code
//

#if os(iOS)
import BackgroundTasks
import CatbirdMLSCore
import Foundation
import OSLog

/// Manages automatic background replenishment of MLS key packages
/// Uses iOS BGTaskScheduler to periodically check and upload key packages when running low
@available(iOS 13.0, *)
actor MLSBackgroundRefreshManager {
  static let shared = MLSBackgroundRefreshManager()
  static let taskIdentifier = "blue.catbird.key-package-refresh"

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSBackgroundRefresh")
  
  /// Track whether registration has completed
  private var isRegistered = false

  private init() {}

  // MARK: - Public API

  /// Register the background task handler with BGTaskScheduler
  /// Must be called before application finishes launching
  func registerBackgroundTask() {
    guard !isRegistered else {
      logger.debug("Background task already registered, skipping")
      return
    }
    
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }

      guard let self = self else {
        task.setTaskCompleted(success: false)
        return
      }

      Task {
        await self.handleBackgroundRefresh(task: processingTask)
      }
    }

    isRegistered = true
    logger.info("Registered background task: \(Self.taskIdentifier)")
  }

  /// Schedule the next background refresh
  /// - Parameter delay: Time interval until next run (default: 24 hours)
  func scheduleBackgroundRefresh(delay: TimeInterval = 24 * 60 * 60) {
    let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: delay)

    do {
      try BGTaskScheduler.shared.submit(request)
      logger.info("Scheduled background refresh for \(delay) seconds from now")
    } catch {
      logger.error("Failed to schedule background refresh: \(error)")
    }
  }

  /// Cancel any pending background refresh tasks
  func cancelBackgroundRefresh() {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    logger.info("Cancelled scheduled background refresh")
  }

  /// Called by AppDelegate when the BGTask handler fires
  /// (registration happens synchronously in didFinishLaunchingWithOptions)
  func handleRegisteredTask(_ task: BGProcessingTask) async {
    isRegistered = true
    await handleBackgroundRefresh(task: task)
  }

  // MARK: - Background Task Handling

  /// Handle background refresh execution
  /// - Parameter task: BGProcessingTask provided by the system
  private func handleBackgroundRefresh(task: BGProcessingTask) async {
    logger.info("Background refresh starting")
    defer { scheduleBackgroundRefresh() }

    // BGTasks run while the app lifecycle is backgrounded; allow MLS contexts to be created for this work.
    MLSClient.clearSuspensionFlag(reason: "MLS BGTask \(Self.taskIdentifier)")
    MLSCoreContext.clearSuspensionFlag()

    // RAII background task assertion — auto-released on scope exit.
    // The expiration handler must interrupt in-flight SQLCipher work: Swift Task
    // cancellation is cooperative and a blocking Rust FFI call never observes it,
    // so without sqlite3_interrupt the process suspends mid-fsync → 0xdead10cc.
    let bgTask = CatbirdBackgroundTask(name: "MLS BGTask \(Self.taskIdentifier)") {
      MLSClient.markSuspensionInProgress(reason: "MLS BGTask assertion expired")
      MLSCoreContext.markSuspensionInProgress()
      MLSClient.interruptAllContexts()
      MLSCoreContext.interruptAllContexts()
    }
    defer { bgTask.end() }

    // While running in background, ensure GRDB connections are resumed for the duration
    // of this task, and re-suspended once it completes to avoid 0xdead10cc termination.
    GRDBSuspensionCoordinator.beginBackgroundWork(reason: "MLS BGTask \(Self.taskIdentifier)")

    // One-shot cleanup: must run BEFORE setTaskCompleted (iOS may suspend the
    // process immediately after task completion), with the defer as a backstop
    // for early-exit/throw paths. One-shot because endBackgroundWork is
    // refcounted — a double call would steal a unit from concurrent work.
    var cleanedUp = false
    func closeContextsAndSuspend() {
      guard !cleanedUp else { return }
      cleanedUp = true
      // Ensure Rust UniFFI contexts are closed before we re-suspend, or iOS may kill us (0xdead10cc).
      MLSClient.emergencyCloseAllContexts(reason: "MLS BGTask complete")
      MLSCoreContext.emergencyCloseAllContexts()
      GRDBSuspensionCoordinator.endBackgroundWork(reason: "MLS BGTask \(Self.taskIdentifier)")
    }
    defer { closeContextsAndSuspend() }

    let logger = self.logger
    let refreshWork = Task<Bool, Never> { [weak self] in
      guard let self else { return false }

      guard let appState = await self.getAppState() else {
        logger.error("Background refresh failed: AppState not available")
        return false
      }

      // Get MLS conversation manager
      guard let mlsManager = await appState.getMLSConversationManager() else {
        logger.warning("Background refresh skipped: MLS not initialized")
        return true
      }

      do {
        try Task.checkCancellation()
        try await mlsManager.smartRefreshKeyPackages(maxGeneratedPackages: 5)
        try Task.checkCancellation()
        logger.info("Background refresh completed successfully")
        return true
      } catch is CancellationError {
        logger.warning("Background refresh canceled")
        return false
      } catch {
        logger.error("Background refresh failed: \(error)")
        return false
      }
    }

    task.expirationHandler = {
      logger.warning("Background task expired before completion; interrupting MLS FFI and canceling refresh")
      // Arm the suspension machinery BEFORE the cooperative cancel: the
      // suspension flag makes runFFI and the Rust check_suspended() bail-outs
      // reject the rest of the batch, and sqlite3_interrupt aborts the
      // statement currently holding the SQLCipher file lock. Task.cancel()
      // alone never reaches a blocking FFI call (0xdead10cc root cause).
      MLSClient.markSuspensionInProgress(reason: "MLS BGTask expired")
      MLSCoreContext.markSuspensionInProgress()
      MLSClient.interruptAllContexts()
      MLSCoreContext.interruptAllContexts()
      refreshWork.cancel()
    }

    let success = await refreshWork.value

    closeContextsAndSuspend()
    task.setTaskCompleted(success: success)
  }

  // MARK: - Helper Methods

  /// Get the current AppState instance
  /// - Returns: AppState if available, nil otherwise
  private func getAppState() async -> AppState? {
    await MainActor.run {
      let appStateManager = AppStateManager.shared
      return appStateManager.lifecycle.appState
    }
  }
}

// MARK: - Registration Helper

@available(iOS 13.0, *)
extension MLSBackgroundRefreshManager {
  /// One-time registration call to ensure task is registered early
  /// Call this from app initialization before SwiftUI rendering
  static func registerIfNeeded() {
    Task {
      await MLSBackgroundRefreshManager.shared.registerBackgroundTask()
    }
  }

  /// Schedule initial refresh after MLS is initialized
  /// Call this after successful MLS initialization
  static func scheduleInitialRefresh() {
    Task {
      await MLSBackgroundRefreshManager.shared.scheduleBackgroundRefresh()
    }
  }
}

#endif
