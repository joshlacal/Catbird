//
//  CharacterLimitIndicator.swift
//  Catbird
//
//  A circular progress indicator showing character count approaching the 300 character limit.
//  Displays with Liquid Glass aesthetic and smooth animations.
//

import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
struct CharacterLimitIndicator: View {
  let currentCount: Int
  let maxCount: Int = 300
  
  private var progress: Double {
    guard currentCount > 0 else { return 0 }
    return min(Double(currentCount) / Double(maxCount), 1.0)
  }
  
  private var remainingCount: Int {
    maxCount - currentCount
  }
  
  private var isOverLimit: Bool {
    currentCount > maxCount
  }

  private var state: LimitState {
    switch currentCount {
    case 0...260:
      return .safe
    case 261...280:
      return .info
    case 281...290:
      return .warning
    case 291...299:
      return .critical
    default:
      return .over
    }
  }
  
  private var tintColor: Color {
    switch state {
    case .safe:
      return .secondary
    case .info:
      return .green
    case .warning:
      return .orange
    case .critical, .over:
      return .red
    }
  }
  
  private var displayText: String {
    if isOverLimit {
      return "+\(abs(remainingCount))"
    } else {
      return "\(remainingCount)"
    }
  }
  
  private var accessibilityLabel: String {
    if isOverLimit {
      return "Character limit exceeded by \(abs(remainingCount))"
    } else {
      return "\(remainingCount) characters remaining"
    }
  }
  
  var body: some View {
    ZStack {
      Circle()
        .stroke(tintColor.opacity(0.2), lineWidth: 2.5)
      
      Circle()
        .trim(from: 0, to: progress)
        .stroke(tintColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: progress)
      
      if isOverLimit {
        Image(systemName: "exclamationmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(tintColor)
      } else {
        Text(displayText)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(tintColor)
          .monospacedDigit()
      }
    }
    .frame(width: 32, height: 32)
//    .glassEffect(.regular.tint(tintColor))
    .opacity(state == .safe ? 0.85 : 1)
    .scaleEffect(state == .critical ? 1.05 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.6).repeatCount(state == .critical ? 2 : 1), value: state)
    .transition(.scale.combined(with: .opacity))
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.updatesFrequently)
  }
  
  private enum LimitState: Equatable {
    case safe
    case info
    case warning
    case critical
    case over
  }
}

@available(iOS 18.0, macOS 13.0, *)
struct CharacterLimitIndicatorLegacy: View {
  let currentCount: Int
  let maxCount: Int = 300
  
  private var progress: Double {
    guard currentCount > 0 else { return 0 }
    return min(Double(currentCount) / Double(maxCount), 1.0)
  }
  
  private var remainingCount: Int {
    maxCount - currentCount
  }
  
  private var isOverLimit: Bool {
    currentCount > maxCount
  }
  
  private var tintColor: Color {
    switch currentCount {
    case 0...260:
      return .secondary
    case 261...280:
      return .green
    case 281...290:
      return .orange
    default:
      return .red
    }
  }
  
  private var displayText: String {
    if isOverLimit {
      return "+\(abs(remainingCount))"
    } else {
      return "\(remainingCount)"
    }
  }
  
  var body: some View {
    ZStack {
      Circle()
        .stroke(tintColor.opacity(0.2), lineWidth: 2.5)
      
      Circle()
        .trim(from: 0, to: progress)
        .stroke(tintColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: progress)
      
      if isOverLimit {
        Image(systemName: "exclamationmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(tintColor)
      } else {
        Text(displayText)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(tintColor)
          .monospacedDigit()
      }
    }
    .frame(width: 32, height: 32)
    .background(
      Circle()
        .fill(.ultraThinMaterial)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    )
    .opacity(currentCount <= 260 ? 0.9 : 1)
    .transition(.scale.combined(with: .opacity))
    .accessibilityLabel(isOverLimit ? "Character limit exceeded by \(abs(remainingCount))" : "\(remainingCount) characters remaining")
  }
}

struct CharacterLimitIndicatorWrapper: View {
  let currentCount: Int
  
  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      CharacterLimitIndicator(currentCount: currentCount)
    } else {
      CharacterLimitIndicatorLegacy(currentCount: currentCount)
    }
  }
}

#Preview("Character Limit States") {
  if #available(iOS 26.0, macOS 26.0, *) {
    VStack(spacing: 24) {
      HStack(spacing: 16) {
        CharacterLimitIndicator(currentCount: 260)
        Text("Safe (260/300)")
      }
      
      HStack(spacing: 16) {
        CharacterLimitIndicator(currentCount: 285)
        Text("Warning (285/300)")
      }
      
      HStack(spacing: 16) {
        CharacterLimitIndicator(currentCount: 295)
        Text("Critical (295/300)")
      }
      
      HStack(spacing: 16) {
        CharacterLimitIndicator(currentCount: 305)
        Text("Over Limit (305/300)")
      }
    }
    .padding()
  }
}
