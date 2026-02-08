import Foundation
import BackgroundTasks
import os

#if os(iOS)
import UIKit

@available(iOS 13.0, *)
enum BGTaskSchedulerManager {
  static let taskIdentifier = "blue.catbird.posting.retry"
  private static let logger = Logger(subsystem: "blue.catbird", category: "BGTasks")
  private static var didRegister = false
  private static var lastScheduleTime: Date?

  static func registerIfNeeded() {
    // Simple guard - called from main thread during app init
    guard !didRegister else { 
      logger.debug("BGTask registration skipped - already registered")
      return 
    }
    
    // Validate Info.plist configuration to avoid runtime assertion
    guard let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
          permitted.contains(taskIdentifier) else {
      logger.error("BGTask not permitted – missing \(taskIdentifier) in BGTaskSchedulerPermittedIdentifiers")
      return
    }
    
    logger.info("Attempting BGTask registration for identifier: \(taskIdentifier)")
    
    // Register at app init as recommended by Apple - must be before app finishes launching
    // The register method asserts on failure, no try/catch needed
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        logger.error("BGTask handler called with unexpected task type: \(type(of: task))")
        task.setTaskCompleted(success: false)
        return
      }
      handle(task: refreshTask)
    }
    
    didRegister = true
    logger.info("BGTask registration completed for identifier: \(taskIdentifier)")
  }

  static func schedule() {
    // Only schedule if we successfully registered
    if !didRegister {
      logger.info("BGTask scheduling - lazily registering task")
      registerIfNeeded()
    }
    
    // Throttle scheduling to avoid too frequent submissions
    let now = Date()
    if let lastTime = lastScheduleTime, now.timeIntervalSince(lastTime) < 60 {
      logger.debug("BGTask scheduling throttled - last scheduled \(Int(now.timeIntervalSince(lastTime)))s ago")
      return
    }
    
    lastScheduleTime = now
    
    let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    
    do { 
      try BGTaskScheduler.shared.submit(request) 
      logger.debug("BGTask scheduled successfully")
    } catch {
      logger.error("BGTask submit failed: \(error.localizedDescription)")
    }
  }

  private static func handle(task: BGAppRefreshTask) {
    logger.info("BGTask started: \(task.identifier)")

    // While running in background, ensure GRDB connections are resumed for the duration
    // of this task, and re-suspended once it completes to avoid 0xdead10cc termination.
    GRDBSuspensionCoordinator.beginBackgroundWork(reason: "Posting BGTask \(taskIdentifier)")

    // RAII background task assertion — auto-released on scope exit.
    let bgTask = CatbirdBackgroundTask(name: "BGTask-\(taskIdentifier)")

    // Schedule next execution
    schedule()

    // Process outbox items with bounded work and cancellation support.
    let retryWork = Task<Bool, Never> {
      guard let activeState = await AppStateManager.shared.lifecycle.appState else {
        logger.warning("BGTask - no active state available")
        return false
      }
      if Task.isCancelled { return false }

      // Signal-style background defense: keep batches small while backgrounded.
      await ComposerOutbox.shared.processAll(appState: activeState, maxItems: 1)
      if Task.isCancelled { return false }

      logger.info("BGTask completed successfully")
      return true
    }

    task.expirationHandler = {
      logger.warning("BGTask expired before completion; canceling retry work")
      retryWork.cancel()
    }

    Task {
      defer {
        bgTask.end()
        GRDBSuspensionCoordinator.endBackgroundWork(reason: "Posting BGTask \(taskIdentifier)")
      }

      let success = await retryWork.value
      task.setTaskCompleted(success: success)
    }
  }
}
#endif
