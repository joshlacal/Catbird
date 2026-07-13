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

enum MLSBackgroundRefreshCloseOutcome: Equatable {
  case closed
  case preparationFailed
  case rustPathUnavailable
  case expired
}

final class MLSBackgroundRefreshTerminationState: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  private var normalCloseClaimed = false
  private var grdbEndClaimed = false
  private var taskCompletionClaimed = false

  var didExpire: Bool {
    lock.withLock { expired }
  }

  func claimExpiration() -> Bool {
    lock.withLock {
      guard !expired, !normalCloseClaimed, !taskCompletionClaimed else { return false }
      expired = true
      return true
    }
  }

  func claimNormalClose() -> Bool {
    lock.withLock {
      guard !expired, !normalCloseClaimed else { return false }
      normalCloseClaimed = true
      return true
    }
  }

  func claimGRDBEnd() -> Bool {
    lock.withLock {
      guard !grdbEndClaimed else { return false }
      grdbEndClaimed = true
      return true
    }
  }

  func claimTaskCompletion() -> Bool {
    lock.withLock {
      guard !taskCompletionClaimed else { return false }
      taskCompletionClaimed = true
      return true
    }
  }
}

@MainActor
enum MLSBackgroundRefreshCloseCoordinator {
  static func run(
    state: MLSBackgroundRefreshTerminationState,
    suspendManager: @MainActor () -> Bool,
    prepareRustRuntime: @MainActor () async -> Bool,
    closePreparedRuntime: @MainActor () -> Void
  ) async -> MLSBackgroundRefreshCloseOutcome {
    guard !state.didExpire else { return .expired }
    guard suspendManager() else { return .rustPathUnavailable }
    guard !state.didExpire else { return .expired }
    guard await prepareRustRuntime() else {
      return state.didExpire ? .expired : .preparationFailed
    }
    guard state.claimNormalClose() else { return .expired }
    closePreparedRuntime()
    return .closed
  }
}

private func markBackgroundRefreshRustRuntimeClosedSynchronously(
  manager: MLSConversationManager,
  reason: String
) {
  if Thread.isMainThread {
    MainActor.assumeIsolated {
      manager.markRustRuntimeClosedForSuspend(reason: reason)
    }
  } else {
    DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        manager.markRustRuntimeClosedForSuspend(reason: reason)
      }
    }
  }
}

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

  nonisolated static func shouldDeferForLifecycleSuspension(
    clientSuspended: Bool,
    coreSuspended: Bool
  ) -> Bool {
    clientSuspended || coreSuspended
  }

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

    // A BGTask is never authorized to reopen lifecycle MLS gates. Foreground resume is
    // the only transaction that may refresh authoritative state and release them.
    guard !Self.shouldDeferForLifecycleSuspension(
      clientSuspended: MLSClient.isSuspensionInProgress,
      coreSuspended: MLSCoreContext.isSuspensionInProgress
    ) else {
      logger.warning("Background refresh deferred while MLS lifecycle suspension is active")
      task.setTaskCompleted(success: false)
      return
    }

    guard let appState = await getAppState() else {
      logger.error("Background refresh failed: AppState not available")
      task.setTaskCompleted(success: false)
      return
    }
    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("Background refresh skipped: MLS not initialized")
      task.setTaskCompleted(success: true)
      return
    }

    // While running in background, ensure GRDB connections are resumed for the duration
    // of this task, and re-suspended once it completes to avoid 0xdead10cc termination.
    GRDBSuspensionCoordinator.beginBackgroundWork(reason: "MLS BGTask \(Self.taskIdentifier)")
    let terminationState = MLSBackgroundRefreshTerminationState()

    let logger = self.logger
    let refreshWork = Task<Bool, Never> {
      do {
        try Task.checkCancellation()
        try await manager.smartRefreshKeyPackages(maxGeneratedPackages: 5)
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

    let expire: @Sendable () -> Void = {
      if terminationState.claimExpiration() {
        logger.warning("Background task expired; force-closing MLS runtime exactly once")
        MLSClient.markSuspensionInProgress(reason: "MLS BGTask expired")
        MLSCoreContext.markSuspensionInProgress()
        MLSClient.interruptAllContexts()
        MLSCoreContext.interruptAllContexts()
        MLSClient.emergencyCloseAllContexts(reason: "MLS BGTask expired")
        MLSCoreContext.emergencyCloseAllContexts()
        markBackgroundRefreshRustRuntimeClosedSynchronously(
          manager: manager,
          reason: "MLS BGTask expired"
        )
        if terminationState.claimGRDBEnd() {
          GRDBSuspensionCoordinator.endBackgroundWork(reason: "MLS BGTask \(Self.taskIdentifier) expired")
        }
        if terminationState.claimTaskCompletion() {
          task.setTaskCompleted(success: false)
        }
      }
      refreshWork.cancel()
    }
    let bgTask = CatbirdBackgroundTask(
      name: "MLS BGTask \(Self.taskIdentifier)",
      expirationHandler: expire
    )
    defer { bgTask.end() }
    task.expirationHandler = expire

    let refreshSucceeded = await refreshWork.value
    let closeOutcome = await MLSBackgroundRefreshCloseCoordinator.run(
      state: terminationState,
      suspendManager: {
        manager.suspendMLSOperations()
      },
      prepareRustRuntime: {
        await manager.prepareRustRuntimeForSuspensionAfterDrain(timeout: 5)
      },
      closePreparedRuntime: {
        MLSClient.emergencyCloseAllContexts(reason: "MLS BGTask prepared completion")
        MLSCoreContext.emergencyCloseAllContexts()
        manager.markRustRuntimeClosedForSuspend(reason: "MLS BGTask prepared completion")
      }
    )

    if terminationState.claimGRDBEnd() {
      GRDBSuspensionCoordinator.endBackgroundWork(reason: "MLS BGTask \(Self.taskIdentifier)")
    }
    if terminationState.claimTaskCompletion() {
      task.setTaskCompleted(success: refreshSucceeded && closeOutcome == .closed)
    }
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
