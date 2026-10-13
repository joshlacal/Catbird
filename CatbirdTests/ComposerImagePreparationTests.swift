import CoreGraphics
import Foundation
import ImageIO
import Petrel
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Catbird

@Suite("Composer image preparation")
struct ComposerImagePreparationTests {
  // MARK: - Fixtures

  /// A smooth photo-like gradient, which compresses like a typical camera image.
  private static func gradientImage(
    width: Int, height: Int, colorSpace: CFString = CGColorSpace.sRGB
  ) -> CGImage {
    let space = CGColorSpace(name: colorSpace)!
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let colors = [
      CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1),
      CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
      gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
    )
    return context.makeImage()!
  }

  /// Seeded per-pixel noise (SplitMix64), which barely compresses and forces the downscale
  /// path. Keep it at or under 2000 px: resampling would smooth the noise away.
  private static func noiseImage(width: Int, height: Int) -> CGImage {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let value = next()
      pixels[index] = UInt8(truncatingIfNeeded: value)
      pixels[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
      pixels[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
  }

  /// Encodes like a camera: EXIF orientation, GPS and device metadata attached.
  private static func cameraJPEG(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 0.95,
      kCGImagePropertyOrientation: orientation.rawValue,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W"
      ],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:12 07:00:00"
      ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private static func properties(of data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
  }

  // MARK: - Upload

  @Test("A 12 MP portrait photo uploads at 2000 px, upright, within the blob limit")
  func downsamplesAndAppliesOrientation() throws {
    // Stored landscape with orientation 6, as the camera writes portrait photos.
    let data = Self.cameraJPEG(Self.gradientImage(width: 4032, height: 3024), orientation: .right)

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)

    #expect(prepared.pixelSize == CGSize(width: 1500, height: 2000))
    #expect(prepared.data.count <= ComposerImagePreparation.uploadMaxBytes)
    let output = Self.properties(of: prepared.data)
    #expect((output[kCGImagePropertyPixelWidth] as? Int) == 1500)
    #expect((output[kCGImagePropertyPixelHeight] as? Int) == 2000)
    #expect(((output[kCGImagePropertyOrientation] as? Int) ?? 1) == 1)
  }

  @Test("Location, device and capture-time metadata are stripped")
  func stripsMetadata() throws {
    let data = Self.cameraJPEG(Self.gradientImage(width: 3000, height: 2000))
    #expect(Self.properties(of: data)[kCGImagePropertyGPSDictionary] != nil)

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)

    let output = Self.properties(of: prepared.data)
    #expect(output[kCGImagePropertyGPSDictionary] == nil)
    let tiff = output[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
    #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    let exif = output[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
  }

  @Test("Small images are not enlarged")
  func keepsSmallImagesAtTheirSize() throws {
    let data = Self.cameraJPEG(Self.gradientImage(width: 800, height: 600))

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)

    #expect(prepared.pixelSize == CGSize(width: 800, height: 600))
  }

  @Test("Images that miss the limit at the lowest quality are downscaled until they fit")
  func downscalesIncompressibleImages() throws {
    let data = Self.cameraJPEG(Self.noiseImage(width: 2000, height: 2000))

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)

    #expect(prepared.data.count <= ComposerImagePreparation.uploadMaxBytes)
    #expect(max(prepared.pixelSize.width, prepared.pixelSize.height) < 2000)
    #expect(max(prepared.pixelSize.width, prepared.pixelSize.height) >= 512)
  }

  @Test("Unreadable bytes fail instead of uploading garbage")
  func rejectsUnreadableData() {
    let data = Data("Not an image".utf8)
    #expect(throws: ComposerImagePreparation.PreparationError.self) {
      try ComposerImagePreparation.prepareForUploadSynchronously(data)
    }
    #expect(ComposerImagePreparation.makePreviewSynchronously(from: data) == nil)
  }

  @Test("Transparent areas flatten the same way the previous UIKit encoder did")
  func flattensTransparencyLikeUIKit() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
    let sticker = renderer.image { context in
      UIColor.systemRed.setFill()
      context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
    }
    let png = try #require(sticker.pngData())
    let previous = try #require(UIImage(data: png)?.jpegData(compressionQuality: 0.85))

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(png)

    func cornerPixel(_ data: Data) throws -> [UInt8] {
      let image = try #require(UIImage(data: data)?.cgImage)
      var pixel = [UInt8](repeating: 0, count: 4)
      let context = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return Array(pixel.prefix(3))
    }
    let previousCorner = try cornerPixel(previous)
    let preparedCorner = try cornerPixel(prepared.data)
    for channel in 0..<3 {
      #expect(abs(Int(previousCorner[channel]) - Int(preparedCorner[channel])) <= 8)
    }
  }

  // MARK: - Crop and edit

  /// A landscape bitmap with 100 px red and blue bands at its left and right edges. Tagged with
  /// orientation 6 it displays as a portrait whose bands sit at the top and bottom.
  private static func bandedImage(width: Int = 800, height: Int = 600) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let band = (width - height) / 2
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: band, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width - band, y: 0, width: band, height: height))
    return context.makeImage()!
  }

  private static func pixel(_ data: Data, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var rgba = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(
      data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    // Draw so that pixel (x, y), counted from the top left, lands on the 1×1 context.
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
  }

  @Test("Square crop of a portrait camera photo is square and centred on the visible image")
  func squareCropUsesUprightGeometry() throws {
    let data = Self.cameraJPEG(Self.bandedImage(), orientation: .right)

    let cropped = try #require(ComposerImagePreparation.squareCroppedSynchronously(data))

    let output = Self.properties(of: cropped.data)
    #expect((output[kCGImagePropertyPixelWidth] as? Int) == 600)
    #expect((output[kCGImagePropertyPixelHeight] as? Int) == 600)
    #expect(((output[kCGImagePropertyOrientation] as? Int) ?? 1) == 1)
    #expect(output[kCGImagePropertyGPSDictionary] == nil)
    #expect(cropped.preview.sourcePixelSize == CGSize(width: 600, height: 600))
    // The bands sat above and below the visible centre, so every corner is green.
    for (x, y) in [(8, 8), (591, 8), (8, 591), (591, 591), (300, 300)] {
      let color = try Self.pixel(cropped.data, x: x, y: y)
      #expect(color.green > 200 && color.red < 60 && color.blue < 60, "pixel (\(x), \(y)) = \(color)")
    }
  }

  @Test("An edited photo with a rotated orientation is encoded upright at full size")
  func editedImageKeepsOrientation() async throws {
    let rotated = UIImage(cgImage: Self.gradientImage(width: 1200, height: 900), scale: 1, orientation: .right)

    let edited = try #require(await ComposerImagePreparation.prepareEditedImage(rotated))

    #expect(edited.preview.sourcePixelSize == CGSize(width: 900, height: 1200))
    let upright = try #require(ComposerImagePreparation.makePreviewSynchronously(from: edited.data, maxPixelSize: 4000))
    #expect(upright.cgImage.width == 900 && upright.cgImage.height == 1200)
  }

  // MARK: - Preview

  @Test("Previews decode at thumbnail size and report the full upright size")
  func previewIsSmallAndReportsSourceSize() throws {
    let data = Self.cameraJPEG(Self.gradientImage(width: 4032, height: 3024), orientation: .right)

    let preview = try #require(ComposerImagePreparation.makePreviewSynchronously(from: data))

    #expect(max(preview.cgImage.width, preview.cgImage.height) <= ComposerImagePreparation.previewMaxPixelSize)
    #expect(preview.cgImage.height > preview.cgImage.width)
    #expect(preview.sourcePixelSize == CGSize(width: 3024, height: 4032))
  }

  @Test("Async preparation returns the same result as the synchronous path")
  func asyncPreparationMatches() async throws {
    let data = Self.cameraJPEG(Self.gradientImage(width: 2400, height: 1800))

    let prepared = try await ComposerImagePreparation.prepareForUpload(data)
    let preview = await ComposerImagePreparation.makePreview(from: data)

    #expect(prepared.pixelSize == CGSize(width: 2000, height: 1500))
    #expect(preview?.sourcePixelSize == CGSize(width: 2400, height: 1800))
  }

  // MARK: - Petrel upload seam

  /// The composer uploads with `uploadBlob(stripMetadata: true)`. For its output that must be a
  /// lossless strip that passes Petrel's read-back check, keeps the colour profile, and leaves
  /// nothing for a second re-encode: a JPEG within 1,000,000 bytes is sent as it is.
  @Test(
    "Prepared portrait photos pass Petrel's strip with no second re-encode",
    arguments: [false, true]
  )
  func preparedUploadsPassPetrelStrip(displayP3: Bool) throws {
    let colorSpace = displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
    let photo = Self.gradientImage(width: 4032, height: 3024, colorSpace: colorSpace)
    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(
      Self.cameraJPEG(photo, orientation: .right)
    )

    #expect(ImageMetadataStripper.detectMIMEType(from: prepared.data) == "image/jpeg")
    #expect(ImageMetadataStripper.jpegIfReadOnlyFormat(prepared.data) == nil)
    let stripped = try #require(ImageMetadataStripper.stripMetadata(from: prepared.data))
    #expect(ImageMetadataStripper.reencodedForUpload(stripped) == nil)
    #expect(stripped.count <= 1_000_000)
    #expect(stripped.count - prepared.data.count < 4096)

    let output = Self.properties(of: stripped)
    #expect((output[kCGImagePropertyPixelWidth] as? Int) == 1500)
    #expect((output[kCGImagePropertyPixelHeight] as? Int) == 2000)
    #expect(((output[kCGImagePropertyOrientation] as? Int) ?? 1) == 1)
    #expect(output[kCGImagePropertyGPSDictionary] == nil)
    if displayP3 {
      let profile = output[kCGImagePropertyProfileName] as? String
      #expect(profile?.contains("P3") == true, "profile = \(profile ?? "none")")
    }
  }
}
