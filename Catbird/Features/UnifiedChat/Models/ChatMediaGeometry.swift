import Foundation

/// Media dimensions describe the content, not the cell or screen. Clamp the
/// display box by scaling both axes together so narrow bubbles retain the ratio.
enum ChatMediaGeometry {
  static func size(proposedWidth: CGFloat?, pixelWidth: Int?, pixelHeight: Int?) -> CGSize {
    let width = min(280, max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 280))
    let ratio: CGFloat
    if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
      ratio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
    } else {
      ratio = 16 / 9 // Provisional only when the message supplies no valid dimensions.
    }
    let height = min(width / ratio, 400)
    return CGSize(width: min(width, height * ratio), height: height)
  }
}
