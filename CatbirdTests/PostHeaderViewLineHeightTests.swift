#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// At Tight SwiftUI draws a line's descenders below its frame (`AppLineHeightModifier`), so the
/// hosted post header must not clip the handle's line to its frame. The header is drawn with room
/// around it and compared with the handle drawn alone, where nothing can clip it.
@MainActor
@Suite("Post header line height", .enabled(if: FontManager.supportsLineHeight))
struct PostHeaderViewLineHeightTests {
  private static let scale: CGFloat = 3
  /// Room around the drawing, so ink outside the header's lines is on the canvas.
  private static let margin: CGFloat = 12
  /// Counts the secondary-colored handle and the anti-aliased edges of every glyph as ink.
  private static let inkThreshold = 230
  /// A display name and time with no descenders, beside a handle full of them.
  private static let displayName = "Ada Lovelace"
  private static let handle = "jpg.gypsy.test"

  private static func fontManager(lineSpacing: String) -> FontManager {
    let fontManager = FontManager()
    fontManager.lineSpacing = lineSpacing
    return fontManager
  }

  /// `content` laid out at `width` from the top leading corner of a white canvas with `margin` around it.
  private static func ink<V: View>(_ content: V, fontManager: FontManager, width: CGFloat) throws -> RenderedPixels {
    let renderer = ImageRenderer(content:
      content
        .frame(width: width, alignment: .topLeading)
        .padding(margin)
        .background(Color.white)
        .environment(\.fontManager, fontManager)
        .environment(\.colorScheme, .light))
    renderer.scale = scale
    return try RenderedPixels(image: try #require(renderer.cgImage), scale: scale)
  }

  /// The handle as the header draws it, alone.
  private static func handleAlone() -> some View {
    Text("@\(handle)").appBody().foregroundStyle(.secondary).lineLimit(1).fixedSize()
  }

  /// The header in full (390 pt) and with its handle truncated beside the name (230 pt).
  @Test("The handle's descenders are drawn whole beside a display name", arguments: [CGFloat(390), 230])
  func handleDescendersAreNotClipped(width: CGFloat) throws {
    for lineSpacing in ["tight", "normal"] {
      let fontManager = Self.fontManager(lineSpacing: lineSpacing)
      let header = try Self.ink(
        PostHeaderView(displayName: Self.displayName, handle: Self.handle, timeAgo: Date()),
        fontManager: fontManager, width: width)
      let handle = try Self.ink(Self.handleAlone(), fontManager: fontManager, width: width)
      let headerBottom = try #require(header.inkRows(threshold: Self.inkThreshold).last).upperBound
      let handleBottom = try #require(handle.inkRows(threshold: Self.inkThreshold).last).upperBound
      #expect(abs(headerBottom - handleBottom) <= 1,
        "\(lineSpacing) at \(width) pt: the header's ink ends at row \(headerBottom), the handle's at \(handleBottom)")
    }
  }

  /// A handle with no room beside the name is still hidden, rather than shown as a stray "@".
  @Test("A handle with no room beside the display name is not drawn")
  func squeezedHandleIsHidden() throws {
    let fontManager = Self.fontManager(lineSpacing: "tight")
    let width: CGFloat = 150
    let header = try Self.ink(
      PostHeaderView(displayName: Self.displayName, handle: Self.handle, timeAgo: Date()),
      fontManager: fontManager, width: width)
    let name = try Self.ink(
      Text(Self.displayName).appHeadline().lineLimit(1), fontManager: fontManager, width: width)
    // The handle's descenders would reach below the name's and time's ink.
    let headerBottom = try #require(header.inkRows(threshold: Self.inkThreshold).last).upperBound
    let nameBottom = try #require(name.inkRows(threshold: Self.inkThreshold).last).upperBound
    #expect(abs(headerBottom - nameBottom) <= 1, "header ink ends at row \(headerBottom), the name's at \(nameBottom)")
  }
}
#endif
