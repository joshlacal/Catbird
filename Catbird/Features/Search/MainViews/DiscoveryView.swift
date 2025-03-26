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
                if !viewModel.recentProfileSearches.isEmpty {
                    RecentProfilesSection(
                        profiles: viewModel.recentProfileSearches,
                        onSelect: { profile in
                            path.append(NavigationDestination.profile(profile.did))
                        },
                        onClear: {
                            viewModel.clearRecentProfileSearches()
                        }
                    )
                }
                
                // Recent searches
                if !viewModel.recentSearches.isEmpty, let client = appState.atProtoClient {
                    RecentSearchesSection(
                        searches: viewModel.recentSearches,
                        onSelect: { search in
                            viewModel.searchQuery = search
                            viewModel.commitSearch(client: client)
                        },
                        onClear: {
                            viewModel.clearRecentSearches()
                        }
                    )
                }
                
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
                            path.append(NavigationDestination.profile(profile.did))
                        },
                        onRefresh: {
                            Task {
                                guard let client = appState.atProtoClient else { return }
                                await viewModel.refreshSuggestedProfiles(client: client)
                            }
                        }
                    )
                }
                
                // Tagged suggestions
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
    let topics: [AppBskyUnspeccedDefs.TrendingTopic]
    let onSelect: (String) -> Void
    
    var body: some View {
        NavigationView {
            // Instead of List + ForEach, use ScrollView + LazyVStack
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Iterate through topics with a simple range
                    ForEach(0..<topics.count, id: \.self) { index in
                        let topic = topics[index]
                        topicRow(topic: topic)
                    }
                }
            }
            .navigationTitle("Trending Topics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // Extract the row view into a separate function to simplify the ForEach
    private func topicRow(topic: AppBskyUnspeccedDefs.TrendingTopic) -> some View {
        Button {
            onSelect(topic.displayName ?? topic.topic)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.displayName ?? topic.topic)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                if let description = topic.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
//                HStack {
//                    Label("\(topic.link) posts", systemImage: "text.bubble")
//                        .font(.caption)
//                        .foregroundColor(.secondary)
//                }
//                .padding(.top, 2)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .background(Color(.systemBackground))
        .listRowInsets(EdgeInsets())
    }
}
