//
//  LockScreenWidgets.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import WidgetKit
import SwiftUI

// MARK: - Feed Rectangular Entry

struct FeedRectangularEntry: TimelineEntry {
  let date: Date
  let posts: [WidgetPost]
  let isSignedIn: Bool
}

// MARK: - Feed Rectangular Provider

struct FeedRectangularProvider: TimelineProvider {
  func placeholder(in context: Context) -> FeedRectangularEntry {
    FeedRectangularEntry(date: Date(), posts: placeholderPosts(), isSignedIn: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (FeedRectangularEntry) -> Void) {
    let entry = currentEntry()
    // Sample posts are only for the widget gallery preview; a real widget never shows them.
    if entry.posts.isEmpty && context.isPreview {
      completion(FeedRectangularEntry(date: Date(), posts: placeholderPosts(), isSignedIn: true))
    } else {
      completion(entry)
    }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FeedRectangularEntry>) -> Void) {
    let entry = currentEntry()
    let nextUpdate = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
    completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
  }

  private func currentEntry() -> FeedRectangularEntry {
    let activeDID = WidgetDataReader.activeAccountDID() ?? ""
    let posts = WidgetDataReader.feedData(
      accountDID: activeDID, configKey: FeedWidgetConstants.timelineConfigKey
    )?.posts ?? []
    return FeedRectangularEntry(date: Date(), posts: Array(posts.prefix(2)), isSignedIn: !activeDID.isEmpty)
  }

  private func placeholderPosts() -> [WidgetPost] {
    [
      WidgetPost(
        id: "p1",
        authorName: "Jane",
        authorHandle: "@jane.bsky.social",
        authorAvatarURL: nil,
        text: String(
          localized: "Just shipped a major update!",
          comment: "Sample post text shown in the lock-screen widget gallery preview."
        ),
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
        authorName: String(
          localized: "Dev",
          comment: "Sample author name shown in the lock-screen widget gallery preview."
        ),
        authorHandle: "@dev.bsky.social",
        authorAvatarURL: nil,
        text: String(
          localized: "New framework looks promising.",
          comment: "Sample post text shown in the lock-screen widget gallery preview."
        ),
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
    .configurationDisplayName(
      LocalizedStringResource(
        "Latest Posts",
        comment: "Widget gallery display name for the lock-screen Latest Posts widget."
      )
    )
    .description(
      LocalizedStringResource(
        "See the latest posts from your Following feed.",
        comment: "Widget gallery description for the lock-screen Latest Posts widget."
      )
    )
    .supportedFamilies([.accessoryRectangular])
  }
}

struct FeedRectangularView: View {
  let entry: FeedRectangularEntry

  private var emptyStatePrompt: LocalizedStringResource {
    if entry.isSignedIn {
      return LocalizedStringResource(
        "Open Catbird to load posts",
        comment: "Empty-state prompt in the lock-screen widget when signed in with no cached posts."
      )
    }
    return LocalizedStringResource(
      "Open Catbird to sign in",
      comment: "Empty-state prompt in the lock-screen widget when no Bluesky account is signed in."
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WidgetSpacing.hairline) {
      Text(
        "Latest Posts",
        comment: "Header label inside the lock-screen Latest Posts widget."
      )
      .widgetFont(.caption, weight: .semibold)
      .foregroundStyle(.secondary)

      if entry.posts.isEmpty {
        Text(emptyStatePrompt)
          .widgetFont(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(entry.posts.prefix(2)), id: \.id) { post in
          HStack(spacing: WidgetSpacing.xs) {
            Circle()
              .fill(Color.secondary.opacity(0.35))
              .frame(width: WidgetAvatarSize.xs, height: WidgetAvatarSize.xs)

            Text(
              "\(post.authorName): \(post.text)",
              comment: "Compact lock-screen post row: first placeholder is the author's name, second is the post text."
            )
            .widgetFont(.caption)
            .lineLimit(1)
          }
        }
      }
    }
  }
}
#endif
