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
    .description("See the latest posts from your Following feed.")
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
        Text(entry.isSignedIn ? "Open Catbird to load posts" : "Open Catbird to sign in")
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
