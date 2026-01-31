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
      guard let self = self else {
        task.setTaskCompleted(success: false)
        return
      }

      Task {
        await self.handleBackgroundRefresh(task: task as! BGProcessingTask)
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

    var backgroundTaskCompleted = false

    // Handle expiration - system may terminate us before we finish
    task.expirationHandler = { [weak self] in
      self?.logger.warning("Background task expired before completion")
      backgroundTaskCompleted = true
    }

    do {
      // Check if task was cancelled before we start
      guard !backgroundTaskCompleted else {
        logger.warning("Background task expired before MLS check")
        task.setTaskCompleted(success: false)
        return
      }

      // Get AppState to access MLS manager
      guard let appState = await getAppState() else {
        logger.error("Background refresh failed: AppState not available")
        task.setTaskCompleted(success: false)
        scheduleBackgroundRefresh()
        return
      }

      // Get MLS conversation manager
      guard let mlsManager = await appState.getMLSConversationManager() else {
        logger.warning("Background refresh skipped: MLS not initialized")
        task.setTaskCompleted(success: true)
        scheduleBackgroundRefresh()
        return
      }

      // Check if task was cancelled before expensive operation
      guard !backgroundTaskCompleted else {
        logger.warning("Background task expired during initialization")
        task.setTaskCompleted(success: false)
        return
      }

      // Execute key package refresh
      try await mlsManager.smartRefreshKeyPackages()

      logger.info("Background refresh completed successfully")
      task.setTaskCompleted(success: true)
    } catch {
      logger.error("Background refresh failed: \(error)")
      task.setTaskCompleted(success: false)
    }

    // Always schedule next run, even if this one failed
    scheduleBackgroundRefresh()
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
