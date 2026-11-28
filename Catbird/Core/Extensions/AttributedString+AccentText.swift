import SwiftUI

enum PostLinkPresentationStyle: Equatable {
  case disabled
  case color
  case underline
  case both

  static func resolve(highlightLinks: Bool, linkStyle: String) -> Self {
    guard highlightLinks else { return .disabled }
    switch linkStyle {
    case "underline": return .underline
    case "both": return .both
    case "color": return .color
    default: return .color
    }
  }
}

extension AttributedString {
  /// Returns a copy with every link/mention/hashtag run colored with the
  /// active theme's WCAG-checked text accent (falling back to the asset-catalog
  /// `AccentTextColor` when no explicit theme accent is provided). Petrel paints
  /// mentions/tags with the chrome `.accentColor` and leaves bare links uncolored,
  /// both of which read too bright against post body copy.
  func applyingPostBodyLinkAccent(
    highlightLinks: Bool = true,
    linkStyle: String = "color",
    accentColor: Color = Color("AccentTextColor")
  ) -> AttributedString {
    let style = PostLinkPresentationStyle.resolve(
      highlightLinks: highlightLinks,
      linkStyle: linkStyle
    )
    var output = self
    let linkRanges = output.runs.compactMap { $0.link != nil ? $0.range : nil }
    for range in linkRanges {
      output[range].foregroundColor = nil
      output[range].underlineStyle = nil
      if style == .color || style == .both {
        output[range].foregroundColor = accentColor
      }
      if style == .underline || style == .both {
        output[range].underlineStyle = .single
      }
    }
    return output
  }
}
