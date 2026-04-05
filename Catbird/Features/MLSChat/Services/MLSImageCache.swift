import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// LRU disk cache for decrypted MLS images.
/// Keyed by blob_id, 200MB max, app sandbox.
actor MLSImageCache {
  static let shared = MLSImageCache()

  private let cacheDir: URL
  private let maxSizeBytes: Int64 = 200 * 1024 * 1024

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDir = caches.appendingPathComponent("mls-images", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
  }

  func get(blobId: String) -> PlatformImage? {
    let fileURL = cacheDir.appendingPathComponent(blobId)
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    // Touch file to update access time for LRU
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: fileURL.path
    )
    return PlatformImage(data: data)
  }

  func put(blobId: String, imageData: Data) {
    let fileURL = cacheDir.appendingPathComponent(blobId)
    try? imageData.write(to: fileURL)
    evictIfNeeded()
  }

  private func evictIfNeeded() {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
    ) else { return }

    var totalSize: Int64 = 0
    var fileInfos: [(url: URL, size: Int64, date: Date)] = []

    for file in files {
      guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
        let size = values.fileSize,
        let date = values.contentModificationDate
      else { continue }
      totalSize += Int64(size)
      fileInfos.append((url: file, size: Int64(size), date: date))
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
