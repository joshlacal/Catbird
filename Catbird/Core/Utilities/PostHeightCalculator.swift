#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Petrel
import CoreGraphics
import SwiftUI
import os

#if os(iOS)
/// Calculates consistent post heights before rendering to improve scroll stability
class PostHeightCalculator {
    // Configuration for the calculator with default values
    struct Config {
        // Main layout settings
        let maxWidth: CGFloat
        let textFont: UIFont
        let lineSpacing: CGFloat
        let letterSpacing: CGFloat
        let verticalPadding: CGFloat
        let contentSpacing: CGFloat
        
        // Image dimensions
        let imageGridAspectRatio: CGFloat
        let maxSingleImageHeight: CGFloat
        let imageGridSpacing: CGFloat
        
        // External embed dimensions
        let externalEmbedHeight: CGFloat
        let externalEmbedThumbHeight: CGFloat
        
        // Record embed dimensions
        let recordEmbedHeight: CGFloat
        let recordWithMediaSpacing: CGFloat
        
        // Avatar dimensions
        let avatarSize: CGFloat
        let avatarContainerWidth: CGFloat
        
        // Button heights
        let actionButtonsHeight: CGFloat
        
        // Video player dimensions
        let videoControlsHeight: CGFloat
        
        @MainActor
        static let standard = Config(
            maxWidth: min(600, PlatformScreenInfo.width) - 9,
            textFont: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body),
            lineSpacing: 1.2,
            letterSpacing: 0.2,
            verticalPadding: 12,
            contentSpacing: 8,
            
            imageGridAspectRatio: 1.667,
            maxSingleImageHeight: 800,
            imageGridSpacing: 3,
            
            externalEmbedHeight: 120,
            externalEmbedThumbHeight: 80,
            
            recordEmbedHeight: 150,
            recordWithMediaSpacing: 8,
            
            avatarSize: 48,
            avatarContainerWidth: 54,
            
            actionButtonsHeight: 36,
            
