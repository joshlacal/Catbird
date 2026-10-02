//
//  CatbirdFeedWidget.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

#if os(iOS)
import WidgetKit
import SwiftUI
import os

let widgetLogger = Logger(subsystem: "blue.catbird", category: "feedWidget")

struct FeedWidgetProvider: AppIntentTimelineProvider {

  func placeholder(in context: Context) -> FeedWidgetEntry {
    FeedWidgetEntry(
      date: Date(),
      posts: createPlaceholderPosts(),
      configuration: ConfigurationAppIntent(),
      isPlaceholder: true
    )
  }

  func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> FeedWidgetEntry {
    let posts = loadFeedData(for: configuration) ?? createPlaceholderPosts()
    return FeedWidgetEntry(
      date: Date(),
      posts: posts,
      configuration: configuration,
      isPlaceholder: context.isPreview
    )
  }

  func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<FeedWidgetEntry> {
    let currentDate = Date()
    let posts = loadFeedData(for: configuration) ?? createPlaceholderPosts()

    let entry = FeedWidgetEntry(
      date: currentDate,
      posts: Array(posts.prefix(configuration.effectivePostCount)),
      configuration: configuration,
      isPlaceholder: false
    )

    let refreshInterval: TimeInterval = {
      switch configuration.effectiveFeedType {
      case .timeline:
        return 10 * 60
      case .profile, .custom:
        return 20 * 60
      case .pinnedFeed, .savedFeed:
        return 15 * 60
      }
    }()

    let nextUpdate = Calendar.current.date(
      byAdding: .second,
      value: Int(refreshInterval),
      to: currentDate
    )!

    return Timeline(entries: [entry], policy: .after(nextUpdate))
  }

  // MARK: - Private Methods

  private func loadFeedData(for configuration: ConfigurationAppIntent) -> [WidgetPost]? {
    let accountDID = configuration.resolvedAccountDID
    let configKey = createConfigurationKey(for: configuration)
    return WidgetDataReader.feedData(accountDID: accountDID, configKey: configKey)
  }

  /// Creates a unique key for widget configuration (matches FeedWidgetDataProvider)
  private func createConfigurationKey(for configuration: ConfigurationAppIntent) -> String {
    var keyComponents = ["widgetData", configuration.effectiveFeedType.rawValue]

    switch configuration.effectiveFeedType {
    case .pinnedFeed, .savedFeed:
      if let feedURI = configuration.selectedFeedURI {
        keyComponents.append(feedURI.replacingOccurrences(of: "at://", with: "").replacingOccurrences(of: "/", with: "_"))
      }
    case .custom:
      if !configuration.customFeedURL.isEmpty {
        keyComponents.append(configuration.customFeedURL.replacingOccurrences(of: "at://", with: "").replacingOccurrences(of: "/", with: "_"))
      }
    case .profile:
      if !configuration.profileHandle.isEmpty {
        keyComponents.append(configuration.profileHandle.replacingOccurrences(of: "@", with: ""))
      }
    case .timeline:
      break
    }

    return keyComponents.joined(separator: "_")
  }

  /// Gets the display name for a feed URI from shared preferences
  func getFeedDisplayName(for feedURI: String?) -> String? {
    guard let feedURI = feedURI,
          let sharedDefaults = UserDefaults(suiteName: FeedWidgetConstants.sharedSuiteName),
          let data = sharedDefaults.data(forKey: "feedGenerators") else {
      return nil
    }

    do {
      let decoder = JSONDecoder()
      let feedGenerators = try decoder.decode([String: String].self, from: data)
      return feedGenerators[feedURI]
    } catch {
      widgetLogger.error("Failed to decode feed generators: \(error.localizedDescription)")
      return nil
    }
  }

