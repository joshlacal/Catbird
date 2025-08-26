//
//  WaveformView.swift
//  Catbird
//
//  Created by Claude on 8/26/25.
//

import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WaveformView: View {
  let samples: [Float]
  let currentLevel: Float
  let isRecording: Bool
  let accentColor: Color
  
  // Animation properties
  @State private var animationPhase: Double = 0
  private let barCount: Int = 50
  private let maxBarHeight: CGFloat = 60
  private let minBarHeight: CGFloat = 4
  
  init(samples: [Float], currentLevel: Float = 0, isRecording: Bool = false, accentColor: Color = .accentColor) {
    self.samples = samples
    self.currentLevel = currentLevel
    self.isRecording = isRecording
    self.accentColor = accentColor
  }
  
  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<barCount, id: \.self) { index in
        waveformBar(for: index)
      }
    }
    .frame(height: maxBarHeight)
    .onAppear {
      if isRecording {
        startAnimation()
      }
    }
    .onChange(of: isRecording) { _, newValue in
      if newValue {
        startAnimation()
      } else {
        stopAnimation()
      }
    }
  }
  
  private func waveformBar(for index: Int) -> some View {
    let height = calculateBarHeight(for: index)
    let opacity = calculateBarOpacity(for: index)
    
    return RoundedRectangle(cornerRadius: 2)
      .fill(accentColor.opacity(opacity))
      .frame(width: 4, height: height)
      .animation(.easeInOut(duration: 0.1), value: height)
  }
  
  private func calculateBarHeight(for index: Int) -> CGFloat {
    // If we have samples data, use it
    if !samples.isEmpty {
      let sampleIndex = Int((Double(index) / Double(barCount)) * Double(samples.count))
      let clampedIndex = min(sampleIndex, samples.count - 1)
      let sample = samples[clampedIndex]
      return minBarHeight + (CGFloat(sample) * (maxBarHeight - minBarHeight))
    }
    
    // If recording, use current level with some variation
    if isRecording && currentLevel > 0 {
      let baseHeight = minBarHeight + (CGFloat(currentLevel) * (maxBarHeight - minBarHeight))
      
      // Add some visual variation based on position and animation phase
      let variation = sin(animationPhase + Double(index) * 0.5) * 0.3 + 0.7
      return baseHeight * CGFloat(variation)
    }
    
    // Default to minimum height when not recording
    return minBarHeight
  }
  
  private func calculateBarOpacity(for index: Int) -> Double {
    if !samples.isEmpty {
      // When showing recorded samples, use full opacity for visible bars
      let sampleIndex = Int((Double(index) / Double(barCount)) * Double(samples.count))
      let clampedIndex = min(sampleIndex, samples.count - 1)
      let sample = samples[clampedIndex]
      return sample > 0.05 ? 0.9 : 0.3
    }
    
    if isRecording && currentLevel > 0 {
      // When recording, create a wave effect
      let distance = abs(Double(index) - Double(barCount) / 2)
      let maxDistance = Double(barCount) / 2
      let baseOpacity = 1.0 - (distance / maxDistance) * 0.6
      
      // Add animation pulse
      let pulse = sin(animationPhase * 2) * 0.2 + 0.8
      return baseOpacity * pulse
    }
    
    return 0.3
  }
  
  private func startAnimation() {
    withAnimation(.linear(duration: 0.1).repeatForever(autoreverses: false)) {
      animationPhase = 2 * .pi
    }
  }
  
  private func stopAnimation() {
    withAnimation(.easeOut(duration: 0.5)) {
      animationPhase = 0
    }
  }
}

// MARK: - Static Waveform View

struct StaticWaveformView: View {
  let waveformData: [WaveformPoint]
  let duration: TimeInterval
  let currentTime: TimeInterval
  let accentColor: Color
  
  private let waveformHeight: CGFloat = 80
  
  var body: some View {
    GeometryReader { geometry in
      Canvas { context, size in
        drawWaveform(in: context, size: size)
        drawPlayhead(in: context, size: size)
      }
    }
    .frame(height: waveformHeight)
  }
  
