import CoreGraphics
import Foundation
import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Decodes and encodes composer photos with ImageIO, away from the main actor.
///
/// Each photo is decoded once, straight to the size it is used at, instead of decoding the
/// full 12–48 MP bitmap. Uploads are encoded once without metadata and re-encoded only while
/// searching for the highest quality that fits the blob limit.
enum ComposerImagePreparation {
  struct PreparedUpload: Sendable {
    let data: Data
    /// Pixel size of the encoded image, with EXIF orientation already applied.
    let pixelSize: CGSize
  }

  /// A small decoded rendition for composer thumbnails.
  struct Preview: @unchecked Sendable {
    // CGImage is immutable, so sharing it across tasks is safe.
    let cgImage: CGImage
    /// Pixel size of the original image, with EXIF orientation applied.
    let sourcePixelSize: CGSize

    var image: Image {
      #if os(iOS)
      Image(uiImage: UIImage(cgImage: cgImage))
      #elseif os(macOS)
      Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
      #endif
    }
  }

  /// A cropped or edited photo: full-size JPEG bytes plus their thumbnail.
  struct EditedImage: Sendable {
    let data: Data
    let preview: Preview
  }

  enum PreparationError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
      switch self {
      case .unreadableImage: return "This photo couldn’t be read."
      case .encodingFailed: return "This photo couldn’t be prepared for upload."
      }
    }
  }

  /// The official client uploads at most 2000 px on the long side.
  static let uploadMaxPixelSize = 2000
  /// Stays under the 1,000,000-byte blob limit of `app.bsky.embed.images`.
  static let uploadMaxBytes = 976_560
  /// Thumbnails fill 100 pt squares and the alt-text editor draws the photo up to 220 pt tall.
  static let previewMaxPixelSize = 720

  /// Crops and edits keep full resolution; uploads downsample them later.
  static let editedImageQuality: CGFloat = 0.9

  private static let initialQuality: CGFloat = 0.85
  private static let minimumQuality: CGFloat = 0.3
  private static let qualitySearchSteps = 4
  private static let minimumDownscalePixelSize = 512
  private static let logger = Logger(subsystem: "blue.catbird", category: "ComposerImagePreparation")

  // MARK: - Upload

  /// Prepares an upload on a background thread; the caller's actor is free while it runs.
  static func prepareForUpload(
    _ data: Data,
    maxPixelSize: Int = uploadMaxPixelSize,
    maxBytes: Int = uploadMaxBytes
  ) async throws -> PreparedUpload {
    try await Task.detached(priority: .userInitiated) {
      try prepareForUploadSynchronously(data, maxPixelSize: maxPixelSize, maxBytes: maxBytes)
    }.value
  }

  /// Downsamples to `maxPixelSize`, strips all metadata, and picks the highest JPEG quality
  /// that fits `maxBytes`. Images that do not fit even at the lowest quality are downscaled.
  static func prepareForUploadSynchronously(
    _ data: Data,
    maxPixelSize: Int = uploadMaxPixelSize,
    maxBytes: Int = uploadMaxBytes
  ) throws -> PreparedUpload {
    // One interval per photo, in the shared "Intervals" category next to ComposerSubmit.
    let interval = PerformanceSignposts.beginInterval("ComposerImageProcess")
    defer { PerformanceSignposts.endInterval("ComposerImageProcess", interval) }

    guard let source = makeSource(data) else { throw PreparationError.unreadableImage }
    var pixelLimit = maxPixelSize
    while true {
      guard let image = downsample(source, maxPixelSize: pixelLimit) else {
        throw PreparationError.unreadableImage
      }
      let pixelSize = CGSize(width: image.width, height: image.height)
      guard let opaque = imageForJPEG(image, source: source) else {
        throw PreparationError.encodingFailed
      }
      let (encoded, smallestSize) = try encodeWithinLimit(opaque, maxBytes: maxBytes)
      if let encoded {
        logger.debug("Prepared \(image.width)x\(image.height) upload: \(encoded.count) bytes")
        return PreparedUpload(data: encoded, pixelSize: pixelSize)
      }
      // Even the lowest quality is too large, which only happens for very noisy images.
      // Shrink by the byte overshoot (bytes scale with area) and try again.
      let currentLongSide = max(image.width, image.height)
      let scale = (Double(maxBytes) / Double(smallestSize)).squareRoot() * 0.9
      let nextLimit = Int(Double(currentLongSide) * scale)
      guard nextLimit >= minimumDownscalePixelSize, nextLimit < currentLongSide else {
        throw PreparationError.encodingFailed
      }
      pixelLimit = nextLimit
    }
  }

  /// Returns the highest-quality encoding within `maxBytes`, or nil and the size of the
  /// lowest-quality encoding when none fits.
  private static func encodeWithinLimit(
    _ image: CGImage, maxBytes: Int
  ) throws -> (Data?, smallestSize: Int) {
    guard let first = encodeJPEG(image, quality: initialQuality) else {
      throw PreparationError.encodingFailed
    }
    if first.count <= maxBytes { return (first, first.count) }

    var low = minimumQuality
    var high = initialQuality
    var best: Data?
    for _ in 0..<qualitySearchSteps {
      let quality = (low + high) / 2
      guard let encoded = encodeJPEG(image, quality: quality) else {
        throw PreparationError.encodingFailed
      }
      if encoded.count <= maxBytes {
        best = encoded
        low = quality
      } else {
        high = quality
      }
    }
    if let best { return (best, best.count) }

    guard let lowest = encodeJPEG(image, quality: minimumQuality) else {
      throw PreparationError.encodingFailed
    }
    return lowest.count <= maxBytes ? (lowest, lowest.count) : (nil, lowest.count)
  }

  /// Adding a bare CGImage writes no EXIF, GPS, TIFF or IPTC properties.
  private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  /// JPEG has no alpha. HEIF-family decoder images can lose alpha without blending in
  /// ImageIO's JPEG encoder, exposing the colour underneath fully transparent pixels.
  /// Composite once before quality search, rather than once per candidate encoding.
  private static func imageForJPEG(_ image: CGImage, source: CGImageSource? = nil) -> CGImage? {
    if let source,
       let properties = CGImageSourceCopyPropertiesAtIndex(
         source, primaryImageIndex(in: source), nil
       ) as? [CFString: Any] {
      // ImageIO omits HasAlpha for opaque sources, including opaque HEICs that decode
      // with an alpha channel. Avoid copying those camera photos unnecessarily.
      let alpha = properties[kCGImagePropertyHasAlpha]
      if alpha == nil || (alpha as? Bool) == false { return image }
    }
    // Unreadable/unknown source properties and edited bitmaps stay conservative.
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
      return image
    default:
      break
    }
    return renderedForJPEG(image)
  }

  private static func renderedForJPEG(_ image: CGImage, croppingTo crop: CGRect? = nil) -> CGImage? {
    let crop = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let bounds = CGRect(origin: .zero, size: crop.size)
    let sourceSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
    for space in [sourceSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap({ $0 }) {
      guard let context = CGContext(
        data: nil, width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { continue }
      context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
      context.fill(bounds)
      // `crop` is top-left based like CGImage.cropping(to:); CGContext's origin is bottom-left.
      context.draw(image, in: CGRect(
        x: -crop.minX, y: crop.maxY - CGFloat(image.height),
        width: CGFloat(image.width), height: CGFloat(image.height)
      ))
      return context.makeImage()
    }
    return nil
  }

  // MARK: - Preview

  /// Decodes a thumbnail rendition on a background thread.
  static func makePreview(
    from data: Data, maxPixelSize: Int = previewMaxPixelSize
  ) async -> Preview? {
    await Task.detached(priority: .userInitiated) {
      makePreviewSynchronously(from: data, maxPixelSize: maxPixelSize)
    }.value
  }

  /// Decodes only a thumbnail rendition; the source's pixel size comes from its header.
  static func makePreviewSynchronously(
    from data: Data, maxPixelSize: Int = previewMaxPixelSize
  ) -> Preview? {
    guard let source = makeSource(data),
          let image = downsample(source, maxPixelSize: maxPixelSize) else { return nil }
    let sourceSize = orientedPixelSize(of: source) ?? CGSize(width: image.width, height: image.height)
    return Preview(cgImage: image, sourcePixelSize: sourceSize)
  }

  // MARK: - Crop and Edit

  /// Crops the upright photo to its centred square on a background thread.
  static func squareCropped(_ data: Data) async -> EditedImage? {
    await Task.detached(priority: .userInitiated) {
      squareCroppedSynchronously(data)
    }.value
  }

  /// Decodes at full size with EXIF orientation applied before cropping, so portrait camera
  /// photos (stored landscape) crop around their visible centre.
  static func squareCroppedSynchronously(_ data: Data) -> EditedImage? {
    guard let source = makeSource(data), let size = orientedPixelSize(of: source),
          let upright = downsample(source, maxPixelSize: Int(max(size.width, size.height))) else { return nil }
    let side = min(upright.width, upright.height)
    let square = CGRect(x: (upright.width - side) / 2, y: (upright.height - side) / 2, width: side, height: side)
    let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
    let opaque: CGImage?
    if type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true {
      // Cropping an ImageIO-backed HEIF CGImage can expose a broken subimage provider
      // on iOS. Draw the upright source into a crop-sized bitmap instead; no full-size
      // intermediate copy is needed, even for opaque camera photos.
      opaque = renderedForJPEG(upright, croppingTo: square)
    } else {
      opaque = upright.cropping(to: square).flatMap { imageForJPEG($0, source: source) }
    }
    guard let opaque,
          let jpeg = encodeJPEG(opaque, quality: editedImageQuality) else { return nil }
    return editedImage(from: jpeg)
  }

  #if os(iOS)
  /// Encodes a photo returned by the editor on a background thread.
  static func prepareEditedImage(_ image: UIImage) async -> EditedImage? {
    await Task.detached(priority: .userInitiated) {
      image.jpegData(compressionQuality: editedImageQuality).flatMap(editedImage(from:))
    }.value
  }
  #elseif os(macOS)
  /// Encodes a photo returned by the editor on a background thread.
  static func prepareEditedImage(_ image: NSImage) async -> EditedImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return await Task.detached(priority: .userInitiated) {
      imageForJPEG(cgImage).flatMap { encodeJPEG($0, quality: editedImageQuality) }
        .flatMap(editedImage(from:))
    }.value
  }
  #endif

  private static func editedImage(from jpeg: Data) -> EditedImage? {
    makePreviewSynchronously(from: jpeg).map { EditedImage(data: jpeg, preview: $0) }
  }

  // MARK: - ImageIO

  private static func makeSource(_ data: Data) -> CGImageSource? {
    // The source only feeds one thumbnail decode, so it should not cache the full image.
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
          CGImageSourceGetCount(source) > 0 else { return nil }
    return source
  }

  /// Decodes directly at the target size, with EXIF orientation applied. ImageIO never
  /// enlarges an image that is already smaller than `maxPixelSize`.
  private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ] as [CFString: Any] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, primaryImageIndex(in: source), options)
  }

  private static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(
      source, primaryImageIndex(in: source), nil
    ) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0 else { return nil }
    let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    switch CGImagePropertyOrientation(rawValue: rawOrientation) {
    case .left, .leftMirrored, .right, .rightMirrored:
      return CGSize(width: height, height: width)
    default:
      return CGSize(width: width, height: height)
    }
  }

  private static func primaryImageIndex(in source: CGImageSource) -> Int {
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return 0 }
    // The container follows HEIF's designated primary item even for plain HEIF,
    // where CGImageSourceGetPrimaryImageIndex can incorrectly return zero.
    let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    if let index = properties?[kCGImagePropertyPrimaryImage] as? Int,
       (0..<count).contains(index) { return index }
    let index = CGImageSourceGetPrimaryImageIndex(source)
    return (0..<count).contains(index) ? index : 0
  }
}

extension PostComposerViewModel.MediaItem {
  /// Shows a downsampled thumbnail while keeping the original bytes for upload and editing.
  mutating func applyPreview(_ preview: ComposerImagePreparation.Preview) {
    image = preview.image
    aspectRatio = preview.sourcePixelSize
  }
}
