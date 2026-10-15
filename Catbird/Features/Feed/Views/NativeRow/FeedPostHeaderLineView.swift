#if os(iOS)
import UIKit

// MARK: - Feed Post Header Line View

/// The "name [badge] @handle · time" line of a native feed row. Every label is placed at the
/// frame `FeedRowLayoutEngine` computed and draws with the same fonts, kerning and strings the
/// engine measured, so none of them truncates unless the engine decided the text does not fit:
/// the display name is measured with `typography.name` and no kerning, the handle with
/// `typography.metadata` and `typography.kerning`, and the time (with its "·" prefix) with
/// `typography.metadata` and no kerning.
///
/// The view spans the row's content and takes no touches; taps reach the avatar, the options
/// button and the row itself.
final class FeedPostHeaderLineView: UIView {
  private let nameLabel = UILabel()
  private let handleLabel = UILabel()
  private let timeLabel = UILabel()
  private let badgeView = UIImageView()
  private var badgeKind: VerificationBadgeKind?
  private var badgeSymbolSide: CGFloat = 0

  var nameLabelForTesting: UILabel { nameLabel }
  var handleLabelForTesting: UILabel { handleLabel }
  var timeLabelForTesting: UILabel { timeLabel }
  var badgeViewForTesting: UIImageView { badgeView }

  /// Custom actions VoiceOver offers on the name element, such as the row's "Open post".
  var nameAccessibilityActions: [UIAccessibilityCustomAction] {
    get { nameLabel.accessibilityCustomActions ?? [] }
    set { nameLabel.accessibilityCustomActions = newValue.isEmpty ? nil : newValue }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    for label in [nameLabel, handleLabel, timeLabel] {
      label.numberOfLines = 1
      addSubview(label)
    }
    nameLabel.lineBreakMode = .byTruncatingTail
    handleLabel.lineBreakMode = .byTruncatingTail
    // The time is sized to fit; clipping loses at most a sub-point sliver where tail truncation
    // would replace the whole text with an ellipsis.
    timeLabel.lineBreakMode = .byClipping
    badgeView.contentMode = .scaleAspectFit
    badgeView.tintColor = .systemBlue
    badgeView.isAccessibilityElement = true
    badgeView.isHidden = true
    handleLabel.isHidden = true
    addSubview(badgeView)
    isUserInteractionEnabled = false
    // `PostHeaderView` reads the badge right after the name. Hidden elements are skipped.
    accessibilityElements = [nameLabel, badgeView, handleLabel, timeLabel]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// - Parameters:
  ///   - originX: The x position of this view's left edge in the coordinate space of `layout`'s
  ///     frames; `0` when the view spans the row's content view.
  ///   - hideVerificationBadges: The user's "hide verification badges" preference. The badge
  ///     is also hidden when `verification` or the layout's badge frame is `nil`.
  func configure(
    _ layout: FeedRowLayout, displayName: String, handle: String, timeText: String,
    timeAccessibilityLabel: String, verification: VerificationBadgeKind?, typography: FeedRowTypography,
    metadataColor: UIColor, originX: CGFloat, hideVerificationBadges: Bool
  ) {
    func local(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: -originX, dy: 0) }

    nameLabel.attributedText = NSAttributedString(
      string: displayName,
      attributes: [.font: typography.name, .kern: CGFloat(0), .foregroundColor: UIColor.label])
    nameLabel.frame = local(layout.nameFrame)

    if let handleFrame = layout.handleFrame {
      handleLabel.attributedText = NSAttributedString(
        string: handle,
        attributes: [.font: typography.metadata, .kern: typography.kerning, .foregroundColor: metadataColor])
      handleLabel.frame = local(handleFrame)
      handleLabel.isHidden = false
    } else {
      handleLabel.isHidden = true
    }

    timeLabel.attributedText = NSAttributedString(
      string: "·  " + timeText,
      attributes: [.font: typography.metadata, .kern: CGFloat(0), .foregroundColor: metadataColor])
    timeLabel.accessibilityLabel = timeAccessibilityLabel
    timeLabel.frame = local(layout.timeFrame)

    if let badgeFrame = layout.badgeFrame, let verification, !hideVerificationBadges {
      if badgeKind != verification {
        badgeKind = verification
        badgeView.image = UIImage(systemName: verification.symbolName)
        badgeView.accessibilityLabel = verification.accessibilityLabel
      }
      if badgeSymbolSide != badgeFrame.height {
        badgeSymbolSide = badgeFrame.height
        badgeView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: badgeFrame.height)
      }
      badgeView.frame = local(badgeFrame)
      badgeView.isHidden = false
    } else {
      badgeView.isHidden = true
    }
  }
}
#endif
