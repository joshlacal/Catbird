import SwiftUI
import NukeUI
import Petrel

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
    @State private var selectedCategory: TenorCategory?
    @State private var showingSearch = false
    @State private var showingSuggestions = false
    @State private var searchTask: Task<Void, Never>?
    
    let onGifSelected: (TenorGif) -> Void
    
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 0.5)
                .padding(.top, 16)
        }
    }
    
    // MARK: - Categories Section
    
    private var categoriesSection: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 12) {
                ForEach(categories) { category in
                    CategoryCardView(category: category) {
                        Task {
                            await searchGifs(query: category.searchterm)
                            showingSearch = true
                        }
                    }
                }
            }
            .padding(16)
        }
    }
    
    // MARK: - Suggestions Section
    
    private var suggestionsSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
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
        .background(Color(.systemBackground))
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
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 4) {
                ForEach(gifs) { gif in
                    GifGridItemView(gif: gif) {
                        onGifSelected(gif)
                        dismiss()
                    }
                }
            }
            .padding(8)
        }
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
            print("Failed to load categories: \(error)")
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
                print("Autocomplete API returned status code: \(httpResponse.statusCode)")
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
            print("Failed to load suggestions for '\(query)': \(error)")
        }
    }
    
    private func searchGifs(query: String) async {
        guard !query.isEmpty else { return }
        
        await MainActor.run {
            isLoading = true
            showingSuggestions = false
        }
        
        do {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "https://catbird.blue/tenor/v2/search?q=\(encodedQuery)&limit=20")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TenorSearchResponse.self, from: data)
            
            await MainActor.run {
                self.gifs = response.results
                self.isLoading = false
                self.showingSearch = true
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
            }
            print("Failed to search GIFs: \(error)")
        }
    }
}

// MARK: - Category Card View

struct CategoryCardView: View {
    let category: TenorCategory
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                LazyImage(url: URL(string: category.image)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(height: 80)
                            .clipped()
                    } else if state.isLoading {
                        ProgressView()
                            .frame(height: 80)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(height: 80)
                    }
                }
                .cornerRadius(8)
                
                Text(category.name)
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - GIF Grid Item View

struct GifGridItemView: View {
    let gif: TenorGif
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            LazyImage(url: gifPreviewURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipped()
                } else if state.isLoading {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                        .frame(height: 120)
                        .overlay(
                            ProgressView()
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(height: 120)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        )
                }
            }
            .cornerRadius(8)
            .overlay(
                // GIF indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("GIF")
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var gifPreviewURL: URL? {
        // Use the best animated GIF URL for preview - prioritize medium quality for better animation
        if let mediumgif = gif.media_formats.mediumgif {
            return URL(string: mediumgif.url)
        } else if let gif = gif.media_formats.gif {
            return URL(string: gif.url)
        } else if let tinygif = gif.media_formats.tinygif {
            return URL(string: tinygif.url)
        } else if let nanogif = gif.media_formats.nanogif {
            return URL(string: nanogif.url)
        }
        return nil
    }
}