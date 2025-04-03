import NukeUI
import OSLog
import Petrel
import SwiftUI

struct AddFeedSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var popularFeeds: [AppBskyFeedDefs.GeneratorView] = []
    @State private var searchResults: [AppBskyFeedDefs.GeneratorView] = []
    @State private var isLoading = true
    @State private var loadingError: String?
    @State private var selectedFeedForPinning: AppBskyFeedDefs.GeneratorView?
    @State private var showPinToggleSheet = false
    @State private var pinSelected = true
    @State private var viewModel: FeedsStartPageViewModel?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AddFeedSheet")
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search feeds...", text: $searchText)
                        .foregroundColor(.primary)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onSubmit {
                            searchForFeeds()
                        }
                    
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            isSearching = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)
                
                // Content
                ScrollView {
                    if isLoading {
                        ProgressView("Loading feeds...")
                            .padding(.top, 40)
                    } else if let error = loadingError {
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.red)
                                .padding()
                            
                            Text(error)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding()
                            
                            Button("Try Again") {
                                if isSearching {
                                    searchForFeeds()
                                } else {
                                    loadPopularFeeds()
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .padding()
                        }
                        .padding(.top, 40)
                    } else {
                        if isSearching {
                            // Search results
                            if searchResults.isEmpty {
                                VStack {
                                    Image(systemName: "magnifyingglass")
                                        .font(.largeTitle)
                                        .foregroundColor(.secondary)
                                        .padding()
                                    
                                    Text("No feeds found matching '\(searchText)'")
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.top, 40)
                            } else {
                                VStack(alignment: .leading) {
                                    Text("Search Results")
                                        .font(.headline)
                                        .padding(.horizontal)
                                        .padding(.top)
                                    
                                    feedsGrid(feeds: searchResults)
                                }
                            }
                        } else {
                            // Popular feeds
                            if popularFeeds.isEmpty {
                                VStack {
                                    Image(systemName: "star")
                                        .font(.largeTitle)
                                        .foregroundColor(.secondary)
                                        .padding()
                                    
                                    Text("No popular feeds available")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 40)
                            } else {
                                VStack(alignment: .leading) {
                                    Text("Popular Feeds")
                                        .font(.headline)
                                        .padding(.horizontal)
                                        .padding(.top)
                                    
                                    feedsGrid(feeds: popularFeeds)
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    if isSearching {
                        searchForFeeds()
                    } else {
                        loadPopularFeeds()
                    }
                }
            }
            .navigationTitle("Discover Feeds")
            .navigationBarItems(
                trailing: Button("Done") {
                    dismiss()
                }
            )
            .onAppear {
                initViewModel()
                loadPopularFeeds()
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.isEmpty && isSearching {
                    isSearching = false
                }
            }
            .sheet(item: $selectedFeedForPinning) { feed in
                pinConfirmationSheet(feed: feed)
            }
        }
    }
    
    private func initViewModel() {
        if viewModel == nil {
            viewModel = FeedsStartPageViewModel(appState: appState, modelContext: modelContext)
        }
    }
    
    // Grid of feeds
    private func feedsGrid(feeds: [AppBskyFeedDefs.GeneratorView]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2),
            spacing: 16
        ) {
            ForEach(feeds, id: \.uri.uriString) { feed in
                feedCard(feed: feed)
                    .onTapGesture {
                        selectedFeedForPinning = feed
                    }
            }
        }
        .padding()
    }
    
    // Individual feed card
    private func feedCard(feed: AppBskyFeedDefs.GeneratorView) -> some View {
        VStack {
            // Avatar image
            Group {
                if let avatarUrl = feed.avatar?.uriString() {
                    LazyImage(url: URL(string: avatarUrl)) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            feedPlaceholder(for: feed.displayName)
                        }
                    }
                } else {
                    feedPlaceholder(for: feed.displayName)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            
            // Feed name
            Text(feed.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.top, 4)
            
            // Creator handle
            Text("@\(feed.creator.handle)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            // Like count if available
            if let likeCount = feed.likeCount {
                HStack(spacing: 2) {
                    Image(systemName: "heart")
                        .font(.caption2)
                    Text("\(likeCount)")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // Confirmation sheet for pinning
    private func pinConfirmationSheet(feed: AppBskyFeedDefs.GeneratorView) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Avatar
                Group {
                    if let avatarUrl = feed.avatar?.uriString() {
                        LazyImage(url: URL(string: avatarUrl)) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                feedPlaceholder(for: feed.displayName)
                            }
                        }
                    } else {
                        feedPlaceholder(for: feed.displayName)
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                
                // Feed name
                Text(feed.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                // Creator
                Text("by @\(feed.creator.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                // Description
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                
                Divider()
                    .padding(.vertical)
                
                // Pin toggle
                Toggle("Pin this feed", isOn: $pinSelected)
                    .padding(.horizontal)
                
                Text("Pinned feeds appear at the top of your feeds list")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                Spacer()
                
                // Buttons
                HStack(spacing: 16) {
                    Button("Cancel") {
                        selectedFeedForPinning = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    
                    Button("Add Feed") {
                        addFeed(feed)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
                .padding()
            }
            .padding()
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // Placeholder for feeds without avatars
    private func feedPlaceholder(for title: String) -> some View {
        ZStack {
            // iOS-like gradient background
            LinearGradient(
                gradient: Gradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.5)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // First letter of feed name
            Text(title.prefix(1).uppercased())
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundColor(.white)
        }
    }
    
    // Load popular feeds
    private func loadPopularFeeds() {
        isLoading = true
        loadingError = nil
        
        Task {
            do {
                guard let client = appState.atProtoClient else {
                    throw NSError(domain: "Feed", code: 0, userInfo: [NSLocalizedDescriptionKey: "Client not available"])
                }
                
                let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 20)
                let (responseCode, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
                
                await MainActor.run {
                    if responseCode == 200, let feeds = response?.feeds {
                        popularFeeds = feeds
                    } else {
                        loadingError = "Failed to load popular feeds. Response code: \(responseCode)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadingError = "Error loading feeds: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    // Search for feeds
    private func searchForFeeds() {
        guard !searchText.isEmpty else { return }
        
        isSearching = true
        isLoading = true
        loadingError = nil
        searchResults = []
        
        Task {
            do {
                guard let client = appState.atProtoClient else {
                    throw NSError(domain: "Feed", code: 0, userInfo: [NSLocalizedDescriptionKey: "Client not available"])
                }
                
                let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 20, query: searchText)
                let (responseCode, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
                
                await MainActor.run {
                    if responseCode == 200, let feeds = response?.feeds {
                        searchResults = feeds
                    } else {
                        loadingError = "Failed to search feeds. Response code: \(responseCode)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadingError = "Error searching for feeds: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    // Add a feed
    private func addFeed(_ feed: AppBskyFeedDefs.GeneratorView) {
        Task {
            do {
                guard let viewModel = viewModel else {
                    throw NSError(domain: "Feed", code: 0, userInfo: [NSLocalizedDescriptionKey: "ViewModel not available"])
                }
                
                let feedURI = feed.uri.uriString()
                await viewModel.addFeed(feedURI, pinned: pinSelected)
                
                // Close the sheets
                await MainActor.run {
                    selectedFeedForPinning = nil
                    dismiss()
                }
            } catch {
                logger.error("Failed to add feed: \(error.localizedDescription)")
                // You could show an error message here
            }
        }
    }
}

extension AppBskyFeedDefs.GeneratorView: Identifiable {
    public var id: String {
        return uri.uriString()
    }
}