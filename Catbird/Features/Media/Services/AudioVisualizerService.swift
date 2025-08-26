//
//  AudioVisualizerService.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import AVFoundation
import SwiftUI
import CoreGraphics
import Observation
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor @Observable
final class AudioVisualizerService {
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioVisualizerService")
  private let waveformAnalyzer = AudioWaveformAnalyzer()
  
  // Observable properties
  var isGenerating: Bool = false
  var progress: Double = 0.0
  var generatedVideoURL: URL?
  
  // Configuration
  private let videoSize = CGSize(width: 1280, height: 720)
  private let fps: Int32 = 30
  private let bitRate: Int = 2_500_000
  
  // MARK: - Video Generation
  
  /// Generates a video from an audio recording with waveform visualization
  func generateVisualizerVideo(
    audioURL: URL,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval
  ) async throws -> URL {
    
    isGenerating = true
    progress = 0.0
    defer {
      isGenerating = false
      progress = 0.0
    }
    
    // Step 1: Analyze audio waveform (20% progress)
    logger.debug("Starting audio analysis")
    let waveformData = try await waveformAnalyzer.analyzeAudioFile(at: audioURL)
    progress = 0.2
    
    // Step 2: Set up video writer (30% progress)
    let outputURL = generateOutputURL()
    let assetWriter = try setupAssetWriter(outputURL: outputURL)
    let videoInput = try setupVideoInput()
    let audioInput = try setupAudioInput()
    
    assetWriter.add(videoInput)
    assetWriter.add(audioInput)
    progress = 0.3
    
    // Step 3: Create pixel buffer adaptor
    let pixelBufferAdaptor = setupPixelBufferAdaptor(videoInput: videoInput)
    
    // Step 4: Start writing
    guard assetWriter.startWriting() else {
      throw VisualizerError.writerSetupFailed
    }
    
    assetWriter.startSession(atSourceTime: .zero)
    progress = 0.4
    
    // Step 5: Generate video frames (40% to 80% progress)
    try await generateVideoFrames(
      pixelBufferAdaptor: pixelBufferAdaptor,
      waveformData: waveformData,
      profileImage: profileImage,
      username: username,
      accentColor: accentColor,
      duration: duration
    )
    progress = 0.8
    
    // Step 6: Add audio track (80% to 90% progress)
    try await addAudioTrack(audioInput: audioInput, audioURL: audioURL, duration: duration)
    progress = 0.9
    
    // Step 7: Finalize video (90% to 100% progress)
    videoInput.markAsFinished()
    audioInput.markAsFinished()
    
    await assetWriter.finishWriting()
    progress = 1.0
    
    guard assetWriter.status == .completed else {
      throw VisualizerError.writingFailed
    }
    
    generatedVideoURL = outputURL
    logger.debug("Video generation completed: \(outputURL)")
    return outputURL
  }
  
  // MARK: - Video Writer Setup
  
  private func setupAssetWriter(outputURL: URL) throws -> AVAssetWriter {
    // Remove existing file if it exists
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    
    return try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
  }
  
