import Foundation
import OSLog
import Observation
import OrderedCollections
import Petrel
import SwiftUI

// MARK: - Models and Enums

/// Defines notification types
enum NotificationType: String, CaseIterable {
  case like, repost, follow, mention, reply, quote

  var icon: String {
    switch self {
    case .like: return "heart.fill"
    case .repost: return "arrow.2.squarepath"
    case .follow: return "person.fill.badge.plus"
    case .mention: return "at"
    case .reply: return "arrowshape.turn.up.left.fill"
    case .quote: return "quote.bubble"
    }
  }

  var color: Color {
    switch self {
    case .like: return .red
    case .repost: return .green
    case .follow: return .blue
    case .mention: return .purple
    case .reply: return .orange
    case .quote: return .cyan
    }
  }

  /// Determines if this notification type should be grouped
  var isGroupable: Bool {
    switch self {
    case .like, .repost, .follow:
      return true
    case .mention, .reply, .quote:
      // Don't group replies and quotes per requirement
      return false
    }
  }
}

/// Represents a group of related notifications
struct GroupedNotification: Identifiable {
  // Add page number to make IDs unique across pages
  let id: String
  let type: NotificationType
  let notifications: [AppBskyNotificationListNotifications.Notification]
  let subjectPost: AppBskyFeedDefs.PostView?
  // Store the page this group belongs to
  let pageNumber: Int

  var latestNotification: AppBskyNotificationListNotifications.Notification {
    notifications.max(by: { $0.indexedAt.date < $1.indexedAt.date })!
  }

  /// Determines if this group contains any unread notifications
  var hasUnreadNotifications: Bool {
    return notifications.contains { !$0.isRead }
  }
}

// MARK: - ViewModel

@Observable final class NotificationsViewModel {
  // MARK: - Properties

  private(set) var groupedNotifications: [GroupedNotification] = []
  private(set) var isLoading = false
  private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  private(set) var hasMoreNotifications = false
  private(set) var error: Error?
  private var cursor: String?
  private var currentPage = 0

  // Add a cache for posts to avoid refetching
  private var postCache: [ATProtocolURI: (post: AppBskyFeedDefs.PostView, timestamp: Date)] = [:]
  // Cache expiration time (5 minutes)
  private let cacheExpirationInterval: TimeInterval = 300

  private let client: ATProtoClient?
  private let logger = Logger(subsystem: "blue.catbird", category: "NotificationsViewModel")

  // Add a new enum for filter types
  enum NotificationFilter {
    case all
    case mentions

    var reasonFilters: [String]? {
      switch self {
      case .all:
        return nil  // No filtering
      case .mentions:
        return ["mention", "reply", "quote"]
      }
    }
  }

  // Add a new property to track the current filter
  private(set) var currentFilter: NotificationFilter = .all

  // MARK: - Initialization

  init(client: ATProtoClient?) {
    self.client = client
  }

  // MARK: - Public Methods

  /// Loads initial notifications
  func loadNotifications() async {
    guard !isLoading else { return }

    isLoading = true
    error = nil

    await fetchNotifications(resetCursor: true)
    await ensureEnoughNotifications()

    isLoading = false
  }

  /// Refreshes the notification list
  func refreshNotifications() async {
    guard !isRefreshing else { return }

    isRefreshing = true
    error = nil

    // Clean up cache on refresh
    cleanupCache()

    await fetchNotifications(resetCursor: true)
    await ensureEnoughNotifications()

    isRefreshing = false
  }

  /// Loads more notifications (pagination)
  func loadMoreNotifications() async {
    guard !isLoadingMore, hasMoreNotifications, cursor != nil else { return }

    isLoadingMore = true

    await fetchNotifications(resetCursor: false)

    isLoadingMore = false
  }

  /// Makes sure we have enough notifications to fill the screen
  private func ensureEnoughNotifications() async {
    // If we have fewer than 5 grouped notifications and there are more available,
    // automatically load more
    if groupedNotifications.count < 5 && hasMoreNotifications && !isLoadingMore {
      await loadMoreNotifications()

      // Recursively check again after loading more
      if groupedNotifications.count < 5 && hasMoreNotifications {
        await ensureEnoughNotifications()
      }
    }
  }

