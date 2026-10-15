#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Trending interstitial typography", .serialized)
struct TrendingInterstitialTypographyTests {
  /// An account switch releases one `FontManager` and creates another, which the allocator can
  /// place at the released manager's address with the same generation. The typography cache must
  /// still serve the new manager's own settings, not the fonts resolved for the released one.
  @Test("A font manager at a released manager's address gets fonts for its own settings")
  func reusedManagerAddressGetsItsOwnFonts() {
    let traits = UITraitCollection { traits in
      traits.preferredContentSizeCategory = .large
      traits.displayScale = 3
    }
    for _ in 0..<500 {
      let releasedID: ObjectIdentifier
      let releasedGeneration: Int
      let releasedSize: CGFloat
      do {
        let released = FontManager()
        released.fontSize = "small"
        releasedID = ObjectIdentifier(released)
        releasedGeneration = released.generation
        releasedSize = TrendingInterstitialTypography.resolved(fontManager: released, traits: traits)
          .subheadline.pointSize
      }
      let current = FontManager()
      current.fontSize = "large"
      guard ObjectIdentifier(current) == releasedID, current.generation == releasedGeneration else { continue }

      let typography = TrendingInterstitialTypography.resolved(fontManager: current, traits: traits)
      let expected = AppUIFont.font(
        current, size: Typography.Size.subheadline, weight: .medium, textStyle: .subheadline).pointSize
      #expect(abs(typography.subheadline.pointSize - expected) < 0.01)
      #expect(abs(typography.subheadline.pointSize - releasedSize) > 0.01)
      return
    }
    Issue.record("No FontManager was allocated at a released manager's address with its generation")
  }
}
#endif
