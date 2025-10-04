//
//  AVPlayer+Extensions.swift
//  Catbird
//
//  Created for the Catbird project on 2/26/25.
//

import AVFoundation
import AVKit
#if os(iOS)
import UIKit
#endif

extension AVPlayer {
    /// Safely plays video without activating the audio session
    func safePlay() {
        // Ensure muted to prevent audio interruption (avoid redundant sets)
        if self.isMuted == false { self.isMuted = true }
        
        // Prevent automatic audio session activation
        self.preventsDisplaySleepDuringVideoPlayback = false
        // Respect existing buffering strategy configured by the coordinator
        if self.rate == 0 {
            if self.automaticallyWaitsToMinimizeStalling {
                // For engaged playback, allow the player to buffer to reduce stutter
                self.play()
            } else if self.currentItem?.status == .readyToPlay {
                // For feed preview where we favor responsiveness, start immediately
                self.playImmediately(atRate: 1.0)
            } else {
                self.play()
            }
        }
    }
    
    
    
    
    
    
    /// Configure player/item for lightweight, muted preview in a scrolling feed
    /// Reduces decode/network pressure while keeping autoplay smooth
    func configureForFeedPreview() {
        guard let item = currentItem else { return }
        
        // Keep muted in preview to avoid audio session churn
        if !isMuted { isMuted = true }
        if volume != 0 { volume = 0 }
        
        // Favor responsive start over deep buffering
        automaticallyWaitsToMinimizeStalling = false
        item.preferredForwardBufferDuration = 2.0
        
        // Cap quality for small, in-feed rendering to reduce CPU/GPU work
        // ~1.2 Mbps is usually plenty for thumbnail-sized playback
        item.preferredPeakBitRate = 1_200_000
        
        // Cap resolution when available (keeps decoder load down for feed tiles)
        #if os(iOS)
        if #available(iOS 15.0, *) {
            item.preferredMaximumResolution = CGSize(width: 960, height: 540) // ~540p cap
        }
        #endif
        
        // When paused or offscreen, disallow network for live streams
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    }
    
    /// Configure player/item for an engaged experience (e.g., top visible, fullscreen, or unmuted)
    /// Restores buffer/quality so the system can pick higher variants when appropriate
    func configureForEngagedPlayback(isUnmuted: Bool) {
        guard let item = currentItem else { return }
        
        // Restore stalling minimization for smoother long-form playback
        automaticallyWaitsToMinimizeStalling = true
        item.preferredForwardBufferDuration = 5.0
        
        // Let ABR choose the optimal variant; 0 clears manual cap
        item.preferredPeakBitRate = 0
        
        #if os(iOS)
        if #available(iOS 15.0, *) {
            // .zero removes the cap and allows full resolution
            item.preferredMaximumResolution = .zero
        }
        #endif
        
        // When actively watched, allow network while paused (e.g., fast resume)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        
        // Respect requested audio state
        if isUnmuted {
            if isMuted { isMuted = false }
            if volume == 0 { volume = 1.0 }
        } else {
            if !isMuted { isMuted = true }
            if volume != 0 { volume = 0 }
        }
    }
}
