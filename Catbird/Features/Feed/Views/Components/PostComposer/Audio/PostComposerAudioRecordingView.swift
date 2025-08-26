//
//  PostComposerAudioRecordingView.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import SwiftUI
import AVFoundation
import Observation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PostComposerAudioRecordingView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var audioRecorder = AudioRecorderService()
  @State private var showingPermissionAlert = false
  @State private var recordingPhase: RecordingPhase = .ready
  @State private var showingDiscardAlert = false
  
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
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            handleCancel()
          }
        }
        
        if recordingPhase == .finished, let url = audioRecorder.currentRecordingURL {
          ToolbarItem(placement: .primaryAction) {
            Button("Use Recording") {
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
        if !audioRecorder.hasPermission {
          showingPermissionAlert = true
        }
      }
      .alert("Microphone Permission Required", isPresented: $showingPermissionAlert) {
        Button("Settings") {
          openAppSettings()
        }
        Button("Cancel", role: .cancel) {
          onCancel()
          dismiss()
        }
      } message: {
        Text("Please allow microphone access in Settings to record audio.")
      }
      .alert("Discard Recording?", isPresented: $showingDiscardAlert) {
        Button("Discard", role: .destructive) {
          audioRecorder.cancelRecording()
          onCancel()
          dismiss()
        }
        Button("Keep Recording", role: .cancel) { }
      } message: {
        Text("This will delete your current recording.")
      }
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
          HStack(spacing: 16) {
            Text(audioRecorder.getRecordingDurationString())
              .font(.title3)
              .fontWeight(.semibold)
              .foregroundColor(.accentColor)
            
            Text("•")
              .foregroundColor(.accentColor)
              .font(.title3)
            
            Text("Remaining: \(audioRecorder.getRemainingTimeString())")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        } else if recordingPhase == .finished {
          Text("Duration: \(audioRecorder.getRecordingDurationString())")
            .font(.subheadline)
            .foregroundColor(.secondary)
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
      
      // Recording level indicator
      if audioRecorder.isRecording {
        VStack(spacing: 8) {
          Text("Recording Level")
            .font(.caption)
            .foregroundColor(.secondary)
          
          ProgressView(value: audioRecorder.recordingLevel, total: 1.0)
            .progressViewStyle(LinearProgressViewStyle(tint: Color.accentColor))
            .frame(width: 200)
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
        HStack(spacing: 40) {
          Button(action: {
            showingDiscardAlert = true
          }) {
            VStack(spacing: 8) {
              Image(systemName: "trash")
                .font(.title2)
              Text("Discard")
                .font(.caption)
            }
            .foregroundColor(.red)
          }
          
          Button(action: {
            playRecording()
          }) {
            VStack(spacing: 8) {
              Image(systemName: "play.circle")
                .font(.title2)
              Text("Play")
                .font(.caption)
            }
            .foregroundColor(.accentColor)
          }
        }
      }
      
      // Recording tips
      if recordingPhase == .ready {
        VStack(spacing: 8) {
          Text("Recording Tips:")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.primary)
          
          VStack(alignment: .leading, spacing: 4) {
            Text("• Hold down the record button to start")
            Text("• Keep device close for best quality")
            Text("• Maximum recording time: 60 seconds")
          }
          .font(.caption)
          .foregroundColor(.secondary)
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
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
        }
      }
    }
    .disabled(!audioRecorder.hasPermission)
    .opacity(audioRecorder.hasPermission ? 1.0 : 0.5)
  }
  
  // MARK: - Computed Properties
  
  private var recordingStatusText: String {
    switch recordingPhase {
    case .ready:
      return "Ready to Record"
    case .recording:
      return "Recording..."
    case .finished:
      return "Recording Complete"
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
  
  // MARK: - Actions
  
  private func handleRecordButtonTap() {
    switch recordingPhase {
    case .ready:
      startRecording()
    case .recording:
      stopRecording()
    case .finished:
      // Restart recording
      recordingPhase = .ready
      audioRecorder.cancelRecording()
    }
  }
  
  private func startRecording() {
    guard audioRecorder.hasPermission else { return }
    
    Task {
      do {
        try await audioRecorder.startRecording()
        recordingPhase = .recording
      } catch {
        print("Failed to start recording: \(error)")
        // Could show error alert here
      }
    }
  }
  
  private func stopRecording() {
    audioRecorder.stopRecording()
    recordingPhase = .finished
  }
  
  private func playRecording() {
    // TODO: Implement audio playback
    // For now, this is a placeholder
    print("Play recording functionality would be implemented here")
  }
  
  private func handleCancel() {
    if audioRecorder.isRecording {
      showingDiscardAlert = true
    } else if recordingPhase == .finished {
      showingDiscardAlert = true
    } else {
      onCancel()
      dismiss()
    }
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

enum RecordingPhase {
  case ready
  case recording
  case finished
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