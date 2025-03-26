//
//  TypeaheadView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// View displaying search suggestions as the user types
struct TypeaheadView: View {
    var viewModel: RefinedSearchViewModel
    @Binding var path: NavigationPath
    @Binding var searchText: String
    let committed: Bool
    @Environment(AppState.self) private var appState
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TypeaheadView")
    
    var body: some View {
        VStack(spacing: 0) {
            if committed {
                // Show loading indicators when a search is committed but still loading
                LoadingRowsView(count: 5)
            } else if searchText.isEmpty {
                // Show empty state if no search text
                emptyStateView
            } else {
                // Show typeahead suggestions
                suggestionsList
            }
            
            Spacer(minLength: 50)
        }
        .animation(.smooth(duration: 0.2), value: viewModel.typeaheadResultsCount)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
                .padding(.top, 60)
            
            Text("Start typing to search")
                .font(.headline)
            
            Text("Search for handles, feeds, hashtags, or keywords")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Profiles Section
                if !viewModel.typeaheadProfiles.isEmpty {
                    sectionHeader(title: "Profiles", icon: "person")
                    
                    ForEach(viewModel.typeaheadProfiles, id: \.did) { profile in
                        Button {
                            // Save to recent profiles and navigate
                            // Save recent profile search
                            viewModel.addRecentProfileSearchBasic(profile: profile)
                            path.append(NavigationDestination.profile(profile.did))
                        } label: {
                            // Use the profile directly
                            ProfileRowView(profile: profile)
                        }
                        .buttonStyle(.plain)
                        
                        if profile != viewModel.typeaheadProfiles.last {
                            EnhancedDivider()
                        }
                    }
                    
                    Divider()
                        .padding(.vertical, 8)
                }
                
                // Feeds Section
                if !viewModel.typeaheadFeeds.isEmpty {
                    sectionHeader(title: "Feeds", icon: "rectangle.on.rectangle.angled")
                    
                    ForEach(viewModel.typeaheadFeeds, id: \.uri) { feed in
                        Button {
                            // Navigate to feed
                            path.append(NavigationDestination.feed(feed.uri))
                        } label: {
                            EnhancedFeedRowView(feed: feed)
                        }
                        .buttonStyle(.plain)
                        
                        if feed != viewModel.typeaheadFeeds.last {
                            EnhancedDivider()
                        }
                    }
                    
                    Divider()
                        .padding(.vertical, 8)
                }
                
                // Search Term Suggestions
                if !viewModel.typeaheadSuggestions.isEmpty {
                    sectionHeader(title: "Suggestions", icon: "text.magnifyingglass")
                    
                    ForEach(viewModel.typeaheadSuggestions, id: \.self) { suggestion in
                        Button {
                            // Update search text and commit search
                            searchText = suggestion
                            viewModel.searchQuery = suggestion
                            guard let client = appState.atProtoClient else {
                                logger.error("Empty client")
                                return
                            }
                            
                            viewModel.commitSearch(client: client)
                        } label: {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, height: 24)
                                    .padding(.trailing, 8)
                                
                                Text(suggestion)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.left")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                        
                        if suggestion != viewModel.typeaheadSuggestions.last {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                    
                    Divider()
                        .padding(.vertical, 8)
                }
                
                // Search directly button
                Button {
                    // Commit search with current text
                    guard let client = appState.atProtoClient else {
                        logger.error("Empty client")
                        return
                    }

                    viewModel.commitSearch(client: client)
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.accentColor)
                        
                        Text("Search for \"\(searchText)\"")
                            .foregroundColor(.accentColor)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .background(Color(.systemBackground))
        }
    }
    
    // Helper to create section headers
    private func sectionHeader(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .font(.subheadline)
            
            Text(title)
                .font(.headline)
            
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
        .background(Color(.systemBackground))
    }
}

// Model representing a search suggestion
struct SearchSuggestion: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let type: SuggestionType
    
    enum SuggestionType {
        case hashtag
        case term
        case handle
    }
    
    // Generate suggestions based on query text
    static func generateSuggestions(for query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Generate potential variations based on query text
        var suggestions: [String] = []
        
        // Add hashtag version if not already a hashtag
        if !trimmed.hasPrefix("#") && !trimmed.contains(" ") {
            suggestions.append("#\(trimmed)")
        }
        
        // Add handle version if applicable
        if !trimmed.hasPrefix("@") && !trimmed.contains(" ") && trimmed.count >= 3 {
            suggestions.append("@\(trimmed)")
        }
        
        // Add some common context terms
        let contextTerms = ["trending", "popular", "latest", "recommended"]
        for term in contextTerms where term.contains(trimmed.lowercased()) || trimmed.lowercased().contains(term) {
            suggestions.append(term)
        }
        
        return suggestions
    }
}

