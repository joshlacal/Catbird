#if os(iOS)
import UIKit

// MARK: - Disclosure Button

/// "Open The Vids": tinted title and small trailing chevron (`DisclosureLinkLabelStyle`), laid out
/// by frames. A plain control avoids `UIButton.Configuration`, whose attributed title converts
/// through `AttributedString` and costs milliseconds the first time.
final class TrendingDisclosureButton: UIControl {
  private let titleLabel = UILabel()
  private let glyphView = UIImageView()
  private var isRightToLeft = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    titleLabel.isUserInteractionEnabled = false
    glyphView.isUserInteractionEnabled = false
    glyphView.contentMode = .center
    addSubview(titleLabel)
    addSubview(glyphView)
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(title: NSAttributedString, glyph: UIImage?, isRightToLeft: Bool) {
    titleLabel.attributedText = title
    glyphView.image = glyph?.withRenderingMode(.alwaysTemplate)
    self.isRightToLeft = isRightToLeft
    setNeedsLayout()
  }

  /// Hides the title and chevron while a zoom anchor draws them; the control stays tappable.
  func setContentHidden(_ hidden: Bool) {
    titleLabel.isHidden = hidden
    glyphView.isHidden = hidden
  }

  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      alpha = isHighlighted ? 0.3 : 1
    }
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    // The title's `.tintColor` foreground resolves against the label's tint.
    titleLabel.setNeedsDisplay()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let text = titleLabel.attributedText.map {
      TrendingInterstitialText.singleLineSize($0, scale: traitCollection.displayScale)
    } ?? .zero
    let glyph = glyphView.image?.size ?? .zero
    let spacing = TrendingInterstitialMetrics.disclosureSpacing
    let titleWidth = min(text.width, max(0, bounds.width - glyph.width - spacing))
    var title = CGRect(x: 0, y: (bounds.height - text.height) / 2, width: titleWidth, height: text.height)
    var chevron = CGRect(x: title.maxX + spacing, y: (bounds.height - glyph.height) / 2, width: glyph.width, height: glyph.height)
    if isRightToLeft {
      title.origin.x = bounds.width - title.maxX
      chevron.origin.x = bounds.width - chevron.maxX
    }
    titleLabel.frame = TrendingInterstitialText.labelFrame(title, for: titleLabel.attributedText)
    glyphView.frame = chevron
  }
}
#endif
