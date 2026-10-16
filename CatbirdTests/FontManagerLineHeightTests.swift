#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// "Tight" line spacing tightens every `appFont` text, plain or linked, through every FontManager
/// modifier; Normal and Relaxed keep their spacing.
@MainActor
@Suite("App line height")
struct FontManagerLineHeightTests {
  private static let settings = ["tight", "normal", "relaxed"]

  private static func fontManager(lineSpacing: String) -> FontManager {
    let fontManager = FontManager()
    fontManager.lineSpacing = lineSpacing
    return fontManager
  }

  /// The height SwiftUI gives `view` at `width`, as a self-sizing row measures it.
  private static func hostedHeight<V: View>(_ view: V, fontManager: FontManager, width: CGFloat = 300) -> CGFloat {
    let host = UIHostingController(rootView:
      view.environment(\.fontManager, fontManager).fixedSize(horizontal: false, vertical: true))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }

  /// `lines` short lines, one per paragraph, so no line wraps at the hosted width.
  private static func copy(lines: Int) -> String {
    (1...lines).map { "Line \($0) of a feed post" }.joined(separator: "\n")
  }

  /// `copy(lines:)` with a mention-style link run on its second line, as post text carries.
  private static func linkedCopy(lines: Int) -> AttributedString {
    var text = AttributedString(copy(lines: lines))
    if let range = text.range(of: "Line 2") {
      text[range].link = URL(string: "mention://did:plc:alice")
    }
    return text
  }

