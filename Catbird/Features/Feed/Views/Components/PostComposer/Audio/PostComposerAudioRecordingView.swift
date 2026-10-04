//
//  PostComposerAudioRecordingView.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import SwiftUI
import AVFoundation
import Observation
import OSLog

private let composerAudioLogger = Logger(subsystem: "blue.catbird", category: "ComposerAudio")

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PostComposerAudioRecordingView: View {
  @ObservationIgnored @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var audioRecorder = AudioRecorderService()
  @State private var recordingStart = ComposerRecordingStart()
  @State private var showingPermissionAlert = false
  @State private var recordingPhase: RecordingPhase = .ready
  @State private var showingDiscardAlert = false
  @State private var audioPlaybackService = AudioPlaybackService()
  
  let onAudioRecorded: (URL) -> Void
  let onCancel: () -> Void
  
  // MARK: - Body
  
  var body: some View {
    NavigationStack {
      ZStack {
        Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
          .ignoresSafeArea()
        
        VStack(spacing: 0) {
          headerSection
          
          Spacer()
          
          recordingVisualizationSection
          
          Spacer()
          
          controlsSection
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 20)
      }
      .navigationTitle("Record Audio")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            handleCancel()
          }
        }
        
        if recordingPhase == .finished, let url = audioRecorder.currentRecordingURL {
          ToolbarItem(placement: .primaryAction) {
            Button("Next") {
              onAudioRecorded(url)
              dismiss()
            }
            .foregroundColor(.accentColor)
            .fontWeight(.semibold)
          }
        }
      }
      .task {
        await audioRecorder.checkMicrophonePermission()
        guard !Task.isCancelled, recordingStart.isPresented else { return }
        if !audioRecorder.hasPermission {
          showingPermissionAlert = true
        }
      }
      .alert("Microphone Permission Required", isPresented: $showingPermissionAlert) {
        Button("Settings") {
          openAppSettings()
        }
        Button("Cancel", role: .cancel) {
          recordingStart.cancelPendingStart()
          onCancel()
          dismiss()
        }
      } message: {
        Text("Please allow microphone access in Settings to record audio.")
      }
      .alert("Start New Recording?", isPresented: $showingDiscardAlert) {
        Button("Start New", role: .destructive) {
          recordingStart.cancelPendingStart()
          audioPlaybackService.stop()
          audioRecorder.cancelRecording()
          recordingPhase = .ready
        }
        Button("Keep Current", role: .cancel) { }
      } message: {
        Text("This will replace your current recording.")
      }
    }
    .onAppear { recordingStart.activate() }
    .onChange(of: audioRecorder.isRecording) { _, isRecording in
      if !isRecording, recordingStart.isPresented, !recordingStart.isPending,
         recordingPhase == .recording {
        recordingPhase = .finished
      }
    }
    .onDisappear {
      recordingStart.invalidate()
      audioRecorder.stopRecording()
      audioPlaybackService.stop()
    }
  }
  
  // MARK: - View Sections
  
  private var headerSection: some View {
    VStack(spacing: 16) {
      // User profile info
      HStack(spacing: 12) {
        if let profile = appState.currentUserProfile,
           let avatarURL = profile.avatar {
          AsyncImage(url: URL(string: avatarURL.description)) { image in
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } placeholder: {
            Circle()
              .fill(Color.systemGray5)
          }
          .frame(width: 50, height: 50)
          .clipShape(Circle())
        } else {
          Circle()
            .fill(Color.systemGray5)
            .frame(width: 50, height: 50)
        }
        
        VStack(alignment: .leading, spacing: 4) {
          if let profile = appState.currentUserProfile {
            Text(profile.displayName ?? "")
              .font(.headline)
              .foregroundColor(.primary)
            
            Text("@\(profile.handle.description)")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }
        
        Spacer()
      }
      .padding(.top, 20)
      
      // Recording status
      VStack(spacing: 8) {
        Text(recordingStatusText)
          .font(.title2)
          .fontWeight(.medium)
          .foregroundColor(.primary)
        
        if audioRecorder.isRecording {
          VStack(spacing: 4) {
            Text(audioRecorder.getRecordingDurationString())
              .font(.title2)
              .fontWeight(.bold)
              .foregroundColor(.accentColor)
              .monospacedDigit()
            
            Text("\(audioRecorder.getRemainingTimeString()) remaining")
              .font(.caption)
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
          .animation(.easeInOut(duration: 0.2), value: audioRecorder.recordingDuration)
        } else if recordingPhase == .finished {
          Text("Duration: \(audioRecorder.getRecordingDurationString())")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .monospacedDigit()
        }
      }
    }
  }
  
  private var recordingVisualizationSection: some View {
    VStack(spacing: 20) {
      // Waveform visualization
      WaveformView(
        samples: audioRecorder.waveformSamples,
        currentLevel: audioRecorder.recordingLevel,
        isRecording: audioRecorder.isRecording,
        accentColor: Color.accentColor
      )
      .frame(maxWidth: 300)
      .animation(.easeInOut(duration: 0.1), value: audioRecorder.waveformSamples)
      
      // Recording level indicator
      if audioRecorder.isRecording {
        VStack(spacing: 8) {
          Text("Recording Level")
            .font(.caption)
            .foregroundColor(.secondary)
          
          ProgressView(value: audioRecorder.recordingLevel, total: 1.0)
            .progressViewStyle(LinearProgressViewStyle(tint: Color.accentColor))
            .frame(width: 200)
            .animation(.easeOut(duration: 0.05), value: audioRecorder.recordingLevel)
        }
      }
    }
    .padding(.vertical, 40)
  }
  
  private var controlsSection: some View {
    VStack(spacing: 30) {
      // Main record button
      recordButton
      
      // Secondary controls
      if recordingPhase == .finished {
        HStack(spacing: 32) {
          Button(action: {
            showingDiscardAlert = true
          }) {
            VStack(spacing: 6) {
              Image(systemName: "arrow.clockwise")
                .font(.title2)
                .fontWeight(.medium)
              Text("New Recording")
                .font(.caption)
                .fontWeight(.medium)
            }
            .foregroundColor(.secondary)
          }
          
          Button(action: {
            togglePlayback()
          }) {
            VStack(spacing: 6) {
              Image(systemName: audioPlaybackService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .fontWeight(.medium)
              Text(audioPlaybackService.isPlaying ? "Pause" : "Preview")
                .font(.caption)
                .fontWeight(.medium)
            }
            .foregroundColor(.accentColor)
          }
        }
        
        // Playback progress
        if audioPlaybackService.isPlaying || audioPlaybackService.progress > 0 {
          VStack(spacing: 8) {
            ProgressView(
              value: max(0, min(audioPlaybackService.progress, audioRecorder.recordingDuration)), 
              total: max(0.1, audioRecorder.recordingDuration)
            )
            .progressViewStyle(LinearProgressViewStyle(tint: Color.accentColor))
              .frame(width: 200)
            
            Text("\(formatTime(audioPlaybackService.progress)) / \(audioRecorder.getRecordingDurationString())")
              .font(.caption)
              .fontWeight(.medium)
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
        }
      }
      
    }
  }
  
  private var recordButton: some View {
    Button(action: {
      handleRecordButtonTap()
    }) {
      ZStack {
        // Outer ring
        Circle()
          .stroke(
            recordButtonRingColor,
            lineWidth: audioRecorder.isRecording ? 8 : 4
          )
          .frame(width: 120, height: 120)
          .scaleEffect(audioRecorder.isRecording ? 1.1 : 1.0)
          .animation(.easeInOut(duration: 0.2), value: audioRecorder.isRecording)
        
        // Inner circle
        RoundedRectangle(cornerRadius: audioRecorder.isRecording ? 8 : 60)
          .fill(recordButtonFillColor)
          .frame(
            width: audioRecorder.isRecording ? 40 : 80,
            height: audioRecorder.isRecording ? 40 : 80
          )
          .animation(.easeInOut(duration: 0.3), value: audioRecorder.isRecording)
        
        // Icon for finished state
        if recordingPhase == .finished {
          Image(systemName: "checkmark")
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(.white)
            .scaleEffect(1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: recordingPhase)
        }
      }
    }
    .disabled(!audioRecorder.hasPermission || recordingStart.isPending)
    .opacity(audioRecorder.hasPermission ? 1.0 : 0.5)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
  }
  
  // MARK: - Computed Properties
  
  private var recordingStatusText: String {
    if recordingStart.isPending { return "Starting Recording…" }
    switch recordingPhase {
    case .ready:
      return "Tap to Record"
    case .recording:
      return "Recording"
    case .finished:
      return "Ready to Share"
    }
  }
  
  private var recordButtonRingColor: Color {
    switch recordingPhase {
    case .ready:
      return .accentColor
    case .recording:
      return .red
    case .finished:
      return .green
    }
  }
  
  private var recordButtonFillColor: Color {
    switch recordingPhase {
    case .ready:
      return .accentColor
    case .recording:
      return .red
    case .finished:
      return .green
    }
  }
  
  private var accessibilityLabel: String {
    if recordingStart.isPending { return "Starting recording" }
    switch recordingPhase {
    case .ready:
      return "Record audio"
    case .recording:
      return "Stop recording"
    case .finished:
      return "Recording complete"
    }
  }
  
  private var accessibilityHint: String {
    switch recordingPhase {
    case .ready:
      return "Tap to start recording audio"
    case .recording:
      return "Tap to stop recording"
    case .finished:
      return "Recording finished successfully"
    }
  }
  
  // MARK: - Actions
  
  private func handleRecordButtonTap() {
    switch recordingPhase {
    case .ready:
      startRecording()
    case .recording:
      stopRecording()
    case .finished:
      // Do nothing - checkmark is just for visual confirmation
      // Users can use "Use Recording" button or start new recording via discard
      break
    }
  }
  
  private func startRecording() {
    guard audioRecorder.hasPermission else { 
      showingPermissionAlert = true
      return 
    }
    
    recordingStart.start(
      operation: {
        try await audioRecorder.startRecording()
        return audioRecorder.isRecording
      },
      cancel: { audioRecorder.cancelRecording() },
      onStarted: { recordingPhase = .recording },
      onFailure: { recordingPhase = .ready }
    )
  }
  
  private func stopRecording() {
    audioRecorder.stopRecording()
    recordingPhase = .finished
  }
  
  private func togglePlayback() {
    guard let url = audioRecorder.currentRecordingURL else { return }
    
    if audioPlaybackService.isPlaying {
      audioPlaybackService.stop()
    } else {
      try? audioPlaybackService.play(url: url)
    }
  }
  
  private func handleCancel() {
    recordingStart.cancelPendingStart()
    // Stop any playback first
    audioPlaybackService.stop()
    
    if audioRecorder.isRecording {
      // If actively recording, stop and then ask about discarding
      audioRecorder.stopRecording()
      recordingPhase = .finished
      showingDiscardAlert = true
    } else if recordingPhase == .finished {
      // If finished recording, ask about discarding
      showingDiscardAlert = true
    } else {
      // If ready state or no recording, just cancel
      onCancel()
      dismiss()
    }
  }
  
  private func formatTime(_ timeInterval: TimeInterval) -> String {
    let minutes = Int(timeInterval) / 60
    let seconds = Int(timeInterval) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
  
  private func openAppSettings() {
    #if os(iOS)
    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(settingsURL)
    }
    #endif
  }
}

// MARK: - Supporting Types

/// Owns one activation attempt for this recording sheet, including its teardown.
@MainActor
@Observable
final class ComposerRecordingStart {
  private(set) var isPending = false
  private(set) var isPresented = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var cancelOperation: (@MainActor () -> Void)?
  @ObservationIgnored private var requestID: UUID?

  func activate() { isPresented = true }

  @discardableResult
  func start(operation: @escaping @MainActor () async throws -> Bool,
             cancel: @escaping @MainActor () -> Void,
             onStarted: @escaping @MainActor () -> Void,
             onFailure: @escaping @MainActor () -> Void) -> Bool {
    guard isPresented, task == nil else { return false }
    let request = UUID()
    requestID = request
    isPending = true
    cancelOperation = cancel
    task = Task { @MainActor in
      defer {
        isPending = false
        cancelOperation = nil
        requestID = nil
        task = nil
      }
      guard requestID == request, isPresented, !Task.isCancelled else { return }
      do {
        let started = try await operation()
        guard requestID == request, !Task.isCancelled, isPresented else {
          cancel()
          return
        }
        if started { onStarted() } else { onFailure() }
      } catch {
        cancel()
        guard requestID == request, !Task.isCancelled, isPresented else { return }
        onFailure()
      }
    }
    return true
  }

  func cancelPendingStart() {
    requestID = nil
    task?.cancel()
    cancelOperation?()
    // Keep the attempt occupied until its suspension returns and cleanup ends.
  }

  func invalidate() {
    isPresented = false
    cancelPendingStart()
  }
}

enum RecordingPhase {
  case ready
  case recording
  case finished
}

// MARK: - Audio Playback Service

@MainActor
protocol ComposerAudioPreviewPlayer: AnyObject {
  var delegate: (any AVAudioPlayerDelegate)? { get set }
  var currentTime: TimeInterval { get }
  @discardableResult func prepareToPlay() -> Bool
  func play() -> Bool
  func stop()
}

extension AVAudioPlayer: ComposerAudioPreviewPlayer { }

@MainActor @Observable
final class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {
  private var audioPlayer: (any ComposerAudioPreviewPlayer)?
  private var progressTimer: Timer?
  private let audioSession: any ImmediatePlaybackAudioSession
  private let makePlayer: (URL) throws -> any ComposerAudioPreviewPlayer
  private var playbackOwner: UUID?

  init(audioSession: any ImmediatePlaybackAudioSession = AudioSessionManager.shared,
       makePlayer: @escaping (URL) throws -> any ComposerAudioPreviewPlayer = { try AVAudioPlayer(contentsOf: $0) }) {
    self.audioSession = audioSession
    self.makePlayer = makePlayer
    super.init()
  }

  var isPlaying = false
  var progress: TimeInterval = 0.0
  
  func play(url: URL) throws {
    // Stop any current playback
    stop()
    
    let owner = UUID()
    do {
      try audioSession.acquireImmediatePlayback(owner: owner)
      playbackOwner = owner
      let player = try makePlayer(url)
      audioPlayer = player
      player.delegate = self
      guard player.prepareToPlay() else { throw AudioPlaybackError.playbackFailed }
      guard !Task.isCancelled, playbackOwner == owner else { throw CancellationError() }
      guard player.play() else { throw AudioPlaybackError.playbackFailed }
      isPlaying = true
      
      // Start progress timer
      progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.playbackOwner == owner, let player = self.audioPlayer else { return }
          self.progress = player.currentTime
        }
      }
      
    } catch {
      if playbackOwner == owner { stop() }
      throw error
    }
  }
  
  func stop() {
    audioPlayer?.stop()
    audioPlayer = nil
    isPlaying = false
    progressTimer?.invalidate()
    progressTimer = nil
    progress = 0.0
    
    if let owner = playbackOwner {
      playbackOwner = nil
      audioSession.releaseVideoPlayback(owner: owner)
    }
  }
  
  // MARK: - AVAudioPlayerDelegate

  func retirePlayback(_ player: any ComposerAudioPreviewPlayer) {
    guard audioPlayer === player else { return }
    stop()
  }
  
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in
      self.retirePlayback(player)
    }
  }
  
  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in
      self.retirePlayback(player)
      if let error { composerAudioLogger.debug("Audio playback decode error: \(error)") }
    }
  }

  isolated deinit {
    audioPlayer?.stop()
    progressTimer?.invalidate()
    if let owner = playbackOwner { audioSession.releaseVideoPlayback(owner: owner) }
  }
}

// MARK: - Audio Playback Errors

enum AudioPlaybackError: LocalizedError {
  case playbackFailed
  
  var errorDescription: String? {
    switch self {
    case .playbackFailed:
      return "Failed to start audio playback"
    }
  }
}

// MARK: - Preview

#if DEBUG
struct PostComposerAudioRecordingView_Previews: PreviewProvider {
  static var previews: some View {
    PostComposerAudioRecordingView(
      onAudioRecorded: { _ in },
      onCancel: { }
    )
  }
}
#endif
