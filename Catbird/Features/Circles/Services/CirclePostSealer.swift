import CatbirdMLSCore
import Foundation
import ImageIO
import OSLog
import Petrel
import PetrelCatbird
import UniformTypeIdentifiers

/// One encrypted media blob of an encrypted Circle post (spec §4.3).
///
/// `blob` is the uploaded CIPHERTEXT (`application/octet-stream`); it goes into
/// the envelope's plaintext `attachments` manifest. `key`, `iv`, `sha256`,
/// `mimeType` (of the plaintext), `alt` and the dimensions travel only inside
/// the sealed payload. `key` is raw key material: never log it.
struct CircleEncryptedMedia: Sendable {
  let blob: Blob
  let key: Data
  let iv: Data
  let sha256: String
  let mimeType: String
  let alt: String?
  let width: Int?
  let height: Int?
}

/// Encrypts one prepared JPEG for an encrypted Circle and uploads the
/// ciphertext. Identifying metadata is removed from the PLAINTEXT first: the
/// upload is opaque `application/octet-stream`, so nothing downstream can strip
/// it, and every member who opens the post would otherwise see it.
enum CircleMediaSealer {
  static let ciphertextMimeType = "application/octet-stream"
  static let plaintextMimeType = "image/jpeg"

  static func encryptAndUpload(
    jpeg: Data,
    alt: String?,
    width: Int?,
    height: Int?,
    upload: (_ ciphertext: Data, _ mimeType: String) async throws -> Blob
  ) async throws -> CircleEncryptedMedia {
    let clean = try withoutIdentifyingMetadata(jpeg)
    let sealed = try BlobCrypto.encrypt(plaintext: clean)
    let blob = try await upload(sealed.ciphertext, ciphertextMimeType)
    return CircleEncryptedMedia(
      blob: blob,
      key: sealed.key,
      iv: sealed.iv,
      sha256: sealed.sha256,
      mimeType: plaintextMimeType,
      alt: alt,
      width: width,
      height: height
    )
  }

  /// Returns `jpeg` unchanged when it carries no identifying metadata (the
  /// composer's prepared uploads are fresh ImageIO encodes, so the normal path
  /// costs nothing). Otherwise re-encodes the pixels, orientation applied, with
  /// no metadata at all, and verifies the result. Fails closed.
  static func withoutIdentifyingMetadata(_ jpeg: Data) throws -> Data {
    let failure = CircleError.invalidParameter("An attachment couldn’t be prepared. Retry it or remove it before posting.")
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { throw failure }
    guard hasIdentifyingMetadata(source) else { return jpeg }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension(source),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw failure
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { throw failure }
    let clean = output as Data
    guard let check = CGImageSourceCreateWithData(clean as CFData, nil), !hasIdentifyingMetadata(check) else {
      throw failure
    }
    return clean
  }

  private static func hasIdentifyingMetadata(_ source: CGImageSource) -> Bool {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return true
    }
    if properties[kCGImagePropertyGPSDictionary] != nil
      || properties[kCGImagePropertyIPTCDictionary] != nil
      || properties[kCGImagePropertyMakerAppleDictionary] != nil {
      return true
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
       || tiff[kCGImagePropertyTIFFDateTime] != nil || tiff[kCGImagePropertyTIFFSoftware] != nil {
      return true
    }
    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
      let identifying: [CFString] = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake, kCGImagePropertyExifCameraOwnerName,
        kCGImagePropertyExifUserComment,
      ]
      if identifying.contains(where: { exif[$0] != nil }) { return true }
    }
    return false
  }

  private static func maxPixelDimension(_ source: CGImageSource) -> Int {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    return max(width, height, 1)
  }
}

