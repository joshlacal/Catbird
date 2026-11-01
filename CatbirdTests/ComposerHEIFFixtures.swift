#if os(iOS) || os(macOS) || os(tvOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIF-family photos built at test time, and pixel checks that tell which way up a photo is.
///
/// ImageIO writes HEIC and AVIF but not plain HEIF (`public.heif` is missing from
/// `CGImageDestinationCopyTypeIdentifiers()`), so a plain HEIF is an ImageIO HEIC whose `ftyp`
/// brands are rewritten to 'mif1'.
enum ComposerHEIFFixtures {

  static let orientation = 6

  static func destination(_ type: UTType, count: Int = 1) -> (destination: CGImageDestination, data: NSMutableData)? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, count, nil) else { return nil }
    return (destination, data)
  }

  static func properties(_ data: Data) -> [String: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, primaryImageIndex(of: data), nil) as? [String: Any] ?? [:]
  }

  static func cameraProperties(orientation: Int = ComposerHEIFFixtures.orientation) -> [CFString: Any] {
    [
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W"
      ],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"]
    ]
  }

  struct Colour: Equatable, CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
      self.red = red
      self.green = green
      self.blue = blue
      self.alpha = alpha
    }

    var description: String {
      "(\(red), \(green), \(blue), \(alpha))"
    }

    func isClose(to other: Colour, tolerance: Int = 24) -> Bool {
      [(red, other.red), (green, other.green), (blue, other.blue), (alpha, other.alpha)]
        .allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }
  }

  enum Quadrant: CaseIterable, CustomStringConvertible {
    case topLeft, topRight, bottomLeft, bottomRight

    var description: String {
      switch self {
      case .topLeft: "top left"
      case .topRight: "top right"
      case .bottomLeft: "bottom left"
      case .bottomRight: "bottom right"
      }
    }
  }

  /// The colour stored in each quadrant of `quadrantPhoto`, before any orientation is applied.
  static let quadrantColours: [Quadrant: Colour] = [
    .topLeft: Colour(red: 255, green: 0, blue: 0),
    .topRight: Colour(red: 0, green: 255, blue: 0),
    .bottomLeft: Colour(red: 0, green: 0, blue: 255),
    .bottomRight: Colour(red: 255, green: 255, blue: 0)
  ]

  static let white = Colour(red: 255, green: 255, blue: 255)

  /// The decoy image of `heicWithSecondImagePrimary`: a uniform grey no quadrant has.
  static let decoyColour = Colour(red: 128, green: 128, blue: 128)

  /// There is no `UTType` constant for AVIF.
  static let avif = UTType("public.avif")

  /// Whether ImageIO on this host can build `quadrantPhoto(type)`: an encoder that exists but
  /// fails to finalize (as on some simulators and VMs) counts as missing.
  static func encodes(_ type: UTType) -> Bool {
    quadrantPhoto(type) != nil
  }

  /// A 96x64 photo of four flat quadrants (stored top-left red, top-right green, bottom-left
  /// blue, bottom-right yellow) with the camera metadata of `cameraProperties`.
  ///
  /// The 48- and 32-pixel quadrant edges are multiples of 16, so no JPEG 4:2:0 block straddles
  /// a colour edge in either upright size. With `transparentTopLeft` the top-left quadrant is
  /// cleared to transparent; otherwise the image has no alpha channel at all.
  static func quadrantPhoto(
    _ type: UTType,
    orientation: Int = ComposerHEIFFixtures.orientation,
    transparentTopLeft: Bool = false,
    transparentTopLeftAlpha: CGFloat = 0
  ) -> Data? {
    let properties = cameraProperties(orientation: orientation)
    guard let image = quadrantImage(transparentTopLeft: transparentTopLeft, transparentTopLeftAlpha: transparentTopLeftAlpha),
       let destination = destination(type)
    else { return nil }
    CGImageDestinationAddImage(destination.destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination.destination) ? destination.data as Data : nil
  }

  /// `heic` with its 'heic' brands replaced by 'mif1', which ImageIO types as `public.heif`.
  ///
  /// The `ftyp` box holds the major brand at bytes 8..<12, the minor version at 12..<16 and
  /// the compatible brands after it. ImageIO keys `public.heic` against `public.heif` on the
  /// major brand. The length does not change, so no box or item offset moves.
  static func rebrandedAsPlainHEIF(_ heic: Data) -> Data? {
    var bytes = [UInt8](heic)
    guard bytes.count >= 16,
       bytes[4 ..< 8].elementsEqual("ftyp".utf8),
       bytes[8 ..< 12].elementsEqual("heic".utf8)
    else { return nil }
    let size = bigEndian(bytes, at: 0, width: 4)
    guard size >= 16, size <= bytes.count, size % 4 == 0 else { return nil }
    for offset in stride(from: 8, to: size, by: 4)
      where offset != 12 && bytes[offset ..< offset + 4].elementsEqual("heic".utf8) {
      bytes.replaceSubrange(offset ..< offset + 4, with: Array("mif1".utf8))
    }
    return Data(bytes)
  }

  /// A HEIC holding two images whose primary item, the one Photos shows, is the second: a grey
  /// decoy with its own GPS position at index 0, then the camera `quadrantPhoto` at index 1.
  ///
  /// ImageIO's HEIC encoder always makes the first image primary (it ignores
  /// `kCGImagePropertyPrimaryImage`), so the primary item ID in the `pitm` box is rewritten to
  /// the second image's item afterwards. Both IDs take the same two bytes, so nothing moves.
  static func heicWithSecondImagePrimary() -> Data? {
    guard let decoy = solidImage(decoyColour),
       let photo = quadrantImage(transparentTopLeft: false),
       let destination = destination(.heic, count: 2)
    else { return nil }
    let decoyProperties: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"
      ]
    ]
    CGImageDestinationAddImage(destination.destination, decoy, decoyProperties as CFDictionary)
    CGImageDestinationAddImage(destination.destination, photo, cameraProperties() as CFDictionary)
    guard CGImageDestinationFinalize(destination.destination) else { return nil }
    return primaryItemMovedToSecondImage(destination.data as Data)
  }

  /// The index of the image whose own properties flag it primary (`kCGImagePropertyPrimaryImage`),
  /// as ImageIO marks the image a HEIF's 'pitm' box names, or 0 when no image is flagged.
  static func primaryImageIndex(of data: Data) -> Int {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
    return (0 ..< CGImageSourceGetCount(source)).first { index in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
      return properties?[kCGImagePropertyPrimaryImage as String] as? Bool == true
    } ?? 0
  }

  /// The colour at the centre of each quadrant of the primary image as stored (no orientation
  /// applied), decoded into sRGB with premultiplied alpha.
  static func storedQuadrantColours(of data: Data) -> [Quadrant: Colour]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
       let image = CGImageSourceCreateImageAtIndex(source, primaryImageIndex(of: data), nil),
       let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    func colour(column: Int, row: Int) -> Colour {
      // Row 0 of a bitmap context's memory is the top row of the image.
      let offset = (row * width + column) * 4
      return Colour(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2], alpha: pixels[offset + 3])
    }
    return [
      .topLeft: colour(column: width / 4, row: height / 4),
      .topRight: colour(column: 3 * width / 4, row: height / 4),
      .bottomLeft: colour(column: width / 4, row: 3 * height / 4),
      .bottomRight: colour(column: 3 * width / 4, row: 3 * height / 4)
    ]
  }

  /// For each quadrant of the upright image, the stored quadrant an EXIF `orientation` puts
  /// there, from the orientation definitions in the EXIF and TIFF specifications rather than
  /// from ImageIO.
  static func displayedQuadrants(orientation: Int) -> [Quadrant: Quadrant] {
    let stored: [Quadrant]
    switch orientation {
    case 2: stored = [.topRight, .topLeft, .bottomRight, .bottomLeft] // mirrored left to right
    case 3: stored = [.bottomRight, .bottomLeft, .topRight, .topLeft] // rotated 180°
    case 4: stored = [.bottomLeft, .bottomRight, .topLeft, .topRight] // mirrored top to bottom
    case 5: stored = [.topLeft, .bottomLeft, .topRight, .bottomRight] // transposed
    case 6: stored = [.bottomLeft, .topLeft, .bottomRight, .topRight] // rotated 90° clockwise
    case 7: stored = [.bottomRight, .topRight, .bottomLeft, .topLeft] // transversed
    case 8: stored = [.topRight, .bottomRight, .topLeft, .bottomLeft] // rotated 90° anticlockwise
    default: stored = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }
    return Dictionary(uniqueKeysWithValues: zip([Quadrant.topLeft, .topRight, .bottomLeft, .bottomRight], stored))
  }

  /// The colours an upright decode of `quadrantPhoto(orientation:)` shows in each quadrant, with
  /// the stored top-left quadrant shown as `transparentTopLeftAs` when it was transparent.
  static func expectedUprightColours(orientation: Int, transparentTopLeftAs: Colour? = nil) -> [Quadrant: Colour] {
    displayedQuadrants(orientation: orientation).mapValues { stored in
      if stored == .topLeft, let transparentTopLeftAs {
        return transparentTopLeftAs
      }
      return quadrantColours[stored] ?? white
    }
  }

  static func coloursMatch(
    _ actual: [Quadrant: Colour]?,
    _ expected: [Quadrant: Colour],
    tolerance: Int = 24
  ) -> Bool {
    guard let actual else { return false }
    return Quadrant.allCases.allSatisfy { quadrant in
      guard let found = actual[quadrant], let wanted = expected[quadrant] else { return false }
      return found.isClose(to: wanted, tolerance: tolerance)
    }
  }

  static func hasAlpha(_ data: Data) -> Bool? {
    properties(data)[kCGImagePropertyHasAlpha as String] as? Bool
  }

}

