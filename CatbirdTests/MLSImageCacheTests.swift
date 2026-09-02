import Testing
import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import Catbird

@Suite("MLS Image Cache Tests", .serialized)
struct MLSImageCacheTests {

  private func createTestImageData(width: Int, height: Int) -> Data {
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
    let image = renderer.image { ctx in
      ctx.cgContext.setFillColor(UIColor.systemBlue.cgColor)
      ctx.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return image.pngData()!
    #else
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
    #endif
  }

  @Test("MLSImageCache decodes a bounded thumbnail and retrieves the original")
  func testMLSImageCacheThumbnailTier() async {
    let cache = MLSImageCache.shared
    let userDID = "did:plc:user_\(UUID().uuidString)"
    let blobID = "blob_large_\(UUID().uuidString)"

    // 1. Create a 400x400 image
    let largeImageData = createTestImageData(width: 400, height: 400)
    await cache.put(blobId: blobID, userDID: userDID, imageData: largeImageData)

    // 2. Request a 100px max thumbnail
    let thumbnail = await cache.getThumbnail(blobId: blobID, userDID: userDID, maxPixelSize: 100)
    #expect(thumbnail != nil)

    if let thumb = thumbnail {
      #if os(iOS)
      let width = thumb.size.width * thumb.scale
      let height = thumb.size.height * thumb.scale
      #else
      let width = thumb.size.width
      let height = thumb.size.height
      #endif
      #expect(width <= 100.0)
      #expect(height <= 100.0)
    }

    // Request full-resolution original from disk
    let original = await cache.getOriginal(blobId: blobID, userDID: userDID)
    #expect(original != nil)
    if let orig = original {
      #if os(iOS)
      let origWidth = orig.size.width * orig.scale
      let origHeight = orig.size.height * orig.scale
      #else
      let origWidth = orig.size.width
      let origHeight = orig.size.height
      #endif
      #expect(origWidth >= 400.0)
      #expect(origHeight >= 400.0)
    }

    await cache.purge(for: userDID)
  }

  @Test("MLSImageCache produces downsampled thumbnail from known bytes without disk source")
  func testMLSImageCacheThumbnailFromKnownBytes() async {
    let cache = MLSImageCache.shared
    let userDID = "did:plc:known_bytes_\(UUID().uuidString)"
    let blobID = "blob_known_\(UUID().uuidString)"

    // 1. Prepare raw image data without saving to disk cache
    let imageData = createTestImageData(width: 300, height: 300)

    // Verify disk has no data for this blob
    let diskDataBefore = await cache.getOriginalData(blobId: blobID, userDID: userDID)
    #expect(diskDataBefore == nil)

    // 2. Decode thumbnail by passing knownData directly
    let thumbnail = await cache.getThumbnail(
      blobId: blobID,
      userDID: userDID,
      maxPixelSize: 100,
      knownData: imageData
    )
    #expect(thumbnail != nil)

    if let thumb = thumbnail {
      #if os(iOS)
      let width = thumb.size.width * thumb.scale
      let height = thumb.size.height * thumb.scale
      #else
      let width = thumb.size.width
      let height = thumb.size.height
      #endif
      #expect(width <= 100.0)
      #expect(height <= 100.0)
    }

    // 3. Verify disk remains empty (thumbnail was created purely in-memory from known bytes)
    let diskOriginal = await cache.getOriginal(blobId: blobID, userDID: userDID)
    #expect(diskOriginal == nil)

    // 4. Verify subsequent lookup hits in-memory tier without passing knownData or disk source
    let memoryCached = await cache.getThumbnail(
      blobId: blobID,
      userDID: userDID,
      maxPixelSize: 100
    )
    #expect(memoryCached != nil)

    await cache.purge(for: userDID)
  }

  @Test("MLSImageCache purge clears both memory and disk tiers")
  func testMLSImageCachePurge() async {
    let cache = MLSImageCache.shared
    let userDID = "did:plc:purge_user_\(UUID().uuidString)"
    let blobID = "blob_purge_\(UUID().uuidString)"

    let testData = createTestImageData(width: 200, height: 200)
    await cache.put(blobId: blobID, userDID: userDID, imageData: testData)

    // Warm memory cache
    _ = await cache.getThumbnail(blobId: blobID, userDID: userDID, maxPixelSize: 80)

    // Purge user
    await cache.purge(for: userDID)

    // Both thumbnail and original must be nil
    let thumbAfterPurge = await cache.getThumbnail(blobId: blobID, userDID: userDID, maxPixelSize: 80)
    let origAfterPurge = await cache.getOriginal(blobId: blobID, userDID: userDID)

    #expect(thumbAfterPurge == nil)
    #expect(origAfterPurge == nil)
  }

#if os(iOS)
  @Test("ZoomableImageViewController updates image and preserves zoom scale and content offset")
  @MainActor
  func testZoomableImageViewControllerUpdateImage() async throws {
    let thumb = UIImage(systemName: "photo") ?? UIImage()
    let full = UIImage(systemName: "photo.fill") ?? UIImage()

    let vc = ZoomableImageViewController(uiImage: thumb, altText: "Test Alt", liveTextSupported: false)
    _ = vc.view
    vc.view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    vc.view.layoutIfNeeded()

    let scrollView = vc.view.subviews.compactMap { $0 as? UIScrollView }.first
    #expect(scrollView != nil)
    scrollView?.zoomScale = 2.5
    scrollView?.contentOffset = CGPoint(x: 15, y: 25)

    let imageView = scrollView?.subviews.compactMap { $0 as? UIImageView }.first
    #expect(imageView != nil)
    #expect(imageView?.image === thumb)

    // Update with full-resolution original image
    vc.updateImage(full)

    #expect(imageView?.image === full)
    #expect(scrollView?.zoomScale == 2.5)
    #expect(scrollView?.contentOffset == CGPoint(x: 15, y: 25))

    // Updating with identical image object is a no-op that preserves state
    vc.updateImage(full)
    #expect(imageView?.image === full)
    #expect(scrollView?.zoomScale == 2.5)
    #expect(scrollView?.contentOffset == CGPoint(x: 15, y: 25))
  }
#endif
}
