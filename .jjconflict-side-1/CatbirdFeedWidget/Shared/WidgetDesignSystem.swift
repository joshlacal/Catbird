//
//  WidgetDesignSystem.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import SwiftUI

// MARK: - SF Symbols
enum WidgetSymbol {
  static let like = "heart"
  static let likeFill = "heart.fill"
  static let repost = "arrow.2.squarepath"
  static let reply = "bubble.right"
  static let mention = "at"
  static let follow = "person.badge.plus"
  static let refresh = "arrow.clockwise"
  static let compose = "square.and.pencil"
  static let notifications = "bell"
  static let notificationsBadge = "bell.badge"
  static let message = "message"
  static let trending = "chart.line.uptrend.xyaxis"
  static let profile = "person.circle"
}

// MARK: - Spacing
enum WidgetSpacing {
  static let xs: CGFloat = 2
  static let sm: CGFloat = 4
  static let md: CGFloat = 8
  static let base: CGFloat = 12
  static let lg: CGFloat = 16
}

// MARK: - Avatar Sizes
enum WidgetAvatarSize {
  static let xs: CGFloat = 12
  static let sm: CGFloat = 16
  static let md: CGFloat = 22
  static let lg: CGFloat = 26
  static let xl: CGFloat = 32
  static let xxl: CGFloat = 40
}

// MARK: - Shared Views

struct WidgetAvatar: View {
  let url: URL?
  let size: CGFloat

  var body: some View {
    if url != nil {
      Circle()
        .fill(
          LinearGradient(
            colors: [Color.blue, Color.cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: size, height: size)
    } else {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: size, height: size)
    }
  }
}

@available(iOS 17.0, *)
struct WidgetHeader: View {
  let avatarURL: URL?
  let title: String
  let subtitle: String?
  let lastUpdated: Date?
  let refreshIntent: RefreshFeedWidgetIntent?

  init(
    avatarURL: URL? = nil,
    title: String,
    subtitle: String? = nil,
    lastUpdated: Date? = nil,
    refreshIntent: RefreshFeedWidgetIntent? = nil
  ) {
    self.avatarURL = avatarURL
    self.title = title
    self.subtitle = subtitle
    self.lastUpdated = lastUpdated
    self.refreshIntent = refreshIntent
  }

  var body: some View {
    HStack(spacing: WidgetSpacing.md) {
      WidgetAvatar(url: avatarURL, size: WidgetAvatarSize.md)

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        if let subtitle {
          Text(subtitle)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if let refreshIntent {
        Button(intent: refreshIntent) {
          Image(systemName: WidgetSymbol.refresh)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }

      if let lastUpdated {
        Text(lastUpdated, style: .relative)
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
  }
}

struct EngagementRow: View {
  let likes: Int
  let reposts: Int
  let replies: Int
  let fontSize: CGFloat

  init(likes: Int, reposts: Int, replies: Int, fontSize: CGFloat = 9) {
    self.likes = likes
    self.reposts = reposts
    self.replies = replies
    self.fontSize = fontSize
  }

  var body: some View {
    HStack(spacing: WidgetSpacing.md) {
      Label(formatCount(likes), systemImage: WidgetSymbol.like)
      Label(formatCount(reposts), systemImage: WidgetSymbol.repost)
      Label(formatCount(replies), systemImage: WidgetSymbol.reply)
    }
    .font(.system(size: fontSize))
    .foregroundStyle(.secondary)
    .labelStyle(WidgetCompactLabelStyle())
  }

  private func formatCount(_ count: Int) -> String {
    if count >= 10_000 {
      return String(format: "%.1fK", Double(count) / 1000.0)
    } else if count >= 1000 {
      return String(format: "%.1fK", Double(count) / 1000.0)
    }
    return "\(count)"
  }
}

struct WidgetCompactLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 2) {
      configuration.icon
      configuration.title
    }
  }
}

struct PostRow: View {
  let post: WidgetPost
  let avatarSize: CGFloat
  let textLineLimit: Int
  let showEngagement: Bool
  let fontSize: CGFloat

  init(
    post: WidgetPost,
    avatarSize: CGFloat = WidgetAvatarSize.md,
    textLineLimit: Int = 2,
    showEngagement: Bool = true,
    fontSize: CGFloat = 10.5
  ) {
    self.post = post
    self.avatarSize = avatarSize
    self.textLineLimit = textLineLimit
    self.showEngagement = showEngagement
    self.fontSize = fontSize
  }

  var body: some View {
    HStack(alignment: .top, spacing: WidgetSpacing.md) {
      WidgetAvatar(url: post.authorAvatarURL.flatMap(URL.init), size: avatarSize)

      VStack(alignment: .leading, spacing: WidgetSpacing.xs) {
        // Author line
        HStack(spacing: WidgetSpacing.sm) {
          Text(post.authorName)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
          Text(post.authorHandle)
            .font(.system(size: fontSize - 1.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text("·")
            .font(.system(size: fontSize - 1.5))
            .foregroundStyle(.secondary)
          Text(post.timestamp, style: .relative)
            .font(.system(size: fontSize - 1.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        // Repost indicator
        if post.isRepost, let repostAuthor = post.repostAuthorName {
          Label("Reposted by \(repostAuthor)", systemImage: WidgetSymbol.repost)
            .font(.system(size: fontSize - 2))
            .foregroundStyle(.secondary)
        }

        // Post text
        Text(post.text)
          .font(.system(size: fontSize))
          .foregroundStyle(.secondary)
          .lineLimit(textLineLimit)

        // Engagement
        if showEngagement {
          EngagementRow(
            likes: post.likeCount,
            reposts: post.repostCount,
            replies: post.replyCount,
            fontSize: fontSize - 2
          )
        }
      }
    }
  }
}
#endif
