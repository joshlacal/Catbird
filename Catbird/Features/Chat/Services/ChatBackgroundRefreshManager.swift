import Foundation
import BackgroundTasks
import OSLog

#if os(iOS)
@available(iOS 13.0, *)
enum ChatBackgroundRefreshManager {
  private static let taskIdentifier = "blue.catbird.chat.refresh"
  private static let logger = Logger(subsystem: "blue.catbird", category: "ChatBackgroundRefresh")
  private static var didRegister = false
  private static var lastScheduleTime: Date?

  static func registerIfNeeded() {
    guard !didRegister else {
      logger.debug("Chat BGTask already registered")
      return
    }

    guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
          identifiers.contains(taskIdentifier) else {
      logger.error("Missing chat BGTask identifier in Info.plist")
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
    logger.info("Registered chat background refresh task")
  }

  static func schedule() {
    guard didRegister else {
      logger.debug("Skipping chat BGTask schedule because registration has not run")
      return
    }

    let now = Date()
    if let lastSubmission = lastScheduleTime, now.timeIntervalSince(lastSubmission) < 60 {
      logger.debug("Skipping chat BGTask reschedule due to throttle window")
      return
    }

    lastScheduleTime = now

    let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

    do {
      try BGTaskScheduler.shared.submit(request)
      logger.debug("Scheduled chat background refresh task")
    } catch {
      logger.error("Failed to submit chat BGTask: \(error.localizedDescription)")
    }
  }

  private static func handle(task: BGAppRefreshTask) {
    logger.info("Chat BGTask started")

    schedule()

    let refreshWork = Task<Bool, Never> {
      guard let activeState = await AppStateManager.shared.lifecycle.appState,
            activeState.isAuthenticated else {
        logger.info("Skipping chat refresh - user not authenticated")
        return true
      }

      let appState = activeState

      if Task.isCancelled { return false }
      await appState.chatManager.loadConversations(refresh: true)

      if Task.isCancelled { return false }
      if appState.notificationManager.notificationsEnabled,
         appState.notificationManager.status == .registered {
        await appState.notificationManager.checkUnreadNotifications()
      }

      if Task.isCancelled { return false }
      logger.info("Chat BGTask finished successfully")
      return true
    }

    task.expirationHandler = {
      logger.warning("Chat BGTask expired")
      refreshWork.cancel()
    }

    Task {
      let success = await refreshWork.value
      task.setTaskCompleted(success: success)
    }
  }
}
#endif