  private func drawWaveform(in context: GraphicsContext, size: CGSize) {
    guard !waveformData.isEmpty else { return }
    
    let centerY = size.height / 2
    let maxAmplitude = size.height * 0.4
    let pointWidth = size.width / CGFloat(waveformData.count)
    
    var path = Path()
    
    for (index, point) in waveformData.enumerated() {
      let x = CGFloat(index) * pointWidth
      let amplitude = CGFloat(point.amplitude) * maxAmplitude
      
      // Draw positive wave
      path.move(to: CGPoint(x: x, y: centerY))
      path.addLine(to: CGPoint(x: x, y: centerY - amplitude))
      
      // Draw negative wave
      path.move(to: CGPoint(x: x, y: centerY))
      path.addLine(to: CGPoint(x: x, y: centerY + amplitude))
    }
    
    context.stroke(path, with: .color(accentColor.opacity(0.8)), lineWidth: 2)
  }
  
  private func drawPlayhead(in context: GraphicsContext, size: CGSize) {
    guard duration > 0 else { return }
    
    let progress = currentTime / duration
    let playheadX = size.width * CGFloat(progress)
    
    let playheadPath = Path { path in
      path.move(to: CGPoint(x: playheadX, y: 0))
      path.addLine(to: CGPoint(x: playheadX, y: size.height))
    }
    
    context.stroke(playheadPath, with: .color(.white), lineWidth: 2)
  }
}

// MARK: - Frequency Visualization

struct FrequencyVisualizerView: View {
  let frequencyBins: [Float]
  let accentColor: Color
  
  @State private var animationOffset: Double = 0
  private let binCount: Int = 32
  
  var body: some View {
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(0..<min(binCount, frequencyBins.count), id: \.self) { index in
        frequencyBar(for: index)
      }
    }
    .onAppear {
      startFrequencyAnimation()
    }
  }
  
  private func frequencyBar(for index: Int) -> some View {
    let height = calculateFrequencyBarHeight(for: index)
    let hue = Double(index) / Double(binCount) * 0.8 // Rainbow effect
    
    return RoundedRectangle(cornerRadius: 1)
      .fill(
        LinearGradient(
          colors: [
            accentColor.opacity(0.3),
            accentColor
          ],
          startPoint: .bottom,
          endPoint: .top
        )
      )
      .frame(width: 8, height: height)
      .animation(.easeOut(duration: 0.1), value: height)
  }
  
  private func calculateFrequencyBarHeight(for index: Int) -> CGFloat {
    guard index < frequencyBins.count else { return 4 }
    
    let minHeight: CGFloat = 4
    let maxHeight: CGFloat = 60
    let frequency = frequencyBins[index]
    
    // Add some animation variation
    let variation = sin(animationOffset + Double(index) * 0.3) * 0.1 + 0.9
    
    return minHeight + (CGFloat(frequency) * (maxHeight - minHeight) * CGFloat(variation))
  }
  
  private func startFrequencyAnimation() {
    withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
      animationOffset = 2 * .pi
    }
  }
}

// MARK: - Preview Helpers

#if DEBUG
struct WaveformView_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      VStack(spacing: 20) {
        Text("Recording Waveform")
          .font(.headline)
        
        WaveformView(
          samples: [],
          currentLevel: 0.7,
          isRecording: true,
          accentColor: .blue
        )
        
        Text("Static Waveform")
          .font(.headline)
        
        WaveformView(
          samples: generateSampleWaveform(),
          currentLevel: 0,
          isRecording: false,
          accentColor: .blue
        )
        
        Text("Frequency Visualizer")
          .font(.headline)
        
        FrequencyVisualizerView(
          frequencyBins: generateSampleFrequencies(),
          accentColor: .purple
        )
      }
      .padding()
    }
    .previewLayout(.sizeThatFits)
  }
  
  static func generateSampleWaveform() -> [Float] {
    return (0..<100).map { i in
      Float(sin(Double(i) * 0.1) * 0.5 + 0.5) * Float.random(in: 0.3...1.0)
    }
  }
  
  static func generateSampleFrequencies() -> [Float] {
    return (0..<32).map { _ in Float.random(in: 0...1) }
  }
}
#endif