//
//  AudioRecorderService.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import AVFoundation
import Foundation
import SwiftUI
import Observation
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

protocol AudioRecordingSession: AnyObject {
  @MainActor func configureForRecording(owner: UUID) async throws
  @MainActor func resetAfterRecording(owner: UUID)
}

extension AudioSessionManager: AudioRecordingSession {}

/// Only the recorder operations used by this service; tests need no microphone.
@MainActor
protocol AudioRecordingDevice: AnyObject {
  var delegate: (any AVAudioRecorderDelegate)? { get set }
  var isMeteringEnabled: Bool { get set }
  var isRecording: Bool { get }
  func prepareToRecord() -> Bool
  func record() -> Bool
  func stop()
  func updateMeters()
  func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecordingDevice {}

@MainActor @Observable
final class AudioRecorderService: NSObject {
  // MARK: - Properties
  
  private var audioRecorder: (any AudioRecordingDevice)?
  private var recordingSessionOwner: UUID?
  private let audioSession: any AudioRecordingSession
  private let recordingDirectory: URL
  private let makeRecorder: (URL, [String: Any]) throws -> any AudioRecordingDevice
  private var recordingTimer: Timer?
  private let audioLogger = Logger(subsystem: "blue.catbird", category: "AudioRecorderService")
  
  // Observable properties
  var isRecording: Bool = false
  var isStartingRecording: Bool { recordingSessionOwner != nil && !isRecording }
  var recordingDuration: TimeInterval = 0
  var recordingLevel: Float = 0.0
  var hasPermission: Bool = false
  var currentRecordingURL: URL?
  var maxDuration: TimeInterval = 60.0 // 60 seconds max
  
  // Waveform data for real-time visualization
  var waveformSamples: [Float] = []
  private var levelTimer: Timer?
  
  // MARK: - Initialization
  
  override convenience init() {
    self.init(
      audioSession: AudioSessionManager.shared,
      recordingDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
      makeRecorder: { try AVAudioRecorder(url: $0, settings: $1) }
    )
    setupAudioSession()
  }

  /// Injected construction does not query permission or touch the shared session.
  init(
    audioSession: any AudioRecordingSession,
    recordingDirectory: URL,
    makeRecorder: @escaping (URL, [String: Any]) throws -> any AudioRecordingDevice
  ) {
    self.audioSession = audioSession
    self.recordingDirectory = recordingDirectory
    self.makeRecorder = makeRecorder
    super.init()
  }
  
  isolated deinit {
    audioRecorder?.delegate = nil
    audioRecorder?.stop()
    recordingTimer?.invalidate()
    levelTimer?.invalidate()
    if let owner = recordingSessionOwner {
      audioSession.resetAfterRecording(owner: owner)
    }
  }

  // MARK: - Setup
  
  private func setupAudioSession() {
    #if os(iOS)
    Task { @MainActor in
      await checkMicrophonePermission()
    }
    #else
    // macOS handles permissions differently
    hasPermission = true
    #endif
  }
  
  // MARK: - Permission Handling
  
  func checkMicrophonePermission() async {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    
    switch session.recordPermission {
    case .granted:
      hasPermission = true
      audioLogger.debug("Microphone permission already granted")
      
    case .denied:
      hasPermission = false
      audioLogger.debug("Microphone permission denied")
      
    case .undetermined:
      hasPermission = await withCheckedContinuation { continuation in
        session.requestRecordPermission { granted in
          DispatchQueue.main.async {
            self.hasPermission = granted
            self.audioLogger.debug("Microphone permission requested: \(granted)")
            continuation.resume(returning: granted)
          }
        }
      }
      
    @unknown default:
      hasPermission = false
    }
    #else
    hasPermission = true
    #endif
  }
  
  // MARK: - Recording Controls
  
