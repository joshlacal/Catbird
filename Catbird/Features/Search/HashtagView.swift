import SwiftUI
import Petrel

struct HashtagView: View {
    let tag: String
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @State private var posts: [AppBskyFeedDefs.PostView] = []
    @State private var relatedTags: [String] = []
    @State private var isLoading = false
    @State private var cursor: String?
    @State private var sortByRecent = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Enhanced hashtag header
            VStack(spacing: 4) {
                Text("#\(tag)")
                    .font(.title.weight(.bold))
                    .padding(.top)
                
                Text("Posts with this hashtag")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                // Sort toggle
                Picker("Sort", selection: $sortByRecent) {
                    Text("Recent").tag(true)
                    Text("Popular").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: sortByRecent) { _, newValue in
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
                                        .font(.caption)
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
            .padding(.bottom)
            .background(Color(.systemBackground))
            
            // Posts list with improved UI
            if isLoading && posts.isEmpty {
                Spacer()
                ProgressView()
                    .padding()
                    .scaleEffect(1.5)
                Spacer()
            } else if posts.isEmpty {
                emptyState
            } else {
                postsList
            }
        }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if posts.isEmpty {
                loadPosts()
                fetchRelatedTags()
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "number.square.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor.opacity(0.7))
                .padding()
                .symbolEffect(.bounce, options: .repeat(.periodic(1, delay: 3)))
            
            Text("No posts found with #\(tag)")
                .font(.headline)
            
            Text("Be the first to post about this topic!")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                // Open post composer with pre-filled hashtag
                // This would need to be implemented through your app's composer
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
    
    private func loadPosts() {
        isLoading = true
        
        Task {
            do {
                guard let client = appState.atProtoClient else {
                    isLoading = false
                    return
                }
                
                // Search for posts with the hashtag and sort by date if requested
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        sort: sortByRecent ? "recent" : nil,
                        limit: 30
                    )
                )
                
                await MainActor.run {
                    posts = data?.posts ?? []
                    cursor = data?.cursor
                    isLoading = false
                }
            } catch {
                logger.debug("Error loading hashtag posts: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func loadMorePosts() {
        guard let currentCursor = cursor, !isLoading else { return }
        isLoading = true
        
        Task {
            do {
                guard let client = appState.atProtoClient else {
                    isLoading = false
                    return
                }
                
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        sort: sortByRecent ? "recent" : nil,
                        limit: 30,
                        cursor: currentCursor
                    )
                )
                
                await MainActor.run {
                    if let newPosts = data?.posts {
                        posts.append(contentsOf: newPosts)
                    }
                    cursor = data?.cursor
                    isLoading = false
                }
            } catch {
                logger.debug("Error loading more hashtag posts: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func fetchRelatedTags() {
        // Reset current related tags
        relatedTags = []
        
        Task {
            do {
                guard let client = appState.atProtoClient else { return }
                
                // First approach: search for posts with similar tags
                // Note: This is a simplified approach - in a real implementation you would
                // analyze results to find frequently co-occurring hashtags
                
                // Get a few posts with the current hashtag
                let (_, data) = try await client.app.bsky.feed.searchPosts(
                    input: .init(
                        q: "#\(tag)",
                        limit: 10
                    )
                )
                
                // Extract related tags based on post content
                await MainActor.run {
                    // For now, use predefined mappings as a starting point
                    let predefinedRelated = [
                        "technology": ["coding", "tech", "programming", "ai", "development"],
                        "art": ["artwork", "artist", "drawing", "design", "creative"],
                        "photography": ["photo", "camera", "portrait", "landscape", "nature"],
                        "music": ["musician", "song", "band", "album", "concert"],
                        "books": ["reading", "literature", "author", "novel", "writing"],
                        "travel": ["vacation", "wanderlust", "adventure", "explore", "destination"],
                        "food": ["cooking", "recipe", "foodie", "baking", "cuisine"]
                    ]
                    
                    if let related = predefinedRelated[tag.lowercased()] {
                        relatedTags = related
                    } else {
                        // If no predefined tags found, attempt to generate some
                        // In the future, this would analyze post content for co-occurring hashtags
                        let wordLength = tag.count
                        
                        if wordLength <= 3 {
                            // Too short to suggest anything meaningful
                            relatedTags = []
                        } else if tag.hasSuffix("ing") {
                            // For words ending in "ing", suggest related forms
                            var suffixRelated = [String]()
                            
                            let stem = String(tag.dropLast(3))
                            if stem.count >= 3 {
                                suffixRelated.append(stem + "er")
                                suffixRelated.append(stem + "ed")
                                suffixRelated.append(stem)
                            }
                            
                            relatedTags = suffixRelated
                        } else {
                            // Generate some general modifiers
                            var modifierRelated = [String]()
                            modifierRelated.append("best" + tag)
                            modifierRelated.append(tag + "s")
                            
                            // Add year if not already present
                            if !tag.contains("2023") && !tag.contains("2024") && !tag.contains("2025") {
                                modifierRelated.append(tag + "2025")
                            }
                            
                            // Filter out any that match the original tag
                            relatedTags = modifierRelated.filter { $0.lowercased() != tag.lowercased() }
                        }
                    }
                    
                    // In the future: analyze posts to extract commonly co-occurring hashtags
                    // This would require parsing post content and extracting hashtags
                }
            } catch {
                logger.debug("Error fetching related hashtags: \(error)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        HashtagView(tag: "bluesky", path: .constant(NavigationPath()))
            .environment(AppState())
    }
}
