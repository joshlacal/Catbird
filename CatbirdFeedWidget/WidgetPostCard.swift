//
//  WidgetPostCard.swift
//  CatbirdFeedWidget
//
//  Created by Claude Code on 6/11/25.
//

#if os(iOS)
import SwiftUI
import WidgetKit

// MARK: - Widget Post Card

/// A sophisticated post card that matches the main app's design language
struct WidgetPostCard: View {
    let post: WidgetPost
    let configuration: ConfigurationAppIntent
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    let isExpanded: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var widgetFamily
    
    // Layout calculations
    private var avatarSize: CGFloat {
        switch (widgetFamily, configuration.effectiveLayoutStyle) {
        case (.systemSmall, _):
            return WidgetDesignTokens.Size.avatarXS
        case (.systemMedium, .compact):
            return WidgetDesignTokens.Size.avatarSM
        case (.systemMedium, _):
            return WidgetDesignTokens.Size.avatarMD
        case (.systemLarge, .compact):
            return WidgetDesignTokens.Size.avatarSM
        case (.systemLarge, _):
            return WidgetDesignTokens.Size.avatarMD
        case (.systemExtraLarge, _):
            return WidgetDesignTokens.Size.avatarLG
        default:
            return WidgetDesignTokens.Size.avatarMD
        }
    }
    
    private var spacing: CGFloat {
        switch configuration.effectiveLayoutStyle {
        case .compact:
            return WidgetDesignTokens.Spacing.sm
        case .comfortable:
            return WidgetDesignTokens.Spacing.md
        case .spacious:
            return WidgetDesignTokens.Spacing.base
        }
    }
    
    private var padding: CGFloat {
        switch configuration.effectiveLayoutStyle {
        case .compact:
            return WidgetDesignTokens.Spacing.md
        case .comfortable:
            return WidgetDesignTokens.Spacing.base
        case .spacious:
            return WidgetDesignTokens.Spacing.lg
        }
    }
    
    private var textLineLimit: Int? {
        if isExpanded {
            return widgetFamily == .systemExtraLarge ? 8 : 6
        } else {
            switch widgetFamily {
            case .systemSmall:
                return 3
            case .systemMedium:
                return 4
            case .systemLarge:
                return 5
            case .systemExtraLarge:
                return 6
            default:
                return 4
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Repost indicator if needed
            if post.isRepost, let repostAuthor = post.repostAuthorName {
                repostHeader(repostAuthor: repostAuthor)
                    .padding(.bottom, WidgetDesignTokens.Spacing.xs)
            }
            
            // Main post content
            VStack(alignment: .leading, spacing: spacing) {
                // Author header
                authorHeader
                
                // Post text
                postText
                
                // Media indicator
                if configuration.effectiveShowImages && !post.imageURLs.isEmpty {
                    mediaIndicator
                }
                
                // Engagement stats and timestamp
                if configuration.effectiveShowEngagementStats || configuration.effectiveShowTimestamps {
                    bottomRow
                }
            }
        }
        .padding(padding)
        .widgetCard(themeProvider: themeProvider, currentScheme: colorScheme)
        .widgetURL(postURL)
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private func repostHeader(repostAuthor: String) -> some View {
        HStack(spacing: WidgetDesignTokens.Spacing.xs) {
            Image(systemName: "arrow.2.squarepath")
                .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text("\(repostAuthor) reposted")
                .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .lineLimit(1)
        }
    }
    
    @ViewBuilder
    private var authorHeader: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.md) {
            // Avatar
            if configuration.effectiveShowAvatars {
                WidgetAvatarView(
                    avatarURL: post.authorAvatarURL,
                    authorName: post.authorName,
                    size: avatarSize,
                    themeProvider: themeProvider
                )
            }
            
            // Author info
            VStack(alignment: .leading, spacing: 1) {
                Text(post.authorName)
                    .widgetAccessibleText(role: .callout, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
                
                Text(post.authorHandle)
                    .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Timestamp (in header for small widgets)
            if configuration.effectiveShowTimestamps && (widgetFamily == .systemSmall || configuration.effectiveLayoutStyle == .compact) {
                Text(post.timestamp, style: .relative)
                    .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
            }
        }
    }
    
    @ViewBuilder
    private var postText: some View {
        Text(post.text)
            .widgetAccessibleText(role: .body, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            .lineLimit(textLineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private var mediaIndicator: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.xs) {
            Image(systemName: post.imageURLs.count == 1 ? "photo" : "photo.on.rectangle")
                .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text("\(post.imageURLs.count) \(post.imageURLs.count == 1 ? "image" : "images")")
                .widgetSecondaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .lineLimit(1)
        }
        .padding(.top, WidgetDesignTokens.Spacing.xs)
    }
    
    @ViewBuilder
    private var bottomRow: some View {
        HStack {
            // Engagement stats
            if configuration.effectiveShowEngagementStats {
                engagementStats
            }
            
            Spacer()
            
            // Timestamp (in bottom for larger widgets)
            if configuration.effectiveShowTimestamps && widgetFamily != .systemSmall && configuration.effectiveLayoutStyle != .compact {
                Text(post.timestamp, style: .relative)
                    .widgetTertiaryText(role: .caption, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                    .lineLimit(1)
            }
        }
        .padding(.top, WidgetDesignTokens.Spacing.sm)
    }
    
    @ViewBuilder
    private var engagementStats: some View {
        HStack(spacing: WidgetDesignTokens.Spacing.base) {
            // Replies
            if post.replyCount > 0 {
                statItem(iconName: "bubble.left", count: post.replyCount)
            }
            
            // Reposts
            if post.repostCount > 0 {
                statItem(iconName: "arrow.2.squarepath", count: post.repostCount)
            }
            
            // Likes
            if post.likeCount > 0 {
                statItem(iconName: "heart", count: post.likeCount)
            }
        }
    }
    
    @ViewBuilder
    private func statItem(iconName: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
            
            Text("\(count)")
                .widgetTertiaryText(role: .micro, themeProvider: themeProvider, fontManager: fontManager, colorScheme: colorScheme)
                .monospacedDigit()
        }
    }
    
    // MARK: - Computed Properties
    
    private var postURL: URL? {
        // Create deep link URL for this specific post
        var components = URLComponents()
        components.scheme = "blue.catbird"
        components.host = "post"
        components.queryItems = [URLQueryItem(name: "id", value: post.id)]
        return components.url
    }
}

// MARK: - Widget Post List

/// A list container for multiple post cards
struct WidgetPostList: View {
    let posts: [WidgetPost]
    let configuration: ConfigurationAppIntent
    let themeProvider: WidgetThemeProvider
    let fontManager: WidgetFontManager
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var widgetFamily
    
    private var spacing: CGFloat {
        switch configuration.effectiveLayoutStyle {
        case .compact:
            return WidgetDesignTokens.Spacing.sm
        case .comfortable:
            return WidgetDesignTokens.Spacing.md
        case .spacious:
            return WidgetDesignTokens.Spacing.base
        }
    }
    
    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                WidgetPostCard(
                    post: post,
                    configuration: configuration,
                    themeProvider: themeProvider,
                    fontManager: fontManager,
                    isExpanded: widgetFamily == .systemExtraLarge
                )
                
                // Add separator between posts (except for last)
                if index < posts.count - 1 && widgetFamily != .systemSmall {
                    Divider()
                        .foregroundColor(.widgetSeparator(themeProvider, currentScheme: colorScheme))
                        .padding(.horizontal, WidgetDesignTokens.Spacing.md)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Widget Post Card", as: .systemMedium) {
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