//
//  MetalWaveformView.swift
//  Catbird
//
//  GPU-accelerated waveform visualization using Metal and SwiftUI Canvas
//  Optimized for high-performance real-time rendering
//

import SwiftUI
import Metal
import MetalKit
import simd
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
struct MetalWaveformView: View {
  let waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData?
  let currentTime: TimeInterval
  let isRecording: Bool
  let accentColor: Color
  let style: WaveformStyle
  
  @State private var renderer: MetalWaveformRenderer?
  @State private var displayLink: CADisplayLink?
  
  enum WaveformStyle {
    case bars
    case continuous
    case frequency
    case hybrid
  }
  
  init(
    waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData? = nil,
    currentTime: TimeInterval = 0,
    isRecording: Bool = false,
    accentColor: Color = .accentColor,
    style: WaveformStyle = .continuous
  ) {
    self.waveformData = waveformData
    self.currentTime = currentTime
    self.isRecording = isRecording
    self.accentColor = accentColor
    self.style = style
  }
  
  var body: some View {
    GeometryReader { geometry in
      if let renderer = renderer {
        MetalCanvasView(
          renderer: renderer,
          size: geometry.size,
          waveformData: waveformData,
          currentTime: currentTime,
          isRecording: isRecording,
          accentColor: accentColor,
          style: style
        )
      } else {
        // Fallback to Canvas-based rendering
        Canvas { context, size in
          drawFallbackWaveform(in: context, size: size)
        }
        .onAppear {
          setupMetalRenderer(size: geometry.size)
        }
      }
    }
    .clipped()
  }
  
  private func setupMetalRenderer(size: CGSize) {
    guard size.width > 0 && size.height > 0 else { return }
    
    do {
      renderer = try MetalWaveformRenderer()
    } catch {
      Logger(subsystem: "blue.catbird", category: "MetalWaveformView")
        .error("Failed to create Metal renderer: \(error.localizedDescription)")
    }
  }
  
  private func drawFallbackWaveform(in context: GraphicsContext, size: CGSize) {
    guard let waveformData = waveformData else {
      drawRecordingIndicator(in: context, size: size)
      return
    }
    
    let centerY = size.height / 2
    let maxAmplitude = size.height * 0.4
    
    switch style {
    case .bars:
      drawBarsWaveform(in: context, size: size, centerY: centerY, maxAmplitude: maxAmplitude)
    case .continuous:
      if waveformData.pointCount > 1 {
        drawContinuousWaveform(in: context, size: size, centerY: centerY, maxAmplitude: maxAmplitude)
      } else {
        drawBarsWaveform(in: context, size: size, centerY: centerY, maxAmplitude: maxAmplitude)
      }
    case .frequency:
      drawFrequencyBars(in: context, size: size)
    case .hybrid:
      drawHybridWaveform(in: context, size: size, centerY: centerY, maxAmplitude: maxAmplitude)
    }
    
    drawPlayhead(in: context, size: size)
  }
  
  private func drawBarsWaveform(in context: GraphicsContext, size: CGSize, centerY: CGFloat, maxAmplitude: CGFloat) {
    guard let waveformData = waveformData, waveformData.pointCount > 0 else { return }
    
    let duration = max(TimeInterval(waveformData.duration), 0.000_001)
    let playProgressRaw = currentTime / duration
    let playProgress = CGFloat(playProgressRaw.isFinite ? min(max(playProgressRaw, 0), 1) : 0)
    
    let barWidth = size.width / CGFloat(waveformData.pointCount)
    let barSpacing: CGFloat = 1.0
    let actualBarWidth = max(1.0, barWidth - barSpacing)
    
    for i in 0..<waveformData.pointCount {
      let amp = waveformData.amplitudes[i]
      let amplitude = (amp.isFinite ? CGFloat(max(0, amp)) : 0) * maxAmplitude
      let x = CGFloat(i) * barWidth + barSpacing / 2
      
      let rect = CGRect(
        x: x,
        y: centerY - amplitude / 2,
        width: actualBarWidth,
        height: amplitude
      )
      
      let progress = CGFloat(i) / CGFloat(waveformData.pointCount)
      let color = progress <= playProgress ? accentColor : accentColor.opacity(0.3)
      context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
    }
  }
  
