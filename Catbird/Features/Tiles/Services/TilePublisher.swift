import CryptoKit
import Foundation
import OSLog
import Petrel

// MARK: - TilePublisher

/// Publishes DASL Web Tiles to the AT Protocol
/// Handles: uploading resources as blobs, creating manifest, writing record
actor TilePublisher {
  private let logger = Logger(subsystem: "blue.catbird", category: "TilePublisher")

  struct PublishResult: Sendable {
    let uri: String
    let cid: String
    let tileCID: String
  }

  /// Publish a tile from a local directory
  /// - Parameters:
  ///   - directory: Local directory containing tile files (must include index.html and manifest.json)
  ///   - client: Authenticated AT Protocol client
  ///   - userDID: The publishing user's DID
  /// - Returns: The published tile's AT URI and CID
  func publish(
    directory: URL,
    client: ATProtoClient,
    userDID: String
  ) async throws -> PublishResult {
    // 1. Read and parse manifest.json
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw TilePublishError.missingManifest
    }

    let manifestData = try Data(contentsOf: manifestURL)
    let partialManifest = try JSONDecoder().decode(PartialManifest.self, from: manifestData)

    // 2. Discover all files in the directory
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      throw TilePublishError.cannotReadDirectory
    }

    var filePaths: [(relativePath: String, url: URL)] = []
    while let fileURL = enumerator.nextObject() as? URL {
      let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard resourceValues.isRegularFile == true else { continue }
      // Skip manifest.json itself
      if fileURL.lastPathComponent == "manifest.json" { continue }

      let relativePath = "/" + fileURL.path.replacingOccurrences(
        of: directory.path + "/",
        with: ""
      )
      filePaths.append((relativePath, fileURL))
    }

    // Ensure root document exists
    let hasRoot = filePaths.contains { $0.relativePath == "/index.html" }
    guard hasRoot else {
      throw TilePublishError.missingRootDocument
    }

    // 3. Upload all files as blobs
    logger.info("Uploading \(filePaths.count) resources for tile: \(partialManifest.name)")

    var resources: [String: TileResource] = [:]

    for (relativePath, fileURL) in filePaths {
      let data = try Data(contentsOf: fileURL)
      let mimeType = Self.mimeType(for: fileURL)

      let (_, blobOutput) = try await client.com.atproto.repo.uploadBlob(
        data: data,
        mimeType: mimeType,
        stripMetadata: false
      )

      guard let blob = blobOutput?.blob else {
        throw TilePublishError.blobUploadFailed(path: relativePath)
      }

      // Map "/" to index.html
      let resourcePath = relativePath == "/index.html" ? "/" : relativePath

      resources[resourcePath] = TileResource(
        src: TileResourceSource(
          type: "blob",
          ref: TileResourceRef(link: blob.ref?.cid.string ?? ""),
          size: blob.size,
          mimeType: "application/octet-stream"
        ),
        contentType: mimeType
      )

      logger.debug("Uploaded: \(resourcePath) (\(data.count) bytes)")
    }

    // Also upload any icon/screenshot files referenced in manifest
    // (they should already be in the directory and uploaded above)

    // 4. Build the full manifest
    let manifest = TileManifest(
      name: partialManifest.name,
      description: partialManifest.description,
      categories: partialManifest.categories,
      backgroundColor: nil,
      icons: partialManifest.icons,
      screenshots: partialManifest.screenshots,
      sizing: nil,
      resources: resources,
      shortName: nil,
      themeColor: nil,
      prev: nil
    )

    // 5. Compute tile CID (using manifest JSON hash)
    let manifestJSON = try JSONEncoder().encode(manifest)
    let tileCID = Self.computeSimpleCID(from: manifestJSON)

    // 6. Create the AT record
    let record = TileRecord(
      cid: tileCID,
      tile: manifest,
      createdAt: Date()
    )

    let recordData = try JSONEncoder().encode(record)
    let recordContainer = try JSONDecoder().decode(
      ATProtocolValueContainer.self, from: recordData
    )

    let (responseCode, createOutput) = try await client.com.atproto.repo.createRecord(
      input: .init(
        repo: try ATIdentifier(string: userDID),
        collection: try NSID(nsidString: "ing.dasl.masl"),
        record: recordContainer
      )
    )

    guard responseCode == 200, let output = createOutput else {
      throw TilePublishError.recordCreationFailed
    }

    logger.info("Published tile: \(output.uri.uriString())")

    return PublishResult(
      uri: output.uri.uriString(),
      cid: output.cid.string,
      tileCID: tileCID
    )
  }

  // MARK: - Helpers

  /// Simple CID computation (SHA-256 hash, base32 encoded)
  private static func computeSimpleCID(from data: Data) -> String {
    let hash = SHA256.hash(data: data)
    // Return hex-based identifier; a proper CID would use multicodec + multibase
    return "bafkrei" + hash.compactMap { String(format: "%02x", $0) }.joined().prefix(52)
  }

  /// Determine MIME type from file extension
  static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "html", "htm": return "text/html"
    case "css": return "text/css"
    case "js", "mjs": return "application/javascript"
    case "json": return "application/json"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    case "webp": return "image/webp"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "wasm": return "application/wasm"
    case "mp4": return "video/mp4"
    case "webm": return "video/webm"
    case "mp3": return "audio/mpeg"
    case "ogg": return "audio/ogg"
    case "ico": return "image/x-icon"
    case "txt": return "text/plain"
    case "xml": return "application/xml"
    default: return "application/octet-stream"
    }
  }
}

// MARK: - PartialManifest

/// Minimal manifest for reading user-created manifest.json files
private struct PartialManifest: Codable {
  let name: String
  let description: String?
  let categories: [String]?
  let icons: [TileIcon]?
  let screenshots: [TileScreenshot]?
}

// MARK: - TilePublishError

enum TilePublishError: LocalizedError {
  case missingManifest
  case missingRootDocument
  case cannotReadDirectory
  case blobUploadFailed(path: String)
  case recordCreationFailed

  var errorDescription: String? {
    switch self {
    case .missingManifest:
      return "manifest.json not found in tile directory"
    case .missingRootDocument:
      return "index.html (root document) not found"
    case .cannotReadDirectory:
      return "Cannot read tile directory"
    case .blobUploadFailed(let path):
      return "Failed to upload blob for: \(path)"
    case .recordCreationFailed:
      return "Failed to create tile record on AT Protocol"
    }
  }
}