/// Seals a Circle post for an encrypted Circle (spec §4.2, §4.5; D13).
///
/// - The key is `CircleKeyManager.keyForPosting`: every key record is
///   refreshed first and the post is refused (`encryptionUnavailable`) when the
///   server, or the summary's `latestKeyVersion`, knows a newer version than
///   this device holds. No key → `encryptionUnavailable`. There is no plaintext
///   fallback anywhere on this path.
/// - `postURI` must be the canonical STANDARD form
///   `at://<author-did>/blue.catbird.circle.post/<tid>`; it is bound into the
///   AAD, so the caller writes the record at exactly that rkey.
/// - The inner payload matches `catbird-mls` `CirclePostPayload` exactly:
///   serde with no `rename_all`, so the keys are `post`, `media`, `created_at`
///   and each media entry is `cid, key, iv, sha256, mime_type, alt?, width?,
///   height?` with `key`/`iv` as JSON integer arrays (serde's `Vec<u8>`).
/// - The `createdAt` string is produced once, by the same formatter the FFI
///   uses for the header (`ATProtocolDate(date:).iso8601String`); the payload
///   and the inner post carry that string, and the returned envelope is checked
///   to carry it too.
/// - The envelope's cleartext is limited to the FFI-built header; this type
///   supplies only blob refs as `attachments` and the reply ref.
///
/// Plaintext and keys are never logged.
actor CirclePostSealer {
  static let maxAttachments = 4
  static let postCollection = "blue.catbird.circle.post"
  /// Every key a sealed envelope may carry in cleartext.
  static let envelopeKeys: Set<String> = [
    "$type", "circleId", "keyVersion", "createdAt", "reply", "ciphertext", "sig", "authorEpochHead", "attachments"
  ]

  private let logger = Logger(subsystem: "blue.catbird", category: "CirclePostSealer")
  private let crypto: any CircleCrypto
  private let keys: CircleKeyManager

  init(crypto: any CircleCrypto, keys: CircleKeyManager) {
    self.crypto = crypto
    self.keys = keys
  }

  /// The canonical post URI for `rkey` (never the space form).
  static func canonicalPostURI(authorDID: DID, rkey: String) throws -> ATProtocolURI {
    try ATProtocolURI(uriString: "at://\(authorDID.didString())/\(postCollection)/\(rkey)")
  }

  func seal(
    draft: CirclePostDraft,
    media: [CircleEncryptedMedia],
    circle: CircleSummary,
    authorDID: DID,
    postURI: ATProtocolURI
  ) async throws -> (recordJSON: String, attachments: [Blob]) {
    guard circle.isEncrypted else {
      throw CircleError.invalidParameter("This Circle is not encrypted.")
    }
    guard draft.embed == nil else {
      throw CircleError.invalidParameter("Link cards, quotes and GIFs are unavailable in encrypted Circles.")
    }
    guard media.count <= Self.maxAttachments else {
      throw CircleError.invalidParameter("Encrypted Circles allow up to \(Self.maxAttachments) images per post.")
    }
    try Self.requireCanonical(postURI: postURI, authorDID: authorDID)

    let current = try await keys.keyForPosting(circle: circle)
    if let summaryLatest = circle.latestKeyVersion, summaryLatest > 0, UInt64(summaryLatest) > current.version {
      throw CircleError.encryptionUnavailable
    }

    let createdAtDate = draft.createdAt.date
    let createdAt = ATProtocolDate(date: createdAtDate).iso8601String
    let payloadJSON = try Self.payloadJSON(draft: draft, media: media, createdAt: createdAtDate)
    let replyJSON = try draft.reply.map { try Self.jsonString($0) }
    let attachmentsJSON = try media.map { try Self.jsonString($0.blob) }

    let recordJSON: String
    do {
      recordJSON = try await crypto.sealPost(
        circleID: circle.circleId.description,
        keyVersion: current.version,
        circleKey: current.key,
        postURI: postURI.uriString(),
        authorDID: authorDID.didString(),
        createdAt: createdAtDate,
        payloadJSON: payloadJSON,
        replyJSON: replyJSON,
        attachmentsJSON: attachmentsJSON
      )
    } catch {
      // The error type only: FFI messages are not guaranteed free of input fragments.
      logger.error("Circles: sealing a post failed (\(String(describing: type(of: error)), privacy: .public))")
      throw CircleError.encryptionUnavailable
    }
    try Self.verifyEnvelope(
      recordJSON, createdAt: createdAt, keyVersion: current.version, attachmentCount: media.count
    )
    return (recordJSON: recordJSON, attachments: media.map(\.blob))
  }

  // MARK: - Payload

  /// `{ "post": <app.bsky.feed.post without blob refs>, "media": [...], "created_at": <header string> }`.
  static func payloadJSON(draft: CirclePostDraft, media: [CircleEncryptedMedia], createdAt: Date) throws -> String {
    let post = AppBskyFeedPost(
      text: draft.text,
      entities: nil,
      facets: draft.facets,
      reply: draft.reply,
      embed: nil,
      langs: draft.langs,
      labels: draft.labels,
      tags: nil,
      createdAt: ATProtocolDate(date: createdAt)
    )
    let postObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(post))
    let createdAtString = ATProtocolDate(date: createdAt).iso8601String
    guard
      let postDictionary = postObject as? [String: Any],
      postDictionary["createdAt"] as? String == createdAtString
    else {
      throw CircleError.encryptionUnavailable
    }

    var mediaEntries: [[String: Any]] = []
    for item in media {
      guard let cid = item.blob.ref?.cid.string ?? item.blob.cid else {
        throw CircleError.invalidParameter("An encrypted attachment is missing its upload reference.")
      }
      var entry: [String: Any] = [
        "cid": cid,
        "key": item.key.map { Int($0) },
        "iv": item.iv.map { Int($0) },
        "sha256": item.sha256,
        "mime_type": item.mimeType
      ]
      if let alt = item.alt { entry["alt"] = alt }
      if let width = item.width, width > 0 { entry["width"] = width }
      if let height = item.height, height > 0 { entry["height"] = height }
      mediaEntries.append(entry)
    }

    let payload: [String: Any] = [
      "post": postDictionary,
      "media": mediaEntries,
      "created_at": createdAtString
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - Checks

  private static func requireCanonical(postURI: ATProtocolURI, authorDID: DID) throws {
    let prefix = "at://\(authorDID.didString())/\(postCollection)/"
    let uri = postURI.uriString()
    guard uri.hasPrefix(prefix), (try? TID(tidString: String(uri.dropFirst(prefix.count)))) != nil else {
      throw CircleError.invalidParameter("Encrypted Circle posts need a canonical post URI.")
    }
  }

  /// The FFI built the header; refuse an envelope that drifted from what was
  /// asked for (wrong `createdAt` or version, extra cleartext, lost blobs).
  private static func verifyEnvelope(
    _ recordJSON: String, createdAt: String, keyVersion: UInt64, attachmentCount: Int
  ) throws {
    guard
      let record = try? JSONSerialization.jsonObject(with: Data(recordJSON.utf8)) as? [String: Any],
      record["$type"] as? String == postCollection,
      record["createdAt"] as? String == createdAt,
      (record["keyVersion"] as? NSNumber)?.uint64Value == keyVersion,
      Set(record.keys).isSubset(of: envelopeKeys),
      ((record["attachments"] as? [Any])?.count ?? 0) == attachmentCount
    else {
      throw CircleError.encryptionUnavailable
    }
  }

  private static func jsonString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
  }
}
