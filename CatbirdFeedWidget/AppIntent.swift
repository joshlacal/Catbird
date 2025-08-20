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

enum FeedTypeOption: String, CaseIterable, AppEnum {
    case timeline = "timeline"
    case pinnedFeed = "pinned"
    case savedFeed = "saved" 
    case custom = "custom"
    case profile = "profile"
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Feed Type")
    }
    
    static var caseDisplayRepresentations: [FeedTypeOption: DisplayRepresentation] {
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

enum LayoutStyleOption: String, CaseIterable, AppEnum {
    case compact = "compact"
    case comfortable = "comfortable"
    case spacious = "spacious"
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Layout Style")
    }
    
    static var caseDisplayRepresentations: [LayoutStyleOption: DisplayRepresentation] {
        [
            .compact: DisplayRepresentation(title: "Compact", subtitle: "More posts, less spacing"),
            .comfortable: DisplayRepresentation(title: "Comfortable", subtitle: "Balanced layout"),
            .spacious: DisplayRepresentation(title: "Spacious", subtitle: "Larger posts, more spacing")
        ]
    }
}

// MARK: - Widget Configuration Intent

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Widget Configuration" }
    static var description: IntentDescription { "Configure your Catbird feed widget to show the content you want to see." }

    @Parameter(title: "Feed Type", description: "Choose what type of content to display")
    var feedType: FeedTypeOption?
    
    @Parameter(title: "Feed Selection", description: "Choose which pinned/saved feed to display")
    var selectedFeedURI: String?
    
    @Parameter(title: "Custom Feed URL", description: "Enter a custom feed URL (only used for Custom Feed type)")
    var customFeedURL: String?
    
    @Parameter(title: "Profile Handle", description: "Enter a profile handle (only used for Profile type, e.g., @user.bsky.social)")
    var profileHandle: String?
    
    @Parameter(title: "Post Count", description: "Number of posts to display (1-10)")
    var postCount: Int?
    
    @Parameter(title: "Layout Style", description: "Choose how posts are displayed")
    var layoutStyle: LayoutStyleOption?
    
    @Parameter(title: "Show Avatars", description: "Display user profile pictures")
    var showAvatars: Bool?
    
    @Parameter(title: "Show Images", description: "Display post media previews")
    var showImages: Bool?
    
    @Parameter(title: "Show Engagement Stats", description: "Display like, repost, and reply counts")
    var showEngagementStats: Bool?
    
    @Parameter(title: "Show Timestamps", description: "Display when posts were created")
    var showTimestamps: Bool?
    
    init() {
        feedType = .timeline
        selectedFeedURI = nil
        customFeedURL = nil
        profileHandle = nil
        postCount = 3
        layoutStyle = .comfortable
        showAvatars = true
        showImages = true
        showEngagementStats = true
        showTimestamps = true
    }
    
    init(
        feedType: FeedTypeOption? = .timeline,
        selectedFeedURI: String? = nil,
        customFeedURL: String? = nil,
        profileHandle: String? = nil,
        postCount: Int? = 3,
        layoutStyle: LayoutStyleOption? = .comfortable,
        showAvatars: Bool? = true,
        showImages: Bool? = true,
        showEngagementStats: Bool? = true,
        showTimestamps: Bool? = true
    ) {
        self.feedType = feedType
        self.selectedFeedURI = selectedFeedURI
        self.customFeedURL = customFeedURL
        self.profileHandle = profileHandle
        self.postCount = postCount.map { min(max($0, 1), 10) } // Clamp between 1-10
        self.layoutStyle = layoutStyle
        self.showAvatars = showAvatars
        self.showImages = showImages
        self.showEngagementStats = showEngagementStats
        self.showTimestamps = showTimestamps
    }
    
    // MARK: - Convenience Properties with Defaults
    
    /// Feed type with default value
    var effectiveFeedType: FeedTypeOption {
        return feedType ?? .timeline
    }
    
    /// Post count with default value
    var effectivePostCount: Int {
        return postCount ?? 3
    }
    
    /// Layout style with default value
    var effectiveLayoutStyle: LayoutStyleOption {
        return layoutStyle ?? .comfortable
    }
    
    /// Show avatars with default value
    var effectiveShowAvatars: Bool {
        return showAvatars ?? true
    }
    
    /// Show images with default value
    var effectiveShowImages: Bool {
        return showImages ?? true
    }
    
    /// Show engagement stats with default value
    var effectiveShowEngagementStats: Bool {
        return showEngagementStats ?? true
    }
    
    /// Show timestamps with default value
    var effectiveShowTimestamps: Bool {
        return showTimestamps ?? true
    }
}

// MARK: - App Intent for Opening Specific Feed

struct OpenFeedAppIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Feed" }
    static var description: IntentDescription { "Open a specific feed in Catbird." }
    
    @Parameter(title: "Feed Type")
    var feedType: String
    
    @Parameter(title: "Feed URL")
    var feedURL: String?
    
    @Parameter(title: "Profile Handle")
    var profileHandle: String?
    
    func perform() async throws -> some IntentResult {
        // Construct deep link URL
        var urlComponents = URLComponents()
        urlComponents.scheme = "blue.catbird"
        
        switch feedType {
        case "profile":
            if let handle = profileHandle {
                urlComponents.host = "profile"
                urlComponents.path = "/\(handle)"
            } else {
                urlComponents.host = "feed"
                urlComponents.path = "/timeline"
            }
        case "custom":
            if let feedURL = feedURL {
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
            return .result(opensIntent: OpenURLIntent(url))
        }
        
        return .result()
    }
}

// MARK: - App Intent for Opening Specific Post

struct OpenPostAppIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Post" }
    static var description: IntentDescription { "Open a specific post in Catbird." }
    
    @Parameter(title: "Post URI")
    var postURI: String
    
    func perform() async throws -> some IntentResult {
        // Construct deep link URL for post
        var urlComponents = URLComponents()
        urlComponents.scheme = "blue.catbird"
        urlComponents.host = "post"
        urlComponents.queryItems = [URLQueryItem(name: "uri", value: postURI)]
        
        if let url = urlComponents.url {
            return .result(opensIntent: OpenURLIntent(url))
        }
        
        return .result()
    }
}
#endif
