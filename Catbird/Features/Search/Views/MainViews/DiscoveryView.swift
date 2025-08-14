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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Trending topics
                if !viewModel.trendingTopics.isEmpty, 
                   let client = appState.atProtoClient,
                   appState.appSettings.showTrendingTopics {
                    TrendingTopicsSection(
                        topics: viewModel.trendingTopics,
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
                
                // Suggested profiles
                if !viewModel.suggestedProfiles.isEmpty {
                    SuggestedProfilesSection(
                        profiles: viewModel.suggestedProfiles,
                        onSelect: { profile in
                            path.append(NavigationDestination.profile(profile.did.didString()))
                        },
                        onRefresh: {
                            Task {
                                guard let client = appState.atProtoClient else { return }
                                await viewModel.refreshSuggestedProfiles(client: client)
                            }
                        }
                    )
                }
                
                // Spacer for bottom safe area
                Spacer(minLength: 32)
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            guard let client = appState.atProtoClient else { return }
            await viewModel.refreshDiscoveryContent(client: client)
        }
    }
}

/// Full screen trending topics view
struct AllTrendingTopicsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedCategory: String?
    @State private var showContributors: Bool = false
    @State private var viewMode: ViewMode = .list
    
    enum ViewMode {
        case list, grid
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
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
    
    private func categoryFilterButton(_ category: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(category?.capitalized ?? "All")
                .appFont(AppTextRole.subheadline.weight(selectedCategory == category ? .semibold : .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selectedCategory == category ?
                              categoryColor(for: category) :
                              Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
                )
                .foregroundColor(selectedCategory == category ?
                                .white :
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
            ForEach(filteredTopics.indices, id: \.self) { index in
                let topic = filteredTopics[index]
                topicCard(topic: topic)
                    .padding(.horizontal, 16)
            }
        }
    }
    
    private var topicsGridView: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 16) {
            ForEach(filteredTopics.indices, id: \.self) { index in
                let topic = filteredTopics[index]
                compactTopicCard(topic: topic)
            }
        }
        .padding(.horizontal, 16)
    }
    
    private func topicCard(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        Button {
            onSelect(topic.displayName ?? topic.topic)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                // Main topic info
                HStack(alignment: .top, spacing: 16) {
                    // Category icon
                    categoryIcon(for: topic.category)
                        .appFont(AppTextRole.title2)
                        .foregroundColor(categoryColor(for: topic.category))
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(categoryColor(for: topic.category).opacity(0.15))
                        )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        // Category and badges
                        HStack {
                            if let category = topic.category {
                                Text(formatCategory(category))
                                    .appFont(AppTextRole.caption.weight(.medium))
                                    .foregroundColor(categoryColor(for: topic.category))
                                    .textCase(.uppercase)
                            }
                            
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
                        Text(topic.displayName)
                            .appFont(AppTextRole.title2.weight(.semibold))
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        
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
                if showContributors && !topic.actors.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.dynamicSeparator(appState.themeManager, currentScheme: colorScheme)
                            .frame(height: 1)
                        
                        Text("Top Contributors")
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
            onSelect(topic.displayName ?? topic.topic)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    categoryIcon(for: topic.category)
                        .appFont(AppTextRole.headline)
                        .foregroundColor(categoryColor(for: topic.category))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(categoryColor(for: topic.category).opacity(0.15))
                        )
                    
                    Spacer()
                    
                    if let status = topic.status, status == "hot" {
                        trendingBadge(status: status)
                    }
                }
                
                Text(topic.displayName)
                    .appFont(AppTextRole.headline.weight(.semibold))
                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                
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
            .frame(height: 120)
            .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
            .cornerRadius(12)
            .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
    
    private func topicContributors(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(topic.actors.prefix(4), id: \.did) { actor in
                    contributorView(actor: actor)
                }
            }
            .padding(.horizontal, 2)
        }
    }
    
    private func contributorView(actor: AppBskyActorDefs.ProfileViewBasic) -> some View {
        Button {
            dismiss()
            appState.navigationManager.navigate(to: .profile(actor.did.didString()))
        } label: {
            HStack(spacing: 8) {
                AsyncProfileImage(url: actor.avatar?.url, size: 32)
                
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
    private func categoryIcon(for category: String?) -> some View {
        switch category {
        case "pop-culture":
            return Image(systemName: "music.note.tv")
        case "politics":
            return Image(systemName: "building.columns")
        case "sports":
            return Image(systemName: "figure.basketball")
        case "video-games":
            return Image(systemName: "gamecontroller")
        case "tech":
            return Image(systemName: "laptopcomputer")
        case "business":
            return Image(systemName: "chart.bar")
        case "science":
            return Image(systemName: "atom")
        default:
            return Image(systemName: "number")
        }
    }
    
    private func categoryColor(for category: String?) -> Color {
        switch category {
        case "pop-culture":
            return .purple
        case "politics":
            return .blue
        case "sports":
            return .orange
        case "video-games":
            return .green
        case "tech":
            return .cyan
        case "business":
            return .yellow
        case "science":
            return .mint
        default:
            return .gray
        }
    }
    
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
    
    private func formatCategory(_ category: String) -> String {
        let specialCases: [String: String] = [
            "pop-culture": "Entertainment",
            "video-games": "Video Games"
        ]
        
        if let specialCase = specialCases[category.lowercased()] {
            return specialCase
        }
        
        let words = category.components(separatedBy: "-")
        let capitalizedWords = words.map { $0.capitalized }
        return capitalizedWords.joined(separator: " ")
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