  @Test("Only Tight, on systems that draw it, has a constant line height",
    arguments: settings + ["bogus"], [true, false])
  func tightSetsConstantLineHeight(setting: String, supportsLineHeight: Bool) {
    let factor = FontManager.lineHeightFactor(for: setting, supportsLineHeight: supportsLineHeight)
    #expect(factor == (setting == "tight" && supportsLineHeight ? 1.075 : nil))
    #expect(FontManager.tightLineHeightFactor == 1.075)
    let fontManager = Self.fontManager(lineSpacing: setting)
    #expect(fontManager.lineHeightFactor
      == FontManager.lineHeightFactor(for: setting, supportsLineHeight: FontManager.supportsLineHeight))
  }

  @Test("Line spacing is never negative, and Relaxed keeps its spacing", arguments: settings + ["bogus"])
  func lineSpacingIsNeverNegative(setting: String) {
    let fontManager = Self.fontManager(lineSpacing: setting)
    for size in [CGFloat(12), 15, 17, 28] {
      #expect(fontManager.getLineSpacing(for: size) >= 0, "\(setting) at \(size) pt")
    }
    #expect(fontManager.roleLineSpacing >= 0)
    if setting == "relaxed" {
      #expect(abs(fontManager.getLineSpacing(for: Typography.Size.body) - 5.1) < 0.001)
      #expect(abs(fontManager.roleLineSpacing - 6.63) < 0.001)
    }
  }

  @Test("Settings offers Tight only where it is drawn, and shows a stored Tight as Normal elsewhere")
  func lineSpacingOptionsHideTightWithoutLineHeight() {
    #expect(FontManager.lineSpacingOptions(supportsLineHeight: true).map(\.value) == ["tight", "normal", "relaxed"])
    #expect(FontManager.lineSpacingOptions(supportsLineHeight: true).map(\.title) == ["Tight", "Normal", "Relaxed"])
    #expect(FontManager.lineSpacingOptions(supportsLineHeight: false).map(\.value) == ["normal", "relaxed"])
    for setting in Self.settings {
      #expect(FontManager.displayedLineSpacing(setting, supportsLineHeight: true) == setting)
    }
    #expect(FontManager.displayedLineSpacing("tight", supportsLineHeight: false) == "normal")
    #expect(FontManager.displayedLineSpacing("relaxed", supportsLineHeight: false) == "relaxed")
    #expect(FontManager.displayedLineSpacing("bogus", supportsLineHeight: false) == "bogus")
  }

  /// `AppLineHeightModifier` checks the system itself: it draws a constant line height exactly
  /// where `supportsLineHeight` offers Tight, so no system draws a Tight it hides in Settings, and
  /// none pays for an environment transform that can never write.
  @Test("The line-height modifier draws exactly where Tight is offered")
  func modifierDrawsExactlyWhereTightIsOffered() {
    let text = Text(Self.copy(lines: 4)).font(Font(UIFont.systemFont(ofSize: 17)))
    let natural = Self.hostedHeight(text, fontManager: FontManager())
    let modified = Self.hostedHeight(
      text.modifier(AppLineHeightModifier(factor: FontManager.tightLineHeightFactor)), fontManager: FontManager())
    #expect((modified < natural) == FontManager.supportsLineHeight,
      "with the modifier \(modified), without \(natural), Tight offered: \(FontManager.supportsLineHeight)")
  }

  @Test("Tight tightens plain and linked body text alike; Normal keeps the font's line height",
    .enabled(if: FontManager.supportsLineHeight))
  func hostedTightTightensPlainAndLinkedText() {
    let lines = 5
    let tight = Self.fontManager(lineSpacing: "tight")
    let normal = Self.fontManager(lineSpacing: "normal")
    let body = AppUIFont.font(normal, size: Typography.Size.body, weight: .regular, textStyle: .body)

    let tightPlain = Self.hostedHeight(Text(Self.copy(lines: lines)).appFont(AppTextRole.body), fontManager: tight)
    let tightLinked = Self.hostedHeight(Text(Self.linkedCopy(lines: lines)).appFont(AppTextRole.body), fontManager: tight)
    let normalPlain = Self.hostedHeight(Text(Self.copy(lines: lines)).appFont(AppTextRole.body), fontManager: normal)

    // Normal: the font's own line height, rounded up to a whole pixel.
    let natural = CGFloat(lines) * body.lineHeight
    #expect(normalPlain >= natural - 0.001, "normal \(normalPlain) natural \(natural)")
    #expect(normalPlain - natural < 0.5, "normal \(normalPlain) natural \(natural)")
    // Tight: every line gap is at least a point and a half shorter, with or without a link run.
    #expect(tightPlain < normalPlain - CGFloat(lines - 1) * 1.5, "tight \(tightPlain) normal \(normalPlain)")
    #expect(abs(tightLinked - tightPlain) < 0.34, "linked \(tightLinked) plain \(tightPlain)")
    // Each line is the constant multiple of the point size, the total rounded up to a whole pixel.
    let constant = CGFloat(lines) * FontManager.tightLineHeightFactor * body.pointSize
    #expect(tightPlain >= constant - 0.001 && tightPlain - constant < 0.5, "tight \(tightPlain) lines \(constant)")
  }

  /// The FontManager modifiers other than `appFont(_: AppTextRole)`.
  enum Modifier: String, CaseIterable, CustomTestStringConvertible {
    case customSize, directFont, customScaledFont, appText, captionRole

    var testDescription: String { rawValue }

    @ViewBuilder
    func apply(to text: Text) -> some View {
      switch self {
      case .customSize: text.appFont(size: 15, weight: .regular, relativeTo: .subheadline)
      case .directFont: text.appFont(Font.body)
      case .customScaledFont: text.customScaledFont(size: 13)
      case .appText: text.appText(size: 15)
      case .captionRole: text.appFont(AppTextRole.caption)
      }
    }
  }

  @Test("Tight tightens text under every FontManager modifier", .enabled(if: FontManager.supportsLineHeight),
    arguments: Modifier.allCases)
  func everyAppFontModifierTightens(modifier: Modifier) {
    let text = Text(Self.copy(lines: 4))
    let tight = Self.hostedHeight(modifier.apply(to: text), fontManager: Self.fontManager(lineSpacing: "tight"))
    let normal = Self.hostedHeight(modifier.apply(to: text), fontManager: Self.fontManager(lineSpacing: "normal"))
    #expect(tight < normal, "tight \(tight) normal \(normal)")
  }
}
#endif
