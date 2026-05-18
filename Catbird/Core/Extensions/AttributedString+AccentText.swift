import SwiftUI

extension AttributedString {
  /// Returns a copy with every link/mention/hashtag run colored with the
  /// dark text accent (`AccentTextColor`). Petrel paints mentions/tags with
  /// the chrome `.accentColor` and leaves bare links uncolored, both of
  /// which read too bright against post body copy.
  func applyingPostBodyLinkAccent() -> AttributedString {
    var output = self
    let textAccent = Color("AccentTextColor")
    let linkRanges = output.runs.compactMap { $0.link != nil ? $0.range : nil }
    for range in linkRanges {
      output[range].foregroundColor = textAccent
    }
    return output
  }
}
