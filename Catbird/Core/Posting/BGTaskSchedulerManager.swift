import Foundation
import BackgroundTasks
import os

@available(iOS 13.0, *)
enum BGTaskSchedulerManager {
  static let taskIdentifier = "blue.catbird.posting.retry"
  private static let logger = Logger(subsystem: "blue.catbird", category: "BGTasks")
  private static var didRegister = false

  static func registerIfNeeded() {
    guard !didRegister else { return }
    didRegister = true
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
      handle(task: task as! BGAppRefreshTask)
    }
  }

  static func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do { try BGTaskScheduler.shared.submit(request) } catch {
      logger.error("BGTask submit failed: \(error.localizedDescription)")
    }
  }

  private static func handle(task: BGAppRefreshTask) {
    schedule()
    task.expirationHandler = {
      task.setTaskCompleted(success: false)
    }
    Task {
      await ComposerOutbox.shared.processAll(appState: AppState.shared)
      task.setTaskCompleted(success: true)
    }
  }
}
