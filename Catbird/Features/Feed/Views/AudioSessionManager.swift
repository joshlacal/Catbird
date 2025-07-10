//
//  AudioSessionManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 11/1/24.
//

import AVFoundation
import Foundation
import UIKit
import os.log

class AudioSessionManager {
  static let shared = AudioSessionManager()
  private var wasAudioPlayingBeforeInterruption = false
  private var isActive = false
  private var isPiPAudioSessionActive = false
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioSessionManager")

  private init() {
    // Configure audio session at startup to prevent auto-activation
    setupInitialAudioSession()

    // Register for interruption notifications
    setupNotificationObservers()
  }

  // MARK: - Setup

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
      // Use allowBluetooth and allowAirPlay for better PiP support
      try audioSession.setCategory(
        .playback, mode: .moviePlayback,
        options: [.mixWithOthers, .duckOthers, .allowBluetooth, .allowAirPlay])
      try audioSession.setActive(true)
      isActive = true
      logger.debug("Audio session activated for video with sound")
    } catch {
      logger.debug("Failed to configure audio session for unmute: \(error)")
    }
  }

  /// Configure audio session specifically for Picture-in-Picture playback
  func configureForPictureInPicture() {
    do {
      let audioSession = AVAudioSession.sharedInstance()

      // PiP requires playback category with specific options
      try audioSession.setCategory(
        .playback, mode: .moviePlayback,
        options: [.mixWithOthers, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
      try audioSession.setActive(true)
      isActive = true
      isPiPAudioSessionActive = true
      logger.debug("Audio session configured for Picture-in-Picture")
    } catch {
      logger.debug("Failed to configure audio session for PiP: \(error)")
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
      isPiPAudioSessionActive = false
      logger.debug("Audio session deactivated and set to ambient")
    } catch {
      logger.debug("Failed to deactivate audio session: \(error)")
    }
  }

  /// Reset PiP audio session state (call when PiP is no longer needed)
  func resetPiPAudioSession() {
    isPiPAudioSessionActive = false
    logger.debug("PiP audio session flag reset")
  }

  /// Ensures the app is in silent playback mode - used when autoplaying videos
  func configureForSilentPlayback() {
    // Don't configure audio session unless absolutely necessary
    // All our videos should be muted anyway, so no need to change the session
    logger.debug("Skipping silent playback config to preserve music - videos are muted anyway")
  }

  // MARK: - Notification Handlers

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

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
