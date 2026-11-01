import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The post text renderer under the existing `appFont` modifiers. iOS 26's linked `Text` ignores
/// lineHeight, so only that combination uses the same drawing and link handling as native rows.
struct PostAttributedText: View {
  let attributedString: AttributedString
  var textColor: Color = .primary
  @Environment(\.font) private var font
  @Environment(\.fontResolutionContext) private var fontResolutionContext
  @Environment(\.fontManager) private var fontManager
  @Environment(\.openURL) private var openURL

  init(_ attributedString: AttributedString, textColor: Color = .primary) {
    self.attributedString = attributedString
    self.textColor = textColor
  }

  var body: some View {
    #if os(iOS)
    if #available(iOS 27.0, *) {
      Text(attributedString)
    } else if #available(iOS 26.0, *), let factor = fontManager.lineHeightFactor,
      attributedString.runs.contains(where: { $0.link != nil }) {
      let resolvedFont = (font ?? .body).resolve(in: fontResolutionContext).ctFont as UIFont
      TightLinkedPostText(
        text: TightLinkedPostText.makeText(
          attributedString, font: resolvedFont, color: UIColor(textColor),
          kerning: fontManager.letterSpacingValue, factor: factor, fontContext: fontResolutionContext),
        placement: .resolve(font: resolvedFont, factor: factor),
        onOpenLink: { url in openURL(url) })
    } else {
      Text(attributedString)
    }
    #else
    Text(attributedString)
    #endif
  }
}

#if os(iOS)
/// A self-sizing adapter around the native row's text view. Font resolution stays in SwiftUI,
/// including Dynamic Type, font design and accessibility weight; the attributed runs retain
/// their own formatting. `FeedPostTextView` supplies tap geometry and VoiceOver link actions.
struct TightLinkedPostText: UIViewRepresentable {
  let text: NSAttributedString
  let placement: AppLineHeightPlacement
  var onOpenLink: (URL) -> Void

  static func makeText(
    _ attributedString: AttributedString, font: UIFont, color: UIColor, kerning: CGFloat, factor: CGFloat,
    fontContext: Font.Context? = nil
  ) -> NSAttributedString {
    let output = NSMutableAttributedString(attributedString)
    let all = NSRange(location: 0, length: output.length)
    output.enumerateAttributes(in: all) { attributes, range, _ in
      let paragraph = NSMutableParagraphStyle()
      if let existing = attributes[.paragraphStyle] as? NSParagraphStyle {
        paragraph.setParagraphStyle(existing)
      }
      paragraph.lineSpacing = 0
      paragraph.lineBreakMode = .byWordWrapping
      AppLineHeightPlacement.resolve(font: font, factor: factor).apply(to: paragraph)
      output.addAttribute(.paragraphStyle, value: paragraph, range: range)
      if attributes[.font] == nil { output.addAttribute(.font, value: font, range: range) }
      if attributes[.foregroundColor] == nil { output.addAttribute(.foregroundColor, value: color, range: range) }
      output.addAttribute(.kern, value: kerning, range: range)
      if let url = attributes[.link] as? URL {
        output.removeAttribute(.link, range: range)
        output.addAttribute(.feedLink, value: url, range: range)
      }
    }
    // NSAttributedString's bridge retains Foundation/UIKit attributes, but not SwiftUI's
    // colors, fonts or link underlines. Post styling supplies those in the SwiftUI scope.
    for run in attributedString.runs {
      let range = NSRange(run.range, in: attributedString)
      if let color = run.foregroundColor {
        output.addAttribute(.foregroundColor, value: UIColor(color), range: range)
      }
      if run.underlineStyle == .single {
        output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      }
      if #available(iOS 26.0, *), let font = run.font, let fontContext {
        output.addAttribute(.font, value: font.resolve(in: fontContext).ctFont as UIFont, range: range)
      }
    }
    return output
  }

  func makeUIView(context: Context) -> FeedPostTextView {
    FeedPostTextView()
  }

  func updateUIView(_ view: FeedPostTextView, context: Context) {
    if view.attributedText != text { view.attributedText = text }
    view.linePlacement = placement
    view.onOpenLink = onOpenLink
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: FeedPostTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    let height = FeedRowLayoutEngine.textHeight(text, width: width)
    let scale = max(context.environment.displayScale, 1)
    return CGSize(width: width, height: ceil(height * scale - 0.0001) / scale)
  }
}
#endif
