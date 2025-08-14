//
//  iOS18GridFeedView.swift
//  Catbird
//
//  iOS 18 Grid-based feed view with adaptive layouts and ProMotion support
//

import SwiftUI
import Nuke
import NukeUI
import Petrel
import OSLog

// MARK: - iOS 18 Grid Feed View

@available(iOS 18.0, *)
struct iOS18GridFeedView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var appState: AppState
    @State private var feedStateManager: FeedStateManager
    @State private var abTesting: ABTestingFramework
    
    @State private var gridLayout: GridLayout = .adaptive
    @State private var selectedPost: CachedFeedViewPost?
    @State private var scrollPosition: ScrollPosition = .init()
    @State private var visibleItems: Set<String> = []
    
    private let logger = Logger(subsystem: "blue.catbird", category: "iOS18GridFeedView")
    
    // MARK: - Grid Layout Configuration
    
    enum GridLayout {
        case singleColumn
        case twoColumn
        case threeColumn
        case adaptive
        
        var columns: [GridItem] {
            switch self {
            case .singleColumn:
                return [GridItem(.flexible())]
            case .twoColumn:
                return [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]
            case .threeColumn:
                return [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ]
            case .adaptive:
                return [
                    GridItem(.adaptive(minimum: 180, maximum: 400), spacing: 12)
                ]
            }
        }
    }
    
    init(appState: AppState, feedType: FetchType) {
        self._appState = State(initialValue: appState)
        let feedStateManager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
        self._feedStateManager = State(initialValue: feedStateManager)
        self._abTesting = State(initialValue: ABTestingFramework())
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: currentGridColumns,
                spacing: gridSpacing,
                pinnedViews: [.sectionHeaders]
            ) {
                Section {
                    ForEach(feedStateManager.posts, id: \.id) { post in
                        GridFeedPostCard(
                            post: post,
                            appState: appState,
                            isSelected: selectedPost?.id == post.id
                        )
                        .id(post.id)
                        .onAppear {
                            handlePostAppear(post)
                        }
                        .onDisappear {
                            handlePostDisappear(post)
                        }
                        .onTapGesture {
                            handlePostTap(post)
                        }
                        // iOS 18: Smooth spring animation
                        .animation(.smooth(duration: 0.3), value: selectedPost?.id)
                        // iOS 18: Phase animator for subtle hover effects
                        .phaseAnimator([false, true]) { content, phase in
                            content
                                .scaleEffect(phase ? 1.02 : 1.0)
                        }
                    }
                    
                    // Loading indicator
                    if feedStateManager.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                } header: {
                    if feedStateManager.hasNewPosts {
                        NewPostsIndicatorBar(
                            count: feedStateManager.newPostsCount,
                            onTap: {
                                Task { @MainActor in
                                    feedStateManager.scrollToTopAndClearNewPosts()
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
        // iOS 18: Enhanced scroll position tracking
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
        // iOS 18: Content margins for better edge-to-edge design
        .contentMargins(.horizontal, contentHorizontalMargin, for: .scrollContent)
        .refreshable {
            await handleRefresh()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GridLayoutPicker(selection: $gridLayout)
            }
        }
        .onChange(of: gridLayout) { _, newLayout in
            withAnimation(.smooth) {
                // Layout change animation handled automatically
            }
        }
        .task {
            await loadInitialDataIfNeeded()
        }
    }
    
    // MARK: - Computed Properties
    
    private var currentGridColumns: [GridItem] {
        // Use A/B testing to determine layout
        if abTesting.isInTreatment(for: "feed_layout_experiment") {
            return determineOptimalColumns()
        } else {
            // Fallback to user-selected layout
            return gridLayout.columns
        }
    }
    
    private func determineOptimalColumns() -> [GridItem] {
        switch (horizontalSizeClass, verticalSizeClass) {
        case (.compact, .regular):
            // iPhone portrait
            return GridLayout.singleColumn.columns
        case (.compact, .compact):
            // iPhone landscape
            return GridLayout.twoColumn.columns
        case (.regular, .regular):
            // iPad
            return UIDevice.current.userInterfaceIdiom == .pad
                ? GridLayout.threeColumn.columns
                : GridLayout.twoColumn.columns
        default:
            return GridLayout.adaptive.columns
        }
    }
    
    private var gridSpacing: CGFloat {
        horizontalSizeClass == .compact ? 12 : 16
    }
    
    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? 12 : 20
    }
    
    private var contentHorizontalMargin: CGFloat {
        horizontalSizeClass == .compact ? 0 : 20
    }
    
    // MARK: - Actions
    
    private func handlePostAppear(_ post: CachedFeedViewPost) {
        visibleItems.insert(post.id)
        
        // Prefetch images for better performance
        if let embed = post.feedViewPost.post.embed {
            Task.detached(priority: .background) {
                await ImageLoadingManager.shared.prefetchImages(for: embed)
            }
        }
        
        // Track metrics
        abTesting.trackEvent(
            ExperimentEvent(
                name: "post_viewed",
                metadata: [
                    "post_id": post.id,
                    "layout": String(describing: gridLayout)
                ]
            ),
            for: "grid_view_layout"
        )
    }
    
    private func handlePostDisappear(_ post: CachedFeedViewPost) {
        visibleItems.remove(post.id)
    }
    
    private func handlePostTap(_ post: CachedFeedViewPost) {
        selectedPost = post
        
        // Navigate to post detail
        Task { @MainActor in
            appState.navigationManager.navigate(to: .post(post.feedViewPost.post.uri))
        }
        
        // Track interaction
        abTesting.trackEvent(
            ExperimentEvent(name: "post_tapped"),
            for: "grid_view_layout"
        )
    }
    
    private func handleRefresh() async {
        await feedStateManager.refresh()
    }
    
    private func loadInitialDataIfNeeded() async {
        if feedStateManager.posts.isEmpty {
            await feedStateManager.loadInitialData()
        }
    }
}

// MARK: - Grid Feed Post Card

@available(iOS 18.0, *)
struct GridFeedPostCard: View {
    let post: CachedFeedViewPost
    let appState: AppState
    let isSelected: Bool
    
    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Author header
            HStack(spacing: 8) {
                AsyncImage(url: URL(string: post.feedViewPost.post.author.avatar?.uriString() ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.feedViewPost.post.author.displayName ?? post.feedViewPost.post.author.handle.description)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    Text("@\(post.feedViewPost.post.author.handle.description)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(relativeDateString(from: post.feedViewPost.post.indexedAt.iso8601String))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // Post content
            if case .knownType(let record) = post.feedViewPost.post.record,
               let feedPost = record as? AppBskyFeedPost,
               !feedPost.text.isEmpty {
                Text(feedPost.text)
                    .font(.callout)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            
            // Media preview
            if let embed = post.feedViewPost.post.embed {
                // Basic embed preview for grid view
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }
            
            // Interaction buttons
            HStack(spacing: 16) {
                InteractionButton(
                    iconName: "bubble.left",
                    count: post.feedViewPost.post.replyCount ?? 0,
                    isActive: false,
                    color: Color.blue,
                    isBig: false
                ) {}
                
                InteractionButton(
                    iconName: (post.feedViewPost.post.viewer?.repost != nil) ? "arrow.2.squarepath.fill" : "arrow.2.squarepath",
                    count: post.feedViewPost.post.repostCount ?? 0,
                    isActive: post.feedViewPost.post.viewer?.repost != nil,
                    color: Color.green,
                    isBig: false
                ) {}
                
                InteractionButton(
                    iconName: (post.feedViewPost.post.viewer?.like != nil) ? "heart.fill" : "heart",
                    count: post.feedViewPost.post.likeCount ?? 0,
                    isActive: post.feedViewPost.post.viewer?.like != nil,
                    color: Color.red,
                    isBig: false
                ) {}
                
                Spacer()
                
                Button {
                    // Share action
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 0.5)
        )
        // iOS 18: Mesh gradient overlay for selected state
        .overlay(
            meshGradientOverlay
                .opacity(isSelected ? 0.05 : 0)
        )
        .shadow(color: .black.opacity(0.05), radius: isHovered ? 8 : 4)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(colorScheme == .dark 
                ? Color(white: 0.1) 
                : Color(white: 0.98))
    }
    
    private var borderColor: Color {
        if isSelected {
            return .accentColor
        } else {
            return colorScheme == .dark 
                ? Color(white: 0.2) 
                : Color(white: 0.9)
        }
    }
    
    // iOS 18: Mesh gradient for visual enhancement
    @available(iOS 18.0, *)
    private var meshGradientOverlay: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                .blue.opacity(0.3), .purple.opacity(0.2), .pink.opacity(0.3),
                .purple.opacity(0.2), .clear, .orange.opacity(0.2),
                .pink.opacity(0.3), .orange.opacity(0.2), .yellow.opacity(0.3)
            ]
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Helper Functions
    
    /// Convert ISO8601 string to relative date string
    private func relativeDateString(from iso8601String: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = formatter.date(from: iso8601String) else {
            return "now"
        }
        
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else {
            let weeks = Int(interval / 604800)
            return "\(weeks)w"
        }
    }
}

// MARK: - Helper Views

struct GridLayoutPicker: View {
    @Binding var selection: iOS18GridFeedView.GridLayout
    
    var body: some View {
        Menu {
            Button {
                selection = .singleColumn
            } label: {
                Label("Single Column", systemImage: "rectangle.grid.1x2")
            }
            
            Button {
                selection = .twoColumn
            } label: {
                Label("Two Columns", systemImage: "rectangle.grid.2x2")
            }
            
            Button {
                selection = .threeColumn
            } label: {
                Label("Three Columns", systemImage: "rectangle.grid.3x2")
            }
            
            Button {
                selection = .adaptive
            } label: {
                Label("Adaptive", systemImage: "rectangle.grid.1x2.fill")
            }
        } label: {
            Image(systemName: "rectangle.grid.2x2")
        }
    }
}

struct NewPostsIndicatorBar: View {
    let count: Int
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                Text("\(count) new posts")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

