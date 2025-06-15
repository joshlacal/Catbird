//
//  RefinedSearchView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog
import TipKit

/// A modernized search view that leverages iOS 18 features for a better search experience
struct RefinedSearchView: View {
    // MARK: - Properties
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: RefinedSearchViewModel
    @Binding var selectedTab: Int
    @Binding var lastTappedTab: Int?
    
    // UI state
    @State private var searchText = ""
    @State private var isShowingFilters = false
    @State private var isShowingAdvancedFilters = false
    @State private var isShowingAllTrendingTopics = false
    @FocusState private var isSearchFieldFocused: Bool
    
    private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchView")
    
    // MARK: - Initialization
    
    init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
        self._viewModel = State(initialValue: RefinedSearchViewModel(appState: appState))
        self._selectedTab = selectedTab
        self._lastTappedTab = lastTappedTab
    }
    
    // MARK: - Main Body
    
    var body: some View {
        NavigationStack(path: navigationPath) {
            mainContentContainer
        }
        .onChange(of: lastTappedTab) { _, newValue in
            handleTabTap(newValue)
        }
        .onChange(of: searchText) { _, newText in
            updateSearchWithText(newText)
        }
        .onAppear {
            initializeOnAppear()
        }
        .sheet(isPresented: $isShowingFilters) {
            FilterView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingAdvancedFilters) {
            AdvancedFilterView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingAllTrendingTopics) {
            AllTrendingTopicsView(
                topics: viewModel.trendingTopics,
                onSelect: handleTopicSelection
            )
        }
    }
    
    // MARK: - Computed Properties
    
    private var navigationPath: Binding<NavigationPath> {
        appState.navigationManager.pathBinding(for: 1)
    }
    
    private var mainContentContainer: some View {
        ResponsiveContentView {
            VStack(spacing: 0) {
                contentTypeSegment
                mainContentArea
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Users, keywords, hashtags, or feeds"
        )
        .searchSuggestions {
            searchSuggestionsContent
        }
        .onSubmit(of: .search) {
            commitSearch()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                searchMenuButton
            }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
            destinationView(for: destination)
        }
    }
    
    private var contentTypeSegment: some View {
        Group {
            if viewModel.searchState == .results, viewModel.hasMultipleResultTypes {
                ContentTypeSegmentControl(selectedContentType: $viewModel.selectedContentType)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Material.bar)
                    .animation(.smooth, value: viewModel.hasMultipleResultTypes)
                    .zIndex(1) // Ensure control stays on top
            }
        }
    }
    
    private var mainContentArea: some View {
        ZStack {
            backgroundLayer
            contentLayer
        }
    }
    
    private var backgroundLayer: some View {
        Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme)
            .ignoresSafeArea()
    }
    
    private var contentLayer: some View {
        Group {
            switch viewModel.searchState {
            case .idle:
                discoveryView
                    .transition(.opacity)
                
            case .searching:
                 typeaheadView
                    .transition(.opacity)
                
            case .results:
                resultsView
                    .transition(.opacity)
                
            case .loading:
                loadingView
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: viewModel.searchState)
    }
    
    private var discoveryView: some View {
        DiscoveryView(
            viewModel: viewModel,
            path: navigationPath,
            showAllTrendingTopics: $isShowingAllTrendingTopics
        )
    }
    
     private var typeaheadView: some View {
         TypeaheadView(
             viewModel: viewModel,
             path: navigationPath,
             searchText: $searchText,
             committed: viewModel.isCommittedSearch
         )
     }
    
    private var resultsView: some View {
        ResultsView(
            viewModel: viewModel,
            path: navigationPath,
            selectedContentType: $viewModel.selectedContentType
        )
    }
    
    private var loadingView: some View {
        LoadingView(message: "Searching for \"\(viewModel.searchQuery)\"...")
    }
    
    // MARK: - Search Menu
    
    private var searchMenuButton: some View {
        Menu {
            Button {
                isShowingFilters = true
            } label: {
                Label("Basic Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            
            Button {
                isShowingAdvancedFilters = true
            } label: {
                Label("Advanced Filters", systemImage: "slider.horizontal.3")
            }
            
            Divider()
            
            Button {
                reset()
            } label: {
                Label("Reset Search", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    // MARK: - Search Suggestions
    
    @ViewBuilder
    private var searchSuggestionsContent: some View {
        if !searchText.isEmpty {
            VStack(spacing: 0) {
                // Profile suggestions
                if !viewModel.typeaheadProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Profiles")
                            .appHeadline()
                            .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        
                        ForEach(viewModel.typeaheadProfiles, id: \.did) { profile in
                            Button {
                                handleProfileSelection(profile)
                            } label: {
                                profileSuggestionRow(profile)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.bottom, 12)
                }
                
                // Feed suggestions
                if !viewModel.typeaheadFeeds.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Feeds")
                            .appHeadline()
                            .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        
                        ForEach(viewModel.typeaheadFeeds, id: \.uri) { feed in
                            Button {
                                handleFeedSelection(feed)
                            } label: {
                                feedSuggestionRow(feed)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.bottom, 12)
                }
                
                // Term suggestions
//                if !viewModel.typeaheadSuggestions.isEmpty {
//                    VStack(alignment: .leading, spacing: 10) {
//                        Text("Suggestions")
//                            .appHeadline()
//                            .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
//                            .padding(.horizontal)
//                            .padding(.top, 8)
//                        
//                        ForEach(viewModel.typeaheadSuggestions, id: \.self) { suggestion in
//                            Button {
//                                handleSuggestionSelection(suggestion)
//                            } label: {
//                                Label(suggestion, systemImage: "magnifyingglass")
//                                    .padding(.horizontal)
//                                    .padding(.vertical, 6)
//                                    .contentShape(Rectangle())
//                            }
//                            .buttonStyle(PlainButtonStyle())
//                        }
//                    }
//                    .padding(.bottom, 12)
//                }
                
                // Direct search button
                Button {
                    commitSearch()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                        Text("Search for \"\(searchText)\"")
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        } else {
            // Recent profiles
            if !viewModel.recentProfileSearches.isEmpty {
                RecentProfilesSection(
                    profiles: viewModel.recentProfileSearches,
                    onSelect: { profile in
                        navigationPath.wrappedValue.append(NavigationDestination.profile(profile.did.didString()))
                    },
                    onClear: {
                        viewModel.clearRecentProfileSearches()
                    }
                )
                .padding(.bottom, 12)
            }
            
            // Recent searches
            if !viewModel.recentSearches.isEmpty, let client = appState.atProtoClient {
                RecentSearchesSection(
                    searches: viewModel.recentSearches,
                    onSelect: { search in
                        searchText = search
                        viewModel.searchQuery = search
                        viewModel.commitSearch(client: client)
                    },
                    onClear: {
                        viewModel.clearRecentSearches()
                    }
                )
            }
        }
    }
    
    private func profileSuggestionRow(_ profile: AppBskyActorDefs.ProfileViewBasic) -> some View {
        HStack(spacing: 12) {
            AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName ?? "@\(profile.handle)")
                    .appHeadline()
                Text("@\(profile.handle)")
                    .appSubheadline()
                    .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
    
    private func feedSuggestionRow(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
        HStack(spacing: 12) {
            AsyncProfileImage(url: URL(string: feed.avatar?.uriString() ?? ""), size: 36)
            Text(feed.displayName)
                .appHeadline()
            Spacer()
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Navigation Handling
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        NavigationHandler.viewForDestination(
            destination,
            path: navigationPath,
            appState: appState,
            selectedTab: $selectedTab
        )
    }
    
    // MARK: - Helper Methods
    
    private func handleTabTap(_ newValue: Int?) {
        if newValue == 1, selectedTab == 1 {
            // Reset search on double-tap
            reset()
            lastTappedTab = nil
        }
    }
    
    private func updateSearchWithText(_ newText: String) {
        if let client = appState.atProtoClient {
            viewModel.updateSearch(query: newText, client: client)
        }
    }
    
    private func initializeOnAppear() {
        if let client = appState.atProtoClient {
            viewModel.initialize(client: client)
        }
    }
    
    private func commitSearch() {
        if let client = appState.atProtoClient {
            viewModel.commitSearch(client: client)
        }
    }
    
    private func handleProfileSelection(_ profile: AppBskyActorDefs.ProfileViewBasic) {
        viewModel.addRecentProfileSearchBasic(profile: profile)
        navigationPath.wrappedValue.append(NavigationDestination.profile(profile.did.didString()))
    }
    
    private func handleFeedSelection(_ feed: AppBskyFeedDefs.GeneratorView) {
        navigationPath.wrappedValue.append(NavigationDestination.feed(feed.uri))
    }
    
    private func handleSuggestionSelection(_ suggestion: String) {
        if let client = appState.atProtoClient {
            viewModel.searchQuery = suggestion
            viewModel.commitSearch(client: client)
        }
    }
    
    private func handleRecentSearchSelection(_ search: String) {
        if let client = appState.atProtoClient {
            searchText = search
            viewModel.searchQuery = search
            viewModel.commitSearch(client: client)
        }
    }
    
    private func handleTopicSelection(_ term: String) {
        if let client = appState.atProtoClient {
            searchText = term
            viewModel.searchQuery = term
            viewModel.commitSearch(client: client)
        }
    }
    
    private func reset() {
        searchText = ""
        viewModel.resetSearch()
        navigationPath.wrappedValue.removeLast(navigationPath.wrappedValue.count)
    }
}

// MARK: - Preview
#Preview {
    @Previewable @State var appState = AppState.shared
    let selectedTab = Binding.constant(1)
    
    RefinedSearchView(appState: appState, selectedTab: selectedTab, lastTappedTab: .constant(1))
}
