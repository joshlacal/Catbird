//
//  RefinedSearchView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// A modernized search view that leverages iOS 18 features for a better search experience
struct RefinedSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: RefinedSearchViewModel
    @Binding var selectedTab: Int
    @Binding var lastTappedTab: Int?
    
    // UI state
    @State private var searchText = ""
    @State private var isShowingFilters = false
    @State private var isShowingAdvancedFilters = false
    @State private var isShowingAllTrendingTopics = false
    @FocusState private var isSearchFieldFocused: Bool
    
    init(appState: AppState, selectedTab: Binding<Int>, lastTappedTab: Binding<Int?>) {
        self._viewModel = State(initialValue: RefinedSearchViewModel(appState: appState))
        self._selectedTab = selectedTab
        self._lastTappedTab = lastTappedTab
    }
    
    private let logger = Logger(subsystem: "blue.catbird", category: "RefinedSearchView")

    var body: some View {
        let navigationPath = appState.navigationManager.pathBinding(for: 1)

        NavigationStack(path: navigationPath) {
            VStack(spacing: 0) {
                // Only show segment control on the results view
                if viewModel.searchState == .results, viewModel.hasMultipleResultTypes {
                    ContentTypeSegmentControl(selectedContentType: $viewModel.selectedContentType)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Material.bar)
                        .zIndex(1) // Ensure control stays on top
                }
                
                // Main content area
                ZStack {
                    Color(.systemGroupedBackground)
                        .ignoresSafeArea()
                    
                    // Content views with transitions
                    Group {
                        switch viewModel.searchState {
                        case .idle:
                            DiscoveryView(
                                viewModel: viewModel, 
                                path: navigationPath,
                                showAllTrendingTopics: $isShowingAllTrendingTopics
                            )
                            .transition(.opacity)
                            
                        case .searching:
                            TypeaheadView(
                                viewModel: viewModel,
                                path: navigationPath,
                                searchText: $searchText, 
                                committed: viewModel.isCommittedSearch
                            )
                            .transition(.opacity)
                            
                        case .results:
                            ResultsView(
                                viewModel: viewModel,
                                path: navigationPath,
                                selectedContentType: $viewModel.selectedContentType
                            )
                            .transition(.opacity)
                            
                        case .loading:
                            LoadingView(message: "Searching for \"\(viewModel.searchQuery)\"...")
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: viewModel.searchState)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Handles, feeds, hashtags, or keywords"
            )
            .searchSuggestions {
                searchSuggestionsContent
            }
            .onSubmit(of: .search) {
                if let client = appState.atProtoClient {
                    viewModel.commitSearch(client: client)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                destinationView(for: destination)
            }
        }
        .toolbarBackgroundVisibility(.visible, for: .tabBar)
        .onChange(of: lastTappedTab) { _, newValue in
            if newValue == 1, selectedTab == 1 {
                // Reset search on double-tap
                reset()
                lastTappedTab = nil
            }
        }
        .onChange(of: searchText) { _, newText in
            if let client = appState.atProtoClient {
                viewModel.updateSearch(query: newText, client: client)
            }
        }
        .onAppear {
            if let client = appState.atProtoClient {
                viewModel.initialize(client: client)
            }
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
                onSelect: { term in
                    if let client = appState.atProtoClient {
                        searchText = term
                        viewModel.searchQuery = term
                        viewModel.commitSearch(client: client)
                    }
                }
            )
        }
    }
    
    // MARK: - Search Suggestions
    
    @ViewBuilder
    private var searchSuggestionsContent: some View {
        // Show dynamic suggestions when typing
        if !searchText.isEmpty {
            // Generate some hashtag/term suggestions
            ForEach(SearchSuggestion.generateSuggestions(for: searchText), id: \.self) { suggestion in
                Button {
                    if let client = appState.atProtoClient {
                        viewModel.searchQuery = suggestion
                        viewModel.commitSearch(client: client)
                    }
                } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                }
            }
        } else {
            // Show recent searches when empty
            ForEach(viewModel.recentSearches.prefix(5), id: \.self) { search in
                Button {
                    if let client = appState.atProtoClient {
                        searchText = search
                        viewModel.searchQuery = search
                        viewModel.commitSearch(client: client)
                    }
                } label: {
                    Label(search, systemImage: "clock")
                }
            }
        }
    }
    
    // MARK: - Navigation Handling
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        let navigationPath = appState.navigationManager.pathBinding(for: 1)

        NavigationHandler.viewForDestination(destination, path: navigationPath, appState: appState, selectedTab: $selectedTab)
    }
    
    // MARK: - Helper Methods
    
    private func reset() {
        let navigationPath = appState.navigationManager.pathBinding(for: 1)

        searchText = ""
        viewModel.resetSearch()
        navigationPath.wrappedValue.removeLast(navigationPath.wrappedValue.count)
    }
}

