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

protocol VideoPlaybackAudioSession: AnyObject {
  func acquireVideoPlayback(owner: UUID)
  func releaseVideoPlayback(owner: UUID)
}

/// For synchronous native playback starts (AVKit PiP and composer preview).
protocol ImmediatePlaybackAudioSession: VideoPlaybackAudioSession {
  func acquireImmediatePlayback(owner: UUID) throws
}

/// The manager invokes this boundary only on its serial session queue.
struct AudioSessionConfiguration: Equatable, Sendable {
  let category: String
  let mode: String
  let options: UInt
}

protocol AudioSessionDriving: Sendable {
  var isVideoPlayback: Bool { get }
  var isRecording: Bool { get }
  var isAmbient: Bool { get }
  var configuration: AudioSessionConfiguration { get }
  func restoreConfiguration(_ configuration: AudioSessionConfiguration) throws
  func activateVideoPlayback() throws
  func deactivatePlayback() throws
  func configureAmbient() throws
  func activateRecording() throws
}

private struct SystemAudioSession: AudioSessionDriving {
  var isAmbient: Bool {
    #if os(iOS)
    let category = AVAudioSession.sharedInstance().category
    return category == .ambient || category == .soloAmbient
    #else
    return true
    #endif
  }

  var configuration: AudioSessionConfiguration {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    return AudioSessionConfiguration(
      category: session.category.rawValue, mode: session.mode.rawValue,
      options: session.categoryOptions.rawValue
    )
    #else
    return AudioSessionConfiguration(category: "ambient", mode: "default", options: 0)
    #endif
  }

  func restoreConfiguration(_ configuration: AudioSessionConfiguration) throws {
    #if os(iOS)
    try AVAudioSession.sharedInstance().setCategory(
      .init(rawValue: configuration.category), mode: .init(rawValue: configuration.mode),
      options: .init(rawValue: configuration.options)
    )
    #endif
  }

  var isVideoPlayback: Bool {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    return session.category == .playback && session.mode == .moviePlayback
    #else
    return false
    #endif
  }

  var isRecording: Bool {
    #if os(iOS)
    let category = AVAudioSession.sharedInstance().category
    return category == .record || category == .playAndRecord || category == .multiRoute
    #else
    return false
    #endif
  }

  func activateVideoPlayback() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    // Bluetooth A2DP and AirPlay are implicit for output-only playback. The
    // allowBluetooth/allowAirPlay options apply to recording categories.
    try session.setCategory(
      .playback, mode: .moviePlayback,
      options: [.mixWithOthers]
    )
    try session.setActive(true)
    #endif
  }

  func deactivatePlayback() throws {
    #if os(iOS)
    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
  }

  func configureAmbient() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    if session.category != .ambient {
      try session.setCategory(.ambient, mode: .default)
    }
    #endif
  }

  func activateRecording() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)
    #endif
  }
}

/// Mutable ownership and all driver calls are confined to `sessionQueue`.
final class AudioSessionManager: ImmediatePlaybackAudioSession, @unchecked Sendable {
  static let shared = AudioSessionManager()
  private let driver: any AudioSessionDriving
  private var playbackOwners: Set<UUID> = []
  private var recordingOwners: Set<UUID> = []
  private var ownsVideoSession = false
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioSessionManager")

  /// Serial queue for all AVAudioSession work. Keeps the synchronous, IPC-blocking
  /// `setCategory`/`setActive` calls off the main thread (avoiding UI hangs) and
  /// serializes access to the manager's mutable state without locks.
  private let sessionQueue = DispatchQueue(label: "blue.catbird.audio-session")

  private convenience init() {
    self.init(driver: SystemAudioSession())
    #if os(iOS)
    // Preserve the system audio session until a playback owner needs it.
    setupInitialAudioSession()

    // Register for interruption notifications
    setupNotificationObservers()
    #else
    // macOS doesn't use AVAudioSession
    logger.debug("AudioSessionManager initialized for macOS - no audio session configuration needed")
    #endif
  }