            videoControlsHeight: 40
        )
    }
    
    private let config: Config
    private let logger = Logger(subsystem: "blue.catbird", category: "PostHeightCalculator")
    
    // Enhanced height cache with better memory management
    private var heightCache = NSCache<NSString, NSNumber>()
    
    // Cache for text size calculations to avoid repeated expensive operations
    private var textSizeCache = NSCache<NSString, NSValue>()
    
    init(config: Config = .standard) {
        self.config = config
        setupCacheConfiguration()
    }
    
    /// Configure cache settings for optimal memory usage
    private func setupCacheConfiguration() {
        // Configure height cache
        heightCache.countLimit = 1000 // Limit to 1000 entries
        heightCache.totalCostLimit = 1024 * 1024 // 1MB limit
        
        // Configure text size cache
        textSizeCache.countLimit = 500 // Limit to 500 text calculations
        textSizeCache.totalCostLimit = 512 * 1024 // 512KB limit
    }
    
    // MARK: - Public API
    
    /// Shared instance for convenience
    static let shared = PostHeightCalculator()
    
    /// Static helper for quick height estimation
    static func estimatedHeight(for post: AppBskyFeedDefs.PostView, mode: CalculationMode = .compact) -> CGFloat {
        return shared.calculateHeight(for: post, mode: mode)
    }
    
    /// Static helper for thread-aware height estimation
    static func estimatedThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        threadContext: ThreadContext,
        mode: CalculationMode = .compact
    ) -> CGFloat {
        return shared.calculateThreadHeight(for: post, threadContext: threadContext, mode: mode)
    }
    
    /// Calculates height for a post, with caching for performance
    func calculateHeight(for post: AppBskyFeedDefs.PostView, mode: CalculationMode = .compact) -> CGFloat {
        // Use post URI and CID as cache key for uniqueness
        let cacheKey = "\(post.uri.uriString())-\(post.cid.string)-\(mode.rawValue)" as NSString
        
        if let cachedHeight = heightCache.object(forKey: cacheKey) {
            return cachedHeight.doubleValue
        }
        
        let height = calculateUncachedHeight(for: post, mode: mode)
        heightCache.setObject(NSNumber(value: Double(height)), forKey: cacheKey)
        
        
        return height
    }
    
    /// Thread-aware height calculation - the core fix for height estimation errors
    func calculateThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        threadContext: ThreadContext,
        mode: CalculationMode = .compact
    ) -> CGFloat {
        // Create comprehensive cache key including thread context
        let contextKey = "\(threadContext.displayMode.rawValue)-\(threadContext.sliceItems?.count ?? 0)-\(threadContext.hiddenCount)"
        let cacheKey = "\(post.uri.uriString())-\(post.cid.string)-\(mode.rawValue)-\(contextKey)" as NSString
        
        if let cachedHeight = heightCache.object(forKey: cacheKey) {
            return cachedHeight.doubleValue
        }
        
        let height = calculateUncachedThreadHeight(for: post, threadContext: threadContext, mode: mode)
        heightCache.setObject(NSNumber(value: Double(height)), forKey: cacheKey)
        
        
        return height
    }
    
    /// Calculate height for a parent post (may have special rendering)
    func calculateParentPostHeight(for parentPost: ParentPost) -> CGFloat {
        switch parentPost.post {
        case .appBskyFeedDefsThreadViewPost(let post):
            return calculateHeight(for: post.post, mode: .parentInThread)
            
        case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
            return 60 // Standard height for error states
            
        case .pending:
            return 100 // Default height for pending posts
        }
    }
    
    /// Calculate height for a reply wrapper
    func calculateReplyHeight(for replyWrapper: ReplyWrapper, showingNestedReply: Bool = false) -> CGFloat {
        var totalHeight: CGFloat = 0
        
        switch replyWrapper.reply {
        case .appBskyFeedDefsThreadViewPost(let replyPost):
            // Calculate height for the reply post
            totalHeight += calculateHeight(for: replyPost.post, mode: .compact)
            
            // Add height for nested reply if shown
            if showingNestedReply, let replies = replyPost.replies, !replies.isEmpty {
                // Simplified height calculation for nested reply
                totalHeight += 12 // Spacing
                totalHeight += 180 // Approximate height for a nested reply
            }
            
        case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
            totalHeight = 60
            
        case .pending:
            totalHeight = 100
        }
        
        return totalHeight
    }
    
    /// Invalidate all caches
    func invalidateCache() {
        heightCache.removeAllObjects()
        textSizeCache.removeAllObjects()
    }
    
    /// Batch calculate heights for multiple posts for better performance
    func batchCalculateHeights(for posts: [AppBskyFeedDefs.PostView], mode: CalculationMode = .compact) -> [String: CGFloat] {
        var results: [String: CGFloat] = [:]
        results.reserveCapacity(posts.count)
        
        for post in posts {
            let height = calculateHeight(for: post, mode: mode)
            results[post.uri.uriString()] = height
        }
        
        return results
    }
    
    // MARK: - Calculation Modes
    
    enum CalculationMode: String {
        case compact // For feed views
        case expanded // For detailed views
        case parentInThread // For parent posts in thread view
        case mainPost // For main post in thread view
    }
    
    // MARK: - Thread Context
    
    /// Context information for thread-aware height calculation
    struct ThreadContext {
        let displayMode: ThreadDisplayMode
        let sliceItems: [ThreadSliceItem]?
        let hiddenCount: Int
        
        enum ThreadDisplayMode: String {
            case standard
            case expanded
            case collapsed
        }
        
        struct ThreadSliceItem {
            let post: AppBskyFeedDefs.PostView
            let parentAuthor: AppBskyActorDefs.ProfileViewBasic?
        }
        
        init(
            displayMode: ThreadDisplayMode = .standard,
            sliceItems: [ThreadSliceItem]? = nil,
            hiddenCount: Int = 0
        ) {
            self.displayMode = displayMode
            self.sliceItems = sliceItems
            self.hiddenCount = hiddenCount
        }
    }
    
    // MARK: - Private Height Calculation Logic
    
    /// Calculate thread-aware height - handles expanded and collapsed thread modes
    private func calculateUncachedThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        threadContext: ThreadContext,
        mode: CalculationMode
    ) -> CGFloat {
        switch threadContext.displayMode {
        case .standard:
            // Standard mode: single post + optional parent
            return calculateStandardThreadHeight(for: post, mode: mode)
            
        case .expanded:
            // Expanded mode: multiple full posts in sequence
            return calculateExpandedThreadHeight(
                for: post,
                sliceItems: threadContext.sliceItems,
                mode: mode
            )
            
        case .collapsed:
            // Collapsed mode: root + separator + last 2 posts
            return calculateCollapsedThreadHeight(
                for: post,
                sliceItems: threadContext.sliceItems,
                hiddenCount: threadContext.hiddenCount,
                mode: mode
            )
        }
    }
    
    private func calculateStandardThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        mode: CalculationMode
    ) -> CGFloat {
        // Same as original single post calculation
        return calculateUncachedHeight(for: post, mode: mode)
    }
    
    private func calculateExpandedThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        sliceItems: [ThreadContext.ThreadSliceItem]?,
        mode: CalculationMode
    ) -> CGFloat {
        guard let sliceItems = sliceItems, !sliceItems.isEmpty else {
            return calculateUncachedHeight(for: post, mode: mode)
        }
        
        var totalHeight: CGFloat = 0
        
        // Add container padding (matches EnhancedFeedPost)
        totalHeight += 9 // Top padding (baseUnit * 3)
        totalHeight += 4.5 // Horizontal padding compensation
        
        // Calculate height for each post in the slice
        for (index, sliceItem) in sliceItems.enumerated() {
            let isLast = index == sliceItems.count - 1
            let postMode: CalculationMode = isLast ? .compact : .parentInThread
            
            // Calculate individual post height
            let postHeight = calculateUncachedHeight(for: sliceItem.post, mode: postMode)
            totalHeight += postHeight
            
            // Add spacing between posts (matches EnhancedFeedPost)
            if !isLast {
                totalHeight += 6 // baseUnit * 2 spacing between posts
            }
        }
        
        return totalHeight
    }
    
    private func calculateCollapsedThreadHeight(
        for post: AppBskyFeedDefs.PostView,
        sliceItems: [ThreadContext.ThreadSliceItem]?,
        hiddenCount: Int,
        mode: CalculationMode
    ) -> CGFloat {
        guard let sliceItems = sliceItems, sliceItems.count >= 3 else {
            return calculateUncachedHeight(for: post, mode: mode)
        }
        
        var totalHeight: CGFloat = 0
        
        // Add container padding
        totalHeight += 9 // Top padding
        totalHeight += 4.5 // Horizontal padding compensation
        
        // Root post (first item)
        let rootPost = sliceItems[0]
        totalHeight += calculateUncachedHeight(for: rootPost.post, mode: .parentInThread)
        
        // Thread separator height (estimated from ThreadSeparatorView)
        totalHeight += 40 // Separator with hidden count text
        
        // Last 2 posts
        let lastTwoItems = Array(sliceItems.suffix(2))
        for (index, sliceItem) in lastTwoItems.enumerated() {
            let isLast = index == lastTwoItems.count - 1
            let postMode: CalculationMode = isLast ? .compact : .parentInThread
            
            totalHeight += calculateUncachedHeight(for: sliceItem.post, mode: postMode)
            
            // Add spacing between last posts
            if !isLast {
                totalHeight += 6 // baseUnit * 2 spacing
            }
        }
        
        return totalHeight
    }
    
    private func calculateUncachedHeight(for post: AppBskyFeedDefs.PostView, mode: CalculationMode) -> CGFloat {
        var totalHeight: CGFloat = 0
        
        // Add top padding
        totalHeight += config.verticalPadding
        
        // Calculate header height (username, handle, time)
        totalHeight += 32 // Header with avatar, name, handle, timestamp
        
        // Get the post record
        guard case .knownType(let postObj) = post.record,
              let feedPost = postObj as? AppBskyFeedPost else {
            return totalHeight + config.verticalPadding // Return minimal height if post can't be processed
        }
        
        // Calculate text height
        let textHeight = calculateTextHeight(for: feedPost)
        totalHeight += textHeight
        
        // Add embed height if present
        if let embed = post.embed {
            if textHeight > 0 {
                totalHeight += config.contentSpacing // Add spacing between text and embed
            }
            totalHeight += calculateEmbedHeight(for: embed, labels: post.labels)
        }
        
        // Add action buttons height
        totalHeight += config.actionButtonsHeight
        
        // Add bottom padding
        totalHeight += config.verticalPadding
        
        // Apply mode-specific adjustments
        switch mode {
        case .expanded:
            // More spacing and details in expanded view
            totalHeight += 20
        case .parentInThread:
            // Parent posts may have extra indicators
            totalHeight += 8
        case .mainPost:
            // Main post may have extra styling
            totalHeight += 24
        default:
            break
        }
        
        return totalHeight
    }
    
    private func calculateTextHeight(for post: AppBskyFeedPost) -> CGFloat {
        if post.text.isEmpty {
            return 0
        }
        
        // Create cache key for text size calculation
        let textWidth = config.maxWidth - config.avatarContainerWidth
        let cacheKey = "\(post.text.hashValue)-\(textWidth)-\(config.textFont.pointSize)" as NSString
        
        // Check cache first
        if let cachedSize = textSizeCache.object(forKey: cacheKey) {
            let height = cachedSize.cgSizeValue.height
            
            // Add more height if post has tags
            if let tags = post.tags, !tags.isEmpty {
                return height + 24
            }
            return height
        }
        
        // Calculate text size if not cached
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = config.lineSpacing
        
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: config.textFont,
            .paragraphStyle: paragraphStyle,
            .kern: config.letterSpacing
        ]
        
        let textRect = post.text.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes,
            context: nil
        )
        
        // Add some padding for facets and text rendering
        let height = ceil(textRect.height) + 8
        
        // Cache the calculated size
        let size = CGSize(width: textWidth, height: height)
        textSizeCache.setObject(NSValue(cgSize: size), forKey: cacheKey)
        
        // Add more height if post has tags
        if let tags = post.tags, !tags.isEmpty {
            return height + 24
        }
        
        return height
    }
    
    private func calculateEmbedHeight(for embed: AppBskyFeedDefs.PostViewEmbedUnion, labels: [ComAtprotoLabelDefs.Label]?) -> CGFloat {
        switch embed {
        case .appBskyEmbedImagesView(let imagesView):
            return calculateImageEmbedHeight(for: imagesView)
            
        case .appBskyEmbedExternalView(let externalView):
            return calculateExternalEmbedHeight(for: externalView)
            
        case .appBskyEmbedRecordView(let recordView):
            return calculateRecordEmbedHeight(for: recordView)
            
        case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
            return calculateRecordWithMediaEmbedHeight(for: recordWithMediaView, labels: labels)
            
        case .appBskyEmbedVideoView(let videoView):
            return calculateVideoEmbedHeight(for: videoView)
            
        case .unexpected:
            return 60 // Default height for unexpected embeds
        }
    }
    
    private func calculateImageEmbedHeight(for imagesView: AppBskyEmbedImages.View) -> CGFloat {
        let images = imagesView.images
        
        if images.isEmpty {
            return 0
        }
        
        // Calculate height based on number of images
        switch images.count {
        case 1:
            // Single image - use aspect ratio with max height
            let aspectRatio = images[0].aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16/9
            let height = config.maxWidth / aspectRatio
            return min(height, config.maxSingleImageHeight)
            
        case 2:
            // Two images - side by side grid
            return config.maxWidth / 2 // Simple approximation
            
        case 3, 4:
            // Multi-image grid - use fixed aspect ratio
            return config.maxWidth / config.imageGridAspectRatio
            
        default:
            // For more than 4 images (though your UI seems to handle max 4)
            return config.maxWidth / config.imageGridAspectRatio
        }
    }
    
    private func calculateExternalEmbedHeight(for externalView: AppBskyEmbedExternal.View) -> CGFloat {
        // Base height for the card
        var height = config.externalEmbedHeight
        
        // Check if this is a special case like a Tenor GIF link
        if let url = URL(string: externalView.external.uri.uriString()),
           url.host?.contains("tenor.com") == true {
            // Calculate aspect ratio from URL or use default
            let aspectRatio: CGFloat = 4/3 // Default aspect ratio for GIFs
            
            // Calculate height based on width and aspect ratio
            return config.maxWidth / aspectRatio + config.videoControlsHeight
        }
        
        // Add extra height if there is a thumbnail
        if externalView.external.thumb != nil {
            height += config.externalEmbedThumbHeight
        }
        
        return height
    }
    
    private func calculateRecordEmbedHeight(for recordView: AppBskyEmbedRecord.View) -> CGFloat {
        // Handle different record types
        switch recordView.record {
        case .appBskyEmbedRecordViewRecord:
            return config.recordEmbedHeight
            
        case .appBskyEmbedRecordViewNotFound, 
             .appBskyEmbedRecordViewBlocked, 
             .appBskyEmbedRecordViewDetached:
            return 60 // Shorter height for error states
            
        case .appBskyFeedDefsGeneratorView,
             .appBskyGraphDefsListView,
             .appBskyLabelerDefsLabelerView,
             .appBskyGraphDefsStarterPackViewBasic:
            return 100 // Medium height for special record types
            
        case .unexpected:
            return 60
        }
    }
    
    private func calculateRecordWithMediaEmbedHeight(for recordWithMediaView: AppBskyEmbedRecordWithMedia.View, labels: [ComAtprotoLabelDefs.Label]?) -> CGFloat {
        // Calculate record embed height
        let recordHeight = calculateRecordEmbedHeight(for: recordWithMediaView.record)
        
        // Calculate media height based on media type
        var mediaHeight: CGFloat = 0
        switch recordWithMediaView.media {
        case .appBskyEmbedImagesView(let imagesView):
            mediaHeight = calculateImageEmbedHeight(for: imagesView)
            
        case .appBskyEmbedExternalView(let externalView):
            mediaHeight = calculateExternalEmbedHeight(for: externalView)
            
        case .appBskyEmbedVideoView(let videoView):
            mediaHeight = calculateVideoEmbedHeight(for: videoView)
            
        case .unexpected:
            mediaHeight = 0
        }
        
        // Return combined height with spacing
        return mediaHeight + config.recordWithMediaSpacing + recordHeight
    }
    
    private func calculateVideoEmbedHeight(for videoView: AppBskyEmbedVideo.View) -> CGFloat {
        // Calculate aspect ratio
        let aspectRatio = videoView.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16/9
        
        // Calculate height based on width and aspect ratio
        let height = config.maxWidth / aspectRatio
        
        // Add height for video controls
        return height + config.videoControlsHeight
    }
}

