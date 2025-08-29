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

@available(iOS 16.0, *)
public enum FeedTypeOption: String, CaseIterable, AppEnum {
    case timeline = "timeline"
    case pinnedFeed = "pinned"
    case savedFeed = "saved"
    case custom = "custom"
    case profile = "profile"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Feed Type")
    }

    public static var caseDisplayRepresentations: [FeedTypeOption: DisplayRepresentation] {
        [
            .timeline: DisplayRepresentation(title: "Home Timeline", subtitle: "Your personalized timeline"),
            .pinnedFeed: DisplayRepresentation(title: "Pinned Feed", subtitle: "Choose from your pinned feeds"),
            .savedFeed: DisplayRepresentation(title: "Saved Feed", subtitle: "Choose from your saved feeds"),
            .custom: DisplayRepresentation(title: "Custom Feed", subtitle: "Enter a specific feed URL"),
            .profile: DisplayRepresentation(title: "Profile", subtitle: "Posts from a specific user")
        ]
    }
}

// MARK: - Layout Style Options

@available(iOS 16.0, *)
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

@available(iOS 16.0, *)
public struct ConfigurationAppIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "Widget Configuration" }
    public static var description: IntentDescription { "Configure your Catbird feed widget to show the content you want to see." }

    @Parameter(title: "Feed Type", description: "Choose what type of content to display", default: .timeline)
    public var feedType: FeedTypeOption

    @Parameter(title: "Feed Selection", description: "Choose which pinned/saved feed to display")
    public var selectedFeed: SavedFeedEntity?

    @Parameter(title: "Custom Feed URL", description: "Enter a custom feed URL (only used for Custom Feed type)", default: "")
    public var customFeedURL: String

    @Parameter(title: "Profile Handle", description: "Enter a profile handle (only used for Profile type, e.g., @user.bsky.social)", default: "")
    public var profileHandle: String

    @Parameter(title: "Post Count", description: "Number of posts to display (1-10)", default: 3)
    public var postCount: Int

    @Parameter(title: "Layout Style", description: "Choose how posts are displayed", default: .comfortable)
    public var layoutStyle: LayoutStyleOption

    @Parameter(title: "Show Avatars", description: "Display user profile pictures", default: true)
    public var showAvatars: Bool

    @Parameter(title: "Show Images", description: "Display post media previews", default: true)
    public var showImages: Bool

    @Parameter(title: "Show Engagement Stats", description: "Display like, repost, and reply counts", default: true)
    public var showEngagementStats: Bool

    @Parameter(title: "Show Timestamps", description: "Display when posts were created", default: true)
    public var showTimestamps: Bool

    public init() {
        feedType = .timeline
        selectedFeed = nil
        customFeedURL = ""
        profileHandle = ""
        postCount = 3
        layoutStyle = .comfortable
        showAvatars = true
        showImages = true
        showEngagementStats = true
        showTimestamps = true
    }

    public init(
        feedType: FeedTypeOption = .timeline,
        selectedFeed: SavedFeedEntity? = nil,
        customFeedURL: String = "",
        profileHandle: String = "",
        postCount: Int = 3,
        layoutStyle: LayoutStyleOption = .comfortable,
        showAvatars: Bool = true,
        showImages: Bool = true,
        showEngagementStats: Bool = true,
        showTimestamps: Bool = true
    ) {
        self.feedType = feedType
        self.selectedFeed = selectedFeed
        self.customFeedURL = customFeedURL
        self.profileHandle = profileHandle
        self.postCount = min(max(postCount, 1), 10) // Clamp between 1-10
        self.layoutStyle = layoutStyle
        self.showAvatars = showAvatars
        self.showImages = showImages
        self.showEngagementStats = showEngagementStats
        self.showTimestamps = showTimestamps
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

    /// Show images with default value
    public var effectiveShowImages: Bool {
        return showImages
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

@available(iOS 16.0, *)
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

@available(iOS 16.0, *)
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
        guard let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared") else {
            return []
        }
        
        let decoder = JSONDecoder()
        
        // Load saved feeds
        let savedFeeds: [String] = {
            guard let data = sharedDefaults.data(forKey: "savedFeeds") else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }()
        
        // Load feed generators for display names
        let feedGenerators: [String: String] = {
            guard let data = sharedDefaults.data(forKey: "feedGenerators") else { return [:] }
            return (try? decoder.decode([String: String].self, from: data)) ?? [:]
        }()
        
        // Load pinned feeds
        let pinnedFeeds: [String] = {
            guard let data = sharedDefaults.data(forKey: "pinnedFeeds") else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }()
        
        var entities: [SavedFeedEntity] = []
        
        // Add pinned feeds
        for feed in pinnedFeeds {
            let displayName = feedGenerators[feed] ?? "Pinned Feed"
            entities.append(SavedFeedEntity(id: feed, displayName: "📌 \(displayName)", uri: feed))
        }
        
        // Add saved feeds
        for feed in savedFeeds {
            let displayName = feedGenerators[feed] ?? "Saved Feed"
            entities.append(SavedFeedEntity(id: feed, displayName: "⭐ \(displayName)", uri: feed))
        }
        
        return entities
    }
}

// MARK: - App Intent for Opening Specific Feed

@available(iOS 16.0, *)
public struct OpenFeedAppIntent: AppIntent {
    public static var title: LocalizedStringResource { "Open Feed" }
    public static var description: IntentDescription { "Open a specific feed in Catbird." }

    @Parameter(title: "Feed Type")
    public var feedType: String

    @Parameter(title: "Feed URL")
    public var feedURL: String

    @Parameter(title: "Profile Handle")
    public var profileHandle: String

    public init() {
        feedType = "timeline"
        feedURL = ""
        profileHandle = ""
    }

    public func perform() async throws -> some IntentResult {
        // Construct deep link URL
        var urlComponents = URLComponents()
        urlComponents.scheme = "blue.catbird"

        switch feedType {
        case "profile":
            if !profileHandle.isEmpty {
                urlComponents.host = "profile"
                urlComponents.path = "/\(profileHandle)"
            } else {
                urlComponents.host = "feed"
                urlComponents.path = "/timeline"
            }
        case "custom":
            if !feedURL.isEmpty {
                urlComponents.host = "feed"
                urlComponents.queryItems = [URLQueryItem(name: "url", value: feedURL)]
            } else {
                urlComponents.host = "feed"
                urlComponents.path = "/timeline"
            }
        default:
            urlComponents.host = "feed"
            urlComponents.path = "/\(feedType)"
        }

        if let url = urlComponents.url {
            return .result(value: url)
        }

        // Return empty URL as fallback
        return .result(value: URL(string: "blue.catbird://feed/timeline")!)
    }
}

// MARK: - App Intent for Opening Specific Post

@available(iOS 16.0, *)
public struct OpenPostAppIntent: AppIntent {
    public static var title: LocalizedStringResource { "Open Post" }
    public static var description: IntentDescription { "Open a specific post in Catbird." }

    @Parameter(title: "Post URI")
    public var postURI: String

    public init() {
        postURI = ""
    }

    public func perform() async throws -> some IntentResult {
        // Construct deep link URL for post
        var urlComponents = URLComponents()
        urlComponents.scheme = "blue.catbird"
        urlComponents.host = "post"
        urlComponents.queryItems = [URLQueryItem(name: "uri", value: postURI)]

        if let url = urlComponents.url {
            return .result(value: url)
        }

        // Return empty URL as fallback
        return .result(value: URL(string: "blue.catbird://feed/timeline")!)
    }
}
#endif

