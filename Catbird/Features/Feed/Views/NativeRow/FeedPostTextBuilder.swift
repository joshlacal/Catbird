#if os(iOS)
import Foundation
import Petrel
import UIKit

// MARK: - Feed Post Text

extension NSAttributedString.Key {
  /// The destination of a mention, hashtag or link run. A custom key rather than `.link`, so
  /// `UILabel` draws the run with our colors and the row decides how to open it.
  static let feedLink = NSAttributedString.Key("blue.catbird.feedLink")
}

enum FeedPostTextBuilder {
  static func build(
    post: AppBskyFeedPost, typography: FeedRowTypography, linkStyle: PostLinkPresentationStyle,
    textColor: UIColor, linkColor: UIColor
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = typography.bodyLineSpacing
    paragraph.lineBreakMode = .byWordWrapping
    let output = NSMutableAttributedString(string: post.text, attributes: [
      .font: typography.body,
      .foregroundColor: textColor,
      .kern: typography.kerning,
      .paragraphStyle: paragraph,
    ])
    guard post.facets?.isEmpty == false else { return output }

    // Petrel resolves facet byte offsets and link schemes; copy its link runs.
    let facetText = post.facetsAsAttributedString
    for run in facetText.runs {
      guard let url = run.link else { continue }
      let range = NSRange(run.range, in: facetText)
      guard range.location != NSNotFound, NSMaxRange(range) <= output.length else { continue }
      output.addAttribute(.feedLink, value: url, range: range)
      if linkStyle == .color || linkStyle == .both {
        output.addAttribute(.foregroundColor, value: linkColor, range: range)
      }
      if linkStyle == .underline || linkStyle == .both {
        output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      }
    }
    return output
  }
}
#endif