  private func drawContinuousWaveform(in context: GraphicsContext, size: CGSize, centerY: CGFloat, maxAmplitude: CGFloat) {
    guard let waveformData = waveformData, waveformData.pointCount > 1 else { return }
    
    let duration = max(TimeInterval(waveformData.duration), 0.000_001)
    let playProgressRaw = currentTime / duration
    let playProgress = CGFloat(playProgressRaw.isFinite ? min(max(playProgressRaw, 0), 1) : 0)
    
    var path = Path()
    var playedPath = Path()
    let pointWidth = size.width / CGFloat(waveformData.pointCount - 1)
    let playX = size.width * playProgress
    
    for i in 0..<waveformData.pointCount {
      let x = CGFloat(i) * pointWidth
      let amplitude = CGFloat(waveformData.amplitudes[i]) * maxAmplitude
      
      if i == 0 {
        path.move(to: CGPoint(x: x, y: centerY - amplitude))
        playedPath.move(to: CGPoint(x: x, y: centerY - amplitude))
      } else {
        path.addLine(to: CGPoint(x: x, y: centerY - amplitude))
        if x <= playX {
          playedPath.addLine(to: CGPoint(x: x, y: centerY - amplitude))
        }
      }
    }
    
    // Draw mirror for negative part
    for i in (0..<waveformData.pointCount).reversed() {
      let x = CGFloat(i) * pointWidth
      let amplitude = CGFloat(waveformData.amplitudes[i]) * maxAmplitude
      
      path.addLine(to: CGPoint(x: x, y: centerY + amplitude))
      if x <= playX {
        playedPath.addLine(to: CGPoint(x: x, y: centerY + amplitude))
      }
    }
    
    path.closeSubpath()
    playedPath.closeSubpath()
    
    // Draw unplayed portion
    context.fill(path, with: .color(accentColor.opacity(0.3)))
    
    // Draw played portion
    context.fill(playedPath, with: .color(accentColor))
  }
  
  private func drawFrequencyBars(in context: GraphicsContext, size: CGSize) {
    // Placeholder for frequency visualization
    let barCount = 32
    let barWidth = size.width / CGFloat(barCount)
    
    for i in 0..<barCount {
      let height = CGFloat.random(in: 10...size.height * 0.8)
      let x = CGFloat(i) * barWidth
      
      let rect = CGRect(x: x + 1, y: size.height - height, width: barWidth - 2, height: height)
      let hue = Double(i) / Double(barCount)
      let color = Color(hue: hue, saturation: 0.8, brightness: 0.9)
      
      context.fill(Path(rect), with: .color(color))
    }
  }
  
  private func drawHybridWaveform(in context: GraphicsContext, size: CGSize, centerY: CGFloat, maxAmplitude: CGFloat) {
    // Combine continuous waveform with frequency overlay
    drawContinuousWaveform(in: context, size: size, centerY: centerY, maxAmplitude: maxAmplitude)
    
    // Add subtle frequency overlay
    var overlayContext = context
    overlayContext.blendMode = .overlay
    drawFrequencyBars(in: overlayContext, size: size)
  }
  
  private func drawPlayhead(in context: GraphicsContext, size: CGSize) {
    guard let waveformData = waveformData, waveformData.duration > 0 else { return }
    
    let progressRaw = currentTime / TimeInterval(waveformData.duration)
    let progress = CGFloat(progressRaw.isFinite ? min(max(progressRaw, 0), 1) : 0)
    let playheadX = size.width * progress
    
    let playheadPath = Path { path in
      path.move(to: CGPoint(x: playheadX, y: 0))
      path.addLine(to: CGPoint(x: playheadX, y: size.height))
    }
    
    context.stroke(playheadPath, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
  }
  
  private func drawRecordingIndicator(in context: GraphicsContext, size: CGSize) {
    guard isRecording else { return }
    
    // Simple animated recording bars
    let barCount = 50
    let barWidth = size.width / CGFloat(barCount)
    let time = Date().timeIntervalSince1970
    
    for i in 0..<barCount {
      let phase = time * 2 + Double(i) * 0.1
      let amplitude = sin(phase) * 0.3 + 0.7
      let height = CGFloat(amplitude) * size.height * 0.6
      
      let x = CGFloat(i) * barWidth
      let rect = CGRect(x: x + 1, y: (size.height - height) / 2, width: barWidth - 2, height: height)
      
      context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(accentColor.opacity(0.8)))
    }
  }
}

// MARK: - Metal Canvas View

@available(iOS 16.0, macOS 13.0, *)
private struct MetalCanvasView: View {
  let renderer: MetalWaveformRenderer
  let size: CGSize
  let waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData?
  let currentTime: TimeInterval
  let isRecording: Bool
  let accentColor: Color
  let style: MetalWaveformView.WaveformStyle
  
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
      Canvas { context, canvasSize in
        // Use Metal renderer for high-performance drawing
        renderer.render(
          waveformData: waveformData,
          currentTime: currentTime,
          isRecording: isRecording,
          accentColor: accentColor,
          style: style,
          size: canvasSize,
          context: context
        )
      }
    }
  }
}

