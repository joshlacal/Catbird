//
//  CatbirdFeedWidget.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

import WidgetKit
import SwiftUI
import os

let widgetLogger = Logger(subsystem: "blue.catbird", category: "feedWidget")

struct FeedWidgetProvider: AppIntentTimelineProvider {
    private let sharedDefaults = UserDefaults(suiteName: FeedWidgetConstants.sharedSuiteName)
    
    func placeholder(in context: Context) -> FeedWidgetEntry {
        FeedWidgetEntry(
            date: Date(),
            posts: createPlaceholderPosts(),
            configuration: ConfigurationAppIntent()
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> FeedWidgetEntry {
        let posts = loadFeedData(for: configuration) ?? createPlaceholderPosts()
        return FeedWidgetEntry(date: Date(), posts: posts, configuration: configuration)
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<FeedWidgetEntry> {
        let currentDate = Date()
        let posts = loadFeedData(for: configuration) ?? createPlaceholderPosts()
        
        // Create single entry with posts
        let entry = FeedWidgetEntry(
            date: currentDate,
            posts: Array(posts.prefix(configuration.postCount)),
            configuration: configuration
        )
        
        // Refresh timeline every 15 minutes
        let nextUpdate = Calendar.current.date(
            byAdding: .minute,
            value: 15,
            to: currentDate
        )!
        
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
    // MARK: - Private Methods
    
    private func loadFeedData(for configuration: ConfigurationAppIntent) -> [WidgetPost]? {
        guard let sharedDefaults = sharedDefaults,
              let data = sharedDefaults.data(forKey: FeedWidgetConstants.feedDataKey) else {
            widgetLogger.debug("No feed data found in shared defaults")
            return nil
        }
        
        do {
            let feedData = try JSONDecoder().decode(FeedWidgetData.self, from: data)
            widgetLogger.debug("Loaded \(feedData.posts.count) posts from shared data")
            
            // Filter posts based on selected feed type
            if feedData.feedType == configuration.feedType {
                return feedData.posts
            } else {
                widgetLogger.debug("Feed type mismatch: \(feedData.feedType) != \(configuration.feedType)")
                return nil
            }
        } catch {
            widgetLogger.error("Failed to decode feed data: \(error.localizedDescription)")
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
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme
    
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
        .widgetURL(URL(string: "blue.catbird://feed/\(entry.configuration.feedType)")!)
    }
}

// MARK: - Widget Size Views

struct SmallFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    
    var body: some View {
        if let firstPost = entry.posts.first {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                    Text(entry.configuration.feedType.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                
                // Post content
                VStack(alignment: .leading, spacing: 4) {
                    Text(firstPost.authorName)
                        .font(.caption.bold())
                        .lineLimit(1)
                    
                    Text(firstPost.text)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.primary.opacity(0.9))
                }
                
                Spacer()
                
                // Stats
                HStack(spacing: 12) {
                    Label("\(firstPost.likeCount)", systemImage: "heart")
                    Label("\(firstPost.repostCount)", systemImage: "arrow.2.squarepath")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            ContentUnavailableView(
                "No Posts",
                systemImage: "text.bubble",
                description: Text("Check back later")
            )
        }
    }
}

struct MediumFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    
    var body: some View {
        if !entry.posts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                    Text(entry.configuration.feedType.capitalized)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Updated \(entry.date.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                Divider()
                
                // First post (larger)
                if let firstPost = entry.posts.first {
                    PostRowView(post: firstPost, showImage: entry.configuration.showImages)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
        } else {
            ContentUnavailableView(
                "No Posts",
                systemImage: "text.bubble",
                description: Text("Open Catbird to load your feed")
            )
        }
    }
}

struct LargeFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    
    var body: some View {
        if !entry.posts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                    Text(entry.configuration.feedType.capitalized + " Feed")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Updated \(entry.date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                
                Divider()
                
                // Show up to 3 posts
                VStack(spacing: 0) {
                    let limitedPosts = Array(entry.posts.prefix(3))
                    ForEach(Array(limitedPosts.enumerated()), id: \.element.id) { index, post in
                        PostRowView(post: post, showImage: entry.configuration.showImages)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        
                        if index < limitedPosts.count - 1 {
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
                
                Spacer()
            }
        } else {
            ContentUnavailableView(
                "No Posts",
                systemImage: "text.bubble",
                description: Text("Open Catbird to load your feed")
            )
        }
    }
}

struct ExtraLargeFeedWidget: View {
    let entry: FeedWidgetProvider.Entry
    
    var body: some View {
        if !entry.posts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                    Text(entry.configuration.feedType.capitalized + " Feed")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Updated \(entry.date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                
                Divider()
                
                // Show all posts with scroll
                ScrollView {
                    VStack(spacing: 0) {
                        let allPosts = Array(entry.posts)
                        ForEach(Array(allPosts.enumerated()), id: \.element.id) { index, post in
                            PostRowView(post: post, showImage: entry.configuration.showImages, expanded: true)
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                            
                            if index < allPosts.count - 1 {
                                Divider()
                                    .padding(.leading)
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Posts",
                systemImage: "text.bubble",
                description: Text("Open Catbird to load your feed")
            )
        }
    }
}

// MARK: - Post Row View

struct PostRowView: View {
    let post: WidgetPost
    let showImage: Bool
    var expanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Repost indicator
            if post.isRepost, let repostAuthor = post.repostAuthorName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.caption2)
                    Text("\(repostAuthor) reposted")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            
            // Author info
            HStack(spacing: 8) {
                // Avatar placeholder
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: expanded ? 40 : 32, height: expanded ? 40 : 32)
                    .overlay(
                        Text(post.authorName.prefix(1))
                            .font(.system(size: expanded ? 16 : 14, weight: .semibold))
                            .foregroundStyle(.blue)
                    )
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(post.authorName)
                        .font(expanded ? .subheadline : .caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    
                    Text(post.authorHandle)
                        .font(expanded ? .caption : .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(post.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // Post text
            Text(post.text)
                .font(expanded ? .body : .caption)
                .lineLimit(expanded ? 6 : 3)
                .foregroundStyle(.primary.opacity(0.9))
            
            // Image indicator (if applicable)
            if showImage && !post.imageURLs.isEmpty {
                HStack {
                    Image(systemName: "photo")
                        .font(.caption)
                    Text("\(post.imageURLs.count) image\(post.imageURLs.count > 1 ? "s" : "")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            
            // Engagement stats
            HStack(spacing: 16) {
                Label("\(post.replyCount)", systemImage: "bubble.left")
                Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
                Label("\(post.likeCount)", systemImage: "heart")
            }
            .font(expanded ? .caption : .caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}

struct CatbirdFeedWidget: Widget {
    let kind: String = "CatbirdFeedWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: FeedWidgetProvider()
        ) { entry in
            CatbirdFeedWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bluesky Feed")
        .description("Shows recent posts from your selected Bluesky feed.")
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
