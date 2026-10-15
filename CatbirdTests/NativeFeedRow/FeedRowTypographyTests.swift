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
    let typography = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    #expect(abs(typography.body.pointSize - Typography.Size.body * fontManager.sizeScale) < 0.01)
    #expect(abs(typography.name.pointSize - Typography.Size.headline * fontManager.sizeScale) < 0.01)
  }

  @Test("Line spacing and kerning come from FontManager")
  func metricsFromFontManager() {
    let fontManager = FontManager()
    let typography = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    #expect(typography.bodyLineSpacing == fontManager.getLineSpacing(for: typography.body.pointSize))
    #expect(typography.kerning == fontManager.letterSpacingValue)
  }

  @Test("Changing a font setting changes the generation key")
  func generationKeyTracksSettings() {
    let fontManager = FontManager()
    let before = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    let afterBold = FeedRowTypography.resolved(fontManager: fontManager, boldText: true)
    #expect(before.generationKey != afterBold.generationKey)
  }

  @Test("Line and letter spacing changes change the generation key")
  func generationKeyTracksSpacing() {
    let fontManager = FontManager()
    let before = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    fontManager.lineSpacing = "relaxed"
    let afterLine = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    #expect(before.generationKey != afterLine.generationKey)
    #expect(afterLine.bodyLineSpacing == fontManager.getLineSpacing(for: afterLine.body.pointSize))
    fontManager.letterSpacing = "loose"
    let afterLetter = FeedRowTypography.resolved(fontManager: fontManager, boldText: false)
    #expect(afterLine.generationKey != afterLetter.generationKey)
    #expect(afterLetter.kerning == fontManager.letterSpacingValue)
  }
}
#endif
