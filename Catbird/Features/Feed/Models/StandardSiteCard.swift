import Foundation
import Petrel

enum ExternalEmbedSystemLabelVisibility {
  case show, warn, hide

  static func resolve(_ labels: [ComAtprotoLabelDefs.Label]?, at date: Date = Date()) -> Self {
    let active = (labels ?? []).filter { $0.neg != true && ($0.exp?.date ?? .distantFuture) > date }
    if active.contains(where: { $0.val == "!hide" }) { return .hide }
    if active.contains(where: { $0.val == "!warn" }) { return .warn }
    return .show
  }
}

/// Presentation derived entirely from the AppView's hydrated external embed.
struct StandardSiteCard {
  let external: AppBskyEmbedExternal.ViewExternal
  let articleURL: URL
  let publicationURL: URL?
  let isPublicationOnly: Bool

  init?(_ external: AppBskyEmbedExternal.ViewExternal) {
    let collections = (external.associatedRefs ?? []).compactMap { $0.uri.collection }
    guard collections.contains(where: { $0.hasPrefix("site.standard.") }),
          let articleURL = Self.webURL(external.uri) else { return nil }
    let isPublicationOnly = collections.contains("site.standard.publication")
      && !collections.contains("site.standard.document")
    let publicationURL = external.source.flatMap { Self.webURL($0.uri) }
    // Incomplete publication metadata must keep the ordinary link card visible.
    guard !isPublicationOnly || publicationURL != nil else { return nil }
    self.external = external
    self.articleURL = articleURL
    self.publicationURL = publicationURL
    self.isPublicationOnly = isPublicationOnly
  }

  static func webURL(_ uri: URI) -> URL? {
    guard let components = URLComponents(string: uri.originalString ?? uri.uriString()),
          let scheme = components.scheme?.lowercased(),
          ["https", "http"].contains(scheme),
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil else { return nil }
    return components.url
  }

  var thumbnailURL: URL? { external.thumb.flatMap(Self.webURL) }
  var iconURL: URL? { external.source?.icon.flatMap(Self.webURL) }
  var publicationTitle: String {
    let title = external.source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? (publicationURL?.host ?? "Publication") : title
  }

  var publisher: String? {
    guard let publicationURL, let host = Self.displayHost(publicationURL) else { return nil }
    for (domain, name) in [("leaflet.pub", "Leaflet"), ("pckt.blog", "pckt"), ("offprint.app", "Offprint")] {
      if host == domain || host.hasSuffix("." + domain) { return name }
    }
    return nil
  }

  var authorHandle: String? {
    // The footer identifies the publication's owner, which may differ from the
    // article author. Ref ordering and profile ordering are not related.
    let collection = publicationURL == nil ? "site.standard.document" : "site.standard.publication"
    let owner = external.associatedRefs?.first(where: {
      $0.uri.collection?.hasPrefix(collection) == true
    })?.uri.authority
    guard let owner else { return nil }
    return external.associatedProfiles?.first { $0.did.didString() == owner }?.handle.description
  }

  var displayDomain: String? {
    guard publisher == nil, let domain = Self.displayHost(articleURL) else { return nil }
    if let handle = authorHandle?.lowercased(), domain == handle || domain.hasSuffix("." + handle) {
      return nil
    }
    return domain
  }

  private static func displayHost(_ url: URL) -> String? {
    guard var domain = url.host?.lowercased() else { return nil }
    // JavaScript URL.host preserves nondefault ports, unlike Foundation URL.host.
    if let port = url.port,
       !(url.scheme?.lowercased() == "https" && port == 443),
       !(url.scheme?.lowercased() == "http" && port == 80) {
      domain += ":\(port)"
    }
    return domain
  }

  var readingMinutes: Int? { external.readingTime.flatMap { $0 > 0 ? $0 : nil } }

  /// Ignore invalid or low-contrast publisher colors; semantic app colors remain readable.
  var buttonColors: (background: AppBskyEmbedExternal.ColorRGB, foreground: AppBskyEmbedExternal.ColorRGB)? {
    guard let background = external.source?.theme?.accentRGB,
          let foreground = external.source?.theme?.accentForegroundRGB,
          let backgroundLuminance = Self.luminance(background),
          let foregroundLuminance = Self.luminance(foreground),
          (max(backgroundLuminance, foregroundLuminance) + 0.05)
            / (min(backgroundLuminance, foregroundLuminance) + 0.05) >= 4.5 else { return nil }
    return (background, foreground)
  }

  private static func luminance(_ color: AppBskyEmbedExternal.ColorRGB) -> Double? {
    let channels = [color.r, color.g, color.b]
    guard channels.allSatisfy({ (0...255).contains($0) }) else { return nil }
    let linear = channels.map { value -> Double in
      let component = Double(value) / 255
      return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }
}
