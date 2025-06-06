//
//  PostViewRecycler.swift
//  Catbird
//
//  Implements view recycling for better scroll performance
//

import SwiftUI
import Petrel
import Observation

/// View recycling characteristics for determining reusability
struct PostViewSignature: Hashable {
    let hasMedia: Bool
    let hasRepost: Bool
    let hasReply: Bool
    let hasEmbed: Bool
    let textLength: Int // Bucketed into ranges
    let authorType: String // Regular, verified, etc.
    
    init(from post: CachedFeedViewPost) {
        let feedPost = post.feedViewPost
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

/// Cached post view data
struct CachedPostView {
    let view: AnyView
    let lastUsed: Date
    let signature: PostViewSignature
}

@Observable
class PostViewRecycler {
    static let shared = PostViewRecycler()
    
    // Cache views by their signature for reuse
    private var viewCache: [PostViewSignature: [CachedPostView]] = [:]
    private let maxCacheSize = 50
    private let maxViewsPerSignature = 5
    private let cacheTimeout: TimeInterval = 300 // 5 minutes
    
    // Track usage statistics
    private var hitCount = 0
    private var missCount = 0
    
    private init() {
        // Start cleanup timer
        startCleanupTimer()
    }
    
    /// Get a recycled view if available, otherwise nil
    func getRecycledView(for post: CachedFeedViewPost) -> AnyView? {
        let signature = PostViewSignature(from: post)
        
        // Look for cached views with matching signature
        guard var cachedViews = viewCache[signature], !cachedViews.isEmpty else {
            missCount += 1
            return nil
        }
        
        // Remove and return the most recently used view
        let cachedView = cachedViews.removeFirst()
        viewCache[signature] = cachedViews
        
        hitCount += 1
        
        // Update usage time (create new entry with current time)
        let updatedView = CachedPostView(
            view: cachedView.view,
            lastUsed: Date(),
            signature: signature
        )
        
        // Put it back for potential reuse
        recycleView(updatedView.view, with: signature)
        
        return cachedView.view
    }
    
    /// Return a view to the recycling pool
    func recycleView(_ view: AnyView, for postId: String) {
        // This method is kept for backward compatibility but we prefer the signature-based version
        // We can't determine the signature from just a postId, so this will have limited effectiveness
    }
    
    /// Return a view to the recycling pool with signature
    func recycleView(_ view: AnyView, with signature: PostViewSignature) {
        // Ensure we don't exceed cache limits
        if getTotalCacheSize() >= maxCacheSize {
            performCleanup()
        }
        
        var cachedViews = viewCache[signature] ?? []
        
        // Don't exceed per-signature limit
        guard cachedViews.count < maxViewsPerSignature else { return }
        
        let cachedView = CachedPostView(
            view: view,
            lastUsed: Date(),
            signature: signature
        )
        
        cachedViews.append(cachedView)
        viewCache[signature] = cachedViews
    }
    
    /// Get cache hit ratio for performance monitoring
    var hitRatio: Double {
        let total = hitCount + missCount
        return total > 0 ? Double(hitCount) / Double(total) : 0.0
    }
    
    /// Clear the entire cache
    func clearCache() {
        viewCache.removeAll()
        hitCount = 0
        missCount = 0
    }
    
    // MARK: - Private Methods
    
    private func getTotalCacheSize() -> Int {
        return viewCache.values.reduce(0) { $0 + $1.count }
    }
    
    private func performCleanup() {
        let now = Date()
        
        // Remove expired entries
        for (signature, cachedViews) in viewCache {
            let validViews = cachedViews.filter { 
                now.timeIntervalSince($0.lastUsed) < cacheTimeout 
            }
            
            if validViews.isEmpty {
                viewCache.removeValue(forKey: signature)
            } else {
                viewCache[signature] = validViews
            }
        }
        
        // If still over limit, remove least recently used signatures
        while getTotalCacheSize() > maxCacheSize {
            guard let oldestSignature = findOldestSignature() else { break }
            viewCache.removeValue(forKey: oldestSignature)
        }
    }
    
    private func findOldestSignature() -> PostViewSignature? {
        var oldestSignature: PostViewSignature?
        var oldestTime: Date = Date()
        
        for (signature, cachedViews) in viewCache {
            if let oldestView = cachedViews.min(by: { $0.lastUsed < $1.lastUsed }) {
                if oldestView.lastUsed < oldestTime {
                    oldestTime = oldestView.lastUsed
                    oldestSignature = signature
                }
            }
        }
        
        return oldestSignature
    }
    
    private func startCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                self.performCleanup()
            }
        }
    }
}
