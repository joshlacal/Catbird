import AVFoundation
import CatbirdMLSCore
import OSLog
import Petrel
import PetrelCatbird
import SwiftUI

private let voicePlayerLogger = Logger(subsystem: "blue.catbird", category: "VoicePlayer")

struct VoiceMessagePlayerView: View {
  let audioData: AudioEmbedData
  let isOwnMessage: Bool

  @State private var isPlaying = false
  @State private var progress: Double = 0
  @State private var isLoading = false
  @State private var loadError: String?
  @State private var audioPlayer: AVAudioPlayer?
  @State private var progressTimer: Timer?
  @State private var showTranscript = false

  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button(action: handleTap) {
          Group {
            if isLoading {
              ProgressView()
                .scaleEffect(0.8)
                .frame(width: 32, height: 32)
            } else if loadError != nil {
              Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.red.opacity(0.7))
            } else {
              Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(isOwnMessage ? .white : Color.accentColor)
            }
          }
        }
        .disabled(isLoading)

        VoiceWaveformView(
          waveform: audioData.waveform,
          progress: progress,
          accentColor: isOwnMessage ? .white : Color.accentColor,
          trackColor: isOwnMessage ? .white.opacity(0.3) : Color.secondary.opacity(0.3)
        )
        .frame(height: 28)
        .layoutPriority(-1)

        Text(formattedDuration)
          .font(.caption.monospacedDigit())
          .foregroundStyle(isOwnMessage ? .white.opacity(0.7) : .secondary)
          .fixedSize()
      }

      if let error = loadError {
        Text(error)
          .font(.caption2)
          .foregroundStyle(.red.opacity(0.8))
          .lineLimit(2)
      }

      if let transcript = audioData.transcript, !transcript.isEmpty {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            showTranscript.toggle()
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "text.quote")
              .font(.caption2)
            Text(showTranscript ? transcript : "Show transcript")
              .font(.caption2)
              .lineLimit(showTranscript ? nil : 1)
          }
          .foregroundStyle(isOwnMessage ? .white.opacity(0.7) : .secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(width: 240)
    .onDisappear {
      stopPlayback()
    }
  }

  // MARK: - Playback

  private func handleTap() {
    if loadError != nil {
      // Reset error and retry
      loadError = nil
      audioPlayer = nil
      Task { await startPlayback() }
    } else {
      togglePlayback()
    }
  }

  private func togglePlayback() {
    if isPlaying {
      stopPlayback()
    } else {
      Task { await startPlayback() }
    }
  }

  @MainActor
  private func startPlayback() async {
    if let player = audioPlayer {
      // Re-activate session for cached player
      configureAudioSession()
      player.play()
      isPlaying = true
      startProgressTimer()
      return
    }

    isLoading = true
    loadError = nil

    // Step 1: Fetch encrypted blob via com.atproto.space.getBlob (I14)
    voicePlayerLogger.info("[play] fetching space blob \(audioData.blobId)")
    let encryptedData: Data
    do {
      let fetchResult = try await MLSSpaceBlobLocator.fetchEncryptedBlob(
        blobId: audioData.blobId,
        using: appState.client
      )
      guard (200..<300).contains(fetchResult.responseCode), let data = fetchResult.data else {
        voicePlayerLogger.error("[play] blob fetch failed: HTTP \(fetchResult.responseCode)")
        loadError = "fetch: HTTP \(fetchResult.responseCode)"
        isLoading = false
        return
      }
      encryptedData = data
      voicePlayerLogger.info("[play] blob fetched: \(encryptedData.count) bytes")
    } catch {
      loadError = "fetch: \(error.localizedDescription)"
      isLoading = false
      return
    }

    // Step 2: Decrypt blob
    voicePlayerLogger.info("[play] decrypt: key=\(audioData.key.count)B iv=\(audioData.iv.count)B sha256=\(audioData.sha256.prefix(16))...")
    let decrypted: Data
    do {
      decrypted = try BlobCrypto.decrypt(
        ciphertext: encryptedData,
        key: audioData.key,
        iv: audioData.iv,
        expectedSHA256: audioData.sha256
      )
      voicePlayerLogger.info("[play] decrypted: \(decrypted.count) bytes")
    } catch {
      voicePlayerLogger.error("[play] decrypt failed: \(error)")
      loadError = "decrypt: \(error.localizedDescription)"
      isLoading = false
      return
    }

    // Step 3: Play decrypted audio container via AVAudioPlayer
    do {
      let player = try AVAudioPlayer(data: decrypted)
      player.prepareToPlay()
      voicePlayerLogger.info("[play] player ready: duration=\(player.duration)s")

      configureAudioSession()

      audioPlayer = player
      isLoading = false

      guard player.play() else {
        voicePlayerLogger.error("[play] player.play() returned false")
        loadError = "play: refused (try again)"
        audioPlayer = nil
        return
      }

      isPlaying = true
      startProgressTimer()
    } catch {
      isLoading = false
      loadError = "player: \(error.localizedDescription)"
      voicePlayerLogger.error("[play] AVAudioPlayer init failed: \(error)")
    }
  }

  private func stopPlayback() {
    audioPlayer?.pause()
    isPlaying = false
    stopProgressTimer()
  }

  private func configureAudioSession() {
    #if os(iOS)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true, options: [])
    } catch {
      voicePlayerLogger.warning("[play] audio session config failed: \(error)")
    }
    #endif
  }


  private func startProgressTimer() {
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
      guard let player = audioPlayer else { return }
      if player.isPlaying {
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
      } else {
        progress = 0
        isPlaying = false
        stopProgressTimer()
      }
    }
  }

  private func stopProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = nil
  }

  private var formattedDuration: String {
    let totalSeconds: Int
    if let player = audioPlayer, isPlaying {
      totalSeconds = Int(player.duration - player.currentTime)
    } else {
      totalSeconds = Int(audioData.durationMs / 1000)
    }
    let m = totalSeconds / 60
    let s = totalSeconds % 60
    return String(format: "%d:%02d", m, s)
  }
}

