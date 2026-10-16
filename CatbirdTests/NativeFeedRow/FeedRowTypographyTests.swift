#if os(iOS)
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed row typography")
struct FeedRowTypographyTests {
  @Test("Body and name sizes follow the app's size scale")
  func sizesFollowScale() {
    let fontManager = FontManager()
    fontManager.dynamicTypeEnabled = false
    let typography = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(abs(typography.body.pointSize - Typography.Size.body * fontManager.sizeScale) < 0.01)
    #expect(abs(typography.name.pointSize - Typography.Size.headline * fontManager.sizeScale) < 0.01)
  }

  @Test("Line spacing and kerning come from FontManager")
  func metricsFromFontManager() {
    let fontManager = FontManager()
    let typography = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    // `AppFontModifier`'s spacing, which the hosted row's text uses.
    #expect(typography.bodyLineSpacing == max(
      0, fontManager.getLineSpacing(for: Typography.Size.body) * fontManager.lineSpacingMultiplier))
    #expect(typography.kerning == fontManager.letterSpacingValue)
  }

  @Test("Changing a font setting changes the generation key")
  func generationKeyTracksSettings() {
    let fontManager = FontManager()
    let before = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    let afterBold = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: true, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(before.generationKey != afterBold.generationKey)
  }

  @Test("Line and letter spacing changes change the generation key")
  func generationKeyTracksSpacing() {
    let fontManager = FontManager()
    let before = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    fontManager.lineSpacing = "relaxed"
    let afterLine = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(before.generationKey != afterLine.generationKey)
    #expect(afterLine.bodyLineSpacing
      == fontManager.getLineSpacing(for: Typography.Size.body) * fontManager.lineSpacingMultiplier)
    fontManager.letterSpacing = "loose"
    let afterLetter = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(afterLine.generationKey != afterLetter.generationKey)
    #expect(afterLetter.kerning == fontManager.letterSpacingValue)
  }

  /// The key hashes the font design as its UIKit value rather than describing it as a string, and
  /// must still tell designs apart when nothing else differs: a manager at a released manager's
  /// address with the same generation and another design.
  @Test("A font manager at a released manager's address with another design gets its own fonts")
  func reusedManagerAddressGetsItsOwnDesign() {
    let contentSize = UIApplication.shared.preferredContentSizeCategory
    for _ in 0..<500 {
      let releasedID: ObjectIdentifier
      let releasedGeneration: Int
      let releasedBody: String
      do {
        let released = FontManager()
        released.fontStyle = "serif"
        releasedID = ObjectIdentifier(released)
        releasedGeneration = released.generation
        releasedBody = FeedRowTypography.resolved(fontManager: released, boldText: false, contentSize: contentSize)
          .body.fontName
      }
      let current = FontManager()
      current.fontStyle = "rounded"
      guard ObjectIdentifier(current) == releasedID, current.generation == releasedGeneration else { continue }

      let typography = FeedRowTypography.resolved(fontManager: current, boldText: false, contentSize: contentSize)
      let expected = AppUIFont.font(current, size: Typography.Size.body, weight: .regular, textStyle: .body)
      #expect(typography.body.fontName == expected.fontName)
      #expect(typography.body.fontName != releasedBody)
      return
    }
    Issue.record("No FontManager was allocated at a released manager's address with its generation")
  }
}
#endif
