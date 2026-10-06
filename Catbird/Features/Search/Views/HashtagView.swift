import SwiftUI
import Petrel

struct HashtagView: View {
    let tag: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var posts: [AppBskyFeedDefs.PostView] = []
    @State private var relatedTags: [String] = []
    @State private var isLoading = false
    @State private var cursor: String?
    @State private var sortByRecent = true // true for "latest", false for "top"
    @State private var languageFilter: String?
    @State private var showFilterSheet = false
    @State private var loadFailed = false
    @State private var loadGeneration = 0
    
    private static let contentFilterService = ContentFilterService()
    
    var body: some View {
        VStack(spacing: 0) {
            // Enhanced hashtag header
            VStack(spacing: 4) {
                Text("#\(tag)")
                    .appFont(AppTextRole.title1.weight(.bold))
                    .padding(.top)
                
                Text("Posts with this hashtag")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                
                // Sort toggle
                Picker("Sort", selection: $sortByRecent) {
                    Text("Latest").tag(true)
                    Text("Top").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: sortByRecent) { _, _ in
                    // Reset and reload posts with new sort order
                    posts = []
                    cursor = nil
                    loadPosts()
                }
                
                // Related tags if available
                if !relatedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(relatedTags, id: \.self) { relatedTag in
                                Button {
                                    path.append(NavigationDestination.hashtag(relatedTag))
                                } label: {
                                    Text("#\(relatedTag)")
                                        .appFont(AppTextRole.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(Color.accentColor.opacity(0.15))
                                        )
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // Add a filter button
            HStack {
                Spacer()
                Button {
                    showFilterSheet = true
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 4)
            .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            
            // Posts list with improved UI
            if isLoading && posts.isEmpty {
                Spacer()
                ProgressView()
                    .padding()
                    .scaleEffect(1.5)
                Spacer()
            } else if loadFailed && posts.isEmpty {
                loadFailedState
            } else if posts.isEmpty {
                emptyState
            } else {
                postsList
            }
        }
        .navigationTitle("#\(tag)")
#if os(iOS)
    .toolbarTitleDisplayMode(.inline)
#endif
        // Ensure content respects device safe areas even if parent ignores them
        .safeAreaPadding([.top, .bottom])
        .sheet(isPresented: $showFilterSheet) {
            HashtagFilterView(languageFilter: $languageFilter, onApply: {
                posts = []
                cursor = nil
                loadPosts()
            })
        }
        .onAppear {
            if posts.isEmpty {
                loadPosts()
                fetchRelatedTags()
            }
        }
    }
    
    private var loadFailedState: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Posts", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Check your connection and try again.")
        } actions: {
            Button("Try Again") {
                loadPosts()
            }
        }
        .frame(maxHeight: .infinity)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "number.square.fill")
                .appFont(size: 60)
                .foregroundColor(.accentColor.opacity(0.7))
                .padding()
                .symbolEffect(.bounce, options: .repeat(.periodic(1, delay: 3)))
            
            Text("No posts found with #\(tag)")
                .appFont(AppTextRole.headline)
            
            Text("Be the first to post about this topic!")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                sceneContext.presentPostComposer(initialText: "#\(tag) ")
            } label: {
                Label("Create Post with #\(tag)", systemImage: "square.and.pencil")
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.accentColor)
                    )
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .padding()
    }
    
    private var postsList: some View {
        List {
            ForEach(posts, id: \.uri) { post in
                Button {
                    path.append(NavigationDestination.post(post.uri))
                } label: {
                    PostView(
                        post: post,
                        grandparentAuthor: nil,
                        isParentPost: false,
                        isSelectable: true,
                        path: $path,
                        appState: appState
                    )
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }
            
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowSeparator(.hidden)
            } else if let _ = cursor {
                Button {
                    loadMorePosts()
                } label: {
                    Text("Load More")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
    
    private var sortOrder: String {
        sortByRecent ? "latest" : "top"
    }
    
    private var languageCode: LanguageCodeContainer? {
        languageFilter.map { LanguageCodeContainer(languageCode: $0) }
    }
    
    /// Removes posts from muted or blocked accounts, muted words and hidden labels.
    private func applyModeration(to posts: [AppBskyFeedDefs.PostView]) async -> [AppBskyFeedDefs.PostView] {
        let settings = await appState.buildFilterSettings()
        return await Self.contentFilterService.filterPostViews(posts, settings: settings)
    }
    
    private func loadPosts() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadFailed = false
        
        Task {
            guard let client = appState.atProtoClient else {
                isLoading = false
                return
            }
            do {
                let (status, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        sort: sortOrder,
                        lang: languageCode,
                        limit: 30
                    )
                )
                guard generation == loadGeneration else { return }
                guard (200..<300).contains(status), let data else {
                    logger.debug("Hashtag posts request failed with status \(status)")
                    loadFailed = true
                    isLoading = false
                    return
                }
                
                let visiblePosts = await applyModeration(to: data.posts)
                guard generation == loadGeneration else { return }
                posts = visiblePosts
                cursor = data.cursor
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                logger.debug("Error loading hashtag posts: \(error)")
                loadFailed = true
                isLoading = false
            }
        }
    }
    
    private func loadMorePosts() {
        guard let currentCursor = cursor, !isLoading else { return }
        let generation = loadGeneration
        isLoading = true
        
        Task {
            guard let client = appState.atProtoClient else {
                isLoading = false
                return
            }
            do {
                let (status, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        sort: sortOrder,
                        lang: languageCode,
                        limit: 30,
                        cursor: currentCursor
                    )
                )
                guard generation == loadGeneration else { return }
                guard (200..<300).contains(status), let data else {
                    logger.debug("Loading more hashtag posts failed with status \(status)")
                    isLoading = false
                    return
                }
                
                let visiblePosts = await applyModeration(to: data.posts)
                guard generation == loadGeneration else { return }
                let existing = Set(posts.map { $0.uri.uriString() })
                posts.append(contentsOf: visiblePosts.filter { !existing.contains($0.uri.uriString()) })
                cursor = data.cursor
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                logger.debug("Error loading more hashtag posts: \(error)")
                isLoading = false
            }
        }
    }
    
    private func fetchRelatedTags() {
        Task {
            do {
                guard let client = appState.atProtoClient else { return }
                
                // First get posts with the current hashtag
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        limit: 40  // Get a good sample size
                    )
                )
                
                // Extract hashtags from post content
                var hashtagCounts: [String: Int] = [:]
                
                if let posts = data?.posts {
                    for post in posts {
                        if case let .knownType(record) = post.record {
                            if let post = record as? AppBskyFeedPost {
                                let text = post.text
                            // Extract hashtags with regex
                            let pattern = "#([a-zA-Z0-9_]+)"
                            let regex = try? NSRegularExpression(pattern: pattern)
                            
                            if let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                                for match in matches {
                                    if let range = Range(match.range(at: 1), in: text) {
                                        let hashtag = String(text[range]).lowercased()
                                        // Don't count the current tag
                                        if hashtag != tag.lowercased() {
                                            hashtagCounts[hashtag, default: 0] += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                }
                
                // Get the top related tags by frequency
                await MainActor.run {
                    relatedTags = Array(hashtagCounts.sorted { $0.value > $1.value }
                                      .prefix(5)
                                      .map { $0.key })
                    
                    // Fallback if we didn't find any related tags
                    if relatedTags.isEmpty {
                        // Try to find related tags by searching for popular tags in the same general domain
                        findPopularTagsInDomain()
                    }
                }
            } catch {
                logger.debug("Error fetching related hashtags: \(error)")
            }
        }
    }

    // Fallback method to find popular tags in the same domain
    private func findPopularTagsInDomain() {
        Task {
            do {
                guard let client = appState.atProtoClient else { return }
                
                // Use broader search terms based on the current tag
                let searchTerm = getTopicFromTag(tag)
                
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: searchTerm,
                        sort: "top",  // Get top posts for better hashtag discovery
                        limit: 20
                    )
                )
                
                // Extract hashtags from post content
                var hashtagCounts: [String: Int] = [:]
                if let posts = data?.posts {
                    for post in posts {
                        if case let .knownType(record) = post.record {
                            if let post = record as? AppBskyFeedPost {
                                let text = post.text
                                let pattern = "#([a-zA-Z0-9_]+)"
                                let regex = try? NSRegularExpression(pattern: pattern)
                                if let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                                    for match in matches {
                                        if let range = Range(match.range(at: 1), in: text) {
                                            let hashtag = String(text[range]).lowercased()
                                            // Don't count the current tag or the search term if it's a hashtag
                                            if hashtag != tag.lowercased() && (searchTerm.starts(with: "#") ? hashtag != searchTerm.dropFirst().lowercased() : true) {
                                                hashtagCounts[hashtag, default: 0] += 1
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Update UI
                await MainActor.run {
                    // Update relatedTags with results, ensuring not to overwrite if primary search yielded results
                    // This check might be redundant if findPopularTagsInDomain is only called when relatedTags is empty
                    if relatedTags.isEmpty {
                         relatedTags = Array(hashtagCounts.sorted { $0.value > $1.value }
                                      .prefix(5)
                                      .map { $0.key })
                    }
                }
            } catch {
                logger.debug("Error finding popular domain tags: \(error)")
            }
        }
    }

    // Helper to get broader topic from specific tag
    private func getTopicFromTag(_ tag: String) -> String {
        // Map common subtopics to broader topics
        let topicMappings = [
            "javascript": "programming",
            "typescript": "programming",
            "swiftui": "ios",
            "uikit": "ios"
        ]
        
        return topicMappings[tag.lowercased()] ?? tag
    }
}

// Simple filter view
struct HashtagFilterView: View {
    @Binding var languageFilter: String?
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Edited locally so Cancel leaves the applied language untouched.
    @State private var draftLanguage: String?
    
    init(languageFilter: Binding<String?>, onApply: @escaping () -> Void) {
        self._languageFilter = languageFilter
        self.onApply = onApply
        self._draftLanguage = State(initialValue: languageFilter.wrappedValue)
    }
    
    // Define a list of common languages
    private let languages = [
        (name: "Any", code: nil as String?),
        (name: "English", code: "en" as String?),
        (name: "Spanish", code: "es" as String?),
        (name: "Japanese", code: "ja" as String?),
        (name: "German", code: "de" as String?),
        (name: "French", code: "fr" as String?),
        (name: "Portuguese", code: "pt" as String?),
        (name: "Italian", code: "it" as String?),
        (name: "Russian", code: "ru" as String?),
        (name: "Korean", code: "ko" as String?),
        (name: "Chinese", code: "zh" as String?)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Language") {
                    Picker("Language", selection: $draftLanguage) {
                        ForEach(languages, id: \.name) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }
            }
            .navigationTitle("Filter Posts")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        languageFilter = draftLanguage
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            HashtagView(tag: "bluesky", path: .constant(NavigationPath()))
        }
  }
}