extension ComposerHEIFFixtures {
  // MARK: - Building blocks

  private static func quadrantImage(transparentTopLeft: Bool, transparentTopLeftAlpha: CGFloat = 0) -> CGImage? {
    let width = 96, height = 64
    let alphaInfo: CGImageAlphaInfo = transparentTopLeft ? .premultipliedLast : .noneSkipLast
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let context = CGContext(
         data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
         space: colorSpace, bitmapInfo: alphaInfo.rawValue
       )
    else { return nil }
    // Core Graphics puts the origin at the bottom left, so the stored top row is y = 63.
    let rects: [Quadrant: CGRect] = [
      .topLeft: CGRect(x: 0, y: 32, width: 48, height: 32),
      .topRight: CGRect(x: 48, y: 32, width: 48, height: 32),
      .bottomLeft: CGRect(x: 0, y: 0, width: 48, height: 32),
      .bottomRight: CGRect(x: 48, y: 0, width: 48, height: 32)
    ]
    for quadrant in Quadrant.allCases {
      guard let colour = quadrantColours[quadrant], let rect = rects[quadrant] else { return nil }
      context.setFillColor(
        red: CGFloat(colour.red) / 255, green: CGFloat(colour.green) / 255,
        blue: CGFloat(colour.blue) / 255, alpha: 1
      )
      context.fill(rect)
    }
    if transparentTopLeft, let topLeft = rects[.topLeft] {
      context.clear(topLeft)
      context.setFillColor(red: 1, green: 0, blue: 0, alpha: transparentTopLeftAlpha)
      context.fill(topLeft)
    }
    return context.makeImage()
  }

