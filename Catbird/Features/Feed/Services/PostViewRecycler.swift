//
//  PostViewRecycler.swift
//  Catbird
//
//  Implements post data caching for better scroll performance
//

import SwiftUI
import Petrel
import Observation

/// Post layout characteristics for determining view configuration
struct PostViewSignature: Hashable {
    let hasMedia: Bool
    let hasRepost: Bool
    let hasReply: Bool
    let hasEmbed: Bool
    let textLength: Int // Bucketed into ranges
    let authorType: String // Regular, verified, etc.

    init(from post: CachedFeedViewPost) {
        guard let feedPost = try? post.feedViewPost else {
            // Provide defaults if post can't be decoded
            self.hasMedia = false
            self.hasRepost = false
            self.hasReply = false
            self.hasEmbed = false
            self.textLength = 1
            self.authorType = "handle_only"
            return
        }

        let record = feedPost.post.record

        // Check for media attachments via post embed
        self.hasMedia = feedPost.post.embed != nil

        // Check for repost
        self.hasRepost = {
            if case .appBskyFeedDefsReasonRepost = feedPost.reason {
                return true
            }
            return false
        }()

        // Check for reply
        self.hasReply = feedPost.reply != nil

        // Check for embeds (external links, records, etc.)
        self.hasEmbed = feedPost.post.embed != nil

        // Bucket text length into ranges for better reuse
        // For now, use a default since we can't easily access text from ATProtocolValueContainer
        let textLen = 100 // Default estimate
        self.textLength = textLen <= 50 ? 0 :
                         textLen <= 150 ? 1 :
                         textLen <= 280 ? 2 : 3

        // Author type for different layouts
        self.authorType = feedPost.post.author.displayName?.isEmpty == false ? "named" : "handle_only"
    }
}

/// Cached post configuration data (not views)
struct CachedPostData {
    let postId: String
    let signature: PostViewSignature
    let estimatedHeight: CGFloat
    let lastAccessed: Date
    let accessCount: Int
}

@Observable
class PostViewRecycler {
    static let shared = PostViewRecycler()

    // Cache post data by postId for height estimation and layout optimization
    private var dataCache: [String: CachedPostData] = [:]
    private var signatureHeights: [PostViewSignature: [CGFloat]] = [:]
    private let maxCacheSize = 200
    private let cacheTimeout: TimeInterval = 600 // 10 minutes

    // Track usage statistics
    private var hitCount = 0
    private var missCount = 0

    private init() {
        // Start cleanup timer
        startCleanupTimer()
    }

    /// Get cached post data if available
    func getCachedData(for post: CachedFeedViewPost) -> CachedPostData? {
        guard let feedPost = try? post.feedViewPost else { return nil }
        let postId = feedPost.post.uri.uriString()

        if let cached = dataCache[postId] {
            // Update access info
            let updated = CachedPostData(
                postId: cached.postId,
                signature: cached.signature,
                estimatedHeight: cached.estimatedHeight,
                lastAccessed: Date(),
                accessCount: cached.accessCount + 1
            )
            dataCache[postId] = updated
            hitCount += 1
            return updated
        }

        missCount += 1
        return nil
    }

    /// Cache post data for future use
    func cachePostData(for post: CachedFeedViewPost, height: CGFloat) {
        guard let feedPost = try? post.feedViewPost else { return }
        let postId = feedPost.post.uri.uriString()
        let signature = PostViewSignature(from: post)

        // Ensure we don't exceed cache limits
        if dataCache.count >= maxCacheSize {
            performCleanup()
        }

        let cached = CachedPostData(
            postId: postId,
            signature: signature,
            estimatedHeight: height,
            lastAccessed: Date(),
            accessCount: 1
        )

        dataCache[postId] = cached

        // Track signature height patterns for better estimation
        var heights = signatureHeights[signature] ?? []
        heights.append(height)
        if heights.count > 10 {
            heights.removeFirst()
        }
        signatureHeights[signature] = heights
    }

    /// Get estimated height for a post signature
    func getEstimatedHeight(for signature: PostViewSignature) -> CGFloat {
        guard let heights = signatureHeights[signature], !heights.isEmpty else {
            return getDefaultHeight(for: signature)
        }

        // Return median height for stability
        let sortedHeights = heights.sorted()
        let middleIndex = sortedHeights.count / 2
        return sortedHeights[middleIndex]
    }

    /// Legacy compatibility - returns nil (no view caching)
    @available(*, deprecated, message: "Use getCachedData instead")
    func getRecycledView(for post: CachedFeedViewPost) -> AnyView? {
        return nil
    }

    /// Legacy compatibility - no-op
    @available(*, deprecated, message: "Use cachePostData instead")
    func recycleView(_ view: AnyView, for postId: String) {
        // No-op - we don't cache views anymore
    }
    
    /// Get cache hit ratio for performance monitoring
    var hitRatio: Double {
        let total = hitCount + missCount
        return total > 0 ? Double(hitCount) / Double(total) : 0.0
    }

    /// Clear the entire cache
    func clearCache() {
        dataCache.removeAll()
        signatureHeights.removeAll()
        hitCount = 0
        missCount = 0
    }

    // MARK: - Private Methods

    private func getDefaultHeight(for signature: PostViewSignature) -> CGFloat {
        var baseHeight: CGFloat = 120 // Base post height

        if signature.hasMedia {
            baseHeight += 200 // Media attachment
        }
        if signature.hasRepost {
            baseHeight += 40 // Repost header
        }
        if signature.hasReply {
            baseHeight += 30 // Reply context
        }
        if signature.hasEmbed {
            baseHeight += 60 // Embed preview
        }

        // Adjust for text length
        switch signature.textLength {
        case 1: baseHeight += 20
        case 2: baseHeight += 40
        case 3: baseHeight += 80
        default: break
        }

        return baseHeight
    }

    private func performCleanup() {
        let now = Date()

        // Remove expired entries
        let expiredKeys = dataCache.compactMap { (key, value) in
            now.timeIntervalSince(value.lastAccessed) > cacheTimeout ? key : nil
        }

        for key in expiredKeys {
            dataCache.removeValue(forKey: key)
        }

        // If still over limit, remove least frequently used entries
        while dataCache.count > maxCacheSize {
            guard let leastUsedKey = findLeastUsedKey() else { break }
            dataCache.removeValue(forKey: leastUsedKey)
        }
    }

    private func findLeastUsedKey() -> String? {
        return dataCache.min { first, second in
            if first.value.accessCount != second.value.accessCount {
                return first.value.accessCount < second.value.accessCount
            }
            return first.value.lastAccessed < second.value.lastAccessed
        }?.key
    }
    
    private func startCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                self.performCleanup()
            }
        }
    }
}
