//
//  AppIntent.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

#if os(iOS)
import WidgetKit
import AppIntents

// MARK: - Feed Type Options

@available(iOS 17.0, *)
public enum FeedTypeOption: String, CaseIterable, AppEnum {
    case timeline = "timeline"
    case pinnedFeed = "pinned"
    case savedFeed = "saved"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource(
                "Feed Type",
                comment: "Widget configuration option label for choosing the feed source type."
            )
        )
    }

    public static var caseDisplayRepresentations: [FeedTypeOption: DisplayRepresentation] {
        [
            .timeline: DisplayRepresentation(
                title: LocalizedStringResource("Timeline", comment: "Widget feed type option for the home Following timeline."),
                subtitle: LocalizedStringResource("Posts from people you follow", comment: "Subtitle describing the Timeline widget feed option.")
            ),
            .pinnedFeed: DisplayRepresentation(
                title: LocalizedStringResource("Pinned Feed", comment: "Widget feed type option for choosing a pinned custom feed."),
                subtitle: LocalizedStringResource("Choose from your pinned feeds", comment: "Subtitle describing the Pinned Feed widget option.")
            ),
            .savedFeed: DisplayRepresentation(
                title: LocalizedStringResource("Saved Feed", comment: "Widget feed type option for choosing a saved custom feed."),
                subtitle: LocalizedStringResource("Choose from your saved feeds", comment: "Subtitle describing the Saved Feed widget option.")
            )
        ]
    }
}

// MARK: - Layout Style Options

@available(iOS 17.0, *)
public enum LayoutStyleOption: String, CaseIterable, AppEnum {
    case compact = "compact"
    case comfortable = "comfortable"
    case spacious = "spacious"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource(
                "Layout Style",
                comment: "Widget configuration option label for choosing post spacing density."
            )
        )
    }

    public static var caseDisplayRepresentations: [LayoutStyleOption: DisplayRepresentation] {
        [
            .compact: DisplayRepresentation(
                title: LocalizedStringResource("Compact", comment: "Widget layout density option showing more posts with tighter spacing."),
                subtitle: LocalizedStringResource("More posts, less spacing", comment: "Subtitle describing the Compact widget layout option.")
            ),
            .comfortable: DisplayRepresentation(
                title: LocalizedStringResource("Comfortable", comment: "Widget layout density option with balanced spacing."),
                subtitle: LocalizedStringResource("Balanced layout", comment: "Subtitle describing the Comfortable widget layout option.")
            ),
            .spacious: DisplayRepresentation(
                title: LocalizedStringResource("Spacious", comment: "Widget layout density option showing larger posts with more spacing."),
                subtitle: LocalizedStringResource("Larger posts, more spacing", comment: "Subtitle describing the Spacious widget layout option.")
            )
        ]
    }
}

// MARK: - Widget Configuration Intent