  /// Marks notifications as seen
  func markNotificationsAsSeen() async throws {
    guard let client = client else {
      logger.error("Client is nil in markNotificationsAsSeen")
      return
    }

    do {
      _ = try await client.app.bsky.notification.updateSeen(
        input: .init(seenAt: ATProtocolDate(date: Date()))
      )
      logger.info("Successfully marked notifications as seen")

      // Update all local notifications as read
      for i in 0..<groupedNotifications.count {
        for _ in 0..<groupedNotifications[i].notifications.count {
          // We can't mutate the notifications directly as they're immutable,
          // but they'll be refreshed as read on the next fetch
        }
      }

      // Tell the notification manager to update badge count
      NotificationCenter.default.post(
        name: NSNotification.Name("NotificationsMarkedAsSeen"), object: nil)
    } catch {
      logger.error("Failed to mark notifications as seen: \(error.localizedDescription)")
      throw error
    }
  }

  /// Sets the filter and refreshes notifications
  func setFilter(_ filter: NotificationFilter) async {
    guard filter != currentFilter else { return }

    currentFilter = filter
    await refreshNotifications()
  }
  
  /// Clears the current error state
  func clearError() {
    error = nil
  }

  // MARK: - Private Methods

  /// Clears expired entries from the post cache
  private func cleanupCache() {
    let now = Date()
    postCache = postCache.filter { _, entry in
      now.timeIntervalSince(entry.timestamp) < cacheExpirationInterval
    }
  }

