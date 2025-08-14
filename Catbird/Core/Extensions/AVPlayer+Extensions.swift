//
//  AVPlayer+Extensions.swift
//  Catbird
//
//  Created for the Catbird project on 2/26/25.
//

import AVFoundation
import AVKit

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
    
    /// Prepares the player for Picture-in-Picture mode
    func preparePiP() {
        // Ensure player is configured for PiP
        self.allowsExternalPlayback = true
        self.usesExternalPlaybackWhileExternalScreenIsActive = false
        
        // Configure for background playback if needed
        self.preventsDisplaySleepDuringVideoPlayback = true
    }
    
    /// Safely enters PiP mode with proper audio session handling
    func enterPiPMode() {
        // Configure audio session for PiP
        AudioSessionManager.shared.configureForPictureInPicture()
        
        // Prepare player for PiP
        preparePiP()
        
        // Ensure video is playing for PiP
        if rate == 0 {
            safePlay()
        }
    }
    
    /// Safely exits PiP mode and restores normal playback
    func exitPiPMode() {
        // Reset audio session
        AudioSessionManager.shared.resetPiPAudioSession()
        
        // Reset display sleep prevention for normal playback
        self.preventsDisplaySleepDuringVideoPlayback = false
    }
    
    /// Checks if the current item supports PiP
    var supportsPiP: Bool {
        guard let currentItem = currentItem else { return false }
        
        // Check if item has video tracks
        let hasVideoTracks = currentItem.tracks.contains { track in
            track.assetTrack?.mediaType == .video
        }
        
        // Check if PiP is supported on the device
        let deviceSupportsPiP = AVPictureInPictureController.isPictureInPictureSupported()
        
        return hasVideoTracks && deviceSupportsPiP && currentItem.status == .readyToPlay
    }
    
    /// Gets the current playback time in a PiP-safe format
    var pipSafeCurrentTime: CMTime {
        // Return a valid time even if player is not ready
        let current = currentTime()
        return current.isValid ? current : .zero
    }
}
