import Foundation
import Observation
import OrderedCollections
import Petrel
import OSLog
import SwiftUI

// MARK: - Models and Enums

/// Defines notification types
enum NotificationType: String, CaseIterable {
    case like, repost, follow, mention, reply, quote
    
    var icon: String {
        switch self {
        case .like: return "heart.fill"
        case .repost: return "arrow.2.squarepath"
        case .follow: return "person.badge.plus"
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
}

// MARK: - ViewModel

@Observable final class NotificationsViewModel {
    // MARK: - Properties
    
    private(set) var groupedNotifications: [GroupedNotification] = []
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var hasMoreNotifications = false
    private var cursor: String?
    private var currentPage = 0
    
    private let client: ATProtoClient?
    private let logger = Logger(subsystem: "blue.catbird", category: "NotificationsViewModel")
    
    // MARK: - Initialization
    
    init(client: ATProtoClient?) {
        self.client = client
    }
    
    // MARK: - Public Methods
    
    /// Loads initial notifications
    func loadNotifications() async {
        guard !isLoading else { return }
        
        isLoading = true
        
            await fetchNotifications(resetCursor: true)
        
        isLoading = false
    }
    
    /// Refreshes the notification list
    func refreshNotifications() async {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        
            await fetchNotifications(resetCursor: true)
        
        isRefreshing = false
    }
    
    /// Loads more notifications (pagination)
    func loadMoreNotifications() async {
        guard !isLoadingMore, hasMoreNotifications, cursor != nil else { return }
        
        isLoadingMore = true
        
            await fetchNotifications(resetCursor: false)
        
        isLoadingMore = false
    }
    
    /// Marks notifications as seen
    func markNotificationsAsSeen() async throws {
        guard let client = client else {
            logger.error("Client is nil in markNotificationsAsSeen")
            return
        }
        
        do {
            let _ = try await client.app.bsky.notification.updateSeen(
                input: .init(seenAt: ATProtocolDate(date: Date()))
            )
            logger.info("Successfully marked notifications as seen")
        } catch {
            logger.error("Failed to mark notifications as seen: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    /// Fetches notifications from the API
    private func fetchNotifications(resetCursor: Bool) async {
        guard let client = client else {
            logger.error("Client is nil in fetchNotifications")
            return
        }
        
        do {
            let params = AppBskyNotificationListNotifications.Parameters(
                limit: 30,
                cursor: resetCursor ? nil : cursor
            )
            
            let (responseCode, output) = try await client.app.bsky.notification.listNotifications(
                input: params
            )
            
            guard responseCode == 200, let output = output else {
                logger.error("Bad response from notifications API: \(responseCode)")
                return
            }
            
            // Reset page counter when doing a full refresh
            if resetCursor {
                currentPage = 0
            } else {
                currentPage += 1
            }
            
            // Process the fetched notifications
            let newGroupedNotifications = await groupNotifications(output.notifications, pageNumber: currentPage)
            
            await MainActor.run {
                if resetCursor {
                    self.groupedNotifications = newGroupedNotifications
                } else {
                    // Simply append the new notifications without merging
                    self.groupedNotifications.append(contentsOf: newGroupedNotifications)
                }
                
                self.cursor = output.cursor
                self.hasMoreNotifications = output.cursor != nil
            }
            
        } catch {
            logger.error("Error fetching notifications: \(error.localizedDescription)")
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
            case "like":
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
                case .like:
                    key = "\(notification.reason)_\(notification.reasonSubject?.uriString() ?? "")"
                case .repost, .follow:
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
            
            let sortedNotifications = notificationGroup.sorted(by: { $0.indexedAt.date > $1.indexedAt.date })
            
            var subjectPost: AppBskyFeedDefs.PostView?
            
            switch type {
            case .like:
                if let reasonSubject = sortedNotifications.first?.reasonSubject {
                    subjectPost = fetchedPosts[reasonSubject]
                }
            case .reply, .mention, .quote:
                subjectPost = fetchedPosts[sortedNotifications.first!.uri]
            case .repost, .follow:
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
    
    /// Fetches multiple posts by their URIs
    private func fetchPosts(uris: [ATProtocolURI]) async -> [ATProtocolURI: AppBskyFeedDefs.PostView] {
        guard !uris.isEmpty, let client = client else { return [:] }
        
        do {
            let params = AppBskyFeedGetPosts.Parameters(uris: uris)
            let (responseCode, output) = try await client.app.bsky.feed.getPosts(input: params)
            
            guard responseCode == 200, let posts = output?.posts else {
                logger.warning("Failed to fetch posts. Response code: \(responseCode)")
                return [:]
            }
            
            return Dictionary(uniqueKeysWithValues: posts.map { ($0.uri, $0) })
        } catch {
            logger.error("Error fetching posts: \(error.localizedDescription)")
            return [:]
        }
    }
}
