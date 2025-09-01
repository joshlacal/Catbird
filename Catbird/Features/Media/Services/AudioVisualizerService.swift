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
  
  // Configuration - adaptive quality settings
  private func getVideoSize(for duration: TimeInterval) -> CGSize {
    if duration > 120 { // > 2 minutes
      return CGSize(width: 960, height: 540) // Lower resolution for long recordings
    } else if duration > 60 { // > 1 minute  
      return CGSize(width: 1280, height: 720) // 720p for medium recordings
    } else {
      return CGSize(width: 1280, height: 720) // 720p for short recordings
    }
  }
  
  private func getFPS(for duration: TimeInterval) -> Int32 {
    if duration > 180 { // > 3 minutes
      return 24 // Lower FPS for very long recordings
    } else if duration > 60 { // > 1 minute
      return 30 // Standard FPS
    } else {
      return 30 // Standard FPS
    }
  }
  
  private func getBitRate(for size: CGSize, fps: Int32) -> Int {
    let pixelCount = Int(size.width * size.height)
    let baseRate = pixelCount / 1000 // Base calculation
    return max(baseRate * Int(fps) / 30, 2_000_000) // Minimum 2Mbps
  }
  
  // Video generation queue for proper threading
  private let videoQueue = DispatchQueue(label: "com.catbird.video-generation", qos: .userInitiated)
  
  // Frame generation state
  private var frameGenerationContinuation: CheckedContinuation<Void, Error>?
  
  // Profile image cache
  private var profileImageCache: CGImage?
  private var currentAvatarURL: String?
  
  // Memory management
  private var pixelBufferPool: CVPixelBufferPool?
  
  // Retry configuration
  private let maxRetryAttempts = 3
  private let baseRetryDelay: TimeInterval = 1.0 // seconds
  
  // MARK: - Retry Logic
  
  /// Executes a task with exponential backoff retry logic
  private func withRetry<T>(
    operation: @escaping () async throws -> T,
    context: String
  ) async throws -> T {
    var lastError: Error?
    
    for attempt in 1...maxRetryAttempts {
      do {
          logger.debug("\(context) - Attempt \(attempt)/\(self.maxRetryAttempts)")
        
        // Check system resources before attempting
        try checkSystemResources()
        
        let result = try await operation()
        
        if attempt > 1 {
          logger.debug("\(context) - Succeeded on attempt \(attempt)")
        }
        
        return result
        
      } catch let error {
        lastError = error
        logger.debug("\(context) - Attempt \(attempt) failed: \(error)")
        
        // Check if error is retryable
        if let visualizerError = error as? VisualizerError, !visualizerError.isRetryable {
          logger.debug("\(context) - Non-retryable error, aborting: \(visualizerError)")
          throw error
        }
        
        // If this was the last attempt, throw the error
        if attempt == maxRetryAttempts {
          logger.error("\(context) - All retry attempts failed")
          throw VisualizerError.maxRetriesExceeded(attempts: attempt)
        }
        
        // Calculate exponential backoff delay
        let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
        logger.debug("\(context) - Retrying in \(delay)s...")
        
        // Wait before retrying
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        
        // Clean up resources between attempts
        await cleanupResourcesForRetry()
      }
    }
    
    // This should never be reached, but satisfy the compiler
    throw lastError ?? VisualizerError.maxRetriesExceeded(attempts: maxRetryAttempts)
  }
  
  /// Checks system resources before attempting video generation
  private func checkSystemResources() throws {
    // Check available disk space
    if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      do {
        let resourceValues = try documentsPath.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let availableCapacity = resourceValues.volumeAvailableCapacity {
          // Require at least 100MB free space for video generation
          let requiredSpace: Int64 = 100 * 1024 * 1024
          if availableCapacity < requiredSpace {
            throw VisualizerError.diskSpaceInsufficient
          }
        }
      } catch {
        logger.debug("Could not check disk space: \(error)")
      }
    }
    
    // Check memory pressure (iOS specific)
    #if os(iOS)
      var memoryInfo = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    
    let result = withUnsafeMutablePointer(to: &memoryInfo) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    
    if result == KERN_SUCCESS {
      // More conservative memory limits for video generation
      let memoryUsage = memoryInfo.resident_size
      let memoryUsageMB = memoryUsage / (1024 * 1024)
      
      // For 720p video generation, be more conservative with memory limits
      let memoryLimit: UInt64 = 600 * 1024 * 1024 // 600MB limit
      
      if memoryUsage > memoryLimit {
        logger.debug("Memory pressure detected: \(memoryUsageMB)MB in use (limit: \(memoryLimit / (1024 * 1024))MB)")
        throw VisualizerError.memoryPressure
      }
      
      // Log memory usage for monitoring
      logger.debug("Current memory usage: \(memoryUsageMB)MB")
    }
    #endif
  }

  /// Returns current resident memory usage in MB (best-effort on iOS)
  private func currentMemoryUsageMB() -> UInt64? {
    #if os(iOS)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    if kr == KERN_SUCCESS {
      return info.resident_size / (1024 * 1024)
    }
    #endif
    return nil
  }
  
  /// Cleans up resources between retry attempts
  private func cleanupResourcesForRetry() async {
    // Clear any cached profile images to free memory
    profileImageCache = nil
    
    // Force garbage collection
    autoreleasepool { }
    
    // Small delay to let system recover
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
  }
  
  // MARK: - Profile Image Loading
  
  private func loadProfileImage(from image: Image?) async {
    // Clear previous cache
    profileImageCache = nil
    
    // Try to load from URL if we have one
    if let urlString = await getUserAvatarURL() {
      logger.debug("Loading profile image from URL: \(urlString)")
      await loadImageFromURL(urlString)
    } else {
      logger.debug("No avatar URL available, will use placeholder")
    }
  }
  
  private func getUserAvatarURL() async -> String? {
    return currentAvatarURL
  }
  
  private func loadImageFromURL(_ urlString: String) async {
    guard let url = URL(string: urlString) else {
      logger.debug("Invalid avatar URL: \(urlString)")
      return
    }
    
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      
      guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200 else {
        logger.debug("Failed to fetch avatar image: invalid response")
        return
      }
      
      guard let cgImage = createCGImage(from: data) else {
        logger.debug("Failed to create CGImage from downloaded data")
        return
      }
      
      // Cache the loaded image
      profileImageCache = cgImage
      logger.debug("Successfully cached profile image")
      
    } catch {
      logger.debug("Failed to download avatar image: \(error)")
      // Note: We don't throw here to allow video generation to continue with placeholder
    }
  }
  
  private func createCGImage(from data: Data) -> CGImage? {
    #if os(iOS)
    guard let uiImage = UIImage(data: data) else { return nil }
    return uiImage.cgImage
    #elseif os(macOS)
    guard let nsImage = NSImage(data: data) else { return nil }
    
    // Convert NSImage to CGImage
    guard let imageData = nsImage.tiffRepresentation,
          let imageRep = NSBitmapImageRep(data: imageData) else {
      return nil
    }
    
    return imageRep.cgImage
    #endif
  }
  
  // MARK: - Video Generation
  
  /// Generates a video from an audio recording with waveform visualization
  func generateVisualizerVideo(
    audioURL: URL,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval,
    avatarURL: String? = nil
  ) async throws -> URL {
    
    // Safety check: limit duration to prevent excessive processing
    let maxDuration: TimeInterval = 300 // 5 minutes maximum
    let clampedDuration = min(duration, maxDuration)
    
    if duration > maxDuration {
      logger.debug("Duration clamped from \(duration)s to \(clampedDuration)s for performance")
    }
    
    // Store avatar URL for profile image loading
    currentAvatarURL = avatarURL
    
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
    
    return try await withTaskCancellationHandler(operation: {
      try await withRetry(
        operation: {
          try await self.performVideoGeneration(
            audioURL: audioURL,
            profileImage: profileImage,
            username: username,
            accentColor: accentColor,
            duration: clampedDuration
          )
        },
        context: "Video Generation"
      )
    }, onCancel: {
      timeoutTask.cancel()
    })
  }
  
  private func performVideoGeneration(
    audioURL: URL,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    duration: TimeInterval
  ) async throws -> URL {
    
    let startTime = Date()
    
    // Step 1: Analyze audio waveform (15% progress)
    logger.debug("Starting audio analysis for duration: \(duration)s")
    let analysisStart = Date()
    let waveformData: WaveformData
    do {
      waveformData = try await waveformAnalyzer.analyzeAudioFile(at: audioURL)
    } catch {
      throw VisualizerError.audioAnalysisFailed(underlying: error)
    }
    let analysisTime = Date().timeIntervalSince(analysisStart)
    logger.debug("Audio analysis completed in \(analysisTime)s, found \(waveformData.waveformPoints.count) waveform points")
    progress = 0.15
    
    // Configure adaptive quality based on duration
    let adaptiveVideoSize = getVideoSize(for: duration)
    let adaptiveFPS = getFPS(for: duration) 
    let adaptiveBitRate = getBitRate(for: adaptiveVideoSize, fps: adaptiveFPS)
    logger.debug("Adaptive quality: \(adaptiveVideoSize.width)x\(adaptiveVideoSize.height) @ \(adaptiveFPS)fps, bitrate: \(adaptiveBitRate)")
    
    // Step 1.5: Load profile image (20% progress)
    logger.debug("Loading profile image")
    let profileImageStart = Date()
    await loadProfileImage(from: profileImage)
    let profileImageTime = Date().timeIntervalSince(profileImageStart)
    logger.debug("Profile image loaded in \(profileImageTime)s")
    progress = 0.2
    
    // Step 2: Set up video writer (30% progress)
    logger.debug("Setting up video writer")
    let setupStart = Date()
    let outputURL = generateOutputURL()
    let assetWriter = try setupAssetWriter(outputURL: outputURL)
    let videoInput = try setupVideoInput(size: adaptiveVideoSize, fps: adaptiveFPS, bitRate: adaptiveBitRate)
    let audioInput = try setupAudioInput()
    
    assetWriter.add(videoInput)
    assetWriter.add(audioInput)
    let setupTime = Date().timeIntervalSince(setupStart)
    logger.debug("Video writer setup completed in \(setupTime)s")
    progress = 0.3
    
    // Step 3: Create pixel buffer adaptor
    logger.debug("Creating pixel buffer adaptor")
    let adaptorStart = Date()
    let pixelBufferAdaptor = setupPixelBufferAdaptor(videoInput: videoInput, size: adaptiveVideoSize)
    let adaptorTime = Date().timeIntervalSince(adaptorStart)
    logger.debug("Pixel buffer adaptor created in \(adaptorTime)s")
    
    // Step 4: Start writing
    logger.debug("Starting asset writer session")
    let sessionStart = Date()
    guard assetWriter.startWriting() else {
      logger.error("Failed to start asset writer")
      throw VisualizerError.writerSetupFailed(underlying: assetWriter.error)
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
      duration: duration,
      videoSize: adaptiveVideoSize,
      fps: adaptiveFPS
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
      throw VisualizerError.writingFailed(underlying: assetWriter.error)
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
  
  private func setupVideoInput(size: CGSize, fps: Int32, bitRate: Int) throws -> AVAssetWriterInput {
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel, // Main profile for better quality
        AVVideoMaxKeyFrameIntervalKey: fps * 2, // Keyframe every 2 seconds
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC, // Better compression
        AVVideoAllowFrameReorderingKey: true // Allow B-frames for better compression
      ]
    ]
    
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true // Important for proper flow control
    
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
  
  private func setupPixelBufferAdaptor(videoInput: AVAssetWriterInput, size: CGSize) -> AVAssetWriterInputPixelBufferAdaptor {
    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      // Backed by IOSurface to reduce copies and improve pool reuse
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
    duration: TimeInterval,
    videoSize: CGSize,
    fps: Int32
  ) async throws {
    
    let totalFrames = Int(duration * Double(fps))
    let frameProgressIncrement = 0.4 / Double(totalFrames) // 40% of total progress
    
      logger.debug("Starting frame generation: \(totalFrames) frames at \(fps) FPS")
    
    // Pre-calculate values to avoid repeated calculations
    let waveformPoints = waveformData.waveformPoints
    let frameTimeInterval = 1.0 / Double(fps)
    
    logger.debug("Starting on-demand frame generation...")
    if let memStart = currentMemoryUsageMB() {
      logger.debug("Memory at start of frame gen: \(memStart)MB")
    }
    
    // Use proper AVAssetWriter pattern with requestMediaDataWhenReady
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      frameGenerationContinuation = continuation
      
      var currentFrameIndex = 0
      var isCompleted = false // Flag to prevent multiple completion calls
      
      videoQueue.async { [weak self] in
        guard let self = self else {
          if !isCompleted {
            isCompleted = true
            continuation.resume(throwing: VisualizerError.generationTimeout)
          }
          return
        }
        
        pixelBufferAdaptor.assetWriterInput.requestMediaDataWhenReady(on: self.videoQueue) {
          // Check if already completed to prevent duplicate execution
          guard !isCompleted else { return }

          while pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData && currentFrameIndex < totalFrames && !isCompleted {
            // Drain autoreleased UIKit/CoreGraphics objects every frame
            autoreleasepool {
              let currentTime = Double(currentFrameIndex) * frameTimeInterval
              let presentationTime = CMTime(value: Int64(currentFrameIndex), timescale: fps)

              // Generate frame on-demand to minimize memory usage
              do {
                let frameImage = try self.renderMemoryEfficientFrameSync(
                  currentTime: currentTime,
                  duration: duration,
                  waveformPoints: waveformPoints,
                  username: username,
                  accentColor: accentColor,
                  videoSize: videoSize
                )

                // Convert to pixel buffer using pool
                guard let pixelBuffer = self.createPooledPixelBuffer(from: frameImage, adaptor: pixelBufferAdaptor) else {
                  self.logger.debug("Failed to create pixel buffer for frame \(currentFrameIndex)")
                  currentFrameIndex += 1
                  return
                }

                // Append the frame
                let success = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                if !success {
                  self.logger.debug("Failed to append frame \(currentFrameIndex)")
                }

                currentFrameIndex += 1

                // Update progress on main
                DispatchQueue.main.async {
                  self.progress += frameProgressIncrement
                }

                if currentFrameIndex % 30 == 0 {
                  self.logger.debug("Encoded frame \(currentFrameIndex)/\(totalFrames)")
                }
              } catch {
                self.logger.error("Failed to generate frame \(currentFrameIndex): \(error)")
                if !isCompleted {
                  isCompleted = true
                  continuation.resume(throwing: error)
                }
                return
              }
            }

            // Check if we're done and haven't already completed
            if currentFrameIndex >= totalFrames && !isCompleted {
              isCompleted = true
              self.logger.debug("All frames encoded successfully")
              continuation.resume()
            }
          }
        }
      }
    }
    
    logger.debug("Completed frame generation")
  }
  
  // MARK: - Frame Rendering
  
  // Memory-efficient frame rendering optimized for on-demand generation
  private func renderMemoryEfficientFrame(
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderMemoryEfficientFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
        username: username,
        accentColor: accentColor,
        videoSize: videoSize
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
    
    renderMemoryEfficientFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor,
      videoSize: videoSize
    )
    
    return context.makeImage()!
    #endif
  }
  
  private func renderMemoryEfficientFrameContent(
    context: CGContext,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) {
    // Blue accent background as requested
    #if os(iOS)
    context.setFillColor(UIColor.systemBlue.cgColor)
    #else
    context.setFillColor(NSColor.systemBlue.cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Enhanced waveform visualization (colorful and prominent)
    drawSimpleWaveform(
      context: context,
      waveformPoints: waveformPoints,
      currentTime: currentTime,
      duration: duration,
      videoSize: videoSize
    )
    
    // Profile picture with cached image or simple placeholder
    drawProfileImage(context: context, cachedImage: profileImageCache, videoSize: videoSize)
    
    // Timer and username with bright text for visibility
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawSimpleText(context: context, text: timerText, position: .topLeft, size: 32, videoSize: videoSize)
    drawSimpleText(context: context, text: "@\(username)", position: .topRight, size: 32, videoSize: videoSize)
  }
  
  // Synchronous memory-efficient frame rendering for on-demand generation
  private func renderMemoryEfficientFrameSync(
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderMemoryEfficientFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
        username: username,
        accentColor: accentColor,
        videoSize: videoSize
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
    
    renderMemoryEfficientFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor,
      videoSize: videoSize
    )
    
    return context.makeImage()!
    #endif
  }

  // High-quality frame rendering with beautiful waveform visualization
  private func renderHighQualityFrame(
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderHighQualityFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
        username: username,
        accentColor: accentColor,
        videoSize: videoSize
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
    
    renderHighQualityFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor,
      videoSize: videoSize
    )
    
    return context.makeImage()!
    #endif
  }
  
  private func renderHighQualityFrameContent(
    context: CGContext,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) {
    // Blue accent background as requested
    #if os(iOS)
    context.setFillColor(UIColor.systemBlue.cgColor)
    #else
    context.setFillColor(NSColor.systemBlue.cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Beautiful waveform visualization (now stands out against dark background)
    drawAdvancedWaveform(
      context: context,
      waveformPoints: waveformPoints,
      currentTime: currentTime,
      duration: duration,
      videoSize: videoSize
    )
    
    // Profile picture with enhanced styling
    drawProfileImage(context: context, cachedImage: profileImageCache, videoSize: videoSize)
    
    // Timer and username with bright text for visibility
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawStyledText(context: context, text: timerText, position: .topLeft, size: 42, videoSize: videoSize)
    drawStyledText(context: context, text: "@\(username)", position: .topRight, size: 42, videoSize: videoSize)
  }
  
  private func drawAdvancedWaveform(
    context: CGContext,
    waveformPoints: [WaveformPoint],
    currentTime: TimeInterval,
    duration: TimeInterval,
    videoSize: CGSize
  ) {
    guard !waveformPoints.isEmpty else { 
      // Draw placeholder animated bars if no waveform data
      drawAnimatedPlaceholderWaveform(context: context, currentTime: currentTime, videoSize: videoSize)
      return 
    }
    
    let waveformRect = CGRect(
      x: 60,
      y: videoSize.height * 0.25,
      width: videoSize.width - 120,
      height: videoSize.height * 0.5
    )
    
    let centerY = waveformRect.midY
    let maxHeight = waveformRect.height * 0.45
    
    // Many more bars for smooth, colorful visualization
    let barCount = 120
    let barWidth = waveformRect.width / CGFloat(barCount)
    let progress = currentTime / duration
    
    for i in 0..<barCount {
      let x = waveformRect.minX + CGFloat(i) * barWidth
      let barProgress = Double(i) / Double(barCount)
      
      // Map to waveform point
      let pointIndex = Int(barProgress * Double(waveformPoints.count - 1))
      let safeIndex = min(pointIndex, waveformPoints.count - 1)
      let amplitude = CGFloat(waveformPoints[safeIndex].amplitude)
      let peak = CGFloat(waveformPoints[safeIndex].peak)
      
      // Enhanced height calculation with minimum visibility
      let normalizedAmplitude = max(amplitude, 0.15) // Ensure minimum visibility
      let height = normalizedAmplitude * maxHeight + 30 // Minimum height of 30
      
      // Simple white waveform as requested
      let alpha: CGFloat = barProgress <= progress ? 1.0 : 0.5 // Played vs unplayed
      
      #if os(iOS)
      context.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
      #else
      context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
      #endif
      
      // Draw simple white bar
      let barRect = CGRect(
        x: x + 1, 
        y: centerY - height/2, 
        width: max(2, barWidth - 2), 
        height: height
      )
      
      let roundedPath = CGPath(
        roundedRect: barRect,
        cornerWidth: 3,
        cornerHeight: 3,
        transform: nil
      )
      
      context.addPath(roundedPath)
      context.fillPath()
    }
  }
  
  private func drawAnimatedPlaceholderWaveform(context: CGContext, currentTime: TimeInterval, videoSize: CGSize) {
    let waveformRect = CGRect(
      x: 60,
      y: videoSize.height * 0.35,
      width: videoSize.width - 120,
      height: videoSize.height * 0.3
    )
    
    let centerY = waveformRect.midY
    let maxHeight = waveformRect.height * 0.4
    
    let barCount = 60
    let barWidth = waveformRect.width / CGFloat(barCount)
    
    for i in 0..<barCount {
      let x = waveformRect.minX + CGFloat(i) * barWidth
      
      // Animated height based on time and position
      let phase = currentTime * 3 + Double(i) * 0.15
      let amplitude = sin(phase) * 0.4 + 0.6
      let height = CGFloat(amplitude) * maxHeight + 20
      
      // Simple white animated bars
      let alpha = 0.7 + sin(phase * 0.5) * 0.3 // Animated opacity
      
      #if os(iOS)
      context.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
      #else
      context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
      #endif
      
      let barRect = CGRect(
        x: x + 1,
        y: centerY - height/2,
        width: max(2, barWidth - 2),
        height: height
      )
      
      let roundedPath = CGPath(
        roundedRect: barRect,
        cornerWidth: 2,
        cornerHeight: 2,
        transform: nil
      )
      
      context.addPath(roundedPath)
      context.fillPath()
    }
  }
  
  private func drawProfileImage(context: CGContext, cachedImage: CGImage?, videoSize: CGSize) {
    let size: CGFloat = 160
    let rect = CGRect(
      x: (videoSize.width - size) / 2,
      y: (videoSize.height - size) / 2, // Center vertically
      width: size,
      height: size
    )
    
    // Save context state
    context.saveGState()
    
    // Add shadow for depth
    #if os(iOS)
    context.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: UIColor.black.withAlphaComponent(0.3).cgColor)
    #else
    context.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    #endif
    
    // Create circular clipping path
    context.addEllipse(in: rect)
    context.clip()
    
    if let profileImage = cachedImage {
      // Flip the context to fix upside-down image
      context.translateBy(x: 0, y: rect.maxY)
      context.scaleBy(x: 1, y: -1)
      
      // Draw the actual profile image
      let flippedRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height)
      context.draw(profileImage, in: flippedRect)
      
      // Restore the flip transformation
      context.scaleBy(x: 1, y: -1)
      context.translateBy(x: 0, y: -rect.maxY)
    } else {
      // Draw placeholder background
      #if os(iOS)
      context.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
      #else
      context.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
      #endif
      context.fillEllipse(in: rect)
      
      // Draw placeholder icon (person silhouette)
      let iconSize: CGFloat = size * 0.5
      let iconRect = CGRect(
        x: rect.midX - iconSize/2,
        y: rect.midY - iconSize/2 + 10,
        width: iconSize,
        height: iconSize
      )
      
      #if os(iOS)
      context.setFillColor(UIColor.white.withAlphaComponent(0.6).cgColor)
      #else
      context.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
      #endif
      
      // Simple person silhouette shape
      let headSize = iconSize * 0.3
      let headRect = CGRect(x: iconRect.midX - headSize/2, y: iconRect.minY, width: headSize, height: headSize)
      context.fillEllipse(in: headRect)
      
      let bodyRect = CGRect(x: iconRect.midX - iconSize*0.4/2, y: iconRect.minY + headSize + 5, width: iconSize*0.4, height: iconSize*0.5)
      context.fill(bodyRect.insetBy(dx: 0, dy: -bodyRect.height*0.2))
    }
    
    // Restore context and add white border
    context.restoreGState()
    
    #if os(iOS)
    context.setStrokeColor(UIColor.white.cgColor)
    #else
    context.setStrokeColor(NSColor.white.cgColor)
    #endif
    context.setLineWidth(4)
    context.strokeEllipse(in: rect)
  }
  
  private func drawStyledText(context: CGContext, text: String, position: TextPosition, size: CGFloat, videoSize: CGSize) {
    #if os(iOS)
      let font = UIFont.systemFont(ofSize: size, weight: UIFont.Weight.bold)
    let textColor = UIColor.white
    #else
      let font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight.bold)
    let textColor = NSColor.white
    #endif
    
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor
    ]
    
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    var textRect: CGRect
    let margin: CGFloat = 80
    
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
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.5).cgColor)
    #else
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    #endif
    attributedString.draw(in: textRect)
    context.restoreGState()
  }
  
  // Ultra-simplified frame rendering for maximum speed
  private func renderUltraSimplifiedFrame(
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformPoints: [WaveformPoint],
    username: String,
    accentColor: Color,
    videoSize: CGSize
  ) async throws -> CGImage {
    
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: videoSize)
    let image = renderer.image { context in
      renderUltraSimplifiedFrameContent(
        context: context.cgContext,
        currentTime: currentTime,
        duration: duration,
        waveformPoints: waveformPoints,
        username: username,
        accentColor: accentColor,
        videoSize: videoSize
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
    
    renderUltraSimplifiedFrameContent(
      context: context,
      currentTime: currentTime,
      duration: duration,
      waveformPoints: waveformPoints,
      username: username,
      accentColor: accentColor,
      videoSize: videoSize
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
    accentColor: Color,
    videoSize: CGSize
  ) {
    // Background - solid color
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Ultra-simple waveform - just 5 bars
    let progress = currentTime / duration
    let barCount = 5
    let barWidth = videoSize.width / CGFloat(barCount + 1)
    let centerY = videoSize.height / 2
    
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
      x: (videoSize.width - circleSize) / 2,
      y: (videoSize.height - circleSize) / 2,
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
    drawUltraSimpleText(context: context, text: timerText, atTop: true, videoSize: videoSize)
    drawUltraSimpleText(context: context, text: "@\(username)", atTop: false, videoSize: videoSize)
  }
  
  private func drawUltraSimpleText(context: CGContext, text: String, atTop: Bool, videoSize: CGSize) {
      #if os(iOS)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 18, weight: UIFont.Weight.medium),
      .foregroundColor: UIColor.white
    ]
      #elseif os(macOS)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 18, weight: NSFont.Weight.medium),
            .foregroundColor: NSColor.white
                                 ]
      #endif
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    let y: CGFloat = atTop ? 10 : videoSize.height - textSize.height - 10
    let x: CGFloat = (videoSize.width - textSize.width) / 2
    
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
    accentColor: Color,
    videoSize: CGSize
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
        accentColor: accentColor,
        videoSize: videoSize
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
      accentColor: accentColor,
      videoSize: videoSize
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
    accentColor: Color,
    videoSize: CGSize
  ) {
    // Background
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Simple waveform (just bars, no complex scrolling)
    drawSimpleWaveform(
      context: context,
      waveformPoints: waveformPoints,
      currentTime: currentTime,
      duration: duration,
      videoSize: videoSize
    )
    
    // Simple profile circle (just a placeholder circle)
    drawSimpleProfileCircle(context: context, videoSize: videoSize)
    
    // Timer and username
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawSimpleText(context: context, text: timerText, position: .topLeft, size: 24, videoSize: videoSize)
    drawSimpleText(context: context, text: "@\(username)", position: .topRight, size: 24, videoSize: videoSize)
  }
  
  private func drawSimpleWaveform(
    context: CGContext,
    waveformPoints: [WaveformPoint],
    currentTime: TimeInterval,
    duration: TimeInterval,
    videoSize: CGSize
  ) {
    guard !waveformPoints.isEmpty else { 
      // Draw animated placeholder if no waveform data
      drawAnimatedPlaceholderWaveform(context: context, currentTime: currentTime, videoSize: videoSize)
      return 
    }
    
    let waveformRect = CGRect(
      x: 50,
      y: videoSize.height * 0.35,
      width: videoSize.width - 100,
      height: videoSize.height * 0.3
    )
    
    let centerY = waveformRect.midY
    let maxHeight = waveformRect.height * 0.45
    
    // More bars for better visualization
    let barCount = 80
    let barWidth = waveformRect.width / CGFloat(barCount)
    let progress = currentTime / duration
    
    for i in 0..<barCount {
      let x = waveformRect.minX + CGFloat(i) * barWidth
      let barProgress = Double(i) / Double(barCount)
      let pointIndex = Int(barProgress * Double(waveformPoints.count - 1))
      let safeIndex = min(pointIndex, waveformPoints.count - 1)
      let amplitude = CGFloat(waveformPoints[safeIndex].amplitude)
      
      // Enhanced height with minimum visibility
      let normalizedAmplitude = max(amplitude, 0.2) // Ensure bars are visible
      let height = normalizedAmplitude * maxHeight + 25 // Minimum height
      
      // Simple white waveform as requested
      let alpha: CGFloat = barProgress <= progress ? 1.0 : 0.5 // Played vs unplayed
      
      #if os(iOS)
      context.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
      #else
      context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
      #endif
      
      // Draw simple white bar
      let barRect = CGRect(
        x: x + 1, 
        y: centerY - height/2, 
        width: max(3, barWidth - 2), 
        height: height
      )
      
      let roundedPath = CGPath(
        roundedRect: barRect,
        cornerWidth: 2,
        cornerHeight: 2,
        transform: nil
      )
      
      context.addPath(roundedPath)
      context.fillPath()
    }
  }
  
  private func drawSimpleProfileCircle(context: CGContext, videoSize: CGSize) {
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
  
  private func drawSimpleText(context: CGContext, text: String, position: TextPosition, size: CGFloat, videoSize: CGSize) {
    #if os(iOS)
      let font = UIFont.systemFont(ofSize: size, weight: UIFont.Weight.bold)
    let textColor = UIColor.white
    #else
      let font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight.bold)
    let textColor = NSColor.white
    #endif
    
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .strokeColor: textColor.withAlphaComponent(0.8),
      .strokeWidth: -2.0 // Negative value for fill + stroke
    ]
    
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedString.size()
    
    var rect: CGRect
    let margin: CGFloat = 30
    
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
    
    // Draw text with shadow for better visibility
    context.saveGState()
    #if os(iOS)
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.6).cgColor)
    #else
    context.setShadow(offset: CGSize(width: 2, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    #endif
    attributedString.draw(in: rect)
    context.restoreGState()
  }
  
  private func renderFrame(
    frameNumber: Int,
    totalFrames: Int,
    currentTime: TimeInterval,
    duration: TimeInterval,
    waveformData: WaveformData,
    profileImage: Image?,
    username: String,
    accentColor: Color,
    videoSize: CGSize
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
        accentColor: accentColor,
        videoSize: videoSize
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
      accentColor: accentColor,
      videoSize: videoSize
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
    accentColor: Color,
    videoSize: CGSize
  ) {
    // Background
    #if os(iOS)
    context.setFillColor(UIColor(accentColor).cgColor)
    #else
    context.setFillColor(NSColor(accentColor).cgColor)
    #endif
    context.fill(CGRect(origin: .zero, size: videoSize))
    
    // Waveform
    drawWaveform(
      context: context,
      waveformData: waveformData,
      currentTime: currentTime,
      duration: duration,
      videoSize: videoSize
    )
    
    // Profile picture (circular)
    if let profileImage = profileImage {
      drawProfileImage(context: context, image: profileImage, videoSize: videoSize)
    }
    
    // Timer (remaining time)
    let timeRemaining = duration - currentTime
    let timerText = formatTime(timeRemaining)
    drawText(context: context, text: timerText, position: .topLeft, size: 40, videoSize: videoSize)
    
    // Username
    drawText(context: context, text: "@\(username)", position: .topRight, size: 40, videoSize: videoSize)
  }
  
  private func drawWaveform(
    context: CGContext,
    waveformData: WaveformData,
    currentTime: TimeInterval,
    duration: TimeInterval,
    videoSize: CGSize
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
  
  private func drawProfileImage(context: CGContext, image: Image, videoSize: CGSize) {
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
  
  private func drawText(context: CGContext, text: String, position: TextPosition, size: CGFloat, videoSize: CGSize) {
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
        // Wait asynchronously until writer is ready, then append within an autoreleasepool (synchronous)
        while !audioInput.isReadyForMoreMediaData {
          // Back off very briefly to avoid busy-waiting and memory growth
          try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        autoreleasepool {
          _ = audioInput.append(sampleBuffer)
        }
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
  
  private func createPooledPixelBuffer(from cgImage: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
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
  case writerSetupFailed(underlying: Error?)
  case writingFailed(underlying: Error?)
  case frameCreationFailed(underlying: Error?)
  case frameAppendFailed(underlying: Error?)
  case noAudioTrack
  case generationTimeout
  case audioAnalysisFailed(underlying: Error?)
  case profileImageLoadFailed(underlying: Error?)
  case diskSpaceInsufficient
  case memoryPressure
  case maxRetriesExceeded(attempts: Int)
  
  var errorDescription: String? {
    switch self {
    case .writerSetupFailed(let error):
      return "Failed to setup video writer" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .writingFailed(let error):
      return "Failed to write video" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .frameCreationFailed(let error):
      return "Failed to create video frame" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .frameAppendFailed(let error):
      return "Failed to append video frame" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .noAudioTrack:
      return "No audio track found in recording"
    case .generationTimeout:
      return "Video generation timed out"
    case .audioAnalysisFailed(let error):
      return "Failed to analyze audio waveform" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .profileImageLoadFailed(let error):
      return "Failed to load profile image" + (error != nil ? ": \(error!.localizedDescription)" : "")
    case .diskSpaceInsufficient:
      return "Insufficient disk space for video generation"
    case .memoryPressure:
      return "System memory pressure - please close other apps and try again"
    case .maxRetriesExceeded(let attempts):
      return "Video generation failed after \(attempts) attempts"
    }
  }
  
  /// Whether this error type should be retried
  var isRetryable: Bool {
    switch self {
    case .writerSetupFailed, .writingFailed, .frameCreationFailed, .frameAppendFailed:
      return true
    case .audioAnalysisFailed, .profileImageLoadFailed:
      return true
    case .memoryPressure:
      return true // Can retry after memory pressure subsides
    case .noAudioTrack, .generationTimeout, .diskSpaceInsufficient, .maxRetriesExceeded:
      return false
    }
  }
}
