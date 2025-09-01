//
//  PostComposerPerformanceOptimizer.swift
//  Catbird
//
//  Performance optimization utilities for Post Composer link creation and text processing
//

import Foundation
import SwiftUI
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Combine

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class PostComposerPerformanceOptimizer: ObservableObject {
    private let logger = Logger(subsystem: "blue.catbird", category: "PostComposer.Performance")
    
    // MARK: - Debouncing Properties
    
    private var urlDetectionWorkItem: DispatchWorkItem?
    private var textProcessingWorkItem: DispatchWorkItem?
    private let urlDetectionDelay: TimeInterval = 0.5
    private let textProcessingDelay: TimeInterval = 0.3
    
    // MARK: - Request Coalescing
    
    private var activeURLCardRequests: Set<String> = []
    private var urlCardRequestQueue: [String: [() -> Void]] = [:]
    private let maxConcurrentRequests = 3
    private var activeRequestCount = 0
    
    // MARK: - Memory Management
    
    private let maxCachedURLCards = 50
    private let maxThumbnailCacheSize = 100
    private var memoryPressureObserver: NSObjectProtocol?
    
    // MARK: - Performance Metrics
    
    private var performanceMetrics = PerformanceMetrics()
    
    init() {
        setupMemoryPressureObserver()
    }
    
    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Text Processing Debouncing
    
    /// Debounced text processing to avoid excessive facet parsing
    func debounceTextProcessing(operation: @escaping () -> Void) {
        // Cancel previous work item
        textProcessingWorkItem?.cancel()
        
        // Create new work item
        let workItem = DispatchWorkItem {
            let startTime = CFAbsoluteTimeGetCurrent()
            operation()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            
            Task { @MainActor in
                self.performanceMetrics.recordTextProcessingTime(duration)
                if duration > 0.1 {
                    self.logger.warning("Slow text processing: \(duration)s")
                }
            }
        }
        
        textProcessingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + textProcessingDelay, execute: workItem)
    }
    
    /// Debounced URL detection to batch URL card requests
    func debounceURLDetection(urls: [String], operation: @escaping ([String]) -> Void) {
        // Cancel previous work item
        urlDetectionWorkItem?.cancel()
        
        // Create new work item
        let workItem = DispatchWorkItem {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Filter out URLs that are already being processed
            let urlsToProcess = urls.filter { !self.activeURLCardRequests.contains($0) }
            
            if !urlsToProcess.isEmpty {
                operation(urlsToProcess)
            }
            
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Task { @MainActor in
                self.performanceMetrics.recordURLDetectionTime(duration)
            }
        }
        
        urlDetectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + urlDetectionDelay, execute: workItem)
    }
    
    // MARK: - Request Coalescing
    
    /// Coalesce URL card requests to prevent duplicate fetches
    func coalesceURLCardRequest(for url: String, completion: @escaping () -> Void) {
        // If request is already active, queue the completion handler
        if activeURLCardRequests.contains(url) {
            urlCardRequestQueue[url, default: []].append(completion)
            logger.debug("Coalescing URL card request for: \(url)")
            return
        }
        
        // If we're at max concurrent requests, queue it
        if activeRequestCount >= maxConcurrentRequests {
            urlCardRequestQueue[url, default: []].append(completion)
            logger.debug("Queueing URL card request (max concurrent reached): \(url)")
            return
        }
        
        // Execute request immediately
        executeURLCardRequest(for: url, completion: completion)
    }
    
    private func executeURLCardRequest(for url: String, completion: @escaping () -> Void) {
        activeURLCardRequests.insert(url)
        self.activeRequestCount += 1
        
        logger.debug("Starting URL card request for: \(url) (active: \(self.activeRequestCount))")
        
        // Execute the completion handler
        completion()
        
        // Clean up after request completes (to be called by the actual network request)
    }
    
    /// Call this when a URL card request completes (success or failure)
    func completeURLCardRequest(for url: String) {
        activeURLCardRequests.remove(url)
        self.activeRequestCount = max(0, self.activeRequestCount - 1)
        
        // Execute queued completion handlers for this URL
        if let queuedCompletions = urlCardRequestQueue.removeValue(forKey: url) {
            for completion in queuedCompletions {
                completion()
            }
        }
        
        // Process next queued request if any
        processNextQueuedRequest()
        
        logger.debug("Completed URL card request for: \(url) (active: \(self.activeRequestCount))")
    }
    
    private func processNextQueuedRequest() {
        guard activeRequestCount < maxConcurrentRequests,
              let (nextUrl, completions) = urlCardRequestQueue.first,
              let firstCompletion = completions.first else {
            return
        }
        
        // Remove the first completion from queue
        var remainingCompletions = completions
        remainingCompletions.removeFirst()
        
        if remainingCompletions.isEmpty {
            urlCardRequestQueue.removeValue(forKey: nextUrl)
        } else {
            urlCardRequestQueue[nextUrl] = remainingCompletions
        }
        
        // Execute the request
        executeURLCardRequest(for: nextUrl, completion: firstCompletion)
    }
    
    // MARK: - Background Processing
    
    /// Execute thumbnail upload in background to avoid blocking UI
    func executeThumbnailUpload<T>(operation: @escaping () async throws -> T) async throws -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let result = try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) {
                try await operation()
            }
            
            return try await group.next()!
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        performanceMetrics.recordThumbnailUploadTime(duration)
        
        if duration > 5.0 {
            logger.warning("Slow thumbnail upload: \(duration)s")
        }
        
        return result
    }
    
    // MARK: - Memory Management
    
    private func setupMemoryPressureObserver() {
        #if os(iOS)
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
        #elseif os(macOS)
        // macOS doesn't have memory warnings like iOS, so we'll skip this
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .NSApplicationDidBecomeActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
        #endif
    }
    
    private func handleMemoryPressure() {
        logger.info("Handling memory pressure - clearing caches")
        
        // Cancel pending work items
        urlDetectionWorkItem?.cancel()
        textProcessingWorkItem?.cancel()
        
        // Clear request queues
        urlCardRequestQueue.removeAll()
        activeURLCardRequests.removeAll()
        activeRequestCount = 0
        
        // Reset metrics
        performanceMetrics = PerformanceMetrics()
    }
    
    /// Check if we should limit operations due to memory pressure
    func shouldLimitOperations() -> Bool {
        return ProcessInfo.processInfo.thermalState == .critical ||
               performanceMetrics.averageTextProcessingTime > 0.5 ||
               activeRequestCount >= maxConcurrentRequests
    }
    
    // MARK: - Performance Monitoring
    
    func getPerformanceReport() -> PerformanceReport {
        return PerformanceReport(
            averageTextProcessingTime: performanceMetrics.averageTextProcessingTime,
            averageURLDetectionTime: performanceMetrics.averageURLDetectionTime,
            averageThumbnailUploadTime: performanceMetrics.averageThumbnailUploadTime,
            activeRequests: activeRequestCount,
            queuedRequests: urlCardRequestQueue.values.flatMap { $0 }.count,
            totalProcessedOperations: performanceMetrics.totalOperations
        )
    }
    
    func logPerformanceReport() {
        let report = getPerformanceReport()
        logger.info("""
        Performance Report:
        - Avg Text Processing: \(String(format: "%.3f", report.averageTextProcessingTime))s
        - Avg URL Detection: \(String(format: "%.3f", report.averageURLDetectionTime))s
        - Avg Thumbnail Upload: \(String(format: "%.3f", report.averageThumbnailUploadTime))s
        - Active Requests: \(report.activeRequests)
        - Queued Requests: \(report.queuedRequests)
        - Total Operations: \(report.totalProcessedOperations)
        """)
    }
}

