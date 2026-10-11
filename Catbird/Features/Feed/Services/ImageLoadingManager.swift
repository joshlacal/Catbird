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
    
    // MARK: - Initialization
    
    /// Private initializer for singleton pattern
    private init() {
        // Initialize pipeline first with our custom configuration
        pipeline = Self.createConfiguredPipeline()
        
        // Prefetch into the disk cache only. Display requests resize, so a full-size
        // decoded image in the memory cache would never be hit and would evict the
        // resized images actually on screen.
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .diskCache)
    }
    
    // MARK: - Public Methods
    
    /// Start prefetching images for the given URLs
    /// - Parameter urls: Array of image URLs to prefetch
    func startPrefetching(urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }
    
    /// Start prefetching images for the given image requests
    /// - Parameter requests: Array of configured image requests to prefetch
    func startPrefetching(requests: [ImageRequest]) {
        guard !requests.isEmpty else { return }
        prefetcher.startPrefetching(with: requests)
    }
    
    /// Alias for startPrefetching for compatibility
    /// - Parameter urls: Array of image URLs to prefetch
    func prefetchImages(urls: [URL]) {
        startPrefetching(urls: urls)
    }
    
    /// Stop prefetching images for the given URLs
    /// - Parameter urls: Array of image URLs to stop prefetching
    func stopPrefetching(urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.stopPrefetching(with: urls)
    }
    
    /// Stop prefetching images for the given image requests
    /// - Parameter requests: Array of image requests to stop prefetching
    func stopPrefetching(requests: [ImageRequest]) {
        guard !requests.isEmpty else { return }
        prefetcher.stopPrefetching(with: requests)
    }
    
    /// Clear all prefetched images
    func clearAllPrefetchedImages() {
        prefetcher.stopPrefetching()
        
        // Clear this pipeline's memory cache (not the unused shared one)
        pipeline.cache.removeAll(caches: [.memory])
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

        // Single disk store: store original data in DataCache once.
        // Disable URLCache so original data is not duplicated, and do not
        // store re-encoded processed images to disk.
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.urlCache = nil
        config.dataLoader = DataLoader(configuration: sessionConfig)
        config.dataCachePolicy = .storeOriginalData
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

        // 2 concurrent processing operations at userInitiated QoS for visible requests
        let processingQueue = OperationQueue()
        processingQueue.qualityOfService = .userInitiated
        processingQueue.maxConcurrentOperationCount = 2
        config.imageProcessingQueue = processingQueue

        // Critical: defer image decompression to background
        config.isStoringPreviewsInMemoryCache = true

        // Configure rate limiting for better network performance
        config.isRateLimiterEnabled = true

        // Return the configured pipeline
        return ImagePipeline(configuration: config)
    }
    
}

// MARK: - Image Processing Helpers

extension ImageLoadingManager {
    private static func normalizedTargetSize(_ targetSize: CGSize) -> CGSize {
        let safeWidth = max(1, min(4000, targetSize.width.rounded(.toNearestOrAwayFromZero)))
        let safeHeight = max(1, min(4000, targetSize.height.rounded(.toNearestOrAwayFromZero)))
        return CGSize(width: safeWidth, height: safeHeight)
    }

    /// Create optimized processors for the given target size
    /// Uses Nuke's built-in processors for better performance and caching
    static func processors(for targetSize: CGSize, contentMode: ImageProcessingOptions.ContentMode = .aspectFill) -> [any ImageProcessing] {
        let safeSize = normalizedTargetSize(targetSize)

        return [
            ImageProcessors.Resize(size: safeSize, contentMode: contentMode, crop: false, upscale: false)
        ]
    }
    /// Create a request with ImageIO thumbnail decoding directly at the target display size,
    /// avoiding full decode and redraw on the processing queue.
    static func thumbnailRequest(
        for url: URL,
        targetSize: CGSize,
        contentMode: ImageProcessingOptions.ContentMode = .aspectFill
    ) -> ImageRequest {
        let safeSize = normalizedTargetSize(targetSize)
        var request = ImageRequest(url: url)
        request.userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(
            size: safeSize,
            unit: .points,
            contentMode: contentMode
        )

        let area = safeSize.width * safeSize.height
        if area < 100_000 {
            request.priority = .high
        } else if area < 500_000 {
            request.priority = .normal
        } else {
            request.priority = .low
        }

        return request
    }


    /// Create a request with optimized caching key for the given size
    static func imageRequest(for url: URL, targetSize: CGSize) -> ImageRequest {
        let safeSize = normalizedTargetSize(targetSize)
        var request = ImageRequest(url: url)

        // Add size to cache key for better cache efficiency
        request.processors = processors(for: safeSize)

        // Set appropriate priority based on size (smaller = higher priority for thumbnails)
        let area = safeSize.width * safeSize.height
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