  func startRecording() async throws {
    guard hasPermission else {
      throw AudioRecordingError.permissionDenied
    }
    guard !isStartingRecording else { throw AudioRecordingError.recordingInProgress }
    guard !isRecording else {
      audioLogger.debug("Recording already in progress")
      return
    }

    let owner = UUID()
    recordingSessionOwner = owner
    do {
      try await audioSession.configureForRecording(owner: owner)
      try Task.checkCancellation()
      // Stop/cancel may run while session activation is suspended.
      guard recordingSessionOwner == owner else { throw CancellationError() }

      let recordingURL = recordingDirectory.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
      currentRecordingURL = recordingURL
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
      ]

      let recorder = try makeRecorder(recordingURL, settings)
      audioRecorder = recorder
      recorder.delegate = self
      recorder.isMeteringEnabled = true
      guard recorder.prepareToRecord(), recorder.record() else {
        throw AudioRecordingError.recordingFailed
      }

      isRecording = true
      recordingDuration = 0
      waveformSamples.removeAll()
      startTimers()
      audioLogger.debug("Started recording to: \(recordingURL)")
    } catch {
      if recordingSessionOwner == owner {
        stopRecording()
      } else {
        audioSession.resetAfterRecording(owner: owner)
      }
      throw error
    }
  }

  func stopRecording() {
    guard isRecording || recordingSessionOwner != nil else { return }
    let owner = recordingSessionOwner
    recordingSessionOwner = nil
    audioRecorder?.delegate = nil
    audioRecorder?.stop()
    audioRecorder = nil
    stopTimers()
    isRecording = false
    recordingLevel = 0.0
    if let owner { audioSession.resetAfterRecording(owner: owner) }
    audioLogger.debug("Stopped recording")
  }

  func cancelRecording() {
    stopRecording()
    
    // Clean up recording file
    if let url = currentRecordingURL {
      try? FileManager.default.removeItem(at: url)
      currentRecordingURL = nil
    }
    
    audioLogger.debug("Cancelled recording")
  }
  
  // MARK: - Timer Management
  
  private func startTimers() {
    // Duration timer (updates every 0.1 seconds)
    recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        
        self.recordingDuration += 0.1
        
        // Stop recording if max duration reached
        if self.recordingDuration >= self.maxDuration {
          self.stopRecording()
        }
      }
    }
    
    // Level monitoring timer (updates every 0.05 seconds for smooth animation)
    levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.updateAudioLevel()
      }
    }
  }
  
  private func stopTimers() {
    recordingTimer?.invalidate()
    recordingTimer = nil
    
    levelTimer?.invalidate()
    levelTimer = nil
  }
  
  private func updateAudioLevel() {
    guard let recorder = audioRecorder, recorder.isRecording else { return }
    
    recorder.updateMeters()
    let level = recorder.averagePower(forChannel: 0)
    
    // Convert decibel level to 0-1 range for visualization
    // -60 dB is considered silence, 0 dB is maximum
    let normalizedLevel = max(0, min(1, (level + 60) / 60))
    recordingLevel = normalizedLevel
    
    // Add to waveform samples for visualization
    waveformSamples.append(normalizedLevel)
    
    // Keep only recent samples for performance (last 5 seconds worth)
    let maxSamples = Int(5.0 / 0.05) // 5 seconds of samples
    if waveformSamples.count > maxSamples {
      waveformSamples.removeFirst(waveformSamples.count - maxSamples)
    }
  }
  
  // MARK: - Utility Methods
  
  func getRecordingDurationString() -> String {
    let minutes = Int(recordingDuration) / 60
    let seconds = Int(recordingDuration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
  
  func getRemainingTimeString() -> String {
    let remaining = maxDuration - recordingDuration
    let minutes = Int(remaining) / 60
    let seconds = Int(remaining) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderService: AVAudioRecorderDelegate {
  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let recorderID = ObjectIdentifier(recorder)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.audioRecorder.map(ObjectIdentifier.init) == recorderID else { return }
      if !flag {
        self.audioLogger.debug("Recording finished unsuccessfully")
        self.cancelRecording()
      } else {
        self.stopRecording()
        self.audioLogger.debug("Recording finished successfully")
      }
    }
  }
  
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    let recorderID = ObjectIdentifier(recorder)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.audioRecorder.map(ObjectIdentifier.init) == recorderID else { return }
      if let error {
        self.audioLogger.debug("Recording encode error: \(error)")
      }
      self.cancelRecording()
    }
  }
}

// MARK: - Error Types

enum AudioRecordingError: LocalizedError {
  case permissionDenied
  case recordingFailed
  case recordingInProgress
  case audioSessionError
  
  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone permission is required to record audio"
    case .recordingFailed:
      return "Failed to start audio recording"
    case .recordingInProgress:
      return "Audio recording is still starting"
    case .audioSessionError:
      return "Failed to configure audio session"
    }
  }
}
