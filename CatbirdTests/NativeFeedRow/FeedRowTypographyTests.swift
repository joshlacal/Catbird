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
}
#endif
