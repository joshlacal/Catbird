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

// MARK: - Spacing (4pt Grid)

/// 4pt widget spacing scale mirroring `Space` in the main app.
enum WidgetSpacing {
  static let hairline: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 24
}

// MARK: - Corner Radius (Continuous)

/// Continuous corner radius scale mirroring `Radius` in the main app.
enum WidgetRadius: CGFloat, CaseIterable, Sendable {
  case xs = 4
  case sm = 8
  case md = 12
  case lg = 16

  var value: CGFloat { rawValue }

  var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: rawValue, style: .continuous)
  }

  static var capsule: Capsule {
    Capsule(style: .continuous)
  }
}

extension View {
  func widgetClip(_ radius: WidgetRadius) -> some View {
    clipShape(radius.shape)
  }
}

// MARK: - Avatar Sizes (4pt Grid)

enum WidgetAvatarSize {
  static let xs: CGFloat = 12
  static let sm: CGFloat = 16
  static let md: CGFloat = 20
  static let lg: CGFloat = 24
  static let xl: CGFloat = 32
  static let xxl: CGFloat = 40
}

// MARK: - Typography (Dynamic Type Scaled)

/// Semantic typography roles for widgets, scaling with Dynamic Type via `@ScaledMetric`
/// and clamped cleanly for compact widget frames.
enum WidgetTextRole: Sendable {
  case micro
  case meta
  case caption
  case bodyCompact
  case body
  case titleCompact
  case title
  case titleLarge
  case iconCompact
  case emptyIcon
  case emptyIconLarge
  case emptyIconHero
  case monogram(CGFloat)

  var baseSize: CGFloat {
    switch self {
    case .micro: return 8
    case .meta: return 9
    case .caption: return 10
    case .bodyCompact: return 11
    case .body: return 12
    case .titleCompact: return 13
    case .title: return 14
    case .titleLarge: return 15
    case .iconCompact: return 16
    case .emptyIcon: return 22
    case .emptyIconLarge: return 28
    case .emptyIconHero: return 34
    case .monogram(let avatarSize): return avatarSize * 0.45
    }
  }

  var maxSize: CGFloat {
    switch self {
    case .micro: return 11
    case .meta: return 12
    case .caption: return 13
    case .bodyCompact: return 14
    case .body: return 16
    case .titleCompact: return 17
    case .title: return 18
    case .titleLarge: return 20
    case .iconCompact: return 20
    case .emptyIcon: return 26
    case .emptyIconLarge: return 34
    case .emptyIconHero: return 40
    case .monogram(let avatarSize): return avatarSize * 0.55
    }
  }

  var relativeTextStyle: Font.TextStyle {
    switch self {
    case .micro, .meta, .caption: return .caption2
    case .bodyCompact, .body: return .caption
    case .titleCompact, .title, .titleLarge: return .subheadline
    case .iconCompact: return .callout
    case .emptyIcon: return .title2
    case .emptyIconLarge: return .title
    case .emptyIconHero: return .largeTitle
    case .monogram: return .caption
    }
  }

  var defaultWeight: Font.Weight {
    switch self {
    case .monogram: return .semibold
    case .titleCompact, .title, .titleLarge, .iconCompact: return .medium
    default: return .regular
    }
  }

  var defaultDesign: Font.Design {
    switch self {
    case .monogram: return .rounded
    default: return .default
    }
  }
}

private struct WidgetScaledFontModifier: ViewModifier {
  @ScaledMetric private var scaledSize: CGFloat
  let maxSize: CGFloat
  let weight: Font.Weight
  let design: Font.Design

  init(role: WidgetTextRole, weight: Font.Weight?, design: Font.Design?) {
    self._scaledSize = ScaledMetric(wrappedValue: role.baseSize, relativeTo: role.relativeTextStyle)
    self.maxSize = role.maxSize
    self.weight = weight ?? role.defaultWeight
    self.design = design ?? role.defaultDesign
  }

  func body(content: Content) -> some View {
    let resolved = Font.system(size: min(scaledSize, maxSize), weight: weight, design: design)
    content.font(resolved)
  }
}

extension View {
  func widgetFont(
    _ role: WidgetTextRole,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil
  ) -> some View {
    modifier(WidgetScaledFontModifier(role: role, weight: weight, design: design))
  }
}

// MARK: - Shared Views

/// Initial-letter avatar. Widgets can't load remote images at render time, so
/// every account and author is shown by the first letter of their name.
struct WidgetAvatar: View {
  let name: String?
  let size: CGFloat