// MARK: - ThreadContext Extensions

extension PostHeightCalculator.ThreadContext {
    /// Create ThreadContext from CachedFeedViewPost for seamless integration
    init(from cachedPost: CachedFeedViewPost) {
        // Determine display mode from cached post
        let displayMode: ThreadDisplayMode
        switch cachedPost.threadDisplayMode {
        case "expanded":
            displayMode = .expanded
        case "collapsed":
            displayMode = .collapsed
        default:
            displayMode = .standard
        }
        
        // Convert slice items if present
        var sliceItems: [ThreadSliceItem]? = nil
        if let cachedSliceItems = cachedPost.sliceItems {
            sliceItems = cachedSliceItems.map { cachedSliceItem in
                ThreadSliceItem(
                    post: cachedSliceItem.post,
                    parentAuthor: cachedSliceItem.parentAuthor
                )
            }
        }
        
        self.init(
            displayMode: displayMode,
            sliceItems: sliceItems,
            hiddenCount: cachedPost.threadHiddenCount ?? 0
        )
    }
}

#else

// macOS stubs - simplified height estimation
class PostHeightCalculator {
    static let shared = PostHeightCalculator()
    
    enum CalculationMode: String {
        case compact, expanded, parentInThread, mainPost
    }
    
    struct ThreadContext {
        enum ThreadDisplayMode: String {
            case standard, expanded, collapsed
        }
        
