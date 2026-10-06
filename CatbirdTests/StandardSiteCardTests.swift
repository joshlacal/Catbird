import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Standard site card presentation")
@MainActor
struct StandardSiteCardTests {
  private let articleOwner = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  private let publicationOwner = "did:plc:og5t4xeyapx5fwjx5hnr2c56"

  private func reference(_ collection: String, owner: String) -> [String: Any] {
    [
      "uri": "at://\(owner)/\(collection)/record",
      "cid": CID.fromDAGCBOR(Data(collection.utf8)).string
    ]
  }

  private func payload(
    document: Bool = true, publication: Bool = false, source: Bool = false
  ) -> [String: Any] {
    var refs: [[String: Any]] = []
    if document { refs.append(reference("site.standard.document", owner: articleOwner)) }
    if publication { refs.append(reference("site.standard.publication", owner: publicationOwner)) }
    var result: [String: Any] = [
      "uri": "https://example.com/article", "title": "Article", "description": "Description",
      "associatedRefs": refs,
      "associatedProfiles": [
        ["did": publicationOwner, "handle": "publisher.example.com"],
        ["did": articleOwner, "handle": "author.example.com"]
      ]
    ]
    if source { result["source"] = ["uri": "https://example.com", "title": "Publication"] }
    return result
  }

  private func view(_ payload: [String: Any]) throws -> AppBskyEmbedExternal.ViewExternal {
    try JSONDecoder().decode(
      AppBskyEmbedExternal.ViewExternal.self,
      from: JSONSerialization.data(withJSONObject: payload)
    )
  }

  private func card(_ payload: [String: Any]) throws -> StandardSiteCard {
    try #require(StandardSiteCard(view(payload)))
  }

  @Test("Article, article with publication and publication-only cards remain distinct")
  func supportedShapes() throws {
    let article = try card(payload())
    #expect(!article.isPublicationOnly)
    #expect(article.publicationURL == nil)
    let combined = try card(payload(publication: true, source: true))
    #expect(!combined.isPublicationOnly)
    #expect(combined.publicationURL?.absoluteString == "https://example.com")
    let publication = try card(payload(document: false, publication: true, source: true))
    #expect(publication.isPublicationOnly)
  }

  @Test("Ordinary and incomplete publication embeds retain fallback rendering")
  func fallbackCards() throws {
    #expect(StandardSiteCard(try view(payload(document: false))) == nil)
    #expect(StandardSiteCard(try view(payload(document: false, publication: true))) == nil)
    var ordinary = payload()
    ordinary["associatedRefs"] = [reference("app.bsky.feed.post", owner: articleOwner)]
    #expect(StandardSiteCard(try view(ordinary)) == nil)
  }

  @Test("Author selection follows the displayed collection, independent of array order")
  func authorByCollection() throws {
    var combined = payload(publication: true, source: true)
    let refs = try #require(combined["associatedRefs"] as? [[String: Any]])
    for orderedRefs in [refs, Array(refs.reversed())] {
      combined["associatedRefs"] = orderedRefs
      #expect(try card(combined).authorHandle == "publisher.example.com")
      var article = combined
      article.removeValue(forKey: "source")
      #expect(try card(article).authorHandle == "author.example.com")
    }
    var unmatchedPublication = payload(source: true)
    unmatchedPublication["associatedProfiles"] = [["did": articleOwner, "handle": "author.example.com"]]
    #expect(try card(unmatchedPublication).authorHandle == nil)
  }

  @Test("Domain suppression preserves full hosts and uses dot boundaries")
  func domainSuppression() throws {
    var data = payload()
    data["uri"] = "https://www.example.com/article"
    #expect(try card(data).displayDomain == "www.example.com")
    data["uri"] = "https://author.example.com/article"
    #expect(try card(data).displayDomain == nil)
    data["uri"] = "https://blog.author.example.com/article"
    #expect(try card(data).displayDomain == nil)
    data["uri"] = "https://notauthor.example.com/article"
    #expect(try card(data).displayDomain == "notauthor.example.com")
    data["uri"] = "https://author.example.com:8443/article"
    #expect(try card(data).displayDomain == "author.example.com:8443")
    data["uri"] = "https://author.example.com:443/article"
    #expect(try card(data).displayDomain == nil)
  }

  @Test("Unsafe article URLs do not become enhanced navigation targets", arguments: [
    "javascript:alert(1)", "file:///tmp/article", "https://user@example.com/article",
    "https://user:password@example.com/article"
  ])
  func unsafeArticleURL(url: String) throws {
    var data = payload()
    data["uri"] = url
    #expect(StandardSiteCard(try view(data)) == nil)
  }

  @Test("Unsafe publication and image URLs are not exposed by the card")
  func unsafeAuxiliaryURLs() throws {
    var data = payload(publication: true, source: true)
    data["source"] = ["uri": "javascript:alert(1)", "title": "Publication", "icon": "file:///tmp/icon.png"]
    data["thumb"] = "https://user:password@example.com/image.jpg"
    let article = try card(data)
    #expect(article.publicationURL == nil)
    #expect(article.iconURL == nil)
    #expect(article.thumbnailURL == nil)
    data["associatedRefs"] = [reference("site.standard.publication", owner: publicationOwner)]
    #expect(StandardSiteCard(try view(data)) == nil)
  }