@available(iOS 17.0, *)
public struct ConfigurationAppIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource {
        LocalizedStringResource(
            "Widget Configuration",
            comment: "Title for the Catbird Feed widget configuration intent."
        )
    }
    public static var description: IntentDescription {
        IntentDescription(
            LocalizedStringResource(
                "Configure your Catbird feed widget to show the content you want to see.",
                comment: "Description for the Catbird Feed widget configuration intent."
            )
        )
    }

    @Parameter(
        title: LocalizedStringResource("Account", comment: "Widget configuration parameter for selecting which signed-in Bluesky account to display."),
        description: LocalizedStringResource("Which account to show", comment: "Description for the Account widget configuration parameter.")
    )
    public var account: AccountEntity?

    @Parameter(
        title: LocalizedStringResource("Feed Type", comment: "Widget configuration parameter for selecting Timeline, Pinned Feed, or Saved Feed."),
        description: LocalizedStringResource("Choose what type of content to display", comment: "Description for the Feed Type widget configuration parameter."),
        default: .timeline,
        requestDisambiguationDialog: IntentDialog(
            LocalizedStringResource("Which feed type?", comment: "Disambiguation prompt asking which widget feed type to display.")
        )
    )
    public var feedType: FeedTypeOption

    @Parameter(
        title: LocalizedStringResource("Feed", comment: "Widget configuration parameter for selecting a specific pinned or saved feed."),
        description: LocalizedStringResource("Choose which pinned or saved feed to display", comment: "Description for the Feed widget configuration parameter.")
    )
    public var selectedFeed: SavedFeedEntity?

    @Parameter(
        title: LocalizedStringResource("Post Count", comment: "Widget configuration parameter for the number of posts to display."),
        description: LocalizedStringResource("Number of posts to display (1-10)", comment: "Description for the Post Count widget configuration parameter."),
        default: 3
    )
    public var postCount: Int

    @Parameter(
        title: LocalizedStringResource("Layout Style", comment: "Widget configuration parameter for post density."),
        description: LocalizedStringResource("Choose how posts are displayed", comment: "Description for the Layout Style widget configuration parameter."),
        default: .comfortable,
        requestDisambiguationDialog: IntentDialog(
            LocalizedStringResource("Which layout style?", comment: "Disambiguation prompt asking which widget layout style to use.")
        )
    )
    public var layoutStyle: LayoutStyleOption

    @Parameter(
        title: LocalizedStringResource("Show Avatars", comment: "Widget configuration toggle for displaying author avatars."),
        description: LocalizedStringResource("Show an avatar beside each post", comment: "Description for the Show Avatars widget configuration parameter."),
        default: true
    )
    public var showAvatars: Bool

    @Parameter(
        title: LocalizedStringResource("Show Engagement Stats", comment: "Widget configuration toggle for displaying like, repost, and reply counts."),
        description: LocalizedStringResource("Display like, repost, and reply counts", comment: "Description for the Show Engagement Stats widget configuration parameter."),
        default: true
    )
    public var showEngagementStats: Bool

    @Parameter(
        title: LocalizedStringResource("Show Timestamps", comment: "Widget configuration toggle for displaying post creation times."),
        description: LocalizedStringResource("Display when posts were created", comment: "Description for the Show Timestamps widget configuration parameter."),
        default: true
    )
    public var showTimestamps: Bool

    public static var parameterSummary: some ParameterSummary {
        When(\.$feedType, .equalTo, .timeline) {
            Summary("Show \(\.$feedType)") {
                \.$account
                \.$postCount
                \.$layoutStyle
                \.$showAvatars
                \.$showEngagementStats
                \.$showTimestamps
            }
        } otherwise: {
            Summary("Show \(\.$selectedFeed) from \(\.$feedType)") {
                \.$account
                \.$postCount
                \.$layoutStyle
                \.$showAvatars
                \.$showEngagementStats
                \.$showTimestamps
            }
        }
    }

    public init() {
        account = nil
        feedType = .timeline
        selectedFeed = nil
        postCount = 3
        layoutStyle = .comfortable
        showAvatars = true
        showEngagementStats = true
        showTimestamps = true
    }

    public init(
        account: AccountEntity? = nil,
        feedType: FeedTypeOption = .timeline,
        selectedFeed: SavedFeedEntity? = nil,
        postCount: Int = 3,
        layoutStyle: LayoutStyleOption = .comfortable,
        showAvatars: Bool = true,
        showEngagementStats: Bool = true,
        showTimestamps: Bool = true
    ) {
        self.account = account
        self.feedType = feedType
        self.selectedFeed = selectedFeed
        self.postCount = min(max(postCount, 1), 10) // Clamp between 1-10
        self.layoutStyle = layoutStyle
        self.showAvatars = showAvatars
        self.showEngagementStats = showEngagementStats
        self.showTimestamps = showTimestamps
    }

    /// Resolved account DID — the selected account, or the active account when none is
    /// selected. Empty when the selected account is no longer in Catbird or no account
    /// is signed in, so the widget shows its signed-out state.
    public var resolvedAccountDID: String {
        if let account {
            let signedIn = WidgetDataReader.allAccounts().contains { $0.did == account.id }
            return signedIn ? account.id : ""
        }
        return WidgetDataReader.activeAccountDID() ?? ""
    }

    // MARK: - Convenience Properties with Defaults

    /// Feed type with default value
    public var effectiveFeedType: FeedTypeOption {
        return feedType
    }
    
    /// Selected feed URI for backward compatibility
    public var selectedFeedURI: String? {
        return selectedFeed?.uri
    }

    /// Post count with default value
    public var effectivePostCount: Int {
        return postCount
    }

    /// Layout style with default value
    public var effectiveLayoutStyle: LayoutStyleOption {
        return layoutStyle
    }

    /// Show avatars with default value
    public var effectiveShowAvatars: Bool {
        return showAvatars
    }

    /// Show engagement stats with default value
    public var effectiveShowEngagementStats: Bool {
        return showEngagementStats
    }

    /// Show timestamps with default value
    public var effectiveShowTimestamps: Bool {
        return showTimestamps
    }
}

