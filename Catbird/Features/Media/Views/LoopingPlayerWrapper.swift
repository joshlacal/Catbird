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
        // We need the original player's item to set up looping
        guard let originalItem = originalPlayer.currentItem else {
            return nil
        }
        
        // Create a new item from the same asset
         let asset = originalItem.asset
                guard let newItem = ((asset as? AVURLAsset) != nil) ?
              AVPlayerItem(asset: asset) : nil else {
            return nil
        }
        
        // Copy important player settings
        let currentTime = originalPlayer.currentTime()
        let rate = originalPlayer.rate
        let isMuted = originalPlayer.isMuted
        let volume = originalPlayer.volume
        
        // Create queue player with a copy of the current item
        self.queuePlayer = AVQueuePlayer(playerItem: newItem)
        
        // Apply the original settings
        self.queuePlayer.seek(to: currentTime)
        self.queuePlayer.isMuted = isMuted
        self.queuePlayer.volume = volume
        
        // Create the looper with the queue player
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: newItem)
        
        // If the original was playing, start playing
        if rate > 0 {
            queuePlayer.play()
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