// MARK: - Voice Waveform View

struct VoiceWaveformView: View {
  let waveform: [Float]
  let progress: Double
  let accentColor: Color
  let trackColor: Color

  private let barSpacing: CGFloat = 2
  private let minBarWidth: CGFloat = 2

  var body: some View {
    GeometryReader { geo in
      let maxBars = max(1, Int(geo.size.width / (minBarWidth + barSpacing)))
      let displaySamples = downsample(waveform, to: min(waveform.count, maxBars))

      HStack(spacing: barSpacing) {
        ForEach(Array(displaySamples.enumerated()), id: \.offset) { index, sample in
          let barProgress = Double(index) / Double(max(displaySamples.count - 1, 1))
          let isActive = barProgress <= progress

          RoundedRectangle(cornerRadius: 1)
            .fill(isActive ? accentColor : trackColor)
            .frame(
              width: max(
                minBarWidth,
                (geo.size.width - CGFloat(displaySamples.count - 1) * barSpacing)
                  / CGFloat(displaySamples.count)
              ),
              height: max(3, CGFloat(sample) * geo.size.height)
            )
        }
      }
      .frame(maxHeight: .infinity, alignment: .center)
    }
    .clipped()
  }

  private func downsample(_ samples: [Float], to count: Int) -> [Float] {
    guard samples.count > count, count > 0 else { return samples }
    let chunkSize = Double(samples.count) / Double(count)
    return (0..<count).map { i in
      let start = Int(Double(i) * chunkSize)
      let end = min(Int(Double(i + 1) * chunkSize), samples.count)
      guard start < end else { return 0 }
      return samples[start..<end].max() ?? 0
    }
  }
}

#Preview {
  VoiceMessagePlayerView(
    audioData: AudioEmbedData(
      blobId: "test-blob",
      key: Data(),
      iv: Data(),
      sha256: "abc",
      contentType: "audio/ogg; codecs=opus",
      size: 5000,
      durationMs: 12500,
      waveform: (0..<64).map { _ in Float.random(in: 0.1...1.0) },
      transcript: "Hello, this is a test voice message."
    ),
    isOwnMessage: false
  )
  .frame(width: 280)
  .padding()
}
