//
//  OptimizedAudioWaveformProcessor.swift
//  Catbird
//
//  High-performance audio waveform processing using Accelerate framework
//  with memory-efficient streaming and GPU-accelerated rendering
//

import AVFoundation
import Accelerate
import Foundation
import Metal
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
final class OptimizedAudioWaveformProcessor {
  private let logger = Logger(subsystem: "blue.catbird", category: "OptimizedWaveformProcessor")
  
  // MARK: - Configuration
  
  private struct ProcessingConfig {
    static let targetSampleRate: Float = 44100.0
    static let defaultWaveformPoints: Int = 200
    static let maxWaveformPoints: Int = 500
    static let chunkSize: Int = 4096
    static let windowSize: Int = 1024
    static let overlapFactor: Float = 0.5
  }
  
  // MARK: - Memory-Efficient Data Structures
  
  /// Compact waveform representation optimized for rendering
  final class CompactWaveformData {
    let amplitudes: UnsafeMutableBufferPointer<Float>
    let peaks: UnsafeMutableBufferPointer<Float>
    let timestamps: UnsafeMutableBufferPointer<Float>
    let pointCount: Int
    let duration: Float
    let sampleRate: Float
    
    init(pointCount: Int, duration: Float, sampleRate: Float) {
      self.pointCount = pointCount
      self.duration = duration
      self.sampleRate = sampleRate
      
      self.amplitudes = UnsafeMutableBufferPointer<Float>.allocate(capacity: pointCount)
      self.peaks = UnsafeMutableBufferPointer<Float>.allocate(capacity: pointCount)
      self.timestamps = UnsafeMutableBufferPointer<Float>.allocate(capacity: pointCount)
      
      // Initialize with zeros
      self.amplitudes.initialize(repeating: 0.0)
      self.peaks.initialize(repeating: 0.0)
      self.timestamps.initialize(repeating: 0.0)
    }
    
    deinit {
      amplitudes.deallocate()
      peaks.deallocate()
      timestamps.deallocate()
    }
  }
  
  // MARK: - Accelerate-Optimized Processing
  
  /// Process audio file with streaming and Accelerate optimization
  func processAudioFile(
    at url: URL,
    targetPoints: Int = ProcessingConfig.defaultWaveformPoints
  ) async throws -> CompactWaveformData {
    let clampedPoints = max(1, min(targetPoints, ProcessingConfig.maxWaveformPoints))
    
    let asset = AVAsset(url: url)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw WaveformError.noAudioTrack
    }
    
    let duration = try await asset.load(.duration)
    let rawDurationSeconds = Float(CMTimeGetSeconds(duration))
    let durationSeconds = rawDurationSeconds.isFinite ? max(0, rawDurationSeconds) : 0
    
    // Set up optimized audio reader
    let assetReader = try AVAssetReader(asset: asset)
    let outputSettings = createOptimizedOutputSettings()
    let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    assetReader.add(readerOutput)
    
    guard assetReader.startReading() else {
      throw WaveformError.readerError
    }
    
    // Initialize result data structure
    let waveformData = CompactWaveformData(
      pointCount: clampedPoints,
      duration: durationSeconds,
      sampleRate: ProcessingConfig.targetSampleRate
    )
    
    // Streaming processing with Accelerate optimization
    try await processAudioStream(
      reader: assetReader,
      readerOutput: readerOutput,
      waveformData: waveformData,
      totalDuration: durationSeconds
    )
    
