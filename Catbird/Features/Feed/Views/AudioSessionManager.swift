//
//  AudioSessionManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 11/1/24.
//

import AVFoundation
import Foundation
import UIKit

class AudioSessionManager {
    static let shared = AudioSessionManager()
    private var wasAudioPlayingBeforeInterruption = false
    private var isActive = false
    
    private init() {
        // Configure audio session at startup to prevent auto-activation
        setupInitialAudioSession()
        
        // Register for interruption notifications
        setupNotificationObservers()
    }
    
    // MARK: - Setup
    
    private func setupInitialAudioSession() {
        do {
            // IMPORTANT: Set to ambient by default - this prevents our app from taking over audio
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            print("Initial audio session configured as ambient")
        } catch {
            print("Failed to configure initial audio session: \(error)")
        }
    }
    
    private func setupNotificationObservers() {
        // Register for interruption notifications to restore music
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // Watch for route changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // Watch app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }
    
    // MARK: - Public API
    
    /// Called when user unmutes a video - prepares audio session for playback
    func handleVideoUnmute() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Store music playback state before we interrupt it
            wasAudioPlayingBeforeInterruption = audioSession.isOtherAudioPlaying
            
            // Configure for playback that ducks but doesn't stop background audio
            try audioSession.setCategory(.playback, mode: .moviePlayback, 
                                       options: [.mixWithOthers, .duckOthers])
            try audioSession.setActive(true)
            isActive = true
            print("Audio session activated for video with sound")
        } catch {
            print("Failed to configure audio session for unmute: \(error)")
        }
    }
    
    /// Called when user mutes a video - returns audio session to ambient state
    func handleVideoMute() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Deactivate the session with notification to other audio apps
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Reset to ambient which doesn't affect other audio
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            isActive = false
            print("Audio session deactivated and set to ambient")
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    /// Ensures the app is in silent playback mode - used when autoplaying videos
    func configureForSilentPlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Only change settings if we're active - avoid unnecessary audio interruptions
            if isActive {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                isActive = false
                print("Reset to ambient mode for silent playback")
            }
        } catch {
            print("Error configuring for silent playback: \(error)")
        }
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Audio session interrupted - store state
            wasAudioPlayingBeforeInterruption = AVAudioSession.sharedInstance().isOtherAudioPlaying
            print("Audio session interrupted")
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            // Only automatically resume if the system says it's OK
            if options.contains(.shouldResume) {
                // We can't directly control other apps' playback, but we can make sure
                // our session isn't interfering
                configureForSilentPlayback()
                print("Audio interruption ended, reset to silent playback")
            }
            
        @unknown default:
            break
        }
    }
    
    @objc private func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        // Handle route changes that might affect playback
        switch reason {
        case .categoryChange:
            // If our category changes, ensure we're properly configured
            if AVAudioSession.sharedInstance().isOtherAudioPlaying && isActive {
                configureForSilentPlayback()
                print("Audio route changed - reset to silent playback")
            }
        default:
            break
        }
    }
    
    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        // When app becomes active, start in silent mode by default
        configureForSilentPlayback()
        print("App became active - configured for silent playback")
    }
    
    @objc private func handleAppWillResignActive(_ notification: Notification) {
        // When app resigns active, ensure we're not disrupting audio
        handleVideoMute()
        print("App resigned active - deactivated audio session")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
