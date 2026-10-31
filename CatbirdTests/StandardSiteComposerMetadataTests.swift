import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Standard site composer metadata")
@MainActor
struct StandardSiteComposerMetadataTests {
  private let articleURL = "https://example.com/article"
  private let originalURL = "https://example.com/article?ref=shared#section"
  private let ownerDID = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  private var recordRef: [String: Any] {
    [
      "uri": "at://\(ownerDID)/site.standard.document/article",
      "cid": CID.fromDAGCBOR(Data("standard site article".utf8)).string
    ]
  }

  private var legacyPayload: [String: Any] {
    [
      "error": "", "likely_type": "text/html", "url": articleURL,
      "title": "Open Graph title", "description": "Open Graph description",
      "image": "https://example.com/open-graph.jpg"
    ]
  }

  private var hydratedView: [String: Any] {
    [
      "external": [
        "uri": articleURL, "title": "Hydrated article", "description": "Hydrated description",
        "thumb": "https://example.com/hydrated.jpg",
        "createdAt": "2026-01-01T12:00:00Z", "updatedAt": "2026-01-02T12:00:00Z",
        "readingTime": 7, "associatedRefs": [recordRef],
        "associatedProfiles": [["did": ownerDID, "handle": "author.example.com"]],
        "labels": [[
          "src": ownerDID, "uri": articleURL, "val": "nudity", "cts": "2026-01-01T12:00:00Z"
        ]],
        "source": [
          "uri": "https://example.com", "title": "Example publication",
          "description": "Publication description", "icon": "https://example.com/icon.jpg",
          "theme": ["backgroundRGB": ["r": 12, "g": 34, "b": 56]]
        ]
      ]
    ]
  }

  private func decode(_ payload: [String: Any]) throws -> URLCardResponse {
    try JSONDecoder().decode(URLCardResponse.self, from: JSONSerialization.data(withJSONObject: payload))
  }

  private func enhancedCard() throws -> URLCardResponse {
    var payload = legacyPayload
    payload["associated_refs"] = [recordRef]
    payload["view"] = hydratedView
    return try decode(payload)
  }

  @Test("Legacy cards still decode and use the ordinary preview")
  func legacyCard() throws {
    let card = try decode(legacyPayload)
    #expect(card.associatedRefs == nil)
    #expect(card.externalView == nil)
    #expect(card.toViewExternal().title == "Open Graph title")
    #expect(card.toViewExternal().uri.uriString() == articleURL)
  }

  @Test("Both metadata view keys carry typed strong refs", arguments: ["view", "external_view"])
  func metadataAliases(key: String) throws {
    var payload = legacyPayload
    payload["associated_refs"] = [recordRef]
    payload[key] = hydratedView
    let card = try decode(payload)
    #expect(card.associatedRefs?.first?.uri.uriString() == recordRef["uri"] as? String)
    #expect(card.associatedRefs?.first?.cid.string == recordRef["cid"] as? String)
    #expect(card.externalView?.external.title == "Hydrated article")
  }

  @Test("Malformed enhanced metadata keeps the legacy card usable")
  func malformedMetadata() throws {
    var payload = legacyPayload
    payload["associated_refs"] = [["uri": "missing CID"]]
    payload["view"] = ["external": "invalid"]
    payload["external_view"] = false
    let card = try decode(payload)
    #expect(card.title == "Open Graph title")
    #expect(card.associatedRefs == nil)
    #expect(card.externalView == nil)

    payload["external_view"] = hydratedView
    #expect(try decode(payload).externalView?.external.title == "Hydrated article")
  }

