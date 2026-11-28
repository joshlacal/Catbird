//
//  CatbirdCatalogAuxSurfaces.swift
//  Catbird
//
//  Offline mocked catalog surfaces for Notifications and Widgets.
//

#if DEBUG
import Petrel
import SwiftUI

// MARK: - Notifications Surface

struct CatalogNotificationsSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var path = NavigationPath()
  @State private var selectedFilter = 0

  var body: some View {
    let items = Array((PreviewFixtures.notifications?.notifications ?? []).prefix(8))
    let groups = items.enumerated().map { index, notification in
      GroupedNotification(
        id: "catalog-notif-\(index)-\(notification.cid)",
        type: Self.notificationType(for: notification.reason),
        notifications: [notification],
        subjectPost: PreviewFixtures.post(.textShort),
        parentPost: nil,
        pageNumber: 0
      )
    }

    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
              CatbirdChip(title: Text(verbatim: "All"), isSelected: selectedFilter == 0) { selectedFilter = 0 }
              CatbirdChip(title: Text(verbatim: "Mentions"), isSelected: selectedFilter == 1) { selectedFilter = 1 }
              CatbirdChip(title: Text(verbatim: "Replies"), isSelected: selectedFilter == 2) { selectedFilter = 2 }
              CatbirdChip(title: Text(verbatim: "Quotes"), isSelected: selectedFilter == 3) { selectedFilter = 3 }
            }
          }

          ForEach(groups) { group in
            NotificationCard(group: group, onTap: { _ in }, path: $path)
          }
        }
        .padding(Space.screenMargin)
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .navigationTitle(Text(verbatim: "Notifications"))
    }
    .accessibilityIdentifier("catalog.surface.content.notifications")
  }

  private static func notificationType(for reason: String) -> NotificationType {
    switch reason {
    case "like-via-repost": return .likeViaRepost
    case "repost-via-repost": return .repostViaRepost
    case "starterpack-joined": return .starterpackJoined
    default: return NotificationType(rawValue: reason) ?? .like
    }
  }
}

// MARK: - Widgets Surface

struct CatalogWidgetsSurface: View {
  @Environment(\.themeManager) private var themeManager
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let feedPosts = Array((PreviewFixtures.timeline?.feed ?? []).prefix(3))
    let notificationsCount = PreviewFixtures.notifications?.notifications.count ?? 4

    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.xl) {
          smallNotificationWidget(count: notificationsCount)
          mediumFeedWidget(firstPost: feedPosts.first)
          largeFeedWidget(posts: feedPosts)
        }
        .padding(Space.screenMargin)
      }
      .background(
        themeManager.map { Color.dynamicBackground($0, currentScheme: colorScheme) }
          ?? Color.clear
      )
      .navigationTitle(Text(verbatim: "Widgets"))
    }
    .accessibilityIdentifier("catalog.surface.content.widgets")
  }

  private func smallNotificationWidget(count: Int) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "System Small (Notifications)")
        .appFont(AppTextRole.headline)

      VStack(alignment: .leading, spacing: Space.sm) {
        HStack {
          Image(systemName: "bell.badge.fill")
            .appFont(AppTextRole.title3)
            .foregroundStyle(.tint)
          Spacer()
          CatbirdBadge(Text(verbatim: "\(count) new"), tone: .accent)
        }
        Spacer(minLength: Space.sm)
        Text(verbatim: "Mentions & Likes")
          .appFont(AppTextRole.subheadline)
        Text(verbatim: "Latest activity from @catbird.blue")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(Space.lg)
      .frame(width: 158, height: 158, alignment: .topLeading)
      .catbirdCard(.panel, radius: .xl)
    }
  }

  private func mediumFeedWidget(firstPost: AppBskyFeedDefs.FeedViewPost?) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "System Medium (Feed)")
        .appFont(AppTextRole.headline)

      VStack(alignment: .leading, spacing: Space.sm) {
        HStack {
          Text(verbatim: "Following")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
          Spacer()
          CatbirdBadge(Text(verbatim: "Live"), tone: .accent)
        }
        if let first = firstPost {
          CompactPostCard(
            avatarURL: first.post.author.finalAvatarURL(),
            displayName: first.post.author.displayName ?? first.post.author.handle.description,
            handle: first.post.author.handle.description,
            text: "Compact timeline preview inside a System Medium widget container."
          )
        }
      }
      .padding(Space.lg)
      .frame(maxWidth: 338, alignment: .leading)
      .catbirdCard(.panel, radius: .xl)
    }
  }

  private func largeFeedWidget(posts: [AppBskyFeedDefs.FeedViewPost]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "System Large (Multi-Post Feed)")
        .appFont(AppTextRole.headline)

      VStack(alignment: .leading, spacing: Space.md) {
        ForEach(posts, id: \.post.cid) { item in
          CompactPostCard(
            avatarURL: item.post.author.finalAvatarURL(),
            displayName: item.post.author.displayName ?? item.post.author.handle.description,
            handle: item.post.author.handle.description,
            text: "Deterministic timeline entry from the harvested fixture corpus."
          )
        }
      }
      .padding(Space.lg)
      .frame(maxWidth: 338, alignment: .leading)
      .catbirdCard(.panel, radius: .xl)
    }
  }
}
#endif
