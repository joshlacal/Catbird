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
        TypeDisplayRepresentation(name: "Feed Type")
    }

    public static var caseDisplayRepresentations: [FeedTypeOption: DisplayRepresentation] {
        [
            .timeline: DisplayRepresentation(title: "Following", subtitle: "Posts from people you follow"),
            .pinnedFeed: DisplayRepresentation(title: "Pinned Feed", subtitle: "Choose from your pinned feeds"),
            .savedFeed: DisplayRepresentation(title: "Saved Feed", subtitle: "Choose from your saved feeds")
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
        TypeDisplayRepresentation(name: "Layout Style")
    }

    public static var caseDisplayRepresentations: [LayoutStyleOption: DisplayRepresentation] {
        [
            .compact: DisplayRepresentation(title: "Compact", subtitle: "More posts, less spacing"),
            .comfortable: DisplayRepresentation(title: "Comfortable", subtitle: "Balanced layout"),
            .spacious: DisplayRepresentation(title: "Spacious", subtitle: "Larger posts, more spacing")
        ]
    }
}

// MARK: - Widget Configuration Intent

@available(iOS 17.0, *)
public struct ConfigurationAppIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "Widget Configuration" }
    public static var description: IntentDescription { "Configure your Catbird feed widget to show the content you want to see." }

    @Parameter(title: "Account", description: "Which account to show")
    public var account: AccountEntity?

    @Parameter(title: "Feed Type", description: "Choose what type of content to display", default: .timeline)
    public var feedType: FeedTypeOption

    @Parameter(title: "Feed", description: "Choose which pinned or saved feed to display")
    public var selectedFeed: SavedFeedEntity?

    @Parameter(title: "Post Count", description: "Number of posts to display (1-10)", default: 3)
    public var postCount: Int

    @Parameter(title: "Layout Style", description: "Choose how posts are displayed", default: .comfortable)
    public var layoutStyle: LayoutStyleOption

    @Parameter(title: "Show Avatars", description: "Show an avatar beside each post", default: true)
    public var showAvatars: Bool

    @Parameter(title: "Show Engagement Stats", description: "Display like, repost, and reply counts", default: true)
    public var showEngagementStats: Bool

    @Parameter(title: "Show Timestamps", description: "Display when posts were created", default: true)
    public var showTimestamps: Bool

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
        TypeDisplayRepresentation(name: "Saved Feed")
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
            let displayName = feedGenerators[feed] ?? "Pinned Feed"
            entities.append(SavedFeedEntity(id: feed, displayName: "📌 \(displayName)", uri: feed))
        }

        for feed in savedFeeds {
            let displayName = feedGenerators[feed] ?? "Saved Feed"
            entities.append(SavedFeedEntity(id: feed, displayName: "⭐ \(displayName)", uri: feed))
        }

        return entities
    }
}
#endif

