//
//  SmartFeedDiscoveryView.swift
//  Catbird
//
//  Created on 6/2/25.
//

import SwiftUI
import Petrel
import OSLog

/// Enhanced feed discovery with personalized recommendations and trending feeds
struct SmartFeedDiscoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var recommendationEngine: SmartFeedRecommendationEngine?
    @State private var socialAnalyzer: SocialConnectionAnalyzer?
    @State private var previewService: FeedPreviewService?
    
    // State for recommendations
    @State private var personalizedRecommendations: [SmartFeedRecommendationEngine.FeedRecommendation] = []
    @State private var trendingFeeds: [SmartFeedRecommendationEngine.FeedRecommendation] = []
    @State private var userInterests: [String] = []
    
    // Loading states
    @State private var isLoadingRecommendations = false
    @State private var isLoadingTrending = false
    @State private var hasLoaded = false
    
    // UI state
    @State private var selectedTab: DiscoveryTab = .personalized
    @State private var showingInterestPicker = false
    @State private var animateTabChange = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "SmartFeedDiscoveryView")
    
    enum DiscoveryTab: String, CaseIterable {
        case personalized = "For You"
        case trending = "Trending"
        case interests = "Interests"
        
        var systemImage: String {
            switch self {
            case .personalized: return "sparkles"
            case .trending: return "chart.line.uptrend.xyaxis"
            case .interests: return "tag"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(platformColor: .platformSystemBackground),
                        Color(platformColor: .platformSecondarySystemBackground).opacity(0.3)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                ScrollView {
                    LazyVStack(spacing: 20) {
                        // Enhanced Header
                        enhancedHeaderView
                        
                        // Enhanced Tab Selector
                        enhancedTabSelectorView
                        
                        // Content based on selected tab with animation
                        Group {
                            switch selectedTab {
                            case .personalized:
                                enhancedPersonalizedRecommendationsView
                            case .trending:
                                enhancedTrendingFeedsView
                            case .interests:
                                enhancedInterestBasedView
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: selectedTab)
                        
                        // Bottom spacing
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .refreshable {
                    await refreshContent()
                }
            }
            .navigationTitle("Discover Feeds")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings") {
                        showingInterestPicker = true
                    }
                    .foregroundColor(.accentColor)
                }
            }
        }
        .task {
            await setupServices()
            if !hasLoaded {
                await loadInitialContent()
                hasLoaded = true
            }
        }
        .sheet(isPresented: $showingInterestPicker) {
            InterestPickerSheet(
                currentInterests: userInterests,
                onSave: { interests in
                    await updateUserInterests(interests)
                }
            )
        }
    }
    
    // MARK: - Enhanced Header View
    
    private var enhancedHeaderView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Main header info
            VStack(alignment: .leading, spacing: 8) {
                Text("Find Your Perfect Feeds")
                    .appFont(AppTextRole.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text("Discover personalized content based on your interests and social connections")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            
            // Interest tags preview with enhanced styling
            if !userInterests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Interests")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(userInterests.prefix(5), id: \.self) { interest in
                                Text(interest)
                                    .appFont(AppTextRole.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.1)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                                    )
                            }
                            
                            if userInterests.count > 5 {
                                Button(action: { showingInterestPicker = true }) {
                                    Text("+\(userInterests.count - 5) more")
                                        .appFont(AppTextRole.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(platformColor: .platformTertiarySystemBackground))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            } else {
                // Show prompt to add interests
                Button(action: { showingInterestPicker = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                        Text("Add your interests")
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(platformColor: .platformSystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Enhanced Tab Selector
    
    private var enhancedTabSelectorView: some View {
        HStack(spacing: 4) {
            ForEach(DiscoveryTab.allCases, id: \.self) { tab in
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                }) {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 14, weight: .medium))
                            Text(tab.rawValue)
                                .appFont(AppTextRole.subheadline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(selectedTab == tab ? .white : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Group {
                                if selectedTab == tab {
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(platformColor: .platformSecondarySystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
    }
    
    // MARK: - Enhanced Content Views
    
    private var enhancedPersonalizedRecommendationsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("For You")
                        .appFont(AppTextRole.title2)
                        .fontWeight(.bold)
                    
                    Text("Curated based on your activity and interests")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            if isLoadingRecommendations {
                enhancedLoadingView
            } else if personalizedRecommendations.isEmpty {
                enhancedEmptyRecommendationsView
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(personalizedRecommendations.indices, id: \.self) { index in
                        let recommendation = personalizedRecommendations[index]
                        
                        EnhancedRecommendationCard(
                            recommendation: recommendation,
                            rank: index + 1,
                            showRank: false,
                            onSubscribe: {
                                await subscribeTo(recommendation.feed)
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .scale)
                        ))
                    }
                }
            }
        }
    }
    
    private var enhancedTrendingFeedsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Enhanced section header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                        Text("Trending Now")
                            .appFont(AppTextRole.title2)
                            .fontWeight(.bold)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Live")
                            .appFont(AppTextRole.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }
                
                Text("Popular feeds across the platform right now")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            if isLoadingTrending {
                enhancedLoadingView
            } else if trendingFeeds.isEmpty {
                enhancedEmptyTrendingView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(trendingFeeds.indices, id: \.self) { index in
                        let recommendation = trendingFeeds[index]
                        
                        EnhancedRecommendationCard(
                            recommendation: recommendation,
                            rank: index + 1,
                            showRank: true,
                            onSubscribe: {
                                await subscribeTo(recommendation.feed)
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .scale)
                        ))
                    }
                }
            }
        }
    }
    
    private var enhancedInterestBasedView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Enhanced section header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.purple)
                        Text("Your Interests")
                            .appFont(AppTextRole.title2)
                            .fontWeight(.bold)
                    }
                    
                    Spacer()
                    
                    Button("Edit") {
                        showingInterestPicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Text("Feeds matching your selected interests")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            if userInterests.isEmpty {
                enhancedNoInterestsView
            } else {
                // Enhanced interest sections
                LazyVStack(spacing: 20) {
                    ForEach(userInterests.prefix(3), id: \.self) { interest in
                        EnhancedInterestFeedSection(
                            interest: interest,
                            recommendations: personalizedRecommendations.filter { recommendation in
                                recommendation.reasons.contains { reason in
                                    if case .interestMatch(let tags) = reason {
                                        return tags.contains(interest)
                                    }
                                    return false
                                }
                            },
                            onSubscribe: { feed in
                                await subscribeTo(feed)
                            }
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Enhanced Helper Views
    
    private var enhancedLoadingView: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 0) {
                    // Skeleton card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            // Skeleton avatar
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 48, height: 48)
                                .shimmering()
                            
                            VStack(alignment: .leading, spacing: 6) {
                                // Skeleton title
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 150, height: 16)
                                    .shimmering()
                                
                                // Skeleton subtitle
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 100, height: 12)
                                    .shimmering()
                            }
                            
                            Spacer()
                            
                            // Skeleton button
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 80, height: 32)
                                .shimmering()
                        }
                        
                        // Skeleton description
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 12)
                                .shimmering()
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 200, height: 12)
                                .shimmering()
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(platformColor: .platformSystemBackground))
                            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                    )
                }
            }
        }
    }
    
    private var enhancedEmptyRecommendationsView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.1), Color.accentColor.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            
            VStack(spacing: 8) {
                Text("No recommendations yet")
                    .appFont(AppTextRole.title3)
                    .fontWeight(.semibold)
                
                Text("Add some interests to get personalized feed recommendations based on your preferences")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            Button("Add Your Interests") {
                showingInterestPicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(platformColor: .platformSystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    private var enhancedEmptyTrendingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.1), Color.orange.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.orange)
            }
            
            VStack(spacing: 8) {
                Text("No trending feeds right now")
                    .appFont(AppTextRole.title3)
                    .fontWeight(.semibold)
                
                Text("Trending feeds update throughout the day. Check back soon for the latest popular content")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            Button("Refresh") {
                Task {
                    await loadTrendingFeeds()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(platformColor: .platformSystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    private var enhancedNoInterestsView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.1), Color.purple.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "tag.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.purple)
            }
            
            VStack(spacing: 8) {
                Text("No interests selected")
                    .appFont(AppTextRole.title3)
                    .fontWeight(.semibold)
                
                Text("Tell us what topics you're passionate about to discover feeds you'll love")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            Button("Choose Your Interests") {
                showingInterestPicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(platformColor: .platformSystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Actions
    
    private func setupServices() async {
        if previewService == nil {
            previewService = FeedPreviewService(appState: appState)
        }
        
        if let previewService = previewService, recommendationEngine == nil {
            recommendationEngine = SmartFeedRecommendationEngine(
                appState: appState,
                previewService: previewService
            )
        }
        
        if socialAnalyzer == nil {
            socialAnalyzer = SocialConnectionAnalyzer(appState: appState)
        }
        
        // Load user interests
        await loadUserInterests()
    }
    
    private func loadInitialContent() async {
        async let personalizedTask: Void = loadPersonalizedRecommendations()
        async let trendingTask: Void = loadTrendingFeeds()
        
        await personalizedTask
        await trendingTask
    }
    
    private func refreshContent() async {
        await loadInitialContent()
    }
    
    private func loadPersonalizedRecommendations() async {
        guard let engine = recommendationEngine else { return }
        
        isLoadingRecommendations = true
        
        do {
            let recommendations = try await engine.getRecommendations(limit: 10, forceRefresh: true)
            await MainActor.run {
                personalizedRecommendations = recommendations
                isLoadingRecommendations = false
            }
        } catch {
            logger.error("Failed to load personalized recommendations: \(error)")
            await MainActor.run {
                isLoadingRecommendations = false
            }
        }
    }
    
    private func loadTrendingFeeds() async {
        guard let engine = recommendationEngine else { return }
        
        isLoadingTrending = true
        
        do {
            let trending = try await engine.getTrendingFeeds(interests: userInterests)
            await MainActor.run {
                trendingFeeds = trending
                isLoadingTrending = false
            }
        } catch {
            logger.error("Failed to load trending feeds: \(error)")
            await MainActor.run {
                isLoadingTrending = false
            }
        }
    }
    
    private func loadUserInterests() async {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            await MainActor.run {
                userInterests = preferences.interests
            }
        } catch {
            logger.error("Failed to load user interests: \(error)")
        }
    }
    
    private func updateUserInterests(_ interests: [String]) async {
        do {
            try await appState.preferencesManager.updateInterests(interests)
            await MainActor.run {
                userInterests = interests
            }
            // Refresh recommendations with new interests
            await loadPersonalizedRecommendations()
            await loadTrendingFeeds()
        } catch {
            logger.error("Failed to update user interests: \(error)")
        }
    }
    
    private func subscribeTo(_ feed: AppBskyFeedDefs.GeneratorView) async {
        do {
            let feedURI = feed.uri.uriString()
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Add to saved feeds
            if !preferences.savedFeeds.contains(feedURI) {
                var updatedSaved = preferences.savedFeeds
                updatedSaved.append(feedURI)
                try await appState.preferencesManager.setSavedFeeds(updatedSaved)
                
                logger.info("Subscribed to feed: \(feed.displayName)")
            }
        } catch {
            logger.error("Failed to subscribe to feed: \(error)")
        }
    }
}

// MARK: - Enhanced Supporting Views

struct EnhancedRecommendationCard: View {
    let recommendation: SmartFeedRecommendationEngine.FeedRecommendation
    let rank: Int
    let showRank: Bool
    let onSubscribe: () async -> Void
    
    @State private var isSubscribing = false
    @State private var showingFullFeed = false
    
    var body: some View {
        cardView
            .sheet(isPresented: $showingFullFeed) {
                feedPreviewSheet
            }
    }
    
    private var cardView: some View {
        mainContentView
            .padding(20)
            .background(cardBackground)
            .overlay(cardBorder)
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(platformColor: .platformSystemBackground))
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
    }
    
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 20)
            .stroke(Color(platformColor: PlatformColor.platformSeparator).opacity(0.1), lineWidth: 0.5)
    }
    
    private var feedPreviewSheet: some View {
        NavigationStack {
            FeedCollectionView.create(
                for: .feed(recommendation.feed.uri),
                appState: AppState.shared,
                navigationPath: .constant(NavigationPath())
            )
            .navigationTitle(recommendation.feed.displayName)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showingFullFeed = false
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("Subscribe") {
                        Task {
                            await onSubscribe()
                            showingFullFeed = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
    @ViewBuilder
    private var mainContentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSectionView
            
            // Enhanced description
            if let description = recommendation.feed.description, !description.isEmpty {
                Text(description)
                    .appFont(AppTextRole.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            
            // Stats row
            if let likeCount = recommendation.feed.likeCount {
                statsRowView(likeCount: likeCount)
            }
        }
    }
    
    private var headerSectionView: some View {
        HStack(alignment: .top, spacing: 16) {
            // Rank badge (for trending)
            if showRank {
                rankBadgeView
            }
            
            // Enhanced feed avatar
            feedAvatarView
            
            feedInfoView
            
            Spacer()
            
            // Action buttons
            actionButtonsView
        }
    }
    
    private var rankBadgeView: some View {
        ZStack {
            Circle()
                .fill(rankGradient)
                .frame(width: 32, height: 32)
            
            Text("\(rank)")
                .appFont(AppTextRole.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
    }
    
    private var feedInfoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recommendation.feed.displayName)
                .appFont(AppTextRole.headline)
                .fontWeight(.bold)
                .lineLimit(2)
            
            Text("by @\(recommendation.feed.creator.handle)")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
            
            // Enhanced reason badge
            reasonBadgeView
        }
    }
    
    private func statsRowView(likeCount: Int) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                Text(formatCount(likeCount))
            }
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            
            Spacer()
            
            // Quality indicator
            if likeCount > 10000 {
                Text("Top Rated")
                    .appFont(AppTextRole.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .clipShape(Capsule())
            }
        }
    }
    
    private var rankGradient: LinearGradient {
        switch rank {
        case 1:
            return LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case 2:
            return LinearGradient(colors: [.gray, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        case 3:
            return LinearGradient(colors: [.orange, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    private var enhancedFeedPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.8),
                    Color.accentColor.opacity(0.6),
                    Color.accentColor.opacity(0.4)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(recommendation.feed.displayName.prefix(1).uppercased())
                .appFont(AppTextRole.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        }
    }
    
    private var feedAvatarView: some View {
        AsyncImage(url: URL(string: recommendation.feed.avatar?.uriString() ?? "")) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            enhancedFeedPlaceholder
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(platformColor: PlatformColor.platformSeparator).opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var reasonBadgeView: some View {
        Text(recommendation.displayReason)
            .appFont(AppTextRole.caption2)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
    
    private var actionButtonsView: some View {
        VStack(spacing: 8) {
            Button(action: {
                Task {
                    isSubscribing = true
                    await onSubscribe()
                    isSubscribing = false
                }
            }) {
                HStack(spacing: 4) {
                    if isSubscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Subscribe")
                            .appFont(AppTextRole.caption)
                            .fontWeight(.semibold)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
            }
            .disabled(isSubscribing)
            .buttonStyle(.plain)
            
            Button("Preview") {
                showingFullFeed = true
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.accentColor)
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }
}

// TrendingFeedCard is now integrated into EnhancedRecommendationCard with showRank parameter

struct EnhancedInterestFeedSection: View {
    let interest: String
    let recommendations: [SmartFeedRecommendationEngine.FeedRecommendation]
    let onSubscribe: (AppBskyFeedDefs.GeneratorView) async -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Enhanced section header
            HStack {
                HStack(spacing: 8) {
                    Text("#")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    
                    Text(interest.capitalized)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                Text("\(recommendations.count) feed\(recommendations.count == 1 ? "" : "s")")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(platformColor: .platformTertiarySystemBackground))
                    .clipShape(Capsule())
            }
            
            if recommendations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    
                    Text("No feeds found for \(interest.lowercased())")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(platformColor: .platformSecondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(platformColor: PlatformColor.platformSeparator).opacity(0.1), lineWidth: 0.5)
                        )
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(recommendations.prefix(3).indices, id: \.self) { index in
                        let recommendation = recommendations[index]
                        
                        EnhancedRecommendationCard(
                            recommendation: recommendation,
                            rank: index + 1,
                            showRank: false,
                            onSubscribe: {
                                await onSubscribe(recommendation.feed)
                            }
                        )
                    }
                    
                    if recommendations.count > 3 {
                        Button("View \(recommendations.count - 3) more") {
                            // Could expand or show more in sheet
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(platformColor: .platformSystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
}

// MARK: - Interest Picker Sheet

struct InterestPickerSheet: View {
    let currentInterests: [String]
    let onSave: ([String]) async -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedInterests: Set<String>
    @State private var isSaving = false
    
    // Common interest tags
    private let availableInterests = [
        "Technology", "Science", "Art", "Music", "Sports", "Politics",
        "Photography", "Travel", "Food", "Books", "Movies", "Gaming",
        "Fashion", "Health", "Fitness", "Business", "Education",
        "Environment", "News", "Comedy", "Design", "Programming"
    ].sorted()
    
    init(currentInterests: [String], onSave: @escaping ([String]) async -> Void) {
        self.currentInterests = currentInterests
        self.onSave = onSave
        self._selectedInterests = State(initialValue: Set(currentInterests))
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Select topics you're interested in to get better feed recommendations")
                        .appFont(AppTextRole.body)
                        .foregroundColor(.secondary)
                    
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Array(availableInterests), id: \.self) { interest in
                            InterestTag(
                                interest: interest,
                                isSelected: selectedInterests.contains(interest),
                                onTap: {
                                    if selectedInterests.contains(interest) {
                                        selectedInterests.remove(interest)
                                    } else {
                                        selectedInterests.insert(interest)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Your Interests")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await onSave(Array(selectedInterests))
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

struct InterestTag: View {
    let interest: String
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Text(interest)
                .appFont(AppTextRole.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(platformColor: .platformSecondarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

// Note: FlowLayout is defined in PostStatsView.swift

// MARK: - Preview

#Preview {
    NavigationStack {
        SmartFeedDiscoveryView()
            .environment(AppState.shared)
    }
}