  private var initial: String {
    let trimmed = (name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
    return trimmed.first.map { String($0).localizedUppercase } ?? ""
  }

  var body: some View {
    Circle()
      .fill(Color.accentColor.opacity(0.2))
      .frame(width: size, height: size)
      .overlay {
        if !initial.isEmpty {
          Text(initial)
            .widgetFont(.monogram(size))
            .foregroundStyle(Color.accentColor)
        }
      }
      .accessibilityHidden(true)
  }
}

struct WidgetHeader: View {
  let avatarName: String?
  let title: LocalizedStringResource
  let subtitle: Text?
  let lastUpdated: Date?

  init(
    avatarName: String? = nil,
    title: LocalizedStringResource,
    subtitle: Text? = nil,
    lastUpdated: Date? = nil
  ) {
    self.avatarName = avatarName
    self.title = title
    self.subtitle = subtitle
    self.lastUpdated = lastUpdated
  }

  var body: some View {
    HStack(spacing: WidgetSpacing.sm) {
      WidgetAvatar(name: avatarName, size: WidgetAvatarSize.md)

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .widgetFont(.body, weight: .semibold)
          .foregroundStyle(.primary)
          .lineLimit(1)

        if let subtitle {
          subtitle
            .widgetFont(.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if let lastUpdated {
        Text(lastUpdated, style: .relative)
          .widgetFont(.meta)
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
  let textRole: WidgetTextRole

  init(likes: Int, reposts: Int, replies: Int, textRole: WidgetTextRole = .meta) {
    self.likes = likes
    self.reposts = reposts
    self.replies = replies
    self.textRole = textRole
  }

  var body: some View {
    HStack(spacing: WidgetSpacing.sm) {
      Label {
        Text(verbatim: formatCount(likes))
      } icon: {
        Image(systemName: WidgetSymbol.like)
      }
      Label {
        Text(verbatim: formatCount(reposts))
      } icon: {
        Image(systemName: WidgetSymbol.repost)
      }
      Label {
        Text(verbatim: formatCount(replies))
      } icon: {
        Image(systemName: WidgetSymbol.reply)
      }
    }
    .widgetFont(textRole)
    .foregroundStyle(.secondary)
    .labelStyle(WidgetCompactLabelStyle())
  }

  private func formatCount(_ count: Int) -> String {
    if count >= 1000 {
      return String(format: "%.1fK", Double(count) / 1000.0)
    }
    return "\(count)"
  }
}

struct WidgetCompactLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: WidgetSpacing.hairline) {
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
  let bodyRole: WidgetTextRole

  init(
    post: WidgetPost,
    avatarSize: CGFloat = WidgetAvatarSize.md,
    textLineLimit: Int = 2,
    showEngagement: Bool = true,
    bodyRole: WidgetTextRole = .bodyCompact
  ) {
    self.post = post
    self.avatarSize = avatarSize
    self.textLineLimit = textLineLimit
    self.showEngagement = showEngagement
    self.bodyRole = bodyRole
  }

  var body: some View {
    HStack(alignment: .top, spacing: WidgetSpacing.sm) {
      if avatarSize > 0 {
        WidgetAvatar(name: post.authorName, size: avatarSize)
      }

      VStack(alignment: .leading, spacing: WidgetSpacing.hairline) {
        // Author line
        HStack(spacing: WidgetSpacing.xs) {
          Text(post.authorName)
            .widgetFont(bodyRole, weight: .semibold)
            .lineLimit(1)
          Text(post.authorHandle)
            .widgetFont(.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(verbatim: "·")
            .widgetFont(.meta)
            .foregroundStyle(.secondary)
          Text(post.timestamp, style: .relative)
            .widgetFont(.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        // Repost indicator
        if post.isRepost, let repostAuthor = post.repostAuthorName {
          Label {
            Text(
              "Reposted by \(repostAuthor)",
              comment: "Indicates who reposted a post in the feed widget; placeholder is the reposter's display name."
            )
          } icon: {
            Image(systemName: WidgetSymbol.repost)
          }
          .widgetFont(.micro)
          .foregroundStyle(.secondary)
        }

        // Post text
        Text(post.text)
          .widgetFont(bodyRole)
          .foregroundStyle(.secondary)
          .lineLimit(textLineLimit)

        // Engagement
        if showEngagement {
          EngagementRow(
            likes: post.likeCount,
            reposts: post.repostCount,
            replies: post.replyCount,
            textRole: .micro
          )
        }
      }
    }
  }
}
#endif