  @Test("Recognized publishers require exact or dot-delimited subdomains")
  func publishersAndLookalikes() throws {
    for (host, expected) in [
      ("leaflet.pub", "Leaflet"), ("writer.leaflet.pub", "Leaflet"),
      ("pckt.blog", "pckt"), ("writer.offprint.app", "Offprint")
    ] {
      var data = payload(publication: true, source: true)
      data["source"] = ["uri": "https://\(host)", "title": "Publication"]
      #expect(try card(data).publisher == expected)
      #expect(try card(data).displayDomain == nil)
    }
    for host in ["evilleaflet.pub", "leaflet.pub.example.com", "notpckt.blog", "offprint.app.example.com"] {
      var data = payload(publication: true, source: true)
      data["source"] = ["uri": "https://\(host)", "title": "Publication"]
      #expect(try card(data).publisher == nil)
    }
  }

  @Test("Only complete, valid high-contrast publisher colors are used")
  func publisherColors() throws {
    let black = ["r": 0, "g": 0, "b": 0]
    let white = ["r": 255, "g": 255, "b": 255]
    for (theme, expected) in [
      (["accentRGB": black, "accentForegroundRGB": white], true),
      (["accentRGB": white, "accentForegroundRGB": white], false),
      (["accentRGB": ["r": 256, "g": 0, "b": 0], "accentForegroundRGB": white], false),
      (["accentRGB": ["r": -1, "g": 0, "b": 0], "accentForegroundRGB": white], false),
      (["accentRGB": black], false)
    ] {
      var data = payload(publication: true, source: true)
      data["source"] = ["uri": "https://example.com", "title": "Publication", "theme": theme]
      #expect((try card(data).buttonColors != nil) == expected)
    }
  }

  @Test("Reading time is positive minutes with no unit conversion", arguments: [-1, 0, 1, 7, 120])
  func readingMinutes(minutes: Int) throws {
    var data = payload()
    data["readingTime"] = minutes
    #expect(try card(data).readingMinutes == (minutes > 0 ? minutes : nil))
  }

  @Test("Hydrated moderation labels remain attached to presentation data")
  func labelsPreserved() throws {
    var data = payload()
    data["labels"] = [[
      "src": articleOwner, "uri": "https://example.com/article", "val": "nudity",
      "cts": "2026-01-01T12:00:00Z"
    ]]
    let external = try view(data)
    let presentation = try #require(StandardSiteCard(external))
    #expect(presentation.external.labels == external.labels)
    #expect(presentation.external.labels?.first?.val == "nudity")
  }

  private func label(
    _ value: String, negated: Bool? = nil, expiresAt: String? = nil
  ) throws -> ComAtprotoLabelDefs.Label {
    var data: [String: Any] = [
      "src": articleOwner, "uri": "https://example.com/article", "val": value,
      "cts": "2025-12-01T12:00:00Z"
    ]
    if let negated { data["neg"] = negated }
    if let expiresAt { data["exp"] = expiresAt }
    return try JSONDecoder().decode(
      ComAtprotoLabelDefs.Label.self, from: JSONSerialization.data(withJSONObject: data)
    )
  }

  @Test("Active system hide labels dominate warnings regardless of order")
  func activeSystemLabels() throws {
    let hidden = try label("!hide")
    let warned = try label("!warn", negated: false)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([warned]) == .warn)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([hidden]) == .hide)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([warned, hidden]) == .hide)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([hidden, warned]) == .hide)
  }

  @Test("Negated and expired system labels do not block previews")
  func inactiveSystemLabels() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
    let negatedHide = try label("!hide", negated: true)
    let negatedWarn = try label("!warn", negated: true)
    let expiredHide = try label("!hide", expiresAt: "2025-12-31T12:00:00Z")
    let expiresNow = try label("!warn", expiresAt: "2026-01-01T12:00:00Z")
    let activeWarn = try label("!warn", expiresAt: "2026-01-02T12:00:00Z")
    let activeHide = try label("!hide", expiresAt: "2026-01-02T12:00:00Z")
    let inactive = [negatedHide, negatedWarn, expiredHide, expiresNow]
    #expect(ExternalEmbedSystemLabelVisibility.resolve(inactive, at: now) == .show)
    #expect(ExternalEmbedSystemLabelVisibility.resolve(inactive + [activeWarn], at: now) == .warn)
    #expect(ExternalEmbedSystemLabelVisibility.resolve(inactive + [activeWarn, activeHide], at: now) == .hide)
  }

  @Test("Absent and ordinary labels defer to the existing content-label policy")
  func noSystemLabels() throws {
    #expect(ExternalEmbedSystemLabelVisibility.resolve(nil) == .show)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([]) == .show)
    #expect(ExternalEmbedSystemLabelVisibility.resolve([try label("nudity"), try label("custom-warning")]) == .show)
  }
}
