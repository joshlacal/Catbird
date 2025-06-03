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
        ScrollView {
            LazyVStack(spacing: 16) {
                // Header
                headerView
                
                // Tab Selector
                tabSelectorView
                
                // Content based on selected tab
                switch selectedTab {
                case .personalized:
                    personalizedRecommendationsView
                case .trending:
                    trendingFeedsView
                case .interests:
                    interestBasedView
                }
            }
            .padding()
        }
        .refreshable {
            await refreshContent()
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
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discover Feeds")
                        .appFont(AppTextRole.title1)
                        .fontWeight(.bold)
                    
                    Text("Find feeds tailored to your interests")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showingInterestPicker = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.accentColor)
                }
                .accessibilityLabel("Edit interests")
            }
            
            // Interest tags preview
            if !userInterests.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(userInterests.prefix(5), id: \.self) { interest in
                            Text(interest)
                                .appFont(AppTextRole.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        
                        if userInterests.count > 5 {
                            Text("+\(userInterests.count - 5) more")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
    
    // MARK: - Tab Selector
    
    private var tabSelectorView: some View {
        HStack(spacing: 0) {
            ForEach(DiscoveryTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 14, weight: .medium))
                            Text(tab.rawValue)
                                .appFont(AppTextRole.subheadline)
                                .fontWeight(.medium)
                        }
                        
                        Rectangle()
                            .frame(height: 2)
                            .opacity(selectedTab == tab ? 1 : 0)
                    }
                }
                .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }
    
    // MARK: - Content Views
    
    private var personalizedRecommendationsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoadingRecommendations {
                loadingView
            } else if personalizedRecommendations.isEmpty {
                emptyRecommendationsView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(personalizedRecommendations.indices, id: \.self) { index in
                        let recommendation = personalizedRecommendations[index]
                        
                        RecommendationCard(
                            recommendation: recommendation,
                            onSubscribe: {
                                await subscribeTo(recommendation.feed)
                            }
                        )
                    }
                }
            }
        }
    }
    
    private var trendingFeedsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Trending Now")
                    .appFont(AppTextRole.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("Updated hourly")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            if isLoadingTrending {
                loadingView
            } else if trendingFeeds.isEmpty {
                emptyTrendingView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(trendingFeeds.indices, id: \.self) { index in
                        let recommendation = trendingFeeds[index]
                        
                        TrendingFeedCard(
                            recommendation: recommendation,
                            rank: index + 1,
                            onSubscribe: {
                                await subscribeTo(recommendation.feed)
                            }
                        )
                    }
                }
            }
        }
    }
    
    private var interestBasedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Based on Your Interests")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            if userInterests.isEmpty {
                noInterestsView
            } else {
                // Show feeds grouped by interests
                ForEach(userInterests.prefix(3), id: \.self) { interest in
                    InterestFeedSection(
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
    
    // MARK: - Helper Views
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 120)
                    .shimmering()
            }
        }
    }
    
    private var emptyRecommendationsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No recommendations yet")
                .appFont(AppTextRole.headline)
            
            Text("Add some interests to get personalized feed recommendations")
                .appFont(AppTextRole.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Add Interests") {
                showingInterestPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var emptyTrendingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No trending feeds")
                .appFont(AppTextRole.headline)
            
            Text("Check back later for trending feeds")
                .appFont(AppTextRole.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var noInterestsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tag")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No interests selected")
                .appFont(AppTextRole.headline)
            
            Text("Tell us what you're interested in to get better recommendations")
                .appFont(AppTextRole.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Choose Interests") {
                showingInterestPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

// MARK: - Supporting Views

struct RecommendationCard: View {
    let recommendation: SmartFeedRecommendationEngine.FeedRecommendation
    let onSubscribe: () async -> Void
    
    @State private var isSubscribing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Feed avatar
                AsyncImage(url: URL(string: recommendation.feed.avatar?.uriString() ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    feedPlaceholder
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.feed.displayName)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.semibold)
                    
                    Text("by @\(recommendation.feed.creator.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(recommendation.displayReason)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Button(action: {
                    Task {
                        isSubscribing = true
                        await onSubscribe()
                        isSubscribing = false
                    }
                }) {
                    if isSubscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Subscribe")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .disabled(isSubscribing)
            }
            
            if let description = recommendation.feed.description {
                Text(description)
                    .appFont(AppTextRole.body)
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var feedPlaceholder: some View {
        ZStack {
            Color.accentColor.opacity(0.6)
            Text(recommendation.feed.displayName.prefix(1).uppercased())
                .appFont(AppTextRole.headline)
                .foregroundColor(.white)
        }
    }
}

struct TrendingFeedCard: View {
    let recommendation: SmartFeedRecommendationEngine.FeedRecommendation
    let rank: Int
    let onSubscribe: () async -> Void
    
    @State private var isSubscribing = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Rank badge
            Text("#\(rank)")
                .appFont(AppTextRole.caption)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())
            
            RecommendationCard(
                recommendation: recommendation,
                onSubscribe: onSubscribe
            )
        }
    }
}

struct InterestFeedSection: View {
    let interest: String
    let recommendations: [SmartFeedRecommendationEngine.FeedRecommendation]
    let onSubscribe: (AppBskyFeedDefs.GeneratorView) async -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(interest.capitalized)
                    .appFont(AppTextRole.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("\(recommendations.count) feed\(recommendations.count == 1 ? "" : "s")")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            if recommendations.isEmpty {
                Text("No feeds found for this interest")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(recommendations.prefix(3).indices, id: \.self) { index in
                        let recommendation = recommendations[index]
                        
                        RecommendationCard(
                            recommendation: recommendation,
                            onSubscribe: {
                                await onSubscribe(recommendation.feed)
                            }
                        )
                    }
                }
            }
        }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
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
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

// Note: FlowLayout is defined in PostStatsView.swift