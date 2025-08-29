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
    private let sharedDefaults = UserDefaults(suiteName: FeedWidgetConstants.sharedSuiteName)
    private let themeProvider = WidgetThemeProvider.shared
    private let fontManager = WidgetFontManager.shared
    
    func placeholder(in context: Context) -> FeedWidgetEntry {
        FeedWidgetEntry(
            date: Date(),
            posts: createPlaceholderPosts(),
            configuration: ConfigurationAppIntent(),
            isPlaceholder: true
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> FeedWidgetEntry {
        // Refresh theme and font settings
        await MainActor.run {
            themeProvider.refreshThemeSettings()
            fontManager.refreshFontSettings()
        }
        
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
        
        // Refresh theme and font settings
        await MainActor.run {
            themeProvider.refreshThemeSettings()
            fontManager.refreshFontSettings()
        }
        
        let posts = loadFeedData(for: configuration) ?? createPlaceholderPosts()
        
        // Create single entry with posts
        let entry = FeedWidgetEntry(
            date: currentDate,
            posts: Array(posts.prefix(configuration.effectivePostCount)),
            configuration: configuration,
            isPlaceholder: false
        )
        
        // Refresh timeline based on configuration and activity
        let refreshInterval: TimeInterval = {
            switch configuration.effectiveFeedType {
            case .timeline:
                return 10 * 60 // 10 minutes for active feeds
            case .profile, .custom:
                return 20 * 60 // 20 minutes for specific feeds
            case .pinnedFeed:
                return 15 * 60 // 15 minutes for pinned feeds
            case .savedFeed:
                return 15 * 60 // 15 minutes for saved feeds
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
        guard let sharedDefaults = sharedDefaults else {
            widgetLogger.debug("No shared defaults available")
            return nil
        }
        
        // Try to load configuration-specific data first
        let configKey = createConfigurationKey(for: configuration)
        var data = sharedDefaults.data(forKey: configKey)
        
        // Fallback to general feed data if no configuration-specific data
        if data == nil {
            data = sharedDefaults.data(forKey: FeedWidgetConstants.feedDataKey)
            widgetLogger.debug("Using fallback feed data")
        } else {
            widgetLogger.debug("Using configuration-specific data for key: \(configKey)")
        }
        
        guard let feedData = data else {
            widgetLogger.debug("No widget data found")
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            // Try enhanced format first, then fallback to basic format
            if let enhancedData = try? decoder.decode(FeedWidgetDataEnhanced.self, from: feedData) {
                widgetLogger.info("Loaded \(enhancedData.posts.count) posts from enhanced data")
                return filterPosts(enhancedData.posts, for: configuration, feedType: enhancedData.feedType)
            } else if let basicData = try? decoder.decode(FeedWidgetData.self, from: feedData) {
                widgetLogger.info("Loaded \(basicData.posts.count) posts from basic data")
                return filterPosts(basicData.posts, for: configuration, feedType: basicData.feedType)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Unable to decode feed data in either format"))
            }
        } catch {
            widgetLogger.error("Failed to decode feed data: \(error.localizedDescription)")
            return nil
        }
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
            break // No additional key needed
        }
        
        return keyComponents.joined(separator: "_")
    }
    
    /// Gets the display name for a feed URI from shared preferences
    func getFeedDisplayName(for feedURI: String?) -> String? {
        guard let feedURI = feedURI,
              let sharedDefaults = sharedDefaults,
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
    
    private func filterPosts(_ posts: [WidgetPost], for configuration: ConfigurationAppIntent, feedType: String) -> [WidgetPost] {
        var filteredPosts = posts
        
        // Filter by feed type match
        let configFeedType = mapConfigurationToFeedType(configuration)
        if feedType != configFeedType {
            widgetLogger.debug("Feed type mismatch: \(feedType) != \(configFeedType)")
            return []
        }
        
        // Additional filtering for profile mode
        if configuration.effectiveFeedType == .profile && !configuration.profileHandle.isEmpty {
            filteredPosts = posts.filter { post in
                post.authorHandle.lowercased().contains(configuration.profileHandle.lowercased().replacingOccurrences(of: "@", with: ""))
            }
        }
        
        // Sort by timestamp (most recent first)
        filteredPosts.sort { $0.timestamp > $1.timestamp }
        
        return filteredPosts
    }
    
    private func mapConfigurationToFeedType(_ configuration: ConfigurationAppIntent) -> String {
        switch configuration.effectiveFeedType {
        case .timeline:
            return "timeline"
        case .pinnedFeed:
            return configuration.selectedFeedURI ?? "timeline"
        case .savedFeed:
            return configuration.selectedFeedURI ?? "timeline"
        case .custom:
            return configuration.customFeedURL ?? "custom"
        case .profile:
            return "profile"
        }
    }
    
    func createPlaceholderPosts() -> [WidgetPost] {
        [
            WidgetPost(
                id: "1",
                authorName: "Jane Doe",
                authorHandle: "@jane.bsky.social",
                authorAvatarURL: nil,
                text: "Just shipped a major update to my app! Really excited about the new features we've added. 🚀",
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
            )
        ]
    }
}

struct CatbirdFeedWidgetEntryView : View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    
    var entry: FeedWidgetProvider.Entry
    
    @StateObject private var themeProvider = WidgetThemeProvider.shared
    @StateObject private var fontManager = WidgetFontManager.shared

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallFeedWidget(entry: entry, themeProvider: themeProvider, fontManager: fontManager)
            case .systemMedium:
                MediumFeedWidget(entry: entry, themeProvider: themeProvider, fontManager: fontManager)
            case .systemLarge:
                LargeFeedWidget(entry: entry, themeProvider: themeProvider, fontManager: fontManager)
            case .systemExtraLarge:
                ExtraLargeFeedWidget(entry: entry, themeProvider: themeProvider, fontManager: fontManager)
            default:
                MediumFeedWidget(entry: entry, themeProvider: themeProvider, fontManager: fontManager)
            }
        }
        .environment(\.widgetThemeProvider, themeProvider)
        .environment(\.widgetFontManager, fontManager)
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

// MARK: - Widget Size Views

struct SmallFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background
            Color.widgetBackground(themeProvider, currentScheme: colorScheme)
            
            if let firstPost = entry.posts.first {
                VStack(spacing: 0) {
                    // Header
                    widgetHeader
                        .padding(.bottom, WidgetDesignTokens.Spacing.sm)
                    
                    // Single post card
                    WidgetPostCard(
                        post: firstPost,
                        configuration: entry.configuration,
                        themeProvider: themeProvider,
                        fontManager: fontManager,
                        isExpanded: false
                    )
                    
                    Spacer(minLength: 0)
                }
                .padding(WidgetDesignTokens.Spacing.md)
            } else {
                emptyState
            }
        }
    }
    
    @ViewBuilder
    private var widgetHeader: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.xs) {
            Image(systemName: "quote.bubble.fill")
                .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text(feedDisplayName)
                .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .lineLimit(1)
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: WidgetDesignTokens.Spacing.sm) {
            Image(systemName: "text.bubble")
                .widgetTertiaryText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text("No Posts")
                .widgetAccessibleText(role: .callout, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text("Check back later")
                .widgetTertiaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
        }
        .padding(WidgetDesignTokens.Spacing.lg)
    }
    
    private var feedDisplayName: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: 
            return "Timeline"
        case .pinnedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Pinned Feed"
        case .savedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Saved Feed"
        case .custom: 
            return "Custom Feed"
        case .profile: 
            return entry.configuration.profileHandle ?? "Profile"
        }
    }
}