        struct ThreadSliceItem {
            let post: AppBskyFeedDefs.PostView
            let parentAuthor: AppBskyActorDefs.ProfileViewBasic?
        }
        
        let displayMode: ThreadDisplayMode
        let sliceItems: [ThreadSliceItem]?
        let hiddenCount: Int
        
        init(displayMode: ThreadDisplayMode = .standard, sliceItems: [ThreadSliceItem]? = nil, hiddenCount: Int = 0) {
            self.displayMode = displayMode
            self.sliceItems = sliceItems
            self.hiddenCount = hiddenCount
        }
        
        init(from cachedPost: CachedFeedViewPost) {
            self.displayMode = .standard
            self.sliceItems = nil
            self.hiddenCount = 0
        }
    }
    
    static func estimatedHeight(for post: AppBskyFeedDefs.PostView, mode: CalculationMode = .compact) -> CGFloat {
        return 200 // Simple fixed height for macOS
    }
    
    static func estimatedThreadHeight(for post: AppBskyFeedDefs.PostView, threadContext: ThreadContext, mode: CalculationMode = .compact) -> CGFloat {
        return 250 // Simple fixed height for threads on macOS
    }
    
    func calculateHeight(for post: AppBskyFeedDefs.PostView, mode: CalculationMode = .compact) -> CGFloat {
        return 200
    }
    
    func calculateThreadHeight(for post: AppBskyFeedDefs.PostView, threadContext: ThreadContext, mode: CalculationMode = .compact) -> CGFloat {
        return 250
    }
    
    func calculateParentPostHeight(for parentPost: ParentPost) -> CGFloat {
        return 180
    }
    
    func calculateReplyHeight(for replyWrapper: ReplyWrapper, showingNestedReply: Bool = false) -> CGFloat {
        return 160
    }
    
    func invalidateCache() {
        // No-op on macOS
    }
    
    func batchCalculateHeights(for posts: [AppBskyFeedDefs.PostView], mode: CalculationMode = .compact) -> [String: CGFloat] {
        var results: [String: CGFloat] = [:]
        for post in posts {
            results[post.uri.uriString()] = 200
        }
        return results
    }
}

#endif