  private static func solidImage(_ colour: Colour) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let context = CGContext(
         data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
         space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
       )
    else { return nil }
    context.setFillColor(
      red: CGFloat(colour.red) / 255, green: CGFloat(colour.green) / 255, blue: CGFloat(colour.blue) / 255,
      alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
    return context.makeImage()
  }

  /// `heif` with its `pitm` box pointing at the second coded image item ('hvc1') instead of
  /// the first, or nil when the boxes are not laid out as ImageIO writes them.
  private static func primaryItemMovedToSecondImage(_ heif: Data) -> Data? {
    var bytes = [UInt8](heif)
    // `meta`, `pitm`, `iinf` and `infe` are full boxes: a version byte and three flag bytes
    // come before their fields.
    guard let meta = boxes(in: bytes, range: 0 ..< bytes.count)?.first(where: { $0.type == "meta" }),
       meta.content + 4 <= meta.end,
       let children = boxes(in: bytes, range: (meta.content + 4) ..< meta.end),
       let pitm = children.first(where: { $0.type == "pitm" }),
       let iinf = children.first(where: { $0.type == "iinf" }),
       pitm.content + 6 <= pitm.end, bytes[pitm.content] == 0, // version 0: a 16-bit item ID
       iinf.content + 4 <= iinf.end
    else { return nil }
    let entryCountWidth = bytes[iinf.content] == 0 ? 2 : 4
    guard iinf.content + 4 + entryCountWidth <= iinf.end,
       let entries = boxes(in: bytes, range: (iinf.content + 4 + entryCountWidth) ..< iinf.end)
    else { return nil }
    var codedImageItems: [Int] = []
    for entry in entries where entry.type == "infe" {
      guard entry.content < entry.end, bytes[entry.content] >= 2 else { return nil }
      let idWidth = bytes[entry.content] == 2 ? 2 : 4
      let typeOffset = entry.content + 4 + idWidth + 2 // after the ID and item_protection_index
      guard typeOffset + 4 <= entry.end else { return nil }
      if bytes[typeOffset ..< typeOffset + 4].elementsEqual("hvc1".utf8) {
        codedImageItems.append(bigEndian(bytes, at: entry.content + 4, width: idWidth))
      }
    }
    guard codedImageItems.count == 2, bigEndian(bytes, at: pitm.content + 4, width: 2) == codedImageItems[0],
       codedImageItems[1] <= Int(UInt16.max)
    else { return nil }
    bytes[pitm.content + 4] = UInt8(codedImageItems[1] >> 8)
    bytes[pitm.content + 5] = UInt8(codedImageItems[1] & 0xFF)
    return Data(bytes)
  }