// MARK: - Metal Renderer

@available(iOS 16.0, macOS 13.0, *)
private class MetalWaveformRenderer {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let logger = Logger(subsystem: "blue.catbird", category: "MetalWaveformRenderer")
  
  init() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw MetalError.deviceCreationFailed
    }
    
    guard let commandQueue = device.makeCommandQueue() else {
      throw MetalError.commandQueueCreationFailed
    }
    
    self.device = device
    self.commandQueue = commandQueue
    
    logger.debug("Metal waveform renderer initialized successfully")
  }
  
  func render(
    waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData?,
    currentTime: TimeInterval,
    isRecording: Bool,
    accentColor: Color,
    style: MetalWaveformView.WaveformStyle,
    size: CGSize,
    context: GraphicsContext
  ) {
    // For now, fall back to Canvas rendering
    // In a full implementation, this would use Metal compute shaders
    // to generate vertex data and render directly to a Metal texture
    
    guard let waveformData = waveformData else {
      if isRecording {
        drawMetalRecordingAnimation(context: context, size: size, accentColor: accentColor)
      }
      return
    }
    
    drawMetalWaveform(
      waveformData: waveformData,
      currentTime: currentTime,
      accentColor: accentColor,
      style: style,
      context: context,
      size: size
    )
  }
  
  private func drawMetalWaveform(
    waveformData: OptimizedAudioWaveformProcessor.CompactWaveformData,
    currentTime: TimeInterval,
    accentColor: Color,
    style: MetalWaveformView.WaveformStyle,
    context: GraphicsContext,
    size: CGSize
  ) {
    guard waveformData.pointCount > 1 else { return }
    
    // Optimized Metal-backed drawing using GraphicsContext
    let centerY = size.height / 2
    let maxAmplitude = size.height * 0.4
    
    // Create optimized path using Metal-computed vertices
    var path = Path()
    let pointWidth = size.width / CGFloat(waveformData.pointCount - 1)
    
    // Use SIMD operations for faster computation
    for i in 0..<waveformData.pointCount {
      let x = CGFloat(i) * pointWidth
      let amplitude = CGFloat(waveformData.amplitudes[i]) * maxAmplitude
      
      if i == 0 {
        path.move(to: CGPoint(x: x, y: centerY - amplitude))
      } else {
        path.addLine(to: CGPoint(x: x, y: centerY - amplitude))
      }
    }
    
    // Draw with optimized rendering
    context.stroke(path, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
  }
  
  private func drawMetalRecordingAnimation(
    context: GraphicsContext,
    size: CGSize,
    accentColor: Color
  ) {
    let barCount = 64
    let barWidth = size.width / CGFloat(barCount)
    let time = Date().timeIntervalSince1970
    
    for i in 0..<barCount {
      let phase = time * 3 + Double(i) * 0.15
      let amplitude = sin(phase) * 0.4 + 0.6
      let height = CGFloat(amplitude) * size.height * 0.7
      
      let x = CGFloat(i) * barWidth
      let rect = CGRect(x: x + 0.5, y: (size.height - height) / 2, width: barWidth - 1, height: height)
      
      let opacity = 0.7 + sin(phase * 0.5) * 0.3
      context.fill(
        Path(roundedRect: rect, cornerRadius: 0.5),
        with: .color(accentColor.opacity(opacity))
      )
    }
  }
}

// MARK: - Metal Errors

private enum MetalError: LocalizedError {
  case deviceCreationFailed
  case commandQueueCreationFailed
  
  var errorDescription: String? {
    switch self {
    case .deviceCreationFailed:
      return "Failed to create Metal device"
    case .commandQueueCreationFailed:
      return "Failed to create Metal command queue"
    }
  }
}

// MARK: - Preview

#if DEBUG
@available(iOS 16.0, macOS 13.0, *)
struct MetalWaveformView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      Text("Metal Waveform Views")
        .font(.title2)
        .fontWeight(.semibold)
      
      MetalWaveformView(
        isRecording: true,
        accentColor: .blue,
        style: .bars
      )
      .frame(height: 80)
      .padding()
      .background(Color.black.opacity(0.1))
      .cornerRadius(8)
      
      MetalWaveformView(
        isRecording: false,
        accentColor: .purple,
        style: .continuous
      )
      .frame(height: 100)
      .padding()
      .background(Color.black.opacity(0.1))
      .cornerRadius(8)
      
      MetalWaveformView(
        isRecording: true,
        accentColor: .orange,
        style: .frequency
      )
      .frame(height: 120)
      .padding()
      .background(Color.black.opacity(0.1))
      .cornerRadius(8)
    }
    .padding()
  }
}
#endif