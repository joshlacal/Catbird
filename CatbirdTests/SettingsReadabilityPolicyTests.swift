import Testing
@testable import Catbird

@Suite("Settings readability policy", .serialized)
@MainActor
struct SettingsReadabilityPolicyTests {
  @Test("Every legacy cap keeps its category and Full System Range removes the maximum")
  func legacyCapsAndFullRange() {
    let manager = FontManager()
    let cases: [(String, CrossPlatformContentSizeCategory)] = [
      ("xxLarge", .extraExtraLarge), ("xxxLarge", .extraExtraExtraLarge),
      ("accessibility1", .accessibilityMedium), ("accessibility2", .accessibilityLarge),
      ("accessibility3", .accessibilityExtraLarge), ("accessibility4", .accessibilityExtraExtraLarge),
      ("accessibility5", .accessibilityExtraExtraExtraLarge)
    ]
    for (value, category) in cases {
      manager.maxDynamicTypeSize = value
      #expect(manager.dynamicTypeLimit == category)
      #expect(manager.maxDynamicTypeSize == value)
    }
    manager.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    #expect(manager.dynamicTypeLimit == nil)
    #expect(manager.maxContentSizeCategory == .accessibilityExtraExtraExtraLarge)
    manager.maxDynamicTypeSize = "future-cap"
    #expect(manager.maxDynamicTypeSize == "future-cap")
    #expect(manager.dynamicTypeLimit == .accessibilityMedium)
    #expect(AppTextSizeLimit.title(for: "future-cap") == "future-cap")
  }

  @Test("System accommodations cannot be disabled by an app choice",
    arguments: [false, true], [false, true])
  func systemBaseline(system: Bool, app: Bool) {
    #expect(AccessibilityAccommodationPolicy.isEnabled(system: system, app: app) == (system || app))
  }

  @Test("Crossfade requires effective reduced motion and preserves both sources")
  func crossfadePolicy() {
    #expect(AccessibilityAccommodationPolicy.usesCrossfade(system: .init(reduceMotion: true, prefersCrossfade: true), reduceMotion: false, prefersCrossfade: false))
    #expect(AccessibilityAccommodationPolicy.usesCrossfade(system: .init(reduceMotion: true), reduceMotion: false, prefersCrossfade: true))
    #expect(!AccessibilityAccommodationPolicy.usesCrossfade(system: .init(prefersCrossfade: true), reduceMotion: false, prefersCrossfade: true))
  }
}
