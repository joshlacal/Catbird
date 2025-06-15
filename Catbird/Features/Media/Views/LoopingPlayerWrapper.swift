//
//  LoopingPlayerWrapper.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/4/25.
//

import AVFoundation
import Foundation

/// A wrapper to handle looping playback using AVPlayerLooper
final class LoopingPlayerWrapper {
    private let queuePlayer: AVQueuePlayer
    private let playerLooper: AVPlayerLooper?
    
    // The wrapped AVQueuePlayer can be accessed as an AVPlayer
    var player: AVPlayer {
        return queuePlayer
    }
    
    // Initialize with an existing AVPlayer to preserve its configuration
    init?(fromPlayer originalPlayer: AVPlayer) {
        // Store the current time and settings before we potentially lose the item
        let currentTime = originalPlayer.currentTime()
        let rate = originalPlayer.rate
        let isMuted = originalPlayer.isMuted
        let volume = originalPlayer.volume
        let automaticallyWaits = originalPlayer.automaticallyWaitsToMinimizeStalling
        
        // Get the current item immediately - if not available, this wrapper cannot be created
        guard let originalItem = originalPlayer.currentItem else {
            return nil
        }
        
        // Get the asset - handle both URL and composition assets
        let asset = originalItem.asset
        
        // Create new player item with the same configuration
        let newItem = AVPlayerItem(asset: asset)
        
        // Copy audio mix settings from original
        if let audioMix = originalItem.audioMix {
            newItem.audioMix = audioMix
        }
        
        // Copy buffer settings optimized for GIF looping
        newItem.preferredForwardBufferDuration = min(originalItem.preferredForwardBufferDuration, 2.0)
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = originalItem.canUseNetworkResourcesForLiveStreamingWhilePaused
        
        // Copy other important item settings for GIFs
        newItem.seekingWaitsForVideoCompositionRendering = originalItem.seekingWaitsForVideoCompositionRendering
        newItem.preferredPeakBitRate = originalItem.preferredPeakBitRate
        
        // Create queue player with the new item
        self.queuePlayer = AVQueuePlayer(playerItem: newItem)
        
        // Apply the original settings
        self.queuePlayer.isMuted = isMuted
        self.queuePlayer.volume = volume
        self.queuePlayer.automaticallyWaitsToMinimizeStalling = automaticallyWaits
        self.queuePlayer.actionAtItemEnd = .none // Prevent default behavior, let looper handle it
        
        // Create the looper with the queue player - this handles seamless looping
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: newItem)
        
        // Seek to current position if needed
        if currentTime.seconds > 0 {
            queuePlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        // If the original was playing, start playing
        if rate > 0 {
            queuePlayer.rate = rate
        }
    }
    
    // Create a new wrapper with a URL
    init?(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        
        // Create queue player
        self.queuePlayer = AVQueuePlayer(playerItem: item)
        
        // Create the looper
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
    }
    
    deinit {
        // Clean up
        playerLooper?.disableLooping()
        queuePlayer.pause()
    }
}
