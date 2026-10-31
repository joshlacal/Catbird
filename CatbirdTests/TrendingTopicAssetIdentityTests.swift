import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Trending topic exact media assets")
@MainActor
struct TrendingTopicAssetIdentityTests {
  @Test("Identical image blobs at different URLs leave fewer real cards")
  func originalBlobDuplicates() throws {
    let first = try post(1, view: imageView("first"), raw: imageRecord(1))
    let second = try post(2, view: imageView("second"), raw: imageRecord(1))
    let third = try post(3, view: imageView("third"), raw: imageRecord(1))
    let preview = TrendingTopicPreviewPolicy.select([first, second, third], context: .init())
    #expect(preview.media.count == 1)
    #expect(preview.media.first?.id == first.post.uri.uriString())
    #expect(preview.media.first?.url.absoluteString == "https://images.example.test/first.jpg?quality=80#card")
    let distinct = try post(4, view: imageView("distinct"), raw: imageRecord(2))
    let mixed = TrendingTopicPreviewPolicy.select([first, second, third, distinct], context: .init())
    #expect(mixed.media.count == 2)
    #expect(mixed == TrendingTopicPreviewPolicy.select([first, second, third, distinct], context: .init()))
  }

  @Test("A shared post-record CID never collapses distinct image blobs; blocked posts reserve nothing")
  func recordCIDAndModerationStaySeparate() throws {
    let blocked = try post(0, view: imageView("blocked"), raw: imageRecord(1), warning: true)
    let posts = try (1...3).map { try post($0, view: imageView("image-\($0)"), raw: imageRecord(UInt8($0))) }
    #expect(Set(posts.map { $0.post.cid }).count == 1)
    let preview = TrendingTopicPreviewPolicy.select([blocked] + posts, context: .init())
    #expect(Set(preview.media.map(\.id)) == Set(posts.map { $0.post.uri.uriString() }))
  }

  @Test("The first HTTPS image uses the blob at its own index")
  func selectedImageIndex() throws {
    let views: [String: Any] = ["$type": "app.bsky.embed.images#view", "images": [
      image("http://images.example.test/invalid.jpg"), image("https://images.example.test/chosen.jpg")
    ]]
    let records: [String: Any] = ["$type": "app.bsky.embed.images", "images": [
      ["image": blob(2), "alt": "Scene"], ["image": blob(1), "alt": "Scene"]
    ]]
    let selected = try post(1, view: views, raw: records)
    let duplicate = try post(2, view: imageView("duplicate"), raw: imageRecord(1))
    #expect(TrendingTopicPreviewPolicy.select([selected, duplicate], context: .init()).media.count == 1)
    var mismatched = records
    mismatched["images"] = [["image": blob(1), "alt": "Scene"]]
    let unmatched = try post(3, view: views, raw: mismatched)
    #expect(TrendingTopicPreviewPolicy.select([unmatched, duplicate], context: .init()).media.count == 2)
  }

  @Test("Link-card and gallery thumbnails use their original image blob", arguments: ["external", "gallery"])
  func otherImageEmbeds(kind: String) throws {
    let first = try post(1, view: imageView("image"), raw: imageRecord(1))
    let view: [String: Any]
    let raw: [String: Any]
    if kind == "external" {
      view = ["$type": "app.bsky.embed.external#view", "external": ["uri": "https://example.test/article", "title": "Article", "description": "Story", "thumb": "https://images.example.test/link.jpg"]]
      raw = ["$type": "app.bsky.embed.external", "external": ["uri": "https://example.test/article", "title": "Article", "description": "Story", "thumb": blob(1)]]
    } else {
      view = ["$type": "app.bsky.embed.gallery#view", "items": [["$type": "app.bsky.embed.gallery#viewImage", "thumbnail": "https://images.example.test/gallery.jpg", "fullsize": "https://images.example.test/gallery-original.jpg", "alt": "Scene", "aspectRatio": ["width": 1, "height": 1]]]]
      raw = ["$type": "app.bsky.embed.gallery", "items": [["$type": "app.bsky.embed.gallery#image", "image": blob(1), "alt": "Scene", "aspectRatio": ["width": 1, "height": 1]]]]
    }
    let duplicate = try post(2, view: view, raw: raw)
    #expect(TrendingTopicPreviewPolicy.select([first, duplicate], context: .init()).media.count == 1)
  }