  func createPlaceholderPosts() -> [WidgetPost] {
    [
      WidgetPost(
        id: "1",
        authorName: "Jane Doe",
        authorHandle: "@jane.bsky.social",
        authorAvatarURL: nil,
        text: "Just shipped a major update to my app! Really excited about the new features we've added.",
        timestamp: Date(),
        likeCount: 42,
        repostCount: 5,
        replyCount: 3,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
      WidgetPost(
        id: "2",
        authorName: "Tech News",
        authorHandle: "@technews.bsky.social",
        authorAvatarURL: nil,
        text: "Breaking: New framework announced at developer conference. This changes everything for mobile development!",
        timestamp: Date().addingTimeInterval(-3600),
        likeCount: 128,
        repostCount: 34,
        replyCount: 12,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
      WidgetPost(
        id: "3",
        authorName: "Developer",
        authorHandle: "@dev.bsky.social",
        authorAvatarURL: nil,
        text: "Pro tip: Always test your widgets on different device sizes. You'd be surprised how different they can look!",
        timestamp: Date().addingTimeInterval(-7200),
        likeCount: 89,
        repostCount: 23,
        replyCount: 8,
        imageURLs: [],
        isRepost: true,
        repostAuthorName: "Code Mentor"
      ),
      WidgetPost(
        id: "4",
        authorName: "Designer",
        authorHandle: "@design.bsky.social",
        authorAvatarURL: nil,
        text: "New design system components are looking great. Consistency is key to a polished user experience.",
        timestamp: Date().addingTimeInterval(-10800),
        likeCount: 67,
        repostCount: 12,
        replyCount: 5,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
      WidgetPost(
        id: "5",
        authorName: "Open Source",
        authorHandle: "@oss.bsky.social",
        authorAvatarURL: nil,
        text: "Just released v2.0 of our popular library. Major performance improvements and new API surface.",
        timestamp: Date().addingTimeInterval(-14400),
        likeCount: 205,
        repostCount: 56,
        replyCount: 19,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
    ]
  }
}

// MARK: - Entry View

struct CatbirdFeedWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  var entry: FeedWidgetProvider.Entry

  var body: some View {
    Group {
      switch family {
      case .systemSmall:
        SmallFeedWidget(entry: entry)
      case .systemMedium:
        MediumFeedWidget(entry: entry)
      case .systemLarge:
        LargeFeedWidget(entry: entry)
      case .systemExtraLarge:
        ExtraLargeFeedWidget(entry: entry)
      default:
        MediumFeedWidget(entry: entry)
      }
    }
    .containerBackground(.clear, for: .widget)
    .widgetURL(createWidgetURL())
  }

  private func createWidgetURL() -> URL? {
    var components = URLComponents()
    components.scheme = "blue.catbird"

    switch entry.configuration.effectiveFeedType {
    case .profile:
      if !entry.configuration.profileHandle.isEmpty {
        components.host = "profile"
        components.path = "/\(entry.configuration.profileHandle)"
      } else {
        components.host = "feed"
        components.path = "/timeline"
      }
    case .custom:
      if !entry.configuration.customFeedURL.isEmpty {
        components.host = "feed"
        components.queryItems = [URLQueryItem(name: "url", value: entry.configuration.customFeedURL)]
      } else {
        components.host = "feed"
        components.path = "/timeline"
      }
    default:
      components.host = "feed"
      components.path = "/\(entry.configuration.effectiveFeedType.rawValue)"
    }

    return components.url
  }
}

// MARK: - Feed Display Name Helper

private func feedDisplayName(for configuration: ConfigurationAppIntent) -> String {
  switch configuration.effectiveFeedType {
  case .timeline:
    return "Timeline"
  case .pinnedFeed:
    return FeedWidgetProvider().getFeedDisplayName(for: configuration.selectedFeedURI) ?? "Pinned Feed"
  case .savedFeed:
    return FeedWidgetProvider().getFeedDisplayName(for: configuration.selectedFeedURI) ?? "Saved Feed"
  case .custom:
    return "Custom Feed"
  case .profile:
    if !configuration.profileHandle.isEmpty {
      return configuration.profileHandle.replacingOccurrences(of: "@", with: "")
    }
    return "Profile"
  }
}

// MARK: - Account Avatar URL Helper

private func accountAvatarURL(for configuration: ConfigurationAppIntent) -> URL? {
  if let account = configuration.account {
    return account.avatarURL
  }
  // Try to get active account avatar
  let accounts = WidgetDataReader.allAccounts()
  let activeDID = WidgetDataReader.activeAccountDID()
  if let activeDID,
     let active = accounts.first(where: { $0.did == activeDID }),
     let urlString = active.avatarURL {
    return URL(string: urlString)
  }
  return nil
}

// MARK: - Small Feed Widget

struct SmallFeedWidget: View {
  let entry: FeedWidgetProvider.Entry

  var body: some View {
    if let firstPost = entry.posts.first {
      VStack(alignment: .leading, spacing: WidgetSpacing.sm) {
        // Header: avatar + feed label
        HStack(spacing: WidgetSpacing.sm) {
          WidgetAvatar(
            url: accountAvatarURL(for: entry.configuration),
            size: WidgetAvatarSize.sm
          )

          Text(feedDisplayName(for: entry.configuration).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)

          Spacer()
        }

        // Single post inline
        VStack(alignment: .leading, spacing: WidgetSpacing.xs) {
          HStack(spacing: WidgetSpacing.xs) {
            Text(firstPost.authorName)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)

            if entry.configuration.showTimestamps {
              Text("·")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
              Text(firstPost.timestamp, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }

          Text(firstPost.text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }

        Spacer(minLength: 0)

        // Engagement at bottom
        if entry.configuration.showEngagementStats {
          EngagementRow(
            likes: firstPost.likeCount,
            reposts: firstPost.repostCount,
            replies: firstPost.replyCount,
            fontSize: 8
          )
        }
      }
      .padding(WidgetSpacing.base)
    } else {
      emptyState
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: WidgetSpacing.md) {
      Image(systemName: "text.bubble")
        .font(.title2)
        .foregroundStyle(.tertiary)

      Text("No Posts")
        .font(.system(size: 12, weight: .medium))

      Text("Check back later")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
    .padding(WidgetSpacing.lg)
  }
}

// MARK: - Medium Feed Widget

@available(iOS 17.0, *)
struct MediumFeedWidget: View {
  let entry: FeedWidgetProvider.Entry

  var body: some View {
    if !entry.posts.isEmpty {
      VStack(spacing: 0) {
        WidgetHeader(
          avatarURL: accountAvatarURL(for: entry.configuration),
          title: feedDisplayName(for: entry.configuration),
          lastUpdated: entry.date,
          refreshIntent: RefreshFeedWidgetIntent()
        )
        .padding(.bottom, WidgetSpacing.md)

        let postsToShow = Array(entry.posts.prefix(2))
        VStack(spacing: 0) {
          ForEach(Array(postsToShow.enumerated()), id: \.element.id) { index, post in
            PostRow(
              post: post,
              avatarSize: entry.configuration.showAvatars ? WidgetAvatarSize.md : 0,
              textLineLimit: 2,
              showEngagement: entry.configuration.showEngagementStats
            )

            if index < postsToShow.count - 1 {
              Divider()
                .padding(.vertical, WidgetSpacing.sm)
            }
          }
        }

        Spacer(minLength: 0)
      }
      .padding(WidgetSpacing.base)
    } else {
      emptyStateWithHeader
    }
  }

  @ViewBuilder
  private var emptyStateWithHeader: some View {
    VStack(spacing: WidgetSpacing.md) {
      WidgetHeader(
        avatarURL: accountAvatarURL(for: entry.configuration),
        title: feedDisplayName(for: entry.configuration),
        lastUpdated: entry.date,
        refreshIntent: RefreshFeedWidgetIntent()
      )

      Spacer()

      VStack(spacing: WidgetSpacing.sm) {
        Image(systemName: "text.bubble")
          .font(.title2)
          .foregroundStyle(.tertiary)

        Text("No Posts Available")
          .font(.system(size: 13, weight: .medium))

        Text("Open Catbird to load your feed")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .padding(WidgetSpacing.base)
  }
}

// MARK: - Large Feed Widget

@available(iOS 17.0, *)
struct LargeFeedWidget: View {
  let entry: FeedWidgetProvider.Entry

  private var postCount: Int {
    switch entry.configuration.layoutStyle {
    case .compact: return 4
    case .comfortable, .spacious: return 3
    }
  }

  var body: some View {
    if !entry.posts.isEmpty {
      VStack(spacing: 0) {
        WidgetHeader(
          avatarURL: accountAvatarURL(for: entry.configuration),
          title: feedDisplayName(for: entry.configuration),
          subtitle: accountHandle(for: entry.configuration),
          lastUpdated: entry.date,
          refreshIntent: RefreshFeedWidgetIntent()
        )
        .padding(.bottom, WidgetSpacing.md)

        let postsToShow = Array(entry.posts.prefix(postCount))
        VStack(spacing: 0) {
          ForEach(Array(postsToShow.enumerated()), id: \.element.id) { index, post in
            PostRow(
              post: post,
              avatarSize: entry.configuration.showAvatars ? WidgetAvatarSize.lg : 0,
              textLineLimit: 2,
              showEngagement: entry.configuration.showEngagementStats
            )

            if index < postsToShow.count - 1 {
              Divider()
                .padding(.vertical, WidgetSpacing.sm)
            }
          }
        }

        Spacer(minLength: 0)
      }
      .padding(WidgetSpacing.base)
    } else {
      largeEmptyState
    }
  }

  @ViewBuilder
  private var largeEmptyState: some View {
    VStack(spacing: WidgetSpacing.lg) {
      WidgetHeader(
        avatarURL: accountAvatarURL(for: entry.configuration),
        title: feedDisplayName(for: entry.configuration),
        subtitle: accountHandle(for: entry.configuration),
        lastUpdated: entry.date,
        refreshIntent: RefreshFeedWidgetIntent()
      )

      Spacer()

      VStack(spacing: WidgetSpacing.md) {
        Image(systemName: "text.bubble.fill")
          .font(.title)
          .foregroundStyle(.tertiary)

        VStack(spacing: WidgetSpacing.sm) {
          Text("No Posts Available")
            .font(.system(size: 14, weight: .medium))

          Text("Your feed will appear here once content is loaded. Try opening Catbird to refresh your timeline.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
        }
      }

      Spacer()
    }
    .padding(WidgetSpacing.base)
  }

  private func accountHandle(for configuration: ConfigurationAppIntent) -> String? {
    if let account = configuration.account {
      return "@\(account.handle)"
    }
    let accounts = WidgetDataReader.allAccounts()
    let activeDID = WidgetDataReader.activeAccountDID()
    if let activeDID,
       let active = accounts.first(where: { $0.did == activeDID }) {
      return "@\(active.handle)"
    }
    return nil
  }
}

// MARK: - Extra Large Feed Widget

@available(iOS 17.0, *)
struct ExtraLargeFeedWidget: View {
  let entry: FeedWidgetProvider.Entry

  private var postCount: Int {
    switch entry.configuration.layoutStyle {
    case .compact: return 8
    case .comfortable: return 6
    case .spacious: return 5
    }
  }

  var body: some View {
    if !entry.posts.isEmpty {
      VStack(spacing: 0) {
        WidgetHeader(
          avatarURL: accountAvatarURL(for: entry.configuration),
          title: feedDisplayName(for: entry.configuration),
          subtitle: "\(entry.posts.count) posts",
          lastUpdated: entry.date,
          refreshIntent: RefreshFeedWidgetIntent()
        )
        .padding(.bottom, WidgetSpacing.lg)

        let postsToShow = Array(entry.posts.prefix(postCount))
        VStack(spacing: 0) {
          ForEach(Array(postsToShow.enumerated()), id: \.element.id) { index, post in
            PostRow(
              post: post,
              avatarSize: entry.configuration.showAvatars ? WidgetAvatarSize.lg : 0,
              textLineLimit: 3,
              showEngagement: entry.configuration.showEngagementStats
            )

            if index < postsToShow.count - 1 {
              Divider()
                .padding(.vertical, WidgetSpacing.sm)
            }
          }
        }

        Spacer(minLength: 0)
      }
      .padding(WidgetSpacing.lg)
    } else {
      extraLargeEmptyState
    }
  }

  @ViewBuilder
  private var extraLargeEmptyState: some View {
    VStack(spacing: WidgetSpacing.lg) {
      WidgetHeader(
        avatarURL: accountAvatarURL(for: entry.configuration),
        title: feedDisplayName(for: entry.configuration),
        subtitle: "0 posts",
        lastUpdated: entry.date,
        refreshIntent: RefreshFeedWidgetIntent()
      )

      Spacer()

      VStack(spacing: WidgetSpacing.lg) {
        Image(systemName: "text.bubble.fill")
          .font(.largeTitle)
          .foregroundStyle(.tertiary)

        VStack(spacing: WidgetSpacing.md) {
          Text("No Posts Available")
            .font(.system(size: 15, weight: .medium))

          Text("Your feed will appear here once content is loaded. Try opening Catbird to refresh and check for new posts.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(4)
        }
      }
      .padding(.horizontal, WidgetSpacing.lg)

      Spacer()
    }
    .padding(WidgetSpacing.lg)
  }
}

// MARK: - Widget Configuration

@available(iOS 17.0, *)
struct CatbirdFeedWidget: Widget {
  let kind: String = "CatbirdFeedWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: ConfigurationAppIntent.self,
      provider: FeedWidgetProvider()
    ) { entry in
      CatbirdFeedWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Catbird Feed")
    .description("Stay connected with your Bluesky timeline, feeds, and profiles directly from your home screen.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .systemLarge,
      .systemExtraLarge
    ])
  }
}

// MARK: - Previews

@available(iOS 17.0, *)
#Preview("Small Widget", as: .systemSmall) {
  CatbirdFeedWidget()
} timeline: {
  let provider = FeedWidgetProvider()
  FeedWidgetEntry(
    date: .now,
    posts: provider.createPlaceholderPosts(),
    configuration: ConfigurationAppIntent()
  )
}

@available(iOS 17.0, *)
#Preview("Medium Widget", as: .systemMedium) {
  CatbirdFeedWidget()
} timeline: {
  let provider = FeedWidgetProvider()
  FeedWidgetEntry(
    date: .now,
    posts: provider.createPlaceholderPosts(),
    configuration: ConfigurationAppIntent()
  )
}

@available(iOS 17.0, *)
#Preview("Large Widget", as: .systemLarge) {
  CatbirdFeedWidget()
} timeline: {
  let provider = FeedWidgetProvider()
  FeedWidgetEntry(
    date: .now,
    posts: provider.createPlaceholderPosts(),
    configuration: ConfigurationAppIntent()
  )
}
#endif
