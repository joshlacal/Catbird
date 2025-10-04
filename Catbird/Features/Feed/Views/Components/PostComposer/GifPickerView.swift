import SwiftUI
import NukeUI
import Petrel
import AVFoundation
import AVKit

// MARK: - Tenor API Models

struct TenorSearchResponse: Codable {
    let results: [TenorGif]
    let next: String?
}

struct TenorCategoriesResponse: Codable {
    let tags: [TenorCategory]
}

struct TenorCategory: Codable, Identifiable {
    let searchterm: String
    let path: String
    let image: String
    let name: String
    
    var id: String { searchterm }
}

// MARK: - GIF Picker View

struct GifPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var gifs: [TenorGif] = []
    @State private var categories: [TenorCategory] = []
    @State private var suggestions: [String] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var nextCursor: String?
    @State private var currentQuery: String?
    @State private var selectedCategory: TenorCategory?
    @State private var showingSearch = false
    @State private var showingSuggestions = false
    @State private var searchTask: Task<Void, Never>?

    let onGifSelected: (TenorGif) -> Void
    
    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                searchSection

                // Show suggestions, search results, or categories
                if showingSuggestions && !suggestions.isEmpty {
                    suggestionsSection
                } else if showingSearch || !searchText.isEmpty {
                    searchResultsSection
                } else {
                    categoriesSection
                }
            }
            .navigationTitle("Add GIF")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadCategories()
            }
        }
    }
    
    // MARK: - Search Section
    
    private var searchSection: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search GIFs...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onSubmit {
                        showingSuggestions = false
                        Task {
                            await searchGifs(query: searchText)
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        searchTask?.cancel()
                        
                        if newValue.isEmpty {
                            showingSearch = false
                            showingSuggestions = false
                            gifs = []
                            suggestions = []
                            isLoadingMore = false
                            nextCursor = nil
                            currentQuery = nil
                        } else if newValue.count >= 2 {
                            // Start autocomplete after 2 characters with debounce
                            searchTask = Task {
                                try? await Task.sleep(for: .milliseconds(500)) // Longer debounce for better UX
                                if !Task.isCancelled && !newValue.isEmpty {
                                    await loadSuggestions(query: newValue)
                                }
                            }
                        } else {
                            showingSuggestions = false
                            suggestions = []
                        }
                    }
                
                if !searchText.isEmpty {
                    Button("Clear") {
                        searchText = ""
                        showingSearch = false
                        gifs = []
                        isLoadingMore = false
                        nextCursor = nil
                        currentQuery = nil
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(platformColor: .platformSystemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Rectangle()
                .fill(Color(platformColor: .platformSystemGray4))
                .frame(height: 0.5)
                .padding(.top, 16)
        }
    }
    
    // MARK: - Categories Section
    
    private var categoriesSection: some View {
        ScrollView {
            LazyVGrid(
                columns: gridColumns,
                spacing: 16
            ) {
                ForEach(categories, id: \.id) { (category: TenorCategory) in
                    CategoryCardView(category: category) {
                        Task {
                            await searchGifs(query: category.searchterm)
                            showingSearch = true
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Suggestions Section
    
    private var suggestionsSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { (suggestion: String) in
                    Button(action: {
                        searchText = suggestion
                        showingSuggestions = false
                        Task {
                            await searchGifs(query: suggestion)
                        }
                    }) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                            
                            Text(suggestion)
                                .appFont(AppTextRole.body)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.clear)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if suggestion != suggestions.last {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
        }
        .background(Color(platformColor: .platformSystemBackground))
    }
    
    // MARK: - Search Results Section
    
    private var searchResultsSection: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Searching GIFs...")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if gifs.isEmpty && !searchText.isEmpty {
                VStack {
                    Image(systemName: "magnifyingglass")
                        .appFont(size: 48)
                        .foregroundColor(.secondary)
                    Text("No GIFs found")
                        .appFont(AppTextRole.headline)
                        .padding(.top, 8)
                    Text("Try a different search term")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                gifGridSection
            }
        }
    }
    
    private var gifGridSection: some View {
        GifWaterfallCollectionView(
            gifs: gifs,
            isLoadingMore: isLoadingMore,
            onGifSelected: { gif in
                onGifSelected(gif)
                dismiss()
            },
            onLoadMore: {
                if nextCursor != nil && !isLoadingMore {
                    Task {
                        await loadMoreGifs()
                    }
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - API Calls
    
    private func loadCategories() async {
        do {
            let url = URL(string: "https://catbird.blue/tenor/v2/categories")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TenorCategoriesResponse.self, from: data)
            
            await MainActor.run {
                self.categories = response.tags
            }
        } catch {
            logger.debug("Failed to load categories: \(error)")
        }
    }
    
    private func loadSuggestions(query: String) async {
        guard !query.isEmpty else { return }
        
        do {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "https://catbird.blue/tenor/v2/autocomplete?q=\(encodedQuery)&limit=8")!
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // Check for HTTP errors
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                logger.debug("Autocomplete API returned status code: \(httpResponse.statusCode)")
                await MainActor.run {
                    self.suggestions = []
                    self.showingSuggestions = false
                }
                return
            }
            
            struct AutocompleteResponse: Codable {
                let results: [String]
            }
            
            let autocompleteResponse = try JSONDecoder().decode(AutocompleteResponse.self, from: data)
            
            await MainActor.run {
                // Only show suggestions if we have results and search text hasn't changed
                if !autocompleteResponse.results.isEmpty && query == self.searchText {
                    self.suggestions = autocompleteResponse.results
                    self.showingSuggestions = true
                } else {
                    self.suggestions = []
                    self.showingSuggestions = false
                }
            }
        } catch {
            await MainActor.run {
                self.suggestions = []
                self.showingSuggestions = false
            }
            logger.debug("Failed to load suggestions for '\(query)': \(error)")
        }
    }
    
    private func searchGifs(query: String) async {
        guard !query.isEmpty else { return }
        
        await MainActor.run {
            isLoading = true
            showingSuggestions = false
            isLoadingMore = false
            nextCursor = nil // Reset cursor for new search
            currentQuery = query
        }
        
        do {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "https://catbird.blue/tenor/v2/search?q=\(encodedQuery)&limit=20")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TenorSearchResponse.self, from: data)
            
            await MainActor.run {
                self.gifs = response.results
                self.nextCursor = response.next
                self.isLoading = false
                self.showingSearch = true
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
            }
            logger.debug("Failed to search GIFs: \(error)")
        }
    }
    
    private func loadMoreGifs() async {
        guard let cursor = nextCursor, !isLoadingMore, let query = currentQuery else { return }
        
        await MainActor.run {
            isLoadingMore = true
        }
        
        do {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "https://catbird.blue/tenor/v2/search?q=\(encodedQuery)&limit=20&pos=\(cursor)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TenorSearchResponse.self, from: data)
            
            await MainActor.run {
                // Deduplicate GIFs to avoid showing the same GIF twice
                let existingIDs = Set(self.gifs.map { $0.id })
                let newGifs = response.results.filter { !existingIDs.contains($0.id) }
                
                self.gifs.append(contentsOf: newGifs)
                self.nextCursor = response.next
                self.isLoadingMore = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingMore = false
            }
            logger.debug("Failed to load more GIFs: \(error)")
        }
    }
}

// MARK: - Category Card View

struct CategoryCardView: View {
    let category: TenorCategory
    let onTap: () -> Void
    @State private var featuredGif: TenorGif?
    @State private var isLoadingFeaturedGif = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Group {
                    if let featuredGif = featuredGif {
                        // Show animated GIF for the category
                        AnimatedCategoryGifView(gif: featuredGif)
                    } else if isLoadingFeaturedGif {
                        loadingView
                    } else {
                        // Fallback to static image
                        staticImageView
                    }
                }
                .frame(height: 100) // Slightly taller for better proportions
                .cornerRadius(12)
                .clipped()
                
                Text(category.name)
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
        .task {
            await loadFeaturedGif()
        }
    }
    
    @ViewBuilder
    private var staticImageView: some View {
        LazyImage(url: URL(string: category.image)) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(height: 100)
                    .clipped()
            } else if state.isLoading {
                loadingView
            } else {
                placeholderView
            }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .priority(.normal)
    }
    
    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(platformColor: .platformSystemGray6))
            .frame(height: 100)
            .overlay(
                ProgressView()
                    .controlSize(.regular)
            )
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(platformColor: .platformSystemGray5))
            .frame(height: 100)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .appFont(size: 24)
                        .foregroundColor(.secondary)
                    Text("GIF")
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                }
            )
    }
    
    // Load a featured GIF for this category to show as animated preview
    private func loadFeaturedGif() async {
        isLoadingFeaturedGif = true
        
        do {
            let encodedQuery = category.searchterm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "https://catbird.blue/tenor/v2/search?q=\(encodedQuery)&limit=1")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TenorSearchResponse.self, from: data)
            
            await MainActor.run {
                if let firstGif = response.results.first {
                    self.featuredGif = firstGif
                }
                self.isLoadingFeaturedGif = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingFeaturedGif = false
            }
            // Silently fail and use static image
        }
    }
}

