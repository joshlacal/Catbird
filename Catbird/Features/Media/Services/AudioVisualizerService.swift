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
  
  // Configuration - optimized for performance
  private let videoSize = CGSize(width: 480, height: 480)  // Even smaller for faster processing
  private let fps: Int32 = 10  // Lower FPS for much faster generation
  private let bitRate: Int = 500_000  // Lower bitrate
  
  // For testing - can be enabled for even faster generation
  private let testModeEnabled = false  // Set to true for ultra-fast testing
  
  private var optimizedVideoSize: CGSize {
    testModeEnabled ? CGSize(width: 240, height: 240) : videoSize
  }
  
  private var optimizedFPS: Int32 {
    testModeEnabled ? 5 : fps
  }
  
  // MARK: - Video Generation
  
  /// Generates a video from an audio recording with waveform visualization
  func generateVisualizerVideo(
    audioURL: URL,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval
  ) async throws -> URL {
    
    // Safety check: limit duration to prevent excessive processing
    let maxDuration: TimeInterval = 120 // 2 minutes maximum
    let clampedDuration = min(duration, maxDuration)
    
    if duration > maxDuration {
      logger.debug("Duration clamped from \(duration)s to \(clampedDuration)s for performance")
    }
    
    isGenerating = true
    progress = 0.0
    defer {
      isGenerating = false
      progress = 0.0
    }
    
    // Add overall timeout to prevent hanging
    let timeoutTask = Task {
      try await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds timeout
      throw VisualizerError.generationTimeout
    }
    defer { timeoutTask.cancel() }
    
    return try await withTaskCancellationHandler {
      try await performVideoGeneration(
        audioURL: audioURL,
        profileImage: profileImage,
        username: username,
        accentColor: accentColor,
        duration: clampedDuration
      )
    } onCancel: {
      timeoutTask.cancel()
    }
  }
  
  private func performVideoGeneration(
    audioURL: URL,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval
  ) async throws -> URL {
    
    let startTime = Date()
    
    // Step 1: Analyze audio waveform (20% progress)
    logger.debug("Starting audio analysis for duration: \(duration)s")
    let analysisStart = Date()
    let waveformData = try await waveformAnalyzer.analyzeAudioFile(at: audioURL)
    let analysisTime = Date().timeIntervalSince(analysisStart)
    logger.debug("Audio analysis completed in \(analysisTime)s, found \(waveformData.waveformPoints.count) waveform points")
    progress = 0.2
    
    // Step 2: Set up video writer (30% progress)
    logger.debug("Setting up video writer")
    let setupStart = Date()
    let outputURL = generateOutputURL()
    let assetWriter = try setupAssetWriter(outputURL: outputURL)
    let videoInput = try setupVideoInput()
    let audioInput = try setupAudioInput()
    
    assetWriter.add(videoInput)
    assetWriter.add(audioInput)
    let setupTime = Date().timeIntervalSince(setupStart)
    logger.debug("Video writer setup completed in \(setupTime)s")
    progress = 0.3
    
    // Step 3: Create pixel buffer adaptor
    logger.debug("Creating pixel buffer adaptor")
    let adaptorStart = Date()
    let pixelBufferAdaptor = setupPixelBufferAdaptor(videoInput: videoInput)
    let adaptorTime = Date().timeIntervalSince(adaptorStart)
    logger.debug("Pixel buffer adaptor created in \(adaptorTime)s")
    
    // Step 4: Start writing
    logger.debug("Starting asset writer session")
    let sessionStart = Date()
    guard assetWriter.startWriting() else {
      logger.error("Failed to start asset writer")
      throw VisualizerError.writerSetupFailed
    }
    
    assetWriter.startSession(atSourceTime: .zero)
    let sessionTime = Date().timeIntervalSince(sessionStart)
    logger.debug("Asset writer session started in \(sessionTime)s")
    progress = 0.4
    
    // Step 5: Generate video frames (40% to 80% progress)
    logger.debug("Starting video frame generation")
    let frameGenerationStart = Date()
    try await generateVideoFrames(
      pixelBufferAdaptor: pixelBufferAdaptor,
      waveformData: waveformData,
      profileImage: profileImage,
      username: username,
      accentColor: accentColor,
      duration: duration
    )
    let frameGenerationTime = Date().timeIntervalSince(frameGenerationStart)
    logger.debug("Video frame generation completed in \(frameGenerationTime)s")
    progress = 0.8
    
    // Step 6: Add audio track (80% to 90% progress)
    logger.debug("Adding audio track")
    let audioStart = Date()
    try await addAudioTrack(audioInput: audioInput, audioURL: audioURL, duration: duration)
    let audioTime = Date().timeIntervalSince(audioStart)
    logger.debug("Audio track added in \(audioTime)s")
    progress = 0.9
    
    // Step 7: Finalize video (90% to 100% progress)
    logger.debug("Finalizing video")
    let finalizeStart = Date()
    videoInput.markAsFinished()
    audioInput.markAsFinished()
    
    await assetWriter.finishWriting()
    let finalizeTime = Date().timeIntervalSince(finalizeStart)
    logger.debug("Video finalized in \(finalizeTime)s")
    progress = 1.0
    
    guard assetWriter.status == .completed else {
      logger.error("Asset writer failed with status: \(assetWriter.status.rawValue)")
      if let error = assetWriter.error {
        logger.error("Asset writer error: \(error)")
      }
      throw VisualizerError.writingFailed
    }
    
    generatedVideoURL = outputURL
    let totalTime = Date().timeIntervalSince(startTime)
    logger.debug("Video generation completed in \(totalTime)s total: \(outputURL)")
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
      AVVideoWidthKey: Int(optimizedVideoSize.width),
      AVVideoHeightKey: Int(optimizedVideoSize.height),
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
      kCVPixelBufferWidthKey as String: Int(optimizedVideoSize.width),
      kCVPixelBufferHeightKey as String: Int(optimizedVideoSize.height),
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
    
    let totalFrames = Int(duration * Double(optimizedFPS))
    let frameProgressIncrement = 0.4 / Double(totalFrames) // 40% of total progress
    
    logger.debug("Starting frame generation: \(totalFrames) frames at \(optimizedFPS) FPS")
    
    // Pre-calculate values to avoid repeated calculations
    let waveformPoints = waveformData.waveformPoints
    let frameTimeInterval = 1.0 / Double(optimizedFPS)
    
    // Process frames in smaller batches to prevent memory buildup
    let batchSize = 5
    let totalBatches = (totalFrames + batchSize - 1) / batchSize
    
    for batchIndex in 0..<totalBatches {
      let batchStartFrame = batchIndex * batchSize
      let batchEndFrame = min(batchStartFrame + batchSize, totalFrames)
      
      logger.debug("Processing batch \(batchIndex + 1)/\(totalBatches) (frames \(batchStartFrame)-\(batchEndFrame - 1))")
      
      for frameNumber in batchStartFrame..<batchEndFrame {
        let frameStartTime = Date()
        
        let currentTime = Double(frameNumber) * frameTimeInterval
        let presentationTime = CMTime(value: Int64(frameNumber), timescale: optimizedFPS)
        
        // Create ultra-simplified frame for speed
        let frameImage = try await renderUltraSimplifiedFrame(
          currentTime: currentTime,
          duration: duration,
          waveformPoints: waveformPoints,
          username: username,
          accentColor: accentColor
        )
        
        // Convert to pixel buffer
        guard let pixelBuffer = createPixelBuffer(from: frameImage, adaptor: pixelBufferAdaptor) else {
          throw VisualizerError.frameCreationFailed
        }
        
        // Wait for input to be ready with shorter timeout
        var waitCount = 0
        while !pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData && waitCount < 50 {
          try await Task.sleep(nanoseconds: 5_000_000) // 5ms
          waitCount += 1
        }
        
        if waitCount >= 50 {
          logger.debug("Timeout waiting for video input at frame \(frameNumber)")
          throw VisualizerError.frameAppendFailed
        }
        
        // Append pixel buffer
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
          logger.debug("Failed to append frame \(frameNumber)")
          throw VisualizerError.frameAppendFailed
        }
        
        progress += frameProgressIncrement
        
        let frameTime = Date().timeIntervalSince(frameStartTime)
        if frameTime > 0.5 { // Warn if frame takes more than 0.5 seconds
          logger.debug("Slow frame \(frameNumber): \(frameTime)s")
        }
      }
      
      // Give system a brief pause between batches
      try await Task.sleep(nanoseconds: 1_000_000) // 1ms
    }
    
    logger.debug("Completed frame generation")
  }
  
  // MARK: - Frame Rendering
  
  // Ultra-simplified frame rendering for maximum speed
  private func renderUltraSimplifiedFrame(
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: optimizedVideoSize)
    let image = renderer.image { context in
      renderUltraSimplifiedFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
        username: username,
        accentColor: accentColor
      )
    }
    return image.cgImage!
    #else
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: Int(optimizedVideoSize.width),
      height: Int(optimizedVideoSize.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    
    renderUltraSimplifiedFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor
    )
    
    return context.makeImage()!
    #endif
  }
  
  private func renderUltraSimplifiedFrameContent(
    context: CGContext,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color
  ) {
    // Background - solid color
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: optimizedVideoSize))
    
    // Ultra-simple waveform - just 5 bars
    let progress = currentTime / duration
    let barCount = 5
    let barWidth = optimizedVideoSize.width / CGFloat(barCount + 1)
    let centerY = optimizedVideoSize.height / 2
    
    #if os(iOS)
    context.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
    #else
    context.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    #endif
    
    for i in 0..<barCount {
      let x = CGFloat(i + 1) * barWidth - barWidth/4
      let heightMultiplier: CGFloat = i < Int(progress * Double(barCount)) ? 1.0 : 0.3
      let height: CGFloat = 40 * heightMultiplier
      
      context.fill(CGRect(
        x: x,
        y: centerY - height/2,
        width: barWidth/2,
        height: height
      ))
    }
    
    // Simple profile circle
    let circleSize: CGFloat = 60
    let circleRect = CGRect(
      x: (optimizedVideoSize.width - circleSize) / 2,
      y: (optimizedVideoSize.height - circleSize) / 2,
      width: circleSize,
      height: circleSize
    )
    
    #if os(iOS)
    context.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
    context.setStrokeColor(UIColor.white.cgColor)
    #else
    context.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    #endif
    context.fillEllipse(in: circleRect)
    context.setLineWidth(2)
    context.strokeEllipse(in: circleRect)
    
    // Simple timer text - just at top
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawUltraSimpleText(context: context, text: timerText, atTop: true)
    drawUltraSimpleText(context: context, text: "@\(username)", atTop: false)
  }
  
  private func drawUltraSimpleText(context: CGContext, text: String, atTop: Bool) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 18, weight: .medium),
      .foregroundColor: UIColor.white
    ]
    
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    let y: CGFloat = atTop ? 10 : optimizedVideoSize.height - textSize.height - 10
    let x: CGFloat = (optimizedVideoSize.width - textSize.width) / 2
    
    let rect = CGRect(x: x, y: y, width: textSize.width, height: textSize.height)
    attributedString.draw(in: rect)
  }
  
  // Simplified frame rendering for better performance
  private func renderSimplifiedFrame(
    frameNumber: Int,
    totalFrames: Int,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderSimplifiedFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
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
    
    renderSimplifiedFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor
    )
    
    return context.makeImage()!
    #endif
  }
  
  private func renderSimplifiedFrameContent(
    context: CGContext,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color
  ) {
    // Background
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: optimizedVideoSize))
    
    // Simple waveform (just bars, no complex scrolling)
    drawSimpleWaveform(
      context: context,
      waveformPoints: waveformPoints,
      currentTime: currentTime,
      duration: duration
    )
    
    // Simple profile circle (just a placeholder circle)
    drawSimpleProfileCircle(context: context)
    
    // Timer and username
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawSimpleText(context: context, text: timerText, position: .topLeft, size: 24)
    drawSimpleText(context: context, text: "@\(username)", position: .topRight, size: 24)
  }
  
  private func drawSimpleWaveform(
    context: CGContext,
    waveformPoints: [WaveformPoint],
    currentTime: TimeInterval,
    duration: TimeInterval
  ) {
    guard !waveformPoints.isEmpty else { return }
    
    let waveformRect = CGRect(
      x: 40,
      y: videoSize.height * 0.4,
      width: videoSize.width - 80,
      height: videoSize.height * 0.2
    )
    
    let centerY = waveformRect.midY
    let maxHeight = waveformRect.height * 0.4
    
    #if os(iOS)
    context.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
    #else
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    #endif
    context.setLineWidth(2)
    
    // Draw simple bars
    let barCount = 20
    let barWidth = waveformRect.width / CGFloat(barCount)
    let progress = currentTime / duration
    
    for i in 0..<barCount {
      let x = waveformRect.minX + CGFloat(i) * barWidth
      let pointIndex = Int(Double(i) / Double(barCount) * Double(waveformPoints.count))
      let amplitude = pointIndex < waveformPoints.count ? CGFloat(waveformPoints[pointIndex].amplitude) : 0
      let height = amplitude * maxHeight
      
      let alpha: CGFloat = Double(i) / Double(barCount) < progress ? 1.0 : 0.3
      
      context.saveGState()
      context.setAlpha(alpha)
      context.fill(CGRect(x: x, y: centerY - height/2, width: barWidth - 2, height: height))
      context.restoreGState()
    }
  }
  
  private func drawSimpleProfileCircle(context: CGContext) {
    let size: CGFloat = 100
    let rect = CGRect(
      x: (videoSize.width - size) / 2,
      y: (videoSize.height - size) / 2,
      width: size,
      height: size
    )
    
    // Simple gray circle
    #if os(iOS)
    context.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
    context.setStrokeColor(UIColor.white.cgColor)
    #else
    context.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    #endif
    context.fillEllipse(in: rect)
    context.setLineWidth(3)
    context.strokeEllipse(in: rect)
  }
  
  private func drawSimpleText(context: CGContext, text: String, position: TextPosition, size: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: size, weight: .medium),
      .foregroundColor: UIColor.white
    ]
    
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    var rect: CGRect
    let margin: CGFloat = 20
    
    switch position {
    case .topLeft:
      rect = CGRect(x: margin, y: margin, width: textSize.width, height: textSize.height)
    case .topRight:
      rect = CGRect(
        x: videoSize.width - textSize.width - margin,
        y: margin,
        width: textSize.width,
        height: textSize.height
      )
    case .bottomLeft:
      rect = CGRect(
        x: margin,
        y: videoSize.height - textSize.height - margin,
        width: textSize.width,
        height: textSize.height
      )
    case .bottomRight:
      rect = CGRect(
        x: videoSize.width - textSize.width - margin,
        y: videoSize.height - textSize.height - margin,
        width: textSize.width,
        height: textSize.height
      )
    }
    
    attributedString.draw(in: rect)
  }
  
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
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: optimizedVideoSize))
    
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
    #if os(iOS)
    context.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
    #else
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    #endif
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
    #if os(iOS)
    context.setFillColor(UIColor.systemGray3.cgColor)
    #else
    context.setFillColor(NSColor.systemGray.cgColor)
    #endif
    context.fillEllipse(in: profileRect)
    
    // Add border
    #if os(iOS)
    context.setStrokeColor(UIColor.white.cgColor)
    #else
    context.setStrokeColor(NSColor.white.cgColor)
    #endif
    context.setLineWidth(4)
    context.strokeEllipse(in: profileRect)
  }
  
  private func drawText(context: CGContext, text: String, position: TextPosition, size: CGFloat) {
    #if os(iOS)
    let font = UIFont.systemFont(ofSize: size, weight: UIFont.Weight.medium)
    #else
    let font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight.medium)
    #endif
    #if os(iOS)
    let textColor = UIColor.white.withAlphaComponent(0.9)
    #else
    let textColor = NSColor.white.withAlphaComponent(0.9)
    #endif
    
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
    #if os(iOS)
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.5).cgColor)
    #else
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    #endif
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
  case generationTimeout
  
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
    case .generationTimeout:
      return "Video generation timed out"
    }
  }
}