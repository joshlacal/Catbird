//
//  LockScreenWidgets.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import WidgetKit
import SwiftUI

// MARK: - Notification Data Model

struct NotificationCountData: Codable {
  let unreadCount: Int
}

// MARK: - Notification Entry

struct NotificationWidgetEntry: TimelineEntry {
  let date: Date
  let unreadCount: Int
}

// MARK: - Notification Provider

struct NotificationWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> NotificationWidgetEntry {
    NotificationWidgetEntry(date: Date(), unreadCount: 3)
  }

  func getSnapshot(in context: Context, completion: @escaping (NotificationWidgetEntry) -> Void) {
    completion(NotificationWidgetEntry(date: Date(), unreadCount: loadUnreadCount()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NotificationWidgetEntry>) -> Void) {
    let entry = NotificationWidgetEntry(date: Date(), unreadCount: loadUnreadCount())
    let nextUpdate = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
    completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
  }

  private func loadUnreadCount() -> Int {
    guard let defaults = UserDefaults(suiteName: FeedWidgetConstants.sharedSuiteName) else {
      return 0
    }
    let decoder = JSONDecoder()

    // Try DID-scoped key first
    if let activeDID = defaults.string(forKey: "activeAccountDID"),
       let data = defaults.data(forKey: "notificationWidgetData.\(activeDID)"),
       let decoded = try? decoder.decode(NotificationCountData.self, from: data) {
      return decoded.unreadCount
    }

    // Fallback to unscoped key
    if let data = defaults.data(forKey: "notificationWidgetData"),
       let decoded = try? decoder.decode(NotificationCountData.self, from: data) {
      return decoded.unreadCount
    }

    return 0
  }
}

// MARK: - Notification Circular Widget

struct NotificationCircularWidget: Widget {
  let kind = "CatbirdNotificationCircular"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NotificationWidgetProvider()) { entry in
      NotificationCircularView(entry: entry)
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Notifications")
    .description("See your unread notification count.")
    .supportedFamilies([.accessoryCircular])
  }
}

struct NotificationCircularView: View {
  let entry: NotificationWidgetEntry

  var body: some View {
    VStack(spacing: 1) {
      Text("\(entry.unreadCount)")
        .font(.system(size: 24, weight: .bold))
        .widgetAccentable()
      Text("NEW")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Notification Inline Widget

struct NotificationInlineWidget: Widget {
  let kind = "CatbirdNotificationInline"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NotificationWidgetProvider()) { entry in
      NotificationInlineView(entry: entry)
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Notifications")
    .description("See your unread notifications inline.")
    .supportedFamilies([.accessoryInline])
  }
}

struct NotificationInlineView: View {
  let entry: NotificationWidgetEntry

  var body: some View {
    let count = entry.unreadCount
    Label(
      "\(count) new \(count == 1 ? "notification" : "notifications")",
      systemImage: WidgetSymbol.notificationsBadge
    )
  }
}

// MARK: - Feed Rectangular Entry

struct FeedRectangularEntry: TimelineEntry {
  let date: Date
  let posts: [WidgetPost]
}

// MARK: - Feed Rectangular Provider

struct FeedRectangularProvider: TimelineProvider {
  func placeholder(in context: Context) -> FeedRectangularEntry {
    FeedRectangularEntry(date: Date(), posts: placeholderPosts())
  }

  func getSnapshot(in context: Context, completion: @escaping (FeedRectangularEntry) -> Void) {
    completion(FeedRectangularEntry(date: Date(), posts: loadPosts()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FeedRectangularEntry>) -> Void) {
    let entry = FeedRectangularEntry(date: Date(), posts: loadPosts())
    let nextUpdate = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
    completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
  }

  private func loadPosts() -> [WidgetPost] {
    let activeDID = WidgetDataReader.activeAccountDID() ?? ""
    let configKey = "widgetData_timeline"
    if let posts = WidgetDataReader.feedData(accountDID: activeDID, configKey: configKey) {
      return Array(posts.prefix(2))
    }
    return []
  }

  private func placeholderPosts() -> [WidgetPost] {
    [
      WidgetPost(
        id: "p1",
        authorName: "Jane",
        authorHandle: "@jane.bsky.social",
        authorAvatarURL: nil,
        text: "Just shipped a major update!",
        timestamp: Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
      WidgetPost(
        id: "p2",
        authorName: "Dev",
        authorHandle: "@dev.bsky.social",
        authorAvatarURL: nil,
        text: "New framework looks promising.",
        timestamp: Date(),
        likeCount: 0,
        repostCount: 0,
        replyCount: 0,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
    ]
  }
}

// MARK: - Feed Rectangular Widget

struct FeedRectangularWidget: Widget {
  let kind = "CatbirdFeedRectangular"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: FeedRectangularProvider()) { entry in
      FeedRectangularView(entry: entry)
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Latest Posts")
    .description("Preview your latest posts on the lock screen.")
    .supportedFamilies([.accessoryRectangular])
  }
}

struct FeedRectangularView: View {
  let entry: FeedRectangularEntry

  var body: some View {
    VStack(alignment: .leading, spacing: WidgetSpacing.xs) {
      Text("Latest Posts")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)

      if entry.posts.isEmpty {
        Text("No posts available")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(entry.posts.prefix(2)), id: \.id) { post in
          HStack(spacing: WidgetSpacing.sm) {
            Circle()
              .fill(Color.gray.opacity(0.4))
              .frame(width: WidgetAvatarSize.xs, height: WidgetAvatarSize.xs)

            Text("\(post.authorName): \(post.text)")
              .font(.system(size: 10))
              .lineLimit(1)
          }
        }
      }
    }
  }
}
#endif