// MARK: - Animated Category GIF View

struct AnimatedCategoryGifView: View {
    let gif: TenorGif
    @State private var player: AVPlayer?
    @State private var hasError = false
    
    var body: some View {
        Group {
            if hasError {
                // Fallback to SimpleGifView if video fails
                SimpleGifView(gif: gif, onTap: {})
                    .disabled(true) // Disable tap for category preview
            } else if let player = player {
                // Use video player for smooth animation like other GIF views
                PlayerLayerView(
                    player: player,
                    gravity: .resizeAspectFill,
                    shouldLoop: true
                )
                .aspectRatio(2.0, contentMode: .fill) // Good category aspect ratio
                .clipped()
            } else {
                // Loading state
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(platformColor: .platformSystemGray6))
                    .overlay(
                        ProgressView()
                            .controlSize(.regular)
                    )
            }
        }
        .onAppear {
            setupVideoPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
    }
    
    private func setupVideoPlayer() {
        guard let videoURL = bestVideoURL else {
            hasError = true
            return
        }
        
        let playerItem = AVPlayerItem(url: videoURL)
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Configure for GIF-like behavior
        avPlayer.isMuted = true // GIFs are silent
        avPlayer.actionAtItemEnd = .none
        
        // Set up looping notification
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            avPlayer.seek(to: .zero)
            avPlayer.play()
        }
        
        // Monitor for player errors
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.hasError = true
        }
        
        self.player = avPlayer
        
        // Start playing immediately
        avPlayer.play()
    }
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Get the best video URL for category animation (prefer smaller sizes for performance)
    private var bestVideoURL: URL? {
        // For categories, prefer smaller video formats for better performance
        if let nanoMP4 = gif.media_formats.nanomp4 {
            return URL(string: nanoMP4.url)
        } else if let tinyMP4 = gif.media_formats.tinymp4 {
            return URL(string: tinyMP4.url)
        } else if let loopedMP4 = gif.media_formats.loopedmp4 {
            return URL(string: loopedMP4.url)
        } else if let mp4 = gif.media_formats.mp4 {
            return URL(string: mp4.url)
        }
        return nil
    }
}

// MARK: - GIF Grid Item View

struct GifGridItemView: View {
    let gif: TenorGif
    let onTap: () -> Void
    
    var body: some View {
        GifVideoView(gif: gif, onTap: onTap)
    }
}
