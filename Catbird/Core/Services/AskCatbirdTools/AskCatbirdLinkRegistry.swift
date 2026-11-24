import Foundation

/// The web links Ask Catbird may open during one turn.
///
/// Only links that already appear in the person's request, the selected
/// content, the conversation or an earlier tool result are readable. The model
/// cannot compose a new address, so retrieved text cannot steer it into
/// encoding conversation data into a request to a host of its choosing.
actor AskCatbirdLinkRegistry {
  static let maximumLinks = 256

  private var links: Set<String> = []

  init(seedText: [String] = []) {
    for text in seedText {
      for key in Self.links(in: text).map(Self.key(for:)) where links.count < Self.maximumLinks {
        links.insert(key)
      }
    }
  }

  func ingest(_ text: String) {
    for url in Self.links(in: text) where links.count < Self.maximumLinks {
      links.insert(Self.key(for: url))
    }
  }

  func contains(_ url: URL) -> Bool {
    links.contains(Self.key(for: url))
  }

  var isEmpty: Bool { links.isEmpty }

  /// Web links found in text, including bare domains the system data detector
  /// recognizes. Only http and https links are kept.
  static func links(in text: String) -> [URL] {
    guard !text.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return detector.matches(in: text, options: [], range: range).compactMap { match in
      guard let url = match.url, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" else { return nil }
      return url
    }
  }

  /// Comparison key that ignores case in the scheme and host, a fragment, a
  /// default port and a lone trailing slash, which models often add or drop.
  static func key(for url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    if components.port == 443 && components.scheme == "https" { components.port = nil }
    if components.port == 80 && components.scheme == "http" { components.port = nil }
    if components.path == "/" { components.path = "" }
    if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
    let normalized = components.string ?? url.absoluteString
    // An https page is the same document whether or not the model kept the scheme it saw.
    return normalized.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
  }
}
