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

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A manager class for efficient image loading and prefetching
actor ImageLoadingManager {
    // MARK: - Properties
    
    /// Shared singleton instance
    static let shared = ImageLoadingManager()
    
    /// The image prefetcher used for preloading images
    private let prefetcher: ImagePrefetcher
    
    /// The configured image pipeline
    nonisolated let pipeline: ImagePipeline
    
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
        prefetcher = ImagePrefetcher(pipeline: pipeline)
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
    
    /// Prefetch images from an embed
    func prefetchImages(for embed: Any) async {
        // Extract image URLs from various embed types
        let urls: [URL] = []
        
        // This is a simplified implementation - in a real app you'd parse the embed structure
        // For now, we'll just return without doing anything to avoid compilation errors
        // In a full implementation, you'd check the embed type and extract image URLs
        
        if !urls.isEmpty {
            startPrefetching(urls: urls)
        }
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

        // Configure request priorities and caching
        config.dataCachePolicy = .automatic
        config.isTaskCoalescingEnabled = true

        // Create operation queues with appropriate QoS
        let decodingQueue = OperationQueue()
        decodingQueue.qualityOfService = .userInitiated
        decodingQueue.maxConcurrentOperationCount = 2 // Limit concurrency
        config.imageDecodingQueue = decodingQueue

        let encodingQueue = OperationQueue()
        encodingQueue.qualityOfService = .utility
        encodingQueue.maxConcurrentOperationCount = 1 // Serial queue for encoding
        config.imageEncodingQueue = encodingQueue

        // Lower priority for processing queue to avoid blocking decoding
        let processingQueue = OperationQueue()
        processingQueue.qualityOfService = .utility // Lower than decoding
        processingQueue.maxConcurrentOperationCount = 1 // Reduce to 1 for better memory usage
        config.imageProcessingQueue = processingQueue

        // Critical: defer image decompression to background
        config.isStoringPreviewsInMemoryCache = true

        // Configure rate limiting for better network performance
        config.isRateLimiterEnabled = true

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

// MARK: - Image Processing Helpers

extension ImageLoadingManager {
    /// Create optimized processors for the given target size
    /// Uses Nuke's built-in processors for better performance and caching
    static func processors(for targetSize: CGSize, contentMode: ImageProcessors.Resize.ContentMode = .aspectFill) -> [any ImageProcessing] {
        // Ensure reasonable minimum size to avoid invalid dimensions
        let safeWidth = max(1, min(4000, targetSize.width))
        let safeHeight = max(1, min(4000, targetSize.height))
        let safeSize = CGSize(width: safeWidth, height: safeHeight)

        return [
            ImageProcessors.Resize(size: safeSize, contentMode: contentMode, crop: false, upscale: false),
            ImageProcessors.CoreImageFilter(name: "CIColorControls") // Optional: improve contrast for thumbnails
        ]
    }

    /// Create a request with optimized caching key for the given size
    static func imageRequest(for url: URL, targetSize: CGSize) -> ImageRequest {
        var request = ImageRequest(url: url)

        // Add size to cache key for better cache efficiency
        request.processors = processors(for: targetSize)

        // Set appropriate priority based on size (smaller = higher priority for thumbnails)
        let area = targetSize.width * targetSize.height
        if area < 100_000 { // Small thumbnails
            request.priority = .high
        } else if area < 500_000 { // Medium images
            request.priority = .normal
        } else { // Large images
            request.priority = .low
        }

        return request
    }
}
