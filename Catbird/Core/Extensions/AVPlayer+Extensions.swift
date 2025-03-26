//
//  AVPlayer+Extensions.swift
//  Catbird
//
//  Created for the Catbird project on 2/26/25.
//

import AVFoundation

extension AVPlayer {
    /// Safely plays video without activating the audio session
    func safePlay() {
        // Ensure muted to prevent audio interruption
        self.isMuted = true
        
        // Prevent automatic audio session activation
        self.preventsDisplaySleepDuringVideoPlayback = false
        
        // Now play
        self.play()
    }
}
