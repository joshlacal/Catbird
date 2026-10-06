//
//  DiscoveryView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Main discovery view shown when search is idle
struct DiscoveryView: View {
    var viewModel: RefinedSearchViewModel
    @Binding var path: NavigationPath
    @Binding var showAllTrendingTopics: Bool
    @Binding var showAllSavedSearches: Bool
    @Binding var showSuggestedProfiles: Bool
    @Binding var showAddFeedSheet: Bool
    let onQueryLoaded: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    @State private var showInterestPicker = false
    @State private var showInviteFriends = false
    @State private var showInviteScanner = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sectionLarge) {
                // SRCH-015: Saved Searches Section
                if !viewModel.savedSearches.isEmpty {
                    SavedSearchesSection(
                        savedSearches: viewModel.savedSearches,
                        onSelect: { savedSearch in
                            if let client = appState.atProtoClient {
                                viewModel.loadAndApplySavedSearch(
                                    savedSearch,
                                    client: client,
                                    onQueryLoaded: onQueryLoaded
                                )
                            }
                        },
                        onDelete: { savedSearch in
                            viewModel.deleteSavedSearch(savedSearch.id)
                        },
                        onShowAll: {
                            showAllSavedSearches = true
                        }
                    )
                }
                // Explore interests NUX card (G07)
                if viewModel.showExploreInterestsCard {
                    ExploreInterestsCard(
                        userInterests: viewModel.userInterests,
                        onEditInterests: {
                            showInterestPicker = true
                        },
                        onDismiss: {
                            Task {
                                await viewModel.dismissExploreInterestsCard()
                            }
                        }
                    )
                }
                // Trending topics (G06)
                if let client = appState.atProtoClient,
                   appState.appSettings.showTrendingTopics {
                    TrendingTopicsSection(
                        topics: viewModel.trendingTopics,
                        isLoading: viewModel.isTrendingTopicsLoading || !viewModel.hasLoadedTrendingTopics,
                        onSelect: { term in
                            viewModel.searchQuery = term
                            viewModel.commitSearch(client: client)
                        },
                        onSeeAll: {
                            showAllTrendingTopics = true
                        },
                        maxItems: 5
                    )
                }
                
                // Trending videos (G03)
                if appState.atProtoClient != nil,
                   appState.appSettings.showTrendingVideos {
                    TrendingVideosSection(
                        videos: viewModel.trendingVideos,
                        isLoading: viewModel.isTrendingVideosLoading,
                        onSelectPost: { post in
                            path.append(NavigationDestination.videoFeedStartingAt(post))
                        },
                        onSeeAll: {
                            path.append(NavigationDestination.videoFeed)
                        }
                    )
                }
                
                // Suggested Accounts with Interest Tabs (G04)
                if let client = appState.atProtoClient {
                    SuggestedProfilesSection(
                        profiles: viewModel.suggestedProfiles,
                        selectedCategory: viewModel.selectedSuggestedCategory,
                        userInterests: viewModel.userInterests,
                        isLoading: viewModel.isSuggestedProfilesLoading,
                        onSelectCategory: { category in
                            Task {
                                await viewModel.fetchSuggestedUsers(category: category, client: client)
                            }
                        },
                        onSelectProfile: { profile in
                            path.append(NavigationDestination.profile(profile.did.didString()))
                        },
                        onRefresh: {
                            Task {
                                await viewModel.refreshSuggestedProfiles(client: client)
                            }
                        }
                    )
                }
                // SRCH-007: Quick Actions Section
                quickActionsSection
                
            }
            .mainContentFrame()
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.section)
        }
        .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            guard let client = appState.atProtoClient else { return }
            await viewModel.refreshDiscoveryContent(client: client)
        }
        .sheet(isPresented: $showInterestPicker) {
            InterestPickerSheet(
                currentInterests: viewModel.userInterests,
                onSave: { updatedInterests in
                    await viewModel.updateInterests(updatedInterests)
                }
            )
        }
        .sheet(isPresented: $showInviteFriends) {
            InviteFriendsView()
        }
        .sheet(isPresented: $showInviteScanner) {
            InviteScannerView(onScannedProfile: { handleOrDID in
                path.append(NavigationDestination.profile(handleOrDID))
            })
        }
    }
    
    private var quickActionsSection: some View {
        DiscoveryToolsSection(
            onFindFriends: { showSuggestedProfiles = true },
            onInviteFriends: { showInviteFriends = true },
            onScanQR: { showInviteScanner = true },
            onExploreFeeds: { showAddFeedSheet = true },
            onOpenTopics: { showAllTrendingTopics = true },
            showsTopics: appState.appSettings.showTrendingTopics
        )
    }
}

