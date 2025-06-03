//
//  VideoCoordinator.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import Foundation
import Observation
import SwiftUI
import AVKit

/// Manages video playback and state across the app

@MainActor
final class VideoCoordinator {
    static let shared = VideoCoordinator()
    
    // MARK: - Properties
    private(set) var activeVideos: [String: (model: VideoModel, player: AVPlayer, lastPlaybackTime: CMTime)] = [:]
    private var visibleVideoIDs: Set<String> = []
    private var currentlyPlayingVideoId: String?
    private var loopingWrappers: [String: LoopingPlayerWrapper] = [:]
    private var statusObservers: [String: Task<Void, Never>] = [:]
    
    // App settings for autoplay preference
    weak var appSettings: AppSettings? {
        didSet {
            // When app settings change, update playback states to respect new autoplay setting
            if appSettings !== oldValue {
                updatePlaybackStates()
            }
        }
    }
    
    // Cache for video positions with automatic eviction
    private let positionCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 100  // Adjust based on your needs
        return cache
    }()
    
    // MARK: - Initialization
    private init() {
        setupBackgroundHandling()
        
        // Explicitly request silent mode at initialization
        AudioSessionManager.shared.configureForSilentPlayback()
    }
    
    // MARK: - Autoplay Check
    
    /// Check if videos should autoplay based on user settings
    private func shouldAutoplayVideos() -> Bool {
        // Default to false if settings are not available (safer fallback)
        return appSettings?.autoplayVideos ?? false
    }
    
    // MARK: - Video Management
    
    /// Register a video to be managed by the coordinator
    // Update your register method to use the looping wrapper
    func register(_ model: VideoModel, player: AVPlayer) {
        // CRITICAL: Always start with muted playback
        player.isMuted = true
        player.volume = 0
        model.isMuted = true
        model.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false

        // Check cache for last position
        let lastPosition: CMTime
        if let seconds = positionCache.object(forKey: model.id as NSString)?.doubleValue {
            lastPosition = CMTime(seconds: seconds, preferredTimescale: 600)
        } else {
            lastPosition = .zero
        }
        
        // Create a looping wrapper for GIFs
        if model.type.isGif {
            // Create a looping wrapper for this player
            if loopingWrappers[model.id] == nil {
                if let wrapper = LoopingPlayerWrapper(fromPlayer: player) {
                    loopingWrappers[model.id] = wrapper
                    // Use the wrapped player instead
                    activeVideos[model.id] = (model, wrapper.player, lastPosition)
                } else {
                    // Fall back to original player if wrapper creation fails
                    activeVideos[model.id] = (model, player, lastPosition)
                }
            }
        } else {
            // Regular video, use normal player
            activeVideos[model.id] = (model, player, lastPosition)
        }
        
        // Update playback states after registration
        updatePlaybackStates()
    }

    /// Update visibility of a video model
    func updateVisibility(_ isVisible: Bool, for modelId: String) {
        // Cancel any pending visibility update tasks
        statusObservers[modelId]?.cancel()
        
        // Create new debounced task
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }
            
            if isVisible {
                visibleVideoIDs.insert(modelId)
            } else {
                visibleVideoIDs.remove(modelId)
                // Immediately pause videos that are no longer visible
                if let videoData = activeVideos[modelId], videoData.model.isPlaying {
                    pauseVideo(modelId)
                }
            }
            updatePlaybackStates()
        }
        
        statusObservers[modelId] = task
    }
    
    /// Force play a video (used when user taps on thumbnail)
    func forcePlayVideo(_ modelId: String) {
        guard let (model, player, lastPlaybackTime) = activeVideos[modelId] else { return }
        
        // Pause any currently playing video
        if let currentlyPlaying = currentlyPlayingVideoId,
           currentlyPlaying != modelId {
            pauseVideo(currentlyPlaying)
        }
        
        // Start playing the requested video
        player.seek(to: lastPlaybackTime)
        player.play()
        
        // Update states
        activeVideos[modelId]?.model.isPlaying = true
        currentlyPlayingVideoId = modelId
        
        // Ensure video is marked as visible
        visibleVideoIDs.insert(modelId)
    }
    
    // MARK: - Private Methods
    
    /// Configure a player for GIF-like behavior (looping, muted)
    private func configureGifPlayer(_ player: AVPlayer, for modelId: String) {
        // Ensure GIF player configuration
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        
        // Setup looping
        if let item = player.currentItem {
            let token = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
    }
    
    /// Update the playback state of all managed videos
    private func updatePlaybackStates() {
        Task { @MainActor in
            guard !Task.isCancelled else { return }
            
            // CRITICAL: Ensure silent mode
            AudioSessionManager.shared.configureForSilentPlayback()
            
            // Find the top visible video
            let topVideoId = activeVideos.keys
                .filter { visibleVideoIDs.contains($0) }
                .sorted { id1, id2 in
                    // Prioritize GIFs over regular videos
                    let isGif1 = activeVideos[id1]?.model.type.isGif ?? false
                    let isGif2 = activeVideos[id2]?.model.type.isGif ?? false
                    if isGif1 != isGif2 {
                        return isGif1
                    }
                    return id1 < id2  // Stable sort for same types
                }
                .first
            
            // Update players based on visibility
            for (id, (model, player, lastPlaybackTime)) in activeVideos {
                // CRITICALLY IMPORTANT: Always ensure videos are muted during auto-playback
                player.isMuted = true
                player.volume = 0
                
                if id == topVideoId {
                    // Play the top visible video if it's not already playing AND autoplay is enabled
                    if !model.isPlaying && shouldAutoplayVideos() {
                        player.seek(to: lastPlaybackTime)
                        player.play()
                        
                        // Update states
                        activeVideos[id]?.model.isPlaying = true
                        currentlyPlayingVideoId = id
                    } else if !shouldAutoplayVideos() && model.isPlaying {
                        // If autoplay is disabled but video is playing, pause it
                        pauseVideo(id)
                    }
                } else {
                    // Pause non-visible videos
                    if model.isPlaying {
                        pauseVideo(id)
                    }
                }
            }
        }
    }
    
    /// Pause a specific video
    private func pauseVideo(_ modelId: String) {
        guard let (model, player, _) = activeVideos[modelId] else { return }
        player.pause()
        model.isPlaying = false
        
        // IMPORTANT: Always ensure audio is muted when pausing
        player.isMuted = true
        player.volume = 0
        
        // Update the last playback time
        let currentTime = player.currentTime()
        activeVideos[modelId]?.lastPlaybackTime = currentTime
        
        if currentlyPlayingVideoId == modelId {
            currentlyPlayingVideoId = nil
        }
    }
    
    /// Unregister a video from management
    func unregister(_ modelId: String) {
        // Save position to cache before cleanup
        if let (_, player, _) = activeVideos[modelId] {
            let seconds = CMTimeGetSeconds(player.currentTime())
            positionCache.setObject(NSNumber(value: seconds), forKey: modelId as NSString)
            
            // CRITICAL: Ensure audio is muted before removing 
            player.isMuted = true
            player.volume = 0
        }
        
        // Clean up looping wrappers
        loopingWrappers.removeValue(forKey: modelId)

        statusObservers[modelId]?.cancel()
        statusObservers.removeValue(forKey: modelId)
        
        // Pause and remove the video
        if let (_, player, _) = activeVideos[modelId] {
            player.pause()
            if currentlyPlayingVideoId == modelId {
                currentlyPlayingVideoId = nil
            }
        }
        
        activeVideos.removeValue(forKey: modelId)
        visibleVideoIDs.remove(modelId)
        updatePlaybackStates()
    }

    // MARK: - Background Handling
    
    /// Set up notifications for app state changes
    private func setupBackgroundHandling() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBackgroundTransition()
                self?.savePlaybackPositions() // Save positions when going to background
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // CRITICAL: Ensure silent mode after returning from background
                AudioSessionManager.shared.configureForSilentPlayback()
                
                // Only after configuring audio, update player states
                self?.updatePlaybackStates()
            }
        }
        
        // Optionally handle app termination
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePlaybackPositions()
            }
        }
    }
    
    /// Handle transition to background mode
    private func handleBackgroundTransition() {
        for (modelId, (model, player, _)) in activeVideos {
            // CRITICAL: Ensure videos are muted when going to background
            player.isMuted = true
            player.volume = 0
            
            if model.isPlaying {
                // Save position to cache when going to background
                let seconds = CMTimeGetSeconds(player.currentTime())
                positionCache.setObject(NSNumber(value: seconds), forKey: modelId as NSString)
                pauseVideo(modelId)
            }
        }
    }

    // MARK: - Playback Position Persistence
    
    /// Save playback positions to UserDefaults
    private func savePlaybackPositions() {
        var positions: [String: Double] = [:]
        for (id, (_, player, _)) in activeVideos {
            positions[id] = CMTimeGetSeconds(player.currentTime())
        }
        UserDefaults(suiteName: "group.blue.catbird.shared")?.set(positions, forKey: "VideoPlaybackPositions")
    }
    
    /// Load playback positions from UserDefaults
    private func loadPlaybackPositions() -> [String: CMTime] {
        guard let positions = UserDefaults(suiteName: "group.blue.catbird.shared")?.dictionary(forKey: "VideoPlaybackPositions") as? [String: Double] else {
            return [:]
        }
        var cmTimePositions: [String: CMTime] = [:]
        for (id, seconds) in positions {
            cmTimePositions[id] = CMTime(seconds: seconds, preferredTimescale: 600)
        }
        return cmTimePositions
    }
    
    // Only use this method when explicitly requested by user action
    func setUnmuted(_ id: String, unmuted: Bool) {
        guard let (model, player, _) = activeVideos[id] else { return }
        
        if unmuted {
            // User explicitly wants sound
            AudioSessionManager.shared.handleVideoUnmute()
            player.isMuted = false
            player.volume = 1.0
            model.isMuted = false
            model.volume = 1.0
        } else {
            // User wants to mute
            AudioSessionManager.shared.handleVideoMute()
            player.isMuted = true
            player.volume = 0
            model.isMuted = true
            model.volume = 0
        }
    }
}
