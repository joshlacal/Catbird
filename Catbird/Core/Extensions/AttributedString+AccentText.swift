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
  /// dark text accent (`AccentTextColor`). Petrel paints mentions/tags with
  /// the chrome `.accentColor` and leaves bare links uncolored, both of
  /// which read too bright against post body copy.
  func applyingPostBodyLinkAccent(
    highlightLinks: Bool = true,
    linkStyle: String = "color"
  ) -> AttributedString {
    let style = PostLinkPresentationStyle.resolve(
      highlightLinks: highlightLinks,
      linkStyle: linkStyle
    )
    guard style != .disabled else { return self }

    var output = self
    let textAccent = Color("AccentTextColor")
    let linkRanges = output.runs.compactMap { $0.link != nil ? $0.range : nil }
    for range in linkRanges {
      if style == .color || style == .both {
        output[range].foregroundColor = textAccent
      }
      if style == .underline || style == .both {
        output[range].underlineStyle = .single
      }
    }
    return output
  }
}