  @Test("Preview preserves original link, moderation labels and publication metadata")
  func previewMetadata() throws {
    var card = try enhancedCard()
    card.sourceURL = originalURL
    let preview = card.toViewExternal()
    let hydrated = try #require(card.externalView?.external)
    #expect(preview.uri.uriString() == originalURL)
    #expect(preview.title == hydrated.title)
    #expect(preview.description == hydrated.description)
    #expect(preview.thumb?.uriString() == "https://example.com/open-graph.jpg")
    #expect(preview.createdAt == hydrated.createdAt)
    #expect(preview.updatedAt == hydrated.updatedAt)
    #expect(preview.readingTime == 7)
    #expect(preview.labels == hydrated.labels)
    #expect(preview.labels?.first?.val == "nudity")
    #expect(preview.source == hydrated.source)
    #expect(preview.associatedRefs == card.associatedRefs)
    #expect(preview.associatedProfiles == hydrated.associatedProfiles)
  }

  @Test("A missing Open Graph image uses the hydrated thumbnail")
  func hydratedThumbnailFallback() throws {
    var payload = legacyPayload
    payload["image"] = ""
    payload["view"] = hydratedView
    #expect(try decode(payload).toViewExternal().thumb?.uriString() == "https://example.com/hydrated.jpg")
  }

  @Test("Empty hydrated text falls back to Open Graph text and then the original URL")
  func emptyTextFallbacks() throws {
    var payload = legacyPayload
    payload["view"] = ["external": ["uri": articleURL, "title": "", "description": ""]]
    #expect(try decode(payload).toViewExternal().title == "Open Graph title")
    #expect(try decode(payload).toViewExternal().description == "Open Graph description")
    payload["title"] = ""
    var card = try decode(payload)
    card.sourceURL = originalURL
    #expect(card.toViewExternal().title == originalURL)
  }

  @Test("Card coding preserves metadata and emits the canonical wire keys")
  func cardRoundTrip() throws {
    let card = try enhancedCard()
    let data = try JSONEncoder().encode(card)
    let restored = try JSONDecoder().decode(URLCardResponse.self, from: data)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(restored.associatedRefs == card.associatedRefs)
    #expect(restored.externalView == card.externalView)
    #expect(json["associated_refs"] != nil)
    #expect(json["view"] != nil)
    #expect(json["external_view"] == nil)
  }

  @Test("Both draft card formats preserve metadata")
  func draftRoundTrips() throws {
    var card = try enhancedCard()
    card.sourceURL = originalURL
    let saved = LinkStatePersistence.CodableURLCard(from: card)
    let data = try JSONEncoder().encode(saved)
    let restored = try JSONDecoder().decode(LinkStatePersistence.CodableURLCard.self, from: data).toURLCard()
    #expect(restored.resolvedURL == originalURL)
    #expect(restored.associatedRefs == card.associatedRefs)
    #expect(restored.externalView == card.externalView)

    var entry = ThreadEntry()
    entry.urlCards = [originalURL: card]
    let threadData = try JSONEncoder().encode(CodableThreadEntry(from: entry, parentPost: nil, quotedPost: nil))
    let restoredEntry = try JSONDecoder().decode(CodableThreadEntry.self, from: threadData).toThreadEntry()
    #expect(restoredEntry.urlCards[originalURL]?.associatedRefs == card.associatedRefs)
    #expect(restoredEntry.urlCards[originalURL]?.externalView == card.externalView)
  }

  @Test("Older and malformed enhanced draft cards retain their ordinary fields")
  func legacyDraftCards() throws {
    var payload: [String: Any] = [
      "url": articleURL, "sourceURL": originalURL, "title": "Saved card",
      "description": "Saved description", "image": ""
    ]
    for malformed in [false, true] {
      if malformed {
        payload["associatedRefs"] = "invalid"
        payload["externalView"] = ["external": false]
      }
      let data = try JSONSerialization.data(withJSONObject: payload)
      let card = try JSONDecoder().decode(LinkStatePersistence.CodableURLCard.self, from: data).toURLCard()
      #expect(card.title == "Saved card")
      #expect(card.resolvedURL == originalURL)
      #expect(card.associatedRefs == nil)
      #expect(card.externalView == nil)
    }
  }
}
