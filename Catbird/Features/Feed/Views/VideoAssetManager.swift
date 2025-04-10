//
//  VideoAssetManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import Foundation
import AVKit
import Observation
import os.log
import CryptoKit

// Actor to safely manage concurrent task access
actor LoadTracker {
    private var activeLoads: [String: Task<AVURLAsset, Error>] = [:]
    
    func getExistingTask(for key: String) -> Task<AVURLAsset, Error>? {
        return activeLoads[key]
    }
    
    func addTask(_ task: Task<AVURLAsset, Error>, for key: String) {
        activeLoads[key] = task
    }
    
    func removeTask(for key: String) {
        activeLoads.removeValue(forKey: key)
    }
    
    func getAllTasksAndClear() -> [Task<AVURLAsset, Error>] {
        let tasks = Array(activeLoads.values)
        activeLoads.removeAll()
        return tasks
    }
}

/// Manager for video assets that handles caching, loading, and player creation
final class VideoAssetManager {
    static let shared = VideoAssetManager()
    
    private let queue = DispatchQueue(label: "blue.catbird.videoasset", qos: .userInitiated)
    private var assetCache = NSCache<NSString, AVURLAsset>()
    private var playerCache = NSCache<NSString, AVPlayer>()
    // Actor-based task management for Swift 6 concurrency safety
    private let loadTracker = LoadTracker()
    private var timeObservers: [String: NSKeyValueObservation] = [:]
    
    private let logger = Logger(subsystem: "blue.catbird", category: "VideoAssetManager")
    private let assetLoadTimeout: TimeInterval = 20 // Reduced timeout for better user experience
    