/// The tools are navigation shortcuts rather than search queries.
struct DiscoveryToolsSection: View {
    let onFindFriends: () -> Void
    let onInviteFriends: () -> Void
    let onScanQR: () -> Void
    let onExploreFeeds: () -> Void
    let onOpenTopics: () -> Void
    var showsTopics: Bool = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
            DiscoverySectionHeader("Explore More", subtitle: "People, feeds, and ways to connect.") {}
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 250), spacing: DesignTokens.Spacing.base)],
                alignment: .leading,
                spacing: 0
            ) {
                tool("Find Friends", detail: "Discover people to follow", icon: "person.2", action: onFindFriends)
                tool("Invite Friends", detail: "Share your invite card", icon: "person.badge.plus", action: onInviteFriends)
                tool("Scan QR", detail: "Open a profile from its code", icon: "qrcode.viewfinder", action: onScanQR)
                tool("Custom Feeds", detail: "Explore curated feeds", icon: "rectangle.on.rectangle.angled", action: onExploreFeeds)
                if showsTopics {
                    tool("All Trending Topics", detail: "Browse the latest conversations", icon: "chart.line.uptrend.xyaxis", action: onOpenTopics)
                }
            }
        }
    }

    private func tool(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.base) {
                Image(systemName: icon)
                    .appFont(AppTextRole.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(title)
                        .appFont(size: Typography.Size.body, weight: .medium, relativeTo: .body)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, DesignTokens.Spacing.base)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) { Divider() }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Full screen trending topics view
struct AllTrendingTopicsView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedCategory: String?
    @State private var showContributors: Bool = false
    @State private var viewMode: ViewMode = .list
    
    enum ViewMode {
        case list, grid
}

