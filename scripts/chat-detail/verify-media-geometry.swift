import Foundation

@main
struct VerifyChatMediaGeometry {
  static func main() {
    for width: CGFloat in [120, 252, 280, 600] {
      for (pixelsWide, pixelsHigh) in [(1920, 1080), (400, 1200), (1200, 100)] {
        let size = ChatMediaGeometry.size(proposedWidth: width, pixelWidth: pixelsWide, pixelHeight: pixelsHigh)
        precondition(size.width <= min(width, 280) && size.height <= 400)
        precondition(abs(size.width / size.height - CGFloat(pixelsWide) / CGFloat(pixelsHigh)) < 0.001)
      }
    }
    for (w, h) in [(0, 100), (100, 0), (-100, 100)] {
      let size = ChatMediaGeometry.size(proposedWidth: 252, pixelWidth: w, pixelHeight: h)
      precondition(size.width == 252 && abs(size.height - 141.75) < 0.001)
    }
    let wide = ChatMediaGeometry.size(proposedWidth: 120, pixelWidth: 1200, pixelHeight: 100)
    precondition(wide.height == 10) // No invented minimum height or crop.
    let tall = ChatMediaGeometry.size(proposedWidth: 280, pixelWidth: 400, pixelHeight: 1200)
    precondition(tall.height == 400 && abs(tall.width - 400 / 3) < 0.001)
    let unknown = ChatMediaGeometry.size(proposedWidth: nil, pixelWidth: nil, pixelHeight: nil)
    precondition(unknown.width == 280 && unknown.height == 157.5)
    let empty = ChatMediaGeometry.size(proposedWidth: 0, pixelWidth: 400, pixelHeight: 1200)
    precondition(empty.width == 0 && empty.height == 0)
    print("PASS: metadata ratios, narrow/rotation widths, proportional height cap, invalid/missing dimensions, wide media without minimum height")
  }
}
