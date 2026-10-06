//
//  BackgroundCacheRefreshManager.swift
//  Catbird
//
//  Created by Claude on 10/31/25.
//

import Foundation
import SwiftData
import Petrel
import OSLog

#if os(iOS)
import BackgroundTasks
import UIKit
@available(iOS 13.0, *)
enum BackgroundCacheRefreshManager {
  private static let taskIdentifier = "blue.catbird.cache.refresh"
  private static let logger = Logger(subsystem: "blue.catbird", category: "BackgroundCacheRefresh")
  private static var didRegister = false
  private static var lastScheduleTime: Date?

  static func registerIfNeeded() {
    guard !didRegister else {
      logger.debug("Cache BGTask already registered")
      return
    }

    guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
          identifiers.contains(taskIdentifier) else {
      logger.error("Missing cache BGTask identifier in Info.plist")
      return
    }

    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        logger.error("Received unexpected task type: \(type(of: task))")
        task.setTaskCompleted(success: false)
        return
      }
      handle(task: refreshTask)
    }

    didRegister = true
    logger.info("Registered cache background refresh task")
  }

  static func schedule() {
      if !didRegister {
        logger.info("Lazily registering cache BGTask before scheduling")
        registerIfNeeded()
    }

    let now = Date()
    if let lastSubmission = lastScheduleTime, now.timeIntervalSince(lastSubmission) < 60 {
      logger.debug("Skipping cache BGTask reschedule due to throttle window")
      return
    }

    lastScheduleTime = now

    let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
    // Run every 30 minutes for cache updates
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

    do {
      try BGTaskScheduler.shared.submit(request)
      logger.debug("Scheduled cache background refresh task")
    } catch {
      logger.error("Failed to submit cache BGTask: \(error.localizedDescription)")
    }
  }

  private static func handle(task: BGAppRefreshTask) {
    logger.info("Cache BGTask started")

    // While running in background, ensure GRDB connections are resumed for the duration
    // of this task, and re-suspended once it completes to avoid 0xdead10cc termination.
    GRDBSuspensionCoordinator.beginBackgroundWork(reason: "Cache BGTask \(taskIdentifier)")

    // RAII background task assertion — auto-released on scope exit
    let bgTask = CatbirdBackgroundTask(name: "BGTask-\(taskIdentifier)")

    // Schedule next refresh
    schedule()

    let refreshWork = Task<Bool, Never> {
      // Capture AppContext on main actor before starting background work
      let context = await MainActor.run {
        guard let appState = AppStateManager.shared.lifecycle.appState else {
          return AppContext.unauthenticated
        }
        return AppContext.from(appState)
      }

      guard context.isValidForBackgroundWork else {
        logger.info("Skipping cache refresh - user not authenticated")
        return true
      }

      // 1. Prefetch new notifications and cache posts
      if Task.isCancelled { return false }
      if context.notificationsEnabled, let notificationManager = context.notificationManager {
        logger.debug("Prefetching notification content in background")
        await notificationManager.checkUnreadNotifications()
        // NotificationManager.prefetchNotificationContent() already saves to cache
      }

      // Timeline and thread caches are not refreshed here: the app reads them from its
      // private SwiftData store, and writing SwiftData from a background task is what
      // previously caused 0xdead10cc terminations.

      if Task.isCancelled { return false }
      logger.info("Cache BGTask finished successfully")
      return true
    }

    task.expirationHandler = {
      logger.warning("Cache BGTask expired")
      refreshWork.cancel()
    }

    Task {
      let success = await refreshWork.value
      GRDBSuspensionCoordinator.endBackgroundWork(reason: "Cache BGTask \(taskIdentifier)")
      bgTask.end()
      task.setTaskCompleted(success: success)
    }
  }
}
#endif