    return waveformData
  }
  
  private func createOptimizedOutputSettings() -> [String: Any] {
    return [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: ProcessingConfig.targetSampleRate,
      AVNumberOfChannelsKey: 1 // Mono for efficiency
    ]
  }
  
  private func processAudioStream(
    reader: AVAssetReader,
    readerOutput: AVAssetReaderTrackOutput,
    waveformData: CompactWaveformData,
    totalDuration: Float
  ) async throws {
    let samplesPerPoint = Int(ProcessingConfig.targetSampleRate * totalDuration / Float(waveformData.pointCount))
    var accumulatedSamples: [Float] = []
    accumulatedSamples.reserveCapacity(samplesPerPoint * 2)
    
    var currentPointIndex = 0
    var totalSamplesProcessed = 0
    
    // Accelerate setup for RMS calculation
    var sumOfSquares: Float = 0.0
    var maxValue: Float = 0.0
    
    while reader.status == .reading && currentPointIndex < waveformData.pointCount {
      autoreleasepool {
        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { return }
        
        do {
          let samples = try extractOptimizedAudioSamples(from: sampleBuffer)
          
          for sample in samples {
            accumulatedSamples.append(sample)
            totalSamplesProcessed += 1
            
            // Process accumulated samples when we have enough for a point
            if accumulatedSamples.count >= samplesPerPoint || totalSamplesProcessed >= Int(ProcessingConfig.targetSampleRate * totalDuration) {
              
              // Use Accelerate for efficient RMS and peak calculation
              let (rms, peak) = calculateOptimizedRMSAndPeak(samples: accumulatedSamples)
              let timestamp = Float(currentPointIndex) / Float(waveformData.pointCount) * totalDuration
              
              // Store directly in buffer
              waveformData.amplitudes[currentPointIndex] = rms
              waveformData.peaks[currentPointIndex] = peak
              waveformData.timestamps[currentPointIndex] = timestamp
              
              accumulatedSamples.removeAll(keepingCapacity: true)
              currentPointIndex += 1
              
              if currentPointIndex >= waveformData.pointCount {
                break
              }
            }
          }
        } catch {
          logger.warning("Skipping problematic sample buffer: \(error.localizedDescription)")
        }
      }
    }
    
    // Process any remaining samples
    if !accumulatedSamples.isEmpty && currentPointIndex < waveformData.pointCount {
      let (rms, peak) = calculateOptimizedRMSAndPeak(samples: accumulatedSamples)
      let timestamp = Float(currentPointIndex) / Float(waveformData.pointCount) * totalDuration
      
      waveformData.amplitudes[currentPointIndex] = rms
      waveformData.peaks[currentPointIndex] = peak
      waveformData.timestamps[currentPointIndex] = timestamp
    }
    
    guard reader.status == .completed else {
      throw WaveformError.analysisError
    }
  }
  
  /// Optimized RMS and Peak calculation using Accelerate
  private func calculateOptimizedRMSAndPeak(samples: [Float]) -> (rms: Float, peak: Float) {
    guard !samples.isEmpty else { return (0.0, 0.0) }
    
    let count = vDSP_Length(samples.count)
    
    // Calculate RMS using Accelerate
    var rms: Float = 0.0
    vDSP_rmsqv(samples, 1, &rms, count)
    
    // Calculate peak using Accelerate
    var peak: Float = 0.0
    vDSP_maxmgv(samples, 1, &peak, count)
    
    return (rms: rms, peak: peak)
  }
  
  /// Efficient audio sample extraction with proper float conversion
  private func extractOptimizedAudioSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw WaveformError.bufferError
    }
    
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: length)
    
    try data.withUnsafeMutableBytes { bytes in
      let result = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
      guard result == noErr else {
        throw WaveformError.bufferError
      }
    }
    
    // Direct Float32 conversion (more efficient than Int16 conversion)
    return data.withUnsafeBytes { bytes in
      let floatPointer = bytes.bindMemory(to: Float.self)
      return Array(floatPointer)
    }
  }
  
  // MARK: - Real-time Processing for Live Audio
  
  /// Process live audio buffer for real-time visualization
  func processLiveAudioBuffer(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float, frequencies: [Float]) {
    guard let channelData = buffer.floatChannelData?[0] else {
      return (0.0, 0.0, [])
    }
    
    let frameCount = Int(buffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
    
    // Calculate RMS and peak
    let (rms, peak) = calculateOptimizedRMSAndPeak(samples: samples)
    
    // Generate frequency analysis for live visualization
    let frequencies = generateFrequencyBins(from: samples, binCount: 32)
    
    return (rms: rms, peak: peak, frequencies: frequencies)
  }
  
  /// Fast FFT-based frequency analysis using Accelerate
  private func generateFrequencyBins(from samples: [Float], binCount: Int) -> [Float] {
    let fftSize = 1024
    guard samples.count >= fftSize else {
      return Array(repeating: 0.0, count: binCount)
    }
    
    let log2N = vDSP_Length(log2(Double(fftSize)))
    guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
      return Array(repeating: 0.0, count: binCount)
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }
    
    // Prepare input data
    var realInput = [Float](samples.prefix(fftSize))
    var imaginaryInput = [Float](repeating: 0.0, count: fftSize)
    var complexBuffer = DSPSplitComplex(realp: &realInput, imagp: &imaginaryInput)
    
    // Apply windowing function for better frequency resolution
    var window = [Float](repeating: 0.0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    vDSP_vmul(realInput, 1, window, 1, &realInput, 1, vDSP_Length(fftSize))
    
    // Perform FFT
    vDSP_fft_zip(fftSetup, &complexBuffer, 1, log2N, FFTDirection(FFT_FORWARD))
    
    // Calculate magnitudes
    var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
    vDSP_zvmags(&complexBuffer, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
    
    // Convert to frequency bins
    let samplesPerBin = magnitudes.count / binCount
    var frequencyBins = [Float](repeating: 0.0, count: binCount)
    
    for i in 0..<binCount {
      let startIndex = i * samplesPerBin
      let endIndex = min(startIndex + samplesPerBin, magnitudes.count)
      
      if startIndex < endIndex {
        let binSlice = Array(magnitudes[startIndex..<endIndex])
        var sum: Float = 0.0
        vDSP_sve(binSlice, 1, &sum, vDSP_Length(binSlice.count))
        frequencyBins[i] = sum / Float(binSlice.count)
      }
    }
    
    // Normalize and apply logarithmic scaling
    if let maxValue = frequencyBins.max(), maxValue > 0 {
      var normalizedBins = frequencyBins.map { $0 / maxValue }
      // Apply log scaling for better visual distribution using manual log calculation
      normalizedBins = normalizedBins.map { value in
        guard value > 0 else { return 0.0 }
        return log10(value * 9.0 + 1.0) // Scale to 0-1 range with log distribution
      }
      return normalizedBins
    }
    
    return frequencyBins
  }
  
  // MARK: - Memory Management
  
  /// Clean up and release resources
  func cleanup() {
    // Any additional cleanup if needed
    logger.debug("Cleaned up waveform processor resources")
  }
}

// MARK: - Error Handling

extension WaveformError {
  static let processingTimeout = WaveformError.custom("Audio processing timed out")
  static let memoryError = WaveformError.custom("Insufficient memory for processing")
  }