struct MediumFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background
            Color.widgetBackground(themeProvider, currentScheme: colorScheme)
            
            if !entry.posts.isEmpty {
                VStack(spacing: 0) {
                    // Header
                    modernHeader
                        .padding(.bottom, WidgetDesignTokens.Spacing.md)
                    
                    // Posts
                    let postsToShow = Array(entry.posts.prefix(2))
                    WidgetPostList(
                        posts: postsToShow,
                        configuration: entry.configuration,
                        themeProvider: themeProvider,
                        fontManager: fontManager
                    )
                    
                    Spacer(minLength: 0)
                }
                .padding(WidgetDesignTokens.Spacing.md)
            } else {
                emptyStateWithHeader
            }
        }
    }
    
    @ViewBuilder
    private var modernHeader: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.sm) {
            // Feed icon
            Image(systemName: feedIcon)
                .widgetAccessibleText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            // Feed name
            Text(feedDisplayName)
                .widgetAccessibleText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .lineLimit(1)
            
            Spacer()
            
            // Last update
            Text("Updated \(entry.date, style: .relative)")
                .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .lineLimit(1)
        }
    }
    
    @ViewBuilder
    private var emptyStateWithHeader: some View {
        VStack(spacing: WidgetDesignTokens.Spacing.base) {
            modernHeader
            
            Spacer()
            
            VStack(spacing: WidgetDesignTokens.Spacing.sm) {
                Image(systemName: "text.bubble")
                    .widgetTertiaryText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                
                Text("No Posts Available")
                    .widgetAccessibleText(role: .subheadline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                
                Text("Open Catbird to load your feed")
                    .widgetTertiaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .padding(WidgetDesignTokens.Spacing.md)
    }
    
    private var feedDisplayName: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "Timeline"
        case .pinnedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Pinned Feed"
        case .savedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Saved Feed"
        case .custom: return "Custom Feed"
        case .profile:
            if !entry.configuration.profileHandle.isEmpty {
                return entry.configuration.profileHandle.replacingOccurrences(of: "@", with: "")
            }
            return "Profile"
        }
    }
    
    private var feedIcon: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "house"
        case .pinnedFeed: return "pin.fill"
        case .savedFeed: return "bookmark.fill"
        case .custom: return "list.bullet"
        case .profile: return "person.circle"
        }
    }
}

