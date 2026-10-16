#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// `AppLineHeightPlacement` puts UIKit's lines where SwiftUI's `Text` draws them under
/// `AppLineHeightModifier`: the same heights, the same baselines, and nothing clipped.
@MainActor
@Suite("App line height placement", .enabled(if: FontManager.supportsLineHeight))
struct AppLineHeightPlacementTests {
  private static let factor = FontManager.tightLineHeightFactor
  private static let scale: CGFloat = 3
  /// Room around rendered text, so ink outside its lines is on the canvas.
  private static let margin: CGFloat = 10

  enum FontCase: String, CaseIterable, CustomTestStringConvertible {
    case system17, system17Semibold, system28, serif17, monospaced17

    var testDescription: String { rawValue }

    var font: UIFont {
      switch self {
      case .system17: .systemFont(ofSize: 17)
      case .system17Semibold: .systemFont(ofSize: 17, weight: UIFont.Weight.semibold)
      case .system28: .systemFont(ofSize: 28)
      case .serif17: Self.designed(.serif)
      case .monospaced17: Self.designed(.monospaced)
      }
    }

    private static func designed(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
      let base = UIFont.systemFont(ofSize: 17)
      return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: 17) } ?? base
    }
  }

  private static func pixelCeil(_ value: CGFloat) -> CGFloat {
    ceil(value * scale - 0.0001) / scale
  }

  private static func attributed(_ string: String, font: UIFont, placement: AppLineHeightPlacement) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    placement.apply(to: paragraph)
    return NSAttributedString(string: string, attributes: [
      .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.black,
    ])
  }

  @Test("Hosted and native text are as tall as their lines", arguments: [1, 2, 4, 10], FontCase.allCases)
  func hostedHeightsMatchPlacement(lines: Int, fontCase: FontCase) {
    let font = fontCase.font
    let placement = AppLineHeightPlacement.resolve(font: font, factor: Self.factor)
    let string = (1...lines).map { "Line \($0) Ágy" }.joined(separator: "\n")

    let host = UIHostingController(rootView:
      Text(string).font(Font(font)).modifier(AppLineHeightModifier(factor: Self.factor))
        .fixedSize(horizontal: false, vertical: true))
    let hosted = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
    #expect(abs(hosted - Self.pixelCeil(placement.height(lines: lines))) < 0.001, "hosted \(hosted)")

    let native = Self.attributed(string, font: font, placement: placement).boundingRect(
      with: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil).height
    #expect(abs(native - placement.height(lines: lines)) < 0.001, "native \(native)")
  }

  /// Accented capitals, an emoji line, an Arabic paragraph and descenders.
  private static let mixedText = "ÁÉÍ Ágy top line\nmiddle 👩🏽‍💻 line\nمرحبا بالعالم gy\nlast gjpqy"

  private static func hostedInk(_ string: String, font: UIFont, width: CGFloat) throws -> RenderedPixels {
    let renderer = ImageRenderer(content:
      Text(string).font(Font(font)).foregroundStyle(.black)
        .modifier(AppLineHeightModifier(factor: factor))
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(margin))
    renderer.scale = scale
    return try RenderedPixels(image: try #require(renderer.cgImage), scale: scale)
  }

  /// `FeedPostTextView` drawing `text` as the native row does, inside a container with room
  /// around it.
  private static func nativeInk(_ text: NSAttributedString, placement: AppLineHeightPlacement, width: CGFloat) throws
    -> (pixels: RenderedPixels, textHeight: CGFloat) {
    let height = pixelCeil(FeedRowLayoutEngine.textHeight(text, width: width))
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width + 2 * margin, height: height + 2 * margin))
    let view = FeedPostTextView(frame: CGRect(x: margin, y: margin, width: width, height: height))
    view.attributedText = text
    view.linePlacement = placement
    container.addSubview(view)
    container.layoutIfNeeded()
    return (try RenderedPixels(of: container, scale: scale), height)
  }

  @Test("Native lines draw where the hosted Text draws them")
  func glyphsLandWhereHostedTextDrawsThem() throws {
    let font = UIFont.systemFont(ofSize: 17)
    let placement = AppLineHeightPlacement.resolve(font: font, factor: Self.factor)
    let width: CGFloat = 300
    let hosted = try Self.hostedInk(Self.mixedText, font: font, width: width).inkRows()
    let native = try Self.nativeInk(
      Self.attributed(Self.mixedText, font: font, placement: placement), placement: placement, width: width
    ).pixels.inkRows()
    try #require(hosted.count == native.count, "hosted bands \(hosted), native bands \(native)")
    for (h, n) in zip(hosted, native) {
      #expect(abs(h.lowerBound - n.lowerBound) <= 1 && abs(h.upperBound - n.upperBound) <= 1,
        "hosted \(hosted), native \(native)")
    }
  }

  @Test("Accents on the first line and descenders on the last are not clipped")
  func tightFirstAndLastLinesAreNotClipped() throws {
    let font = UIFont.systemFont(ofSize: 17)
    let placement = AppLineHeightPlacement.resolve(font: font, factor: Self.factor)
    let width: CGFloat = 300
    let text = Self.attributed("ÁÉÍ 👩🏽‍💻 Ångström\nmiddle line\nlast gjpqy", font: font, placement: placement)
    let native = try Self.nativeInk(text, placement: placement, width: width)

    // The same text drawn with nothing to clip it, where the label draws it.
    let format = UIGraphicsImageRendererFormat()
    format.scale = Self.scale
    format.opaque = true
    let size = CGSize(width: width + 2 * Self.margin, height: native.textHeight + 2 * Self.margin)
    let reference = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      text.draw(
        with: CGRect(x: Self.margin, y: Self.margin + placement.glyphOffset, width: width, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    let referencePixels = try RenderedPixels(image: try #require(reference.cgImage), scale: Self.scale)
    let expected = referencePixels.darkPixelCount()
    let drawn = native.pixels.darkPixelCount()
    try #require(expected > 1000, "the reference text was not drawn")
    // Anti-aliasing differs slightly between `UILabel` and `NSAttributedString.draw`.
    #expect(abs(CGFloat(drawn - expected)) <= CGFloat(expected) * 0.01, "drawn \(drawn) expected \(expected)")
    // Clipping would start the ink below the accents' tops or end it above the descenders.
    let drawnBands = native.pixels.inkRows()
    let expectedBands = referencePixels.inkRows()
    let top = (try #require(drawnBands.first).lowerBound, try #require(expectedBands.first).lowerBound)
    let bottom = (try #require(drawnBands.last).upperBound, try #require(expectedBands.last).upperBound)
    #expect(abs(top.0 - top.1) <= 1 && abs(bottom.0 - bottom.1) <= 1, "drawn \(drawnBands) expected \(expectedBands)")
  }
}
#endif
