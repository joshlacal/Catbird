import AVFoundation
import CatbirdMLS
import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

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

    // Step 1: Fetch encrypted blob
    voicePlayerLogger.info("[play] fetching blob \(audioData.blobId)")
    let encryptedData: Data
    do {
      let (code, response) = try await appState.client.blue.catbird.mlschat.getBlob(
        input: .init(blobId: audioData.blobId)
      )
      guard (200..<300).contains(code), let output = response else {
        voicePlayerLogger.error("[play] blob fetch failed: HTTP \(code)")
        loadError = "fetch: HTTP \(code)"
        isLoading = false
        return
      }
      encryptedData = output.data
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

    // Step 3: Decode Opus → PCM via free Rust FFI function
    let pcmData: Data
    do {
      pcmData = try ffiDecodeOpusToPcm(opusData: decrypted)
      voicePlayerLogger.info("[play] decoded PCM: \(pcmData.count) bytes (\(pcmData.count / 2) samples)")
    } catch {
      voicePlayerLogger.error("[play] opus decode failed: \(error)")
      loadError = "decode: \(error.localizedDescription)"
      isLoading = false
      return
    }

    // Step 4: Build WAV in memory
    let sampleCount = pcmData.count / 2
    guard sampleCount > 0 else {
      voicePlayerLogger.error("[play] empty PCM data")
      loadError = "decode: empty audio"
      isLoading = false
      return
    }

    let wavData = buildWAV(pcmData: pcmData, sampleRate: 48000, channels: 1, bitsPerSample: 16)
    voicePlayerLogger.info("[play] WAV built: \(wavData.count) bytes, \(sampleCount) samples")

    // Step 5: Create player and play — configure session RIGHT before play()
    do {
      let player = try AVAudioPlayer(data: wavData)
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
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true, options: [])
    } catch {
      voicePlayerLogger.warning("[play] audio session config failed: \(error)")
    }
  }

  /// Build a WAV file in memory from raw PCM Int16 LE data.
  private func buildWAV(pcmData: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = UInt32(pcmData.count)
    let fileSize = 36 + dataSize

    var wav = Data(capacity: Int(44 + dataSize))
    wav.append(contentsOf: "RIFF".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM format
    wav.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    wav.append(pcmData)
    return wav
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

  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(Array(waveform.enumerated()), id: \.offset) { index, sample in
          let barProgress = Double(index) / Double(max(waveform.count - 1, 1))
          let isActive = barProgress <= progress

          RoundedRectangle(cornerRadius: 1)
            .fill(isActive ? accentColor : trackColor)
            .frame(
              width: max(
                2,
                (geo.size.width - CGFloat(waveform.count - 1) * 2)
                  / CGFloat(waveform.count)
              ),
              height: max(3, CGFloat(sample) * geo.size.height)
            )
        }
      }
      .frame(maxHeight: .infinity, alignment: .center)
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

#endif
