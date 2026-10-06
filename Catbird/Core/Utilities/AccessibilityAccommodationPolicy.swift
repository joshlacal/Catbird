import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// System accommodations remain separate from the account's stored augmentations.
struct SystemAccessibilitySnapshot: Equatable, Sendable {
  var reduceMotion = false
  var prefersCrossfade = false
  var increaseContrast = false
  var boldText = false

  @MainActor static var current: Self {
    #if os(iOS)
    return Self(
      reduceMotion: UIAccessibility.isReduceMotionEnabled,
      prefersCrossfade: UIAccessibility.prefersCrossFadeTransitions,
      increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
      boldText: UIAccessibility.isBoldTextEnabled
    )
    #elseif os(macOS)
    return Self(
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    )
    #endif
  }
}

enum AccessibilityAccommodationPolicy {
  static func isEnabled(system: Bool, app: Bool) -> Bool { system || app }

  static func usesCrossfade(system: SystemAccessibilitySnapshot, reduceMotion: Bool, prefersCrossfade: Bool) -> Bool {
    isEnabled(system: system.reduceMotion, app: reduceMotion)
      && isEnabled(system: system.prefersCrossfade, app: prefersCrossfade)
  }
}

/// Raw preference strings are retained, including values from a newer app version.
enum AppTextSizeLimit {
  static let fullSystemRange = "system"
  static let options: [(value: String, title: String)] = [
    (fullSystemRange, "Full System Range"),
    ("xxLarge", "Extra Extra Large"),
    ("xxxLarge", "Extra Extra Extra Large"),
    ("accessibility1", "Accessibility Medium"),
    ("accessibility2", "Accessibility Large"),
    ("accessibility3", "Accessibility Extra Large"),
    ("accessibility4", "Accessibility Extra Extra Large"),
    ("accessibility5", "Accessibility Extra Extra Extra Large")
  ]

  static func title(for value: String) -> String {
    options.first { $0.value == value }?.title ?? value
  }
}
