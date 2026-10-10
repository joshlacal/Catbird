import OSLog
import Petrel
import SwiftUI
struct HashtagView: View {
    let tag: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    private static let hashtagRegex = try? NSRegularExpression(pattern: "#([a-zA-Z0-9_]+)")
    var body: some View {
        postsList
            .navigationTitle("#\(tag)")
            .modifier(HashtagNavigationTitleModifier())
            .safeAreaPadding([.top, .bottom])
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label("Language", systemImage: languageFilter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter by language, \(languageFilterName)")
                    .accessibilityIdentifier("hashtag.languageFilter")
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                HashtagFilterView(languageFilter: $languageFilter, onApply: reloadPosts)
            }
            .onChange(of: sortByRecent) { _, _ in
                reloadPosts()
            }
            .onAppear {
                if posts.isEmpty {
                    loadPosts()
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            sortPicker
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("hashtag.sort")

            if languageFilter != nil {
                Button {
                    showFilterSheet = true
                } label: {
                    Label("Language: \(languageFilterName)", systemImage: "line.3.horizontal.decrease")
                        .appFont(AppTextRole.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if !relatedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(relatedTags, id: \.self) { relatedTag in
                            Button {
                                path.append(NavigationDestination.hashtag(relatedTag))
                            } label: {
                                Text("#\(relatedTag)")
                                    .appFont(AppTextRole.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityLabel("Related hashtags")
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sortPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            sortOptions.pickerStyle(.menu)
        } else {
            #if compiler(>=6.4)
            if #available(anyAppleOS 27.0, *), !reduceTransparency {
                sortOptions
                    .buttonBorderShape(.capsule)
                    .pickerStyle(.tabs)
            } else {
                sortOptions.pickerStyle(.segmented)
            }
            #else
            sortOptions.pickerStyle(.segmented)
            #endif
        }
    }

    private var sortOptions: some View {
        Picker("Sort posts", selection: $sortByRecent) {
            Text("Latest").tag(true)
            Text("Top").tag(false)
        }
    }

    private var languageFilterName: String {
        guard let languageFilter else { return "Any language" }
        return Locale.current.localizedString(forLanguageCode: languageFilter) ?? languageFilter
    }

    private func reloadPosts() {
        posts = []
        cursor = nil
        loadPosts()
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
        .padding(.vertical, 24)
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No matching posts", systemImage: "number")
        } description: {
            if cursor != nil {
                Text("There are no visible matches on this page. Load more to keep looking.")
            } else if languageFilter != nil {
                Text("No visible posts matching #\(tag) in \(languageFilterName) are available.")
            } else {
                Text("No visible posts matching #\(tag) are available.")
            }
        } actions: {
            if languageFilter != nil {
                Button("Change Language") {
                    showFilterSheet = true
                }
            }
            Button {
                sceneContext.presentPostComposer(initialText: "#\(tag) ")
            } label: {
                Label("Create Post", systemImage: "square.and.pencil")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 24)
    }

    private var postsList: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowBackground(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))

            if isLoading && posts.isEmpty {
                ProgressView("Loading posts")
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .listRowSeparator(.hidden)
            } else if loadFailed && posts.isEmpty {
                loadFailedState
                    .listRowSeparator(.hidden)
            } else if posts.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            }

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
            
            if isLoading && !posts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowSeparator(.hidden)
            } else if !isLoading, cursor != nil {
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
        .accessibilityIdentifier("hashtag.posts")
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
        let isInitial = posts.isEmpty
        isLoading = true
        loadFailed = false
        
        Task {
            let signpost = isInitial ? PerformanceSignposts.beginInterval("HashtagOpen") : nil
            defer {
                if let signpost {
                    PerformanceSignposts.endInterval("HashtagOpen", signpost)
                }
            }
            guard generation == loadGeneration else { return }
            guard let client = appState.atProtoClient else {
                loadFailed = true
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
                
                let related = Self.relatedTags(from: data.posts, excluding: tag)
                relatedTags = related
                if related.isEmpty {
                    findPopularTagsInDomain()
                }
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
    
    nonisolated static func relatedTags(from posts: [AppBskyFeedDefs.PostView], excluding currentTag: String) -> [String] {
        var hashtagCounts: [String: Int] = [:]
        let excluded = currentTag.lowercased()
        
        for post in posts {
            guard case let .knownType(record) = post.record,
                  let feedPost = record as? AppBskyFeedPost else { continue }
            var postTags = Set<String>()
            if let facets = feedPost.facets {
                for facet in facets {
                    for feature in facet.features {
                        if case .appBskyRichtextFacetTag(let tagFeature) = feature {
                            let candidate = tagFeature.tag.lowercased()
                            if candidate != excluded {
                                postTags.insert(candidate)
                            }
                        }
                    }
                }
            }
            if postTags.isEmpty, let regex = hashtagRegex {
                let text = feedPost.text
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: text) {
                        let candidate = String(text[range]).lowercased()
                        if candidate != excluded {
                            postTags.insert(candidate)
                        }
                    }
                }
            }
            for tag in postTags {
                hashtagCounts[tag, default: 0] += 1
            }
        }
        
        return Array(hashtagCounts.sorted { $0.value > $1.value }.prefix(5).map { $0.key })
    }

    // Fallback method to find popular tags in the same domain when initial search yields no tags
    private func findPopularTagsInDomain() {
        Task {
            do {
                guard let client = appState.atProtoClient else { return }
                let searchTerm = getTopicFromTag(tag)
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: searchTerm,
                        sort: "top",
                        limit: 20
                    )
                )
                if let posts = data?.posts {
                    let tags = Self.relatedTags(from: posts, excluding: tag)
                    if !tags.isEmpty {
                        await MainActor.run {
                            if relatedTags.isEmpty {
                                relatedTags = tags
                            }
                        }
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

private struct HashtagNavigationTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbarTitleDisplayMode(.inline)
        #else
        content
        #endif
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
            .navigationTitle("Post Language")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if languageFilter != draftLanguage {
                            languageFilter = draftLanguage
                            onApply()
                        }
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

