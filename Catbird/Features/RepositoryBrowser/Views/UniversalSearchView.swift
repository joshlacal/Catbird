import SwiftUI
import SwiftData

// MARK: - ⚠️ EXPERIMENTAL UNIVERSAL SEARCH ⚠️

/// 🧪 EXPERIMENTAL: Universal search across all repository data types
/// ⚠️ This searches experimental parsing results across posts, connections, and media
struct RepositoryUniversalSearchView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: UniversalSearchViewModel
    @State private var selectedSearchResult: SearchResult?
    @State private var showingAdvancedSearch = false
    
    init(repository: RepositoryRecord) {
        self.repository = repository
        self._viewModel = State(wrappedValue: UniversalSearchViewModel(repositoryID: repository.id))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Experimental warning header
                ExperimentalSearchHeader(repository: repository)
                    .background(Color(UIColor.systemGroupedBackground))
                
                // Search content
                if viewModel.searchQuery.isEmpty {
                    searchSuggestionsView
                } else if viewModel.isSearching {
                    searchLoadingView
                } else if viewModel.searchResults.isEmpty {
                    emptySearchView
                } else {
                    searchResultsView
                }
            }
            .navigationTitle("Universal Search")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Advanced Search", systemImage: "magnifyingglass.circle") {
                            showingAdvancedSearch = true
                        }
                        
                        Button("Clear History", systemImage: "trash") {
                            viewModel.clearSearchHistory()
                        }
                        
                        Picker("Result Type", selection: $viewModel.resultTypeFilter) {
                            ForEach(SearchResultType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        
                        Picker("Sort Order", selection: $viewModel.sortOrder) {
                            ForEach(SearchSortOrder.allCases, id: \.self) { order in
                                Label(order.displayName, systemImage: order.systemImage).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search across all data...")
            .onSubmit(of: .search) {
                viewModel.performSearch()
            }
            .onChange(of: viewModel.searchQuery) { _, newValue in
                if !newValue.isEmpty && newValue.count >= 2 {
                    viewModel.performSearchWithDelay()
                }
            }
            .sheet(isPresented: $showingAdvancedSearch) {
                AdvancedSearchView(viewModel: viewModel)
            }
            .sheet(item: $selectedSearchResult) { result in
                SearchResultDetailView(result: result, repository: repository)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
    }
    
    // MARK: - Search Suggestions View
    
    private var searchSuggestionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Search tips
                VStack(alignment: .leading, spacing: 12) {
                    Text("Search Tips")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        SearchTipRow(icon: "text.quote", tip: "Search post content", example: "hello world")
                        SearchTipRow(icon: "person.2", tip: "Find connections", example: "did:plc:")
                        SearchTipRow(icon: "photo", tip: "Media alt text", example: "sunset")
                        SearchTipRow(icon: "calendar", tip: "Date ranges", example: "2024-01-01")
                        SearchTipRow(icon: "hashtag", tip: "Record keys", example: "3k")
                    }
                }
                
                // Recent searches
                if !viewModel.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Searches")
                            .font(.headline)
                        
                        ForEach(viewModel.searchHistory, id: \.self) { query in
                            Button(action: {
                                viewModel.searchQuery = query
                                viewModel.performSearch()
                            }) {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundColor(.secondary)
                                    Text(query)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                
                // Quick stats
                VStack(alignment: .leading, spacing: 12) {
                    Text("Repository Stats")
                        .font(.headline)
                    
                    HStack(spacing: 16) {
                        QuickStatView(label: "Posts", value: "\(repository.postCount)", icon: "text.bubble")
                        QuickStatView(label: "Connections", value: "\(repository.connectionCount)", icon: "person.2")
                        QuickStatView(label: "Media", value: "\(repository.mediaCount)", icon: "photo")
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Search Loading View
    
    private var searchLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
            
            Text("Searching...")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Scanning \(repository.totalRecordCount) records")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Empty Search View
    
    private var emptySearchView: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Results")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("No results found for \"\(viewModel.searchQuery)\"\n\nTry adjusting your search terms or using the advanced search options.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Advanced Search") {
                showingAdvancedSearch = true
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Search Results View
    
    private var searchResultsView: some View {
        List {
            // Results summary
            Section {
                SearchSummaryView(viewModel: viewModel)
            }
            
            // Results by type
            ForEach(viewModel.groupedResults, id: \.type) { group in
                Section(header: SearchResultTypeHeader(type: group.type, count: group.results.count)) {
                    ForEach(group.results, id: \.id) { result in
                        RepoSearchResultRow(result: result) {
                            selectedSearchResult = result
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Universal Search ViewModel

@MainActor
@Observable
final class UniversalSearchViewModel {
    private let repositoryID: UUID
    private var modelContext: ModelContext?
    private var searchTask: Task<Void, Never>?
    
    var searchQuery = ""
    var isSearching = false
    var searchResults: [SearchResult] = []
    var searchHistory: [String] = []
    var resultTypeFilter: SearchResultType = .all
    var sortOrder: SearchSortOrder = .relevance
    
    // Advanced search options
    var dateRangeStart: Date?
    var dateRangeEnd: Date?
    var confidenceThreshold: Double = 0.0
    var includeParseErrors = false
    
    init(repositoryID: UUID) {
        self.repositoryID = repositoryID
        loadSearchHistory()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    var groupedResults: [SearchResultGroup] {
        let filtered = filteredResults
        let grouped = Dictionary(grouping: filtered) { $0.type }
        
        return SearchResultType.allCases.compactMap { type in
            guard let results = grouped[type], !results.isEmpty else { return nil }
            return SearchResultGroup(type: type, results: results)
        }
    }
    
    private var filteredResults: [SearchResult] {
        var filtered = searchResults
        
        // Apply result type filter
        if resultTypeFilter != .all {
            filtered = filtered.filter { $0.type == resultTypeFilter }
        }
        
        // Apply date range filter
        if let startDate = dateRangeStart {
            filtered = filtered.filter { $0.date >= startDate }
        }
        
        if let endDate = dateRangeEnd {
            filtered = filtered.filter { $0.date <= endDate }
        }
        
        // Apply confidence filter
        if confidenceThreshold > 0 {
            filtered = filtered.filter { $0.confidence >= confidenceThreshold }
        }
        
        // Apply parse error filter
        if !includeParseErrors {
            filtered = filtered.filter { $0.parseSuccessful }
        }
        
        // Apply sort order
        switch sortOrder {
        case .relevance:
            // Keep original relevance order
            break
        case .dateAscending:
            filtered.sort { $0.date < $1.date }
        case .dateDescending:
            filtered.sort { $0.date > $1.date }
        case .confidence:
            filtered.sort { $0.confidence > $1.confidence }
        case .type:
            filtered.sort { $0.type.rawValue < $1.type.rawValue }
        }
        
        return filtered
    }
    
    func performSearch() {
        guard !searchQuery.isEmpty, let modelContext = modelContext else {
            searchResults = []
            return
        }
        
        addToSearchHistory(searchQuery)
        
        searchTask?.cancel()
        
        searchTask = Task { @MainActor in
            isSearching = true
            searchResults = []
            
            do {
                let results = try await performUniversalSearch(query: searchQuery, context: modelContext)
                if !Task.isCancelled {
                    searchResults = results
                }
            } catch {
                print("Search error: \(error)")
                searchResults = []
            }
            
            isSearching = false
        }
    }
    
    func performSearchWithDelay() {
        searchTask?.cancel()
        
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            
            if !Task.isCancelled {
                performSearch()
            }
        }
    }
    
    private func performUniversalSearch(query: String, context: ModelContext) async throws -> [SearchResult] {
        var allResults: [SearchResult] = []
        
        // Search posts
        let postDescriptor = FetchDescriptor<ParsedPost>()
        let allPosts = try context.fetch(postDescriptor)
        let posts = allPosts.filter { post in
            post.repositoryRecordID == repositoryID &&
            (post.text.localizedStandardContains(query) ||
             post.recordKey.localizedStandardContains(query))
        }
        allResults.append(contentsOf: posts.map { post in
            SearchResult(
                id: post.id,
                type: .post,
                title: String(post.text.prefix(100)),
                subtitle: post.postType,
                content: post.text,
                date: post.createdAt,
                confidence: post.parseConfidence,
                parseSuccessful: post.parseSuccessful,
                recordKey: post.recordKey,
                originalObject: .post(post)
            )
        })
        
        // Search connections
        let connectionDescriptor = FetchDescriptor<ParsedConnection>()
        let allConnections = try context.fetch(connectionDescriptor)
        let connections = allConnections.filter { connection in
            connection.repositoryRecordID == repositoryID &&
            (connection.targetUserDID.localizedStandardContains(query) ||
             connection.recordKey.localizedStandardContains(query))
        }
        allResults.append(contentsOf: connections.map { connection in
            SearchResult(
                id: connection.id,
                type: .connection,
                title: connection.targetUserDID,
                subtitle: connection.connectionType.capitalized,
                content: "Connection to \(connection.targetUserDID)",
                date: connection.createdAt,
                confidence: connection.parseConfidence,
                parseSuccessful: connection.parseSuccessful,
                recordKey: connection.recordKey,
                originalObject: .connection(connection)
            )
        })
        
        // Search media
        let mediaDescriptor = FetchDescriptor<ParsedMedia>()
        let allMediaItems = try context.fetch(mediaDescriptor)
        let mediaItems = allMediaItems.filter { media in
            media.repositoryRecordID == repositoryID &&
            (media.altText?.localizedStandardContains(query) == true ||
             media.mediaType.localizedStandardContains(query) ||
             media.mimeType?.localizedStandardContains(query) == true ||
             media.recordKey.localizedStandardContains(query))
        }
        allResults.append(contentsOf: mediaItems.map { media in
            SearchResult(
                id: media.id,
                type: .media,
                title: media.altText ?? media.mediaType,
                subtitle: media.mimeType ?? "Unknown type",
                content: media.altText ?? "Media attachment",
                date: media.discoveredAt,
                confidence: media.parseConfidence,
                parseSuccessful: media.parseSuccessful,
                recordKey: media.recordKey,
                originalObject: .media(media)
            )
        })
        
        // Search profiles
        let profileDescriptor = FetchDescriptor<ParsedProfile>()
        let allProfiles = try context.fetch(profileDescriptor)
        let profiles = allProfiles.filter { profile in
            profile.repositoryRecordID == repositoryID &&
            (profile.displayName?.localizedStandardContains(query) == true ||
             profile.profileDescription?.localizedStandardContains(query) == true ||
             profile.recordKey.localizedStandardContains(query))
        }
        allResults.append(contentsOf: profiles.map { profile in
            SearchResult(
                id: profile.id,
                type: .profile,
                title: profile.displayName ?? "Profile",
                subtitle: "Profile information",
                content: profile.profileDescription ?? "User profile",
                date: profile.updatedAt,
                confidence: profile.parseConfidence,
                parseSuccessful: profile.parseSuccessful,
                recordKey: profile.recordKey,
                originalObject: .profile(profile)
            )
        })
        
        // Sort by advanced relevance scoring algorithm
        return allResults.sorted { result1, result2 in
            let score1 = calculateAdvancedRelevanceScore(for: result1, query: query)
            let score2 = calculateAdvancedRelevanceScore(for: result2, query: query)
            return score1 > score2
        }
    }
    
    private func calculateRelevanceScore(for result: SearchResult, query: String) -> Double {
        let queryLower = query.lowercased()
        var score: Double = 0
        
        // Title match (highest weight)
        if result.title.lowercased().contains(queryLower) {
            score += 10
            if result.title.lowercased().hasPrefix(queryLower) {
                score += 5
            }
        }
        
        // Content match
        if result.content.lowercased().contains(queryLower) {
            score += 5
        }
        
        // Subtitle match
        if result.subtitle.lowercased().contains(queryLower) {
            score += 3
        }
        
        // Confidence bonus
        score += result.confidence * 2
        
        // Recency bonus (more recent = higher score)
        let daysSinceDate = Date().timeIntervalSince(result.date) / (24 * 60 * 60)
        if daysSinceDate < 30 {
            score += max(0, 5 - (daysSinceDate / 6)) // Up to 5 points for recent items
        }
        
        return score
    }
    
    private func calculateAdvancedRelevanceScore(for result: SearchResult, query: String) -> Double {
        let queryLower = query.lowercased()
        let queryWords = queryLower.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var score: Double = 0
        
        // 1. TF-IDF Style Term Frequency Scoring
        let allText = "\(result.title) \(result.content) \(result.subtitle)".lowercased()
        let textWords = allText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        for queryWord in queryWords {
            let termFrequency = Double(textWords.filter { $0.contains(queryWord) }.count)
            if termFrequency > 0 {
                // Logarithmic TF scoring to reduce impact of excessive repetition
                let tfScore = 1.0 + log(termFrequency)
                
                // Field-specific boosting
                if result.title.lowercased().contains(queryWord) {
                    score += tfScore * 15.0 // High weight for title matches
                    
                    // Exact match bonus for title
                    if result.title.lowercased() == queryWord {
                        score += 25.0
                    }
                    
                    // Prefix match bonus for title
                    if result.title.lowercased().hasPrefix(queryWord) {
                        score += 10.0
                    }
                }
                
                if result.content.lowercased().contains(queryWord) {
                    score += tfScore * 8.0 // Medium weight for content matches
                }
                
                if result.subtitle.lowercased().contains(queryWord) {
                    score += tfScore * 5.0 // Lower weight for subtitle matches
                }
            }
        }
        
        // 2. Fuzzy Matching for Typo Tolerance
        for queryWord in queryWords {
            if queryWord.count >= 3 { // Only apply fuzzy matching for words 3+ characters
                let fuzzyMatches = textWords.filter { textWord in
                    levenshteinDistance(queryWord, textWord) <= max(1, queryWord.count / 4)
                }
                
                for match in fuzzyMatches {
                    let distance = levenshteinDistance(queryWord, match)
                    let fuzzyScore = max(0, 3.0 - Double(distance)) // Decreasing score based on edit distance
                    score += fuzzyScore
                }
            }
        }
        
        // 3. Semantic Proximity Scoring
        let queryPhrase = queryWords.joined(separator: " ")
        if allText.localizedStandardContains(queryPhrase) {
            score += 20.0 // Bonus for exact phrase matches
        }
        
        // Word order proximity bonus
        if queryWords.count > 1 {
            let proximityScore = calculateWordProximity(queryWords: queryWords, in: textWords)
            score += proximityScore * 5.0
        }
        
        // 4. Document Quality Factors
        
        // Parse confidence bonus (higher quality parsing = more reliable content)
        score += result.confidence * 8.0
        
        // Content completeness bonus
        let contentLength = result.content.count
        let lengthBonus = min(5.0, Double(contentLength) / 100.0) // Up to 5 points for substantial content
        score += lengthBonus
        
        // Record type boost (some types may be more valuable)
        switch result.type {
        case .post:
            score += 2.0 // Posts are generally important
        case .profile:
            score += 4.0 // Profiles often searched for specifically  
        case .connection:
            score += 1.0 // Connections less commonly primary search target
        case .media:
            score += 3.0 // Media files often specifically sought
        case .all:
            break // No specific bonus
        }
        
        // 5. Recency Scoring with More Granular Control
        let daysSinceDate = Date().timeIntervalSince(result.date) / (24 * 60 * 60)
        if daysSinceDate < 1 {
            score += 12.0 // Very recent (last day)
        } else if daysSinceDate < 7 {
            score += 8.0 // Recent (last week)
        } else if daysSinceDate < 30 {
            score += 4.0 // Somewhat recent (last month)
        } else if daysSinceDate < 90 {
            score += 2.0 // Moderately recent (last quarter)
        }
        // No recency bonus for older content
        
        // 6. Query Length Adjustment
        // Longer queries should have higher precision requirements
        if queryWords.count > 3 {
            score *= 1.2 // Boost precision for complex queries
        }
        
        // 7. Document Length Normalization
        // Prevent very long documents from getting artificially high scores
        let wordCount = Double(textWords.count)
        if wordCount > 100 {
            let normalizationFactor = log(wordCount) / log(100.0)
            score /= normalizationFactor
        }
        
        return max(0, score) // Ensure no negative scores
    }
    
    // Helper function to calculate Levenshtein distance for fuzzy matching
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let s1Length = s1Array.count
        let s2Length = s2Array.count
        
        if s1Length == 0 { return s2Length }
        if s2Length == 0 { return s1Length }
        
        var matrix = Array(repeating: Array(repeating: 0, count: s2Length + 1), count: s1Length + 1)
        
        for i in 0...s1Length {
            matrix[i][0] = i
        }
        
        for j in 0...s2Length {
            matrix[0][j] = j
        }
        
        for i in 1...s1Length {
            for j in 1...s2Length {
                let cost = s1Array[i-1] == s2Array[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,      // deletion
                    matrix[i][j-1] + 1,      // insertion
                    matrix[i-1][j-1] + cost  // substitution
                )
            }
        }
        
        return matrix[s1Length][s2Length]
    }
    
    // Helper function to calculate word proximity scoring
    private func calculateWordProximity(queryWords: [String], in textWords: [String]) -> Double {
        var proximityScore: Double = 0
        
        for i in 0..<(queryWords.count - 1) {
            let word1 = queryWords[i]
            let word2 = queryWords[i + 1]
            
            // Find positions of both words in text
            let positions1 = textWords.enumerated().compactMap { $1.contains(word1) ? $0 : nil }
            let positions2 = textWords.enumerated().compactMap { $1.contains(word2) ? $0 : nil }
            
            // Calculate minimum distance between any occurrence of word1 and word2
            var minDistance = Int.max
            for pos1 in positions1 {
                for pos2 in positions2 {
                    minDistance = min(minDistance, abs(pos2 - pos1))
                }
            }
            
            if minDistance != Int.max {
                // Closer words get higher proximity scores
                let distance = Double(minDistance)
                proximityScore += max(0, 5.0 - distance) // Max 5 points when adjacent
            }
        }
        
        return proximityScore
    }
    
    private func addToSearchHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !searchHistory.contains(trimmed) else { return }
        
        searchHistory.insert(trimmed, at: 0)
        
        // Keep only the last 10 searches
        if searchHistory.count > 10 {
            searchHistory = Array(searchHistory.prefix(10))
        }
        
        saveSearchHistory()
    }
    
    func clearSearchHistory() {
        searchHistory = []
        saveSearchHistory()
    }
    
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: "RepositorySearchHistory") ?? []
    }
    
    private func saveSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: "RepositorySearchHistory")
    }
}

// MARK: - Supporting Views

private struct ExperimentalSearchHeader: View {
    let repository: RepositoryRecord
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("🧪 EXPERIMENTAL UNIVERSAL SEARCH")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text("Search across all parsed data from \(repository.userHandle)'s repository. Results may be incomplete.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding()
    }
}

private struct SearchTipRow: View {
    let icon: String
    let tip: String
    let example: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(tip)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text("e.g. \"\(example)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

private struct QuickStatView: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
            
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SearchSummaryView: View {
    var viewModel: UniversalSearchViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Found \(viewModel.searchResults.count) results")
                .font(.headline)
                .fontWeight(.semibold)
            
            HStack {
                ForEach(SearchResultType.allCases.filter { $0 != .all }, id: \.self) { type in
                    let count = viewModel.searchResults.filter { $0.type == type }.count
                    if count > 0 {
                        SearchTypeTag(type: type, count: count)
                    }
                }
            }
        }
    }
}

private struct SearchTypeTag: View {
    let type: SearchResultType
    let count: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.systemImage)
                .font(.caption2)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(type.color.opacity(0.2))
        .foregroundColor(type.color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SearchResultTypeHeader: View {
    let type: SearchResultType
    let count: Int
    
    var body: some View {
        HStack {
            Image(systemName: type.systemImage)
                .foregroundColor(type.color)
            Text("\(type.displayName) (\(count))")
                .fontWeight(.semibold)
        }
    }
}

private struct RepoSearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: result.type.systemImage)
                        .foregroundColor(result.type.color)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        ConfidenceBadge(confidence: result.confidence)
                        
                        if !result.parseSuccessful {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                }
                
                Text(result.content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                
                Text(result.date, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Advanced Search View

private struct AdvancedSearchView: View {
    var viewModel: UniversalSearchViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Date Range") {
                    DatePicker("Start Date", selection: Binding(
                        get: { viewModel.dateRangeStart ?? Date.distantPast },
                        set: { viewModel.dateRangeStart = $0 }
                    ), displayedComponents: .date)
                    
                    DatePicker("End Date", selection: Binding(
                        get: { viewModel.dateRangeEnd ?? Date() },
                        set: { viewModel.dateRangeEnd = $0 }
                    ), displayedComponents: .date)
                }
                
                Section("Filters") {
                    Picker("Result Type", selection: Binding(
                        get: { viewModel.resultTypeFilter },
                        set: { viewModel.resultTypeFilter = $0 }
                    )) {
                        ForEach(SearchResultType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confidence Threshold: \(Int(viewModel.confidenceThreshold * 100))%")
                            .font(.caption)
                        
                        Slider(value: Binding(
                            get: { viewModel.confidenceThreshold },
                            set: { viewModel.confidenceThreshold = $0 }
                        ), in: 0...1, step: 0.1)
                    }
                    
                    Toggle("Include Parse Errors", isOn: Binding(
                        get: { viewModel.includeParseErrors },
                        set: { viewModel.includeParseErrors = $0 }
                    ))
                }
                
                Section("Sort Order") {
                    Picker("Sort by", selection: Binding(
                        get: { viewModel.sortOrder },
                        set: { viewModel.sortOrder = $0 }
                    )) {
                        ForEach(SearchSortOrder.allCases, id: \.self) { order in
                            Label(order.displayName, systemImage: order.systemImage).tag(order)
                        }
                    }
                }
            }
            .navigationTitle("Advanced Search")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        viewModel.dateRangeStart = nil
                        viewModel.dateRangeEnd = nil
                        viewModel.confidenceThreshold = 0.0
                        viewModel.includeParseErrors = false
                        viewModel.resultTypeFilter = .all
                        viewModel.sortOrder = .relevance
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Search Result Detail View

private struct SearchResultDetailView: View {
    let result: SearchResult
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Result header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: result.type.systemImage)
                                .foregroundColor(result.type.color)
                            
                            Text(result.type.displayName)
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        
                        Text(result.date, style: .relative)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Content
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content")
                            .font(.headline)
                        
                        Text(result.content)
                            .font(.body)
                            .padding()
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Metadata")
                            .font(.headline)
                        
                        SearchResultMetadataGrid(result: result)
                    }
                }
                .padding()
            }
            .navigationTitle("Search Result")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SearchResultMetadataGrid: View {
    let result: SearchResult
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            MetadataItem(label: "Type", value: result.type.displayName)
            MetadataItem(label: "Record Key", value: result.recordKey)
            MetadataItem(label: "Confidence", value: String(format: "%.1f%%", result.confidence * 100))
            MetadataItem(label: "Parse Status", value: result.parseSuccessful ? "Success" : "Failed")
        }
    }
}

// MARK: - Supporting Types

struct SearchResult: Identifiable {
    let id: UUID
    let type: SearchResultType
    let title: String
    let subtitle: String
    let content: String
    let date: Date
    let confidence: Double
    let parseSuccessful: Bool
    let recordKey: String
    let originalObject: SearchResultObject
}

enum SearchResultObject {
    case post(ParsedPost)
    case connection(ParsedConnection)
    case media(ParsedMedia)
    case profile(ParsedProfile)
}

enum SearchResultType: String, CaseIterable {
    case all = "all"
    case post = "post"
    case connection = "connection"
    case media = "media"
    case profile = "profile"
    
    var displayName: String {
        switch self {
        case .all:
            return "All Types"
        case .post:
            return "Posts"
        case .connection:
            return "Connections"
        case .media:
            return "Media"
        case .profile:
            return "Profiles"
        }
    }
    
    var systemImage: String {
        switch self {
        case .all:
            return "magnifyingglass"
        case .post:
            return "text.bubble"
        case .connection:
            return "person.2"
        case .media:
            return "photo"
        case .profile:
            return "person.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .all:
            return .primary
        case .post:
            return .blue
        case .connection:
            return .green
        case .media:
            return .purple
        case .profile:
            return .orange
        }
    }
}

struct SearchResultGroup {
    let type: SearchResultType
    let results: [SearchResult]
}

enum SearchSortOrder: String, CaseIterable {
    case relevance = "relevance"
    case dateAscending = "date_asc"
    case dateDescending = "date_desc"
    case confidence = "confidence"
    case type = "type"
    
    var displayName: String {
        switch self {
        case .relevance:
            return "Relevance"
        case .dateAscending:
            return "Oldest First"
        case .dateDescending:
            return "Newest First"
        case .confidence:
            return "Parse Confidence"
        case .type:
            return "Result Type"
        }
    }
    
    var systemImage: String {
        switch self {
        case .relevance:
            return "star"
        case .dateAscending:
            return "arrow.up"
        case .dateDescending:
            return "arrow.down"
        case .confidence:
            return "checkmark.circle"
        case .type:
            return "textformat"
        }
    }
}

// Reuse components
private struct ConfidenceBadge: View {
    let confidence: Double
    
    private var color: Color {
        if confidence >= 0.9 {
            return .green
        } else if confidence >= 0.7 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        Text(String(format: "%.0f%%", confidence * 100))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct MetadataItem: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    return RepositoryUniversalSearchView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedPost.self, ParsedConnection.self, ParsedMedia.self, ParsedProfile.self], inMemory: true)
}
