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
    #expect(typography.bodyLineSpacing == fontManager.roleLineSpacing)
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

  @Test("Tight resolves constant line heights for the body, name and metadata",
    .enabled(if: FontManager.supportsLineHeight))
  func tightResolvesLinePlacements() {
    let fontManager = FontManager()
    let contentSize = UIApplication.shared.preferredContentSizeCategory
    let normal = FeedRowTypography.resolved(fontManager: fontManager, boldText: false, contentSize: contentSize)
    #expect(normal.bodyLine == nil && normal.nameLine == nil && normal.metadataLine == nil)
    #expect(normal.separatorLineHeight == FeedRowTypography.environmentFont(contentSize: contentSize).lineHeight)

    fontManager.lineSpacing = "tight"
    let tight = FeedRowTypography.resolved(fontManager: fontManager, boldText: false, contentSize: contentSize)
    let factor = FontManager.tightLineHeightFactor
    #expect(tight.generationKey != normal.generationKey)
    #expect(tight.bodyLine == .resolve(font: tight.body, factor: factor))
    #expect(tight.nameLine == .resolve(font: tight.name, factor: factor))
    #expect(tight.metadataLine == .resolve(font: tight.metadata, factor: factor))
    let separator = FeedRowTypography.environmentFont(contentSize: contentSize)
    #expect(abs(tight.separatorLineHeight - factor * separator.pointSize) < 0.001)
    #expect(tight.bodyLineSpacing == 0)
  }

  /// The test factory scales its fonts for an explicit content size, and must otherwise build rows
  /// as production does, so tests that use it see Tight's constant line heights.
  @Test("Factory rows at Tight carry the production line placements", .enabled(if: FontManager.supportsLineHeight))
  func factoryRowsFollowTight() throws {
    let tightManager = FontManager()
    tightManager.lineSpacing = "tight"
    let factor = FontManager.tightLineHeightFactor
    let tight = NativeFeedRowTestFactory.typography(contentSize: .large, fontManager: tightManager)
    #expect(tight.bodyLine == .resolve(font: tight.body, factor: factor))
    #expect(tight.nameLine == .resolve(font: tight.name, factor: factor))
    #expect(tight.metadataLine == .resolve(font: tight.metadata, factor: factor))
    #expect(tight.bodyLineSpacing == tightManager.roleLineSpacing)
    #expect(tight.separatorLineHeight
      == FeedRowTypography.separatorLineHeight(contentSize: .large, lineHeightFactor: factor))
    let normal = NativeFeedRowTestFactory.typography(contentSize: .large, fontManager: FontManager())
    #expect(normal.bodyLine == nil && normal.nameLine == nil && normal.metadataLine == nil)
    #expect(tight.generationKey != normal.generationKey)

    let text = "Line one of a post\nLine two of a post\nLine three of a post"
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: text, fontManager: tightManager)
    let normalContent = try NativeFeedRowTestFactory.content(text: text, fontManager: FontManager())
    #expect(cell.textViewForTesting.linePlacement == tight.bodyLine)
    #expect(content.layout.height < normalContent.layout.height,
      "tight \(content.layout.height) normal \(normalContent.layout.height)")
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
    #expect(afterLine.bodyLineSpacing == fontManager.roleLineSpacing)
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
