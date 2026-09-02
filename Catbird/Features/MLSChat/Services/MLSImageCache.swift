import Foundation
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// LRU disk cache for decrypted MLS images with a size-keyed in-memory thumbnail tier.
/// Keyed by blob_id and partitioned by user DID, 200MB max disk across all accounts.
actor MLSImageCache {
  static let shared = MLSImageCache()

  private let baseCacheDir: URL
  private let maxSizeBytes: Int64 = 200 * 1024 * 1024
  private let thumbnailMemoryCache: NSCache<NSString, PlatformImage> = {
    let cache = NSCache<NSString, PlatformImage>()
    cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB memory limit
    cache.countLimit = 250
    return cache
  }()

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    baseCacheDir = caches.appendingPathComponent("mls-images", isDirectory: true)
    try? FileManager.default.createDirectory(at: baseCacheDir, withIntermediateDirectories: true)
  }

  private func sanitizedDID(_ userDID: String) -> String {
    userDID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "#", with: "_")
      .replacingOccurrences(of: "?", with: "_")
  }

  private func userCacheDir(for userDID: String) -> URL {
    let dir = baseCacheDir.appendingPathComponent(sanitizedDID(userDID), isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func memoryKey(blobId: String, userDID: String, maxPixelSize: CGFloat) -> String {
    "\(sanitizedDID(userDID))/\(blobId)@\(Int(maxPixelSize.rounded()))"
  }

  private func computeCost(for image: PlatformImage) -> Int {
    #if os(iOS)
    let scale = image.scale
    let pixelWidth = image.size.width * scale
    let pixelHeight = image.size.height * scale
    return max(Int(pixelWidth * pixelHeight * 4), 1024)
    #else
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      return max(cgImage.width * cgImage.height * 4, 1024)
    }
    return max(Int(image.size.width * image.size.height * 4), 1024)
    #endif
  }

  private func decodeThumbnail(from data: Data, maxPixelSize: CGFloat) -> PlatformImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
      return nil
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
      return nil
    }
    #if os(iOS)
    return UIImage(cgImage: cgImage)
    #else
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #endif
  }

  /// Get an image from cache, optionally downsampled to the requested pixel size.
  func get(blobId: String, userDID: String, maxPixelSize: CGFloat? = nil) -> PlatformImage? {
    if let maxPixelSize {
      return getThumbnail(blobId: blobId, userDID: userDID, maxPixelSize: maxPixelSize)
    }
    return getOriginal(blobId: blobId, userDID: userDID)
  }

  /// Retrieve downsampled thumbnail from memory cache or decode from knownData / disk cache
  func getThumbnail(blobId: String, userDID: String, maxPixelSize: CGFloat, knownData: Data? = nil) -> PlatformImage? {
    guard !userDID.isEmpty, !blobId.isEmpty, maxPixelSize > 0 else { return nil }
    let memKey = memoryKey(blobId: blobId, userDID: userDID, maxPixelSize: maxPixelSize)
    if let cached = thumbnailMemoryCache.object(forKey: memKey as NSString) {
      return cached
    }

    guard let data = knownData ?? getOriginalData(blobId: blobId, userDID: userDID) else { return nil }
    guard let thumbnail = decodeThumbnail(from: data, maxPixelSize: maxPixelSize) else { return nil }
    thumbnailMemoryCache.setObject(thumbnail, forKey: memKey as NSString, cost: computeCost(for: thumbnail))
    return thumbnail
  }

  /// Retrieve full-resolution image from disk cache
  func getOriginal(blobId: String, userDID: String) -> PlatformImage? {
    guard let data = getOriginalData(blobId: blobId, userDID: userDID) else { return nil }
    return PlatformImage(data: data)
  }

  /// Retrieve original decrypted bytes from disk cache
  func getOriginalData(blobId: String, userDID: String) -> Data? {
    guard !userDID.isEmpty, !blobId.isEmpty else { return nil }
    let fileURL = userCacheDir(for: userDID).appendingPathComponent(blobId)
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    // Touch file to update access time for LRU
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: fileURL.path
    )
    return data
  }

  /// Save original decrypted bytes to disk cache
  func put(blobId: String, userDID: String, imageData: Data) {
    guard !userDID.isEmpty, !blobId.isEmpty else { return }
    let fileURL = userCacheDir(for: userDID).appendingPathComponent(blobId)
    try? imageData.write(to: fileURL)
    evictIfNeeded()
  }

  /// Purge all cached images for a specific user DID (called on logout or account removal)
  func purge(for userDID: String) {
    guard !userDID.isEmpty else { return }
    let dir = baseCacheDir.appendingPathComponent(sanitizedDID(userDID), isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    thumbnailMemoryCache.removeAllObjects()
  }

  /// Purge all cached images across all accounts
  func purgeAll() {
    try? FileManager.default.removeItem(at: baseCacheDir)
    try? FileManager.default.createDirectory(at: baseCacheDir, withIntermediateDirectories: true)
    thumbnailMemoryCache.removeAllObjects()
  }

  private func evictIfNeeded() {
    guard let enumerator = FileManager.default.enumerator(
      at: baseCacheDir,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    var totalSize: Int64 = 0
    var fileInfos: [(url: URL, size: Int64, date: Date)] = []

    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
        values.isDirectory == false,
        let size = values.fileSize,
        let date = values.contentModificationDate
      else { continue }
      totalSize += Int64(size)
      fileInfos.append((url: fileURL, size: Int64(size), date: date))
    }

    guard totalSize > maxSizeBytes else { return }

    // Sort oldest first for LRU eviction
    fileInfos.sort { $0.date < $1.date }

    for info in fileInfos {
      guard totalSize > maxSizeBytes else { break }
      try? FileManager.default.removeItem(at: info.url)
      totalSize -= info.size
    }
  }
}
