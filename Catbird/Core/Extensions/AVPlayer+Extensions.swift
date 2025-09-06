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
        self.automaticallyWaitsToMinimizeStalling = true
        
        // Now play
        if self.rate == 0 { self.play() }
    }
    
    /// Prepares the player for Picture-in-Picture mode
    func preparePiP() {
        #if os(iOS)
        // Ensure player is configured for PiP
        self.allowsExternalPlayback = true
        self.usesExternalPlaybackWhileExternalScreenIsActive = false
        
        // Configure for background playback if needed
        self.preventsDisplaySleepDuringVideoPlayback = true
        #else
        // PiP not available on macOS, do nothing
        #endif
    }
    
    /// Safely enters PiP mode with proper audio session handling
    func enterPiPMode() {
        #if os(iOS)
        // Configure audio session for PiP
        AudioSessionManager.shared.configureForPictureInPicture()
        
        // Prepare player for PiP
        preparePiP()
        
        // Ensure video is playing for PiP
        if rate == 0 {
            safePlay()
        }
        #else
        // PiP not available on macOS, just play normally
        if rate == 0 {
            safePlay()
        }
        #endif
    }
    
    /// Safely exits PiP mode and restores normal playback
    func exitPiPMode() {
        #if os(iOS)
        // Reset audio session
        AudioSessionManager.shared.resetPiPAudioSession()
        
        // Reset display sleep prevention for normal playback
        self.preventsDisplaySleepDuringVideoPlayback = false
        #else
        // PiP not available on macOS, just reset display sleep
        self.preventsDisplaySleepDuringVideoPlayback = false
        #endif
    }
    
    /// Checks if the current item supports PiP
    var supportsPiP: Bool {
        #if os(iOS)
        guard let currentItem = currentItem else { return false }
        
        // Check if item has video tracks
        let hasVideoTracks = currentItem.tracks.contains { track in
            track.assetTrack?.mediaType == .video
        }
        
        // Check if PiP is supported on the device
        let deviceSupportsPiP = AVPictureInPictureController.isPictureInPictureSupported()
        
        return hasVideoTracks && deviceSupportsPiP && currentItem.status == .readyToPlay
        #else
        // PiP not available on macOS
        return false
        #endif
    }
    
    /// Gets the current playback time in a PiP-safe format
    var pipSafeCurrentTime: CMTime {
        // Return a valid time even if player is not ready
        let current = currentTime()
        return current.isValid ? current : .zero
    }
}