  /// The boxes laid end to end in `range`: four-character type, where the content starts and
  /// where the box ends, or nil when a size runs past the range. A size of 1 means a 64-bit
  /// size follows the type (ImageIO writes `mdat` that way), and 0 means the rest of the range.
  private struct Box {
    let type: String
    let content: Int
    let end: Int
  }

  private static func boxes(in bytes: [UInt8], range: Range<Int>) -> [Box]? {
    var found: [Box] = []
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
      var size = bigEndian(bytes, at: offset, width: 4)
      var headerSize = 8
      if size == 1 {
        guard offset + 16 <= range.upperBound else { return nil }
        size = bigEndian(bytes, at: offset + 8, width: 8)
        headerSize = 16
      } else if size == 0 {
        size = range.upperBound - offset
      }
      guard size >= headerSize, size <= range.upperBound - offset else { return nil }
      guard let type = String(bytes: bytes[(offset + 4) ..< (offset + 8)], encoding: .utf8) else { return nil }
      found.append(Box(type: type, content: offset + headerSize, end: offset + size))
      offset += size
    }
    return found
  }

  private static func bigEndian(_ bytes: [UInt8], at offset: Int, width: Int) -> Int {
    bytes[offset ..< offset + width].reduce(0) { $0 << 8 | Int($1) }
  }
}
#endif
