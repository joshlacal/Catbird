//
//  MLSBackgroundRefreshManager.swift
//  Catbird
//
//  Created by Claude Code
//

import BackgroundTasks
import CatbirdMLSService
import Foundation
import OSLog

/// Manages automatic background replenishment of MLS key packages
/// Uses iOS BGTaskScheduler to periodically check and upload key packages when running low
@available(iOS 13.0, *)
actor MLSBackgroundRefreshManager {
  static let shared = MLSBackgroundRefreshManager()

  private let taskIdentifier = "blue.catbird.key-package-refresh"
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
      forTaskWithIdentifier: taskIdentifier,
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
    logger.info("Registered background task: \(self.taskIdentifier)")
  }

  /// Schedule the next background refresh
  /// - Parameter delay: Time interval until next run (default: 24 hours)
  func scheduleBackgroundRefresh(delay: TimeInterval = 24 * 60 * 60) {
    if !isRegistered {
      logger.info("Lazily registering background task before scheduling")
      registerBackgroundTask()
    }
    
    let request = BGProcessingTaskRequest(identifier: taskIdentifier)
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
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    logger.info("Cancelled scheduled background refresh")
  }

  // MARK: - Background Task Handling

  /// Handle background refresh execution
  /// - Parameter task: BGProcessingTask provided by the system
  private func handleBackgroundRefresh(task: BGProcessingTask) async {
    logger.info("Background refresh starting")
    defer { scheduleBackgroundRefresh() }

    // RAII background task assertion — auto-released on scope exit
    let bgTask = CatbirdBackgroundTask(name: "MLS BGTask \(taskIdentifier)")
    defer { bgTask.end() }

    // While running in background, ensure GRDB connections are resumed for the duration
    // of this task, and re-suspended once it completes to avoid 0xdead10cc termination.
    GRDBSuspensionCoordinator.beginBackgroundWork(reason: "MLS BGTask \(taskIdentifier)")
    defer {
      GRDBSuspensionCoordinator.endBackgroundWork(reason: "MLS BGTask \(taskIdentifier)")
    }

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
        try await mlsManager.smartRefreshKeyPackages()
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
      logger.warning("Background task expired before completion; canceling refresh")
      refreshWork.cancel()
    }

    let success = await refreshWork.value
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