// MARK: - Performance Metrics

private struct PerformanceMetrics {
    private var textProcessingTimes: [TimeInterval] = []
    private var urlDetectionTimes: [TimeInterval] = []
    private var thumbnailUploadTimes: [TimeInterval] = []
    private let maxSamples = 100
    
    var totalOperations: Int {
        textProcessingTimes.count + urlDetectionTimes.count + thumbnailUploadTimes.count
    }
    
    var averageTextProcessingTime: TimeInterval {
        guard !textProcessingTimes.isEmpty else { return 0 }
        return textProcessingTimes.reduce(0, +) / Double(textProcessingTimes.count)
    }
    
    var averageURLDetectionTime: TimeInterval {
        guard !urlDetectionTimes.isEmpty else { return 0 }
        return urlDetectionTimes.reduce(0, +) / Double(urlDetectionTimes.count)
    }
    
    var averageThumbnailUploadTime: TimeInterval {
        guard !thumbnailUploadTimes.isEmpty else { return 0 }
        return thumbnailUploadTimes.reduce(0, +) / Double(thumbnailUploadTimes.count)
    }
    
    mutating func recordTextProcessingTime(_ time: TimeInterval) {
        textProcessingTimes.append(time)
        if textProcessingTimes.count > maxSamples {
            textProcessingTimes.removeFirst()
        }
    }
    
