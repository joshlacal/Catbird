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
  @Environment(SceneNavigationContext.self) private var sceneContext
    // MARK: - Properties
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var viewModel: RefinedSearchViewModel
    @Binding var selectedTab: Int
    @Binding var lastTappedTab: Int?
    
    // UI state
    @State private var searchText = ""
    @State private var isShowingAllTrendingTopics = false
    @State private var isShowingAllSavedSearches = false  // SRCH-015: All saved searches sheet
    @State private var isShowingSaveSearchSheet = false  // SRCH-015: Save search UI
    @State private var isShowingSuggestedProfiles = false
    @State private var isShowingAddFeedSheet = false
    @State private var isShowingFiltersSheet = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var lastHandledSearchRequestID: UUID?
    @State private var isApplyingPendingSearchRequest = false
    @State private var showingSettings = false
    @State private var isShowingCopilot = false
    @State private var pendingDedicatedProposal: CopilotProposal?

    private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchView")
    
    // MARK: - Initialization
    
    init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
        self._selectedTab = selectedTab
        self._lastTappedTab = lastTappedTab
        self._viewModel = State(initialValue: RefinedSearchViewModel(appState: appState))
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
        .onChange(of: sceneContext.pendingSearchRequest?.id) { _, _ in
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
        .sheet(isPresented: $isShowingAllTrendingTopics) {
            AllTrendingTopicsView(
                topics: viewModel.trendingTopics,
                onSelect: handleTopicSelection
            )
        }
        .sheet(isPresented: $isShowingAllSavedSearches) {
            AllSavedSearchesView(
                savedSearches: viewModel.savedSearches,
                onSelect: { savedSearch in
                    isShowingAllSavedSearches = false
                    if let client = appState.atProtoClient {
                        viewModel.loadAndApplySavedSearch(
                            savedSearch,
                            client: client,
                            onQueryLoaded: { searchText = $0 }
                        )
                    }
                },
                onDelete: { savedSearch in
                    viewModel.deleteSavedSearch(savedSearch.id)
                }
            )
        }
        .sheet(isPresented: $isShowingSaveSearchSheet) {
            // SRCH-015: Save search sheet
            SaveSearchSheet(
                query: viewModel.searchQuery,
                filters: viewModel.filterState,
                onSave: { name in
                    let savedSearch = SavedSearch(
                        name: name,
                        query: viewModel.searchQuery,
                        filters: viewModel.filterState
                    )
                    viewModel.saveSearch(savedSearch)
                }
            )
        }
        .sheet(isPresented: $isShowingFiltersSheet) {
            SearchFiltersSheet(
                initialState: viewModel.filterState,
                onApply: { state in
                    if let client = appState.atProtoClient {
                        viewModel.applyFilterState(state, client: client)
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingSuggestedProfiles) {
            SuggestedProfilesSheet(
                profiles: viewModel.suggestedProfiles,
                isLoading: viewModel.isSuggestedProfilesLoading,
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
        sceneContext.navigationManager.pathBinding(for: 1)
    }

    /// The sort/filter bar only applies to post results (Top + Latest scopes).
    private var shouldShowFilterBar: Bool {
        viewModel.searchState == .results
            && (viewModel.selectedContentType == .top || viewModel.selectedContentType == .latest)
    }

    private var availableScopes: [ContentType] {
        if viewModel.filterState.hasPostOnlyFilters {
            return [.top, .latest]
        }
        return ContentType.allCases
    }
    
    /// True while the native `.searchSuggestions` overlay owns the viewport.
    /// Hiding the underlying content prevents `DiscoveryView`, `TypeaheadView`, or
    /// `ResultsView` from showing through below the last suggestion row when
    /// `.scrollContentBackground(.hidden)` makes the suggestions container transparent.
    private var isShowingSearchSuggestionsOverlay: Bool {
        isSearchFieldFocused || (viewModel.searchState == .searching && !viewModel.isCommittedSearch)
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
                if shouldShowFilterBar {
                    SearchFilterBar(
                        activeFilterCount: viewModel.filterState.activeFilterCount,
                        onFiltersTap: { isShowingFiltersSheet = true }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                mainContentArea
            }
            .opacity(isShowingSearchSuggestionsOverlay ? 0 : 1)
            .allowsHitTesting(!isShowingSearchSuggestionsOverlay)
            .accessibilityHidden(isShowingSearchSuggestionsOverlay)
        }
        .navigationTitle("Search")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Profiles, posts, or feeds"
        )
        .searchFocused($isSearchFieldFocused)
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .searchScopes($bindableViewModel.selectedContentType) {
            ForEach(availableScopes, id: \.self) { scope in
                Text(scope.scopeTitle).tag(scope)
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
                Task { await viewModel.refreshSearch(client: client, displayScale: displayScale) }
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
            ForEach(availableScopes, id: \.self) { scope in
                Text(scope.scopeTitle).tag(scope)
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
                Task { await viewModel.refreshSearch(client: client, displayScale: displayScale) }
            } else {
                logger.debug("No action taken - empty search text and no committed search")
            }
        }
        #endif
        .searchSuggestions {
            searchSuggestionsContent
        }
        // Configure the native suggestions list, not just the discovery scroll view.
        // Short history must still accept a vertical pan to dismiss the keyboard.
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always, axes: .vertical)
        .onSubmit(of: .search) {
            commitSearch()
        }
        #if !targetEnvironment(macCatalyst)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                searchMenuButton
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsAvatarToolbarButton {
                    showingSettings = true
                }
            }
        }
        #endif
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .applyAppStateEnvironment(appState)
                .environment(appState)
        }
        .sheet(isPresented: $isShowingCopilot) {
            let query = activeSearchQuery
            CatbirdCopilotSheet(
                context: .search(query: query),
                onDedicatedAction: { proposal in
                    pendingDedicatedProposal = proposal
                }
            )
        }
        .onChange(of: isShowingCopilot) { wasShowing, isShowing in
            if wasShowing && !isShowing, let proposal = pendingDedicatedProposal {
                pendingDedicatedProposal = nil
                if case .preparePostDraft(let text) = proposal {
                    sceneContext.presentPostComposer(initialText: text)
                }
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
            showAllSavedSearches: $isShowingAllSavedSearches,
            showSuggestedProfiles: $isShowingSuggestedProfiles,
            showAddFeedSheet: $isShowingAddFeedSheet,
            onQueryLoaded: { searchText = $0 }
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
            selectedContentType: $bindableViewModel.selectedContentType,
            onReset: { reset() }
        )
    }
    
    private var loadingView: some View {
        SearchLoadingSkeletonView()
    }
    
    // MARK: - Search Menu
    
    private var activeSearchQuery: String {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchMenuButton: some View {
        Menu {
            if !activeSearchQuery.isEmpty && CopilotAvailability.isAvailable {
                Button {
                    isShowingCopilot = true
                } label: {
                    Label("Ask Catbird", systemImage: "sparkles")
                }

                Divider()
            }

            // SRCH-015: Save Search option
            if viewModel.isCommittedSearch && !viewModel.searchQuery.isEmpty {
                Button {
                    isShowingSaveSearchSheet = true
                } label: {
                    Label("Save Search", systemImage: "bookmark")
                }
                
                Divider()
            }
            
            Button {
                reset()
            } label: {
                Label("Reset Search", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Search options")
    }
    
    // MARK: - Search Suggestions
    
    /// Native search suggestions replace the page while the field is focused. Three
    /// distinct states: typing (query + typeahead), history, and no history yet.
    @ViewBuilder
    private var searchSuggestionsContent: some View {
        if !trimmedSearchText.isEmpty {
            typeaheadSuggestions
        } else if hasSearchHistory {
            searchHistorySuggestions
        } else {
            SearchHistoryEmptyHint()
                .modifier(SearchSuggestionRowModifier())
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSearchHistory: Bool {
        !viewModel.recentProfileSearches.isEmpty
            || (!viewModel.recentSearchEntries.isEmpty && appState.atProtoClient != nil)
    }

    /// Recent searches that contain the typed text, excluding an exact repeat of it.
    private var matchingRecentSearches: [RecentSearchEntry] {
        guard appState.atProtoClient != nil else { return [] }
        let query = trimmedSearchText
        return Array(viewModel.recentSearchEntries.filter {
            $0.query.localizedCaseInsensitiveContains(query)
                && $0.query.compare(query, options: .caseInsensitive) != .orderedSame
        }.prefix(3))
    }

    @ViewBuilder
    private var typeaheadSuggestions: some View {
        VStack(spacing: 0) {
            Button {
                commitSearch()
            } label: {
                SearchSuggestionRow(systemImage: "magnifyingglass", tint: .accentColor) {
                    Text("Search for “\(trimmedSearchText)”")
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.suggestion.submit")

            if !matchingRecentSearches.isEmpty || !viewModel.typeaheadProfiles.isEmpty {
                Rectangle()
                    .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
        .modifier(SearchSuggestionRowModifier())

        ForEach(matchingRecentSearches) { entry in
            VStack(spacing: 0) {
                Button {
                    applyRecentSearch(entry)
                } label: {
                    SearchSuggestionRow(systemImage: "clock.arrow.circlepath", tint: .secondary) {
                        Text(entry.query)
                            .foregroundStyle(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Recent search")

                Rectangle()
                    .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
                    .frame(height: 0.5)
                    .padding(.leading, 58)
            }
            .modifier(SearchSuggestionRowModifier())
        }

        if !viewModel.typeaheadProfiles.isEmpty {
            // Keep header and profile rows in one suggestion block so XCUITest and VoiceOver
            // expose individual profile staticTexts while giving each row generous height.
            VStack(alignment: .leading, spacing: 0) {
                Text("Profiles")
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                let profiles = viewModel.typeaheadProfiles
                ForEach(Array(profiles.enumerated()), id: \.element.did) { index, profile in
                    VStack(spacing: 0) {
                        Button {
                            handleProfileSelection(profile)
                        } label: {
                            profileSuggestionRow(profile)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < profiles.count - 1 {
                            Rectangle()
                                .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
                                .frame(height: 0.5)
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .modifier(SearchSuggestionRowModifier())
        }
    }

    @ViewBuilder
    private var searchHistorySuggestions: some View {
        if !viewModel.recentProfileSearches.isEmpty {
            RecentProfilesSection(
                profiles: viewModel.recentProfileSearches,
                onSelect: { profile in
                    isSearchFieldFocused = false
                    navigationPath.wrappedValue.append(NavigationDestination.profile(profile.did.didString()))
                },
                onClear: {
                    viewModel.clearRecentProfileSearches()
                }
            )
            .modifier(SearchSuggestionRowModifier())
        }

        // Recent searches (G05)
        if !viewModel.recentSearchEntries.isEmpty, appState.atProtoClient != nil {
            RecentSearchesSection(
                entries: viewModel.recentSearchEntries,
                onSelect: { entry in
                    applyRecentSearch(entry)
                },
                onFill: { entry in
                    searchText = entry.query
                },
                onDelete: { entry in
                    viewModel.deleteRecentSearch(entry)
                },
                onClear: {
                    viewModel.clearRecentSearches()
                }
            )
        }
    }

    private func applyRecentSearch(_ entry: RecentSearchEntry) {
        guard let client = appState.atProtoClient else { return }
        isSearchFieldFocused = false
        viewModel.applyRecentSearchEntry(
            entry,
            client: client,
            onQueryLoaded: { searchText = $0 }
        )
    }

    private func profileSuggestionRow(_ profile: AppBskyActorDefs.ProfileViewBasic) -> some View {
        HStack(spacing: 12) {
            AsyncProfileImage(
                url: URL(string: profile.avatar?.uriString() ?? ""),
                size: 44,
                did: profile.did.didString(),
                labels: profile.labels
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(profile.handle)")
                        .appFont(AppTextRole.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        .lineLimit(1)

                    if let badgeKind = VerificationBadge.kind(for: profile.verification, did: profile.did) {
                        VerificationBadgeView(kind: badgeKind)
                            .font(.subheadline)
                    }
                    if AutomationBadge.isSelfDeclared(labels: profile.labels, authorDID: profile.did) {
                        AutomationBadgeView()
                            .layoutPriority(1)
                    }
                }

                HStack(spacing: 6) {
                    Text(verbatim: "@\(profile.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        .lineLimit(1)

                    if profile.viewer?.followedBy != nil {
                        FollowsBadgeView()
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
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
        guard newValue == 1, selectedTab == 1 else { return }
        lastTappedTab = nil

        if !navigationPath.wrappedValue.isEmpty {
            // Reselecting a deeper destination returns to Search first.
            // Keep the query and results available when the root reappears.
            isSearchFieldFocused = false
            navigationPath.wrappedValue = NavigationPath()
        } else {
            // Ordinary tab reselection focuses search; no timed double tap is needed.
            isSearchFieldFocused = true
        }
    }

    private func applyPendingSearchRequestIfNeeded() {
        guard selectedTab == 1 else { return }
        guard let request = sceneContext.pendingSearchRequest else { return }
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

        sceneContext.pendingSearchRequest = nil
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
            return .top
        case .profiles:
            return .people
        case .posts:
            return .top
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
        viewModel.ensureLocalPreferencesAndStoredSearchesLoaded()
        // Subscribe to events only if this is the active search tab
        if selectedTab == 1 {
            viewModel.subscribeToEvents(displayScale: displayScale)
        }
        
        if let client = appState.atProtoClient {
            viewModel.initialize(client: client, displayScale: displayScale)
        }
    }
    
    private func handleViewDisappear() {
        // Always unsubscribe when view disappears to prevent memory leaks
        viewModel.unsubscribeFromEvents()
    }
    
    private func handleTabChange(_ newTab: Int) {
        if newTab == 1 {
            // Search tab became active - subscribe to events
            viewModel.subscribeToEvents(displayScale: displayScale)
        } else {
            // Search tab became inactive - unsubscribe from events
            viewModel.unsubscribeFromEvents()
        }
    }
    
    private func commitSearch() {
        logger.debug("commitSearch() called")

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFieldFocused = false
        // The field can hold text the view model no longer has (for example after
        // "Explore Trending Content"), so always commit what the user sees.
        viewModel.searchQuery = trimmed

        if let client = appState.atProtoClient {
            viewModel.commitSearch(client: client)
        }
    }
    
    private func handleProfileSelection(_ profile: AppBskyActorDefs.ProfileViewBasic) {
        isSearchFieldFocused = false
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
                _ = sceneContext.urlHandler.handle(url)
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
  AsyncPreviewContent { appState in
    let selectedTab = Binding.constant(1)
    
        RefinedSearchView(appState: appState, selectedTab: selectedTab, lastTappedTab: .constant(1))
  }
}