struct LargeFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background
            Color.widgetBackground(themeProvider, currentScheme: colorScheme)
            
            if !entry.posts.isEmpty {
                VStack(spacing: 0) {
                    // Header
                    largeHeader
                        .padding(.bottom, WidgetDesignTokens.Spacing.md)
                    
                    // Posts
                    let postsToShow = Array(entry.posts.prefix(3))
                    WidgetPostList(
                        posts: postsToShow,
                        configuration: entry.configuration,
                        themeProvider: themeProvider,
                        fontManager: fontManager
                    )
                    
                    Spacer(minLength: 0)
                }
                .padding(WidgetDesignTokens.Spacing.base)
            } else {
                largeEmptyState
            }
        }
    }
    
    @ViewBuilder
    private var largeHeader: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.md) {
            // Feed icon
            Image(systemName: feedIcon)
                .widgetAccessibleText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(feedDisplayName)
                    .widgetAccessibleText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
                
                Text("\(entry.posts.count) recent posts")
                    .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("Updated")
                    .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                
                Text(entry.date, style: .relative)
                    .widgetTertiaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
            }
        }
        .widgetElevation(themeProvider: themeProvider, currentScheme: colorScheme)
        .padding(WidgetDesignTokens.Spacing.md)
    }
    
    @ViewBuilder
    private var largeEmptyState: some View {
        VStack(spacing: WidgetDesignTokens.Spacing.lg) {
            largeHeader
            
            Spacer()
            
            VStack(spacing: WidgetDesignTokens.Spacing.base) {
                Image(systemName: "text.bubble.fill")
                    .widgetTertiaryText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                
                VStack(spacing: WidgetDesignTokens.Spacing.sm) {
                    Text("No Posts Available")
                        .widgetAccessibleText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    
                    Text("Your feed will appear here once content is loaded. Try opening Catbird to refresh your timeline.")
                        .widgetSecondaryText(role: .body, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            
            Spacer()
        }
        .padding(WidgetDesignTokens.Spacing.base)
    }
    
    private var feedDisplayName: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "Timeline"
        case .pinnedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Pinned Feed"
        case .savedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Saved Feed"
        case .custom: return "Custom Feed"
        case .profile:
            if !entry.configuration.profileHandle.isEmpty {
                return "\(entry.configuration.profileHandle.replacingOccurrences(of: "@", with: ""))'s Posts"
            }
            return "Profile Posts"
        }
    }
    
    private var feedIcon: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "house.fill"
        case .pinnedFeed: return "pin.fill"
        case .savedFeed: return "bookmark.fill"
        case .custom: return "list.bullet.rectangle"
        case .profile: return "person.circle.fill"
        }
    }
}

