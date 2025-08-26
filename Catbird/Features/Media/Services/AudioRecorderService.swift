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

@MainActor @Observable
final class AudioRecorderService: NSObject {
  // MARK: - Properties
  
  private var audioRecorder: AVAudioRecorder?
  private var recordingTimer: Timer?
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioRecorderService")
  
  // Observable properties
  var isRecording: Bool = false
  var recordingDuration: TimeInterval = 0
  var recordingLevel: Float = 0.0
  var hasPermission: Bool = false
  var currentRecordingURL: URL?
  var maxDuration: TimeInterval = 60.0 // 60 seconds max
  
  // Waveform data for real-time visualization
  var waveformSamples: [Float] = []
  private var levelTimer: Timer?
  
  // MARK: - Initialization
  
  override init() {
    super.init()
    setupAudioSession()
  }
  
  // MARK: - Setup
  
  private func setupAudioSession() {
    #if os(iOS)
    Task {
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
      logger.debug("Microphone permission already granted")
      
    case .denied:
      hasPermission = false
      logger.debug("Microphone permission denied")
      
    case .undetermined:
      hasPermission = await withCheckedContinuation { continuation in
        session.requestRecordPermission { granted in
          Task { @MainActor in
            self.hasPermission = granted
            self.logger.debug("Microphone permission requested: \(granted)")
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
    
    guard !isRecording else {
      logger.debug("Recording already in progress")
      return
    }
    
    // Configure audio session for recording
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)
    #endif
    
    // Create recording URL
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let recordingURL = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
    currentRecordingURL = recordingURL
    
    // Configure recorder settings
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44100.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    
    // Create and configure recorder
    audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
    audioRecorder?.delegate = self
    audioRecorder?.isMeteringEnabled = true
    audioRecorder?.prepareToRecord()
    
    // Start recording
    guard audioRecorder?.record() == true else {
      throw AudioRecordingError.recordingFailed
    }
    
    isRecording = true
    recordingDuration = 0
    waveformSamples.removeAll()
    
    // Start timers
    startTimers()
    
    logger.debug("Started recording to: \(recordingURL)")
  }
  
  func stopRecording() {
    guard isRecording else { return }
    
    audioRecorder?.stop()
    stopTimers()
    
    isRecording = false
    recordingLevel = 0.0
    
    // Deactivate audio session
    #if os(iOS)
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      logger.debug("Failed to deactivate audio session: \(error)")
    }
    #endif
    
    logger.debug("Stopped recording")
  }
  
  func cancelRecording() {
    stopRecording()
    
    // Clean up recording file
    if let url = currentRecordingURL {
      try? FileManager.default.removeItem(at: url)
      currentRecordingURL = nil
    }
    
    logger.debug("Cancelled recording")
  }
  
  // MARK: - Timer Management
  
  private func startTimers() {
    // Duration timer (updates every 0.1 seconds)
    recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in
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
      Task { @MainActor in
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
  
  // MARK: - Cleanup
  
  deinit {
    stopRecording()
    if let url = currentRecordingURL {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderService: AVAudioRecorderDelegate {
  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    Task { @MainActor in
      if !flag {
        logger.debug("Recording finished unsuccessfully")
        cancelRecording()
      } else {
        logger.debug("Recording finished successfully")
      }
    }
  }
  
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor in
      if let error = error {
        logger.debug("Recording encode error: \(error)")
        cancelRecording()
      }
    }
  }
}

// MARK: - Error Types

enum AudioRecordingError: LocalizedError {
  case permissionDenied
  case recordingFailed
  case audioSessionError
  
  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone permission is required to record audio"
    case .recordingFailed:
      return "Failed to start audio recording"
    case .audioSessionError:
      return "Failed to configure audio session"
    }
  }
}