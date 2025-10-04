//
//  AudioSessionManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 11/1/24.
//

import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os.log

class AudioSessionManager {
  static let shared = AudioSessionManager()
  private var wasAudioPlayingBeforeInterruption = false
  private var isActive = false
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioSessionManager")

  private init() {
    #if os(iOS)
    // Configure audio session at startup to prevent auto-activation (iOS only)
    setupInitialAudioSession()

    // Register for interruption notifications
    setupNotificationObservers()
    #else
    // macOS doesn't use AVAudioSession
    logger.debug("AudioSessionManager initialized for macOS - no audio session configuration needed")
    #endif
  }

  // MARK: - Setup

  #if os(iOS)
  private func setupInitialAudioSession() {
    // Don't configure audio session at startup - leave the system default
    // This prevents us from taking over audio before we even need it
    logger.debug("Skipping initial audio session config to preserve music")
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
    #if os(iOS)
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
    #elseif os(macOS)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppWillResignActive),
      name: NSApplication.willResignActiveNotification,
      object: nil
    )
    #endif
  }
  #endif

  // MARK: - Public API

  /// Called when user unmutes a video - prepares audio session for playback
  func handleVideoUnmute() {
    #if os(iOS)
    do {
      let audioSession = AVAudioSession.sharedInstance()

      // Store music playback state before we interrupt it
      wasAudioPlayingBeforeInterruption = audioSession.isOtherAudioPlaying

      // Configure for playback that ducks but doesn't stop background audio
      // Use allowBluetooth and allowAirPlay for better audio support.
      // IMPORTANT: Do not use .duckOthers to avoid attenuating/interrupting other audio apps.
      try audioSession.setCategory(
        .playback, mode: .moviePlayback,
        options: [.mixWithOthers, .allowBluetooth, .allowAirPlay]
      )
      try audioSession.setActive(true)
      isActive = true
      logger.debug("Audio session activated for video with sound")
    } catch {
      logger.debug("Failed to configure audio session for unmute: \(error)")
    }
    #else
    // macOS doesn't require audio session configuration
    logger.debug("Video unmute handled - no audio session config needed on macOS")
    #endif
  }


  /// Called when user mutes a video - returns audio session to ambient state
  func handleVideoMute() {
    #if os(iOS)
    do {
      let audioSession = AVAudioSession.sharedInstance()

      // Deactivate the session with notification to other audio apps
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)

      // Reset to ambient which doesn't affect other audio
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      isActive = false
      logger.debug("Audio session deactivated and set to ambient")
    } catch {
      logger.debug("Failed to deactivate audio session: \(error)")
    }
    #else
    // macOS doesn't require audio session management
    isActive = false
    logger.debug("Video mute handled - no audio session changes needed on macOS")
    #endif
  }


  /// Ensures the app is in silent playback mode - used when autoplaying videos
  func configureForSilentPlayback() {
    #if os(iOS)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // Only configure if we're not already in ambient mode to avoid interruptions
      if audioSession.category != .ambient {
        try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        logger.debug("Configured ambient audio session for silent/muted playback (mix with others)")
      } else {
        logger.debug("Audio session already in ambient mode - no change needed")
      }
      // CRITICAL: Never activate the session here - let it remain inactive
      isActive = false
    } catch {
      logger.debug("Failed to configure ambient session for silent playback: \(error)")
    }
    #else
    logger.debug("Silent playback configuration not required on macOS")
    #endif
  }
  
  /// Configure audio session for recording
  func configureForRecording() {
    #if os(iOS)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      // Store music playback state before interrupting
      wasAudioPlayingBeforeInterruption = audioSession.isOtherAudioPlaying
      
      // Configure for recording with playback capability
      try audioSession.setCategory(
        .playAndRecord, 
        mode: .default, 
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try audioSession.setActive(true)
      isActive = true
      logger.debug("Audio session configured for recording")
    } catch {
      logger.debug("Failed to configure audio session for recording: \(error)")
    }
    #else
    // macOS doesn't require explicit audio session configuration for recording
    isActive = true
    logger.debug("Recording configuration not needed on macOS")
    #endif
  }
  
  /// Reset audio session after recording
  func resetAfterRecording() {
    #if os(iOS)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      // Deactivate the session with notification to other audio apps
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      
      // Return to ambient mode which doesn't interfere with other audio
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      isActive = false
      logger.debug("Audio session reset after recording - set to ambient mode")
    } catch {
      logger.debug("Failed to reset audio session after recording: \(error)")
    }
    #else
    // macOS doesn't require explicit session reset
    isActive = false
    logger.debug("Recording session reset on macOS")
    #endif
  }

  // MARK: - Notification Handlers

  #if os(iOS)
  @objc private func handleAudioSessionInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began:
      // Audio session interrupted - store state
      wasAudioPlayingBeforeInterruption = AVAudioSession.sharedInstance().isOtherAudioPlaying
      logger.debug("Audio session interrupted")

    case .ended:
      // Don't automatically configure audio session when interruption ends
      // This prevents us from taking over audio when music resumes
      logger.debug("Audio interruption ended - leaving audio session unchanged to preserve music")

    @unknown default:
      break
    }
  }

  @objc private func handleAudioRouteChange(notification: Notification) {
    guard let userInfo = notification.userInfo,
      let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else {
      return
    }

    // Don't automatically change audio session on route changes
    // This prevents interrupting music when headphones are plugged/unplugged
    logger.debug("Audio route changed - leaving audio session unchanged to preserve music")
  }

  @objc private func handleAppDidBecomeActive(_ notification: Notification) {
    // Don't automatically configure audio session when app becomes active
    // This allows music to continue playing
    logger.debug("App became active - leaving audio session unchanged to preserve music")
  }

  @objc private func handleAppWillResignActive(_ notification: Notification) {
    // Don't automatically mute when app resigns active
    // This prevents interrupting music when switching apps
    logger.debug("App resigned active - leaving audio session unchanged to preserve music")
  }
  #endif

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
