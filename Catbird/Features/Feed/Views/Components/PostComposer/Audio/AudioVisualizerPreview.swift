//
//  AudioVisualizerPreview.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import SwiftUI
import AVFoundation
import Observation

struct AudioVisualizerPreview: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var visualizerService = AudioVisualizerService()
  @State private var isGeneratingVideo = false
  @State private var generationError: String?
  @State private var showingErrorAlert = false
  
  let audioURL: URL
  let audioDuration: TimeInterval
  let onVideoGenerated: (URL) -> Void
  let onCancel: () -> Void
  
  // Preview state
  @State private var isPlaying = false
  @State private var currentTime: TimeInterval = 0
  @State private var playbackTimer: Timer?
  
  // Waveform data
  @State private var waveformAnalyzer = AudioWaveformAnalyzer()
  @State private var waveformData: [WaveformPoint] = []
  @State private var isLoadingWaveform = false
  
  var body: some View {
    NavigationStack {
      ZStack {
        Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
          .ignoresSafeArea()
        
        if isGeneratingVideo {
          generatingVideoView
        } else {
          previewContentView
        }
      }
      .navigationTitle("Audio Visualizer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            handleCancel()
          }
          .disabled(isGeneratingVideo)
        }
        
        ToolbarItem(placement: .primaryAction) {
          Button("Generate Video") {
            generateVideo()
          }
          .disabled(isGeneratingVideo)
          .foregroundColor(.accentColor)
          .fontWeight(.semibold)
        }
      }
      .alert("Generation Error", isPresented: $showingErrorAlert) {
        Button("OK") { }
      } message: {
        Text(generationError ?? "An unknown error occurred")
      }
      .task {
        await loadWaveformData()
      }
    }
  }
  
  // MARK: - Preview Content
  
  private var previewContentView: some View {
    VStack(spacing: 0) {
      // Header with user info
      headerSection
      
      // Main preview area
      previewVisualizationSection
      
      Spacer()
      
      // Controls
      controlsSection
        .padding(.bottom, 40)
    }
    .padding(.horizontal, 20)
  }
  
  private var headerSection: some View {
    VStack(spacing: 16) {
      HStack(spacing: 12) {
        // User avatar
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
          .frame(width: 60, height: 60)
          .clipShape(Circle())
          .overlay(
            Circle()
              .stroke(Color.white, lineWidth: 3)
          )
        } else {
          Circle()
            .fill(Color.systemGray5)
            .frame(width: 60, height: 60)
        }
        
        VStack(alignment: .leading, spacing: 4) {
          Text("Preview")
            .font(.headline)
            .foregroundColor(.primary)
          
          if let profile = appState.currentUserProfile {
            Text("@\(profile.handle.description)")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
          
          Text("Duration: \(formatDuration(audioDuration))")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        
        Spacer()
        
        // Accent color preview
        Circle()
          .fill(Color.accentColor)
          .frame(width: 20, height: 20)
          .overlay(
            Text("Theme")
              .font(.caption2)
              .foregroundColor(.white)
              .opacity(0.8)
          )
      }
      .padding(.top, 20)
      
      Divider()
        .padding(.vertical, 8)
    }
  }
  
  private var previewVisualizationSection: some View {
    VStack(spacing: 24) {
      // Mock video preview frame (properly constrained and clipped)
      ZStack {
        // Background with accent color + border
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.accentColor)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.primary.opacity(0.1), lineWidth: 1)

        // Content constrained to the same frame
        VStack(spacing: 16) {
          // Real waveform visualization
          realWaveformPreview

          // Profile picture placeholder
          if let profile = appState.currentUserProfile,
             let avatarURL = profile.avatar {
            AsyncImage(url: URL(string: avatarURL.description)) { image in
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
            } placeholder: {
              Circle()
                .fill(Color.white.opacity(0.3))
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            .overlay(
              Circle()
                .stroke(Color.white, lineWidth: 2)
            )
          } else {
            Circle()
              .fill(Color.white.opacity(0.3))
              .frame(width: 80, height: 80)
          }

          // Mock timer and username
          HStack {
            Text(formatDuration(max(0, audioDuration - currentTime)))
              .font(.title3)
              .fontWeight(.semibold)
              .foregroundColor(.white.opacity(0.9))

            Spacer()

            if let profile = appState.currentUserProfile {
              Text("@\(profile.handle.description)")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.9))
            }
          }
          .padding(.horizontal, 20)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity)
      .aspectRatio(16/9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)

      // Playback progress
      playbackProgressView
    }
    .padding(.vertical, 20)
  }
  
  private var realWaveformPreview: some View {
    HStack(alignment: .center, spacing: 2) {
      if isLoadingWaveform {
        // Show loading placeholder
        ForEach(0..<40, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.3))
            .frame(width: 3, height: 12)
        }
      } else if waveformData.isEmpty {
        // Fallback visualization if waveform data failed to load
        ForEach(0..<40, id: \.self) { index in
          let baseHeight = sin(Double(index) * 0.3) * 15 + 20
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.4))
            .frame(width: 3, height: max(4, CGFloat(baseHeight)))
        }
      } else {
        // Downsample to a fixed bar count to prevent overflow/perf spikes
        let maxBars = 120
        let step = max(1, waveformData.count / maxBars)
        ForEach(Array(stride(from: 0, to: waveformData.count, by: step)), id: \.self) { i in
          let waveformPoint = waveformData[i]
          let progress = currentTime / max(0.1, audioDuration)
          let barProgress = waveformPoint.timestamp / max(0.1, audioDuration)

          // Scale amplitude to appropriate height
          let baseHeight = CGFloat(waveformPoint.amplitude * 40 + 8) // Scale 0-1 to 8-48 pixels
          let activity = barProgress <= progress ? 1.0 : 0.3

          RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.8 * activity))
            .frame(width: 3, height: max(4, baseHeight))
        }
      }
    }
    .animation(.easeInOut(duration: 0.3), value: currentTime)
  }
  
  private var playbackProgressView: some View {
    VStack(spacing: 12) {
      // Progress bar
      ProgressView(
        value: max(0, min(currentTime, audioDuration)), 
        total: max(0.1, audioDuration)
      )
      .progressViewStyle(LinearProgressViewStyle(tint: Color.accentColor))
      
      // Time indicators
      HStack {
        Text(formatDuration(currentTime))
          .font(.caption)
          .foregroundColor(.secondary)
        
        Spacer()
        
        Text(formatDuration(audioDuration))
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }
  
  private var controlsSection: some View {
    VStack(spacing: 20) {
      // Play/Pause button
      Button(action: togglePlayback) {
        HStack(spacing: 12) {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.title2)
          
          Text(isPlaying ? "Pause Preview" : "Play Preview")
            .font(.headline)
            .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.accentColor, in: Capsule())
      }
      
      // Settings info
      VStack(spacing: 8) {
        Text("Video Settings")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
        
        VStack(alignment: .leading, spacing: 4) {
          Label("1920×1080 Full HD Quality", systemImage: "video")
          Label("30 FPS Smooth Animation", systemImage: "timer")
          Label("Your Theme Color", systemImage: "paintbrush")
          Label("Profile Picture Overlay", systemImage: "person.crop.circle")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .labelStyle(.trailingIcon)
      }
    }
  }
  
  // MARK: - Generating Video View
  
  private var generatingVideoView: some View {
    VStack(spacing: 32) {
      Spacer()
      
      // Progress indicator
      VStack(spacing: 20) {
        ProgressView(value: visualizerService.progress, total: 1.0)
          .progressViewStyle(CircularProgressViewStyle(tint: Color.accentColor))
          .scaleEffect(1.5)
        
        Text("Generating Video...")
          .font(.title2)
          .fontWeight(.medium)
          .foregroundColor(.primary)
        
        Text(progressText)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Spacer()
      
      // Cancel button
      Button("Cancel Generation") {
        handleCancel()
      }
      .foregroundColor(.red)
    }
    .padding(.horizontal, 40)
  }
  
  // MARK: - Computed Properties
  
  private var progressText: String {
    let progress = visualizerService.progress
    
    switch progress {
    case 0..<0.2:
      return "Analyzing audio waveform..."
    case 0.2..<0.4:
      return "Setting up video encoder..."
    case 0.4..<0.8:
      return "Rendering video frames..."
    case 0.8..<0.9:
      return "Adding audio track..."
    case 0.9..<1.0:
      return "Finalizing video..."
    default:
      return "Almost done..."
    }
  }
  
  // MARK: - Waveform Loading
  
  private func loadWaveformData() async {
    guard !isLoadingWaveform else { return }
    
    isLoadingWaveform = true
    
    do {
      let audioData = try await waveformAnalyzer.analyzeAudioFile(at: audioURL)
      await MainActor.run {
        waveformData = audioData.waveformPoints
        isLoadingWaveform = false
      }
    } catch {
      logger.debug("Failed to analyze audio waveform: \(error)")
      await MainActor.run {
        isLoadingWaveform = false
        // Keep waveformData empty, which will show a fallback visualization
      }
    }
  }
  
  // MARK: - Actions
  
  private func togglePlayback() {
    if isPlaying {
      stopPreview()
    } else {
      startPreview()
    }
  }
  
  private func startPreview() {
    isPlaying = true
    
    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      if currentTime >= audioDuration {
        stopPreview()
      } else {
        currentTime += 0.1
      }
    }
  }
  
  private func stopPreview() {
    isPlaying = false
    playbackTimer?.invalidate()
    playbackTimer = nil
  }
  
  private func resetPreview() {
    stopPreview()
    currentTime = 0
  }
  
  private func generateVideo() {
    guard !isGeneratingVideo else { return }
    
    isGeneratingVideo = true
    
    Task {
      do {
        let username = appState.currentUserProfile?.handle.description ?? "user"
        let avatarURL = appState.currentUserProfile?.avatar?.description
        let profileImage: Image? = nil // Profile will be fetched via avatarURL
        
        let videoURL = try await visualizerService.generateVisualizerVideo(
          audioURL: audioURL,
          profileImage: profileImage,
          username: username,
          accentColor: Color.accentColor,
          duration: audioDuration,
          avatarURL: avatarURL
        )
        
        await MainActor.run {
          isGeneratingVideo = false
          onVideoGenerated(videoURL)
          dismiss()
        }
        
      } catch {
        await MainActor.run {
          isGeneratingVideo = false
          generationError = error.localizedDescription
          showingErrorAlert = true
        }
      }
    }
  }
  
  private func handleCancel() {
    resetPreview()
    onCancel()
    dismiss()
  }
  
  private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

// MARK: - Custom Label Style

struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.title
      configuration.icon
    }
  }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
  static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

// MARK: - Preview

#if DEBUG
struct AudioVisualizerPreview_Previews: PreviewProvider {
  static var previews: some View {
    AudioVisualizerPreview(
      audioURL: URL(fileURLWithPath: "/tmp/test.m4a"),
      audioDuration: 30.0,
      onVideoGenerated: { _ in },
      onCancel: { }
    )
  }
}
#endif
