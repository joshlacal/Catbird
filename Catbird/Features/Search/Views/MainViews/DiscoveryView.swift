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
            VStack(spacing: 24) {
                // Recent profile searches
                
                // Trending topics
                if !viewModel.trendingTopics.isEmpty, let client = appState.atProtoClient {
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
                
//                 Tagged suggestions
//                if !viewModel.taggedSuggestions.isEmpty {
//                    TaggedSuggestionsSection(
//                        suggestions: viewModel.taggedSuggestions,
//                        onSelectProfile: { did in
//                            path.append(NavigationDestination.profile(did))
//                        },
//                        onRefresh: {
//                            Task {
//                                guard let client = appState.atProtoClient else { return }
//                                await viewModel.fetchTaggedSuggestions(client: client)
//                            }
//                        }
//                    )
//                }
                Spacer(minLength: 50)
            }
            .padding(.vertical)
        }
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
    @State private var selectedCategory: String?
    @State private var showContributors: Bool = true
    
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
                VStack(spacing: 16) {
                    // Categories filter
                    categoriesFilterView
                        .padding(.horizontal)
                    
                    if filteredTopics.isEmpty {
                        Text("No topics found")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        topicsListView
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Trending Topics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showContributors ? "Hide Contributors" : "Show Contributors") {
                        showContributors.toggle()
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // Categories horizontal scroll view
    private var categoriesFilterView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryFilterButton(nil)
                
                ForEach(categories, id: \.self) { category in
                    categoryFilterButton(category)
                }
            }
        }
    }
    
    private func categoryFilterButton(_ category: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(category?.capitalized ?? "All")
                .font(.footnote.weight(selectedCategory == category ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(selectedCategory == category ?
                              categoryColor(for: category).opacity(0.2) :
                              Color(.systemGray6))
                )
                .foregroundColor(selectedCategory == category ?
                                categoryColor(for: category) :
                                Color(.label))
        }
    }
    
    private var topicsListView: some View {
        LazyVStack(spacing: 16) {
            ForEach(filteredTopics.indices, id: \.self) { index in
                let topic = filteredTopics[index]
                topicCard(topic: topic)
                    .padding(.horizontal)
            }
        }
    }
    
    private func topicCard(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Topic header
            topicHeader(topic: topic)
            
            Divider()
                .padding(.horizontal)
                .padding(.vertical, 8)
            
            // Topic details
            topicDetails(topic: topic)
            
            // Contributors section (conditionally shown)
            if showContributors && !topic.actors.isEmpty {
                Divider()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                
                topicContributors(topic: topic)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
    }
    
    private func topicHeader(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        HStack(alignment: .top, spacing: 12) {
            categoryIcon(for: topic.category)
                .font(.title2)
                .foregroundColor(categoryColor(for: topic.category))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(categoryColor(for: topic.category).opacity(0.2))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack {
                    if let category = topic.category {
                        Text(category.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Add badges in a container
                    HStack(spacing: 4) {
                        if let status = topic.status, status == "hot" {
                            trendingBadge(status: status)
                        }
                        
                        if isWithinLastThirtyMinutes(date: topic.startedAt.date) {
                            newBadge()
                        }
                    }
                }
            }
            
            Spacer()
            
            Button {
                onSelect(topic.displayName ?? topic.topic)
                dismiss()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundColor(.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }
        }
        .padding()
    }
    
    private func topicDetails(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                // Post count
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatPostCount(topic.postCount))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Total Posts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                    .frame(height: 24)
                
                // Time since started trending
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatTimeSince(topic.startedAt.date))
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Trending Since")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                
                Spacer()
                
                // Visit link button
                Button {
                    if let url = URL(string: "https://bsky.app\(topic.link)") {
                        _ = appState.urlHandler.handle(url, tabIndex: 1)
                        dismiss()
                    }
                } label: {
                    Text("Visit Feed")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            Capsule()
                                .fill(Color.accentColor)
                        )
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func topicContributors(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Contributors")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(topic.actors.prefix(5), id: \.did) { actor in
                        contributorView(actor: actor)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }
    
    private func contributorView(actor: AppBskyActorDefs.ProfileViewBasic) -> some View {
        Button {
            // Navigate to profile
            dismiss()
            appState.navigationManager.navigate(to: .profile(actor.did.didString()))
        } label: {
            VStack(alignment: .center, spacing: 4) {
                AsyncProfileImage(url: actor.avatar?.url, size: 48)
//                    .overlay(
//                        Circle()
//                            .stroke(Color.accentColor, lineWidth: actor.verification?.verifiedStatus == "valid" ? 2 : 0)
//                    )
                
                VStack(spacing: 0) {
                    Text(actor.displayName ?? "@\(actor.handle)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.primary)
                    
                    Text("@\(actor.handle.description.prefix(15))\(actor.handle.description.count > 15 ? "..." : "")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 80)
            }
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
            .font(.system(size: 10, weight: .bold))
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
            .font(.system(size: 10, weight: .bold))
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
