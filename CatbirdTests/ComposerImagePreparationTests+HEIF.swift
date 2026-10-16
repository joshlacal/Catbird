import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Catbird

extension ComposerImagePreparationTests {
  private typealias Fixtures = ComposerHEIFFixtures

  // These gates finalize a real encode: advertised ImageIO encoders can still be unusable.
  private static let canEncodeHEIC = Fixtures.encodes(.heic)
  private static let canEncodeAVIF = Fixtures.avif.map(Fixtures.encodes) ?? false
  private static var heifFormats: [String] {
    (canEncodeHEIC ? [UTType.heic.identifier, UTType.heif.identifier] : [])
      + (canEncodeAVIF ? ["public.avif"] : [])
  }

  private static func photo(_ identifier: String, transparent: Bool = false, alpha: CGFloat = 0) throws -> Data {
    let type = try #require(UTType(identifier == UTType.heif.identifier ? UTType.heic.identifier : identifier))
    let encoded = try #require(Fixtures.quadrantPhoto(
      type, transparentTopLeft: transparent, transparentTopLeftAlpha: alpha
    ))
    let data = try #require(identifier == UTType.heif.identifier ? Fixtures.rebrandedAsPlainHEIF(encoded) : encoded)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == identifier)
    return data
  }

  @Test("Transparent HEIF-family uploads and square crops blend onto white",
        arguments: heifFormats, [Double(0), Double(0.5)])
  func heifTransparencyFlattensOntoWhite(identifier: String, opacity: Double) throws {
    let data = try Self.photo(identifier, transparent: true, alpha: CGFloat(opacity))
    // Positive control: the encoder retained alpha, including fractional coloured pixels.
    #expect(Fixtures.hasAlpha(data) == true)
    let sourceColours = try #require(Fixtures.storedQuadrantColours(of: data))
    let stored = try #require(sourceColours[.topLeft])
    #expect(abs(Int(stored.alpha) - Int(opacity * 255)) <= 8, "\(identifier): \(stored)")
    if opacity > 0 { #expect(abs(Int(stored.red) - 128) <= 24) }

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)
    let background = opacity == 0 ? Fixtures.white : Fixtures.Colour(red: 255, green: 128, blue: 128)
    let expected = Fixtures.expectedUprightColours(orientation: identifier == "public.avif" ? 1 : 6,
                                                  transparentTopLeftAs: background)
    // Check upload pixels before requiring crop success: an alpha decoder can also make the
    // bare cropped CGImage fail to encode, which must not conceal the wrong upload pixels.
    let uploadedColours = Fixtures.storedQuadrantColours(of: prepared.data)
    #expect(Fixtures.coloursMatch(uploadedColours, expected), "\(identifier), opacity \(opacity): \(String(describing: uploadedColours))")
    #expect(prepared.data.count <= ComposerImagePreparation.uploadMaxBytes)
    #expect(Fixtures.properties(prepared.data)[kCGImagePropertyGPSDictionary as String] == nil)

    let cropped = try #require(ComposerImagePreparation.squareCroppedSynchronously(data))
    let croppedColours = Fixtures.storedQuadrantColours(of: cropped.data)
    #expect(Fixtures.coloursMatch(croppedColours, expected), "\(identifier), opacity \(opacity): \(String(describing: croppedColours))")
    #expect(Fixtures.properties(cropped.data)[kCGImagePropertyGPSDictionary as String] == nil)
    #expect(cropped.preview.sourcePixelSize == CGSize(width: 64, height: 64))
  }

  @Test("Opaque HEIF-family uploads keep their oriented colours and dimensions", arguments: heifFormats)
  func opaqueHEIFPreservesPixels(identifier: String) throws {
    let data = try Self.photo(identifier)
    // ImageIO omits HasAlpha for these opaque sources even though HEIC decodes with alpha.
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 96)
    #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 64)
    #expect(properties[kCGImagePropertyHasAlpha as String] == nil)
    let expectedSize = identifier == "public.avif" ? CGSize(width: 96, height: 64) : CGSize(width: 64, height: 96)
    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)
    let preview = try #require(ComposerImagePreparation.makePreviewSynchronously(from: data))
    #expect(prepared.pixelSize == expectedSize)
    #expect(preview.sourcePixelSize == expectedSize)
    let actual = Fixtures.storedQuadrantColours(of: prepared.data)
    let expected = Fixtures.expectedUprightColours(orientation: identifier == "public.avif" ? 1 : 6)
    #expect(Fixtures.coloursMatch(actual, expected), "\(identifier): \(String(describing: actual))")
  }

  @Test("HEIC and plain HEIF preview, upload and crop use the designated primary image",
        .enabled(if: canEncodeHEIC, "HEIC encoder cannot finalize a fixture on this host"),
        arguments: [false, true])
  func heifUsesPrimaryImage(plainHEIF: Bool) throws {
    let heic = try #require(Fixtures.heicWithSecondImagePrimary())
    let data = try #require(plainHEIF ? Fixtures.rebrandedAsPlainHEIF(heic) : heic)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 2)
    #expect(Fixtures.primaryImageIndex(of: data) == 1)
    let decoy = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let decoyData = try Self.jpeg(decoy)
    #expect(Fixtures.storedQuadrantColours(of: decoyData)?.values.allSatisfy { $0.isClose(to: Fixtures.decoyColour) } == true)

    let prepared = try ComposerImagePreparation.prepareForUploadSynchronously(data)
    let preview = try #require(ComposerImagePreparation.makePreviewSynchronously(from: data))
    let cropped = try #require(ComposerImagePreparation.squareCroppedSynchronously(data))
    #expect(prepared.pixelSize == CGSize(width: 64, height: 96))
    #expect(preview.sourcePixelSize == CGSize(width: 64, height: 96))
    #expect(preview.cgImage.width == 64 && preview.cgImage.height == 96)
    #expect(cropped.preview.sourcePixelSize == CGSize(width: 64, height: 64))
    let expected = Fixtures.expectedUprightColours(orientation: 6)
    for output in [prepared.data, try Self.jpeg(preview.cgImage), cropped.data] {
      let actual = Fixtures.storedQuadrantColours(of: output)
      #expect(Fixtures.coloursMatch(actual, expected), "plain HEIF \(plainHEIF): \(String(describing: actual))")
    }
  }

  private static func jpeg(_ image: CGImage) throws -> Data {
    let output = try #require(Fixtures.destination(.jpeg))
    CGImageDestinationAddImage(output.destination, image, nil)
    try #require(CGImageDestinationFinalize(output.destination))
    return output.data as Data
  }
}
