import Foundation

extension FeedManager {
    /// Batch precompute embeddings for a set of cached posts.
    func precomputeEmbeddings(for posts: [CachedFeedViewPost]) async {
        await FeedEmbeddings.shared.embedPosts(posts)
    }

    /// Semantic search across provided cached posts.
    func semanticSearch(_ query: String, in posts: [CachedFeedViewPost], topK: Int = 20) async -> [CachedFeedViewPost] {
        await FeedEmbeddings.shared.semanticSearch(query: query, in: posts, topK: topK)
    }

    /// Find related posts for a given post within the provided set.
    func relatedPosts(for post: CachedFeedViewPost, in posts: [CachedFeedViewPost], topK: Int = 5, minCos: Float = 0.3) async -> [CachedFeedViewPost] {
        await FeedEmbeddings.shared.relatedPosts(for: post, in: posts, topK: topK, minCos: minCos)
    }
}

