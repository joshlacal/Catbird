//
//  EnhancedAudioVisualizerService.swift
//  Catbird
//
//  Enhanced audio visualization service that combines optimized waveform processing
//  with the existing video generation system for maximum performance
//

import AVFoundation
import Foundation
import SwiftUI
import os.log

@available(iOS 16.0, macOS 13.0, *)
@Observable
final class EnhancedAudioVisualizerService {
  private let logger = Logger(subsystem: "blue.catbird", category: "EnhancedAudioVisualizerService")
  
  // MARK: - Dependencies
  
  private let optimizedProcessor = OptimizedAudioWaveformProcessor()
  private let legacyAnalyzer = AudioWaveformAnalyzer()
  
  // MARK: - State
  
  var isProcessing: Bool = false
  var progress: Double = 0.0
  var currentWaveformData: OptimizedAudioWaveformProcessor.CompactWaveformData?
  var error: Error?
  
  // MARK: - Real-time Processing
  
  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var currentLiveData: (rms: Float, peak: Float, frequencies: [Float]) = (0, 0, [])
  
  // MARK: - Public Interface
  
  /// Process audio file and generate both waveform data and video
  func processAudioFile(
    at url: URL,
    targetWaveformPoints: Int = 200,
    generateVideo: Bool = true
  ) async throws -> (waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData, videoURL: URL?) {
    
    await MainActor.run {
      isProcessing = true
      progress = 0.0
      error = nil
      currentWaveformData = nil
    }
    
    do {
      // Step 1: Generate optimized waveform data
      await MainActor.run { progress = 0.1 }
      logger.debug("Starting optimized waveform processing")
      
      let waveformData = try await optimizedProcessor.processAudioFile(
        at: url,
        targetPoints: targetWaveformPoints
      )
      
      await MainActor.run {
        progress = 0.5
        currentWaveformData = waveformData
      }
      
      // Step 2: Generate video if requested
      var videoURL: URL?
      if generateVideo {
        logger.debug("Starting video generation")
        await MainActor.run { progress = 0.6 }
        
        // Use legacy system for video generation (already optimized)
        let legacyWaveformData = try await convertToLegacyFormat(waveformData)
        await MainActor.run { progress = 0.8 }
        
        videoURL = try await generateVisualizerVideo(
          from: url,
          waveformData: legacyWaveformData
        )
        
        await MainActor.run { progress = 0.95 }
      }
      
      await MainActor.run {
        progress = 1.0
        isProcessing = false
      }
      
      logger.info("Audio processing completed successfully")
      return (waveformData: waveformData, videoURL: videoURL)
      
    } catch {
      await MainActor.run {
        self.error = error
        isProcessing = false
      }
      logger.error("Audio processing failed: \(error.localizedDescription)")
      throw error
    }
  }
  
  /// Start real-time audio processing for live visualization
  func startRealtimeProcessing() throws {
    guard audioEngine == nil else { return }
    
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    
    // Install tap for real-time processing
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self = self else { return }
      
      let liveData = self.optimizedProcessor.processLiveAudioBuffer(buffer)
      
      Task { @MainActor in
        self.currentLiveData = liveData
      }
    }
    
    self.audioEngine = engine
    self.inputNode = inputNode
    
