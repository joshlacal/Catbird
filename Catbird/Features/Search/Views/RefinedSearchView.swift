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
import Observation

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
    @State private var isShowingSaveSearchSheet = false  // SRCH-015: Save search UI
    @State private var isShowingSuggestedProfiles = false
    @State private var isShowingAddFeedSheet = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var lastHandledSearchRequestID: UUID?
    @State private var isApplyingPendingSearchRequest = false
    
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
        .onChange(of: selectedTab) { _, newTab in
            handleTabChange(newTab)
            if newTab == 1 {
                applyPendingSearchRequestIfNeeded()
            }
        }
        .onChange(of: lastTappedTab) { _, newValue in
            handleTabTap(newValue)
        }
        .onChange(of: searchText) { _, newText in
            updateSearchWithText(newText)
        }
        .onChange(of: appState.pendingSearchRequest?.id) { _, _ in
            applyPendingSearchRequestIfNeeded()
        }
        // selectedContentType handler moved next to the scope binding
        .onAppear {
            initializeOnAppear()
            applyPendingSearchRequestIfNeeded()
        }
        .onDisappear {
            handleViewDisappear()
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
        .sheet(isPresented: $isShowingSaveSearchSheet) {
            // SRCH-015: Save search sheet
            SaveSearchSheet(
                query: viewModel.searchQuery,
                filters: viewModel.advancedParams,
                onSave: { name in
                    let savedSearch = SavedSearch(
                        name: name,
                        query: viewModel.searchQuery,
                        filters: viewModel.advancedParams
                    )
                    viewModel.saveSearch(savedSearch)
                }
            )
        }
        .sheet(isPresented: $isShowingSuggestedProfiles) {
            SuggestedProfilesSheet(
                profiles: viewModel.suggestedProfiles,
                onSelect: { profile in
                    isShowingSuggestedProfiles = false
                    navigationPath.wrappedValue.append(NavigationDestination.profile(profile.did.didString()))
                },
                onRefresh: {
                    Task {
                        guard let client = appState.atProtoClient else { return }
                        await viewModel.refreshSuggestedProfiles(client: client)
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingAddFeedSheet) {
            AddFeedSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.thinMaterial)
        }
    }
    
    // MARK: - Computed Properties
    
    private var navigationPath: Binding<NavigationPath> {
        appState.navigationManager.pathBinding(for: 1)
    }
    
    @ViewBuilder
    private var mainContentContainer: some View {
        @Bindable var bindableViewModel = viewModel
        ZStack {
            // Full-width background layer
            Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme)
                .ignoresSafeArea()
            
            // Edge-to-edge content; individual rows constrain via .mainContentFrame()
            VStack(spacing: 0) {
                mainContentArea
            }
        }
        .navigationTitle("Search")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        .searchFocused($isSearchFieldFocused)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Profiles, posts, or feeds"
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .searchScopes($bindableViewModel.selectedContentType) {
            ForEach(ContentType.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .onChange(of: bindableViewModel.selectedContentType) { oldValue, newValue in
            logger.debug("Search scope changed from \(oldValue.title) to \(newValue.title)")
            logger.debug("Current search state: \(String(describing: viewModel.searchState)), searchText: '\(searchText)', isCommittedSearch: \(viewModel.isCommittedSearch)")

            if isApplyingPendingSearchRequest {
                logger.debug("Skipping scope side effects while applying pending search request")
                return
            }
            
            // Ensure scope changes while typing commit a search and dismiss typeahead
            guard let client = appState.atProtoClient else { 
                logger.error("No AT Proto client available for search scope change")
                return 
            }
            
            if !searchText.isEmpty {
                logger.debug("Committing search with query: '\(searchText)' for scope: \(newValue.title), dismissing keyboard")
                
                // Forcefully dismiss keyboard and search field focus
                isSearchFieldFocused = false
                
                // Delay to ensure keyboard dismissal takes effect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    viewModel.searchQuery = searchText
                    viewModel.commitSearch(client: client)
                }
            } else if viewModel.isCommittedSearch {
                logger.debug("Refreshing existing committed search for new scope: \(newValue.title)")
                Task { await viewModel.refreshSearch(client: client) }
            } else {
                logger.debug("No action taken - empty search text and no committed search")
            }
        }
        #else
        .searchable(
            text: $searchText,
            prompt: "Profiles, posts, or feeds"
        )
        .searchFocused($isSearchFieldFocused)
        .searchScopes($bindableViewModel.selectedContentType) {
            ForEach(ContentType.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .onChange(of: bindableViewModel.selectedContentType) { oldValue, newValue in
            logger.debug("Search scope changed from \(oldValue.title) to \(newValue.title)")
            logger.debug("Current search state: \(String(describing: viewModel.searchState)), searchText: '\(searchText)', isCommittedSearch: \(viewModel.isCommittedSearch)")

            if isApplyingPendingSearchRequest {
                logger.debug("Skipping scope side effects while applying pending search request")
                return
            }
            
            // Ensure scope changes while typing commit a search and dismiss typeahead
            guard let client = appState.atProtoClient else { 
                logger.error("No AT Proto client available for search scope change")
                return 
            }
            
            if !searchText.isEmpty {
                logger.debug("Committing search with query: '\(searchText)' for scope: \(newValue.title), dismissing keyboard")
                
                // Forcefully dismiss keyboard and search field focus
                isSearchFieldFocused = false
                
                // Delay to ensure keyboard dismissal takes effect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    viewModel.searchQuery = searchText
                    viewModel.commitSearch(client: client)
                }
            } else if viewModel.isCommittedSearch {
                logger.debug("Refreshing existing committed search for new scope: \(newValue.title)")
                Task { await viewModel.refreshSearch(client: client) }
            } else {
                logger.debug("No action taken - empty search text and no committed search")
            }
        }
        #endif
        .searchSuggestions {
            searchSuggestionsContent
        }
        .onSubmit(of: .search) {
            commitSearch()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                searchMenuButton
            }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
            destinationView(for: destination)
        }
    }
    
    // Custom contentTypeSegment removed in favor of native .searchScopes
    
    private var mainContentArea: some View {
        Group {
            switch viewModel.searchState {
            case .idle:
                discoveryView
                    .transition(.opacity)
                    .onAppear { logger.debug("Showing discoveryView") }
                
            case .searching:
                 typeaheadView
                    .transition(.opacity)
                    .onAppear { logger.debug("Showing typeaheadView") }
                
            case .results:
                resultsView
                    .transition(.opacity)
                    .onAppear { logger.debug("Showing resultsView") }
                
            case .loading:
                loadingView
                    .transition(.opacity)
                    .onAppear { logger.debug("Showing loadingView") }
            }
        }
        .animation(.smooth(duration: 0.25), value: viewModel.searchState)
        .onChange(of: viewModel.searchState) { oldState, newState in
            logger.debug("Search state changed from \(String(describing: oldState)) to \(String(describing: newState))")
        }
    }
    
    private var discoveryView: some View {
        DiscoveryView(
            viewModel: viewModel,
            path: navigationPath,
            showAllTrendingTopics: $isShowingAllTrendingTopics,
            showSuggestedProfiles: $isShowingSuggestedProfiles,
            showAddFeedSheet: $isShowingAddFeedSheet
        )
    }
    
     private var typeaheadView: some View {
         TypeaheadView(
             viewModel: viewModel,
             path: navigationPath,
             searchText: $searchText
         )
     }
    
    private var resultsView: some View {
        @Bindable var bindableViewModel = viewModel
        return ResultsView(
            viewModel: viewModel,
            path: navigationPath,
            selectedContentType: $bindableViewModel.selectedContentType
        )
    }
    
    private var loadingView: some View {
        SearchLoadingSkeletonView()
    }
    
    // MARK: - Search Menu
    
    private var searchMenuButton: some View {
        Menu {
            // SRCH-015: Save Search option
            if viewModel.isCommittedSearch && !viewModel.searchQuery.isEmpty {
                Button {
                    isShowingSaveSearchSheet = true
                } label: {
                    Label("Save Search", systemImage: "bookmark")
                }
                
                Divider()
            }
            
            // Sort options
            Menu("Sort") {
                ForEach(SearchSort.allCases, id: \.self) { option in
                    Button {
                        viewModel.searchSort = option
                        if viewModel.isCommittedSearch, let client = appState.atProtoClient {
                            Task { await viewModel.refreshSearch(client: client) }
                        }
                    } label: {
                        Label(option.displayName, systemImage: option.icon)
                    }
                }
            }
            
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
                                    .mainContentFrame()
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.bottom, 12)
                }
                
                // Feeds typeahead removed (profiles only)
                
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
                        Text(verbatim: "Search for \"\(searchText)\"")
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .mainContentFrame()
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
                    onDelete: { search in
                        // SRCH-008: Delete individual search
                        viewModel.deleteRecentSearch(search)
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
                Text(verbatim: "@\(profile.handle)")
                    .appSubheadline()
                    .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
    
    // Feeds typeahead row removed
    
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

    private func applyPendingSearchRequestIfNeeded() {
        guard selectedTab == 1 else { return }
        guard let request = appState.pendingSearchRequest else { return }
        guard request.id != lastHandledSearchRequestID else { return }

        lastHandledSearchRequestID = request.id
        applySearchRequest(request)
    }

    private func applySearchRequest(_ request: AppState.SearchRequest) {
        isApplyingPendingSearchRequest = true

        if let desiredScope = contentType(for: request.focus),
           viewModel.selectedContentType != desiredScope {
            viewModel.selectedContentType = desiredScope
        }

        searchText = request.query
        viewModel.searchQuery = request.query

        Task { @MainActor in
            await focusSearchField()
            isApplyingPendingSearchRequest = false
        }

        appState.pendingSearchRequest = nil
    }

    @MainActor
    private func focusSearchField() async {
        // Toggle focus to guarantee SwiftUI registers the change
        isSearchFieldFocused = false
        await Task.yield()
        isSearchFieldFocused = true
    }

    private func contentType(for focus: AppState.SearchRequest.Focus) -> ContentType? {
        switch focus {
        case .all:
            return .all
        case .profiles:
            return .profiles
        case .posts:
            return .posts
        case .feeds:
            return .feeds
        }
    }

    private func updateSearchWithText(_ newText: String) {
        if let client = appState.atProtoClient {
            viewModel.updateSearch(query: newText, client: client)
        }
    }
    
    private func initializeOnAppear() {
        // Subscribe to events only if this is the active search tab
        if selectedTab == 1 {
            viewModel.subscribeToEvents()
        }
        
        if let client = appState.atProtoClient {
            viewModel.initialize(client: client)
        }
    }
    
    private func handleViewDisappear() {
        // Always unsubscribe when view disappears to prevent memory leaks
        viewModel.unsubscribeFromEvents()
    }
    
    private func handleTabChange(_ newTab: Int) {
        if newTab == 1 {
            // Search tab became active - subscribe to events
            viewModel.subscribeToEvents()
        } else {
            // Search tab became inactive - unsubscribe from events
            viewModel.unsubscribeFromEvents()
        }
    }
    
    private func commitSearch() {
        logger.debug("commitSearch() called")

        if let client = appState.atProtoClient {
            viewModel.commitSearch(client: client)
        }
    }
    
    private func handleProfileSelection(_ profile: AppBskyActorDefs.ProfileViewBasic) {
        viewModel.addRecentProfileSearchBasic(profile: profile)
        navigationPath.wrappedValue.append(NavigationDestination.profile(profile.did.didString()))
    }
    
    // Feeds typeahead selection removed
    
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
        // If term looks like a trending topic link, route directly to the feed via URLHandler
        if term.hasPrefix("http://") || term.hasPrefix("https://") {
            if let url = URL(string: term) {
                _ = appState.urlHandler.handle(url)
                return
            }
        }
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
