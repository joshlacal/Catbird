//
//  ImageLoadingManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/30/24.
//

import Foundation
import Nuke
import NukeUI
import SwiftUI

/// A manager class for efficient image loading and prefetching
actor ImageLoadingManager {
    // MARK: - Properties
    
    /// Shared singleton instance
    static let shared = ImageLoadingManager()
    
    /// The image prefetcher used for preloading images
    private let prefetcher: ImagePrefetcher
    
    /// The configured image pipeline
    let pipeline: ImagePipeline
    
    /// Cache of prefetched image URLs to avoid duplicate prefetching
    private var prefetchedURLs = Set<URL>()
    
    /// Maximum number of prefetched images to store
    private let maxPrefetchedImages = 100
    
    /// Cache clear threshold - when to start removing old images
    private let cacheClearThreshold = 80
    
    // MARK: - Initialization
    
    /// Private initializer for singleton pattern
    private init() {
        // Initialize pipeline first with our custom configuration
        pipeline = Self.createConfiguredPipeline()
        
        // Configure prefetcher with this pipeline
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .memoryCache)
    }
    
    // MARK: - Public Methods
    
    /// Start prefetching images for the given URLs
    /// - Parameter urls: Array of image URLs to prefetch
    func startPrefetching(urls: [URL]) {
        // Filter out already prefetched URLs
        let newURLs = urls.filter { !prefetchedURLs.contains($0) }
        guard !newURLs.isEmpty else { return }
        
        // Check if we need to clear some prefetched images
        if prefetchedURLs.count > cacheClearThreshold {
            clearOldPrefetchedURLs()
        }
        
        // Add new URLs to the prefetched set
        for url in newURLs {
            prefetchedURLs.insert(url)
        }
        
        // Start prefetching the new URLs
        prefetcher.startPrefetching(with: newURLs)
    }
    
    /// Alias for startPrefetching for compatibility
    /// - Parameter urls: Array of image URLs to prefetch
    func prefetchImages(urls: [URL]) {
        startPrefetching(urls: urls)
    }
    
    /// Stop prefetching images for the given URLs
    /// - Parameter urls: Array of image URLs to stop prefetching
    func stopPrefetching(urls: [URL]) {
        prefetcher.stopPrefetching(with: urls)
        
        // Remove URLs from the prefetched set
        for url in urls {
            prefetchedURLs.remove(url)
        }
    }
    
    /// Clear all prefetched images
    func clearAllPrefetchedImages() {
        prefetcher.stopPrefetching()
        prefetchedURLs.removeAll()
        
        // Clear memory cache
        ImageCache.shared.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Create and configure an optimized image pipeline
    private static func createConfiguredPipeline() -> ImagePipeline {
        var config = ImagePipeline.Configuration()
        
        // Use up to 20% of available RAM for the memory cache
        config.imageCache = ImageCache(costLimit: 1024 * 1024 * 100) // 100MB
        
        // Set disk cache to 300MB
        let diskCache = try? DataCache(name: "blue.catbird.ImageCache")
        diskCache?.sizeLimit = 1024 * 1024 * 300 // 300MB
        config.dataCache = diskCache
        
        // Improve performance for scrolling
        config.isProgressiveDecodingEnabled = false
        
        // Configure request priorities
        config.dataCachePolicy = .automatic
        
        // Create operation queues with appropriate QoS
        let decodingQueue = OperationQueue()
        decodingQueue.qualityOfService = .userInitiated
        decodingQueue.maxConcurrentOperationCount = 2 // Limit concurrency
        config.imageDecodingQueue = decodingQueue
        
        let encodingQueue = OperationQueue()
        encodingQueue.qualityOfService = .utility
        encodingQueue.maxConcurrentOperationCount = 1 // Serial queue for encoding
        config.imageEncodingQueue = encodingQueue
        
        // Critical: Add additional image processing queue
        let processingQueue = OperationQueue()
        processingQueue.qualityOfService = .userInitiated
        processingQueue.maxConcurrentOperationCount = 2 // Limited concurrency
        config.imageProcessingQueue = processingQueue
        
        // Configure for background execution to prevent blocking main thread
        config.isTaskCoalescingEnabled = true
        
        // Critical: defer image decompression to background
        config.isStoringPreviewsInMemoryCache = true
        
        // Return the configured pipeline
        return ImagePipeline(configuration: config)
    }
    
    /// Clear older prefetched URLs when the cache gets too large
    private func clearOldPrefetchedURLs() {
        // If we exceed the threshold, remove the oldest entries
        if prefetchedURLs.count > cacheClearThreshold {
            // Remove approximately 50% of the cached URLs
            let countToRemove = prefetchedURLs.count / 2
            let urlsToRemove = Array(prefetchedURLs.prefix(countToRemove))
            
            // Stop prefetching these URLs
            prefetcher.stopPrefetching(with: urlsToRemove)
            
            // Remove them from our tracked set
            for url in urlsToRemove {
                prefetchedURLs.remove(url)
            }
        }
    }
}

// MARK: - Custom Image Processors

extension ImageProcessors {
    /// A processor that asynchronously downscales images in a background thread
    /// to avoid "PreferredTransform" main thread blocking issues
    struct AsyncImageDownscaling: ImageProcessing {
        let targetSize: CGSize
        
        var identifier: String {
            "blue.catbird.async-downscaling-\(targetSize.width)x\(targetSize.height)"
        }
        
        // Using ImageProcessing protocol's required method signature
        func process(_ image: PlatformImage) -> PlatformImage? {
            // Ensure we're not already on the main thread
            if Thread.isMainThread {
                // If on main thread, create a copy to avoid blocking
                var copy = image
                if let cgImage = image.cgImage {
                    copy = PlatformImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
                }
                return applyProcessing(to: copy)
            } else {
                return applyProcessing(to: image)
            }
        }
        
        private func applyProcessing(to image: PlatformImage) -> PlatformImage? {
            let targetSize = self.targetSize
            
            // We'll implement a safer approach that uses UIGraphicsImageRenderer 
            // instead of SwiftUI's ImageRenderer to avoid potential compatibility issues
            
            // Determine the appropriate content mode-based size
            let imageSize = CGSize(width: max(1, image.size.width * image.scale), 
                                  height: max(1, image.size.height * image.scale))
            let aspectRatio = imageSize.width / imageSize.height
            
            // Calculate target dimensions maintaining aspect ratio
            var width: CGFloat
            var height: CGFloat
            
            // Guard against zero or very small dimensions
            let safeTargetWidth = max(1, targetSize.width)
            let safeTargetHeight = max(1, targetSize.height) 
            
            if safeTargetWidth / safeTargetHeight > aspectRatio {
                width = safeTargetHeight * aspectRatio
                height = safeTargetHeight
            } else {
                width = safeTargetWidth
                height = safeTargetWidth / aspectRatio
            }
            
            // Ensure dimensions are at least 1pt
            width = max(1, width)
            height = max(1, height)
            
            // Check if we can safely use UIGraphicsImageRenderer
            if width.isFinite && height.isFinite && width > 0 && height > 0 {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
                return renderer.image { _ in
                    // Clear background to avoid artifacts
                    UIColor.clear.setFill()
                    UIRectFill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
                    
                    // Draw image maintaining aspect ratio
                    image.draw(in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
                }
            } else {
                // If dimensions are invalid, fall back to Nuke's built-in processor with safe dimensions
                let safeSize = CGSize(width: max(1, min(4000, targetSize.width)), 
                                     height: max(1, min(4000, targetSize.height)))
                return ImageProcessors.Resize(size: safeSize, contentMode: .aspectFit).process(image)
            }
        }
    }
}