    try engine.start()
    logger.debug("Real-time audio processing started")
  }
  
  /// Stop real-time audio processing
  func stopRealtimeProcessing() {
    audioEngine?.stop()
    inputNode?.removeTap(onBus: 0)
    audioEngine = nil
    inputNode = nil
    
    currentLiveData = (0, 0, [])
    logger.debug("Real-time audio processing stopped")
  }
  
  /// Get current live audio data for visualization
  var liveAudioData: (rms: Float, peak: Float, frequencies: [Float]) {
    return currentLiveData
  }
  
  // MARK: - Private Methods
  
  private func convertToLegacyFormat(
    _ compactData: OptimizedAudioWaveformProcessor.CompactWaveformData
  ) async throws -> WaveformData {
    // Convert the compact format to legacy format for video generation
    var waveformPoints: [WaveformPoint] = []
    
    for i in 0..<compactData.pointCount {
      let point = WaveformPoint(
        timestamp: TimeInterval(compactData.timestamps[i]),
        amplitude: compactData.amplitudes[i],
        peak: compactData.peaks[i]
      )
      waveformPoints.append(point)
    }
    
    return WaveformData(
      samples: [], // Not needed for video generation
      waveformPoints: waveformPoints,
      duration: TimeInterval(compactData.duration),
      sampleRate: Int(compactData.sampleRate)
    )
  }
  
  private func generateVisualizerVideo(
    from audioURL: URL,
    waveformData: WaveformData
  ) async throws -> URL {
    
    let outputURL = generateOutputURL()
    
    // Use existing video generation logic with enhanced waveform data
      return try await withCheckedThrowingContinuation { continuation in
      Task {
        do {
          let videoGenerator = AudioVisualizerVideoGenerator()
          let generatedURL = try await videoGenerator.generateVideo(
            from: audioURL,
            waveformData: waveformData,
            outputURL: outputURL
          )
          continuation.resume(returning: generatedURL)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
  private func generateOutputURL() -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let fileName = "enhanced_audio_visualizer_\(UUID().uuidString).mp4"
    return documentsPath.appendingPathComponent(fileName)
  }
  
  // MARK: - Cleanup
  
  deinit {
    stopRealtimeProcessing()
    optimizedProcessor.cleanup()
  }
}

// MARK: - Audio Visualizer Video Generator

@available(iOS 16.0, macOS 13.0, *)
private actor AudioVisualizerVideoGenerator {
  
  func generateVideo(
    from audioURL: URL,
    waveformData: WaveformData,
    outputURL: URL
  ) async throws -> URL {
    
    // This would integrate with the existing AudioVisualizerService
    // video generation logic, but use the enhanced waveform data
    
    let asset = AVURLAsset(url: audioURL)
    let duration = try await asset.load(.duration)
    let durationSeconds = CMTimeGetSeconds(duration)
    
    // Set up video writer with optimized settings
    let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
    
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 1920,
      AVVideoHeightKey: 1080,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: 30
      ]
    ]
    
    let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoWriterInput.expectsMediaDataInRealTime = false
    
    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: 1920,
      kCVPixelBufferHeightKey as String: 1080,
      kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoWriterInput,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )
    
    guard videoWriter.canAdd(videoWriterInput) else {
      throw VideoGenerationError.cannotAddInput
    }
    
    videoWriter.add(videoWriterInput)
    
    // Add audio track
    let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
    guard videoWriter.canAdd(audioWriterInput) else {
      throw VideoGenerationError.cannotAddAudioInput
    }
    
    videoWriter.add(audioWriterInput)
    
    guard videoWriter.startWriting() else {
      throw VideoGenerationError.cannotStartWriting
    }
    
    videoWriter.startSession(atSourceTime: .zero)
    
    // Generate frames using enhanced waveform data
    try await generateVideoFrames(
      adaptor: adaptor,
      videoWriterInput: videoWriterInput,
      waveformData: waveformData,
      duration: durationSeconds
    )
    
    // Copy audio track
    try await copyAudioTrack(from: asset, to: audioWriterInput)
    
    videoWriterInput.markAsFinished()
    audioWriterInput.markAsFinished()
    
    await videoWriter.finishWriting()
    
    if let error = videoWriter.error {
      throw error
    }
    
    return outputURL
  }
  
  private func generateVideoFrames(
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    videoWriterInput: AVAssetWriterInput,
    waveformData: WaveformData,
    duration: TimeInterval
  ) async throws {
    
    let frameRate: Double = 30.0
    let frameDuration = CMTime(value: 1, timescale: Int32(frameRate))
    let totalFrames = Int(duration * frameRate)
    
    for frameIndex in 0..<totalFrames {
      while !videoWriterInput.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
      }
      
      let currentTime = Double(frameIndex) / frameRate
      let presentationTime = CMTime(value: Int64(frameIndex), timescale: Int32(frameRate))
      
      guard let pixelBufferPool = adaptor.pixelBufferPool else {
        throw VideoGenerationError.cannotCreatePixelBuffer
      }
      
      var pixelBuffer: CVPixelBuffer?
      let result = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
      
      guard result == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw VideoGenerationError.cannotCreatePixelBuffer
      }
      
      // Create the frame using enhanced waveform data
      try renderWaveformFrame(
        pixelBuffer: buffer,
        waveformData: waveformData,
        currentTime: currentTime,
        duration: duration
      )
      
      guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
        throw VideoGenerationError.cannotAppendFrame
      }
    }
  }
  
  private func renderWaveformFrame(
    pixelBuffer: CVPixelBuffer,
    waveformData: WaveformData,
    currentTime: TimeInterval,
    duration: TimeInterval
  ) throws {
    
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw VideoGenerationError.cannotAccessPixelBuffer
    }
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else {
      throw VideoGenerationError.cannotCreateContext
    }
    
    // Clear the frame
    context.setFillColor(red: 0.0, green: 0.0, blue: 0.1, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    
    // Draw enhanced waveform visualization
    drawEnhancedWaveform(
      in: context,
      waveformData: waveformData,
      currentTime: currentTime,
      duration: duration,
      width: width,
      height: height
    )
  }
  
  private func drawEnhancedWaveform(
    in context: CGContext,
    waveformData: WaveformData,
    currentTime: TimeInterval,
    duration: TimeInterval,
    width: Int,
    height: Int
  ) {
    
    let centerY = Double(height) / 2
    let maxAmplitude = Double(height) * 0.4
    let progress = currentTime / duration
    
    // Draw waveform bars with enhanced visual effects
    let pointWidth = Double(width) / Double(waveformData.waveformPoints.count)
    
    for (index, point) in waveformData.waveformPoints.enumerated() {
      let x = Double(index) * pointWidth
      let amplitude = Double(point.amplitude) * maxAmplitude
      let pointProgress = Double(index) / Double(waveformData.waveformPoints.count)
      
      // Color based on progress and frequency content
      let hue = pointProgress * 0.6 + 0.2 // Blue to purple range
      let saturation = 0.8
      let brightness = pointProgress <= progress ? 1.0 : 0.4
      
      context.setFillColor(
        CGColor(
          colorSpace: CGColorSpaceCreateDeviceRGB(),
          components: [
            CGFloat(hue),
            CGFloat(saturation), 
            CGFloat(brightness),
            1.0
          ]
        ) ?? CGColor.init(red: 0.5, green: 0.5, blue: 1.0, alpha: 1.0)
      )
      
      // Draw bar with enhanced visualization
      let barRect = CGRect(
        x: x,
        y: centerY - amplitude / 2,
        width: max(2, pointWidth - 1),
        height: amplitude
      )
      
      context.fillEllipse(in: barRect) // Use ellipse for smoother appearance
    }
    
    // Draw progress indicator
    let progressX = Double(width) * progress
    context.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.8)
    context.setLineWidth(3.0)
    context.move(to: CGPoint(x: progressX, y: 0))
    context.addLine(to: CGPoint(x: progressX, y: Double(height)))
    context.strokePath()
  }
  
  private func copyAudioTrack(from asset: AVAsset, to audioInput: AVAssetWriterInput) async throws {
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw VideoGenerationError.noAudioTrack
    }
    
    let audioReader = try AVAssetReader(asset: asset)
    let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    audioReader.add(audioReaderOutput)
    
    guard audioReader.startReading() else {
      throw VideoGenerationError.cannotStartReading
    }
    
    while audioReader.status == .reading {
      if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
        while !audioInput.isReadyForMoreMediaData {
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        audioInput.append(sampleBuffer)
      }
    }
  }
}

// MARK: - Error Types

private enum VideoGenerationError: LocalizedError {
  case cannotAddInput
  case cannotAddAudioInput
  case cannotStartWriting
  case cannotCreatePixelBuffer
  case cannotAppendFrame
  case cannotAccessPixelBuffer
  case cannotCreateContext
  case noAudioTrack
  case cannotStartReading
  
  var errorDescription: String? {
    switch self {
    case .cannotAddInput: return "Cannot add video input to writer"
    case .cannotAddAudioInput: return "Cannot add audio input to writer"
    case .cannotStartWriting: return "Cannot start video writing"
    case .cannotCreatePixelBuffer: return "Cannot create pixel buffer"
    case .cannotAppendFrame: return "Cannot append video frame"
    case .cannotAccessPixelBuffer: return "Cannot access pixel buffer data"
    case .cannotCreateContext: return "Cannot create graphics context"
    case .noAudioTrack: return "No audio track found in source"
    case .cannotStartReading: return "Cannot start reading audio"
    }
  }
}
