//
//  WidgetAvatarView.swift
//  CatbirdFeedWidget
//
//  Created by Claude Code on 6/11/25.
//

import SwiftUI
import WidgetKit

/// A widget-optimized avatar view that handles loading and fallback states
struct WidgetAvatarView: View {
    let avatarURL: String?
    let authorName: String
    let size: CGFloat
    let themeProvider: WidgetThemeProvider
    
    @Environment(\.colorScheme) private var colorScheme
    
    // Use simple color generation for initials fallback
    private var initialsColor: Color {
        guard !authorName.isEmpty else { return .blue }
        
        // Generate a consistent color based on the author name
        let hash = authorName.hash
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .indigo, .teal, .red]
        let index = abs(hash) % colors.count
        return colors[index]
    }
    
    private var initials: String {
        let components = authorName.components(separatedBy: " ")
        if components.count >= 2 {
            let first = String(components[0].prefix(1))
            let last = String(components[1].prefix(1))
            return (first + last).uppercased()
        } else {
            return String(authorName.prefix(2)).uppercased()
        }
    }
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(initialsColor.opacity(0.2))
                .frame(width: size, height: size)
            
            if let avatarURL = avatarURL, let url = URL(string: avatarURL) {
                // Try to load real avatar
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } placeholder: {
                    // Loading state - show initials
                    initialsView
                }
            } else {
                // No URL - show initials
                initialsView
            }
        }
    }
    
    @ViewBuilder
    private var initialsView: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundColor(initialsColor)
            .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("Widget Avatars", as: .systemMedium) {
    CatbirdFeedWidget()
} timeline: {
    FeedWidgetEntry(
        date: .now,
        posts: [
            WidgetPost(
                id: "1",
                authorName: "Jane Doe",
                authorHandle: "@jane.bsky.social",
                authorAvatarURL: "https://avatars.githubusercontent.com/u/1?v=4",
                text: "Testing avatar loading in widgets",
                timestamp: Date(),
                likeCount: 42,
                repostCount: 5,
                replyCount: 3,
                imageURLs: [],
                isRepost: false,
                repostAuthorName: nil
            )
        ],
        configuration: ConfigurationAppIntent()
    )
}