struct ExtraLargeFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background
            Color.widgetBackground(themeProvider, currentScheme: colorScheme)
            
            if !entry.posts.isEmpty {
                VStack(spacing: 0) {
                    // Header
                    extraLargeHeader
                        .padding(.bottom, WidgetDesignTokens.Spacing.lg)
                    
                    // Scrollable posts
                    ScrollView(.vertical, showsIndicators: false) {
                        WidgetPostList(
                            posts: entry.posts,
                            configuration: entry.configuration,
                            themeProvider: themeProvider,
                            fontManager: fontManager
                        )
                        .padding(.bottom, WidgetDesignTokens.Spacing.base)
                    }
                }
                .padding(WidgetDesignTokens.Spacing.lg)
            } else {
                extraLargeEmptyState
            }
        }
    }
    
    @ViewBuilder
    private var extraLargeHeader: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.lg) {
            // Feed icon with background
            ZStack {
                Circle()
                    .fill(Color.widgetElevatedBackground(themeProvider, currentScheme: colorScheme))
                    .frame(width: WidgetDesignTokens.Size.avatarLG, height: WidgetDesignTokens.Size.avatarLG)
                
                Image(systemName: feedIcon)
                    .widgetAccessibleText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            }
            
            VStack(alignment: .leading, spacing: WidgetDesignTokens.Spacing.xs) {
                Text(feedDisplayName)
                    .widgetAccessibleText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
                
                HStack(spacing: WidgetDesignTokens.Spacing.sm) {
                    Text("\(entry.posts.count) posts")
                        .widgetSecondaryText(role: .callout, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    
                    Text("•")
                        .widgetTertiaryText(role: .callout, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    
                    Text("Updated \(entry.date, style: .relative)")
                        .widgetSecondaryText(role: .callout, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                }
                .lineLimit(1)
            }
            
            Spacer()
        }
        .widgetElevation(themeProvider: themeProvider, currentScheme: colorScheme)
        .padding(WidgetDesignTokens.Spacing.base)
    }
    
    @ViewBuilder
    private var extraLargeEmptyState: some View {
        VStack(spacing: WidgetDesignTokens.Spacing.xl) {
            extraLargeHeader
            
            Spacer()
            
            VStack(spacing: WidgetDesignTokens.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(Color.widgetElevatedBackground(themeProvider, currentScheme: colorScheme))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "text.bubble.fill")
                        .widgetTertiaryText(role: .title, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                }
                
                VStack(spacing: WidgetDesignTokens.Spacing.md) {
                    Text("No Posts Available")
                        .widgetAccessibleText(role: .headline, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    
                    Text("Your \(feedDisplayName.lowercased()) will appear here once content is loaded. Try opening Catbird to refresh and check for new posts.")
                        .widgetSecondaryText(role: .body, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, WidgetDesignTokens.Spacing.xl)
            
            Spacer()
        }
        .padding(WidgetDesignTokens.Spacing.lg)
    }
    
    private var feedDisplayName: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "Timeline"
        case .pinnedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Pinned Feed"
        case .savedFeed:
            return FeedWidgetProvider().getFeedDisplayName(for: entry.configuration.selectedFeedURI) ?? "Saved Feed"
        case .custom: return "Custom Feed"
        case .profile:
            if !entry.configuration.profileHandle.isEmpty {
                return "\(entry.configuration.profileHandle.replacingOccurrences(of: "@", with: ""))'s Posts"
            }
            return "Profile Posts"
        }
    }
    
    private var feedIcon: String {
        switch entry.configuration.effectiveFeedType {
        case .timeline: return "house.fill"
        case .pinnedFeed: return "pin.fill"
        case .savedFeed: return "bookmark.fill"
        case .custom: return "list.bullet.rectangle.fill"
        case .profile: return "person.circle.fill"
        }
    }
}

// MARK: - Widget Configuration

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
