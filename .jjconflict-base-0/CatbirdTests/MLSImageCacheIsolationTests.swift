import Testing
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import Catbird

@Suite("MLSImageCache Isolation Tests")
struct MLSImageCacheIsolationTests {

  @Test("Image cache is partitioned strictly per user DID")
  func testImageCachePartitioning() async throws {
    let cache = MLSImageCache.shared
    let userA = "did:plc:alice_\(UUID().uuidString)"
    let userB = "did:plc:bob_\(UUID().uuidString)"
    let blobID = "blob_shared_\(UUID().uuidString)"

    defer {
      Task {
        await cache.purge(for: userA)
        await cache.purge(for: userB)
      }
    }

    // Create distinct test image bytes
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
    let imageA = renderer.image { ctx in
      UIColor.red.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    let imageB = renderer.image { ctx in
      UIColor.blue.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    let dataA = imageA.pngData()!
    let dataB = imageB.pngData()!
    #else
    let repA = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    )!
    let dataA = repA.representation(using: .png, properties: [:])!
    let repB = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    )!
    let dataB = repB.representation(using: .png, properties: [:])!
    #endif

    // User A puts image for blobID
    await cache.put(blobId: blobID, userDID: userA, imageData: dataA)

    // User A must hit cache
    let cachedA = await cache.get(blobId: blobID, userDID: userA)
    #expect(cachedA != nil)

    // User B must get nil (cross-account cache miss)
    let cachedB = await cache.get(blobId: blobID, userDID: userB)
    #expect(cachedB == nil)

    // User B puts own image for the same blobID
    await cache.put(blobId: blobID, userDID: userB, imageData: dataB)
    let newCachedB = await cache.get(blobId: blobID, userDID: userB)
    #expect(newCachedB != nil)
  }

  @Test("Purge for user DID removes only that user's cached attachments")
  func testImageCachePurge() async throws {
    let cache = MLSImageCache.shared
    let userA = "did:plc:alice_\(UUID().uuidString)"
    let userB = "did:plc:bob_\(UUID().uuidString)"
    let blobID = "blob_purge_\(UUID().uuidString)"

    defer {
      Task {
        await cache.purge(for: userA)
        await cache.purge(for: userB)
      }
    }

    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
    let image = renderer.image { ctx in
      UIColor.green.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    let data = image.pngData()!
    #else
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    )!
    let data = rep.representation(using: .png, properties: [:])!
    #endif

    await cache.put(blobId: blobID, userDID: userA, imageData: data)
    await cache.put(blobId: blobID, userDID: userB, imageData: data)

    // Purge only user A
    await cache.purge(for: userA)

    #expect(await cache.get(blobId: blobID, userDID: userA) == nil)
    #expect(await cache.get(blobId: blobID, userDID: userB) != nil)
  }
}