    init() {
        setupCache()
        
        // Configure audio session at startup to prevent conflicts
        AudioSessionManager.shared.configureForSilentPlayback()
        
        // Register for memory pressure notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning(_:)),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    private func generateCacheKey(from id: String) -> String {
        let inputData = Data(id.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Prepares an asset for the given video model
    /// - Parameter model: The video model containing URL and type information
    /// - Returns: A configured AVURLAsset
    func prepareAsset(for model: VideoModel) async throws -> AVURLAsset {
        let cacheKey: String = generateCacheKey(from: model.id)
        
        // First try reading from cache without blocking
        if let cachedAsset = assetCache.object(forKey: cacheKey as NSString) {
            logger.debug("Found cached asset for \(model.id)")
            return cachedAsset
        }

        return try await queue.asyncResult {
            // Check cache again after entering the queue
            if let cachedAsset = self.assetCache.object(forKey: cacheKey as NSString) {
                return cachedAsset
            }
            
            // Check if there's already a task loading this asset using the actor
            if let existingTask = await self.loadTracker.getExistingTask(for: cacheKey) {
                return try await existingTask.value
            }
            
            // Start a new loading task
            let loadTask = Task {
                self.logger.debug("Starting new load for \(cacheKey)")
                
                // CRITICAL: These options prevent excessive resource usage for network assets
                let options: [String: Any] = [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true,
                    AVURLAssetAllowsCellularAccessKey: true,
                    AVURLAssetAllowsConstrainedNetworkAccessKey: true,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: true
                ]
                
                // Create the asset with optimized options
                let asset = AVURLAsset(url: model.url, options: options)
                
                // Different loading strategy based on content type
                try await self.withTimeout(seconds: self.assetLoadTimeout) {
                    switch model.type {
                    case .hlsStream:
                        // For HLS streams, ensure basic playability
                        _ = try await asset.load(.isPlayable)
                        _ = try await asset.load(.duration)
                    case .tenorGif:
                        // For Tenor GIFs, just ensure we have duration
                        _ = try await asset.load(.duration)
                    }
                }
                
                // Store in cache and safely clean up using the actor
                self.assetCache.setObject(asset, forKey: cacheKey as NSString)
                await self.loadTracker.removeTask(for: cacheKey)
                
                return asset
            }
            
            // Track the active load using the actor
            await self.loadTracker.addTask(loadTask, for: cacheKey)
            return try await loadTask.value
        }
    }
    
    /// Prepares a player for the given video model
    /// - Parameter model: The video model
    /// - Returns: A configured AVPlayer ready for playback
    func preparePlayer(for model: VideoModel) async throws -> AVPlayer {
        let cacheKey: String = generateCacheKey(from: model.id)

        // Check for cached player
        if let cachedPlayer = playerCache.object(forKey: cacheKey as NSString) {
            logger.debug("Found cached player for \(model.id)")
            return cachedPlayer
        }

        logger.debug("Preparing new player for \(cacheKey)")
        
        // Create appropriate player based on content type
        switch model.type {
        case .hlsStream:
            return try await prepareHLSPlayer(for: model)
        case .tenorGif:
            return try await prepareTenorPlayer(for: model)
        }
    }
    
    /// Prepares an HLS player with optimized settings
    private func prepareHLSPlayer(for model: VideoModel) async throws -> AVPlayer {
        let cacheKey = generateCacheKey(from: model.id)
        
        // Get the asset (async operation)
        let asset = try await prepareAsset(for: model)
        
        // Configure player on main actor
        return await MainActor.run {
            // Configure item with proper settings for silent playback
            let playerItem = AVPlayerItem(asset: asset)
            
            // Disable audio tracks before creating the player
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = []
            playerItem.audioMix = audioMix
            
            // Create player with minimal resource usage
            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = true
            player.volume = 0
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            
            // Cache and return
            self.playerCache.setObject(player, forKey: cacheKey as NSString)
            return player
        }
    }
    
    /// Prepares a player optimized for Tenor GIFs
    @MainActor
    private func prepareTenorPlayer(for model: VideoModel) async throws -> AVPlayer {
        let cacheKey: String = generateCacheKey(from: model.id)
        
        // For GIFs, use more direct approach with fewer properties loaded
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true
        ]
        
        // Create the asset - using fewer loaded properties to avoid blocking
        let asset = AVURLAsset(url: model.url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure for smoother playback
        playerItem.seekingWaitsForVideoCompositionRendering = false
        
        // Disable audio for GIFs
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = []
        playerItem.audioMix = audioMix
        
        // Create silent player configured for looping
        let player = AVPlayer(playerItem: playerItem)
        player.volume = 0
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        
        // IMPORTANT: Make sure this player starts playing
        player.play()
        
        // Cache and return the configured player
        playerCache.setObject(player, forKey: cacheKey as NSString)
        return player
    }
        
    /// Timeout wrapper function for asset loading operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw VideoError.timeout
            }
            
            // Add actual operation
            group.addTask {
                try await operation()
            }
            
            // Return first completing task (success or timeout)
            do {
                let result = try await group.next()
                group.cancelAll()
                if let result = result {
                    return result
                } else {
                    throw VideoError.unknown
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
    
    /// Configure cache sizes based on device capabilities
    private func setupCache() {
        // Limit number of cached assets/players
        assetCache.countLimit = 12
        playerCache.countLimit = 6
        
        // Scale cache size based on available memory
        let memoryLimit = ProcessInfo.processInfo.physicalMemory
        let maxCacheMB = memoryLimit > 4_000_000_000 ? 120 : 60
        assetCache.totalCostLimit = maxCacheMB * 1024 * 1024
    }
    
    /// Handle memory warnings by clearing caches
    @objc func handleMemoryWarning(_ notification: Notification) {
        // First handle main actor work
        Task { @MainActor in
            for (modelId, _) in VideoCoordinator.shared.activeVideos {
                VideoCoordinator.shared.unregister(modelId)
            }
        }
        
        // Clean up resources on dedicated queue
        queue.async {
            // Clean up observers
            for (_, observer) in self.timeObservers {
                observer.invalidate()
            }
            self.timeObservers.removeAll()
            
            // Clear caches
            self.assetCache.removeAllObjects()
            self.playerCache.removeAllObjects()
            
            // Cancel and clean up active loads using the actor
            Task {
                let tasks = await self.loadTracker.getAllTasksAndClear()
                // Cancel tasks after getting them from the actor
                for task in tasks {
                    task.cancel()
                }
            }
        }
    }
    
    deinit {
        // Remove notification observer
        NotificationCenter.default.removeObserver(self)
        
        // Clean up remaining observers
        queue.sync {
            for (_, observer) in self.timeObservers {
                observer.invalidate()
            }
        }
    }

    /// Video-specific errors
    enum VideoError: LocalizedError {
        case timeout
        case notPlayable
        case noTracks
        case noPlayerItem
        case playerFailed
        case unknown
        case trackCreationFailed

        var errorDescription: String? {
            switch self {
            case .timeout: return "Video loading timed out"
            case .notPlayable: return "Video is not playable"
            case .noTracks: return "No playable tracks found"
            case .noPlayerItem: return "Unable to create player item"
            case .playerFailed: return "Player initialization failed"
            case .unknown: return "An unknown error occurred"
            case .trackCreationFailed: return "Video track creation failed"
            }
        }
    }
}

/// Extension to run async tasks on a DispatchQueue
extension DispatchQueue {
    func asyncResult<T>(execute work: @escaping () async throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            self.async {
                Task {
                    do {
                        let result = try await work()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