  /// An injected driver avoids changing the device's shared session in tests.
  init(driver: any AudioSessionDriving) {
    self.driver = driver
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

  /// A lease belongs to one playback surface, including muted Picture in Picture.
  func acquireVideoPlayback(owner: UUID) {
    sessionQueue.async {
      self.playbackOwners.insert(owner)
      self.activateVideoSessionIfAllowed()
    }
  }

  func releaseVideoPlayback(owner: UUID) {
    sessionQueue.async {
      guard self.playbackOwners.remove(owner) != nil else { return }
      self.releaseVideoSessionIfUnused()
    }
  }

  enum PlaybackActivationError: Error { case recordingInProgress }

  /// AVKit and AVAudioPlayer start synchronously. Serialize their activation
  /// through the same recording-aware boundary and grant no lease on failure.
  /// Call from the playback caller, never from the manager's session queue.
  func acquireImmediatePlayback(owner: UUID) throws {
    try sessionQueue.sync {
      guard recordingOwners.isEmpty, !driver.isRecording else {
        throw PlaybackActivationError.recordingInProgress
      }
      let previousConfiguration = driver.configuration
      let canDeactivate = !hasVideoPlaybackOwner && !ownsVideoSession && driver.isAmbient
      do {
        try driver.activateVideoPlayback()
      } catch {
        // setCategory may succeed before setActive fails. Undo only our still-
        // installed category; never deactivate a retained or external consumer.
        if driver.isVideoPlayback, driver.configuration != previousConfiguration {
          if canDeactivate {
            do { try driver.deactivatePlayback() } catch {
              logger.debug("Failed to deactivate partial playback activation: \(error)")
            }
          }
          do {
            try driver.restoreConfiguration(previousConfiguration)
          } catch {
            logger.debug("Failed to restore playback configuration: \(error)")
          }
        }
        throw error
      }
      ownsVideoSession = true
      playbackOwners.insert(owner)
    }
  }

  /// Muted previews must not downgrade an audible video or a recording session.
  func configureForSilentPlayback() {
    sessionQueue.async {
      guard !self.hasVideoPlaybackOwner, self.recordingOwners.isEmpty, !self.driver.isRecording else { return }
      do {
        try self.driver.configureAmbient()
      } catch {
        self.logger.debug("Failed to configure ambient session: \(error)")
      }
    }
  }

  /// Returns after activation and propagates failures before a recorder starts.
  func configureForRecording(owner: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async {
        do {
          if self.recordingOwners.isEmpty {
            try self.driver.activateRecording()
            self.ownsVideoSession = false
          }
          self.recordingOwners.insert(owner)
          continuation.resume()
        } catch {
          // setCategory may succeed before setActive throws. Roll that partial
          // configuration back without granting a recording owner.
          self.restoreAfterRecording()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func resetAfterRecording(owner: UUID) {
    sessionQueue.async {
      guard self.recordingOwners.remove(owner) != nil, self.recordingOwners.isEmpty else { return }
      self.restoreAfterRecording()
    }
  }

  private func restoreAfterRecording() {
    // Do not undo a newer playback category installed after this recording.
    // This also leaves the session alone if recording activation failed before
    // changing its category.
    guard driver.isRecording else { return }
    do {
      try driver.deactivatePlayback()
      try driver.configureAmbient()
      ownsVideoSession = false
      if hasVideoPlaybackOwner { activateVideoSessionIfAllowed() }
    } catch {
      logger.debug("Failed to reset recording session: \(error)")
    }
  }

  private var hasVideoPlaybackOwner: Bool {
    !playbackOwners.isEmpty
  }

  private func activateVideoSessionIfAllowed() {
    // Respect managed recording ownership and any recording category installed
    // by another audio consumer.
    guard recordingOwners.isEmpty, !driver.isRecording else { return }
    do {
      try driver.activateVideoPlayback()
      ownsVideoSession = true
    } catch {
      logger.debug("Failed to activate video session: \(error)")
    }
  }

  private func releaseVideoSessionIfUnused() {
    guard !hasVideoPlaybackOwner, recordingOwners.isEmpty, ownsVideoSession else { return }
    // A recorder or audio preview may have replaced our category/mode since
    // acquisition. Do not deactivate that newer consumer's session.
    guard driver.isVideoPlayback else {
      ownsVideoSession = false
      return
    }
    do {
      try driver.deactivatePlayback()
      try driver.configureAmbient()
      ownsVideoSession = false
    } catch {
      logger.debug("Failed to release video session: \(error)")
    }
  }

  /// A queue barrier for deterministic tests of the injected session boundary.
  func waitForPendingConfiguration() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sessionQueue.async { continuation.resume() }
    }
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
      AVAudioSession.RouteChangeReason(rawValue: reasonValue) != nil
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
