#if os(iOS)
import Testing
import UIKit

// MARK: - Rendered Pixels

/// The pixels a view draws, as 8-bit RGB, for tests that check drawing against geometry.
@MainActor
struct RenderedPixels {
  let width: Int
  let height: Int
  let scale: CGFloat
  private let bytes: [UInt8]

  /// Renders `view` over a white background at `scale`.
  init(of view: UIView, scale: CGFloat) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(view.bounds)
      view.layer.render(in: context.cgContext)
    }
    let cgImage = try #require(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
        bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
      return true
    }
    try #require(drawn)
    self.width = cgImage.width
    self.height = cgImage.height
    self.scale = scale
    self.bytes = bytes
  }

  struct Color {
    let red: Int
    let green: Int
    let blue: Int

    /// Fully saturated red, away from anti-aliased edges.
    var isSolidRed: Bool { red > 230 && green < 40 && blue < 40 }
    var isSolidBlack: Bool { red < 25 && green < 25 && blue < 25 }
    var isNearWhite: Bool { red > 240 && green > 240 && blue > 240 }
  }

  func color(column: Int, row: Int) -> Color {
    let offset = (row * width + column) * 4
    return Color(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
  }

  /// The color at a point in the view's coordinate space.
  func color(at point: CGPoint) -> Color {
    color(column: min(width - 1, max(0, Int(point.x * scale))), row: min(height - 1, max(0, Int(point.y * scale))))
  }
}
#endif
