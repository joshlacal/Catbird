//
//  BackgroundCacheRefreshManager.swift
//  Catbird
//
//  Created by Claude on 10/31/25.
//

import Foundation
import BackgroundTasks
import SwiftData
import Petrel
import OSLog

#if os(iOS)
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
    guard didRegister else {
      logger.debug("Skipping cache BGTask schedule because registration has not run")
      return
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

      // 2. Refresh cached threads (update old cached threads)
      if Task.isCancelled { return false }
      await refreshCachedThreads(context: context)

      // 3. Refresh main feed cache
      if Task.isCancelled { return false }
      await refreshFeedCache(context: context)

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
      task.setTaskCompleted(success: success)
    }
  }

  /// Refresh cached threads by fetching fresh data for recently-viewed threads
  @MainActor private static func refreshCachedThreads(context: AppContext) async {
    logger.debug("Refreshing cached threads in background")

    guard let modelContainer = try? ModelContainer(
      for: CachedFeedViewPost.self,
      configurations: ModelConfiguration(cloudKitDatabase: .none)
    ) else {
      logger.error("Failed to create model container for thread refresh")
      return
    }

    let modelContext = modelContainer.mainContext

    // Find unique thread URIs from recently cached thread posts
    let descriptor = FetchDescriptor<CachedFeedViewPost>(
      predicate: #Predicate<CachedFeedViewPost> { post in
        post.feedType == "thread-cache"
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )

    do {
      let cachedPosts = try modelContext.fetch(descriptor)

      // Get unique thread URIs from the last 10 viewed threads
      var seenURIs = Set<String>()
      var threadURIs: [String] = []

      for post in cachedPosts.prefix(50) {
        guard let postUri = post.uri else { continue }
        let uriString = postUri.uriString()
        if !seenURIs.contains(uriString) {
          seenURIs.insert(uriString)
          threadURIs.append(uriString)
          if threadURIs.count >= 10 {
            break
          }
        }
      }

      if threadURIs.isEmpty {
        logger.debug("No cached threads to refresh")
        return
      }

      logger.info("Refreshing \(threadURIs.count) cached threads")

      guard let client = await context.createClient() else {
        logger.error("No AT Protocol client available")
        return
      }

      // Get AppState from main actor for ThreadManager
      guard let appState = await MainActor.run(resultType: AppState?.self, body: { AppStateManager.shared.lifecycle.appState }) else {
        logger.error("No active AppState available")
        return
      }

      // Refresh each thread
      for uriString in threadURIs {
        if Task.isCancelled { break }

        guard let uri = try? ATProtocolURI(uriString: uriString) else {
          logger.warning("Invalid thread URI: \(uriString)")
          continue
        }

        // Create temporary ThreadManager to refresh
        let threadManager = ThreadManager(appState: appState)
        threadManager.setModelContext(modelContext)

        await MainActor.run {
          Task {
            await threadManager.loadThread(uri: uri)
            // loadThread already saves to cache via cacheThreadPosts()
          }
        }

        // Small delay between requests to avoid rate limiting
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
      }

      logger.info("✅ Refreshed \(threadURIs.count) cached threads")
    } catch {
      logger.error("Failed to refresh cached threads: \(error.localizedDescription)")
    }
  }

  /// Refresh main feed cache by fetching latest posts
  private static func refreshFeedCache(context: AppContext) async {
    logger.debug("Refreshing feed cache in background")

    guard let client = await context.createClient() else {
      logger.error("No AT Protocol client available")
      return
    }

    guard let modelContainer = try? ModelContainer(
      for: CachedFeedViewPost.self,
      configurations: ModelConfiguration(cloudKitDatabase: .none)
    ) else {
      logger.error("Failed to create model container for feed refresh")
      return
    }

      let modelContext = await modelContainer.mainContext

    do {
      // Fetch latest following feed
      let params = AppBskyFeedGetTimeline.Parameters(
        algorithm: nil,
        limit: 30,
        cursor: nil
      )

      let (responseCode, output) = try await client.app.bsky.feed.getTimeline(input: params)

      if responseCode == 200, let output = output {
        let posts = output.feed
        logger.info("Fetched \(posts.count) posts for feed cache")

        // Save posts to cache
        var savedCount = 0
        for post in posts {
          if Task.isCancelled { break }

          if let cachedPost = CachedFeedViewPost(
            from: post,
            cursor: output.cursor,
            feedType: "following",
            feedOrder: nil
          ) {
            await MainActor.run {
              // Upsert: update existing post or insert new one to avoid constraint violations
              let postId = cachedPost.id
              let descriptor = FetchDescriptor<CachedFeedViewPost>(
                predicate: #Predicate<CachedFeedViewPost> { post in
                  post.id == postId
                }
              )

              do {
                let existing = try modelContext.fetch(descriptor)
                _ = modelContext.upsert(
                  cachedPost,
                  existingModel: existing.first,
                  update: { existingPost, newPost in existingPost.update(from: newPost) }
                )
                savedCount += 1
              } catch {
                logger.error("Failed to check/save feed post: \(error.localizedDescription)")
              }
            }
          }
        }

        // Save all changes
        await MainActor.run {
          do {
            if savedCount > 0 {
              try modelContext.save()
              logger.info("✅ Saved \(savedCount) posts to feed cache")
            }
          } catch {
            logger.error("Failed to save feed cache: \(error.localizedDescription)")
          }
        }
      }
    } catch {
      logger.error("Failed to refresh feed cache: \(error.localizedDescription)")
    }
  }
}
#endif