// Local summary line helper to avoid cross-file visibility constraints
private struct InlineTopicSummaryLine: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let topic: AppBskyUnspeccedDefs.TrendView
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let description = TrendingTopicPresentation.description(for: topic) {
                Text(description)
                    .appFont(AppTextRole.footnote)
                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }
}

    let topics: [AppBskyUnspeccedDefs.TrendView]
    let onSelect: (String) -> Void
    
    // Get unique categories from topics
    private var categories: [String] {
        var uniqueCategories = Set<String>()
        topics.forEach { topic in
            if let category = topic.category {
                uniqueCategories.insert(category)
            }
        }
        return Array(uniqueCategories).sorted()
    }
    
    // Filter topics by selected category
    private var filteredTopics: [AppBskyUnspeccedDefs.TrendView] {
        if let selectedCategory = selectedCategory {
            return topics.filter { $0.category == selectedCategory }
        } else {
            return topics
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Categories filter
                    categoriesFilterView
                        .padding(.horizontal, 16)
                    
                    if filteredTopics.isEmpty {
                        emptyStateView
                    } else {
                        if viewMode == .list {
                            topicsListView
                        } else {
                            topicsGridView
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
            .navigationTitle("Trending Topics")
            #if os(iOS)
            .toolbarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { viewMode = .list }) {
                            Label("List View", systemImage: "list.bullet")
                        }
                        Button(action: { viewMode = .grid }) {
                            Label("Grid View", systemImage: "square.grid.2x2")
                        }
                        
                        Divider()
                        
                        Button(action: { showContributors.toggle() }) {
                            Label(showContributors ? "Hide Contributors" : "Show Contributors", 
                                  systemImage: showContributors ? "eye.slash" : "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .task(id: appState.topicPreviewPrefetchIdentity(links: filteredTopics.map(\.link))) {
            appState.prefetchTopicPreviews(trends: filteredTopics, owner: .search)
        }
        .onDisappear { appState.cancelTopicPreviewPrefetch(owner: .search) }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No topics found")
                .appFont(AppTextRole.headline)
                .foregroundColor(.primary)
            
            Text("Try adjusting your filters or check back later")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 32)
    }
    
    // Categories horizontal scroll view
    private var categoriesFilterView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                categoryFilterButton(nil)
                
                ForEach(categories, id: \.self) { category in
                    categoryFilterButton(category)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    /// Yellow, mint and cyan fills are too light for white text.
    private static func usesDarkChipText(_ category: String?) -> Bool {
        ["business", "economy", "finance", "science", "tech", "technology", "weather"].contains(category?.lowercased() ?? "")
    }
    
    private func categoryFilterButton(_ category: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(category.map { TrendingTopicCategoryStyle.name(for: $0) } ?? "All")
                .appFont(AppTextRole.subheadline.weight(selectedCategory == category ? .semibold : .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selectedCategory == category ?
                              TrendingTopicCategoryStyle.color(for: category) :
                              Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
                )
                .foregroundColor(selectedCategory == category ?
                                (Self.usesDarkChipText(category) ? .black : .white) :
                                Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                .overlay(
                    Capsule()
                        .stroke(selectedCategory == category ? 
                                Color.clear : 
                                Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), 
                                lineWidth: 1)
                )
        }
    }
    
    private var topicsListView: some View {
        LazyVStack(spacing: 16) {
            ForEach(filteredTopics, id: \.link) { topic in
                topicCard(topic: topic)
                    .padding(.horizontal, 16)
            }
        }
    }
    
    private var topicsGridView: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 180), spacing: 12)
        ], spacing: 16) {
            ForEach(filteredTopics, id: \.link) { topic in
                compactTopicCard(topic: topic)
            }
        }
        .padding(.horizontal, 16)
    }
    
    private func topicCard(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        Button {
            if let url = URL(string: topic.link, relativeTo: URL(string: "https://bsky.app"))?.absoluteURL {
                onSelect(url.absoluteString)
            }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                // Main topic info
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Category and badges
                        HStack {
                            Spacer()
                            
                            HStack(spacing: 6) {
                                if let status = topic.status, status == "hot" {
                                    trendingBadge(status: status)
                                }
                                
                                if isWithinLastThirtyMinutes(date: topic.startedAt.date) {
                                    newBadge()
                                }
                            }
                        }
                        
                        // Topic name
                        TrendingTopicHeading(title: topic.displayName, category: topic.category)
                        TrendingTopicArtwork(link: topic.link, actors: topic.actors)
                        // Topic summary
                        InlineTopicSummaryLine(topic: topic)
                        
                        // Stats row
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatPostCount(topic.postCount))
                                    .appFont(AppTextRole.subheadline.weight(.semibold))
                                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                                Text("Posts")
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatTimeSince(topic.startedAt.date))
                                    .appFont(AppTextRole.subheadline.weight(.semibold))
                                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                                Text("Trending")
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            }
                            
                            Spacer()
                            
                            Image(systemName: "arrow.up.right")
                                .appFont(AppTextRole.subheadline)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                
                // Contributors section (conditionally shown)
                if showContributors && !appState.topicPreview(for: topic.link).contributorProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.dynamicSeparator(appState.themeManager, currentScheme: colorScheme)
                            .frame(height: 1)
                        
                        Text("Topic Participants")
                            .appFont(AppTextRole.subheadline.weight(.medium))
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        
                        topicContributors(topic: topic)
                    }
                }
            }
            .padding(20)
            .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
            .cornerRadius(16)
            .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
    
    private func compactTopicCard(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        Button {
            if let url = URL(string: topic.link, relativeTo: URL(string: "https://bsky.app"))?.absoluteURL {
                onSelect(url.absoluteString)
            }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                TrendingTopicHeading(title: topic.displayName, category: topic.category, size: 20)
                if let status = topic.status, status == "hot" {
                    trendingBadge(status: status)
                }
                TrendingTopicArtwork(link: topic.link, actors: topic.actors)
                InlineTopicSummaryLine(topic: topic)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatPostCount(topic.postCount))
                        .appFont(AppTextRole.subheadline.weight(.medium))
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                    
                    Text(formatTimeSince(topic.startedAt.date))
                        .appFont(AppTextRole.caption)
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                }
                
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 120)
            .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
            .cornerRadius(12)
            .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
    
    private func topicContributors(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(appState.topicPreview(for: topic.link).contributorProfiles, id: \.did) { actor in
                    contributorView(actor: actor)
                }
            }
            .padding(.horizontal, 2)
        }
    }
    
    private func contributorView(actor: AppBskyActorDefs.ProfileViewBasic) -> some View {
        Button {
            dismiss()
            sceneContext.navigationManager.navigate(to: .profile(actor.did.didString()))
        } label: {
            HStack(spacing: 8) {
                AsyncProfileImage(url: actor.finalAvatarURL(), size: 32, labels: actor.labels)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(actor.displayName ?? "@\(actor.handle)")
                        .appFont(AppTextRole.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                    
                    Text("@\(actor.handle)")
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        .lineLimit(1)
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
            .cornerRadius(8)
        }
    }
    
    // Helper functions
    private func trendingBadge(status: String) -> some View {
        Text(status.uppercased())
            .appFont(size: 10)
            .foregroundColor(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                Capsule()
                    .fill(Color.red)
            )
    }
    
    private func newBadge() -> some View {
        Text("NEW")
            .appFont(size: 10)
            .foregroundColor(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                Capsule()
                    .fill(Color.green)
            )
    }
    
    private func isWithinLastThirtyMinutes(date: Date) -> Bool {
        let now = Date()
        let thirtyMinutesAgo = now.addingTimeInterval(-30 * 60)
        return date >= thirtyMinutesAgo
    }
    
    private func formatPostCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let formatted = Double(count) / 1_000_000.0
            return String(format: "%.1fM", formatted)
        } else if count >= 1_000 {
            let formatted = Double(count) / 1_000.0
            return String(format: "%.1fK", formatted)
        } else {
            return "\(count)"
        }
    }
    
    private func formatTimeSince(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.hour, .minute], from: date, to: now)
        
        if let hours = components.hour, hours > 0 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if let minutes = components.minute, minutes > 0 {
            return minutes == 1 ? "1 min ago" : "\(minutes) mins ago"
        } else {
            return "just now"
        }
    }
}


#Preview("DiscoveryView") {
  AsyncPreviewContent { appState in
    NavigationStack {
      DiscoveryView(
        viewModel: RefinedSearchViewModel(appState: appState),
        path: .constant(NavigationPath()),
        showAllTrendingTopics: .constant(false),
        showAllSavedSearches: .constant(false),
        showSuggestedProfiles: .constant(false),
        showAddFeedSheet: .constant(false),
        onQueryLoaded: { _ in }
      )
    }
  }
}