  /// Fetches notifications from the API
  private func fetchNotifications(resetCursor: Bool) async {
    guard let client = client else {
      logger.error("Client is nil in fetchNotifications")
      return
    }

    do {
      // Use the filter reasons when creating parameters
      let params = AppBskyNotificationListNotifications.Parameters(
        reasons: currentFilter.reasonFilters,
        limit: 50,  // Increased from 30 to batch more notifications
        cursor: resetCursor ? nil : cursor
      )

      let (responseCode, output) = try await client.app.bsky.notification.listNotifications(
        input: params
      )

      guard responseCode == 200, let output = output else {
        let errorMessage = "Failed to load notifications (HTTP \(responseCode))"
        logger.error("Bad response from notifications API: \(responseCode)")
        await MainActor.run {
          self.error = NSError(domain: "NotificationsError", code: responseCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        return
      }

      // Reset page counter when doing a full refresh
      if resetCursor {
        currentPage = 0
      } else {
        currentPage += 1
      }

      // Process the fetched notifications
      let newGroupedNotifications = await groupNotifications(
        output.notifications, pageNumber: currentPage)

      await MainActor.run {
        if resetCursor {
          if self.groupedNotifications.isEmpty {
            // Initial load, just set the notifications
            self.groupedNotifications = newGroupedNotifications
          } else {
            // Refresh - merge with existing notifications
            // Take the first page of new notifications
            let newFirstPage = newGroupedNotifications

            // Keep all notifications beyond the first page
            let existingLaterPages = self.groupedNotifications.filter { $0.pageNumber > 0 }

            // Combine new first page with existing later pages
            self.groupedNotifications = newFirstPage + existingLaterPages
          }
        } else {
          // Simply append the new notifications for pagination
          self.groupedNotifications.append(contentsOf: newGroupedNotifications)
        }

        self.cursor = output.cursor
        self.hasMoreNotifications = output.cursor != nil
      }

    } catch {
      logger.error("Error fetching notifications: \(error.localizedDescription)")
      await MainActor.run {
        self.error = error
      }
    }
  }

  /// Groups notifications based on type and subject
  private func groupNotifications(
    _ notifications: [AppBskyNotificationListNotifications.Notification],
    pageNumber: Int
  ) async -> [GroupedNotification] {

    // Collect URIs to fetch for post subjects
    var urisToFetch = Set<ATProtocolURI>()

    for notification in notifications {
      switch notification.reason {
      case "like", "repost":  // Added repost to also fetch posts for reposts
        if let reasonSubject = notification.reasonSubject {
          urisToFetch.insert(reasonSubject)
        }
      case "reply", "mention", "quote":
        urisToFetch.insert(notification.uri)
      default:
        break
      }
    }

    // Fetch posts that are referenced by notifications
    let fetchedPosts = await fetchPosts(uris: Array(urisToFetch))

    // For groupable notification types (like, repost, follow), group by type and subject
    // For non-groupable types (reply, quote, mention), keep them separate
    var notificationGroups: [String: [AppBskyNotificationListNotifications.Notification]] = [:]

    for notification in notifications {
      let type = mapReasonToNotificationType(notification.reason)

      // Only group notification types that are groupable
      if let type = type, type.isGroupable {
        let key: String

        switch type {
        case .like, .repost:  // Modified to handle reposts similar to likes
          key = "\(notification.reason)_\(notification.reasonSubject?.uriString() ?? "")"
        case .follow:
          key = notification.reason
        default:
          // For non-groupable types, use unique ID to prevent grouping
          key = "\(notification.reason)_\(notification.uri.uriString())_\(notification.cid)"
        }

        if notificationGroups[key] == nil {
          notificationGroups[key] = [notification]
        } else {
          notificationGroups[key]?.append(notification)
        }
      } else {
        // For non-groupable types, create a unique key to prevent grouping
        let uniqueKey = "\(notification.reason)_\(notification.uri.uriString())_\(notification.cid)"
        notificationGroups[uniqueKey] = [notification]
      }
    }

    // Create grouped notifications
    var groupedNotifications: [GroupedNotification] = []

    for (key, notificationGroup) in notificationGroups {
      guard let firstNotification = notificationGroup.first else {
        continue
      }

      let typeStr = firstNotification.reason
      guard let type = mapReasonToNotificationType(typeStr) else {
        continue
      }

      let sortedNotifications = notificationGroup.sorted(by: {
        $0.indexedAt.date > $1.indexedAt.date
      })

      var subjectPost: AppBskyFeedDefs.PostView?

      switch type {
      case .like, .repost:  // Modified to handle reposts similar to likes
        if let reasonSubject = sortedNotifications.first?.reasonSubject {
          subjectPost = fetchedPosts[reasonSubject]
        }
      case .reply, .mention, .quote:
        subjectPost = fetchedPosts[sortedNotifications.first!.uri]
      case .follow:
        // No subject post needed
        break
      }

      // Add page number to key to make it unique across pages
      let uniqueId = "\(key)_page\(pageNumber)_\(firstNotification.indexedAt)"

      let groupedNotification = GroupedNotification(
        id: uniqueId,
        type: type,
        notifications: sortedNotifications,
        subjectPost: subjectPost,
        pageNumber: pageNumber
      )

      groupedNotifications.append(groupedNotification)
    }

    // Sort by most recent first
    return groupedNotifications.sorted {
      $0.latestNotification.indexedAt.date > $1.latestNotification.indexedAt.date
    }
  }

  /// Maps API reason strings to our NotificationType enum
  private func mapReasonToNotificationType(_ reason: String) -> NotificationType? {
    switch reason {
    case "like": return .like
    case "repost": return .repost
    case "follow": return .follow
    case "mention": return .mention
    case "reply": return .reply
    case "quote": return .quote
    default: return nil
    }
  }

  /// Fetches multiple posts by their URIs, using cache when possible and batching requests in groups of 25
  private func fetchPosts(uris: [ATProtocolURI]) async -> [ATProtocolURI: AppBskyFeedDefs.PostView] {
    guard !uris.isEmpty, let client = client else { return [:] }

    // Filter out URIs that are already in the cache and still valid
    let now = Date()
    let cachedPosts = uris.reduce(into: [ATProtocolURI: AppBskyFeedDefs.PostView]()) {
      result, uri in
      if let cachedEntry = postCache[uri],
        now.timeIntervalSince(cachedEntry.timestamp) < cacheExpirationInterval {
        result[uri] = cachedEntry.post
      }
    }

    // Only fetch URIs that aren't in the cache or expired
    let urisToFetch = uris.filter { uri in
      if let cachedEntry = postCache[uri] {
        return now.timeIntervalSince(cachedEntry.timestamp) >= cacheExpirationInterval
      }
      return true
    }

    // If all posts are in cache, return them immediately
    if urisToFetch.isEmpty {
      return cachedPosts
    }

    // Deduplicate URIs to avoid sending the same URI multiple times
    let uniqueUrisToFetch = Array(Set(urisToFetch))

    // Split URIs into batches of 25 (API limit)
    let batchSize = 25
    let batches = stride(from: 0, to: uniqueUrisToFetch.count, by: batchSize).map {
      Array(uniqueUrisToFetch[$0..<min($0 + batchSize, uniqueUrisToFetch.count)])
    }

    // Process each batch
    var allFetchedPosts: [ATProtocolURI: AppBskyFeedDefs.PostView] = [:]

    for batch in batches {
      do {
        let params = AppBskyFeedGetPosts.Parameters(uris: batch)
        let (responseCode, output) = try await client.app.bsky.feed.getPosts(input: params)

        guard responseCode == 200, let posts = output?.posts else {
          logger.warning("Failed to fetch posts batch. Response code: \(responseCode)")
          continue
        }

        // Update cache with newly fetched posts
        let fetchTime = Date()
        for post in posts {
          postCache[post.uri] = (post: post, timestamp: fetchTime)
          allFetchedPosts[post.uri] = post
        }

      } catch {
        logger.error("Error fetching posts batch: \(error.localizedDescription)")
      }
    }

    // Combine cached and newly fetched posts
    var result = cachedPosts
    for (uri, post) in allFetchedPosts {
      result[uri] = post
    }

    return result
  }
}
