#if os(iOS)
import UIKit

/// Lightweight UIKit waveform view for the voice preview in the composer.
/// Draws bars from a [Float] array with a progress overlay.
final class ComposerWaveformView: UIView {

  private var waveform: [Float] = []
  private var progress: Float = 0
  private let barWidth: CGFloat = 2
  private let barSpacing: CGFloat = 1.5

  var onSeek: ((Float) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setWaveform(_ waveform: [Float], progress: Float) {
    self.waveform = waveform
    self.progress = progress
    setNeedsDisplay()
  }

  func setProgress(_ progress: Float) {
    self.progress = progress
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard !waveform.isEmpty else { return }

    let totalBarWidth = barWidth + barSpacing
    let maxBars = Int(rect.width / totalBarWidth)
    let displayCount = min(waveform.count, maxBars)

    let samples: [Float]
    if waveform.count > maxBars {
      samples = resample(waveform, to: displayCount)
    } else {
      samples = Array(waveform.prefix(displayCount))
    }

    let startX = (rect.width - CGFloat(displayCount) * totalBarWidth + barSpacing) / 2

    for (index, sample) in samples.enumerated() {
      let barProgress = Float(index) / Float(max(displayCount - 1, 1))
      let isActive = barProgress <= progress

      let color: UIColor = isActive ? .tintColor : .secondaryLabel.withAlphaComponent(0.3)
      color.setFill()

      let barHeight = max(3, CGFloat(sample) * rect.height * 0.9)
      let x = startX + CGFloat(index) * totalBarWidth
      let y = (rect.height - barHeight) / 2

      let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
      UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2).fill()
    }
  }

  private func resample(_ input: [Float], to count: Int) -> [Float] {
    guard count > 0, !input.isEmpty else { return [] }
    let step = Float(input.count) / Float(count)
    return (0..<count).map { i in
      let index = Int(Float(i) * step)
      return input[min(index, input.count - 1)]
    }
  }

  // MARK: - Tap to Seek

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    let x = touch.location(in: self).x
    let newProgress = min(max(Float(x / bounds.width), 0), 1)
    progress = newProgress
    setNeedsDisplay()
    onSeek?(newProgress)
  }
}
#endif