  private func setupVideoInput() throws -> AVAssetWriterInput {
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(videoSize.width),
      AVVideoHeightKey: Int(videoSize.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: 30
      ]
    ]
    
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    
    return videoInput
  }
  
  private func setupAudioInput() throws -> AVAssetWriterInput {
    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 128000
    ]
    
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = false
    
    return audioInput
  }
  
  private func setupPixelBufferAdaptor(videoInput: AVAssetWriterInput) -> AVAssetWriterInputPixelBufferAdaptor {
    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: Int(videoSize.width),
      kCVPixelBufferHeightKey as String: Int(videoSize.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    
    return AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )
  }
  
  // MARK: - Frame Generation
  
  private func generateVideoFrames(
    pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
    waveformData: WaveformData,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval
  ) async throws {
    
    let totalFrames = Int(duration * Double(fps))
    let frameProgressIncrement = 0.4 / Double(totalFrames) // 40% of total progress
    
    for frameNumber in 0..<totalFrames {
      let currentTime = Double(frameNumber) / Double(fps)
      let presentationTime = CMTime(value: Int64(frameNumber), timescale: fps)
      
      // Create frame image
      let frameImage = try await renderFrame(
        frameNumber: frameNumber,
        totalFrames: totalFrames,
        currentTime: currentTime,
        duration: duration,
        waveformData: waveformData,
        profileImage: profileImage,
        username: username,
        accentColor: accentColor
      )
      
      // Convert to pixel buffer
      guard let pixelBuffer = createPixelBuffer(from: frameImage, adaptor: pixelBufferAdaptor) else {
        throw VisualizerError.frameCreationFailed
      }
      
      // Wait for input to be ready
      while !pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
      }
      
      // Append pixel buffer
      guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw VisualizerError.frameAppendFailed
      }
      
      progress += frameProgressIncrement
    }
  }
  
  // MARK: - Frame Rendering
  
  private func renderFrame(
    frameNumber: Int,
    totalFrames: Int,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformData: WaveformData,
    profileImage: Image?,
    username: String,
    accentColor: Color
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformData: waveformData,
        profileImage: profileImage,
        username: username,
        accentColor: accentColor
      )
    }
    return image.cgImage!
    #else
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: Int(videoSize.width),
      height: Int(videoSize.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    
    renderFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformData: waveformData,
      profileImage: profileImage,
      username: username,
      accentColor: accentColor
    )
    
    return context.makeImage()!
    #endif
  }
  
  private func renderFrameContent(
    context: CGContext,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformData: WaveformData,
    profileImage: Image?,
    username: String,
    accentColor: Color
  ) {
    // Background
    context.setFillColor(UIColor(accentColor).cgColor)
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Waveform
    drawWaveform(
      context: context,
      waveformData: waveformData,
      currentTime: currentTime,
      duration: duration
    )
    
    // Profile picture (circular)
    if let profileImage = profileImage {
      drawProfileImage(context: context, image: profileImage)
    }
    
    // Timer (remaining time)
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawText(context: context, text: timerText, position: .topLeft, size: 40)
    
    // Username
    drawText(context: context, text: "@\(username)", position: .topRight, size: 40)
  }
  
  private func drawWaveform(
    context: CGContext,
    waveformData: WaveformData,
    currentTime: TimeInterval,
    duration: TimeInterval
  ) {
    let waveformRect = CGRect(
      x: 0,
      y: videoSize.height * 0.3,
      width: videoSize.width,
      height: videoSize.height * 0.4
    )
    
    let centerY = waveformRect.midY
    let maxAmplitude = waveformRect.height * 0.4
    
    // Draw waveform with scrolling effect
    context.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
    context.setLineWidth(3)
    
    let pointsToShow = 100 // Number of waveform points visible at once
    let progressRatio = currentTime / duration
    let startIndex = max(0, Int(Double(waveformData.waveformPoints.count) * progressRatio) - pointsToShow/2)
    let endIndex = min(waveformData.waveformPoints.count, startIndex + pointsToShow)
    
    if startIndex < endIndex {
      let visiblePoints = Array(waveformData.waveformPoints[startIndex..<endIndex])
      let xStep = waveformRect.width / CGFloat(pointsToShow)
      
      context.beginPath()
      for (index, point) in visiblePoints.enumerated() {
        let x = waveformRect.minX + CGFloat(index) * xStep
        let amplitude = CGFloat(point.amplitude) * maxAmplitude
        let y = centerY + amplitude * (index % 2 == 0 ? 1 : -1) // Alternating pattern
        
        if index == 0 {
          context.move(to: CGPoint(x: x, y: centerY))
        }
        context.addLine(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x, y: centerY - amplitude * (index % 2 == 0 ? 1 : -1)))
      }
      context.strokePath()
    }
  }
  
  private func drawProfileImage(context: CGContext, image: Image) {
    // For now, draw a placeholder circle
    // In a full implementation, we'd convert the SwiftUI Image to CGImage
    let profileSize: CGFloat = 200
    let profileRect = CGRect(
      x: (videoSize.width - profileSize) / 2,
      y: (videoSize.height - profileSize) / 2,
      width: profileSize,
      height: profileSize
    )
    
    // Draw circular background
    context.setFillColor(UIColor.systemGray3.cgColor)
    context.fillEllipse(in: profileRect)
    
    // Add border
    context.setStrokeColor(UIColor.white.cgColor)
    context.setLineWidth(4)
    context.strokeEllipse(in: profileRect)
  }
  
  private func drawText(context: CGContext, text: String, position: TextPosition, size: CGFloat) {
    let font = UIFont.systemFont(ofSize: size, weight: .medium)
    let textColor = UIColor.white.withAlphaComponent(0.9)
    
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor
    ]
    
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    var textRect: CGRect
    let margin: CGFloat = 40
    
    switch position {
    case .topLeft:
      textRect = CGRect(x: margin, y: margin, width: textSize.width, height: textSize.height)
    case .topRight:
      textRect = CGRect(
        x: videoSize.width - textSize.width - margin,
        y: margin,
        width: textSize.width,
        height: textSize.height
      )
    case .bottomLeft:
      textRect = CGRect(
        x: margin,
        y: videoSize.height - textSize.height - margin,
        width: textSize.width,
        height: textSize.height
      )
    case .bottomRight:
      textRect = CGRect(
        x: videoSize.width - textSize.width - margin,
        y: videoSize.height - textSize.height - margin,
        width: textSize.width,
        height: textSize.height
      )
    }
    
    // Draw text shadow
    context.saveGState()
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.5).cgColor)
    attributedString.draw(in: textRect)
    context.restoreGState()
  }
  
  // MARK: - Audio Track Addition
  
  private func addAudioTrack(audioInput: AVAssetWriterInput, audioURL: URL, duration: TimeInterval) async throws {
    let audioAsset = AVAsset(url: audioURL)
    
    guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
      throw VisualizerError.noAudioTrack
    }
    
    let audioReader = try AVAssetReader(asset: audioAsset)
    let audioReaderOutput = AVAssetReaderTrackOutput(
      track: audioTrack,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false
      ]
    )
    
    audioReader.add(audioReaderOutput)
    audioReader.startReading()
    
    while audioReader.status == .reading {
      if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
        while !audioInput.isReadyForMoreMediaData {
          try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        audioInput.append(sampleBuffer)
      }
    }
  }
  
  // MARK: - Utility Methods
  
  private func generateOutputURL() -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documentsPath.appendingPathComponent("audio_visualizer_\(Date().timeIntervalSince1970).mp4")
  }
  
  private func formatTime(_ timeInterval: TimeInterval) -> String {
    let minutes = Int(timeInterval) / 60
    let seconds = Int(timeInterval) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
  
  private func createPixelBuffer(from cgImage: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
    guard let pixelBufferPool = adaptor.pixelBufferPool else { return nil }
    
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
    
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
    
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    )
    
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(CVPixelBufferGetWidth(buffer)), height: CGFloat(CVPixelBufferGetHeight(buffer))))
    
    return buffer
  }
}

// MARK: - Supporting Types

enum TextPosition {
  case topLeft, topRight, bottomLeft, bottomRight
}

enum VisualizerError: LocalizedError {
  case writerSetupFailed
  case writingFailed
  case frameCreationFailed
  case frameAppendFailed
  case noAudioTrack
  
  var errorDescription: String? {
    switch self {
    case .writerSetupFailed:
      return "Failed to setup video writer"
    case .writingFailed:
      return "Failed to write video"
    case .frameCreationFailed:
      return "Failed to create video frame"
    case .frameAppendFailed:
      return "Failed to append video frame"
    case .noAudioTrack:
      return "No audio track found in recording"
    }
  }
}