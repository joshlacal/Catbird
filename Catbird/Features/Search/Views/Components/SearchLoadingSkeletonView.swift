//
//  SearchLoadingSkeletonView.swift
//  Catbird
//
//  Loading skeleton view for search results
//

import SwiftUI

/// Skeleton loading view shown during search operations
struct SearchLoadingSkeletonView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Profiles section skeleton
                SearchSectionSkeleton(
                    title: "Profiles",
                    icon: "person",
                    itemCount: 3,
                    itemType: .profile
                )
                
                // Posts section skeleton
                SearchSectionSkeleton(
                    title: "Posts", 
                    icon: "text.bubble",
                    itemCount: 3,
                    itemType: .post
                )
                
                // Feeds section skeleton
                SearchSectionSkeleton(
                    title: "Feeds",
                    icon: "rectangle.on.rectangle.angled", 
                    itemCount: 2,
                    itemType: .feed
                )
            }
            .mainContentFrame()
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
    }
}

/// Individual section skeleton for search results
struct SearchSectionSkeleton: View {
    let title: String
    let icon: String
    let itemCount: Int
    let itemType: SearchSkeletonItemType
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .appFont(AppTextRole.subheadline)
                
                Text(title)
                    .appFont(AppTextRole.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Skeleton items
            VStack(spacing: 8) {
                ForEach(0..<itemCount, id: \.self) { _ in
                    SkeletonItemView(type: itemType)
                }
            }
        }
        .background(
            Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme).opacity(0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Individual skeleton item based on type
struct SkeletonItemView: View {
    let type: SearchSkeletonItemType
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar/Icon
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: avatarSize, height: avatarSize)
                .shimmer()
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Title
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: titleHeight)
                    .frame(maxWidth: titleWidth)
                    .shimmer()
                
                // Subtitle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: subtitleHeight)
                    .frame(maxWidth: subtitleWidth)
                    .shimmer()
                
                // Additional content for posts
                if type == .post {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 12)
                        .frame(maxWidth: .infinity)
                        .shimmer()
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // Type-specific sizing
    private var avatarSize: CGFloat {
        switch type {
        case .profile: return 50
        case .post: return 40
        case .feed: return 50
        }
    }
    
    private var titleHeight: CGFloat { 16 }
    private var subtitleHeight: CGFloat { 12 }
    
    private var titleWidth: CGFloat {
        switch type {
        case .profile: return 140
        case .post: return 200
        case .feed: return 160
        }
    }
    
    private var subtitleWidth: CGFloat {
        switch type {
        case .profile: return 100
        case .post: return 120
        case .feed: return 90
        }
    }
}

/// Types of skeleton items to render
enum SearchSkeletonItemType {
    case profile
    case post
    case feed
}

/// Shimmer effect modifier
struct ShimmerModifier: ViewModifier {
    @State private var isAnimating = false
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.3),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: isAnimating ? 1 : 0.1, anchor: .leading)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                    .onAppear {
                        isAnimating = true
                    }
            )
            .clipped()
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
    SearchLoadingSkeletonView()
        .applyAppStateEnvironment(appState)
}
