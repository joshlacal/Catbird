//
//  CircleMediaLoader.swift
//  Catbird
//

import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import ImageIO
import CoreGraphics

/// Authenticated image loader and memory cache for Circle media.
///
/// Images are fetched exclusively through the proxied AppView media endpoint
/// (`blue.catbird.circle.getMedia`) via `CircleService`. Raw tokens and media
/// URLs are never exposed. Decoded `PlatformImage` instances are kept in memory
/// only, keyed by `accountDID|space|authorDID|cid|targetBucket`, and purged on account
/// logout/switch or Space unavailability.
///
/// Encrypted Circles: `getMedia` serves ciphertext. `image(decryptWith:)`
/// verifies the ciphertext digest, decrypts with `BlobCrypto`, and decodes;
/// only the decoded image enters the (memory) cache, never the plaintext bytes
/// and never a disk cache. Media keys of opened posts are registered here
/// (`registerKeys`, memory only, purged with the images) so `CircleMediaView`
/// can find them.
actor CircleMediaLoader {
  static let shared = CircleMediaLoader()

  private var service: CircleService?
  private var caches: [String: NSCache<NSString, PlatformImage>] = [:]
  private var cacheKeys: [String: Set<String>] = [:]
  /// accountKey → `space|authorDID|cid` → key ref.
  private var mediaKeys: [String: [String: CircleMediaKeyRef]] = [:]
  private var generation: UInt64 = 0

  private let totalCostLimit: Int = 50 * 1024 * 1024 // 50MB per account
  private let countLimit: Int = 200

  init(service: CircleService? = nil) {
    self.service = service
  }

  func setService(_ service: CircleService) {
    generation &+= 1
    self.service = service
  }

  private func cache(for accountKey: String) -> NSCache<NSString, PlatformImage> {
    if let existing = caches[accountKey] {
      return existing
    }
    let cache = NSCache<NSString, PlatformImage>()
    cache.totalCostLimit = totalCostLimit
    cache.countLimit = countLimit
    caches[accountKey] = cache
    return cache
  }

  /// Fetches and decodes a Circle image as an oriented thumbnail matching the target bucket, caching in memory.
  func image(
    accountDID: String? = nil,
    space: SpaceRef,
    authorDID: DID,
    cid: CID,
    targetBucket: Int,
    service: CircleService? = nil,
    decryptWith keyRef: CircleMediaKeyRef? = nil
  ) async throws -> PlatformImage {
    let accountKey = accountDID ?? "default"
    let cacheKey = "\(space.description)|\(authorDID.description)|\(cid.description)|\(targetBucket)"
    let accountCache = cache(for: accountKey)

    if let cached = accountCache.object(forKey: cacheKey as NSString) {
      return cached
    }

    guard let activeService = service ?? self.service else {
      throw CircleMediaError.serviceUnavailable
    }

    let requestGeneration = generation
    let fetched = try await activeService.media(space: space, authorDID: authorDID, cid: cid)
    guard !Task.isCancelled, generation == requestGeneration else {
      throw CancellationError()
    }
    let data = try keyRef.map { try Self.decrypt(fetched, with: $0) } ?? fetched
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CircleMediaError.invalidImage
    }

    let options: [CFString: Any]
    if targetBucket > 0 {
      options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: targetBucket,
        kCGImageSourceShouldCacheImmediately: true
      ]
    } else {
      options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
      ]
    }

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
      throw CircleMediaError.invalidImage
    }

    #if os(iOS)
    let platformImage = UIImage(cgImage: cgImage)
    #elseif os(macOS)
    let platformImage = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    #endif

    let bytesPerRow = cgImage.bytesPerRow
    let height = cgImage.height
    let cost = (bytesPerRow > 0 && height > 0) ? bytesPerRow * height : max(1, cgImage.width * cgImage.height * 4)

    accountCache.setObject(platformImage, forKey: cacheKey as NSString, cost: cost)
    var keys = cacheKeys[accountKey, default: []]
    keys.insert(cacheKey)
    keys = keys.filter { accountCache.object(forKey: $0 as NSString) != nil }
    cacheKeys[accountKey] = keys
    return platformImage
  }

  /// Verifies the ciphertext's SHA-256 against the key ref, then decrypts it.
  /// Any failure is `decryptionFailed`; ciphertext is never decoded as an image.
  static func decrypt(_ ciphertext: Data, with keyRef: CircleMediaKeyRef) throws -> Data {
    do {
      return try BlobCrypto.decrypt(
        ciphertext: ciphertext, key: keyRef.key, iv: keyRef.iv, expectedSHA256: keyRef.sha256
      )
    } catch {
      throw CircleMediaError.decryptionFailed
    }
  }

  // MARK: Media keys (encrypted Circles)

  private static func keyID(space: SpaceRef, authorDID: DID, cid: CID) -> String {
    "\(space.description)|\(authorDID.description)|\(cid.string)"
  }

  /// Records the keys of an opened post's media (memory only).
  func registerKeys(_ refs: [CircleMediaKeyRef], accountDID: String, space: SpaceRef, authorDID: DID) {
    var keys = mediaKeys[accountDID, default: [:]]
    for ref in refs {
      keys[Self.keyID(space: space, authorDID: authorDID, cid: ref.cid)] = ref
    }
    mediaKeys[accountDID] = keys
  }

  /// The registered key for one blob, if its post was opened by this account.
  func registeredKey(accountDID: String, space: SpaceRef, authorDID: DID, cid: CID) -> CircleMediaKeyRef? {
    mediaKeys[accountDID]?[Self.keyID(space: space, authorDID: authorDID, cid: cid)]
  }

  /// Purges every cached image for an account (called on logout, switch, removal).
  func purge(accountDID: String) {
    generation &+= 1
    mediaKeys.removeValue(forKey: accountDID)
    caches[accountDID]?.removeAllObjects()
    caches.removeValue(forKey: accountDID)
    cacheKeys.removeValue(forKey: accountDID)
  }

  /// Purges cached images for one account in one Space.
  func purge(accountDID: String, space: SpaceRef) {
    generation &+= 1
    let prefix = "\(space.description)|"
    mediaKeys[accountDID] = mediaKeys[accountDID]?.filter { !$0.key.hasPrefix(prefix) }
    if let accountCache = caches[accountDID], var keys = cacheKeys[accountDID] {
      for key in keys where key.hasPrefix(prefix) {
        accountCache.removeObject(forKey: key as NSString)
        keys.remove(key)
      }
      cacheKeys[accountDID] = keys
    }
  }

  /// Purges cached images for a specific Space regardless of account.
  func purge(space: SpaceRef) {
    generation &+= 1
    let prefix = "\(space.description)|"
    for (account, keys) in mediaKeys {
      mediaKeys[account] = keys.filter { !$0.key.hasPrefix(prefix) }
    }
    for (accountDID, accountCache) in caches {
      if var keys = cacheKeys[accountDID] {
        for key in keys where key.hasPrefix(prefix) {
          accountCache.removeObject(forKey: key as NSString)
          keys.remove(key)
        }
        cacheKeys[accountDID] = keys
      }
    }
  }

  /// Purges all in-memory Circle images.
  func purgeAll() {
    generation &+= 1
    for cache in caches.values {
      cache.removeAllObjects()
    }
    caches.removeAll()
    cacheKeys.removeAll()
    mediaKeys.removeAll()
  }
}

public enum CircleMediaError: Error, LocalizedError, Equatable {
  case invalidImage
  case serviceUnavailable
  case decryptionFailed

  public var errorDescription: String? {
    switch self {
    case .invalidImage:
      return String(localized: "The Circle media could not be decoded as an image.", comment: "Error when downloaded Circle media bytes cannot be decoded as an image.")
    case .serviceUnavailable:
      return String(localized: "The Circle media service is unavailable.", comment: "Error when the Circle media service cannot be reached.")
    case .decryptionFailed:
      return String(localized: "The Circle media could not be decrypted.", comment: "Error when encrypted Circle media fails decryption.")
    }
  }
}
