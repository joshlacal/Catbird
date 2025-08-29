//
//  AudioWaveformAnalyzer.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import AVFoundation
import Accelerate
import Foundation
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class AudioWaveformAnalyzer {
  private let logger = Logger(subsystem: "blue.catbird", category: "AudioWaveformAnalyzer")
  
  // MARK: - FFT Configuration
  
  private let fftSize: Int = 1024
  private let windowSize: Int = 512
  private let hopSize: Int = 256
  
  // MARK: - Waveform Analysis
  
  /// Analyzes an audio file and returns waveform data with streaming processing
  func analyzeAudioFile(at url: URL) async throws -> WaveformData {
    let asset = AVAsset(url: url)
    
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw WaveformError.noAudioTrack
    }
    
    let duration = try await asset.load(.duration)
    let durationSeconds = CMTimeGetSeconds(duration)
    
    // Set up audio reader
    let assetReader = try AVAssetReader(asset: asset)
    
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: 44100
    ]
    
    let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    assetReader.add(readerOutput)
    
    guard assetReader.startReading() else {
      throw WaveformError.readerError
    }
    
    // Process audio in streaming chunks to reduce memory usage
    let targetPoints = 100
    let samplesPerPoint = Int(44100 * durationSeconds / Double(targetPoints)) // Approximate samples per point
    var waveformPoints: [WaveformPoint] = []
    var currentSegment: [Float] = []
    var totalSamplesProcessed = 0
    var currentPointIndex = 0
    
    while assetReader.status == .reading {
      autoreleasepool {
        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
          do {
            let samples = try extractAudioSamples(from: sampleBuffer)
            
            for sample in samples {
              currentSegment.append(sample)
              totalSamplesProcessed += 1
              
              // When we have enough samples for a waveform point, process it
              if currentSegment.count >= samplesPerPoint || totalSamplesProcessed >= Int(44100 * durationSeconds) {
                let rms = calculateRMS(currentSegment)
                let peak = currentSegment.map { abs($0) }.max() ?? 0.0
                let timestamp = Double(currentPointIndex) / Double(targetPoints) * durationSeconds
                
                waveformPoints.append(WaveformPoint(
                  timestamp: timestamp,
                  amplitude: rms,
                  peak: peak
                ))
                
                currentSegment.removeAll(keepingCapacity: true) // Clear but keep capacity
                currentPointIndex += 1
                
                if currentPointIndex >= targetPoints {
                  break
                }
              }
            }
          } catch {
            // Skip problematic sample buffers and continue with next buffer
          }
        }
      }
    }
    
    // Process any remaining samples
    if !currentSegment.isEmpty && currentPointIndex < targetPoints {
      let rms = calculateRMS(currentSegment)
      let peak = currentSegment.map { abs($0) }.max() ?? 0.0
      let timestamp = Double(currentPointIndex) / Double(targetPoints) * durationSeconds
      
      waveformPoints.append(WaveformPoint(
        timestamp: timestamp,
        amplitude: rms,
        peak: peak
      ))
    }
    
    guard assetReader.status == .completed else {
      throw WaveformError.analysisError
    }
    
    return WaveformData(
      samples: [], // No longer store all samples to save memory
      waveformPoints: waveformPoints,
      duration: durationSeconds,
      sampleRate: 44100
    )
  }
  
  /// Generates simplified waveform points from raw audio samples - faster processing
  private func generateSimplifiedWaveformPoints(from samples: [Float], duration: TimeInterval) -> [WaveformPoint] {
    guard !samples.isEmpty else { return [] }
    
    let targetPoints = 100 // More waveform points for beautiful visualization
    let samplesPerPoint = samples.count / targetPoints
    
    var waveformPoints: [WaveformPoint] = []
    
    for i in 0..<targetPoints {
      let startIndex = i * samplesPerPoint
      let endIndex = min(startIndex + samplesPerPoint, samples.count)
      
      guard startIndex < endIndex else { continue }
      
      let segment = Array(samples[startIndex..<endIndex])
      
      // Calculate RMS (Root Mean Square) for this segment
      let rms = calculateRMS(segment)
      
      // Calculate peak amplitude
      let peak = segment.map { abs($0) }.max() ?? 0.0
      
      let timestamp = (Double(i) / Double(targetPoints)) * duration
      
      waveformPoints.append(WaveformPoint(
        timestamp: timestamp,
        amplitude: rms,
        peak: peak
      ))
    }
    
    return waveformPoints
  }
  
  /// Calculates Root Mean Square for better waveform visualization
  private func calculateRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0.0 }
    
    let squaredSum = samples.reduce(0) { sum, sample in
      sum + (sample * sample)
    }
    
    return sqrt(squaredSum / Float(samples.count))
  }
  
  /// Extracts audio samples from a sample buffer
  private func extractAudioSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
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
    
    // Convert 16-bit PCM data to Float
    return data.withUnsafeBytes { bytes in
      let int16Pointer = bytes.bindMemory(to: Int16.self)
      return int16Pointer.map { Float($0) / Float(Int16.max) }
    }
  }
  
  /// Performs FFT analysis on audio samples for frequency domain visualization
  func performFFTAnalysis(on samples: [Float]) -> [Float] {
    guard samples.count >= fftSize else { return [] }
    
    let log2N = vDSP_Length(log2(Double(fftSize)))
    guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
      return []
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }
    
    var realInput = [Float](samples.prefix(fftSize))
    var imaginaryInput = [Float](repeating: 0, count: fftSize)
    
    var complexBuffer = DSPSplitComplex(realp: &realInput, imagp: &imaginaryInput)
    
    // Perform FFT
    vDSP_fft_zip(fftSetup, &complexBuffer, 1, log2N, FFTDirection(FFT_FORWARD))
    
    // Calculate magnitudes
    var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    vDSP_zvmags(&complexBuffer, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
    
    // Apply logarithmic scaling
    magnitudes = magnitudes.map { sqrt($0) }
    
    return magnitudes
  }
  
  /// Creates frequency-based visualization data
  func generateFrequencyVisualization(from samples: [Float], binCount: Int = 32) -> [Float] {
    let fftResult = performFFTAnalysis(on: samples)
    guard !fftResult.isEmpty else { return Array(repeating: 0, count: binCount) }
    
    let samplesPerBin = fftResult.count / binCount
    var frequencyBins: [Float] = []
    
    for i in 0..<binCount {
      let startIndex = i * samplesPerBin
      let endIndex = min(startIndex + samplesPerBin, fftResult.count)
      
      if startIndex < endIndex {
        let binSamples = Array(fftResult[startIndex..<endIndex])
        let average = binSamples.reduce(0, +) / Float(binSamples.count)
        frequencyBins.append(average)
      } else {
        frequencyBins.append(0)
      }
    }
    
    // Normalize to 0-1 range
    if let maxValue = frequencyBins.max(), maxValue > 0 {
      frequencyBins = frequencyBins.map { $0 / maxValue }
    }
    
    return frequencyBins
  }
}

// MARK: - Data Structures

struct WaveformData {
  let samples: [Float]
  let waveformPoints: [WaveformPoint]
  let duration: TimeInterval
  let sampleRate: Int
}

struct WaveformPoint {
  let timestamp: TimeInterval
  let amplitude: Float
  let peak: Float
}

// MARK: - Error Types

enum WaveformError: LocalizedError {
  case noAudioTrack
  case readerError
  case analysisError
  case bufferError
    case custom(String)

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      return "No audio track found in file"
    case .readerError:
      return "Failed to read audio data"
    case .analysisError:
      return "Failed to analyze audio waveform"
    case .bufferError:
      return "Failed to process audio buffer"
    case .custom(let message):
      return message

    }
  }
}
