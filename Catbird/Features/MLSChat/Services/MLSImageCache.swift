import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// LRU disk cache for decrypted MLS images.
/// Keyed by blob_id and partitioned by user DID, 200MB max across all accounts, app sandbox.
actor MLSImageCache {
  static let shared = MLSImageCache()

  private let baseCacheDir: URL
  private let maxSizeBytes: Int64 = 200 * 1024 * 1024

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

  func get(blobId: String, userDID: String) -> PlatformImage? {
    guard !userDID.isEmpty, !blobId.isEmpty else { return nil }
    let fileURL = userCacheDir(for: userDID).appendingPathComponent(blobId)
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    // Touch file to update access time for LRU
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: fileURL.path
    )
    return PlatformImage(data: data)
  }

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
  }

  /// Purge all cached images across all accounts
  func purgeAll() {
    try? FileManager.default.removeItem(at: baseCacheDir)
    try? FileManager.default.createDirectory(at: baseCacheDir, withIntermediateDirectories: true)
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
