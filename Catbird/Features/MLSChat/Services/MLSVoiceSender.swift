import AVFoundation
import CatbirdMLS
import CatbirdMLSCore
import Foundation
import OSLog
import Petrel

#if os(iOS)

private let mlsVoiceSenderLogger = Logger(subsystem: "blue.catbird", category: "MLSVoiceSender")

@Observable
final class MLSVoiceSender {
  enum RecordingState: Equatable {
    case idle
    case recording(duration: TimeInterval)
    case processing
    case previewing
    case sending
    case error(String)
  }

  struct VoicePreview {
    let localURL: URL
    let preparedData: FfiVoicePrepareResult
    let durationMs: UInt64
    let waveform: [Float]
  }

  var state: RecordingState = .idle

  private var audioRecorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var recordingStartTime: Date?
  private var displayLink: CADisplayLink?
  private let client: ATProtoClient

  init(client: ATProtoClient) {
    self.client = client
  }

  deinit {
    stopDisplayLink()
    audioRecorder?.stop()
    cleanupRecording()
  }

  // MARK: - Recording

  func startRecording() async throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    try session.setActive(true)

    let tempDir = FileManager.default.temporaryDirectory
    let url = tempDir.appendingPathComponent("voice_\(UUID().uuidString).wav")
    recordingURL = url

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]

    audioRecorder = try AVAudioRecorder(url: url, settings: settings)
    audioRecorder?.record()
    recordingStartTime = Date()
    state = .recording(duration: 0)
    startDisplayLink()
  }

  func cancelRecording() {
    stopDisplayLink()
    audioRecorder?.stop()
    audioRecorder = nil
    cleanupRecording()
    state = .idle
  }

  /// Stop recording, encode via Rust FFI, upload blob, and send as audio embed.
  func finishAndSend(
    convoId: String,
    manager: MLSConversationManager
  ) async throws {
    stopDisplayLink()
    audioRecorder?.stop()
    audioRecorder = nil
    state = .processing

    guard let url = recordingURL else {
      state = .error("No recording found")
      throw VoiceSendError.noRecording
    }

    defer { cleanupRecording() }

    do {
      // 1. Encode PCM → Opus + encrypt via free Rust FFI function
      let prepared = try ffiPrepareVoiceMessage(
        pcmPath: url.path,
        sampleRate: 48000
      )

      // 2. Upload encrypted blob via MLS blob service
      let (responseCode, output) = try await client.blue.catbird.mlschat.uploadBlob(
        data: prepared.encryptedBlob,
        mimeType: "application/octet-stream",
        convoId: convoId,
        stripMetadata: false
      )

      guard (200..<300).contains(responseCode), let blobId = output?.blobId else {
        let msg = responseCode == 413
          ? "Storage quota exceeded"
          : "Upload failed (\(responseCode))"
        state = .error(msg)
        throw VoiceSendError.uploadFailed(msg)
      }

      mlsVoiceSenderLogger.info("Uploaded voice blob \(blobId), \(prepared.size) bytes, \(prepared.durationMs)ms")

      // 3. Construct audio embed and send via MLS manager
      let audioEmbed = MLSAudioEmbed(
        blobId: blobId,
        key: prepared.key,
        iv: prepared.iv,
        sha256: prepared.sha256,
        contentType: "audio/ogg; codecs=opus",
        size: prepared.size,
        durationMs: prepared.durationMs,
        waveform: prepared.waveform,
        transcript: nil
      )

      _ = try await manager.sendMessage(
        convoId: convoId,
        plaintext: "",
        embed: .audio(audioEmbed)
      )

      state = .idle
    } catch let error as VoiceSendError {
      throw error
    } catch {
      state = .error(error.localizedDescription)
      throw error
    }
  }

  // MARK: - Display Link for Duration Updates

  private func startDisplayLink() {
    let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in
      guard let self, let start = self.recordingStartTime else { return }
      let duration = Date().timeIntervalSince(start)
      self.state = .recording(duration: duration)
    }, selector: #selector(DisplayLinkTarget.tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func cleanupRecording() {
    if let url = recordingURL {
      try? FileManager.default.removeItem(at: url)
      recordingURL = nil
    }
  }

  enum VoiceSendError: LocalizedError {
    case noRecording
    case uploadFailed(String)

    var errorDescription: String? {
      switch self {
      case .noRecording: return "No recording available"
      case .uploadFailed(let msg): return msg
      }
    }
  }
}

// MARK: - DisplayLink Target Helper

private final class DisplayLinkTarget: NSObject {
  let callback: () -> Void
  init(_ callback: @escaping () -> Void) {
    self.callback = callback
  }
  @objc func tick() {
    callback()
  }
}

#endif
