import Foundation
import OSLog

// MARK: - TileResourceLoader

/// Loads and caches tile resources (blobs) from a PDS
/// Resources are cached by CID for deduplication across tiles
actor TileResourceLoader {
  static let shared = TileResourceLoader()

  private var cache: [String: CachedTileResource] = [:]
  private var inFlightTasks: [String: Task<CachedTileResource, Error>] = [:]
  private let logger = Logger(subsystem: "blue.catbird", category: "TileResourceLoader")
  private let cacheDirectory: URL?

  init() {
    cacheDirectory = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")?
      .appendingPathComponent("TileCache", isDirectory: true)

    if let dir = cacheDirectory {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  // MARK: - Public API

  /// Load all resources for a tile manifest
  func loadResources(
    for manifest: TileManifest,
    authorDID: String,
    pdsHost: String
  ) async throws -> [String: CachedTileResource] {
    var results: [String: CachedTileResource] = [:]

    try await withThrowingTaskGroup(of: (String, CachedTileResource).self) { group in
      for (path, resource) in manifest.resources {
        guard let cid = resource.src.ref?.link else { continue }

        group.addTask {
          let cached = try await self.loadResource(
            cid: cid,
            contentType: resource.contentType,
            expectedSize: resource.src.size,
            authorDID: authorDID,
            pdsHost: pdsHost
          )
          return (path, cached)
        }
      }

      for try await (path, cached) in group {
        results[path] = cached
      }
    }

    return results
  }

  /// Load a single resource by CID
  func loadResource(
    cid: String,
    contentType: String,
    expectedSize: Int?,
    authorDID: String,
    pdsHost: String
  ) async throws -> CachedTileResource {
    // Check memory cache
    if let cached = cache[cid] {
      logger.debug("Cache hit for CID: \(cid, privacy: .public)")
      return cached
    }

    // Check disk cache
    if let diskCached = loadFromDisk(cid: cid, contentType: contentType) {
      cache[cid] = diskCached
      return diskCached
    }

    // Deduplicate in-flight requests
    if let existing = inFlightTasks[cid] {
      return try await existing.value
    }

    let task = Task<CachedTileResource, Error> {
      defer { inFlightTasks.removeValue(forKey: cid) }

      let data = try await fetchBlob(
        cid: cid,
        authorDID: authorDID,
        pdsHost: pdsHost
      )

      // Validate size if expected
      if let expectedSize, data.count != expectedSize {
        logger.warning(
          "Size mismatch for CID \(cid, privacy: .public): expected \(expectedSize), got \(data.count)"
        )
      }

      let cached = CachedTileResource(
        cid: cid,
        data: data,
        contentType: contentType
      )

      cache[cid] = cached
      saveToDisk(cached)

      return cached
    }

    inFlightTasks[cid] = task
    return try await task.value
  }

  /// Resolve a resource path to a blob URL on the PDS (for image loading via Nuke)
  func blobURL(
    cid: String,
    authorDID: String,
    pdsHost: String
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = pdsHost
    components.path = "/xrpc/com.atproto.sync.getBlob"
    components.queryItems = [
      URLQueryItem(name: "did", value: authorDID),
      URLQueryItem(name: "cid", value: cid),
    ]
    return components.url
  }

  /// Clear all cached resources
  func clearCache() {
    cache.removeAll()
    if let dir = cacheDirectory {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  // MARK: - Private

  private func fetchBlob(
    cid: String,
    authorDID: String,
    pdsHost: String
  ) async throws -> Data {
    guard let url = blobURL(cid: cid, authorDID: authorDID, pdsHost: pdsHost) else {
      throw TileResourceError.invalidURL
    }

    logger.debug("Fetching blob: \(url, privacy: .public)")

    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw TileResourceError.fetchFailed(statusCode: statusCode)
    }

    logger.debug("Fetched blob CID=\(cid, privacy: .public) size=\(data.count)")
    return data
  }

  private func diskPath(for cid: String) -> URL? {
    cacheDirectory?.appendingPathComponent(cid)
  }

  private func saveToDisk(_ resource: CachedTileResource) {
    guard let path = diskPath(for: resource.cid) else { return }
    let metadata = "\(resource.contentType)\n".data(using: .utf8) ?? Data()
    let combined = metadata + resource.data
    try? combined.write(to: path, options: .atomic)
  }

  private func loadFromDisk(cid: String, contentType: String) -> CachedTileResource? {
    guard let path = diskPath(for: cid),
      let combined = try? Data(contentsOf: path)
    else { return nil }

    // Find the newline separator between metadata and data
    guard let newlineIndex = combined.firstIndex(of: UInt8(ascii: "\n")) else { return nil }

    let metadataRange = combined.startIndex..<newlineIndex
    guard let storedContentType = String(data: combined[metadataRange], encoding: .utf8) else {
      return nil
    }

    let dataStart = combined.index(after: newlineIndex)
    let data = combined[dataStart...]

    return CachedTileResource(
      cid: cid,
      data: Data(data),
      contentType: storedContentType
    )
  }
}

// MARK: - CachedTileResource

/// A tile resource loaded and cached locally
struct CachedTileResource: Sendable {
  let cid: String
  let data: Data
  let contentType: String

  /// MIME type suitable for HTTP responses
  var mimeType: String { contentType }
}

// MARK: - TileResourceError

enum TileResourceError: LocalizedError {
  case invalidURL
  case fetchFailed(statusCode: Int)
  case cidMismatch
  case resourceNotFound(path: String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Invalid blob URL"
    case .fetchFailed(let code):
      return "Failed to fetch blob (HTTP \(code))"
    case .cidMismatch:
      return "Content integrity check failed"
    case .resourceNotFound(let path):
      return "Resource not found: \(path)"
    }
  }
}
