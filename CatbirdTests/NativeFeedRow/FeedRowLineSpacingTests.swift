#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Native rows space body lines as the hosted row's `Text` does: `AppFontModifier` passes
/// `getLineSpacing(for: Typography.Size.body) × lineSpacingMultiplier` to `.lineSpacing`, and
/// `Text` ignores a negative value.
@MainActor
@Suite("Feed row line spacing")
struct FeedRowLineSpacingTests {
  private static let settings = ["tight", "normal", "relaxed"]

  /// What the hosted row hands to SwiftUI's `.lineSpacing` (`AppFontModifier`).
  private static func hostedSpacing(_ fontManager: FontManager) -> CGFloat {
    fontManager.getLineSpacing(for: Typography.Size.body) * fontManager.lineSpacingMultiplier
  }

  @Test("Body line spacing is the hosted row's, with negative spacing ignored", arguments: settings)
  func spacingMatchesHostedRow(setting: String) {
    let fontManager = FontManager()
    fontManager.lineSpacing = setting
    let typography = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(typography.bodyLineSpacing == max(0, Self.hostedSpacing(fontManager)))
  }

  @Test("Wrapped text is as tall as the hosted row's Text at every line spacing", arguments:
    settings.flatMap { setting in [UIContentSizeCategory.large, .accessibilityLarge].map { (setting, $0) } })
  func textHeightMatchesHostedText(setting: String, contentSize: UIContentSizeCategory) throws {
    let fontManager = FontManager()
    fontManager.lineSpacing = setting
    let spacing = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory).bodyLineSpacing
    let body = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: .systemFont(ofSize: Typography.Size.body),
      compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
    // Kerning 0 isolates line spacing; `Text`'s tracking and the native `.kern` are compared elsewhere.
    let typography = FeedRowTypography(
      body: body, name: body, metadata: body, bodyLineSpacing: spacing, kerning: 0,
      optionsGlyphSize: .zero, separatorLineHeight: 0, generationKey: 0)
    let text = String(repeating: "spacing between wrapped lines of a feed post ", count: 4)
    let record = AppBskyFeedPost(
      text: text, entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil, tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    let attributed = FeedPostTextBuilder.build(
      post: record, typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    let width: CGFloat = 320
    let native = FeedRowLayoutEngine.textHeight(attributed, width: width)

    let host = UIHostingController(rootView:
      Text(text).font(Font(body)).lineSpacing(Self.hostedSpacing(fontManager))
        .fixedSize(horizontal: false, vertical: true))
    let hosted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    // SwiftUI reports the height rounded up to a whole pixel (under half a point at 2x and 3x).
    #expect(hosted - native > -0.001, "native \(native) hosted \(hosted)")
    #expect(hosted - native < 0.5, "native \(native) hosted \(hosted)")
  }
}
#endif
