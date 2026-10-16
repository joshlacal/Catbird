#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Native rows space body lines as the hosted row's `Text` does: `AppFontModifier`'s spacing
/// (`FontManager.roleLineSpacing`), and at Tight its constant line height.
@MainActor
@Suite("Feed row line spacing")
struct FeedRowLineSpacingTests {
  private static let settings = ["tight", "normal", "relaxed"]

  @Test("Body line spacing and line height are the hosted row's", arguments: settings)
  func spacingMatchesHostedRow(setting: String) {
    let fontManager = FontManager()
    fontManager.lineSpacing = setting
    let typography = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    #expect(typography.bodyLineSpacing == fontManager.roleLineSpacing)
    let tight = setting == "tight" && FontManager.supportsLineHeight
    #expect(typography.bodyLine
      == (tight ? .resolve(font: typography.body, factor: FontManager.tightLineHeightFactor) : nil))
  }

  /// Post text whose lines never wrap at the test width, so line breaking (which `Text`'s tracking
  /// and the native `.kern` reach differently) cannot change the line count.
  enum Content: String, CaseIterable, CustomTestStringConvertible {
    case plain, links, emoji, twoParagraphs

    var testDescription: String { rawValue }

    var text: String {
      switch self {
      case .plain: "Line one of a feed post\nLine two of a feed post\nLine three\nLine four"
      case .links: "Hi @alice.test there\nTagged #catbird today\nRead example.com/read/1\nLine four"
      case .emoji: "Line one 🦋🏳️‍🌈👩🏽‍💻\nLine two of a feed post\nLine three 🎉\nLine four"
      case .twoParagraphs: "First paragraph line one\nFirst paragraph line two\n\nSecond paragraph"
      }
    }

    func facets() throws -> [AppBskyRichtextFacet]? {
      guard self == .links else { return nil }
      let text = self.text
      func slice(_ token: String) throws -> AppBskyRichtextFacet.ByteSlice {
        let range = try #require(text.range(of: token))
        let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
        return AppBskyRichtextFacet.ByteSlice(byteStart: start, byteEnd: start + token.utf8.count)
      }
      return [
        AppBskyRichtextFacet(index: try slice("@alice.test"), features: [
          .appBskyRichtextFacetMention(AppBskyRichtextFacet.Mention(did: try DID(didString: "did:plc:alice")))]),
        AppBskyRichtextFacet(index: try slice("#catbird"), features: [
          .appBskyRichtextFacetTag(AppBskyRichtextFacet.Tag(tag: "catbird"))]),
        AppBskyRichtextFacet(index: try slice("example.com/read/1"), features: [
          .appBskyRichtextFacetLink(AppBskyRichtextFacet.Link(uri: URI(uriString: "https://example.com/read/1")))]),
      ]
    }

    func post() throws -> AppBskyFeedPost {
      AppBskyFeedPost(
        text: text, entities: nil, facets: try facets(), reply: nil, embed: nil, langs: nil, labels: nil,
        tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    }
  }

  private static var screenScale: CGFloat {
    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
  }

  private static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    ceil(value * scale - 0.0001) / scale
  }

  /// The row's typography under `fontManager`. At an accessibility size the fonts are scaled for
  /// that size explicitly, as `FeedRowTypography.resolved` scales them for the running app's.
  private static func typography(fontManager: FontManager, contentSize: UIContentSizeCategory?) -> FeedRowTypography {
    let resolved = FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
    guard let contentSize else { return resolved }
    let body = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: .systemFont(ofSize: Typography.Size.body),
      compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
    let line = fontManager.lineHeightFactor.map { AppLineHeightPlacement.resolve(font: body, factor: $0) }
    return FeedRowTypography(
      body: body, name: body, metadata: body, bodyLineSpacing: resolved.bodyLineSpacing, bodyLine: line,
      nameLine: line, metadataLine: line, kerning: resolved.kerning, optionsGlyphSize: .zero, separatorLineHeight: 0,
      generationKey: resolved.generationKey &+ contentSize.rawValue.hashValue)
  }

  /// The native text height the layout engine measures for `content` under `typography`.
  private static func nativeHeight(_ content: Content, typography: FeedRowTypography, width: CGFloat) throws -> CGFloat {
    let attributed = FeedPostTextBuilder.build(
      post: try content.post(), typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    return FeedRowLayoutEngine.textHeight(attributed, width: width)
  }

  @Test("Body text is as tall natively as the hosted row's Text draws it, at every line spacing",
    arguments: settings, [UIContentSizeCategory?.none, .accessibilityLarge])
  func textHeightMatchesHostedText(setting: String, contentSize: UIContentSizeCategory?) throws {
    let width: CGFloat = 320
    let fontManager = FontManager()
    fontManager.lineSpacing = setting
    let typography = Self.typography(fontManager: fontManager, contentSize: contentSize)
    let normalTypography = Self.typography(fontManager: FontManager(), contentSize: contentSize)
    for content in Content.allCases {
      let native = try Self.nativeHeight(content, typography: typography, width: width)
      // The hosted row's body: the post's attributed text (link runs included) under `appFont(.body)`,
      // or at an accessibility size the modifiers `AppFontModifier` applies, with that size's font.
      let text = Text(try content.post().facetsAsAttributedString)
      let hosted: CGFloat
      if contentSize == nil {
        hosted = Self.hostedHeight(text.appFont(AppTextRole.body), fontManager: fontManager, width: width)
      } else {
        hosted = Self.hostedHeight(
          text.font(Font(typography.body)).lineSpacing(fontManager.roleLineSpacing)
            .tracking(fontManager.letterSpacingValue)
            .modifier(AppLineHeightModifier(factor: fontManager.lineHeightFactor)),
          fontManager: fontManager, width: width)
      }
      let label = "\(setting) \(content.rawValue) \(contentSize?.rawValue ?? "app size")"
      #expect(abs(hosted - Self.pixelCeil(native, scale: Self.screenScale)) < 0.001, "\(label): native \(native) hosted \(hosted)")

      if setting == "tight" && FontManager.supportsLineHeight {
        let normal = try Self.nativeHeight(content, typography: normalTypography, width: width)
        #expect(native < normal, "\(label): tight \(native) normal \(normal)")
      }
    }
  }

  private static func hostedHeight<V: View>(_ view: V, fontManager: FontManager, width: CGFloat) -> CGFloat {
    let host = UIHostingController(rootView:
      view.environment(\.fontManager, fontManager).fixedSize(horizontal: false, vertical: true))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }
}
#endif