    mutating func recordURLDetectionTime(_ time: TimeInterval) {
        urlDetectionTimes.append(time)
        if urlDetectionTimes.count > maxSamples {
            urlDetectionTimes.removeFirst()
        }
    }
    
    mutating func recordThumbnailUploadTime(_ time: TimeInterval) {
        thumbnailUploadTimes.append(time)
        if thumbnailUploadTimes.count > maxSamples {
            thumbnailUploadTimes.removeFirst()
        }
    }
}

// MARK: - Performance Report

struct PerformanceReport {
    let averageTextProcessingTime: TimeInterval
    let averageURLDetectionTime: TimeInterval
    let averageThumbnailUploadTime: TimeInterval
    let activeRequests: Int
    let queuedRequests: Int
    let totalProcessedOperations: Int
    
    var isPerformingWell: Bool {
        averageTextProcessingTime < 0.1 &&
        averageURLDetectionTime < 0.05 &&
        averageThumbnailUploadTime < 3.0 &&
        activeRequests < 5
    }
}

// MARK: - Link Creation Performance Enhancer

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LinkCreationPerformanceEnhancer {
    private let logger = Logger(subsystem: "blue.catbird", category: "LinkCreation.Performance")
    
    // MARK: - Animation Optimization
    
    /// Optimized animation configuration for link creation
    static let linkCreationAnimation = SwiftUI.Animation.interactiveSpring(
        response: 0.3,
        dampingFraction: 0.8,
        blendDuration: 0.1
    )
    
    static let linkEditingAnimation = SwiftUI.Animation.easeInOut(duration: 0.2)
    
    // MARK: - Batch Operations
    
    /// Batch link facet updates to minimize AttributedString conversions
    func batchLinkFacetUpdates<T>(
        operations: [() -> T]
    ) -> [T] {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            if duration > 0.05 {
                logger.warning("Slow batch facet update: \(duration)s for \(operations.count) operations")
            }
        }
        
        return operations.map { $0() }
    }
    
    /// Optimize large document link operations
    func optimizedLinkOperationForLargeDocument(
        textLength: Int,
        operation: @escaping () -> Void
    ) {
        if textLength > 10000 {
            // For large documents, defer to next run loop to avoid blocking
            DispatchQueue.main.async { [operation] in
                operation()
            }
        } else {
            operation()
        }
    }
    
    // MARK: - Memory-Efficient Link Tracking
    
    /// Memory-efficient link facet tracking for large documents
    func createMemoryEfficientLinkFacets(
        from linkFacets: [RichTextFacetUtils.LinkFacet],
        maxFacets: Int = 100
    ) -> [RichTextFacetUtils.LinkFacet] {
        // Limit number of tracked facets to prevent memory bloat
        if linkFacets.count > maxFacets {
            logger.warning("Limiting link facets from \(linkFacets.count) to \(maxFacets) for memory efficiency")
            return Array(linkFacets.prefix(maxFacets))
        }
        return linkFacets
    }
}

// MARK: - Extensions

extension PostComposerViewModel {
    
    /// Initialize performance optimizer (to be called during init)
    func setupPerformanceOptimization() {
        // This would be called from the view model's init
        // The optimizer should be stored as a property in the view model
    }
}