  @Test("Video view CIDs identify video blobs even when poster URLs differ")
  func videoBlobIdentity() throws {
    func video(_ name: String, cid: UInt8) -> [String: Any] {
      ["$type": "app.bsky.embed.video#view", "cid": assetCID(cid).string,
       "playlist": "https://video.example.test/\(name)/playlist.m3u8",
       "thumbnail": "https://video.example.test/\(name)/thumbnail.jpg"]
    }
    let first = try post(1, view: video("first", cid: 1))
    let duplicate = try post(2, view: video("second", cid: 1))
    let distinct = try post(3, view: video("third", cid: 2))
    let preview = TrendingTopicPreviewPolicy.select([first, duplicate, distinct], context: .init())
    #expect(Set(preview.media.map(\.id)) == Set([first.post.uri.uriString(), distinct.post.uri.uriString()]))
    #expect(preview.media.allSatisfy { $0.url.lastPathComponent == "thumbnail.jpg" })
  }

  @Test("Quotes use their own blob and record-with-media uses its own attached blob", arguments: [false, true])
  func quoteAndAttachedMedia(ownMedia: Bool) throws {
    let quoted = try post(7, view: imageView("quoted"), raw: imageRecord(ownMedia ? 2 : 1))
    let quotedJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(quoted.post)) as? [String: Any])
    let quote: [String: Any] = ["$type": "app.bsky.embed.record#view", "record": [
      "$type": "app.bsky.embed.record#viewRecord", "uri": quoted.post.uri.uriString(), "cid": quoted.post.cid.string,
      "author": try #require(quotedJSON["author"]), "value": try #require(quotedJSON["record"]),
      "indexedAt": timestamp, "embeds": [try #require(quotedJSON["embed"])]
    ]]
    let strongRef: [String: Any] = ["$type": "app.bsky.embed.record", "record": ["uri": quoted.post.uri.uriString(), "cid": quoted.post.cid.string]]
    let view = ownMedia ? ["$type": "app.bsky.embed.recordWithMedia#view", "record": quote, "media": imageView("own-media")] : quote
    let raw = ownMedia ? ["$type": "app.bsky.embed.recordWithMedia", "record": strongRef, "media": imageRecord(1)] : strongRef
    let wrapper = try post(1, view: view, raw: raw)
    let duplicate = try post(2, view: imageView("direct"), raw: imageRecord(1))
    let context = TrendingTopicPreviewPolicy.Context(quotedPosts: [quoted.post.uri.uriString(): quoted.post])
    #expect(TrendingTopicPreviewPolicy.select([wrapper, duplicate], context: context).media.count == 1)
  }

  @Test("Known CDN presets, formats and repository paths share the original blob identity")
  func knownCDNVariants() throws {
    let cid = assetCID(1).string
    let urls = [
      "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)@jpeg?quality=80#card",
      "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:zyxwvutsrqponmlkjihgfedc/\(cid)@jxl?quality=90#full",
      "https://cdn.bsky.social/img/feed_thumbnail/plain/did%3Aplc%3Aabcdefghijklmnopqrstuvwx/\(cid)@png"
    ]
    let posts = try urls.enumerated().map { try post($0.offset + 1, view: imageView(url: $0.element)) }
    let preview = TrendingTopicPreviewPolicy.select(posts, context: .init())
    #expect(preview.media.count == 1)
    #expect(preview.media.first?.url.absoluteString == urls[0])
  }

  @Test("Unknown or malformed routes use exact URL identity", arguments: ["unknown-host", "lookalike-host", "unknown-preset", "malformed-cid", "query"])
  func unknownURLFallback(kind: String) throws {
    let cid = assetCID(1).string
    let base: String
    switch kind {
    case "unknown-host": base = "https://images.example.test/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)"
    case "lookalike-host": base = "https://cdn.bsky.app.example.test/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)"
    case "unknown-preset": base = "https://cdn.bsky.app/img/arbitrary/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)"
    case "malformed-cid": base = "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/invalid-cid"
    default: base = "https://images.example.test/picture"
    }
    let first = try post(1, view: imageView(url: base + "@jpeg?revision=1"))
    let second = try post(2, view: imageView(url: base + "@png?revision=2"))
    let repeated = try post(3, view: imageView(url: base + "@jpeg?revision=1"))
    #expect(TrendingTopicPreviewPolicy.select([first, second, repeated], context: .init()).media.count == 2)
  }

  @Test("CDN identity validates original credentials and ports in thumbnail and fullsize metadata",
    arguments: ["thumbnail-user", "thumbnail-port", "fullsize-user", "fullsize-port"])
  func unsafeCDNMetadataUsesURLFallback(kind: String) throws {
    let cid = assetCID(1).string
    let path = "/img/feed_fullsize/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)@png?revision=2"
    let authority = kind.hasSuffix("-user") ? "user@cdn.bsky.app" : "cdn.bsky.app:8443"
    let unsafe = "https://\(authority)\(path)"
    let first = try post(1, view: imageView(url:
      "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/\(cid)@jpeg"))
    var fields = image("https://images.example.test/opaque-\(kind).jpg")
    fields["fullsize"] = unsafe
    if kind.hasPrefix("thumbnail") { fields["thumb"] = unsafe }
    let second = try post(2, view: ["$type": "app.bsky.embed.images#view", "images": [fields]])
    let preview = TrendingTopicPreviewPolicy.select([first, second], context: .init())
    #expect(preview.media.count == 2)
    #expect(Set(preview.media.map(\.id)) == Set([first.post.uri.uriString(), second.post.uri.uriString()]))
  }

  @Test("Typed legacy blobs use parsed CIDs; invalid legacy CIDs use exact URLs")
  func legacyBlobReferences() throws {
    let modern = try post(1, view: imageView("modern"), raw: imageRecord(1))
    func typedLegacy(_ index: Int, cid: String) throws -> AppBskyFeedDefs.FeedViewPost {
      let item = try post(index, view: imageView("legacy-\(index)"))
      let blob = Blob(type: "blob", mimeType: "image/jpeg", size: 0, cid: cid)
      let record = AppBskyFeedPost(text: "Topic",
        embed: .appBskyEmbedImages(.init(images: [.init(image: blob, alt: "Scene")])),
        createdAt: item.post.indexedAt)
      return .init(post: .init(uri: item.post.uri, cid: item.post.cid, author: item.post.author,
        record: .knownType(record), embed: item.post.embed, indexedAt: item.post.indexedAt))
    }
    let old = try typedLegacy(2, cid: assetCID(1).string)
    #expect(TrendingTopicPreviewPolicy.permits(old, context: .init()))
    #expect(TrendingTopicPreviewPolicy.select([old], context: .init()).media.count == 1)
    #expect(TrendingTopicPreviewPolicy.select([modern, old], context: .init()).media.count == 1)
    let fallback = try typedLegacy(3, cid: "invalid")
    #expect(TrendingTopicPreviewPolicy.permits(fallback, context: .init()))
    #expect(TrendingTopicPreviewPolicy.select([modern, fallback], context: .init()).media.count == 2)
  }

  @Test("Lossless decoding keeps legacy wire records unknown and preview guards exclude them", arguments: [false, true])
  func legacyWireRecordGuard(invalid: Bool) throws {
    let modern = try post(1, view: imageView("modern"), raw: imageRecord(1))
    let raw: [String: Any] = ["$type": "app.bsky.embed.images", "images": [[
      "image": ["cid": invalid ? "invalid" : assetCID(1).string, "mimeType": "image/jpeg"], "alt": "Scene"
    ]]]
    let legacy = try post(2, view: imageView("legacy"), raw: raw)
    guard case .unknownType = legacy.post.record else {
      Issue.record("Expected the existing lossless decoder to preserve this legacy wire record as unknown")
      return
    }
    #expect(!TrendingTopicPreviewPolicy.permits(legacy, context: .init()))
    let preview = TrendingTopicPreviewPolicy.select([modern, legacy], context: .init())
    #expect(preview.media.map(\.id) == [modern.post.uri.uriString()])
  }

  private let timestamp = "2026-01-01T00:00:00Z"

  private func assetCID(_ value: UInt8) -> CID {
    CID(codec: .raw, multihash: Multihash(algorithm: 0x12, length: 32, digest: Data(repeating: value, count: 32)))
  }

  private func blob(_ value: UInt8) -> [String: Any] {
    ["$type": "blob", "ref": ["$link": assetCID(value).string], "mimeType": "image/jpeg", "size": 100]
  }

  private func imageRecord(_ value: UInt8) -> [String: Any] {
    ["$type": "app.bsky.embed.images", "images": [["image": blob(value), "alt": "Scene"]]]
  }

  private func image(_ url: String) -> [String: Any] {
    ["thumb": url, "fullsize": url, "alt": "Scene"]
  }

  private func imageView(_ name: String) -> [String: Any] {
    imageView(url: "https://images.example.test/\(name).jpg?quality=80#card")
  }

  private func imageView(url: String) -> [String: Any] {
    ["$type": "app.bsky.embed.images#view", "images": [image(url)]]
  }

  private func post(_ index: Int, view: [String: Any], raw: [String: Any]? = nil, warning: Bool = false) throws -> AppBskyFeedDefs.FeedViewPost {
    let did = "did:plc:assetfixture\(index)"
    let uri = "at://\(did)/app.bsky.feed.post/one"
    var record: [String: Any] = ["$type": "app.bsky.feed.post", "text": "Topic", "createdAt": timestamp]
    if let raw { record["embed"] = raw }
    let labels: [[String: Any]] = warning ? [["src": "did:plc:assetlabeler", "uri": uri, "val": "porn", "cts": timestamp]] : []
    let post: [String: Any] = ["$type": "app.bsky.feed.defs#postView", "uri": uri, "cid": assetCID(99).string,
      "author": ["did": did, "handle": "author\(index).test"], "record": record, "indexedAt": timestamp, "embed": view, "labels": labels]
    return try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: ["post": post]))
  }
}