// MARK: - Dynamic Feed Entities

@available(iOS 17.0, *)
public struct SavedFeedEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource(
                "Saved Feed",
                comment: "Widget configuration entity type name for a saved or pinned Bluesky custom feed."
            ),
            numericFormat: LocalizedStringResource(
                "\(placeholder: .int) saved feeds",
                comment: "Pluralized count of saved Bluesky custom feeds."
            )
        )
    }
    
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
    
    public static var defaultQuery = SavedFeedQuery()
    
    public let id: String
    public let displayName: String
    public let uri: String
    
    public init(id: String, displayName: String, uri: String) {
        self.id = id
        self.displayName = displayName
        self.uri = uri
    }
}

@available(iOS 17.0, *)
public struct SavedFeedQuery: EntityQuery {
    public init() {}
    
    public func entities(for identifiers: [String]) async throws -> [SavedFeedEntity] {
        let feeds = loadSavedFeeds()
        return feeds.filter { identifiers.contains($0.id) }
    }
    
    public func suggestedEntities() async throws -> [SavedFeedEntity] {
        return loadSavedFeeds()
    }
    
    private func loadSavedFeeds() -> [SavedFeedEntity] {
        guard let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared"),
              let accountDID = WidgetDataReader.activeAccountDID() else {
            return []
        }

        let decoder = JSONDecoder()

        // The app stores these per account (see FeedWidgetDataProvider.updateSharedFeedPreferences).
        func stringList(_ key: String) -> [String] {
            guard let data = sharedDefaults.data(forKey: "\(key).\(accountDID)") else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }

        let feedGenerators: [String: String] = {
            guard let data = sharedDefaults.data(forKey: "feedGenerators.\(accountDID)") else { return [:] }
            return (try? decoder.decode([String: String].self, from: data)) ?? [:]
        }()

        // Only feed generators can be shown: the app saves widget posts for those feeds,
        // not for lists or the Following timeline (which has its own feed type).
        func isFeedGenerator(_ uri: String) -> Bool {
            uri.contains("/app.bsky.feed.generator/")
        }

        let pinnedFeeds = stringList("pinnedFeeds").filter(isFeedGenerator)
        let pinnedSet = Set(pinnedFeeds)
        let savedFeeds = stringList("savedFeeds").filter { isFeedGenerator($0) && !pinnedSet.contains($0) }

        var entities: [SavedFeedEntity] = []

        for feed in pinnedFeeds {
            let displayName = feedGenerators[feed] ?? String(
                localized: "Pinned Feed",
                comment: "Fallback name for a pinned Bluesky feed in widget configuration."
            )
            entities.append(SavedFeedEntity(id: feed, displayName: "📌 \(displayName)", uri: feed))
        }

        for feed in savedFeeds {
            let displayName = feedGenerators[feed] ?? String(
                localized: "Saved Feed",
                comment: "Fallback name for a saved Bluesky feed in widget configuration."
            )
            entities.append(SavedFeedEntity(id: feed, displayName: "⭐ \(displayName)", uri: feed))
        }

        return entities
    }
}
#endif

