import Foundation
import BackgroundTasks
import os

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
    
    // Schedule next execution
    schedule()
    
    // Set up expiration handler
    task.expirationHandler = { [weak task] in
      logger.warning("BGTask expired before completion")
      task?.setTaskCompleted(success: false)
    }
    
    // Process outbox items with timeout protection
    Task {
      do {
        guard let activeState = await AppStateManager.shared.lifecycle.appState else {
          logger.warning("BGTask - no active state available")
          task.setTaskCompleted(success: false)
          return
        }
        await ComposerOutbox.shared.processAll(appState: activeState)
        logger.info("BGTask completed successfully")
        task.setTaskCompleted(success: true)
      } catch {
        logger.error("BGTask failed with error: \(error.localizedDescription)")
        task.setTaskCompleted(success: false)
      }
    }
  }
}
