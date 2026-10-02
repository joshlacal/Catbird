//
//  ThreadPostNumberView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2026-08-24.
//

import SwiftUI

/// Formatter and validation logic for OP thread post numbering (1/N indicators).
public enum ThreadPostNumberFormatter {
  /// Returns true if index and count are each at least one and index is not greater than count.
  public static func isValid(index: Int?, count: Int?) -> Bool {
    guard let index, let count else { return false }
    return index >= 1 && count >= 1 && index <= count
  }

  /// Formats the display string (e.g., "1/4").
  public static func displayText(index: Int, count: Int) -> String {
    "\(index)/\(count)"
  }

  /// Formats the VoiceOver accessibility label (e.g., "Post 1 of 4").
  public static func accessibilityLabel(index: Int, count: Int) -> String {
    "Post \(index) of \(count)"
  }
}

/// Compact tabular badge displaying the post index within an OP thread (e.g., "1/4").
public struct ThreadPostNumberView: View {
  public let index: Int
  public let count: Int

  public init?(index: Int?, count: Int?) {
    guard ThreadPostNumberFormatter.isValid(index: index, count: count),
      let index,
      let count
    else {
      return nil
    }
    self.index = index
    self.count = count
  }

  public init(index: Int, count: Int) {
    self.index = index
    self.count = count
  }

  public var body: some View {
    if ThreadPostNumberFormatter.isValid(index: index, count: count) {
      Text(ThreadPostNumberFormatter.displayText(index: index, count: count))
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.secondary.opacity(0.12))
        )
        .accessibilityLabel(ThreadPostNumberFormatter.accessibilityLabel(index: index, count: count))
    }
  }
}
